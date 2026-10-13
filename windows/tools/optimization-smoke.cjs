// Isolated UI/IPC regression for the shared Electron code. A macOS run does
// not establish Windows installer, notification, tray or native-window parity.
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

function defaultExecutable(root) {
  const dist = path.join(root, "node_modules", "electron", "dist");
  return process.platform === "darwin"
    ? path.join(dist, "Electron.app", "Contents", "MacOS", "Electron")
    : path.join(dist, process.platform === "win32" ? "electron.exe" : "electron");
}
function writeJSON(file, value) { fs.writeFileSync(file, JSON.stringify(value, null, 2)); }

(async () => {
  const root = path.resolve(process.argv[2] || path.join(__dirname, ".."));
  const output = path.resolve(process.env.PULSE_OPTIMIZATION_OUTPUT || process.argv[3] || path.join(root, "optimization-validation"));
  const profile = path.join(output, "profile-" + Date.now());
  const launcher = path.join(profile, "launcher"), sessions = path.join(profile, "sessions");
  fs.mkdirSync(launcher, { recursive: true }); fs.mkdirSync(sessions);
  const version = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).version;
  const projectURL = "file:///C:/Synthetic/" + encodeURIComponent("预算项目");
  const literalPath = "C:\\Synthetic\\literal%20project";
  for (const [i, cwd] of [projectURL, literalPath].entries()) {
    const fixture = [
      { type: "session_meta", payload: { cwd } },
      { timestamp: new Date().toISOString(), type: "event_msg", payload: { type: "token_count", info: {
        total_token_usage: { total_tokens: 3000 - i * 1000 },
        last_token_usage: { total_tokens: 3000 - i * 1000, input_tokens: 2000 - i * 1000, output_tokens: 1000 },
      } } },
    ];
    fs.writeFileSync(path.join(sessions, "rollout-fixture-" + i + ".jsonl"), fixture.map((row) => JSON.stringify(row)).join("\n") + "\n");
  }
  writeJSON(path.join(profile, "settings.json"), {
    schemaVersion: 2118, themeMode: "dark", selectedSection: "insights", oneDriveSync: false,
    notifications: false, autoUpdates: false, dailyBackup: false, dailySummary: false,
    floatingEnabled: false, refreshSeconds: 120,
  });
  writeJSON(path.join(launcher, "package.json"), { name: "pulse-optimization-fixture", version, main: "launch.cjs" });
  // Only the fixture launcher instruments failures and gates. Production files
  // and the real user's profile are never changed by this script.
  fs.writeFileSync(path.join(launcher, "launch.cjs"), `
const { Runtime } = require(${JSON.stringify(path.join(root, "src/core/runtime.js"))});
const { Store } = require(${JSON.stringify(path.join(root, "src/core/storage.js"))});
const { OfficialSource } = require(${JSON.stringify(path.join(root, "src/core/official-source.js"))});
const hook = globalThis.__pulseOptimizationTest = { budgetCalls: [], refreshCalls: 0, failWrite: false, holdBudget: false, holdRefresh: false };
OfficialSource.prototype.snapshot = function () {
  const now = new Date().toISOString();
  return { accountScope: "synthetic-optimization-account", weekly: { remainingPercent: 67, windowMinutes: 10080, resetsAt: new Date(Date.now() + 3 * 86400000).toISOString() },
    fiveHour: { remainingPercent: 42, windowMinutes: 300, resetsAt: new Date(Date.now() + 7200000).toISOString() },
    quotaRead: { sampledAt: now, lastSuccessAt: now }, sourceStates: { quota: "fresh", fiveHour: "fresh", flexible: "unavailable", reset: "unavailable" } };
};
const start = Runtime.prototype.start;
Runtime.prototype.start = function () {
  hook.runtime = this; start.call(this);
  this.timers.forEach(clearInterval); this.timers = [];
};
const budget = Runtime.prototype.setBudget;
Runtime.prototype.setBudget = async function (value) {
  hook.budgetCalls.push(structuredClone(value));
  if (hook.holdBudget) await new Promise((resolve) => { hook.releaseBudget = resolve; });
  return budget.call(this, value);
};
const write = Store.prototype.write;
Store.prototype.write = function (name, value) {
  if (hook.failWrite && name === "project-budgets-v1") throw new Error("隔离验收：预算写入失败");
  return write.call(this, name, value);
};
const refresh = Runtime.prototype.refresh;
Runtime.prototype.refresh = async function (options = {}) {
  if (options.force) {
    hook.refreshCalls++;
    if (hook.holdRefresh) await new Promise((resolve) => { hook.releaseRefresh = resolve; });
  }
  return refresh.call(this, options);
};
require(${JSON.stringify(path.join(root, "src/main.js"))});
`);

  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: profile, CODEX_PULSE_SESSION_ROOT: sessions,
    CODEX_PULSE_OFFLINE: "1", CODEX_PULSE_ACCEPTANCE: "0" };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ cwd: root,
    executablePath: process.env.ELECTRON_EXECUTABLE || defaultExecutable(root), args: [launcher], env, timeout: 60000 });
  const report = { passed: false, version, hostPlatform: process.platform, nativeWindowsRun: process.platform === "win32",
    scope: "Shared Electron UI and IPC; synthetic local sessions; isolated profile; offline",
    limitation: process.platform === "win32"
      ? "Does not by itself verify the distributed installer, Windows notifications or tray lifecycle."
      : "Cross-platform UI evidence only; Windows native acceptance remains separate.",
    output, profile, checks: [], screenshots: [], errors: [] };
  const errors = report.errors;
  app.on("window", (window) => window.on("pageerror", (error) => errors.push(error.message)));
  try {
    const page = await app.firstWindow(); page.setDefaultTimeout(20000);
    page.on("pageerror", (error) => errors.push(error.message));
    await page.waitForFunction(() => typeof budgetEditor !== "undefined" && status && !status.statisticsLoading && status.tokenStats.monthTopProjects.length === 2);
    await page.locator('[data-section="insights"]').click();
    await page.locator("#budgetProject").selectOption(projectURL);
    assert.equal(await page.locator("#budgetProject option:checked").textContent(), "预算项目");
    assert.match(await page.locator("#budgetProject").textContent(), /literal%20project/);
    assert.match(await page.locator("#projects").textContent(), /预算项目/);
    assert.match(await page.locator("#recentUsage").textContent(), /预算项目/);
    const raw = await page.evaluate((id) => status.tokenStats.monthTopProjects.find((row) => row.id === id), projectURL);
    assert.equal(raw.id, projectURL); assert.equal(raw.projectPath, projectURL);
    assert.equal(raw.projectName, encodeURIComponent("预算项目"));
    report.checks.push("file URL Chinese display; ordinary percent filename and original ID/path preserved");

    for (const value of ["", "0", "-1", "1.5", "2e6", "2,00", "9007199254740992"]) {
      await page.locator("#budgetLimit").fill(value);
      // fill("") is still checked via disabled state even when the field was
      // already empty and Chromium emits no new input event.
      assert.equal(await page.locator("#saveBudget").isDisabled(), true, value);
    }
    assert.equal(await app.evaluate(() => globalThis.__pulseOptimizationTest.budgetCalls.length), 0);
    report.checks.push("empty, zero, negative, fraction, exponent, malformed separator and unsafe integers cannot save");

    await page.locator("#budgetLimit").fill("2,000,000");
    assert.equal(await page.locator("#saveBudget").isEnabled(), true);
    await page.locator("#saveBudget").click();
    await page.waitForFunction(() => document.querySelector("#budgetFeedback").textContent === "预算已保存");
    const persisted = JSON.parse(fs.readFileSync(path.join(profile, "project-budgets-v1.json"), "utf8"));
    assert.equal(persisted[0].monthlyTokenLimit, 2000000); assert.equal(persisted[0].id, projectURL);
    assert.equal(await page.locator("#toast").getAttribute("data-kind"), "success");
    assert.equal(await page.locator("#toast").getAttribute("role"), "status");
    report.checks.push("valid comma-separated budget persists through real IPC and confirms success");

    await app.evaluate(() => { globalThis.__pulseOptimizationTest.failWrite = true; });
    await page.locator("#budgetLimit").fill("3,000,000"); await page.locator("#saveBudget").click();
    await page.waitForFunction(() => document.querySelector("#budgetFeedback").textContent.includes("隔离验收：预算写入失败"));
    await app.evaluate(() => globalThis.__pulseOptimizationTest.runtime.publish());
    assert.equal(await page.locator("#budgetLimit").inputValue(), "3,000,000");
    assert.equal(await page.locator("#budgetProject").inputValue(), projectURL);
    assert.equal(await page.locator("#saveBudget").isEnabled(), true);
    assert.equal(await page.locator("#toast").getAttribute("data-kind"), "error");
    assert.equal(await page.locator("#toast").getAttribute("role"), "alert");
    assert.doesNotMatch(await page.locator("#toast").textContent(), /Error invoking remote method/);
    assert.doesNotMatch(await page.locator("#budgetFeedback").textContent(), /Error invoking remote method/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(profile, "project-budgets-v1.json"), "utf8"))[0].monthlyTokenLimit, 2000000);
    assert.equal(await app.evaluate(() => globalThis.__pulseOptimizationTest.runtime.budgets[0].monthlyTokenLimit), 2000000);
    report.checks.push("injected disk failure retains draft, selected project and durable budget after a status push");

    const beforeSave = await app.evaluate(() => { const h = globalThis.__pulseOptimizationTest; h.failWrite = false; h.holdBudget = true; return h.budgetCalls.length; });
    await page.locator("#saveBudget").click();
    await page.waitForFunction(() => document.querySelector("#saveBudget").disabled && document.querySelector("#budgetProject").disabled);
    await page.evaluate(() => {
      document.querySelector("#saveBudget").dispatchEvent(new Event("click"));
      document.querySelector("#removeBudget").dispatchEvent(new Event("click"));
    });
    assert.equal(await app.evaluate(() => globalThis.__pulseOptimizationTest.budgetCalls.length), beforeSave + 1);
    await app.evaluate(() => { const h = globalThis.__pulseOptimizationTest; h.holdBudget = false; h.releaseBudget(); });
    await page.waitForFunction(() => document.querySelector("#budgetFeedback").textContent === "预算已保存" && !document.querySelector("#saveBudget").disabled);
    assert.equal(JSON.parse(fs.readFileSync(path.join(profile, "project-budgets-v1.json"), "utf8"))[0].monthlyTokenLimit, 3000000);
    report.checks.push("pending save disables controls and coalesces repeated submit/delete events");

    const beforeRefresh = await app.evaluate(() => { const h = globalThis.__pulseOptimizationTest; h.holdRefresh = true; return h.refreshCalls; });
    await page.locator("#refreshButton").click();
    await page.waitForFunction(() => document.querySelector("#refreshButton").disabled);
    await app.evaluate(() => globalThis.__pulseOptimizationTest.runtime.publish());
    await page.evaluate(() => {
      showToast("隔离验收操作完成", "success");
      document.querySelector("#refreshButton").dispatchEvent(new Event("click"));
    });
    assert.match(await page.locator("#refreshState").textContent(), /正在刷新/);
    assert.equal(await app.evaluate(() => globalThis.__pulseOptimizationTest.refreshCalls), beforeRefresh + 1);
    await app.evaluate(() => { const h = globalThis.__pulseOptimizationTest; h.holdRefresh = false; h.releaseRefresh(); });
    await page.waitForFunction(() => !document.querySelector("#refreshButton").disabled && !document.body.classList.contains("loading"));
    report.checks.push("refresh status survives intermediate publication and action toast; duplicate request is suppressed");

    await app.evaluate(() => {
      const h = globalThis.__pulseOptimizationTest;
      h.originalRead = h.runtime.official.read;
      h.runtime.official.read = async () => { throw new Error("隔离验收读取失败"); };
    });
    await page.locator("#refreshButton").click();
    await page.waitForFunction(() => document.querySelector("#refreshState").textContent.includes("刷新失败") && !document.querySelector("#refreshButton").disabled);
    assert.equal(await page.locator("#toast").getAttribute("data-kind"), "error");
    assert.equal(await page.locator("#toast").textContent(), "官方数据刷新失败");
    assert.doesNotMatch(await page.locator("#subtitle").textContent(), /Error invoking remote method/);
    await app.evaluate(() => { const h = globalThis.__pulseOptimizationTest; h.runtime.official.read = h.originalRead; });
    await page.locator("#refreshButton").click();
    await page.waitForFunction(() => !document.querySelector("#refreshButton").disabled && !document.querySelector("#subtitle").textContent.includes("读取失败"));
    assert.equal(await page.locator("#toast").evaluate((element) => element.classList.contains("show")), false);
    assert.equal(await page.locator("#toast").textContent(), "");
    report.checks.push("real manual-refresh failure propagates across IPC, restores controls and clears after recovery");

    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().find((window) => !window.webContents.getURL().includes("card.html")).setSize(1120, 1000));
    for (const mode of ["dark", "light"]) {
      await page.evaluate((themeMode) => window.suanli.setSettings({ themeMode }), mode);
      await page.waitForFunction((mode) => document.body.dataset.theme === mode, mode);
      await page.locator('[data-section="insights"]').click();
      await page.locator("#budgetLimit").fill("3,000,000");
      await page.evaluate(() => { document.querySelector(".scroll-area").scrollTop = 0; document.querySelector("#toast").classList.remove("show"); });
      const file = path.join(output, "optimization-" + mode + ".png");
      await page.screenshot({ path: file }); report.screenshots.push(file);
    }
    await page.locator("#removeBudget").click();
    await page.waitForFunction(() => document.querySelector("#budgetFeedback").textContent === "预算已删除");
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(profile, "project-budgets-v1.json"), "utf8")), []);
    assert.equal(await page.locator("#budgetLimit").inputValue(), "");
    report.checks.push("explicit remove persists deletion and clears the form after success");
    assert.deepEqual(errors, []);
    report.passed = true;
  } catch (error) {
    report.failure = error.stack || error.message;
    throw error;
  } finally {
    report.completedAt = new Date().toISOString();
    writeJSON(path.join(output, "report.json"), report);
    await app.close();
  }
  console.log(JSON.stringify(report, null, 2));
})().catch((error) => { console.error(error); process.exitCode = 1; });
