const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function port() { const server = net.createServer(); await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); const value = server.address().port; await new Promise(resolve => server.close(resolve)); return value; }
(async () => {
  const root = path.resolve(process.argv[2]);
  const output = path.join(root, 'portable-validation');
  const support = path.join(output, 'profile-' + Date.now());
  fs.mkdirSync(path.join(support, 'sessions'), { recursive: true });
  const debugPort = await port(), inspectPort = await port();
  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: support, CODEX_PULSE_SESSION_ROOT: path.join(support, 'sessions'), CODEX_PULSE_OFFLINE: '1', CODEX_PULSE_ACCEPTANCE: '0' };
  delete env.ELECTRON_RUN_AS_NODE;
  const child = spawn(process.env.PULSE_TEST_EXECUTABLE, ['--remote-debugging-port=' + debugPort, '--inspect=' + inspectPort], { cwd: root, env, windowsHide: true, stdio: 'ignore' });
  let exitCode, exited = false;
  child.once('exit', code => { exited = true; exitCode = code; });
  let browser, inspector;
  try {
    for (let i = 0; i < 120; i++) {
      try { const r = await fetch('http://127.0.0.1:' + debugPort + '/json/version'); if (r.ok) break; } catch {}
      if (exited) throw new Error('portable launcher exited early: ' + exitCode);
      await pause(500);
    }
    browser = await chromium.connectOverCDP('http://127.0.0.1:' + debugPort);
    const context = browser.contexts()[0];
    let page = context.pages().find(page => page.url().includes('index.html'));
    if (!page) page = await context.waitForEvent('page');
    await page.waitForFunction(async () => window.suanli && !(await window.suanli.bootstrap()).status.statisticsLoading);
    const bootstrap = await page.evaluate(() => window.suanli.bootstrap());
    assert.equal(bootstrap.version, require(path.join(root, 'package.json')).version);
    await page.screenshot({path: path.join(output, 'portable-start.png')});
    await page.locator('#closeButton').click();
    assert.equal(exited, false);
    const targets = await (await fetch('http://127.0.0.1:' + inspectPort + '/json/list')).json();
    inspector = new WebSocket(targets[0].webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { inspector.addEventListener('open', resolve, {once:true}); inspector.addEventListener('error', reject, {once:true}); });
    inspector.send(JSON.stringify({id: 1, method: 'Runtime.evaluate', params: {expression: "process.mainModule.require('electron').app.quit()"}}));
    await pause(500);
    inspector.close();
    for (let i = 0; i < 60 && !exited; i++) await pause(500);
    assert.equal(exited, true, 'portable launcher should exit and clean up after application quit');
    assert.equal(exitCode, 0);
    const report = { passed: true, version: bootstrap.version, workerReady: !bootstrap.status.statisticsLoading, closeToTray: true, explicitQuitExitCode: exitCode, completedAt: new Date().toISOString() };
    fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
  } finally { inspector?.close(); await browser?.close().catch(() => {}); if (!exited) child.kill(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
