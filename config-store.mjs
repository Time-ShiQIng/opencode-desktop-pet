// 配置与桌宠库的磁盘协议（扩展与独立窗口共用）
// 工作副本：<dataDir>/pet.json；桌宠库：<dataDir>/pets/<uuid>/pet.json + 贴图；
// 当前激活项：<dataDir>/pets/active.json；哈希日志：<dataDir>/.config-sources.json。
// 只有“源文件内容发生变化”才会覆盖工作副本，旧源文件不能撤销一次切换。
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile, stat, copyFile, mkdir, rename, readdir, rm } from "node:fs/promises";
import path from "node:path";

export const validPetId = (id) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(id || ""));
const hash = (text) => createHash("sha256").update(text.replace(/^\uFEFF/, "")).digest("hex");

async function optionalRead(file) {
    try { return await readFile(file, "utf8"); }
    catch (err) { if (err.code === "ENOENT") return null; throw err; }
}

export async function atomicJson(file, value) {
    const temporary = file + "." + randomUUID() + ".tmp";
    await writeFile(temporary, JSON.stringify(value, null, 2), "utf8");
    await rename(temporary, file);
}

async function readActiveId(dataDir) {
    try { return JSON.parse(await readFile(path.join(dataDir, "pets", "active.json"), "utf8")).id || ""; }
    catch { return ""; }
}

function petDir(dataDir, id) {
    if (!validPetId(id)) throw new Error("无效的桌宠编号");
    return path.join(dataDir, "pets", id);
}

async function snapshotSources(dataDir, extDir) {
    const legacy = await optionalRead(path.join(extDir, "pet.json"));
    const id = await readActiveId(dataDir);
    const library = validPetId(id) ? await optionalRead(path.join(petDir(dataDir, id), "pet.json")) : null;
    const journal = { legacy: legacy === null ? null : hash(legacy), id, library: library === null ? null : hash(library) };
    await atomicJson(path.join(dataDir, ".config-sources.json"), journal);
    return journal;
}

async function applySource(file, raw, sourceDir, dataDir, id) {
    const cfg = JSON.parse(raw.replace(/^\uFEFF/, ""));
    if (!cfg || Array.isArray(cfg) || typeof cfg !== "object") throw new Error("配置必须是 JSON 对象");
    const sprite = String(cfg.sprite || "");
    if (path.basename(sprite) !== sprite || !/\.(png|gif|webp)$/i.test(sprite)) throw new Error("配置中的贴图路径无效");
    if (id) cfg.sprite = path.join("pets", id, sprite).replace(/\\/g, "/");
    else await copyFile(path.join(sourceDir, sprite), path.join(dataDir, sprite));
    await atomicJson(file, cfg);
}

// 启动时调用：首次迁移，之后只同步“内容真的变了”的源
export async function syncSources(dataDir, extDir) {
    await mkdir(path.join(dataDir, "pets"), { recursive: true });
    const file = path.join(dataDir, "pet.json");
    const journalRaw = await optionalRead(path.join(dataDir, ".config-sources.json"));
    const legacyFile = path.join(extDir, "pet.json");
    const legacy = await optionalRead(legacyFile);
    if (!journalRaw) {
        // 升级：旧扩展目录里的 pet.json 比工作副本新时，采用它
        if (legacy !== null) {
            const workingStat = await stat(file).catch(() => null);
            const legacyStat = await stat(legacyFile);
            if (!workingStat || legacyStat.mtimeMs > workingStat.mtimeMs) await applySource(file, legacy, extDir, dataDir, "");
        }
        await snapshotSources(dataDir, extDir);
        return;
    }
    const previous = JSON.parse(journalRaw);
    const id = await readActiveId(dataDir);
    const library = validPetId(id) ? await optionalRead(path.join(petDir(dataDir, id), "pet.json")) : null;
    // 显式切换优先：不重放旧的库快照
    if (legacy !== null && hash(legacy) !== previous.legacy) {
        await applySource(file, legacy, extDir, dataDir, "");
        await atomicJson(path.join(dataDir, "pets", "active.json"), { id: "" });
    } else if (id === previous.id && library !== null && hash(library) !== previous.library) {
        await applySource(file, library, petDir(dataDir, id), dataDir, id);
    } else if (id === previous.id
        && (library === null ? null : hash(library)) === previous.library
        && (legacy === null ? null : hash(legacy)) === previous.legacy) return;
    await snapshotSources(dataDir, extDir);
}

// ---- 桌宠库 ----

export async function listLibrary(dataDir) {
    const root = path.join(dataDir, "pets");
    let entries = [];
    try { entries = await readdir(root, { withFileTypes: true }); } catch { return []; }
    const out = [];
    for (const e of entries) {
        if (!e.isDirectory() || !validPetId(e.name)) continue;
        try {
            const cfg = JSON.parse((await readFile(path.join(root, e.name, "pet.json"), "utf8")).replace(/^\uFEFF/, ""));
            out.push({ id: e.name, name: String(cfg.name || e.name) });
        } catch { /* 跳过损坏的条目 */ }
    }
    return out;
}

export async function activateLibraryPet(dataDir, extDir, id) {
    const dir = petDir(dataDir, id);
    const raw = await readFile(path.join(dir, "pet.json"), "utf8");
    const cfg = JSON.parse(raw.replace(/^\uFEFF/, ""));
    const sprite = String(cfg.sprite || "");
    if (path.basename(sprite) !== sprite) throw new Error("找不到桌宠贴图");
    await stat(path.join(dir, sprite)).catch(() => { throw new Error("找不到桌宠贴图"); });
    cfg.sprite = "pets/" + id + "/" + sprite;
    await atomicJson(path.join(dataDir, "pet.json"), cfg);
    await atomicJson(path.join(dataDir, "pets", "active.json"), { id });
    await snapshotSources(dataDir, extDir);
}

// 导入：config 为对象，spriteBuffer 为贴图二进制，ext 为 .png/.gif/.webp
export async function importLibraryPet(dataDir, extDir, config, spriteBuffer, ext) {
    const e = String(ext || "").toLowerCase();
    if (![".png", ".gif", ".webp"].includes(e)) throw new Error("贴图仅支持 PNG、GIF 或 WebP");
    if (spriteBuffer.length > 12 * 1024 * 1024) throw new Error("贴图超过 12 MB");
    if (!config || Array.isArray(config) || typeof config !== "object") throw new Error("配置必须是 JSON 对象");
    const id = randomUUID();
    const dir = petDir(dataDir, id);
    await mkdir(dir, { recursive: true });
    const sprite = "spritesheet" + e;
    await writeFile(path.join(dir, sprite), spriteBuffer);
    await atomicJson(path.join(dir, "pet.json"), { ...config, sprite });
    await activateLibraryPet(dataDir, extDir, id);
    return id;
}

export async function saveCurrentLibraryPet(dataDir, extDir) {
    await syncSources(dataDir, extDir);
    const cfg = JSON.parse((await readFile(path.join(dataDir, "pet.json"), "utf8")).replace(/^\uFEFF/, ""));
    const sprite = path.join(dataDir, String(cfg.sprite || ""));
    const src = await stat(sprite).then(() => sprite, () => path.join(extDir, String(cfg.sprite || "")));
    const id = randomUUID();
    const dir = petDir(dataDir, id);
    await mkdir(dir, { recursive: true });
    const name = path.basename(src);
    await copyFile(src, path.join(dir, name));
    await atomicJson(path.join(dir, "pet.json"), { ...cfg, sprite: name });
    return id;
}

export async function removeLibraryPet(dataDir, extDir, id) {
    const dir = petDir(dataDir, id);
    await stat(path.join(dir, "pet.json")).catch(() => { throw new Error("找不到该桌宠"); });
    const working = JSON.parse((await readFile(path.join(dataDir, "pet.json"), "utf8")).replace(/^\uFEFF/, ""));
    const active = await readActiveId(dataDir);
    if (active === id || String(working.sprite || "").replace(/\\/g, "/").startsWith("pets/" + id + "/")) {
        const others = (await listLibrary(dataDir)).filter((p) => p.id !== id);
        if (!others.length) throw new Error("请先导入或保存另一只桌宠，再删除当前桌宠");
        await activateLibraryPet(dataDir, extDir, others[0].id);
    }
    await rm(dir, { recursive: true, force: true });
}
