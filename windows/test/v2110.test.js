const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const {
  freshness,
  succeed,
  fail,
  visible,
} = require("../src/core/data-freshness");
const pricing = require("../src/core/model-pricing");
const {
  forecast,
  recordSnapshot,
  alerts,
  commitAlert,
  analyze,
} = require("../src/core/analytics");
const { CodexReader, buildStats } = require("../src/core/codex-reader");
const {
  payloadToEvents,
  normalizeWindow,
} = require("../src/core/codex-app-server");
const { OfficialSource, accountScope } = require("../src/core/official-source");
const {
  score,
  lifetime,
  parsePage,
  RadarService,
  ptMidnight,
} = require("../src/core/radar-v2110");
const { Store } = require("../src/core/storage");
const { compare, UpdateService } = require("../src/core/update-service");
const {
  validatePatch,
  visibleBounds,
  migrateSettings,
} = require("../src/core/settings");
const { makeCSV } = require("../src/core/csv-exporter");
const now = Date.parse("2026-09-20T08:00:00Z");
const deliveredLedger = result => result.deliveries.reduce((ledger, item) => commitAlert(ledger, item, now), result.ledger);
async function temp(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "pulse-2118-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}
function event(timestamp, total = 1000, model = "gpt-5.6-sol") {
  return {
    timestamp: new Date(timestamp).toISOString(),
    sourcePath: "test",
    projectName: "测试",
    projectPath: "C:\\测试",
    model,
    usageCategory: "coding",
    usage: {
      totalTokens: total,
      lastTotalTokens: total,
      lastInputTokens: total * 0.8,
      lastCachedInputTokens: total * 0.2,
      lastOutputTokens: total * 0.2,
    },
  };
}
function line(total = 123, time = now) {
  return (
    JSON.stringify({
      timestamp: new Date(time).toISOString(),
      payload: {
        type: "token_count",
        info: {
          total_token_usage: { total_tokens: total },
          last_token_usage: {
            total_tokens: total,
            input_tokens: 100,
            cached_input_tokens: 25,
            output_tokens: 23,
          },
        },
      },
    }) + "\n"
  );
}
function page(posts = [], extra = {}) {
  return {
    updatedAt: new Date(now).toISOString(),
    headline: "待确认",
    summary: "公开信息",
    posts,
    ...extra,
  };
}
function post(text, time = now) {
  return {
    id: "12345",
    url: "https://x.com/thsottiaux/status/12345",
    publishedAt: new Date(time).toISOString(),
    originalText: text,
    isReply: false,
  };
}
function html(timestamp = now, text = "Hard reset within 24 hours") {
  return (
    '<section class="desktop-tibo-radar" data-tibo-posts-updated-at="' +
    new Date(timestamp).toISOString() +
    '" data-tibo-post-ids="12345"><li class="reset-tibo-post" data-tibo-post-id="12345"><a href="https://x.com/thsottiaux/status/12345">Post</a><time datetime="' +
    new Date(timestamp).toISOString() +
    '"></time><p class="reset-tibo-post-original">英文原文 ' +
    text +
    "</p></li></section>"
  );
}

test("freshness boundaries, failed refresh, official reset, and future timestamps", () => {
  const meta = succeed("official", now);
  assert.equal(freshness(meta, now + 300000), "fresh");
  assert.equal(freshness(meta, now + 300001), "cached");
  assert.equal(freshness(meta, now + 1800001), "expired");
  assert.equal(freshness(fail(meta, now + 1000), now + 1000), "cached");
  assert.equal(
    freshness(meta, now + 1, new Date(now).toISOString()),
    "waitingForReset",
  );
  assert.equal(freshness(succeed("official", now + 10000), now), "unavailable");
  assert.equal(visible(meta, now + 1800001), false);
  assert.equal(freshness({}, now), "unavailable");
});
test("writing a snapshot never extends sampled data freshness", () => {
  const meta = succeed("official", now, new Date(now - 1700000).toISOString());
  assert.equal(freshness(meta, now + 100001), "expired");
});
test("builtin pricing matches Astra Sol Terra Luna and excludes double-counted reasoning", () => {
  for (const [model, input, cached, output] of [
    ["gpt-6-astra", 10, 1, 50],
    ["gpt-5.6-sol", 4, 0.4, 20],
    ["gpt-5.6-terra", 2, 0.2, 12],
    ["gpt-5.6-luna", 0.2, 0.02, 1.2],
  ]) {
    const result = pricing.estimateCost([
      {
        model,
        inputTokens: 1000,
        cachedInputTokens: 200,
        outputTokens: 100,
        reasoningOutputTokens: 100,
        totalTokens: 1100,
      },
    ]);
    assert.ok(
      Math.abs(result.usd - (800 * input + 200 * cached + 100 * output) / 1e6) <
        1e-10,
    );
    assert.equal(result.coverage, 1);
  }
});
test("unknown and missing cache prices preserve partial/unavailable distinctions", () => {
  const unknown = pricing.estimateCost([
    { model: "future", totalTokens: 120, inputTokens: 100, outputTokens: 20 },
  ]);
  assert.equal(unknown.isUnavailable, true);
  const partial = pricing.estimateCost([
    {
      model: "gpt-5.4-pro",
      inputTokens: 100,
      cachedInputTokens: 50,
      outputTokens: 20,
      totalTokens: 120,
    },
  ]);
  assert.equal(partial.unpricedTokens, 50);
  assert.ok(Math.abs(partial.coverage - 70 / 120) < 1e-12);
  assert.equal(partial.isPartial, true);
  assert.equal(partial.isUnavailable, false);
});
test("price imports reject invalid, negative, conflicting models and leave active prices intact", () => {
  const original = pricing.version();
  const table = structuredClone(pricing.builtin);
  table.models[0].input = -1;
  assert.throws(() => pricing.setPriceTable(table));
  assert.equal(pricing.version(), original);
  table.models[0].input = NaN;
  assert.throws(() => pricing.validate(table));
  table.models[0].input = 10;
  table.models[0].aliases = ["gpt-5.4"];
  assert.throws(() => pricing.validate(table));
  table.models[0].aliases = [];
  table.models[0].sourceURL = "file:///x";
  assert.throws(() => pricing.validate(table));
});
test("price preview does not change prices and successful imports recalculate only money", () => {
  const table = structuredClone(pricing.builtin);
  table.models = table.models.filter((m) => m.model === "gpt-5.6-sol");
  table.models[0].input = 8;
  const before = pricing.version(),
    preview = pricing.preview(table);
  assert.equal(pricing.version(), before);
  assert.equal(preview.changes.length, 1);
  const rows = [event(now)];
  const a = buildStats(rows, new Date(now));
  pricing.setPriceTable(preview.table);
  try {
    const b = buildStats(rows, new Date(now));
    assert.equal(a.monthTokens, b.monthTokens);
    assert.ok(b.costMonth.usd > a.costMonth.usd);
  } finally {
    pricing.setPriceTable(null);
  }
});
test("seven-day costs and tokens use the same local calendar dates; rolling 24h excludes older events", () => {
  const n = new Date(2026, 8, 20, 12),
    first = new Date(2026, 8, 14, 0),
    old = new Date(2026, 8, 13, 23, 59);
  const stats = buildStats(
    [event(+first, 1000), event(+old, 2000), event(+n - 86400000 + 1, 3000)],
    n,
  );
  assert.equal(stats.last7DaysTokens, 4000);
  assert.equal(stats.cost7Days.pricedTokens, 4000);
  assert.equal(stats.rolling24HoursTokens, 3000);
  assert.equal(stats.daily.length, 30);
});
test("new API buckets take precedence over legacy, absent fields do not mean full quota", () => {
  const events = payloadToEvents({
    rateLimits: {
      limitId: "codex",
      primary: { usedPercent: 10, windowDurationMins: 10080 },
    },
    rateLimitsByLimitId: {
      codex: {
        limitId: "codex",
        primary: { usedPercent: 40, windowDurationMins: 10080 },
      },
    },
  });
  assert.equal(events[0].primary.remainingPercent, 60);
  assert.equal(normalizeWindow({ windowDurationMins: 10080 }), null);
  assert.equal(
    payloadToEvents({
      rateLimitsByLimitId: {
        codex: { primary: { usedPercent: 20, windowDurationMins: 300 } },
      },
    }).length,
    1,
  );
});
test("parser handles token usage without quota events, append, same-size replacement, truncate and malformed timestamp", async (t) => {
  const root = await temp(t),
    file = path.join(root, "a.jsonl");
  const reader = new CodexReader({
    sessionRoots: [root],
    liveReader: async () => [],
  });
  t.after(() => reader.close());
  await fs.writeFile(file, line());
  assert.equal((await reader.read(new Date(now))).eventCount, 1);
  await fs.appendFile(file, line(246));
  assert.equal((await reader.read(new Date(now))).eventCount, 2);
  await fs.writeFile(file, line(321) + line(654));
  const replaced = await reader.read(new Date(now));
  assert.equal(replaced.tokenStats.monthTokens, 975);
  await fs.writeFile(file, line(123));
  assert.equal((await reader.read(new Date(now))).eventCount, 1);
  await fs.appendFile(
    file,
    '{"timestamp":"invalid","payload":{"type":"token_count"}}\n',
  );
  assert.equal((await reader.read(new Date(now))).eventCount, 1);
});
test("streaming parser preserves split UTF-8 and incomplete trailing JSON across restart", async (t) => {
  const root = await temp(t),
    file = path.join(root, "a.jsonl"),
    cachePath = path.join(root, "cache.json");
  const text =
      JSON.stringify({
        type: "turn_context",
        payload: { cwd: "C:\\测试项目", model: "gpt-5.6-sol" },
      }) +
      "\n" +
      line(),
    bytes = Buffer.from(text),
    cut = bytes.indexOf(Buffer.from("测")) + 1;
  await fs.writeFile(file, bytes.subarray(0, cut));
  const r1 = new CodexReader({
    sessionRoots: [root],
    cachePath,
    liveReader: async () => [],
  });
  assert.equal((await r1.read(new Date(now))).eventCount, 0);
  await fs.appendFile(file, bytes.subarray(cut));
  const r2 = new CodexReader({
    sessionRoots: [root],
    cachePath,
    liveReader: async () => [],
  });
  const result = await r2.read(new Date(now));
  assert.equal(result.tokenStats.recentUsageEvents[0].projectName, "测试项目");
  assert.equal(result.tokenStats.monthTokens, 123);
});
test("no file changes means no parsing or repeated analysis before the next time boundary", async (t) => {
  const root = await temp(t);
  await fs.writeFile(path.join(root, "a.jsonl"), line());
  const reader = new CodexReader({
    sessionRoots: [root],
    liveReader: async () => [],
  });
  const first = await reader.read(new Date(now));
  const second = await reader.read(new Date(now + 100000));
  assert.deepEqual(second.metrics, first.metrics);
});
test("forecast requires sufficient samples and segments upward corrections", () => {
  const reset = new Date(now + 24 * 3600000).toISOString();
  const rows = Array.from({ length: 7 }, (_, i) => ({
    recordedAt: new Date(now - (6 - i) * 3600000).toISOString(),
    remainingPercent: 60 - i * 5,
    resetsAt: reset,
    windowMinutes: 10080,
  }));
  const f = forecast(rows, rows.at(-1), now);
  assert.equal(f.risk, "critical");
  assert.equal(f.ratePerHour, 5);
  assert.equal(f.confidence, "medium");
  assert.equal(f.sampleCount, 7);
  assert.equal(
    forecast(rows.slice(-3), rows.at(-1), now).risk,
    "insufficientData",
  );
  const correction = {
    ...rows.at(-1),
    recordedAt: new Date(now + 1000).toISOString(),
    remainingPercent: 50,
  };
  assert.equal(
    forecast([...rows, correction], correction, now + 1000).risk,
    "insufficientData",
  );
});
test("quota history deduplicates within five minutes and respects reset cycles", () => {
  const w = {
    remainingPercent: 60,
    resetsAt: new Date(now + 86400000).toISOString(),
    windowMinutes: 10080,
  };
  const first = recordSnapshot([], w, new Date(now).toISOString(), now);
  assert.equal(first.length, 1);
  assert.strictEqual(
    recordSnapshot(first, w, new Date(now + 1000).toISOString(), now + 1000),
    first,
  );
  assert.equal(
    recordSnapshot(
      first,
      { ...w, remainingPercent: 59 },
      new Date(now + 2000).toISOString(),
      now + 2000,
    ).length,
    2,
  );
});
test("alerts select the most urgent threshold, deduplicate, reset cycles, and suppress stale data", () => {
  const weekly = {
      remainingPercent: 4,
      resetsAt: new Date(now + 86400000).toISOString(),
    },
    settings = { notifications: true, alertPreset: "standard" };
  const a = alerts({ weekly, settings, now });
  assert.equal(a.candidates.length, 1);
  assert.match(a.candidates[0], /5%/);
  assert.equal(
    alerts({ weekly, settings, ledger: deliveredLedger(a), now: now + 1000 }).candidates
      .length,
    0,
  );
  assert.equal(
    alerts({ weekly, settings, now, fresh: false }).candidates.length,
    0,
  );
  assert.equal(
    alerts({
      weekly: {
        ...weekly,
        resetsAt: new Date(now + 2 * 86400000).toISOString(),
      },
      settings,
      ledger: deliveredLedger(a),
      now,
    }).candidates.length,
    1,
  );
});
test("forecast alert cooldown and credit expiry notifications match baseline", () => {
  const settings = { notifications: true },
    prediction = { risk: "critical", reason: "risk" },
    weekly = {
      remainingPercent: 80,
      resetsAt: new Date(now + 86400000).toISOString(),
    };
  const a = alerts({ weekly, forecast: prediction, settings, now });
  assert.equal(a.candidates.length, 1);
  assert.equal(
    alerts({
      weekly,
      forecast: prediction,
      settings,
      ledger: deliveredLedger(a),
      now: now + 3600000,
    }).candidates.length,
    0,
  );
  assert.equal(
    alerts({
      weekly,
      forecast: prediction,
      settings,
      ledger: deliveredLedger(a),
      now: now + 6 * 3600000,
    }).candidates.length,
    1,
  );
  const credits = {
    availableCredits: [
      {
        title: "Full reset",
        grantedAt: new Date(now - 86400000).toISOString(),
        expiresAt: new Date(now + 10000).toISOString(),
      },
    ],
  };
  const b = alerts({ credits, settings, now });
  assert.equal(b.candidates.length, 1);
  assert.equal(
    alerts({ credits, settings, ledger: deliveredLedger(b), now }).candidates.length,
    0,
  );
});
test("analysis detects robust anomalies and project budget overflow", () => {
  const stats = buildStats([], new Date(now));
  stats.daily = Array.from({ length: 14 }, (_, i) => ({
    key: String(i),
    label: String(i),
    totalTokens: i === 13 ? 100000 : 20000,
  }));
  stats.monthTokens = 300000;
  stats.monthTopProjects = [{ id: "p", projectName: "p", totalTokens: 90000 }];
  const a = analyze(
    stats,
    [{ id: "p", monthlyTokenLimit: 80000 }],
    new Date(now),
  );
  assert.equal(a.anomalies.length, 1);
  assert.equal(a.projectBudgets[0].risk, "overBudget");
  assert.equal(a.projectBudgets[0].remainingTokens, 0);
  assert.ok(a.sevenDayChangePercent > 25);
});
test("radar excludes BANKED reset and standalone product launches, decays evidence, caps at 95%", () => {
  assert.equal(
    score(page([post("BANKED reset: hard reset tomorrow")]), now)
      .probability24hPercent,
    0,
  );
  assert.equal(
    score(
      page([post("Tomorrow we ship again, intelligence too cheap to meter")]),
      now,
    ).probability24hPercent,
    0,
  );
  assert.equal(
    score(page([post("Hard reset within 24 hours")]), now)
      .probability24hPercent,
    65,
  );
  assert.equal(
    score(page([post("Hard reset within 24 hours", now - 86400000)]), now)
      .probability24hPercent,
    0,
  );
  assert.equal(
    score(
      page([post("Hard reset within 24 hours")], { eventStatus: "confirmed" }),
      now,
    ).probability24hPercent,
    95,
  );
});
test("radar tomorrow signals expire at Pacific target-day end including DST", () => {
  const posted = Date.parse("2026-03-07T20:00:00Z"),
    p = post("hard reset tomorrow", posted);
  assert.equal(ptMidnight(2026, 3, 8), Date.parse("2026-03-08T08:00:00Z"));
  assert.equal(ptMidnight(2026, 3, 9), Date.parse("2026-03-09T07:00:00Z"));
  assert.equal(lifetime(p, Date.parse("2026-03-09T07:00:00Z"), true), 0);
  assert.ok(lifetime(p, Date.parse("2026-03-08T19:30:00Z"), true) > 0.49);
});
test("radar validates public source links and rejects incomplete advertised feeds", () => {
  assert.equal(parsePage(html()).posts.length, 1);
  assert.throws(() =>
    parsePage(html().replace("x.com/thsottiaux", "evil.test/thsottiaux")),
  );
  assert.throws(() =>
    parsePage(
      html().replace(
        'data-tibo-post-ids="12345"',
        'data-tibo-post-ids="12345,999"',
      ),
    ),
  );
});
test("radar failure backoff retains real success timestamp, expires at 90m and records no synthetic history", async (t) => {
  let clock = now,
    fail = false,
    calls = 0;
  const store = new Store(await temp(t));
  const service = new RadarService({
    store,
    now: () => clock,
    fetcher: async () => {
      calls++;
      if (fail) throw new Error("offline");
      return { ok: true, text: async () => html() };
    },
  });
  await service.current();
  assert.equal(service.archive.length, 1);
  const success = service.lastSuccessAt;
  clock += 300000;
  service.snapshot();
  assert.equal(service.archive.length, 2);
  assert.equal(service.lastSuccessAt, success);
  fail = true;
  clock += 1800000;
  await service.current();
  const before = calls;
  await service.current();
  assert.equal(calls, before);
  clock = now + 5400001;
  assert.equal(service.snapshot().prediction.probability24h, null);
  assert.equal(service.lastSuccessAt, success);
  assert.equal(service.archive.length, 3);
});
test("Brier score includes only ended verified windows; unknown is not false", async (t) => {
  let clock = now;
  const service = new RadarService({
    store: new Store(await temp(t)),
    now: () => clock,
    fetcher: async () => ({ ok: true, text: async () => html() }),
  });
  await service.current();
  const id = service.archive[0].id;
  assert.throws(() =>
    service.mark({ id, outcome: true, source: "Official source" }),
  );
  clock += 86400001;
  assert.equal(service.evaluation().n, 0);
  service.mark({ id, outcome: true, source: "Official source" });
  assert.equal(service.evaluation().n, 1);
  assert.ok(Math.abs(service.evaluation().brier - 0.35 ** 2) < 1e-10);
});
test("account switches clear official cached balances and use anonymous scopes", async (t) => {
  const root = await temp(t);
  await fs.writeFile(
    path.join(root, "auth.json"),
    JSON.stringify({ tokens: { account_id: "first-account" } }),
  );
  const first = await accountScope(root);
  assert.ok(first && !first.includes("first"));
  let broken = false;
  const credits = {
    summary: null,
    cachedAt: Date.now(),
    failedUntil: 0,
    current: async () => null,
  };
  const source = new OfficialSource({
    home: root,
    credits,
    fetchLive: async () => {
      if (broken) throw new Error("offline");
      return {
        rateLimits: {
          primary: {
            usedPercent: 10,
            windowDurationMins: 10080,
            resetsAt: Date.now() / 1000 + 86400,
          },
          credits: { hasCredits: true, balance: "250" },
        },
      };
    },
  });
  const a = await source.read();
  assert.equal(a.weekly.remainingPercent, 90);
  assert.equal(a.flexible.amountUSD, 10);
  await fs.writeFile(
    path.join(root, "auth.json"),
    JSON.stringify({ tokens: { account_id: "second-account" } }),
  );
  broken = true;
  const b = await source.read();
  assert.notEqual(a.accountScope, b.accountScope);
  assert.equal(b.weekly, null);
  assert.equal(b.flexible, null);
});
test("semantic versions, release asset filtering and 24h throttling", async (t) => {
  assert.equal(compare("v2.11.0", "2.9.0"), 1);
  assert.equal(compare("2.11.0-beta.2", "2.11.0-beta.10"), -1);
  assert.equal(compare("2.11.0-rc.1", "2.11.0"), -1);
  let calls = 0;
  const service = new UpdateService(new Store(await temp(t)), {
    version: "2.11.0",
    manifestEndpoint: null,
    now: () => now,
    fetcher: async () => {
      calls++;
      return {
        ok: true,
        json: async () => [
          {
            tag_name: "v2.12.0",
            assets: [
              {
                name: "Codex-Mac.dmg",
                browser_download_url: "https://example.com/app.dmg",
              },
            ],
          },
        ],
      };
    },
  });
  const a = await service.check();
  assert.equal(a.available, false);
  assert.match(a.message, /暂无 Windows/);
  await service.check();
  assert.equal(calls, 1);
  await service.check(true);
  assert.equal(calls, 2);
});
test("settings migrate preferences, validate inputs and return off-screen windows to a visible display", () => {
  const s = migrateSettings({
    palette: "peachSunset",
    refreshSeconds: 5,
    compact: true,
  });
  assert.equal(s.refreshSeconds, 5);
  assert.equal(s.floatingEnabled, true);
  assert.equal(s.compact, false);
  assert.equal(s.notifications, false);
  assert.throws(() => validatePatch({ refreshSeconds: NaN }));
  assert.throws(() => validatePatch({ bounds: { x: 0 } }));
  const b = visibleBounds(
    { x: 5000, y: 5000, width: 1000, height: 800 },
    [{ x: 0, y: 0, width: 1920, height: 1080 }],
    { width: 640, height: 760 },
  );
  assert.equal(b.x, 920);
  assert.equal(b.y, 280);
});
test("CSV protects spreadsheet formula cells and exposes pricing coverage without fabricated zero costs", () => {
  const stats = buildStats([event(now, 1000, "unknown")], new Date(now));
  stats.recentUsageEvents[0].projectName = '=HYPERLINK("x")';
  const csv = makeCSV(stats);
  assert.match(csv, /计价覆盖率/);
  assert.match(csv, /暂无法估算/);
  assert.match(csv, /'=HYPERLINK/);
});
