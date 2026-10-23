const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const output = path.join(root, 'validation-2153' + (process.env.PULSE_TEST_SCALE ? '-scale-' + process.env.PULSE_TEST_SCALE : ''));
fs.mkdirSync(output, { recursive: true });
const support = path.join(output, 'profile-' + Date.now()), sessions = path.join(support, 'sessions'); fs.mkdirSync(sessions, { recursive: true });
const now = Date.now(), arrival = now - 600000, DAY = 86400000;
const iso = at => new Date(at).toISOString();
const tokenLog = JSON.stringify({ type: 'session_meta', payload: { id: 'synthetic-windows-2153', cwd: 'C:\\synthetic-project' } }) + '\n' + JSON.stringify({ timestamp: iso(now), type: 'event_msg', payload: { type: 'token_count', info: { total_token_usage: { total_tokens: 123 }, last_token_usage: { total_tokens: 123, input_tokens: 100, output_tokens: 23 } } } }) + '\n';
fs.writeFileSync(path.join(sessions, 'synthetic.jsonl.zst'), require('node:zlib').zstdCompressSync(Buffer.from(tokenLog)));
const rows = [{ recordedAt: iso(arrival - 300000), remainingPercent: 5, resetsAt: iso(arrival + 5 * DAY), windowMinutes: 10080 }, { recordedAt: iso(arrival), remainingPercent: 100, resetsAt: iso(arrival + 7 * DAY), windowMinutes: 10080 }];
fs.writeFileSync(path.join(support, 'quota-history-fixture-account.json'), JSON.stringify(rows));
fs.writeFileSync(path.join(support, 'settings.json'), JSON.stringify({ schemaVersion: 2118, selectedSection: 'overview', themeMode: 'dark', palette: 'mintDawn', dailyBackup: false, autoUpdates: false, oneDriveSync: false }));
const errors = [], checks = []; let activeApp;
async function launch() {
  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: support, CODEX_PULSE_SESSION_ROOT: sessions, CODEX_PULSE_OFFLINE: '1', CODEX_PULSE_ACCEPTANCE: '0' }; delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ cwd: root, executablePath: process.env.PULSE_TEST_EXECUTABLE || path.join(root, 'node_modules/electron/dist/electron.exe'), args: [...(process.env.PULSE_TEST_EXECUTABLE ? [] : [root]), ...(process.env.PULSE_TEST_SCALE ? ['--force-device-scale-factor=' + process.env.PULSE_TEST_SCALE] : [])], env, timeout: 60000 });
  activeApp = app;
  app.on('window', w => w.on('pageerror', e => errors.push(e.message)));
  let page = await app.firstWindow();
  for (let n = 0; n < 100; n++) {
    const main = app.windows().find(w => w.url().includes('index.html') && w.url().includes('surface=main'));
    if (main) { page = main; break; }
    await page.waitForTimeout(50);
  }
  page.on('pageerror', e => errors.push(e.message));
  await page.waitForFunction(() => window.suanli && document.querySelector('#calendarGrid'));
  await page.waitForFunction(async () => !(await window.suanli.bootstrap()).status.statisticsLoading);
  const appPath = await app.evaluate(({ app }) => app.getAppPath());
  await app.evaluate((_, input) => {
    const { OfficialSource } = process.mainModule.require(input.appPath + '/src/core/official-source.js');
    const original = OfficialSource.prototype.snapshot;
    OfficialSource.prototype.snapshot = function(at) {
      const data = original.call(this, at);
      return { ...data, accountScope: 'fixture-account', weekly: { remainingPercent: 100, usedPercent: 0, windowMinutes: 10080, resetsAt: input.resetsAt },
        sourceStates: { ...data.sourceStates, quota: 'fresh' }, quotaRead: { sampledAt: new Date().toISOString(), lastSuccessAt: new Date().toISOString(), state: 'fresh' } };
    };
  }, { appPath, resetsAt: iso(arrival + 7 * DAY) });
  await page.evaluate(() => window.suanli.refresh());
  await page.waitForFunction(() => document.querySelector('.radar-main [data-bind="radarProbability"]').textContent === '已完成重置');
  return { app, page, appPath };
}
(async () => {
  let { app, page, appPath } = await launch();
  try {
    const boot = await page.evaluate(() => window.suanli.bootstrap());
    assert.equal(boot.version, '2.12.26'); assert.equal(boot.build, 2153); checks.push('version/build');
    const navigationFits = await page.evaluate(() => [...document.querySelectorAll('.segmented-control button')].every(button => {
      const range = document.createRange(); range.selectNodeContents(button); const text = range.getBoundingClientRect(), box = button.getBoundingClientRect();
      return text.left >= box.left && text.right <= box.right + 1 && text.height < 25;
    }));
    assert.equal(navigationFits, true); checks.push('all five navigation labels fit without wrapping or overlap');
    assert.equal(boot.status.tokenStats.todayTokens, 123); checks.push('bundled Electron reads compressed session in background worker');
    assert.equal(boot.status.radar.completionUntil, iso(arrival + DAY)); assert.equal(boot.status.radar.refreshHealthy, false); checks.push('account arrival with independent failed refresh status');
    await page.screenshot({ path: path.join(output, 'overview-completed.png') });
    await page.locator('[data-section="calendar"]').click();
    await page.waitForFunction(() => document.querySelector('#calendarGrid').children.length >= 35);
    const state = await page.evaluate(() => ({ n: status.resetCalendar.events.length, stored: settings.selectedSection, panel: document.querySelector('[data-panel="calendar"]').classList.contains('selected') }));
    assert.equal(state.n, 33); assert.equal(state.panel, true); checks.push('offline calendar and navigation');
    await page.locator('#calendarPrevious').click(); await page.locator('#calendarKind').selectOption('resetCard'); await page.locator('#calendarToday').click();
    await page.screenshot({ path: path.join(output, 'calendar.png') });
    await page.evaluate(() => window.suanli.setSettings({ floatingEnabled: true }));
    let floating;
    for (let n = 0; n < 100; n++) { floating = app.windows().find(w => w.url().includes('surface=floating')); if (floating) break; await page.waitForTimeout(50); }
    assert.ok(floating); await floating.waitForFunction(() => document.body.classList.contains('compact') && document.querySelector('.compact-reset-clock'));
    for (const size of ['standard', 'mini']) for (const style of ['rings', 'circle', 'square', 'pill', 'bars', 'barsQuad', 'badge', 'badgeQuad']) {
      await page.evaluate(patch => window.suanli.setSettings(patch), { compactStyle: style, compactSizeMode: size, showRadar: true });
      await floating.waitForFunction(({ style, size }) => document.body.dataset.compactStyle === style && document.body.dataset.size === size, { style, size });
      const view = await floating.evaluate(() => {
        const footer = document.querySelector('.compact-reset-clock'), box = footer.getBoundingClientRect(), gauge = [...document.querySelectorAll('.compact-gauge')].find(el => el.getBoundingClientRect().width > 0)?.getBoundingClientRect();
        return { title: footer.querySelector('strong').textContent, detail: footer.querySelector('span').textContent, clipped: box.left < 0 || box.right > innerWidth + 1 || box.bottom > innerHeight + 1 || box.top < 0, gaugeOverlap: !!gauge && box.top < gauge.bottom - 1 };
      });
      assert.equal(view.title, '已完成重置'); assert.ok(view.detail.includes('到账展示剩余')); assert.equal(view.clipped, false, style + ' footer clipped'); assert.equal(view.gaugeOverlap, false, style + ' overlaps quota ring');
      await floating.screenshot({ path: path.join(output, `floating-${style}-${size}.png`) });
    }
    checks.push('16 floating style/size combinations');
    for (const type of ['overview', 'radar']) {
      await page.evaluate(type => window.suanli.setCard({ type, enabled: true }), type);
      let card;
      for (let n = 0; n < 100; n++) { card = app.windows().find(w => w.url().includes('surface=' + type) && w.url().includes('card.html')); if (card) break; await page.waitForTimeout(50); }
      assert.ok(card); await card.waitForFunction(() => document.querySelector('#content').textContent.includes('已完成重置'));
      assert.ok((await card.locator('.reset-clock').innerText()).includes('到账展示剩余'));
      await card.screenshot({ path: path.join(output, 'card-' + type + '.png') });
    }
    checks.push('overview and radar desktop cards');
    await page.evaluate(() => window.suanli.setSettings({ floatingEnabled: false }));
    await app.close();
    ({ app, page, appPath } = await launch());
    const restored = await page.evaluate(() => window.suanli.bootstrap()); assert.equal(restored.status.radar.completionUntil, iso(arrival + DAY)); checks.push('restart preserves original countdown');
    await page.evaluate(() => window.suanli.showSection('settings'));
    await page.waitForFunction(() => document.querySelector('[data-panel="settings"]').classList.contains('selected'));
    const form = page.locator('#batchForm');
    await form.locator('[name="credits"]').fill('1,234.567890123'); await form.locator('[name="grantedOn"]').fill('2026-10-23'); await form.locator('[name="expiresOn"]').fill('2026-11-23'); await form.locator('[name="evidence"]').fill('Synthetic verified source for compatibility testing'); await form.locator('[type="submit"]').click();
    await page.waitForFunction(() => document.querySelector('#batchForm + .record-feedback').textContent.includes('已保存'));
    assert.equal(await form.locator('[name="credits"]').inputValue(), '1234.567890123');
    const stored = JSON.parse(fs.readFileSync(path.join(support, 'credit-expiry-batches-v1.json'))); assert.equal(stored.length, 1); assert.equal(stored[0].credits, 1234.567890123);
    await form.locator('[name="credits"]').fill('1,5'); await form.locator('[type="submit"]').click(); assert.equal(JSON.parse(fs.readFileSync(path.join(support, 'credit-expiry-batches-v1.json'))).length, 1); checks.push('batch saving/edit precision and invalid grouping');
    await page.screenshot({ path: path.join(output, 'settings-protection.png') });
    await app.evaluate((_, input) => {
      const { RadarService } = process.mainModule.require(input.appPath + '/src/core/radar-announcements.js'), original = RadarService.prototype.snapshot;
      RadarService.prototype.snapshot = function() {
        const data = original.call(this), now = Date.now(), publishedAt = new Date(now - 60000).toISOString();
        return { ...data, error: null, analysisError: null, lastSuccessAt: now, refreshHealthy: true,
          analysis: { state: 'announced', kind: 'hard_reset', summaryZh: '合成界面用例：新一轮明确预告，尚未确认到账。', timingZh: '', evidenceIDs: ['2111111111111111111'], analyzedAt: new Date(now).toISOString(), deadline: { localDateTime: input.deadline, sourceTimeZone: 'UTC', evidenceID: '2111111111111111111', sourceQuote: 'before deadline UTC' } },
          posts: [{ id: '2111111111111111111', publishedAt, originalText: 'Synthetic new reset announcement before deadline UTC' }] };
      };
    }, { appPath, deadline: iso(Date.now() + 7200000).slice(0, 19) });
    await page.evaluate(async () => { await window.suanli.setSettings({ selectedSection: 'overview' }); showSection('overview', false); });
    await page.waitForFunction(() => document.querySelector('.radar-main [data-bind="radarProbability"]').textContent === '重置已预告');
    assert.ok((await page.locator('.radar-main .reset-clock').innerText()).includes('北京时间'));
    await page.screenshot({ path: path.join(output, 'overview-announcement.png') }); checks.push('new announcement supersedes arrival and displays Beijing deadline');
    assert.equal(errors.length, 0, errors.join('\n'));
    fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify({ passed: true, version: restored.version, build: restored.build, platform: process.platform, checks, errors, completionUntil: restored.status.radar.completionUntil }, null, 2));
    console.log(JSON.stringify({ passed: true, checks, errors, output }));
  } finally { await app.close().catch(() => {}); }
})().catch(async error => { console.error(error.stack); console.error(JSON.stringify({ errors })); await activeApp?.close().catch(() => {}); process.exitCode = 1; });
