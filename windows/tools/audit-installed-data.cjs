const fs = require('node:fs'), fsp = require('node:fs/promises'), path = require('node:path'), os = require('node:os'), assert = require('node:assert/strict');
const { StringDecoder } = require('node:string_decoder');
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const stage = path.resolve(process.argv[2]);
const executable = process.env.PULSE_TEST_EXECUTABLE;
assert.ok(executable);
const actualRoot = path.join(process.env.APPDATA, 'Codex算力码表');
const support = fs.mkdtempSync(path.join(stage, 'audit-profile-'));
for (const name of fs.readdirSync(actualRoot).filter(n => /^(settings|quota-history-.+|alert-ledger-.+|radar-source-v1|radar-announcements-v2|reset-calendar-v1|project-budgets-v1|credit-expiry.*|model-prices-v1)\.json$/.test(n))) fs.copyFileSync(path.join(actualRoot, name), path.join(support, name));
const settings = JSON.parse(fs.readFileSync(path.join(support, 'settings.json')));
Object.assign(settings, { oneDriveSync: false, autoUpdates: false, dailyBackup: false, notifications: false, dailySummary: false, launchAtLogin: false, launchWithCodex: false, floatingEnabled: true, cards: {} });
fs.writeFileSync(path.join(support, 'settings.json'), JSON.stringify(settings));
const checks = [], errors = [];
const compact = v => v >= 1e8 ? `${(v / 1e8).toFixed(v >= 1e9 ? 1 : 2).replace(/\.0+$/, '')}亿` : v >= 1e4 ? `${(v / 1e4).toFixed(v >= 1e6 ? 1 : 2).replace(/\.0+$/, '')}万` : Math.round(v).toLocaleString('zh-CN');
async function poll(read, predicate, message, attempts = 120) {
  let result;
  for (let i = 0; i < attempts; i++) { result = await read(); if (predicate(result)) return result; await new Promise(r => setTimeout(r, 500)); }
  throw new Error(message);
}
async function independentTotals(roots) {
  const files = [];
  async function walk(dir) { for (const entry of await fsp.readdir(dir, { withFileTypes: true }).catch(() => [])) { const file = path.join(dir, entry.name); if (entry.isDirectory()) await walk(file); else if (entry.isFile() && /\.jsonl(?:\.zst)?$/.test(file)) files.push(file); } }
  for (const dir of roots) await walk(dir);
  const sessions = new Map(); let compressed = 0;
  for (const file of files) {
    let id = path.basename(file).replace(/\.zst$/, ''), partial = '', events = [], decoder = new StringDecoder('utf8');
    const input = fs.createReadStream(file), zipped = file.endsWith('.zst'); if (zipped) compressed++;
    const stream = zipped ? input.pipe(require('node:zlib').createZstdDecompress()) : input;
    function line(text) {
      let row; try { row = JSON.parse(text); } catch { return; }
      if (row.type === 'session_meta' && typeof row.payload?.id === 'string') id = row.payload.id;
      if (row.payload?.type === 'token_count' && Number.isFinite(Date.parse(row.timestamp))) events.push({ at: row.timestamp, total: Number(row.payload.info?.total_token_usage?.total_tokens || 0), last: Number(row.payload.info?.last_token_usage?.total_tokens || 0) });
    }
    for await (const buffer of stream) { const rows = (partial + decoder.write(buffer)).split(/\r?\n/); partial = rows.pop(); rows.forEach(line); }
    if (partial.trim()) line(partial);
    if (!sessions.has(id) || sessions.get(id).length < events.length) sessions.set(id, events);
  }
  const daily = new Map();
  for (const events of sessions.values()) {
    const unique = new Map();
    for (const e of events.filter(e => e.total > 0 && e.last > 0).sort((a, b) => Date.parse(a.at) - Date.parse(b.at))) if (!unique.has(e.total)) unique.set(e.total, e);
    for (const e of unique.values()) { const key = new Date(e.at).toLocaleDateString('sv-SE'); daily.set(key, (daily.get(key) || 0) + e.last); }
  }
  return { daily, files: files.length, compressed };
}
(async () => {
  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: support }; delete env.CODEX_PULSE_OFFLINE; delete env.CODEX_PULSE_SESSION_ROOT; delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ executablePath: executable, args: [], cwd: stage, env, timeout: 60000 });
  app.on('window', page => page.on('pageerror', e => errors.push(e.message)));
  try {
    const page = await poll(async () => app.windows().find(p => p.url().includes('surface=main')), Boolean, 'Main window missing');
    page.on('pageerror', e => errors.push(e.message));
    const boot = await poll(() => page.evaluate(() => window.suanli.bootstrap()), b => b.status.weekly && !b.status.statisticsLoading && b.status.tokenStats.monthTokens > 0, 'Real quota or usage unavailable');
    assert.equal(boot.version, '2.12.29'); assert.equal(boot.build, 2157); assert.equal(boot.status.statisticsWarning, null);
    for (const name of ['quota', 'flexible', 'reset']) assert.equal(boot.status.sourceStates[name], 'fresh'); checks.push('live quota, flexible balance and Full reset fresh');
    for (const section of ['overview', 'trends', 'insights', 'calendar', 'settings']) {
      await page.locator(`[data-section="${section}"]`).click();
      await page.waitForFunction(section => document.querySelector(`[data-panel="${section}"]`).classList.contains('selected'), section);
      const mismatches = await page.evaluate(() => {
        const t = status.tokenStats, expected = { weekly: percentage(status.weekly?.remainingPercent), rolling24: compactNumber(t.rolling24HoursTokens), last7: compactNumber(t.last7DaysTokens), month: compactNumber(t.monthTokens), creditCount: `${status.rateLimitResetCredits.availableCount} 次` };
        return Object.entries(expected).flatMap(([name, value]) => [...document.querySelectorAll(`[data-bind="${name}"]`)].filter(el => el.textContent !== value).map(() => name));
      }); assert.deepEqual(mismatches, []); checks.push(section + ': display matches current backend');
    }
    const ui = await page.evaluate(() => ({ hourly: document.querySelectorAll('#hourlyChart .bar').length, models: document.querySelector('#models').children.length, history: document.querySelectorAll('#quotaHistoryChart .history-line').length, categories: document.querySelector('#categories').children.length, projects: document.querySelector('#projects').children.length, calendarDays: document.querySelectorAll('.calendar-day').length, calendarEvents: status.resetCalendar.events.length, settingsHealth: document.querySelector('#recordHealth').children.length, costPartial: status.tokenStats.costMonth.isPartial, unpricedDisclosed: status.tokenStats.costMonth.unpricedModels.every(m => document.querySelector('#costNote').textContent.includes(m)) }));
    assert.equal(ui.hourly, 24); for (const key of ['models', 'history', 'categories', 'projects', 'settingsHealth']) assert.ok(ui[key] > 0, key); assert.ok(ui.calendarEvents >= 33); assert.equal(ui.unpricedDisclosed, true); checks.push('charts, history, projects, calendar, settings and partial prices populated');
    const captured = await page.evaluate(() => ({ daily: status.tokenStats.daily, monthlyDifference: status.tokenStats.monthTokens - status.tokenStats.todayTokens, roots: status.sessionsRoot.split(' | ') }));
    const reference = await independentTotals(captured.roots), today = new Date().toLocaleDateString('sv-SE'), month = today.slice(0, 7);
    for (const row of captured.daily.filter(row => row.key < today)) assert.equal(row.totalTokens, reference.daily.get(row.key) || 0, 'Independent daily total: ' + row.key);
    assert.equal(captured.monthlyDifference, [...reference.daily].filter(([day]) => day.startsWith(month) && day < today).reduce((sum, [, tokens]) => sum + tokens, 0)); checks.push('independent raw-log aggregation matches all completed days and month excluding active today');
    const before = boot.status.quotaRead.lastSuccessAt;
    await page.evaluate(() => window.suanli.refresh());
    const refreshed = await poll(() => page.evaluate(() => window.suanli.bootstrap()), b => Date.parse(b.status.quotaRead.lastSuccessAt) > Date.parse(before), 'Quota refresh did not advance');
    assert.equal(refreshed.status.sourceStates.quota, 'fresh'); checks.push('manual refresh advances actual successful read');
    const floating = await poll(async () => app.windows().find(p => p.url().includes('surface=floating')), Boolean, 'Floating window missing');
    for (const style of ['rings', 'circle', 'square', 'pill', 'bars', 'barsQuad', 'badge', 'badgeQuad']) {
      await page.evaluate(style => window.suanli.setSettings({ compactStyle: style }), style);
      await floating.waitForFunction(style => document.body.dataset.compactStyle === style, style);
      assert.equal(await floating.locator('[data-bind="weekly"]').first().textContent(), Math.round(refreshed.status.weekly.remainingPercent) + '%');
    } checks.push('all eight floating styles show real quota');
    for (const type of ['overview', 'quota', 'radar', 'credits', 'tokens', 'trend', 'projects']) {
      await page.evaluate(type => window.suanli.setCard({ type, enabled: true }), type);
      const card = await poll(async () => app.windows().find(p => p.url().includes('surface=' + type) && p.url().includes('card.html')), Boolean, type + ' card missing');
      await card.waitForFunction(() => !!document.querySelector('#content')?.children.length);
      const text = await card.locator('#content').innerText(); assert.ok(text.length > 10); assert.ok(!/undefined|NaN|Infinity/.test(text));
      if (['quota', 'overview'].includes(type)) assert.ok(text.includes(Math.round(refreshed.status.weekly.remainingPercent) + '%'));
    } checks.push('all seven desktop cards populated without invalid values');
    const appPath = await app.evaluate(({ app }) => app.getAppPath());
    const analysis = await app.evaluate(async (_, appPath) => {
      const fs = process.mainModule.require('node:fs'), path = process.mainModule.require('node:path');
      const saved = JSON.parse(fs.readFileSync(path.join(process.env.CODEX_PULSE_SUPPORT_DIR, 'radar-announcements-v2.json')));
      const { analyze } = process.mainModule.require(path.join(appPath, 'src/core/tibo-analysis.js'));
      const result = await analyze(saved.page.posts, Date.now(), { timeout: 120000 });
      return { state: result.state, model: result.model, reasoningEffort: result.reasoningEffort, evidenceCount: result.evidenceIDs.length };
    }, appPath);
    assert.equal(analysis.model, 'gpt-6-astra'); checks.push('packaged external model reads staged schema and validates real public posts');
    assert.deepEqual(errors, []);
    const report = { version: boot.version, build: boot.build, installedExecutable: path.basename(executable), checkedAt: new Date().toISOString(), checks, rendererErrors: errors, files: reference.files, compressedFiles: reference.compressed, weeklyRemainingPercent: refreshed.status.weekly.remainingPercent, todayTokens: refreshed.status.tokenStats.todayTokens, monthTokens: refreshed.status.tokenStats.monthTokens, statisticsWarning: refreshed.status.statisticsWarning, ui, publicModel: analysis };
    fs.writeFileSync(path.join(stage, 'full-data-audit.json'), JSON.stringify(report, null, 2)); console.log(JSON.stringify(report));
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
