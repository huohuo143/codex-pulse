const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

(async () => {
  const executablePath = process.env.PULSE_TEST_EXECUTABLE;
  if (!executablePath) throw new Error('PULSE_TEST_EXECUTABLE is required');
  const root = path.resolve(process.argv[2]);
  const output = path.join(root, 'lifecycle-validation');
  fs.mkdirSync(output, { recursive: true });
  const reports = [];
  for (const corrupt of [false, true]) {
    const support = path.join(output, 'profile-' + Date.now());
    const sessions = path.join(support, 'sessions');
    fs.mkdirSync(sessions, { recursive: true });
    const secret = 'PRIVATE_CONVERSATION_lifecycle_测试凭据';
    const original = { palette: 'wisteriaNight', appearance: 'glass', refreshSeconds: 60, oneDriveSync: false, opacity: 0.66, bounds: { x: 100, y: 100, width: 800, height: 900 } };
    fs.writeFileSync(path.join(support, 'settings.json'), JSON.stringify(original));
    fs.writeFileSync(path.join(support, 'session-cache-v5.json'), corrupt ? 'malformed ' + secret : JSON.stringify({ schemaVersion: 5, files: [['test', { partial: secret, offset: 100, events: [] }]] }));
    fs.writeFileSync(path.join(sessions, 'test.jsonl'), JSON.stringify({ timestamp: new Date().toISOString(), payload: { type: 'token_count', info: { total_token_usage: { total_tokens: 123 }, last_token_usage: { total_tokens: 123, input_tokens: 100, output_tokens: 23 } } } }) + '\n');
    const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: support, CODEX_PULSE_SESSION_ROOT: sessions, CODEX_PULSE_OFFLINE: '1', CODEX_PULSE_ACCEPTANCE: '0' };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({ executablePath, cwd: root, env, timeout: 60000 });
    try {
      const page = await app.firstWindow();
      await page.waitForFunction(async () => window.suanli && !(await window.suanli.bootstrap()).status.statisticsLoading);
      const data = await page.evaluate(() => window.suanli.bootstrap());
      assert.equal(data.version, require(path.join(root, 'package.json')).version);
      for (const key of ['palette', 'appearance', 'refreshSeconds', 'oneDriveSync', 'opacity']) assert.equal(data.settings[key], original[key], key);
      assert.equal(data.settings.notifications, false);
      assert.equal(data.status.tokenStats.todayTokens, 123);
      const backup = fs.readdirSync(support).find(x => x.startsWith('migration-backup-'));
      assert.ok(backup);
      const backupDir = path.join(support, backup);
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(backupDir, 'settings.json'))), original);
      for (const file of fs.readdirSync(backupDir)) assert.equal(fs.readFileSync(path.join(backupDir, file), 'utf8').includes(secret), false);
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      await page.locator('#closeButton').click();
      assert.equal(await app.evaluate(({BrowserWindow}) => BrowserWindow.getAllWindows().some(w => w.isVisible())), false);
      const secondExit = await new Promise((resolve, reject) => {
        const second = spawn(executablePath, [], { cwd: root, env, windowsHide: true, stdio: 'ignore' });
        const timer = setTimeout(() => { second.kill(); reject(new Error('second instance did not exit')); }, 20000);
        second.on('error', reject);
        second.on('exit', code => { clearTimeout(timer); resolve(code); });
      });
      assert.equal(secondExit, 0);
      await page.waitForFunction(() => document.visibilityState === 'visible');
      assert.equal(await app.evaluate(({BrowserWindow}) => BrowserWindow.getAllWindows().length), 1);
      await app.evaluate(({powerMonitor, screen}) => { powerMonitor.emit('resume'); screen.emit('display-removed', {}, {}); });
      await page.waitForFunction(async () => (await window.suanli.bootstrap()).status.tokenStats.todayTokens === 123);
      const invalid = await page.evaluate(async () => {
        const attempts = [() => window.suanli.setSettings({ notifications: 'yes' }), () => window.suanli.setCard({ type: 'arbitrary', enabled: true }), () => window.suanli.openExternal('file:///C:/Windows/notepad.exe')];
        return Promise.all(attempts.map(async fn => { try { await fn(); return false; } catch { return true; } }));
      });
      assert.ok(invalid.every(Boolean));
      assert.deepEqual(errors, []);
      reports.push({ corruptCache: corrupt, migration: true, workerTokens: 123, secondInstanceExit: secondExit, resumeEvent: true, displayRemovalEvent: true, invalidInputsRejected: true, isolatedSupport: support });
    } finally { await app.close(); }
  }
  const report = { executablePath, completedAt: new Date().toISOString(), reports, limitations: ['Resume and display removal are simulated Electron events; no physical sleep or monitor unplug was performed.'] };
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
})().catch(error => { console.error(error); process.exitCode = 1; });
