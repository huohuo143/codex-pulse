const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const history = require("../src/core/quota-history");
const { alerts, commitAlert } = require("../src/core/analytics");
const { Runtime } = require("../src/core/runtime");
const { makeCSV, hourTimestamp } = require("../src/core/csv-exporter");
const { buildStats } = require("../src/core/codex-reader");
const expiry = require("../src/core/credit-expiry");
const { RadarService, parsePage, score } = require("../src/core/radar-v2110");
const { request, retryAfter } = require("../src/core/radar-http");
const { Store } = require("../src/core/storage");
const { UpdateService } = require("../src/core/update-service");
const now = Date.parse("2026-10-11T08:00:00Z"), H = 3600000;
function sample(at = now, percent = 60, reset = now + 48 * H) {
  return { recordedAt: new Date(at).toISOString(), remainingPercent: percent, resetsAt: new Date(reset).toISOString(), windowMinutes: 10080 };
}
function temp(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pulse-2120-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir;
}
function runtime(t, notify) {
  let clock = now;
  const r = new Runtime(temp(t), { notifications: true }, { now: () => clock, notify });
  r.changeScope("test-a");
  t.after(() => r.stop());
  return { r, advance: ms => { clock += ms; } };
}
const quota = sample(), plan = ledger => alerts({ weekly: { ...quota, remainingPercent: 4 }, settings: { notifications: true }, now, ledger });
test("history filters invalid, future, nonweekly and out-of-range samples, deduplicating by time", () => {
  const rows = history.points([sample(now - H), sample(now - H, 42), sample(now + 1), sample(now - 31 * 24 * H), { ...sample(), remainingPercent: 101 }, { ...sample(), windowMinutes: 300 }, { ...sample(), resetsAt: "invalid" }], 7, now);
  assert.equal(rows.length, 1); assert.equal(rows[0].remainingPercent, 42);
  assert.throws(() => history.points([], 2));
});
test("history breaks on cycle change, upward adjustment or gap over 90m, retaining boundary points", () => {
  const rows = history.points([sample(now - 5 * H, 80), sample(now - 4 * H, 75), sample(now - 3 * H, 76), sample(now - H, 70), sample(now, 60, now + 72 * H)], 1, now);
  assert.deepEqual(rows.map(r => r.segment), [0, 0, 1, 2, 3]);
});
test("history keeps exactly 90m connected and a 0.1-point adjustment within tolerance", () => {
  const rows = history.points([sample(now - 1.5 * H, 60), sample(now, 60.1)], 1, now);
  assert.deepEqual(rows.map(r => r.segment), [0, 0]);
});
test("history display sampling preserves endpoints and extrema; inspection and CSV use every sample", () => {
  const rows = Array.from({ length: 4000 }, (_, i) => ({ ...sample(now - (4000 - i) * 1000, i === 2500 ? 100 : i === 2800 ? 0 : 50), segment: 0 }));
  const display = history.displayPoints(rows);
  assert.ok(display.length < 1200); assert.equal(display[0], rows[0]); assert.equal(display.at(-1), rows.at(-1));
  assert.ok(display.includes(rows[2500]) && display.includes(rows[2800]));
  assert.equal(history.nearestPoint(rows, Date.parse(rows[999].recordedAt)), rows[999]);
  assert.equal(history.makeCSV(rows).split("\r\n").length, 4005);
  assert.ok(!history.makeCSV([{ ...rows[0], accountScope: "secret", projectPath: "private" }]).includes("secret"));
});
test("usage CSV exports full UTC hours, keeps unknown hour keys and device calendar dates", () => {
  const stats = buildStats([], new Date(now));
  stats.hourly = [{ key: String(Date.parse("2025-12-31T23:00:00Z") / H), totalTokens: 123 }, { key: "unknown-hour", totalTokens: 9 }];
  stats.daily = [{ key: "2026-01-01", totalTokens: 200 }];
  stats.devices = [{ deviceID: "same", deviceName: "old", updatedAt: "2026-01-01T00:00:00Z", daily: [] },
    { deviceID: "same", deviceName: "=SUM(1)", updatedAt: "2026-01-02T00:00:00Z", todayTokens: 888, daily: [{ key: "2025-12-31", totalTokens: 555 }] }];
  const csv = makeCSV(stats);
  assert.match(csv, /2025-12-31T23:00:00.000Z/); assert.match(csv, /\r\n,unknown-hour,9/); assert.match(csv, /2026-01-01,200/);
  assert.match(csv, /'=SUM\(1\),same,2025-12-31,555/); assert.ok(!csv.includes("old,same")); assert.match(csv, /不能叠加回本机总量/);
  assert.equal(hourTimestamp(""), ""); assert.equal(hourTimestamp("2026-01-01T00:00:00Z"), "2026-01-01T00:00:00.000Z");
});
test("alert planning never records success until a delivery is committed", () => {
  const p = plan({}); assert.equal(p.ledger.sentKeys.length, 0); assert.equal(plan(p.ledger).candidates.length, 1);
  assert.equal(plan(commitAlert(p.ledger, p.deliveries[0], now)).candidates.length, 0);
});
test("failed alert delivery retries after 60s and overlapping batches never double-send", async t => {
  let calls = 0, resolve;
  const { r, advance } = runtime(t, () => { calls++; return new Promise(done => { resolve = done; }); });
  r.deliverAlerts(plan({}).deliveries); r.deliverAlerts(plan({}).deliveries); assert.equal(calls, 1);
  resolve(false); await r.notificationBatch; assert.deepEqual(r.ledger.sentKeys || [], []);
  advance(59999); r.deliverAlerts(plan({}).deliveries); assert.equal(calls, 1);
  advance(1); r.deliverAlerts(plan({}).deliveries); assert.equal(calls, 2);
  resolve(true); await r.notificationBatch; assert.equal(plan(r.ledger).candidates.length, 0);
});
test("partial notification success commits only accepted items", async t => {
  let calls = 0; const { r } = runtime(t, async () => ++calls === 1);
  r.deliverAlerts([{ id: "a", body: "a", keys: ["a"] }, { id: "b", body: "b", keys: ["b"] }]);
  await r.notificationBatch; assert.deepEqual(r.ledger.sentKeys, ["a"]); assert.ok(r.notificationRetries.has("b"));
});
test("account switch discards old notification batch results and clears visible history", async t => {
  let resolve; const { r } = runtime(t, () => new Promise(done => { resolve = done; }));
  r.history = [sample()]; r.state.quotaHistory = [sample()]; r.state.forecast = { risk: "critical" };
  r.deliverAlerts(plan({}).deliveries); r.changeScope("test-b");
  assert.deepEqual(r.state.quotaHistory, []); assert.equal(r.state.forecast, null);
  resolve(true); await r.notificationBatch; assert.deepEqual(r.ledger, {});
  assert.equal(r.store.read("alert-ledger-test-b", null), null);
});
test("forecast re-entry remains retryable after a failed delivery within the previous cooldown", () => {
  const args = { weekly: quota, settings: { notifications: true }, fresh: true, now };
  const first = alerts({ ...args, forecast: { risk: "critical", reason: "risk" } });
  let ledger = commitAlert(first.ledger, first.deliveries[0], now);
  ledger = alerts({ ...args, ledger, forecast: { risk: "healthy" } }).ledger;
  const again = alerts({ ...args, ledger, forecast: { risk: "critical", reason: "risk" }, now: now + 1000 });
  assert.equal(again.candidates.length, 1);
  assert.equal(alerts({ ...args, ledger: again.ledger, forecast: { risk: "critical" }, now: now + 61000 }).candidates.length, 1);
});
test("credit batches validate actual calendar dates and isolate records across accounts", () => {
  const value = { credits: 1000, grantedOn: "2026-10-01", expiresOn: "2026-12-01", evidence: "官方记录截图", kind: "confirmed" };
  let rows = expiry.save([], value, "a"); rows = expiry.save(rows, { ...value, kind: "estimated" }, "b");
  assert.equal(expiry.forAccount(rows, "b").length, 1);
  assert.throws(() => expiry.save(rows, { ...value, expiresOn: "2026-02-30" }, "a"));
  assert.throws(() => expiry.save(rows, { id: rows[0].id, remove: true }, "b"));
  assert.equal(expiry.save(rows, { id: rows[0].id, remove: true }, "a").length, 1);
});
function html() { return `<section data-tibo-posts-updated-at="${new Date(now).toISOString()}" data-tibo-post-ids="123" class='extra desktop-tibo-radar other'><li data-tibo-post-id='123' class='reset-tibo-post'><a href='https://x.com/thsottiaux/status/123'>原帖</a><time datetime='${new Date(now - H).toISOString()}'></time><p class='extra reset-tibo-post-original other'>Hello world</p></li></section><section id='tibo-challenge'><article><h3>新进展</h3><p>hard reset tomorrow</p><a href='https://x.com/thsottiaux/status/456'>查看</a><time datetime='${new Date(now).toISOString()}'></time></article></section>`; }
test("upgrade ignores cached update offers older than the installed version", t => {
  const store = new Store(temp(t)); store.write("updates-v1", { version: "v2.11.3", available: true, url: "https://example.test", checkedAt: new Date(now).toISOString() });
  const updates = new UpdateService(store); assert.equal(updates.state.available, false); assert.equal(updates.state.url, null);
});
test("radar accepts quote/class variations and displays challenge summaries without scoring paraphrases", () => {
  const page = parsePage(html()); assert.equal(page.posts[0].id, "456"); assert.equal(page.posts[0].originalText, "");
  assert.equal(score(page, now).probability24hPercent, 0); assert.equal(page.posts[1].originalText, "Hello world");
});
test("radar retries transient failures within the same synchronization", async () => {
  let calls = 0;
  const service = new RadarService({ now: () => now, sleep: async () => {}, fetcher: async () => {
    if (++calls < 3) throw new Error("connection interrupted");
    return { ok: true, text: async () => html() };
  } });
  await service.current(); assert.equal(calls, 3); assert.equal(service.failures, 0); assert.equal(service.lastSuccessAt, now);
});
test("radar server Retry-After survives manual refresh, network recovery and restart", async t => {
  let clock = now, calls = 0; const store = new Store(temp(t));
  const options = { store, now: () => clock, fetcher: async () => { calls++; return { ok: false, status: 429, headers: { get: () => "120" } }; } };
  const service = new RadarService(options); await service.current(); service.networkRestored(); await service.current({ force: true });
  assert.equal(calls, 1); const restored = new RadarService(options); await restored.current({ force: true }); assert.equal(calls, 1);
  clock += 120000; await restored.current({ force: true }); assert.equal(calls, 2);
  assert.equal(retryAfter(new Date(now + H).toUTCString(), now), now + H);
});
test("radar timeout covers the body even when a source ignores cancellation", async () => {
  const begin = Date.now();
  await assert.rejects(request(async () => ({ ok: true, text: () => new Promise(() => {}) }), "https://example.test", { timeout: 30, attempts: 1 }), /超时/);
  assert.ok(Date.now() - begin < 500);
});
test("radar shows waiting data on cold failure and preserves backoff across restarts", async t => {
  let clock = now; const store = new Store(temp(t));
  const service = new RadarService({ store, now: () => clock, sleep: async () => {}, fetcher: async () => { throw new Error("offline"); } });
  await service.current(); assert.equal(service.snapshot().sourceState, "unavailable"); assert.equal(service.snapshot().latestLevelLabel, "等待数据");
  const restored = new RadarService({ store, now: () => clock }); assert.equal(restored.failures, 1); assert.equal(restored.nextFetchAt, now + 60000);
  clock += 1000; restored.networkRestored(); assert.equal(restored.nextFetchAt, clock);
});
