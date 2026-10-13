const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const {
  CodexReader,
  buildStats,
  normalizeWindow,
  normalizeUsage,
  bestCategory,
  scoreContext,
  emptyScores,
} = require("../src/core/codex-reader");
const { OneDriveSync, slug } = require("../src/core/onedrive-sync");
const { payloadToEvents } = require("../src/core/codex-app-server");

test("normalizes quota windows and token usage", () => {
  assert.deepEqual(
    normalizeWindow({
      used_percent: 28,
      window_minutes: 10080,
      resets_at: 1_800_000_000,
    }),
    {
      usedPercent: 28,
      remainingPercent: 72,
      windowMinutes: 10080,
      resetsAt: new Date(1_800_000_000_000).toISOString(),
    },
  );
  const usage = normalizeUsage({
    total_token_usage: {
      total_tokens: 300,
      input_tokens: 200,
      cached_input_tokens: 90,
      output_tokens: 100,
    },
    last_token_usage: {
      total_tokens: 120,
      input_tokens: 80,
      cached_input_tokens: 30,
      output_tokens: 40,
    },
  });
  assert.equal(usage.totalTokens, 300);
  assert.equal(usage.lastTotalTokens, 120);
  assert.equal(usage.lastCachedInputTokens, 30);
  assert.equal(usage.lastOutputTokens, 40);
});

test("classifies a turn using the same weighted context rules as macOS", () => {
  const scores = emptyScores();
  scoreContext(
    '{"type":"user_message","message":"请用 apply_patch 修复这个 TypeScript bug"}',
    scores,
  );
  assert.equal(bestCategory(scores), "coding");

  const slides = emptyScores();
  scoreContext(
    '{"role":"user","content":"生成一个 PowerPoint slide deck"}',
    slides,
  );
  assert.equal(bestCategory(slides), "presentation");
});

test("parses Codex JSONL, selects the 7-day window, and aggregates usage", async (context) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "suanli-reader-"));
  context.after(() => fs.rm(root, { recursive: true, force: true }));
  const sessions = path.join(root, "sessions", "2026", "07", "14");
  await fs.mkdir(sessions, { recursive: true });
  const now = new Date();
  const timestamp1 = new Date(now.getTime() - 60_000).toISOString();
  const timestamp2 = new Date(now.getTime() - 30_000).toISOString();
  const quota = {
    limit_id: "codex",
    primary: {
      used_percent: 10,
      window_minutes: 300,
      resets_at: now.getTime() / 1000 + 3600,
    },
    secondary: {
      used_percent: 25,
      window_minutes: 10080,
      resets_at: now.getTime() / 1000 + 200_000,
    },
  };
  const lines = [
    JSON.stringify({
      type: "session_meta",
      payload: { cwd: "C:\\work\\dashboard" },
    }),
    JSON.stringify({
      type: "user_message",
      role: "user",
      message: "请用 apply_patch 修复 bug",
    }),
    JSON.stringify({
      timestamp: timestamp1,
      payload: {
        type: "token_count",
        info: {
          total_token_usage: { total_tokens: 100 },
          last_token_usage: {
            total_tokens: 100,
            input_tokens: 80,
            output_tokens: 20,
          },
        },
        rate_limits: quota,
      },
    }),
    JSON.stringify({
      type: "user_message",
      role: "user",
      message: "继续修改代码",
    }),
    JSON.stringify({
      timestamp: timestamp2,
      payload: {
        type: "token_count",
        info: {
          total_token_usage: { total_tokens: 250 },
          last_token_usage: {
            total_tokens: 150,
            input_tokens: 100,
            output_tokens: 50,
          },
        },
        rate_limits: quota,
      },
    }),
  ];
  await fs.writeFile(
    path.join(sessions, "rollout-test.jsonl"),
    `${lines.join("\n")}\n`,
  );

  const reader = new CodexReader({
    codexHome: root,
    sessionRoots: [path.join(root, "sessions")],
    liveReader: async () => [],
  });
  const result = await reader.read(now);
  assert.equal(result.scannedFiles, 1);
  assert.equal(result.eventCount, 2);
  assert.equal(result.weekly.windowMinutes, 10080);
  assert.equal(result.weekly.remainingPercent, 75);
  assert.equal(result.tokenStats.todayTokens, 250);
  assert.equal(result.tokenStats.sampleCount, 2);
  assert.equal(result.tokenStats.todayTopProjects[0].projectName, "dashboard");
  assert.equal(
    result.tokenStats.categoryBreakdown.find((row) => row.category === "coding")
      .totalTokens,
    250,
  );
});

test("deduplicates repeated cumulative samples from one session", () => {
  const now = new Date();
  const base = {
    timestamp: now.toISOString(),
    sourceName: "a.jsonl",
    sourcePath: "/a.jsonl",
    usageCategory: "other",
    projectName: "A",
    projectPath: "/A",
  };
  const firstUsage = {
    totalTokens: 500,
    lastTotalTokens: 100,
    lastInputTokens: 75,
    lastOutputTokens: 25,
    lastReasoningOutputTokens: 0,
  };
  const repeatedSnapshot = {
    totalTokens: 500,
    lastTotalTokens: 40,
    lastInputTokens: 30,
    lastOutputTokens: 10,
    lastReasoningOutputTokens: 0,
  };
  const stats = buildStats(
    [
      { ...base, usage: firstUsage },
      {
        ...base,
        timestamp: new Date(now.getTime() + 1000).toISOString(),
        usage: repeatedSnapshot,
      },
    ],
    now,
  );
  assert.equal(stats.sampleCount, 1);
  assert.equal(stats.todayTokens, 100);
});

test("creates a filesystem-safe Windows device id", () => {
  assert.equal(slug("Tilo 的 Windows PC.local"), "tilo-的-windows-pc");
});

test("maps the live Codex app-server quota response", () => {
  const events = payloadToEvents({
    rateLimits: {
      limitId: "codex",
      limitName: "Codex",
      planType: "pro",
      primary: {
        usedPercent: 12,
        windowDurationMins: 300,
        resetsAt: 1_800_000_000,
      },
      secondary: {
        usedPercent: 35,
        windowDurationMins: 10080,
        resetsAt: 1_800_100_000,
      },
    },
  });
  assert.equal(events.length, 1);
  assert.equal(events[0].sourceName, "Codex app-server");
  assert.equal(events[0].secondary.remainingPercent, 65);
  assert.equal(events[0].secondary.windowMinutes, 10080);
});

test("writes and reads a privacy-safe OneDrive aggregate snapshot", async (context) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "suanli-onedrive-"));
  context.after(() => fs.rm(root, { recursive: true, force: true }));
  const sync = new OneDriveSync(root);
  const devices = await sync.persistAndRead({
    todayTokens: 120,
    monthTokens: 900,
    sampleCount: 4,
    daily: [],
    monthly: [],
    hourly: [],
  });
  assert.equal(devices.length, 1);
  assert.equal(devices[0].monthTokens, 900);
  assert.equal(devices[0].schemaVersion, 4);
  assert.deepEqual(devices[0].modelHourly, []);
  assert.equal("conversation" in devices[0], false);
  assert.equal("messages" in devices[0], false);
});
