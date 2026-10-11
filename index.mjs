// opencode desktop-pet plugin
// - opencode TUI/app 会话事件 -> 桌宠状态机（thinking / tool / review / error）
// - 本地 HTTP 服务：GET /api/state、SSE /api/events、POST /api/say|animation|reload|look_at_mouse|look_at_opencode|chat|working|idle|activity|pet/*
// - 心跳注册 %TEMP%\opencode-desktop-pet\inst-<pid>-<instanceId>.json，供 pet-window.ps1 独立模式发现
// - 拉起 pet-window.ps1（WPF 透明置顶窗）
import { createServer } from "node:http";
import { readFile, stat, writeFile, mkdir, unlink, copyFile } from "node:fs/promises";
import { statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
    syncSources,
    listLibrary,
    activateLibraryPet,
    importLibraryPet,
    saveCurrentLibraryPet,
    removeLibraryPet,
} from "./config-store.mjs";
import {
    DEFAULT_CONFIG,
    EXPLICIT_IDLE_SUPPRESS_MS,
    DONE_PHRASES,
    CRASH_PHRASES,
    ERROR_PHRASES,
    clampPollMs,
    mergeConfig,
    createPetState,
    markWorking,
    markIdle,
    sanitizeActivity,
    computeActivity,
    say,
    visibleMessage,
    setAnimation,
    setLookAtMouse,
    setLookAtOpenCode,
    setWorkPhase,
    pickPhrase,
    buildChatPrompt,
    truncateForBubble,
    normalizeChatText,
} from "./state.mjs";

const EXT_DIR = path.dirname(fileURLToPath(import.meta.url));
const USER_DATA_DIR = path.join(process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming"), "opencode-desktop-pet");
const LEGACY_CONFIG_FILE = path.join(EXT_DIR, "pet.json");
const CONFIG_FILE = path.join(USER_DATA_DIR, "pet.json");
const HTML_FILE = path.join(EXT_DIR, "pet.html");
const PS1_FILE = path.join(EXT_DIR, "pet-window.ps1");
const REG_DIR = path.join(os.tmpdir(), "opencode-desktop-pet");
// 实例唯一 ID：文件名带随机后缀，避免 PID 复用或多个桌宠实例之间的注册文件撞名
const INSTANCE_ID = randomUUID().slice(0, 8);
const REG_FILE = path.join(REG_DIR, `inst-${process.pid}-${INSTANCE_ID}.json`);
const DEFAULT_HTTP_PORT = 12030;
const BODY_LIMIT = 18 * 1024 * 1024; // 桌宠导入包含 base64 贴图（最大 12 MiB）

let configCache = { mtimeMs: -1, config: DEFAULT_CONFIG };
let petProcess = null;
let server = null;
let serverPort = 0;
const sseClients = new Set();
const state = createPetState(Date.now());
const sessions = new Map(); // sessionID -> { activity }
let lastWorkingAt = 0;
let explicitIdleUntil = 0;
let opencodeClient = null;   // 插件上下文提供的 SDK client，用于聊天
let lastSessionID = "";      // 最近活跃的会话，聊天消息发往这里
let chatBusy = false;

async function ensureUserData() {
    try { await stat(CONFIG_FILE); }
    catch {
        try { await mkdir(USER_DATA_DIR, { recursive: true }); } catch {}
        try { await copyFile(LEGACY_CONFIG_FILE, CONFIG_FILE, 1); } // EXCL
        catch { /* fall through */ }
        try {
            await stat(CONFIG_FILE);
        } catch {
            await writeFile(CONFIG_FILE, JSON.stringify(DEFAULT_CONFIG, null, 2));
        }
    }
}

async function readConfig(force) {
    try {
        await ensureUserData();
        if (force) await syncSources(USER_DATA_DIR, EXT_DIR).catch(() => {});
        const st = await stat(CONFIG_FILE);
        if (force || st.mtimeMs !== configCache.mtimeMs) {
            const raw = await readFile(CONFIG_FILE, "utf8");
            configCache = { mtimeMs: st.mtimeMs, config: mergeConfig(JSON.parse(raw)) };
        }
    } catch (err) {
        configCache.config = mergeConfig(null);
    }
    if (force) {
        state.lookAtMouse = !!configCache.config.behavior.lookAtMouse;
        state.lookAtOpenCode = !!configCache.config.behavior.lookAtOpenCode;
    }
    return configCache.config;
}

function now() { return Date.now(); }

async function readActiveIdSafe() {
    try { return JSON.parse(await readFile(path.join(USER_DATA_DIR, "pets", "active.json"), "utf8")).id || ""; }
    catch { return ""; }
}

function aggregatedWorking() {
    for (const v of sessions.values()) if (v.activity === "working") return true;
    return false;
}

function currentActivity() {
    const cfg = configCache.config;
    const entries = [...sessions.values()];
    const selfWorking = state.activity === "working" || aggregatedWorking();
    const st = { ...state };
    if (selfWorking) st.activity = "working"; else st.activity = "idle";
    // 独立兜底：opencode.db-wal 最近写入
    let fallbackActive = false;
    try {
        const wal = path.join(os.homedir(), ".local", "share", "opencode", "opencode.db-wal");
        const st2 = statSync(wal);
        fallbackActive = (Date.now() - st2.mtimeMs) < 6000;
    } catch { fallbackActive = false; }
    return computeActivity({ state: st, entries: selfWorking ? [] : entries, now: now(), fallbackActive });
}

function pushState() {
    const cfg = configCache.config;
    const act = currentActivity();
    const visible = state.message && now() < state.messageUntil ? state.message : null;
    const payload = {
        service: "opencode-desktop-pet",
        animation: state.animation,
        message: visible,
        activity: act.activity,
        activitySource: act.source,
        workPhase: act.activity === "working" ? state.workPhase : null,
        lookAtMouse: state.lookAtMouse,
        lookAtOpenCode: state.lookAtOpenCode,
        running: !!(petProcess && petProcess.exitCode === null && !petProcess.killed),
        sessions: sessions.size,
        pollIntervalMs: clampPollMs(cfg.pollIntervalMs, 250),
        externalEvents: cfg.externalEvents,
        pid: process.pid,
    };
    const data = `event: state\ndata: ${JSON.stringify(payload)}\n\n`;
    for (const res of sseClients) { try { res.write(data); } catch {} }
    return payload;
}

function onWorking(sessionID, phase) {
    if (sessionID) sessions.set(sessionID, { activity: "working" });
    markWorking(state, now());
    lastWorkingAt = now();
    if (phase) setWorkPhase(state, phase);
    pushState();
}

function onIdle(sessionID, opts) {
    const wasWorking = state.activity === "working" || aggregatedWorking();
    if (sessionID) sessions.delete(sessionID);
    const res = markIdle(state, now(), opts || { suppressMs: EXPLICIT_IDLE_SUPPRESS_MS });
    if (wasWorking || res.wasWorking) {
        // 收工：演一段 review，并冒泡
        if (!state.crashed) {
            state.animation = "review";
            say(state, pickPhrase(DONE_PHRASES), 4, now());
            setTimeout(() => { if (state.animation === "review") state.animation = null; pushState(); }, 6000);
        }
    }
    pushState();
}

function onError(sessionID) {
    if (sessionID) sessions.delete(sessionID);
    markIdle(state, now(), { suppressMs: EXPLICIT_IDLE_SUPPRESS_MS });
    state.animation = "error";
    say(state, pickPhrase(ERROR_PHRASES), 4, now());
    setTimeout(() => { if (state.animation === "error") state.animation = null; pushState(); }, 6000);
    pushState();
}

async function startDesktopPet() {
    if (petProcess && petProcess.exitCode === null && !petProcess.killed) return { ok: true, already: true };
    const url = `http://127.0.0.1:${serverPort}/`;
    petProcess = spawn("powershell", ["-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PS1_FILE, "-ExtDir", EXT_DIR, "-StateUrl", url], {
        detached: true, stdio: "ignore", windowsHide: false,
    });
    petProcess.once("exit", () => { petProcess = null; });
    petProcess.unref();
    return { ok: true };
}

async function stopDesktopPet() {
    try { petProcess?.kill(); } catch {}
    petProcess = null;
    // WPF runs its message loop in powershell.exe; terminate the window host tree as well.
    return { ok: true };
}

async function handle(req, res) {
    const url = new URL(req.url, "http://127.0.0.1");
    const p = url.pathname;
    const isPost = req.method === "POST";
    const json = (code, obj) => { res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Access-Control-Allow-Origin": "*" }); res.end(JSON.stringify(obj)); };
    const readBody = () => new Promise((resolve) => { let b = ""; req.on("data", (c) => { if (b.length < BODY_LIMIT) b += c; }); req.on("end", () => resolve(b)); });

    if (p === "/api/state") { json(200, pushState()); return; }
    if (p === "/api/events") {
        res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive", "Access-Control-Allow-Origin": "*" });
        res.write(`event: state\ndata: ${JSON.stringify(pushState())}\n\n`);
        sseClients.add(res); req.on("close", () => sseClients.delete(res));
        return;
    }
    if (p === "/" || p === "/index.html") {
        try { const html = await readFile(HTML_FILE, "utf8"); res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" }); res.end(html); }
        catch { json(404, { error: "no index" }); }
        return;
    }
    if (p === "/pet.json") {
        const cfg = await readConfig();
        json(200, cfg); return;
    }
    if (req.method === "GET" && !p.startsWith("/api/")) {
        let relative;
        try { relative = decodeURIComponent(p.slice(1)); } catch { json(400, { error: "bad path" }); return; }
        if (!/\.(png|gif|webp)$/i.test(relative) || relative.split(/[\\/]/).some((part) => part === "..")) { json(404, { error: "not found" }); return; }
        const roots = relative.replace(/\\/g, "/").startsWith("pets/") ? [USER_DATA_DIR] : [USER_DATA_DIR, EXT_DIR];
        for (const root of roots) {
            const file = path.resolve(root, relative);
            if (!file.startsWith(path.resolve(root) + path.sep)) continue;
            try {
                const data = await readFile(file);
                const type = /\.png$/i.test(file) ? "image/png" : /\.gif$/i.test(file) ? "image/gif" : "image/webp";
                res.writeHead(200, { "Content-Type": type, "Cache-Control": "no-cache" }); res.end(data); return;
            } catch {}
        }
        json(404, { error: "sprite not found" }); return;
    }
    if (p === "/api/sessions") { json(200, { sessions: [...sessions.entries()].map(([id, v]) => ({ id, activity: v.activity })), cwd: process.cwd() }); return; }
    if (p === "/api/pets" && !isPost) {
        const pets = await listLibrary(USER_DATA_DIR);
        const activeId = (await readActiveIdSafe()) || null;
        json(200, { pets, activeId }); return;
    }
    if (p === "/api/pets/activate" && isPost) {
        const b = JSON.parse(await readBody() || "{}");
        try {
            await activateLibraryPet(USER_DATA_DIR, EXT_DIR, b.id);
            const config = await readConfig(true);
            json(200, { ok: true, config });
        }
        catch (err) { json(400, { ok: false, error: err.message }); }
        return;
    }
    if (p === "/api/pets/save" && isPost) {
        try {
            const id = await saveCurrentLibraryPet(USER_DATA_DIR, EXT_DIR);
            const pets = await listLibrary(USER_DATA_DIR);
            json(200, { ok: true, pet: pets.find((p) => p.id === id) || { id, name: "桌宠" } });
        }
        catch (err) { json(400, { ok: false, error: err.message }); }
        return;
    }
    if (p === "/api/pets/delete" && isPost) {
        const b = JSON.parse(await readBody() || "{}");
        try { await removeLibraryPet(USER_DATA_DIR, EXT_DIR, b.id); await readConfig(true); json(200, { ok: true }); }
        catch (err) { json(400, { ok: false, error: err.message }); }
        return;
    }
    if (p === "/api/pets/import" && isPost) {
        // body: { config: "JSON", spriteName: "spritesheet.png", spriteData: "<base64>" }
        const b = JSON.parse(await readBody() || "{}");
        try {
            const config = typeof b.config === "string" ? JSON.parse(b.config) : b.config;
            const ext = path.extname(String(b.spriteName || config?.sprite || ""));
            const buf = Buffer.from(String(b.spriteData || b.sprite || ""), "base64");
            const id = await importLibraryPet(USER_DATA_DIR, EXT_DIR, config, buf, ext);
            const activeConfig = await readConfig(true);
            json(200, { ok: true, id, pet: { id, name: activeConfig.name || "桌宠" } });
        } catch (err) { json(400, { ok: false, error: err.message }); }
        return;
    }
    if (p === "/api/open_folder" && isPost) {
        spawn("explorer", [path.join(USER_DATA_DIR, "pets")], { detached: true, stdio: "ignore", windowsHide: true }).unref();
        json(200, { ok: true }); return;
    }
    if (p === "/api/chat" && isPost) {
        const b = JSON.parse(await readBody() || "{}");
        const cfg = await readConfig();
        const norm = normalizeChatText(b.text ?? b.message, cfg);
        if (!norm.ok) { json(400, norm); return; }
        if (chatBusy) { json(429, { error: "已有聊天进行中" }); return; }
        if (!opencodeClient || !lastSessionID) { json(503, { error: "没有可用的 opencode 会话" }); return; }
        chatBusy = true;
        try {
            const prompt = buildChatPrompt(norm.text, cfg);
            const call = opencodeClient.session.prompt({
                path: { id: lastSessionID },
                body: { parts: [{ type: "text", text: prompt }] },
            });
            const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), cfg.chat.timeoutMs));
            const result = await Promise.race([call, timeout]);
            const reply = (result?.data?.parts || []).filter((x) => x.type === "text").map((x) => x.text).join("").trim();
            if (!reply) throw new Error("empty reply");
            say(state, truncateForBubble(reply), 8, now());
            pushState();
            json(200, { ok: true, reply });
        } catch (err) {
            const offline = pickPhrase(cfg.chat.offlineReplies || ["..."]);
            say(state, offline, 4, now());
            pushState();
            json(504, { ok: false, error: String(err?.message || err), reply: offline });
        } finally {
            chatBusy = false;
        }
        return;
    }
    if (p === "/api/say" && isPost) { const b = JSON.parse(await readBody() || "{}"); say(state, b.text || "", b.durationSec, now()); pushState(); json(200, { ok: true }); return; }
    if (p === "/api/animation" && isPost) { const b = JSON.parse(await readBody() || "{}"); const cfg = await readConfig(); const r = setAnimation(state, b.animation, cfg); pushState(); json(r.ok ? 200 : 400, r); return; }
    if (p === "/api/look_at_mouse" && isPost) { const b = JSON.parse(await readBody() || "{}"); setLookAtMouse(state, b.enabled); pushState(); json(200, { ok: true, lookAtMouse: state.lookAtMouse }); return; }
    if (p === "/api/look_at_opencode" && isPost) { const b = JSON.parse(await readBody() || "{}"); setLookAtOpenCode(state, b.enabled); pushState(); json(200, { ok: true, lookAtOpenCode: state.lookAtOpenCode }); return; }
    if (p === "/api/reload" && isPost) { await readConfig(true); json(200, { ok: true }); return; }
    if (p === "/api/pet/show" || p === "/api/pet/hide" || p === "/api/pet/toggle") {
        if (p === "/api/pet/hide") { json(200, await stopDesktopPet()); return; }
        if (p === "/api/pet/toggle" && petProcess && !petProcess.killed) { json(200, await stopDesktopPet()); return; }
        json(200, await startDesktopPet()); return;
    }
    if ((p === "/api/working" || p === "/api/idle" || p === "/api/activity") && isPost) {
        const cfg = await readConfig();
        if (!cfg.externalEvents?.enabled) { json(403, { error: "externalEvents disabled" }); return; }
        if (cfg.externalEvents?.token) {
            const tok = req.headers["x-pet-token"] || url.searchParams.get("token");
            if (tok !== cfg.externalEvents.token) { json(401, { error: "bad token" }); return; }
        }
        const b = JSON.parse(await readBody() || "{}");
        let act = null;
        if (p === "/api/activity") act = sanitizeActivity(b.activity);
        else act = p === "/api/working" ? "working" : "idle";
        if (!act) { json(400, { error: "bad activity" }); return; }
        if (act === "working") onWorking(null, "tool"); else onIdle(null);
        json(200, { ok: true, activity: act }); return;
    }
    json(404, { error: "not found" });
}

async function writeRegistry() {
    try {
        await mkdir(REG_DIR, { recursive: true });
        await writeFile(REG_FILE, JSON.stringify({ pid: process.pid, id: INSTANCE_ID, url: `http://127.0.0.1:${serverPort}/`, ts: now() }));
    } catch {}
}

async function startServer() {
    await ensureUserData();
    await syncSources(USER_DATA_DIR, EXT_DIR).catch(() => {});
    await readConfig(true);
    const cfg = configCache.config;
    server = createServer((req, res) => { handle(req, res).catch(() => { try { res.writeHead(500); res.end(); } catch {} }); });
    const preferred = Number(process.env.PET_HTTP_PORT) || DEFAULT_HTTP_PORT;
    await new Promise((resolve) => {
        const onError = () => {
            server.off("listening", onListening);
            // 固定端口已被占用时保持关闭，避免静默换端口后启动器接错其他桌宠服务。
            serverPort = -1;
            resolve();
        };
        const onListening = () => {
            server.off("error", onError);
            resolve();
        };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(preferred, "127.0.0.1", resolve);
    });
    if (serverPort === -1 || !server.address()) { server = null; return false; }
    serverPort = server.address().port;
    await writeRegistry();
    setInterval(writeRegistry, 3000).unref();
    return true;
}

export const OpenCodeDesktopPet = async (input) => {
    opencodeClient = input?.client || null;
    const serverStarted = await startServer().catch(() => false);
    const cfg = await readConfig();
    if (serverStarted && cfg.autoStart) startDesktopPet().catch(() => {});

    return {
        event: async ({ event }) => {
            try {
                const type = event.type;
                if (event.properties?.sessionID) lastSessionID = event.properties.sessionID;
                if (type === "session.status") {
                    const st = event.properties.status;
                    if (st.type === "busy") onWorking(event.properties.sessionID, sessions.has(event.properties.sessionID) ? undefined : "thinking");
                    else if (st.type === "idle") onIdle(event.properties.sessionID);
                    else if (st.type === "retry") { onWorking(event.properties.sessionID, "thinking"); say(state, "重试中…", 3, now()); }
                } else if (type === "session.idle") {
                    onIdle(event.properties.sessionID);
                } else if (type === "session.error") {
                    onError(event.properties.sessionID);
                }
            } catch {}
        },
        "chat.message": async () => { onWorking(null, "thinking"); },
        "tool.execute.before": async (input) => { onWorking(input?.sessionID, "tool"); },
        "tool.execute.after": async (input) => { onWorking(input?.sessionID, "thinking"); },
        "permission.ask": async () => { say(state, "需要你确认一下…", 4, now()); pushState(); },
        dispose: async () => {
            try { await unlink(REG_FILE); } catch {}
            try { server?.close(); } catch {}
        },
    };
};

export default OpenCodeDesktopPet;
