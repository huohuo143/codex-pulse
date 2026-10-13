const fs = require("node:fs"), path = require("node:path"), assert = require("node:assert/strict");
const { _electron: electron } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
(async () => {
  const root = path.resolve(process.argv[2] || path.join(__dirname, ".."));
  const scale = process.env.PULSE_TEST_SCALE || "1.75", output = path.join(root, "gauge-validation-scale-" + scale);
  const profile = path.join(output, "profile-" + Date.now()); fs.mkdirSync(path.join(profile, "sessions"), { recursive: true });
  const env = { ...process.env, CODEX_PULSE_SUPPORT_DIR: profile, CODEX_PULSE_SESSION_ROOT: path.join(profile, "sessions"), CODEX_PULSE_OFFLINE: "1", CODEX_PULSE_ACCEPTANCE: "0" };
  delete env.ELECTRON_RUN_AS_NODE;
  const executablePath = process.env.PULSE_TEST_EXECUTABLE || path.join(root, "node_modules/electron/dist/electron.exe");
  const app = await electron.launch({ executablePath, cwd: root, args: [...(process.env.PULSE_TEST_EXECUTABLE ? [] : [root]), "--force-device-scale-factor=" + scale], env });
  const failures = [], reports = [], errors = [];
  // Measure text rectangles against the inner edge of the nearest circular stroke.
  const inspect = () => {
    const gauge = [...document.querySelectorAll(".gauge,.card-ring")].find(e => e.getBoundingClientRect().width && getComputedStyle(e).display !== "none" && e.closest("main").getBoundingClientRect().width);
    const box = gauge.querySelector("svg").getBoundingClientRect(), svg = gauge.querySelector("svg");
    const circles = [...svg.querySelectorAll("circle")].filter(c => getComputedStyle(c).display !== "none");
    const radius = Math.min(...circles.map(c => (Number(c.getAttribute("r")) - parseFloat(getComputedStyle(c).strokeWidth) / 2) * box.width / svg.viewBox.baseVal.width));
    const cx = box.left + box.width / 2, cy = box.top + box.height / 2;
    const center = gauge.querySelector(".gauge-center,.center"), overlaps = [];
    if (document.body.classList.contains("compact") && !document.body.classList.contains("show-five") && gauge.querySelector(".five-label")?.getBoundingClientRect().height)
      overlaps.push({ text: "未启用的5小时额度仍然显示" });
    const walker = document.createTreeWalker(center, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (!node.textContent.trim()) continue;
      const range = document.createRange(); range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (!rect.width || !rect.height) continue;
        const farthest = Math.max(...[rect.left, rect.right].flatMap(x => [rect.top, rect.bottom].map(y => Math.hypot(x - cx, y - cy))));
        if (farthest > radius - 0.25) overlaps.push({ text: node.textContent, radius, farthest });
      }
    }
    const reset = gauge.closest(".compact-quota")?.querySelector(".gauge-reset");
    const resetBox = reset?.getBoundingClientRect(), gaugeBox = gauge.getBoundingClientRect();
    if (resetBox?.height && resetBox.top < gaugeBox.bottom) overlaps.push({ text: reset.textContent, outsideCountdown: false });
    return { radius, overlaps, reset: reset?.textContent };
  };
  try {
    const page = await app.firstWindow(); page.on("pageerror", e => errors.push(e.message));
    await page.waitForFunction(() => typeof renderMacAligned === "function" && !status?.statisticsLoading);
    await page.evaluate(() => window.suanli.setSettings({ floatingEnabled: true, themeMode: "dark", compactShowsResetCredits: true }));
    await page.waitForTimeout(200);
    const floating = app.windows().find(w => w.url().includes("surface=floating"));
    assert.ok(floating); floating.on("pageerror", e => errors.push(e.message));
    await floating.waitForFunction(() => document.body.classList.contains("compact") && typeof renderMacAligned === "function");
    for (const style of ["rings-horizontal", "rings-vertical", "circle"]) for (const size of ["standard", "mini"]) for (const mode of ["weekly", "both", "five"]) for (const value of [100, null]) {
      const config = { compactStyle: style.startsWith("rings") ? "rings" : "circle", compactRingOrientation: style.endsWith("vertical") ? "vertical" : "horizontal", compactSizeMode: size, showWeekly: mode !== "five", showFiveHour: mode !== "weekly" };
      await page.evaluate(config => window.suanli.setSettings(config), config);
      await floating.waitForFunction(config => document.body.dataset.size === config.compactSizeMode && document.body.dataset.compactStyle === config.compactStyle && document.body.classList.contains("show-five") === config.showFiveHour, config);
      await floating.evaluate(value => {
        document.querySelectorAll(".gauge-value,.five-value").forEach(e => e.style.transition = "none");
        const sample = structuredClone(status); sample.statisticsLoading = false;
        sample.weekly = { remainingPercent: value, resetsAt: new Date(Date.now() + 7 * 86400000 - 1000).toISOString() };
        sample.fiveHour = { remainingPercent: value, resetsAt: new Date(Date.now() + 5 * 3600000 - 1000).toISOString() };
        sample.tokenStats.rolling24HoursTokens = 1234567; renderStatus(sample);
      }, value);
      const result = await floating.evaluate(inspect), name = [style, size, mode, value ?? "missing"].join("-");
      reports.push({ name, ...result });
      if (result.overlaps.length) failures.push({ name, ...result });
      if (value === 100 || result.overlaps.length) await floating.screenshot({ path: path.join(output, name + ".png") });
    }
    for (const width of [640, 880]) for (const five of [false, true]) {
      await page.evaluate(five => window.suanli.setSettings({ showFiveHour: five, showWeekly: true }), five);
      await app.evaluate(({ BrowserWindow }, width) => BrowserWindow.getAllWindows().find(w => !w.webContents.getURL().includes("surface=floating")).setSize(width, 860), width);
      await page.waitForFunction(width => Math.abs(innerWidth - width) <= 2, width);
      await page.evaluate(() => { const sample = structuredClone(status); sample.weekly = { remainingPercent: 100 }; sample.fiveHour = { remainingPercent: 100 }; renderStatus(sample); });
      const result = await page.evaluate(inspect), name = "main-" + width + "-" + five;
      reports.push({ name, ...result }); if (result.overlaps.length) failures.push({ name, ...result });
    }
    for (const five of [false, true]) {
      await page.evaluate(five => window.suanli.setSettings({ cardFiveHour: five }), five);
      await page.evaluate(() => window.suanli.setCard({ type: "quota", enabled: true }));
      await page.waitForTimeout(100);
      const card = app.windows().find(w => w.url().includes("card.html?surface=quota"));
      await card.waitForFunction(() => !!document.querySelector(".card-ring"));
      await card.evaluate(() => { const sample = structuredClone(status); sample.weekly = { remainingPercent: 100 }; sample.fiveHour = { remainingPercent: 100 }; render(sample); });
      const result = await card.evaluate(inspect), name = "card-" + five;
      reports.push({ name, ...result }); if (result.overlaps.length) failures.push({ name, ...result });
    }
    fs.writeFileSync(path.join(output, "report.json"), JSON.stringify({ scale, cases: reports.length, failures, reports, errors }, null, 2));
    assert.deepEqual(errors, []); assert.deepEqual(failures, []);
    console.log(JSON.stringify({ passed: true, scale, cases: reports.length, failures: failures.length }));
  } finally { await app.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
