const fs = require("node:fs"), path = require("node:path"), assert = require("node:assert/strict");
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
(async () => {
  const root = path.resolve(process.argv[2] || path.join(__dirname, "..")), output = path.join(root, "parity-validation");
  fs.mkdirSync(output, { recursive: true });
  const profile = path.join(output, "profile-" + Date.now()), launcher = path.join(profile, "launcher");
  fs.mkdirSync(launcher, { recursive: true });
  const now = Date.now(), scope = "fixture-account", reset = new Date(now + 2 * 86400000).toISOString();
  const samples = Array.from({ length: 90 }, (_, i) => ({ recordedAt: new Date(now - (89 - i) * 3600000).toISOString(), remainingPercent: i < 45 ? 86 - i : 96 - (i - 45),
    resetsAt: i < 45 ? new Date(now + 86400000).toISOString() : reset, windowMinutes: 10080 })).filter((_, i) => i < 45 || i > 49);
  fs.writeFileSync(path.join(profile, "quota-history-" + scope + ".json"), JSON.stringify(samples));
  fs.writeFileSync(path.join(profile, "settings.json"), JSON.stringify({ schemaVersion: 2118, themeMode: "dark", oneDriveSync: false, notifications: false, autoUpdates: false, showFiveHour: true }));
  fs.writeFileSync(path.join(launcher, "package.json"), JSON.stringify({ name: "pulse-parity-fixture", version: "2.12.0", main: "launch.cjs" }));
  const officialModule = path.join(root, "src/core/official-source.js");
  fs.writeFileSync(path.join(launcher, "launch.cjs"), `const { OfficialSource } = require(${JSON.stringify(officialModule)});
    OfficialSource.prototype.snapshot = function() { return { accountScope: ${JSON.stringify(scope)}, weekly: { remainingPercent: 51, windowMinutes: 10080, resetsAt: ${JSON.stringify(reset)} },
    fiveHour: { remainingPercent: 42, windowMinutes: 300, resetsAt: new Date(Date.now()+7200000).toISOString() }, flexible: { amountUSD: 100, balanceCredits: 2500 },
    quotaRead: { sampledAt: new Date(${now}).toISOString(), lastSuccessAt: new Date(${now}).toISOString() }, sourceStates: { quota: 'fresh', fiveHour: 'fresh', flexible: 'fresh', reset: 'fresh' }, rateLimitResetCredits: { availableCount: 2, availableCredits: [] } }; };
    require(${JSON.stringify(path.join(root, "src/main.js"))});`);
  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: profile, CODEX_PULSE_SESSION_ROOT: path.join(profile, "sessions"), CODEX_PULSE_OFFLINE: "1", CODEX_PULSE_ACCEPTANCE: "0" };
  fs.mkdirSync(env.CODEX_PULSE_SESSION_ROOT); delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ executablePath: path.join(root, "node_modules/electron/dist/electron.exe"), args: [launcher], env, timeout: 60000 });
  const errors = [];
  try {
    const page = await app.firstWindow(); page.on("pageerror", e => errors.push(e.message));
    await page.waitForFunction(() => typeof renderMacAligned === "function" && status?.quotaHistory?.length > 20 && !status?.statisticsLoading);
    const expected = (await page.evaluate(() => status.quotaHistory.length));
    const exportFile = path.join(output, "official-history.csv");
    await app.evaluate(({ dialog }, file) => { dialog.showSaveDialog = async () => ({ canceled: false, filePath: file }); }, exportFile);
    await page.locator('[data-section="trends"]').click();
    assert.ok(await page.locator("#quotaHistoryChart polyline").count() >= 2);
    await page.locator("#exportHistory").click();
    await page.waitForFunction(() => document.querySelector("#toast").textContent.includes("已导出"));
    assert.equal(fs.readFileSync(exportFile, "utf8").split("\r\n").length, expected + 5);
    assert.ok(!fs.readFileSync(exportFile, "utf8").includes(scope));
    await page.locator("#quotaHistoryChart").focus(); await page.keyboard.press("ArrowLeft");
    assert.equal(await page.locator("#historyMarker").getAttribute("visibility"), "visible");
    assert.match(await page.locator("#quotaHistoryInspection").textContent(), /官方重置时间/);
    for (const mode of ["dark", "light"]) {
      await page.evaluate(mode => window.suanli.setSettings({ themeMode: mode }), mode);
      await page.waitForFunction(mode => document.body.dataset.theme === mode, mode);
      await page.evaluate(() => document.querySelector("#toast").classList.remove("show"));
      await page.screenshot({ path: path.join(output, "history-" + mode + ".png") });
      await page.locator('[data-section="overview"]').click();
      await page.evaluate(() => {
        const demo = structuredClone(status);
        demo.tokenStats.rolling24HoursTokens = 1234567;
        demo.tokenStats.last7DaysTokens = 4300000;
        demo.tokenStats.monthTokens = 8250000;
        demo.tokenStats.cost24Hours = { ...demo.tokenStats.cost24Hours, usd: 13, coverage: 1, isUnavailable: false };
        demo.exchangeRate = { rate: 7.1 };
        renderStatus(demo);
      });
      await page.screenshot({ path: path.join(output, "overview-" + mode + ".png") });
      await page.locator('[data-section="trends"]').click();
    }
    for (const days of [1, 7, 30]) {
      await page.locator('[data-history-days="' + days + '"]').click();
      const count = await page.evaluate(() => historyRows.length); assert.ok(count > 0);
    }
    await page.locator('[data-usage-period="daily"]').click();
    assert.equal(await page.locator("#stackedDaily").isVisible(), true);
    await page.locator('[data-usage-period="hourly"]').click();
    assert.equal(await page.locator("#hourlyChart").isVisible(), true);
    await page.locator('[data-section="settings"]').click();
    await page.locator('[name="credits"]').fill("1000"); await page.locator('[name="grantedOn"]').fill("2026-10-01");
    await page.locator('[name="expiresOn"]').fill("2026-12-01"); await page.locator('[name="kind"]').selectOption("estimated");
    await page.locator('[name="evidence"]').fill("隔离验收推算依据"); await page.locator('#batchForm button').click();
    await page.waitForFunction(() => document.querySelector("#expiryBatches").textContent.includes("个人推算"));
    await page.screenshot({ path: path.join(output, "credit-batches.png") });
    await page.locator("#expiryBatches button").click(); await page.waitForFunction(() => document.querySelector("#expiryBatches").textContent.includes("暂无批次"));
    await page.locator('[data-section="overview"]').click();
    await page.locator("#maximizeButton").click(); assert.equal(await app.evaluate(({BrowserWindow}) => BrowserWindow.getAllWindows()[0].isMaximized()), true);
    await page.locator("#maximizeButton").click(); assert.equal(await app.evaluate(({BrowserWindow}) => BrowserWindow.getAllWindows()[0].isMaximized()), false);
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(640, 760));
    await page.waitForFunction(() => Math.abs(window.innerWidth - 640) <= 2);
    await page.evaluate(() => document.querySelector(".scroll-area").scrollTop = 0);
    await page.screenshot({ path: path.join(output, "overview-minimum.png") });
    const clipping = await page.evaluate(() => [...document.querySelectorAll(".titlebar,.section-nav,.summary-card,.flexible-card")].filter(e => e.scrollWidth > e.clientWidth + 2).map(e => e.className));
    assert.deepEqual(clipping, []); assert.deepEqual(errors, []);
    const report = { passed: true, historySamples: expected, exportedSamples: expected, keyboardInspection: true, historyPeriods: [1,7,30], themes: ["dark","light"], creditBatchAddRemove: true, windowMaximizeRestore: true, clipping, errors };
    fs.writeFileSync(path.join(output, "report.json"), JSON.stringify(report, null, 2)); console.log(JSON.stringify(report));
  } finally { await app.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
