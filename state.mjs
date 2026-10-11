// 桌宠状态机（纯逻辑：无 IO、无副作用，便于单元测试）
// extension.mjs 与本地 HTTP 服务共用：
//   - agent 会话事件、HTTP 外部推送，全部收敛到 markWorking / markIdle
//   - computeActivity 把「本会话状态 + 其他会话心跳 + 事件日志兜底」合成为最终展示状态

// 桌宠气泡能显示的字符数（聊天回复可能很长，气泡只放摘要）
export const BUBBLE_TEXT_MAX = 160;

export const DEFAULT_CONFIG = {
    name: "opencode 桌宠",
    autoStart: true,
    sprite: "spritesheet.png",
    frameWidth: 32,
    frameHeight: 32,
    scale: 4,
    fps: 8,
    defaultAnimation: "idle",
    animations: { idle: { row: 0, frames: 4 } },
    behavior: { autoWander: true, walkSpeedPxPerSec: 40, wanderIntervalSec: [3, 8], sleepAfterIdleSec: 45, lookAtMouse: false, lookAtOpenCode: false },
    speech: { phrases: ["(◕‿◕)"], fontSize: 13 },
    // 聊天：消息发给当前 opencode 会话，回复由桌宠说出来
    chat: {
        persona: "",
        timeoutMs: 60000,
        maxChars: 2000,
        offlineReplies: ["我现在连不上大脑（opencode 会话），先陪我待会儿吧。"],
    },
    pollIntervalMs: 250,
    // 外部事件监听：默认关闭。开启后可通过本机 HTTP 直接推送 working / idle，
    // 这样不装 opencode 扩展（例如只用 PowerShell 启动）也能让桌宠联动。
    externalEvents: { enabled: false, port: 0, token: "" },
};

// 「明确空闲」信号之后的兜底抑制窗口：
// 收到 session.idle（或 POST /api/idle）说明本会话确实收工了，
// 但 events.jsonl 可能仍被后台补写，此时不能再让兜底逻辑把桌宠拉回 working。
export const EXPLICIT_IDLE_SUPPRESS_MS = 7000;

export const WORK_EVENTS = [
    "user.message", "assistant.turn_start", "assistant.message",
    "assistant.reasoning", "tool.execution_start", "tool.execution_complete",
];

// 「思考中」与「干工具活」的区分：同一批工作事件里，只有工具执行算 tool 阶段，
// 其余（用户发话、模型开始/正在推理、工具跑完在琢磨结果）都算 thinking 阶段。
export const TOOL_EVENTS = ["tool.execution_start"];
export const THINKING_EVENTS = ["user.message", "assistant.turn_start", "assistant.message", "assistant.reasoning", "tool.execution_complete"];

export const DONE_PHRASES = ["做完了。", "任务完成，去看看吧。", "嗯，都处理好了。", "收工。"];
export const CRASH_PHRASES = ["哎呀，我摔了一跤……", "出了点状况，正在重启。", "别慌，我马上回来。"];
// 主动结束（用户点停止/打断）与异常结束（会话报错）分开演，别让两种收场看起来一样
export const ABORT_PHRASES = ["好，我停下来了。", "那我先不做了。", "听你的，收手。"];
export const ERROR_PHRASES = ["出错了……我有点懵。", "这次没跑通，再看看日志？", "呜，报错了。"];

// 特殊动画别名：pet.json 里用哪个名字都行，按顺序取第一个存在的
export const ANIM_ALIASES = {
    thinking: ["thinking", "think", "reasoning"],
    tool: ["work", "typing", "busy"],
    drag: ["drag", "grab", "lift"],
    poke: ["poke", "tap", "hit"],
    chat: ["chat", "talk", "talking"],
    look: ["look", "stare", "watch"],
    sleep: ["sleep", "rest"],
    walk: ["walk"],
    review: ["review", "done", "inspect"],
    aborted: ["aborted", "stop", "cancel", "interrupted"],
    error: ["error", "failed", "crash"],
};

// 聊天时给 opencode 的桌宠人设：{name} 会替换成 pet.json 里的 name
export const DEFAULT_CHAT_PERSONA =
    "你是一只住在 Windows 桌面上的 2D 桌宠，名字叫「{name}」。"
    + "用简短、可爱、口语化的中文回答，控制在 80 字以内；"
    + "不要调用任何工具，不要修改文件或执行命令，只是聊天。";

const POLL_MIN_MS = 100;
const POLL_MAX_MS = 5000;

export function clampPollMs(value, fallback) {
    const n = Number(value);
    if (!Number.isFinite(n) || n <= 0) return fallback;
    return Math.min(POLL_MAX_MS, Math.max(POLL_MIN_MS, Math.round(n)));
}

// 浅合并 + 嵌套字段补齐：pet.json 只写一部分时也要拿到完整默认值
export function mergeConfig(parsed) {
    const src = parsed || {};
    const cfg = Object.assign({}, DEFAULT_CONFIG, src);
    cfg.behavior = Object.assign({}, DEFAULT_CONFIG.behavior, src.behavior || {});
    cfg.speech = Object.assign({}, DEFAULT_CONFIG.speech, src.speech || {});
    cfg.chat = Object.assign({}, DEFAULT_CONFIG.chat, src.chat || {});
    cfg.externalEvents = Object.assign({}, DEFAULT_CONFIG.externalEvents, src.externalEvents || {});
    return cfg;
}

export function createPetState(now) {
    return {
        animation: null,      // 动画覆盖（null = 自动行为）
        message: null,
        messageUntil: 0,
        activity: "idle",     // idle | working
        activityAt: now || 0,
        explicitIdleUntil: 0, // 兜底抑制截止时间戳
        workPhase: null,      // working 期间的细分：thinking | tool
        lookAtMouse: false,   // 看着鼠标模式（桌面窗据此让桌宠朝光标转头）
        lookAtOpenCode: false, // 看向 opencode 窗口的对话区
        crashed: false,
    };
}

export function markWorking(state, now) {
    state.activity = "working";
    state.activityAt = now;
    state.crashed = false;
    return state;
}

// 返回 { wasWorking }：调用方据此决定要不要放「做完了」的复盘动画
export function markIdle(state, now, opts) {
    const wasWorking = state.activity === "working";
    state.activity = "idle";
    state.activityAt = now;
    state.crashed = false;
    state.workPhase = null;
    const suppressMs = opts && Number(opts.suppressMs);
    if (Number.isFinite(suppressMs) && suppressMs > 0) state.explicitIdleUntil = now + suppressMs;
    return { wasWorking };
}

export function sanitizeActivity(value) {
    if (typeof value !== "string") return null;
    const v = value.trim().toLowerCase();
    if (v === "working" || v === "busy" || v === "work") return "working";
    if (v === "idle" || v === "done" || v === "stop" || v === "stopped") return "idle";
    return null;
}

// 合成最终状态；source 便于 /api/state 调试与测试断言
export function computeActivity(input) {
    const state = input.state;
    const entries = input.entries || [];
    const now = input.now;
    if (state.activity === "working") return { activity: "working", source: "self" };
    if (entries.some((e) => e && e.activity === "working")) return { activity: "working", source: "registry" };
    // 明确空闲的抑制窗口内：忽略事件日志兜底，并把来源标成 explicit-idle 便于排查
    if (now < state.explicitIdleUntil) return { activity: "idle", source: "explicit-idle" };
    if (input.fallbackActive) return { activity: "working", source: "events-log" };
    return { activity: "idle", source: entries.length ? "registry" : "none" };
}

export function say(state, text, durationSec, now) {
    state.message = String(text == null ? "" : text);
    const sec = Math.max(1, Number(durationSec) || 4);
    state.messageUntil = now + sec * 1000;
    return { ok: true };
}

export function visibleMessage(state, now) {
    return state.message && now < state.messageUntil ? state.message : null;
}

export function setAnimation(state, anim, config) {
    if (anim === null || anim === undefined || anim === "" || anim === "auto") {
        state.animation = null;
        return { ok: true, animation: null };
    }
    const animations = (config && config.animations) || {};
    if (!(anim in animations)) {
        return { ok: false, error: "unknown animation '" + anim + "'", available: Object.keys(animations) };
    }
    state.animation = anim;
    return { ok: true, animation: anim };
}

export function pickPhrase(list, random) {
    const rnd = typeof random === "function" ? random : Math.random;
    return list[Math.floor(rnd() * list.length)];
}

// 看着鼠标：不传 enabled（或传 null）即取反
export function setLookAtMouse(state, enabled) {
    state.lookAtMouse = (enabled === undefined || enabled === null) ? !state.lookAtMouse : !!enabled;
    return { ok: true, lookAtMouse: state.lookAtMouse };
}

export function setLookAtOpenCode(state, enabled) {
    state.lookAtOpenCode = (enabled === undefined || enabled === null) ? !state.lookAtOpenCode : !!enabled;
    return { ok: true, lookAtOpenCode: state.lookAtOpenCode };
}

// working 细分阶段：thinking（模型在想）/ tool（在跑工具）
export function setWorkPhase(state, phase) {
    state.workPhase = (phase === "tool" || phase === "thinking") ? phase : null;
    return state.workPhase;
}

// 按别名挑一个配置里真实存在的动画名；都不存在返回 null
export function resolveAnimAlias(kind, config) {
    const list = ANIM_ALIASES[kind];
    if (!list) return null;
    const anims = (config && config.animations) || {};
    for (const name of list) {
        if (anims[name]) return name;
    }
    return null;
}

// 把用户的聊天内容包成给 opencode 的提示词（人设 + 用户原话）
export function buildChatPrompt(text, config) {
    const chat = (config && config.chat) || {};
    const name = String((config && config.name) || DEFAULT_CONFIG.name);
    const persona = String(chat.persona || DEFAULT_CHAT_PERSONA).replace(/\{name\}/g, name);
    return persona + "\n\n用户说：" + String(text == null ? "" : text);
}

// 气泡只放得下摘要：压缩空白 + 超长截断加省略号
export function truncateForBubble(text, max) {
    const limit = Number(max) > 0 ? Math.floor(Number(max)) : BUBBLE_TEXT_MAX;
    const s = String(text == null ? "" : text).replace(/\s+/g, " ").trim();
    if (s.length <= limit) return s;
    return s.slice(0, Math.max(1, limit - 1)) + "…";
}

// 聊天输入校验：返回 { ok, text } 或 { ok:false, error }
export function normalizeChatText(text, config) {
    const chat = (config && config.chat) || {};
    const maxChars = Number(chat.maxChars) > 0 ? Math.floor(Number(chat.maxChars)) : DEFAULT_CONFIG.chat.maxChars;
    const value = String(text == null ? "" : text).trim();
    if (!value) return { ok: false, error: "text is required" };
    if (value.length > maxChars) return { ok: false, error: "消息太长（最多 " + maxChars + " 字）" };
    return { ok: true, text: value };
}
