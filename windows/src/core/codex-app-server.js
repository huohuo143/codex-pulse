const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

function codexCandidates() {
  const home = process.env.USERPROFILE || process.env.HOME || "";
  const appData = process.env.APPDATA || "";
  const local = process.env.LOCALAPPDATA || "";
  const candidates = [
    process.env.CODEX_EXECUTABLE,
    appData && path.join(appData, "npm", "codex.cmd"),
    local && path.join(local, "Programs", "ChatGPT", "resources", "codex.exe"),
    local && path.join(local, "Programs", "Codex", "resources", "codex.exe"),
    process.platform === "darwin" &&
      "/Applications/ChatGPT.app/Contents/Resources/codex",
    process.platform === "darwin" &&
      "/Applications/Codex.app/Contents/Resources/codex",
    home &&
      path.join(
        home,
        ".npm-global",
        "bin",
        process.platform === "win32" ? "codex.cmd" : "codex",
      ),
  ].filter(Boolean);
  const codexBin = path.join(local, "OpenAI", "Codex", "bin");
  try {
    for (const folder of fs.readdirSync(codexBin))
      candidates.push(path.join(codexBin, folder, "codex.exe"));
  } catch {}
  for (const folder of (process.env.PATH || "").split(path.delimiter))
    candidates.push(
      path.join(folder, process.platform === "win32" ? "codex.exe" : "codex"),
    );
  return [
    ...new Set(
      candidates
        .filter((candidate) => fs.existsSync(candidate))
        .sort((a, b) => Number(/\.cmd$/i.test(a)) - Number(/\.cmd$/i.test(b))),
    ),
    "codex",
  ];
}

function normalizeWindow(window) {
  if (!window) return null;
  const usedValue = window.usedPercent ?? window.used_percent;
  if (usedValue == null || !Number.isFinite(Number(usedValue))) return null;
  const used = Math.max(0, Math.min(100, Number(usedValue)));
  return {
    usedPercent: used,
    remainingPercent: Math.max(0, Math.min(100, 100 - used)),
    windowMinutes: Number(
      window.windowDurationMins ?? window.window_minutes ?? 0,
    ),
    resetsAt:
      (window.resetsAt ?? window.resets_at)
        ? new Date(
            Number(window.resetsAt ?? window.resets_at) * 1000,
          ).toISOString()
        : null,
  };
}

function payloadToEvents(payload, now = new Date()) {
  if (!payload?.rateLimits && !payload?.rateLimitsByLimitId) return [];
  const snapshots = { ...(payload.rateLimitsByLimitId || {}) };
  const mainId = payload.rateLimits?.limitId || "codex";
  if (payload.rateLimits && !snapshots[mainId])
    snapshots[mainId] = payload.rateLimits;
  return Object.values(snapshots)
    .filter(Boolean)
    .map((snapshot) => ({
      timestamp: now.toISOString(),
      sourceName: "Codex app-server",
      sourcePath: "account/rateLimits/read",
      limitID: snapshot.limitId || mainId,
      limitName: snapshot.limitName || "Codex 默认额度",
      planType: snapshot.planType || null,
      primary: normalizeWindow(snapshot.primary),
      secondary: normalizeWindow(snapshot.secondary),
      reachedType: snapshot.rateLimitReachedType || null,
      usage: emptyUsage(),
      usageCategory: "other",
      projectName: "实时额度",
      projectPath: "",
    }));
}

function emptyUsage() {
  return {
    totalTokens: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    reasoningOutputTokens: 0,
    lastTotalTokens: 0,
    lastInputTokens: 0,
    lastCachedInputTokens: 0,
    lastOutputTokens: 0,
    lastReasoningOutputTokens: 0,
  };
}

async function fetchLiveRateLimits({ timeoutMs = 7000, raw = false } = {}) {
  let lastError;
  for (const command of codexCandidates()) {
    try {
      return await runClient(command, timeoutMs, raw);
    } catch (error) {
      lastError = error;
      if (command === "codex") break;
    }
  }
  throw lastError || new Error("未找到 Codex 命令");
}

function runClient(command, timeoutMs, raw = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, ["app-server", "--listen", "stdio://"], {
      windowsHide: true,
      cwd: require("node:os").homedir(),
      stdio: ["pipe", "pipe", "ignore"],
      shell: process.platform === "win32" && /\.cmd$/i.test(command),
    });
    const lines = readline.createInterface({ input: child.stdout });
    let settled = false;
    let initialized = false;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      lines.close();
      child.kill();
      if (error) reject(error);
      else resolve(value);
    };
    child.stdin.on("error", () => finish(new Error("Codex 连接已关闭")));
    const send = (value) => {
      if (!settled && child.stdin.writable)
        child.stdin.write(`${JSON.stringify(value)}\n`);
    };
    const timer = setTimeout(
      () => finish(new Error("Codex 实时额度读取超时")),
      timeoutMs,
    );

    child.once("error", (error) => finish(error));
    child.once("exit", (code) => {
      if (!settled)
        finish(new Error(`Codex app-server 已退出 (${code ?? "unknown"})`));
    });
    lines.on("line", (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      if (message.id === 1 && !initialized) {
        initialized = true;
        send({ jsonrpc: "2.0", method: "initialized" });
        send({ jsonrpc: "2.0", id: 2, method: "account/rateLimits/read" });
      } else if (message.id === 2) {
        if (message.error)
          finish(new Error(message.error.message || "额度接口返回错误"));
        else
          finish(null, raw ? message.result : payloadToEvents(message.result));
      }
    });
    send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "SuanliDashboardWindows", version: "1" } },
    });
  });
}

module.exports = {
  codexCandidates,
  fetchLiveRateLimits,
  normalizeWindow,
  payloadToEvents,
};
