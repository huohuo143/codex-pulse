const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { Runtime } = require("../src/core/runtime");
const { BackupArchive, MANIFEST } = require("../src/core/backup-archive");
const { SessionFileIndex } = require("../src/core/session-file-index");
const { CodexReader } = require("../src/core/codex-reader");

const now = new Date("2026-10-13T08:00:00Z");
function temp(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pulse-2122-core-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}
function runtime(t, root = temp(t), notify = async () => true) {
  const r = new Runtime(root, { notifications: true, dailyBackup: true }, { now: () => now.getTime(), notify, sessionRoots: [] });
  // These tests exercise only local records and never call the official source.
  r.publish = () => {};
  t.after(() => r.stop());
  return r;
}
const delivery = id => ({ id, body: "synthetic reminder", keys: [id] });

test("notification receipts restore per account across switches and restart", async t => {
  const root = temp(t), r = runtime(t, root);
  r.changeScope("account-a");
  r.deliverAlerts([delivery("a")]); await r.notificationBatch;
  r.changeScope("account-b"); assert.deepEqual(r.ledger, {});
  r.deliverAlerts([delivery("b")]); await r.notificationBatch;
  r.changeScope("account-a"); assert.deepEqual(r.ledger.sentKeys, ["a"]);
  const restored = runtime(t, root); restored.changeScope("account-b");
  assert.deepEqual(restored.ledger.sentKeys, ["b"]);
});
test("a late accepted receipt is saved to the old account without sending the next old reminder", async t => {
  let resolve, calls = 0;
  const r = runtime(t, temp(t), () => { calls++; return new Promise(done => { resolve = done; }); });
  r.changeScope("account-a");
  r.deliverAlerts([delivery("a"), delivery("never-submitted")]);
  r.changeScope("account-b");
  resolve(true); await r.notificationBatch;
  assert.equal(calls, 1); assert.deepEqual(r.ledger, {});
  assert.equal(r.store.read("alert-ledger-account-b", null), null);
  assert.deepEqual(r.store.read("alert-ledger-account-a", {}).sentKeys, ["a"]);
  r.changeScope("account-a"); assert.deepEqual(r.ledger.sentKeys, ["a"]);
});
test("a receipt returning after A to B to A merges current A records", async t => {
  let resolve;
  const r = runtime(t, temp(t), () => new Promise(done => { resolve = done; }));
  r.changeScope("account-a"); r.deliverAlerts([delivery("late")]);
  r.changeScope("account-b"); r.changeScope("account-a");
  r.persistAlertLedger("account-a", { sentKeys: ["existing"] });
  resolve(true); await r.notificationBatch;
  assert.deepEqual(r.ledger.sentKeys, ["existing", "late"]);
});
test("a late failed receipt cannot create retry state in the new account", async t => {
  let resolve;
  const r = runtime(t, temp(t), () => new Promise(done => { resolve = done; }));
  r.changeScope("account-a"); r.deliverAlerts([delivery("a")]); r.changeScope("account-b");
  resolve(false); await r.notificationBatch;
  assert.equal(r.notificationRetries.size, 0);
  assert.equal(r.store.read("alert-ledger-account-a", null), null);
});
test("a late forecast receipt preserves a newer cycle, cooldown, pending episode and current risk", async t => {
  let resolve;
  const r = runtime(t, temp(t), () => new Promise(done => { resolve = done; }));
  r.changeScope("account-a");
  r.persistAlertLedger("account-a", { sentKeys: [], lastRisk: "critical", forecastEpisode: 1 });
  r.deliverAlerts([{ id: "old-forecast", body: "old", forecastCycle: "old-cycle", episode: 1 }]);
  r.changeScope("account-b"); r.changeScope("account-a");
  const newer = { sentKeys: ["new"], lastRisk: "healthy", lastForecastCycle: "new-cycle", lastForecastCriticalAt: now.getTime() - 500, forecastPending: true, forecastEpisode: 2 };
  r.persistAlertLedger("account-a", newer);
  resolve(true); await r.notificationBatch;
  assert.deepEqual(r.ledger, newer);
  assert.deepEqual(r.store.read("alert-ledger-account-a", null), newer);
});
test("a late forecast receipt retains a recovered risk while recording the accepted cycle", async t => {
  let resolve;
  const r = runtime(t, temp(t), () => new Promise(done => { resolve = done; }));
  r.changeScope("account-a");
  r.persistAlertLedger("account-a", { sentKeys: [], lastRisk: "critical", forecastEpisode: 1 });
  r.deliverAlerts([{ id: "forecast", body: "risk", forecastCycle: "cycle", episode: 1 }]);
  r.changeScope("account-b"); r.changeScope("account-a");
  r.persistAlertLedger("account-a", { ...r.ledger, lastRisk: "healthy" });
  resolve(true); await r.notificationBatch;
  assert.equal(r.ledger.lastRisk, "healthy"); assert.equal(r.ledger.lastForecastCycle, "cycle");
});
test("accepted receipts survive a failed write in memory and retry against the original account", async t => {
  const r = runtime(t), write = r.store.write.bind(r.store);
  r.changeScope("account-a");
  r.store.write = (name, value) => { if (name.startsWith("alert-ledger-")) throw new Error("full disk"); return write(name, value); };
  r.deliverAlerts([delivery("a")]); await r.notificationBatch;
  r.changeScope("account-b"); r.changeScope("account-a");
  assert.deepEqual(r.ledger.sentKeys, ["a"]); assert.equal(r.pendingLedgerWrites.size, 1);
  r.changeScope("account-b"); r.store.write = write; r.maintenance();
  assert.equal(r.pendingLedgerWrites.size, 0); assert.deepEqual(r.ledger, {});
  assert.deepEqual(r.store.read("alert-ledger-account-a", {}).sentKeys, ["a"]);
});
test("legacy unscoped notification receipts remain untouched", t => {
  const r = runtime(t); r.store.write("alert-ledger", { sentKeys: ["legacy"] });
  r.changeScope("account-a"); assert.deepEqual(r.ledger, {});
  assert.deepEqual(r.store.read("alert-ledger", null), { sentKeys: ["legacy"] });
});
test("empty backups do not create a receipt and later sources become eligible", t => {
  const root = temp(t), archive = new BackupArchive(root), source = path.join(root, "quota-history-account-a.json");
  assert.equal(archive.backup([source], now).itemCount, 0);
  assert.equal(archive.hasBackup(now, [source]), false);
  assert.equal(fs.existsSync(path.join(archive.directory(now), MANIFEST)), false);
  fs.writeFileSync(source, "[]"); archive.backup([source], now);
  assert.equal(archive.hasBackup(now, [source]), true);
});
test("backups supplement later histories and different accounts in one day", t => {
  const root = temp(t), archive = new BackupArchive(root);
  const budget = path.join(root, "project-budgets-v1.json"), a = path.join(root, "quota-history-account-a.json"), b = path.join(root, "quota-history-account-b.json");
  fs.writeFileSync(budget, "[]"); archive.backup([budget, a], now);
  fs.writeFileSync(a, '[{"remainingPercent":70}]'); assert.equal(archive.hasBackup(now, [budget, a]), false);
  archive.backup([budget, a], now);
  fs.writeFileSync(b, '[{"remainingPercent":30}]'); archive.backup([budget, b], now);
  assert.equal(archive.hasBackup(now, [a, b, budget]), true);
  assert.equal(fs.readFileSync(path.join(archive.directory(now), path.basename(a)), "utf8"), fs.readFileSync(a, "utf8"));
});
test("backup completion is verified after restart and corrupted archives retry", t => {
  const root = temp(t), source = path.join(root, "project-budgets-v1.json"), archive = new BackupArchive(root);
  fs.writeFileSync(source, "[]"); archive.backup([source], now);
  const restarted = new BackupArchive(root); assert.equal(restarted.hasBackup(now, [source]), true);
  fs.writeFileSync(path.join(archive.directory(now), path.basename(source)), "corrupted");
  assert.equal(restarted.hasBackup(now, [source]), false);
  restarted.backup([source], now); assert.equal(restarted.hasBackup(now, [source]), true);
});
test("a failed or corrupted backup write has no completion receipt and can retry", t => {
  const root = temp(t), source = path.join(root, "project-budgets-v1.json"); fs.writeFileSync(source, "[]");
  let fail = true;
  const io = { ...fs, writeFileSync: (file, data, options) => fs.writeFileSync(file, fail ? "broken" : data, options) };
  const archive = new BackupArchive(root, { io });
  assert.throws(() => archive.backup([source], now), /完整性/);
  assert.equal(archive.hasBackup(now, [source]), false);
  assert.equal(fs.existsSync(path.join(archive.directory(now), MANIFEST)), false);
  fail = false; archive.backup([source], now); assert.equal(archive.hasBackup(now, [source]), true);
});
test("backup manifest rejects path traversal and duplicate basenames", t => {
  const root = temp(t), archive = new BackupArchive(root);
  fs.mkdirSync(archive.directory(now), { recursive: true });
  fs.writeFileSync(path.join(archive.directory(now), MANIFEST), JSON.stringify({ schemaVersion: 1, files: { "../outside.json": "a".repeat(64) } }));
  assert.equal(archive.hasBackup(now), false);
  const a = path.join(root, "a"), b = path.join(root, "b"); fs.mkdirSync(a); fs.mkdirSync(b);
  for (const dir of [a, b]) fs.writeFileSync(path.join(dir, "same.json"), "{}");
  assert.throws(() => archive.backup([path.join(a, "same.json"), path.join(b, "same.json")], now), /重复/);
});
test("automatic backup waits for account selection and keeps old daily files", t => {
  const root = temp(t), r = runtime(t, root); r.store.write("settings", { notifications: true });
  const old = path.join(root, "backups", "2026-10-01.json"); fs.mkdirSync(path.dirname(old)); fs.writeFileSync(old, "legacy");
  r.maintenance(); assert.equal(fs.existsSync(r.backupArchive.directory(now)), false);
  r.changeScope("account-a"); r.store.write("quota-history-account-a", [{ remainingPercent: 60 }]); r.maintenance();
  assert.equal(r.backupArchive.hasBackup(now, [r.store.file("quota-history-account-a")]), true);
  r.changeScope("account-b"); r.store.write("quota-history-account-b", [{ remainingPercent: 20 }]); r.maintenance();
  assert.equal(r.backupArchive.hasBackup(now, [r.store.file("quota-history-account-a"), r.store.file("quota-history-account-b")]), true);
  assert.equal(fs.readFileSync(old, "utf8"), "legacy");
});
test("automatic backups read only the selected application records", t => {
  const root = temp(t), r = runtime(t, root), marker = "SYNTHETIC_PRIVATE_AUTH_AND_CONVERSATION";
  r.changeScope("account-a"); r.store.write("settings", { notifications: true });
  r.store.write("quota-history-account-a", []);
  r.store.write("auth", { secret: marker });
  fs.writeFileSync(path.join(root, "session.jsonl"), marker);
  r.maintenance();
  const names = fs.readdirSync(r.backupArchive.directory(now)).sort();
  assert.deepEqual(names, [MANIFEST, "quota-history-account-a.json", "settings.json"].sort());
  for (const name of names) assert.equal(fs.readFileSync(path.join(r.backupArchive.directory(now), name), "utf8").includes(marker), false);
});
test("manual refresh reports unexpected failure while automatic refresh stays retryable", async t => {
  const r = runtime(t); r.official.read = async () => { throw new Error("synthetic failure"); };
  await assert.doesNotReject(() => r.refresh());
  await assert.rejects(() => r.refresh({ force: true }), /官方数据刷新失败/);
  assert.equal(r.refreshPromise, null); assert.equal(r.events.filter(e => e.level === "failure").length, 2);
});
test("budget save and explicit removal change memory only after persistence succeeds", t => {
  const r = runtime(t); r.state.tokenStats.monthTopProjects = [{ id: "p", projectName: "Project", projectPath: "C:\\p" }];
  r.setBudget({ id: "p", limit: 1000 });
  const original = r.budgets, write = r.store.write.bind(r.store);
  r.store.write = () => { throw new Error("read-only"); };
  assert.throws(() => r.setBudget({ id: "p", limit: 2000 }), /read-only/); assert.equal(r.budgets, original);
  assert.throws(() => r.setBudget({ id: "p", remove: true }), /read-only/); assert.equal(r.budgets, original);
  r.store.write = write;
  for (const limit of [0, -1, 1.5, NaN, Infinity, "1000", Number.MAX_SAFE_INTEGER + 1]) assert.throws(() => r.setBudget({ id: "p", limit }), /正整数/);
  r.setBudget({ id: "p", remove: true }); assert.deepEqual(r.budgets, []); assert.deepEqual(r.store.read("project-budgets-v1", null), []);
});
test("one changed file only stats that path and leaves historical entries intact", async t => {
  const root = temp(t);
  await Promise.all(Array.from({ length: 300 }, (_, i) => fsp.writeFile(path.join(root, `${i}.jsonl`), "{}\n")));
  const index = new SessionFileIndex([root]); await index.refresh();
  const untouched = index.entries.get(path.join(root, "1.jsonl")), checks = index.metrics.statChecks;
  fs.appendFileSync(path.join(root, "0.jsonl"), "{}\n"); index.markDirty(root, "0.jsonl"); await index.refresh();
  assert.equal(index.metrics.fullScans, 1); assert.equal(index.metrics.subtreeScans, 0);
  assert.equal(index.metrics.statChecks - checks, 1); assert.equal(index.entries.get(path.join(root, "1.jsonl")), untouched);
  assert.equal(index.entries.get(path.join(root, "0.jsonl")).size, 6);
  fs.unlinkSync(path.join(root, "0.jsonl")); index.markDirty(root, "0.jsonl"); await index.refresh(); assert.equal(index.files().length, 299);
});
test("directory rename and removal refresh just the affected subtree", async t => {
  const root = temp(t), old = path.join(root, "old"), next = path.join(root, "next");
  fs.mkdirSync(old); fs.writeFileSync(path.join(old, "a.jsonl"), "{}");
  const index = new SessionFileIndex([root]); await index.refresh();
  fs.renameSync(old, next); index.markDirty(root, "old"); index.markDirty(root, "next"); await index.refresh();
  assert.deepEqual(index.files().map(f => f.path), [path.join(next, "a.jsonl")]);
  assert.equal(index.metrics.fullScans, 1); assert.equal(index.metrics.subtreeScans, 1);
  fs.rmSync(next, { recursive: true }); index.markDirty(root, "next"); await index.refresh(); assert.deepEqual(index.files(), []);
});
test("unknown watcher filenames and out-of-root paths trigger reconciliation", async t => {
  const root = temp(t), index = new SessionFileIndex([root]); await index.refresh();
  fs.writeFileSync(path.join(root, "a.jsonl"), "{}"); index.markDirty(root, null); await index.refresh(); assert.equal(index.files().length, 1);
  index.markDirty(root, "../outside.jsonl"); await index.refresh(); assert.equal(index.metrics.fullScans, 3);
});
test("file events arriving during reconciliation remain queued for the next read", async t => {
  const root = temp(t); fs.writeFileSync(path.join(root, "a.jsonl"), "{}");
  let index, injected = false;
  const io = { ...fsp, readdir: async (...args) => { const rows = await fsp.readdir(...args); if (!injected) { injected = true; index.markDirty(root, "later.jsonl"); } return rows; } };
  index = new SessionFileIndex([root], { io }); await index.refresh();
  fs.writeFileSync(path.join(root, "later.jsonl"), "{}"); await index.refresh(); assert.equal(index.files().length, 2); assert.equal(index.metrics.fullScans, 1);
});
test("transient metadata failures preserve known records until reconciliation succeeds", async t => {
  const root = temp(t), file = path.join(root, "a.jsonl"); fs.writeFileSync(file, "{}");
  let fail = false;
  const io = { ...fsp, lstat: async name => { if (fail && name === file) { const error = new Error("busy"); error.code = "EBUSY"; throw error; } return fsp.lstat(name); } };
  const index = new SessionFileIndex([root], { io }); await index.refresh();
  const original = index.entries.get(file); fail = true; await index.refresh(true);
  assert.equal(index.entries.get(file), original); assert.equal(index.needsFull, true);
  fail = false; fs.appendFileSync(file, "{}"); await index.refresh(); assert.equal(index.entries.get(file).size, 4);
  fs.unlinkSync(file); await index.refresh(true); assert.equal(index.entries.size, 0);
});
test("a limited view retains overflow entries when a newer file is removed", async t => {
  const root = temp(t); fs.writeFileSync(path.join(root, "a.jsonl"), "{}"); fs.writeFileSync(path.join(root, "b.jsonl"), "{}");
  fs.utimesSync(path.join(root, "a.jsonl"), new Date(0), new Date(0));
  const index = new SessionFileIndex([root], { maxFiles: 1 }); await index.refresh(); assert.equal(path.basename(index.files()[0].path), "b.jsonl");
  fs.unlinkSync(path.join(root, "b.jsonl")); index.markDirty(root, "b.jsonl"); await index.refresh(); assert.equal(path.basename(index.files()[0].path), "a.jsonl");
});
test("reader incremental results match a fresh reader after append, create and delete", async t => {
  const root = temp(t), token = total => JSON.stringify({ timestamp: now.toISOString(), payload: { type: "token_count", info: { last_token_usage: { total_tokens: total, input_tokens: total }, total_token_usage: { total_tokens: total } } } }) + "\n";
  fs.writeFileSync(path.join(root, "a.jsonl"), token(10)); fs.writeFileSync(path.join(root, "b.jsonl"), token(20));
  const reader = new CodexReader({ sessionRoots: [root], liveReader: async () => [] });
  // A synthetic watcher keeps this test deterministic on every host OS.
  reader.watchers = [{ root, watcher: { close() {} } }]; t.after(() => reader.close());
  assert.equal((await reader.read(now)).tokenStats.todayTokens, 30);
  fs.appendFileSync(path.join(root, "a.jsonl"), token(30)); fs.unlinkSync(path.join(root, "b.jsonl")); fs.writeFileSync(path.join(root, "c.jsonl"), token(40));
  for (const name of ["a.jsonl", "b.jsonl", "c.jsonl"]) reader.fileIndex.markDirty(root, name);
  const actual = await reader.read(now), fresh = new CodexReader({ sessionRoots: [root], liveReader: async () => [] });
  t.after(() => fresh.close()); const expected = await fresh.read(now);
  assert.deepEqual(actual.tokenStats, expected.tokenStats); assert.equal(actual.eventCount, expected.eventCount); assert.equal(reader.fileIndex.metrics.fullScans, 1);
});
