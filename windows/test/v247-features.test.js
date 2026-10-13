const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const {
  CodexReader,
  buildStats,
  selectSevenDayWindow,
  scoreContext,
  emptyScores,
  bestCategory,
  categoryFromProject,
} = require("../src/core/codex-reader");
const {
  RadarService,
  parseRadarPayload,
} = require("../src/core/radar-service");
const {
  normalizeSummary,
  decodeJWTAccountID,
} = require("../src/core/reset-credits");
const { makeCSV } = require("../src/core/csv-exporter");
const { OneDriveSync } = require("../src/core/onedrive-sync");

function usageEvent({
  timestamp,
  model = "gpt-5.4",
  total = 1000,
  input = 700,
  cached = 200,
  output = 300,
  category = "coding",
}) {
  return {
    timestamp,
    sourceName: "rollout.jsonl",
    sourcePath: "/rollout.jsonl",
    usageCategory: category,
    projectName: "App",
    projectPath: "C:\\work\\App",
    model,
    usage: {
      totalTokens: total,
      lastTotalTokens: total,
      lastInputTokens: input,
      lastCachedInputTokens: cached,
      lastOutputTokens: output,
      lastReasoningOutputTokens: 40,
    },
  };
}

test("2.4.7 classification covers the expanded categories and project fallback", () => {
  const cases = [
    ["请用 hyperframes 做视频分镜", "videoProduction"],
    ["用 DESeq2 做 RNA-seq 差异分析", "dataAnalysis"],
    ["查 ClinVar 和 gnomAD 频率", "lifeScience"],
    ["修改 website 的 HTML CSS", "webDevelopment"],
    ["诊断群晖 NAS 内网穿透", "systemOperations"],
    ["润色 Nature manuscript 并回复 reviewer", "manuscript"],
  ];
  for (const [message, expected] of cases) {
    const scores = emptyScores();
    scoreContext(`{"role":"user","content":"${message}"}`, scores);
    assert.equal(bestCategory(scores), expected);
  }
  assert.equal(categoryFromProject("D:\\84-Codex\\网站构建"), "webDevelopment");
  assert.equal(categoryFromProject("D:\\组学分析\\RNA-seq"), "dataAnalysis");
});

test("only a real seven-day window is exposed", () => {
  assert.equal(
    selectSevenDayWindow({
      primary: { windowMinutes: 300 },
      secondary: { windowMinutes: 60 },
    }),
    null,
  );
  assert.equal(
    selectSevenDayWindow({
      primary: { windowMinutes: 10_080, remainingPercent: 73 },
    }).remainingPercent,
    73,
  );
  assert.equal(
    selectSevenDayWindow({
      primary: { windowMinutes: 10_120, remainingPercent: 71 },
    }).remainingPercent,
    71,
  );
});

test("rolling 24h uses exact timestamps and official model pricing", () => {
  const now = new Date("2026-07-16T12:00:00Z");
  const events = [
    usageEvent({ timestamp: "2026-07-15T11:59:59Z", total: 1000 }),
    usageEvent({
      timestamp: "2026-07-15T12:00:01Z",
      total: 2000,
      input: 1400,
      cached: 400,
      output: 600,
    }),
    usageEvent({
      timestamp: "2026-07-16T11:00:00Z",
      total: 3000,
      model: "future-model",
      input: 2000,
      output: 1000,
    }),
    usageEvent({ timestamp: "2026-06-30T00:00:00Z", total: 999, cached: 999 }),
  ];
  const stats = buildStats(events, now);
  assert.equal(stats.rolling24HoursTokens, 5000);
  assert.equal(
    stats.modelHourly.reduce((sum, row) => sum + row.cachedInputTokens, 0),
    800,
  );
  assert.equal(stats.cost24Hours.isPartial, true);
  assert.equal(stats.cost24Hours.unpricedTokens, 3000);
  assert.deepEqual(stats.cost24Hours.unpricedModels, ["future-model"]);
  assert.ok(Math.abs(stats.cost24Hours.usd - 0.0116) < 1e-9);
});

test("official long-context pricing multipliers are applied above 272K input tokens", () => {
  const now = new Date("2026-07-16T12:00:00Z");
  const stats = buildStats(
    [
      usageEvent({
        timestamp: now.toISOString(),
        model: "gpt-5.4",
        total: 300_000,
        input: 280_000,
        cached: 80_000,
        output: 20_000,
      }),
    ],
    now,
  );

  // Input and cached input are 2x; output is 1.5x.
  assert.ok(Math.abs(stats.cost24Hours.usd - 1.49) < 1e-9);
});

test("incremental parser preserves an unfinished JSONL line across app restarts", async (context) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codex-v247-cache-"));
  context.after(() => fs.rm(root, { recursive: true, force: true }));
  const sessions = path.join(root, "sessions");
  await fs.mkdir(sessions);
  const file = path.join(sessions, "rollout.jsonl");
  const cachePath = path.join(root, "session-cache-v5.json");
  const token = JSON.stringify({
    timestamp: "2026-07-16T10:00:00Z",
    payload: {
      type: "token_count",
      info: {
        total_token_usage: { total_tokens: 123 },
        last_token_usage: {
          total_tokens: 123,
          input_tokens: 100,
          cached_input_tokens: 30,
          output_tokens: 23,
        },
      },
      rate_limits: {
        limit_id: "codex",
        primary: { used_percent: 10, window_minutes: 300 },
        secondary: { used_percent: 20, window_minutes: 10080 },
      },
    },
  });
  await fs.writeFile(
    file,
    `${JSON.stringify({ type: "turn_context", payload: { cwd: "C:\\work\\App", model: "gpt-5.4" } })}\n${token}`,
  );
  const first = new CodexReader({
    codexHome: root,
    sessionRoots: [sessions],
    cachePath,
    liveReader: async () => [],
  });
  assert.equal(
    (await first.read(new Date("2026-07-16T10:01:00Z"))).eventCount,
    0,
  );
  await fs.appendFile(file, "\n");
  const second = new CodexReader({
    codexHome: root,
    sessionRoots: [sessions],
    cachePath,
    liveReader: async () => [],
  });
  const result = await second.read(new Date("2026-07-16T10:01:00Z"));
  assert.equal(result.eventCount, 1);
  assert.equal(result.tokenStats.recentUsageEvents[0].model, "gpt-5.4");
  assert.equal(result.tokenStats.recentUsageEvents[0].cachedInputTokens, 30);
});

const dashboardFixture = {
  generatedAt: "2026-07-15T10:21:00.000Z",
  platforms: [
    {
      id: "codex",
      probability: 82,
      statusLabel: "高概率",
      updatedAt: "2026-07-15T10:21:00.000Z",
      summaryBlocks: [
        { text: "Tibo：900 万可能很快到达" },
        { text: "官方正在征询是否再次重置" },
      ],
    },
    { id: "claude", probability: 7, statusLabel: "冷却观察" },
  ],
  accountPosts: {
    codex: {
      handle: "@thsottiaux",
      text: "是否再次重置 Codex 额度？",
      publishedAt: "2026-07-15T05:59:46.000Z",
    },
  },
};

test("radar maps only Codex and Tibo public data", () => {
  const snapshot = parseRadarPayload(dashboardFixture);
  assert.equal(snapshot.prediction.probability24hPercent, 82);
  assert.equal(snapshot.prediction.levelLabel, "高概率");
  assert.match(snapshot.latestSummary, /900 万/);
  assert.equal(snapshot.tiboPresence.timezone, "America/Los_Angeles");
  assert.match(snapshot.tiboPresence.latestActivityZh, /Codex/);
});

test("older radar payload cannot overwrite a newer probability", async () => {
  const oldFixture = {
    service: "codex-reset-radar",
    monitored_at: "2026-07-13T22:08:00+08:00",
    prediction: {
      level: "low",
      probability_24h: 0.14,
      summary: "旧数据",
      updated_at: "2026-07-13T22:08:00+08:00",
    },
  };
  const sequence = [dashboardFixture, oldFixture];
  const service = new RadarService({
    cacheDuration: 0,
    fetcher: async () => ({
      ok: true,
      text: async () => JSON.stringify(sequence.shift()),
    }),
  });
  const first = await service.current();
  const second = await service.current({ force: true });
  assert.equal(first.prediction.probability24hPercent, 82);
  assert.equal(second.prediction.probability24hPercent, 82);
});

test("reset credits keep official count, sort expiry, and discard opaque ids", () => {
  const summary = normalizeSummary({
    available_count: 3,
    credits: [
      {
        id: "opaque-2",
        status: "AVAILABLE",
        granted_at: 1783890499,
        expires_at: 1786482499,
      },
      {
        id: "opaque-1",
        status: "available",
        granted_at: 1782935919,
        expires_at: 1785527919,
      },
    ],
  });
  assert.equal(summary.availableCount, 3);
  assert.equal(summary.availableCredits.length, 2);
  assert.equal(summary.missingDetailCount, 1);
  assert.ok(
    Date.parse(summary.availableCredits[0].expiresAt) <
      Date.parse(summary.availableCredits[1].expiresAt),
  );
  assert.equal("id" in summary.availableCredits[0], false);
  const payload = Buffer.from(
    JSON.stringify({
      "https://api.openai.com/auth": { chatgpt_account_id: "account-123" },
    }),
  ).toString("base64url");
  assert.equal(decodeJWTAccountID(`a.${payload}.c`), "account-123");
});

test("CSV exports summary, model, cache, categories, and safely quoted projects", () => {
  const now = new Date("2026-07-16T12:00:00Z");
  const stats = buildStats(
    [
      usageEvent({
        timestamp: now.toISOString(),
        total: 1200,
        input: 900,
        cached: 300,
        output: 300,
        category: "dataAnalysis",
      }),
    ],
    now,
  );
  stats.recentUsageEvents[0].projectName = '水稻,"BPH33"';
  const csv = makeCSV(stats, { cnyRate: 7.2, generatedAt: now });
  assert.match(csv, /滚动24小时,1200/);
  assert.match(csv, /gpt-5\.4,1200,900,300,300,1/);
  assert.match(csv, /数据\/\u7ec4学分析,1200,1/);
  assert.match(csv, /"水稻,""BPH33"""/);
});

test("OneDrive writes schema 4 v2 and reads legacy schema 2/3 without duplication", async (context) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codex-v247-onedrive-"));
  context.after(() => fs.rm(root, { recursive: true, force: true }));
  const directory = path.join(root, "算力码表", "设备统计");
  await fs.mkdir(directory, { recursive: true });
  await fs.writeFile(
    path.join(directory, "remote-codex.json"),
    JSON.stringify({
      schemaVersion: 3,
      app: "codex",
      deviceID: "remote",
      deviceName: "Remote PC",
      updatedAt: "2026-07-15T00:00:00Z",
      todayTokens: 20,
      monthTokens: 80,
      daily: [],
      monthly: [],
      hourly: [],
    }),
  );
  const sync = new OneDriveSync(root);
  const devices = await sync.persistAndRead({
    todayTokens: 120,
    monthTokens: 900,
    sampleCount: 4,
    daily: [],
    monthly: [],
    hourly: [],
    modelHourly: [{ hourKey: "1", model: "gpt-5.4", totalTokens: 120 }],
  });
  assert.equal(devices[0].deviceID, sync.deviceID);
  assert.equal(devices[0].schemaVersion, 4);
  assert.equal(devices[0].modelHourly.length, 1);
  assert.equal(
    devices.find((row) => row.deviceID === "remote").schemaVersion,
    3,
  );
  assert.ok(
    (await fs.readdir(directory)).includes(`${sync.deviceID}-codex-v2.json`),
  );
});
