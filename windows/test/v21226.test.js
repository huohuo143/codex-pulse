const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { zstdCompressSync } = require('node:zlib');
const tibo = require('../src/core/tibo-analysis');
const { RadarService, REFRESH_INTERVAL_MS } = require('../src/core/radar-announcements');
const { ResetCalendar, parsePage, completion, mergeEvents } = require('../src/core/reset-calendar');
const { clock } = require('../src/core/radar-display');
const { ProtectedRecord, validators, safeRead } = require('../src/core/protected-record');
const { Store } = require('../src/core/storage');
const { CodexReader } = require('../src/core/codex-reader');
const { parse: amount } = require('../src/core/credit-amount');
const arrival = Date.parse('2026-10-23T02:00:00Z'), DAY = 86400000;
const iso = at => new Date(at).toISOString();
const histories = () => [{ recordedAt: iso(arrival - 300000), remainingPercent: 5, resetsAt: iso(arrival + 5 * DAY), windowMinutes: 10080 }, { recordedAt: iso(arrival), remainingPercent: 100, resetsAt: iso(arrival + 7 * DAY + 1000), windowMinutes: 10080 }];
const post = { id: '2111111111111111111', url: 'https://x.com/thsottiaux/status/2111111111111111111', publishedAt: iso(arrival - 3600000), originalText: 'It is reset day today. Before 10am PST today.', isReply: false };
const result = () => ({ state: 'announced', kind: 'hard_reset', summaryZh: '明确预告，实际到账待确认', timingZh: '', evidenceIDs: [post.id], deadline: null, completionEvidenceID: null });
function snapshot(now = arrival + 600000) { return { lastSuccessAt: now, lastAttemptAt: now, refreshHealthy: true, analysis: tibo.validate(result(), [post], now), posts: [post] }; }
function temporary(t) { const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pulse-2153-')); t.after(() => fs.rmSync(root, { recursive: true, force: true })); return root; }

test('actual weekly refill ends announcement and countdown survives reload and the 24h boundary', () => {
  for (const age of [600000, 3600000, DAY - 1, DAY, DAY + 1]) {
    const now = arrival + age, data = tibo.presentation(snapshot(now), JSON.parse(JSON.stringify(histories())), now);
    assert.equal(data.latestLevelLabel, age < DAY ? '已完成重置' : '等待新预告');
    assert.equal(data.completionUntil, age < DAY ? iso(arrival + DAY) : null);
    assert.equal(data.deadline, null); assert.equal(data.localCompletion, true);
  }
});
test('near full accounts still recognize a new weekly reset', () => { const rows = histories(); rows[0].remainingPercent = 95; assert.equal(tibo.latestConfirmedAt(rows, arrival), iso(arrival)); });
for (const mode of ['correction', 'natural', 'noRefill', 'earlier', 'longGap', 'fiveHour', 'future', 'nan', 'badDate']) test('reset detection rejects ' + mode, () => {
  const rows = histories();
  if (mode === 'correction') rows[1].resetsAt = rows[0].resetsAt;
  if (mode === 'natural') rows[0].resetsAt = iso(arrival);
  if (mode === 'noRefill') rows[0].remainingPercent = 100;
  if (mode === 'earlier') rows[1].resetsAt = iso(arrival + 4 * DAY);
  if (mode === 'longGap') rows[0].recordedAt = iso(arrival - 3600000);
  if (mode === 'fiveHour') rows.forEach(r => r.windowMinutes = 300);
  if (mode === 'future') rows[1].recordedAt = iso(arrival + 1);
  if (mode === 'nan') rows[1].remainingPercent = NaN;
  if (mode === 'badDate') rows[1].resetsAt = 'invalid';
  assert.equal(tibo.latestConfirmedAt(rows, arrival), null);
});
test('new announcement supersedes local completion; reanalysis of an old post never does', () => {
  const now = arrival + 1200000, data = snapshot(now);
  data.posts = [{ ...post, publishedAt: iso(arrival + 600000) }];
  assert.equal(tibo.presentation(data, histories(), now).latestLevelLabel, '重置已预告');
  assert.equal(tibo.presentation(snapshot(now), histories(), now).latestLevelLabel, '已完成重置');
});
test('source/model failure preserves account arrival but never reports healthy refresh', () => {
  const now = arrival + 1200000, data = { ...snapshot(now), lastSuccessAt: now - DAY, refreshHealthy: false, analysisError: '模型失败', error: '离线' };
  const shown = tibo.presentation(data, histories(), now);
  assert.equal(shown.latestLevelLabel, '已完成重置'); assert.equal(shown.refreshHealthy, false); assert.equal(shown.completionUntil, iso(arrival + DAY));
});
test('later public confirmation never restarts account display; a next day cycle may replace it', () => {
  const now = arrival + 3600000, data = snapshot(now);
  data.analysis = { ...data.analysis, state: 'completed', completedAt: iso(now - 60000) };
  assert.equal(tibo.presentation(data, histories(), now).completionUntil, iso(arrival + DAY));
  data.analysis.completedAt = iso(arrival + DAY + 60000);
  assert.equal(tibo.presentation(data, histories(), arrival + DAY + 120000).localCompletion, false);
});
test('empty account history cannot reuse another account reset', () => { assert.equal(tibo.presentation(snapshot(), [], arrival + 600000).latestLevelLabel, '重置已预告'); });
test('model conclusions require real original evidence and exact source quotes', () => {
  for (const bad of [{ evidenceIDs: ['invented'] }, { evidenceIDs: [] }, { kind: 'none' }, { completionEvidenceID: post.id }, { deadline: { evidenceID: post.id, sourceQuote: 'invented PST', sourceTimeZone: 'PST', localDateTime: '2026-10-23T10:00:00' } }]) assert.throws(() => tibo.validate({ ...result(), ...bad }, [post], arrival));
  assert.throws(() => tibo.validate(result(), [{ ...post, originalText: '', publicSummaryZh: '摘要' }], arrival));
});
test('public completion timestamp comes from its source post across reanalysis', () => {
  const value = { ...result(), state: 'completed', completionEvidenceID: post.id, completedAt: iso(arrival) };
  assert.equal(tibo.validate(value, [post], arrival).completedAt, post.publishedAt);
  assert.equal(tibo.validate(value, [post], arrival + 60000).completedAt, post.publishedAt);
  assert.throws(() => tibo.validate({ ...value, completionEvidenceID: 'other' }, [post], arrival));
});
test('fixed PST differs from seasonal PT; ambiguous or skipped local time is rejected', () => {
  const d = { localDateTime: '2026-10-23T10:00:00', sourceTimeZone: 'PST' };
  assert.equal(iso(tibo.deadlineDate(d)), '2026-10-23T18:00:00.000Z');
  assert.equal(iso(tibo.deadlineDate({ ...d, sourceTimeZone: 'PT' })), '2026-10-23T17:00:00.000Z');
  for (const sourceTimeZone of ['CST', 'UTC+14:01', 'made/up']) assert.equal(tibo.deadlineDate({ ...d, sourceTimeZone }), null);
  for (const localDateTime of ['2026-11-01T01:30:00', '2026-03-08T02:30:00', '2026-02-30T10:00:00']) assert.equal(tibo.deadlineDate({ ...d, sourceTimeZone: 'PT', localDateTime }), null);
});
test('relative dates are grounded in source publication date, never refresh time', () => {
  const d = { localDateTime: '2026-10-22T10:00:00', sourceTimeZone: 'PST', evidenceID: post.id, sourceQuote: 'Before 10am PST today.' };
  // Published 2026-10-22 at 17:00 PST; a 10am deadline would predate publication.
  assert.equal(tibo.groundedDeadline(d, post), false);
  assert.equal(tibo.groundedDeadline({ ...d, localDateTime: '2026-10-23T10:00:00' }, post), false);
});
test('prompt is bounded, read-only and explicitly excludes instructions in untrusted posts', () => {
  const prompt = tibo.prompt([post], arrival);
  assert.ok(prompt.includes('不可信数据')); assert.ok(prompt.includes(post.id)); assert.ok(!prompt.includes('{{NOW}}'));
  assert.throws(() => tibo.prompt([{ ...post, originalText: 'x'.repeat(260000) }], arrival), /过多/);
});
test('countdown runs on the wall clock and an expired deadline does not invent completion', () => {
  const r = { latestLevelLabel: '已完成重置', completionUntil: iso(arrival + DAY) };
  assert.ok(clock(r, arrival + 1000).detail.includes('23:59:59'));
  assert.equal(clock(r, arrival + DAY).title, '等待新预告');
  assert.ok(clock({ latestLevelLabel: '重置已预告', deadline: { at: iso(arrival) } }, arrival + 1).detail.includes('等待确认'));
});
test('all manual, automatic, network and restart checks share ten-minute floor even after model failure', async t => {
  const store = new Store(temporary(t)); let now = arrival, calls = 0, analyses = 0;
  const html = `<section class="desktop-tibo-radar" data-tibo-posts-updated-at="${iso(arrival)}"><li class="reset-tibo-post" data-tibo-post-id="${post.id}"><a href="${post.url}">原帖</a><time datetime="${post.publishedAt}"></time><p class="reset-tibo-post-original">${post.originalText}</p></li></section>`;
  const options = { store, now: () => now, fetcher: async () => { calls++; return { ok: true, text: async () => html }; }, analyzer: async () => { analyses++; throw new Error('模型权限不足'); } };
  const radar = new RadarService(options);
  await Promise.all([radar.current({ force: true }), radar.current({ force: true })]);
  assert.equal(calls, 1); assert.equal(analyses, 1); assert.equal(radar.snapshot().refreshHealthy, false);
  radar.networkRestored(); await radar.current({ force: true });
  const restarted = new RadarService(options); await restarted.current({ force: true }); assert.equal(calls, 1);
  now += REFRESH_INTERVAL_MS; await restarted.current(); assert.equal(calls, 2);
});
test('calendar ships 33 offline records without faking online success and merges same-kind identities', t => {
  const calendar = new ResetCalendar(new Store(temporary(t))), state = calendar.snapshot();
  assert.equal(state.events.length, 33); assert.equal(state.lastSuccessAt, null); assert.ok(state.attribution.includes('CC BY'));
  const rows = mergeEvents([{ id: 'a', aliases: ['x:1'], kind: 'hardReset', day: '2026-10-01' }], [{ id: 'b', aliases: ['x:1'], kind: 'hardReset', day: '2026-10-02' }, { id: 'c', aliases: ['x:1'], kind: 'resetCard', day: '2026-10-02' }]);
  assert.equal(rows.length, 2); assert.ok(rows.some(r => r.day === '2026-10-02'));
});
test('calendar completion accepts confirmed Beijing dates, never assigns invented exact time', () => {
  const raw = { completion_observation: { event_id: 'done', status: 'completed', kind: 'direct_reset', confirmation_level: 'stationmaster_confirmed', occurred_on: '2026-10-23', timezone: 'Asia/Shanghai', time_precision: 'date', occurred_at: iso(arrival) } };
  assert.equal(completion(raw, arrival).occurredAt, null);
  raw.completion_observation.status = 'announced'; assert.equal(completion(raw, arrival), null);
});
test('calendar parses only confirmed challenge events and keeps monthly totals separate', () => {
  const html = '<section id="tibo-challenge"><article><span class="t28-event-type">已确认重置</span><h3>硬重置完成</h3><time datetime="2026-10-22T22:00:00Z"></time><p>官方确认</p><a href="https://x.com/thsottiaux/status/2111111111111111111">完成确认</a></article><article><h3>重置卡</h3><p>尚未确认完成</p></article></section><div data-month="2026-10"><span class="monthly-count-direct"><strong>4</strong></span><span class="monthly-count-card"><strong>2</strong></span></div>';
  const data = parsePage(html, arrival); assert.equal(data.events.length, 1); assert.equal(data.events[0].day, '2026-10-23'); assert.equal(data.monthlyTotals[0].hardResets, 4);
});
test('protected records preserve corruption and restore only a previous valid backup', t => {
  const file = path.join(temporary(t), 'history.json'), record = new ProtectedRecord(file, validators.history, []);
  record.write(histories().slice(0, 1)); record.write(histories()); fs.writeFileSync(file, '{broken');
  const broken = new ProtectedRecord(file, validators.history, []);
  assert.throws(() => broken.write([])); assert.equal(fs.readFileSync(file, 'utf8'), '{broken');
  broken.restore(); assert.equal(broken.value.length, 1);
  const saved = fs.readdirSync(path.dirname(file)).find(f => f.includes('.damaged-'));
  assert.equal(fs.readFileSync(path.join(path.dirname(file), saved), 'utf8'), '{broken');
});
test('unsupported main or backup versions cannot be downgraded or overwritten', t => {
  const file = path.join(temporary(t), 'history.json'); fs.writeFileSync(file, JSON.stringify({ schemaVersion: 100, rows: [] })); fs.writeFileSync(file + '.last-good', '[]');
  const r = new ProtectedRecord(file, validators.history, []); assert.throws(() => r.write([])); assert.throws(() => r.restore(), /不支持/);
  fs.writeFileSync(file, '[]'); fs.writeFileSync(file + '.last-good', JSON.stringify({ schemaVersion: 100 })); r.reload(); assert.throws(() => r.write([]));
});
test('external changes, missing main files with backups and unsafe files stop record writes', t => {
  const file = path.join(temporary(t), 'history.json'), r = new ProtectedRecord(file, validators.history, []); r.write([]); fs.writeFileSync(file, JSON.stringify(histories()));
  assert.throws(() => r.write([]), /外部修改/); assert.equal(r.health().state, 'warning');
  r.reload(); r.write([]); fs.unlinkSync(file);
  const missing = new ProtectedRecord(file, validators.history, []); assert.throws(() => missing.write([]), /缺失/);
  assert.throws(() => safeRead(path.dirname(file)), /普通文件/);
});
test('amount parsing validates grouping and preserves full edit precision', () => {
  assert.equal(amount('1,234.567890123'), 1234.567890123);
  for (const value of ['1,5', '2,00', '0', '-1', '1e5', '', 'Infinity', '1.2.3']) assert.throws(() => amount(value));
});
test('thread enrichment verifies exact source URL and original text and bounds the request budget', async t => {
  let calls = 0;
  const radar = new RadarService({ store: new Store(temporary(t)), auxiliary: true, now: () => arrival, fetcher: async url => { calls++; const id = url.split('/').at(-1); return { ok: true, text: async () => `URL Source: https://x.com/thsottiaux/status/${id}\nMarkdown Content:\nOriginal ${id}\nParent: reset day` }; } });
  const posts = Array.from({ length: 10 }, (_, i) => ({ ...post, id: String(i + 1), url: 'https://x.com/thsottiaux/status/' + (i + 1), originalText: 'Original ' + (i + 1) }));
  await radar.context(posts); assert.equal(calls, 3); assert.ok(posts[0].threadContext.includes('Parent'));
  radar.fetcher = async () => ({ ok: true, text: async () => 'URL Source: https://x.com/other/status/4\nMarkdown Content:\nOriginal 4' });
  await radar.context(posts.slice(3)); assert.equal(posts[3].threadContext, undefined);
  const changed = { ...posts[0], originalText: 'Changed original', threadContext: undefined }; await radar.context([changed]); assert.equal(changed.threadContext, undefined);
});
test('backup rejects unsafe sources and unsupported manifests before replacing existing files', t => {
  const { BackupArchive, MANIFEST } = require('../src/core/backup-archive');
  const root = temporary(t), file = path.join(root, 'settings.json'), archive = new BackupArchive(root), now = new Date(arrival);
  fs.writeFileSync(file, '{}'); archive.backup([file], now);
  const saved = fs.readFileSync(path.join(archive.directory(now), 'settings.json'));
  fs.writeFileSync(path.join(archive.directory(now), MANIFEST), JSON.stringify({ schemaVersion: 100, files: {} }));
  fs.writeFileSync(file, '{"changed":true}'); assert.throws(() => archive.backup([file], now));
  assert.deepEqual(fs.readFileSync(path.join(archive.directory(now), 'settings.json')), saved);
  assert.throws(() => archive.backup([root], now), /普通文件/);
});
test('upgrade backups verify selected records, preserve original settings and exclude auth/session contents', t => {
  const { backupBeforeUpgrade } = require('../src/core/upgrade-backup'); const root = temporary(t);
  fs.writeFileSync(path.join(root, 'settings.json'), '{"palette":"peachSunset"}'); fs.writeFileSync(path.join(root, 'auth.json'), '{"secret":"never-copy"}');
  fs.writeFileSync(path.join(root, 'session-cache-v5.json'), '{"partial":"private"}');
  const directory = backupBeforeUpgrade(root, '2.12.26', 2153), manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json')));
  assert.deepEqual(manifest.files.map(r => r.name), ['settings.json']); assert.equal(fs.readFileSync(path.join(directory, 'settings.json'), 'utf8'), '{"palette":"peachSunset"}');
  assert.equal(backupBeforeUpgrade(root, '2.12.26', 2153), null);
});

test('upgrade preserves large legacy radar archives without the editable-record size limit', t => {
  const { backupBeforeUpgrade } = require('../src/core/upgrade-backup'); const root = temporary(t);
  const name = 'radar-evaluation-v1.json', bytes = Buffer.alloc(18 * 1024 * 1024, 120);
  fs.writeFileSync(path.join(root, name), bytes);
  const directory = backupBeforeUpgrade(root, '2.12.26', 2153);
  assert.deepEqual(fs.readFileSync(path.join(directory, name)), bytes);
  assert.deepEqual(fs.readFileSync(path.join(root, name)), bytes);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json')));
  assert.equal(manifest.files[0].bytes, bytes.length);
  assert.equal(manifest.files[0].sha256, require('node:crypto').createHash('sha256').update(bytes).digest('hex'));
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, 'app-version.json'))), { version: '2.12.26', build: 2153 });
});

test('upgrade rejects files changed mid-copy and removes only its incomplete destination', t => {
  const { copyVerified } = require('../src/core/upgrade-backup'); const root = temporary(t);
  const source = path.join(root, 'old.json'), destination = path.join(root, 'copy.json');
  fs.writeFileSync(source, Buffer.alloc(200000, 120)); let changed = false;
  const io = Object.create(fs);
  io.writeSync = (...args) => {
    const count = fs.writeSync(...args);
    if (!changed) { changed = true; fs.appendFileSync(source, 'changed'); }
    return count;
  };
  assert.throws(() => copyVerified(source, destination, io), /发生变化/);
  assert.equal(fs.existsSync(destination), false); assert.equal(fs.statSync(source).size, 200007);
  fs.writeFileSync(destination, 'keep existing');
  assert.throws(() => copyVerified(source, destination), /EEXIST/);
  assert.equal(fs.readFileSync(destination, 'utf8'), 'keep existing');
  assert.throws(() => copyVerified(root, path.join(root, 'bad.json')), /普通文件/);
});
test('valid current data remains visible when a future-version backup prevents saving', t => {
  const file = path.join(temporary(t), 'history.json'); fs.writeFileSync(file, JSON.stringify(histories())); fs.writeFileSync(file + '.last-good', '{"schemaVersion":999}');
  const r = new ProtectedRecord(file, validators.history, []); assert.equal(r.value.length, 2); assert.throws(() => r.write([]));
});
test('compressed and archived copies count once; broken compressed replacements preserve known data', async t => {
  const root = temporary(t), archive = path.join(root, 'archived_sessions'); fs.mkdirSync(archive);
  const meta = JSON.stringify({ type: 'session_meta', payload: { id: 'one-session', cwd: 'C:\\project' } });
  const token = JSON.stringify({ timestamp: iso(arrival), type: 'event_msg', payload: { type: 'token_count', info: { total_token_usage: { total_tokens: 123 }, last_token_usage: { total_tokens: 123, input_tokens: 100, output_tokens: 23 } } } });
  const data = meta + '\n' + token + '\n';
  fs.writeFileSync(path.join(root, 'active.jsonl'), data); const compressed = path.join(archive, 'copy.jsonl.zst'); fs.writeFileSync(compressed, zstdCompressSync(Buffer.from(data)));
  const reader = new CodexReader({ sessionRoots: [root], liveReader: async () => [], cachePath: path.join(root, 'cache.json') });
  t.after(() => reader.close());
  let value = await reader.read(new Date(arrival)); assert.equal(value.eventCount, 1); assert.equal(value.tokenStats.todayTokens, 123);
  fs.unlinkSync(path.join(root, 'active.jsonl')); value = await reader.read(new Date(arrival)); assert.equal(value.tokenStats.todayTokens, 123);
  fs.writeFileSync(compressed, zstdCompressSync(Buffer.from(data)).subarray(0, 10));
  value = await reader.read(new Date(arrival)); assert.equal(value.tokenStats.todayTokens, 123); assert.ok(value.statisticsWarning);
  fs.writeFileSync(compressed, zstdCompressSync(Buffer.from(data))); value = await reader.read(new Date(arrival)); assert.equal(value.statisticsWarning, null);
  fs.writeFileSync(compressed, zstdCompressSync(Buffer.from(data + '{bad-json}\n'))); value = await reader.read(new Date(arrival)); assert.equal(value.tokenStats.todayTokens, 123); assert.ok(value.statisticsWarning);
});

test('null usage in quota-only events does not discard the surrounding session', async t => {
  const root = temporary(t);
  const timestamp = iso(arrival);
  const lines = [
    { type: 'event_msg', timestamp, payload: { type: 'token_count', info: null } },
    { type: 'event_msg', timestamp, payload: { type: 'token_count', info: { total_token_usage: { total_tokens: 123 }, last_token_usage: { total_tokens: 123 } } } },
    { type: 'event_msg', timestamp, payload: { type: 'token_count', info: null } },
  ].map(row => JSON.stringify(row)).join('\n') + '\n';
  for (const compressed of [false, true]) {
    const file = path.join(root, 'session.jsonl' + (compressed ? '.zst' : ''));
    fs.writeFileSync(file, compressed ? zstdCompressSync(Buffer.from(lines)) : lines);
    const reader = new CodexReader({ sessionRoots: [root], liveReader: async () => [] });
    const value = await reader.read(new Date(arrival)); reader.close();
    assert.equal(value.tokenStats.todayTokens, 123);
    assert.equal(value.statisticsWarning, null);
    fs.unlinkSync(file);
  }
});
