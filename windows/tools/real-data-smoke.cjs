const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(process.argv[2]);
const installed = process.argv.includes('--installed');
const support = installed ? path.join(process.env.APPDATA, 'Codex算力码表') : process.env.PULSE_REVIEW_PROFILE;
assert.ok(support, 'Provide an isolated copy of the existing app records');
const errors = [];
(async () => {
  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: support };
  if (installed) delete env.CODEX_PULSE_SUPPORT_DIR;
  delete env.CODEX_PULSE_OFFLINE; delete env.CODEX_PULSE_SESSION_ROOT; delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ cwd: root, executablePath: process.env.PULSE_TEST_EXECUTABLE || path.join(root, 'node_modules/electron/dist/electron.exe'), args: process.env.PULSE_TEST_EXECUTABLE ? [] : [root], env, timeout: 60000 });
  app.on('window', page => page.on('pageerror', error => errors.push(error.name + ': ' + error.message)));
  try {
    const page = await app.firstWindow();
    page.on('pageerror', error => errors.push(error.name + ': ' + error.message));
    await page.waitForFunction(() => !!window.suanli);
    let boot;
    for (let attempt = 0; attempt < 120; attempt++) {
      boot = await page.evaluate(() => window.suanli.bootstrap());
      if (boot.status.weekly && !boot.status.statisticsLoading && boot.status.tokenStats.monthTokens > 0) break;
      await page.waitForTimeout(500);
    }
    assert.ok(boot.status.weekly, 'Live quota unavailable');
    assert.equal(boot.status.statisticsLoading, false);
    assert.equal(boot.version, '2.12.26'); assert.equal(boot.build, 2153);
    assert.equal(boot.status.statisticsWarning, null);
    assert.ok(boot.status.scannedFiles >= 21);
    await page.evaluate(() => window.suanli.showSection('overview'));
    await page.waitForFunction(() => document.querySelector('[data-panel="overview"]').classList.contains('selected'));
    assert.equal(await page.locator('[data-bind="weeklyNumber"]').first().innerText(), String(Math.round(boot.status.weekly.remainingPercent)));
    assert.ok((await page.locator('[data-bind="month"]').first().innerText()).length > 1);
    await page.screenshot({ path: path.join(root, 'real-data-overview.png') });
    await page.evaluate(() => window.suanli.showSection('trends'));
    await page.waitForFunction(() => document.querySelector('[data-panel="trends"]').classList.contains('selected'));
    await page.screenshot({ path: path.join(root, 'real-data-trends.png') });
    const backups = fs.readdirSync(path.join(support, 'version-backups'));
    const latest = path.join(support, 'version-backups', backups.at(-1));
    const manifest = JSON.parse(fs.readFileSync(path.join(latest, 'manifest.json')));
    assert.ok(manifest.files.find(f => f.name === 'radar-evaluation-v1.json').bytes > 16 * 1024 * 1024);
    assert.deepEqual(errors, []);
    await page.evaluate(() => window.suanli.showSection('overview'));
    const report = { version: boot.version, build: boot.build, installed, realData: true, quotaFreshness: boot.status.sourceStates.quota, weeklyRemainingPercent: boot.status.weekly.remainingPercent, todayTokens: boot.status.tokenStats.todayTokens, monthTokens: boot.status.tokenStats.monthTokens, scannedFiles: boot.status.scannedFiles, eventCount: boot.status.eventCount, statisticsWarning: boot.status.statisticsWarning, legacyArchiveBackupVerified: true, rendererErrors: errors };
    fs.writeFileSync(path.join(root, installed ? 'installed-real-data-review.json' : 'real-data-review.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
  } finally { await app.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
