const fs = require("node:fs");
const path = require("node:path");
const { _electron: electron } = require(
  process.env.PLAYWRIGHT_MODULE || "playwright",
);
(async () => {
  const root = path.resolve(process.argv[2] || path.join(__dirname, "..")),
    output = path.join(root, "ui-validation" + (process.env.PULSE_TEST_SCALE ? "-scale-" + process.env.PULSE_TEST_SCALE : ""));
  fs.mkdirSync(output, { recursive: true });
  const support = path.join(output, "profile-" + Date.now());
  fs.mkdirSync(support, { recursive: true });
  const sessions = path.join(support, "sessions");
  fs.mkdirSync(sessions, { recursive: true });
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({
    cwd: root,
    executablePath: process.env.PULSE_TEST_EXECUTABLE || path.join(root, "node_modules/electron/dist/electron.exe"),
    args: [...(process.env.PULSE_TEST_EXECUTABLE ? [] : [root]), ...(process.env.PULSE_TEST_SCALE ? ["--force-device-scale-factor="+process.env.PULSE_TEST_SCALE] : [])],
    env: {
      ...env,
      CODEX_PULSE_SUPPORT_DIR: support,
      CODEX_PULSE_SESSION_ROOT: sessions,
      CODEX_PULSE_OFFLINE: "1",
      CODEX_PULSE_ACCEPTANCE: "0",
    },
    timeout: 60000,
  });
  const errors = [];
  app.on("window", (w) => {
    w.on("pageerror", (e) => errors.push(e.message));
  });
  try {
    const page = await app.firstWindow();
    page.on("pageerror", (e) => errors.push(e.message));
    await page.waitForFunction(
      () =>
        window.suanli &&
        document.querySelector("#newSettings")?.children.length > 0,
    );
    await page.waitForFunction(async () => !(await window.suanli.bootstrap()).status.statisticsLoading, { timeout: 30000 });
    const deviceScale = await page.evaluate(() => window.devicePixelRatio);
    if (process.env.PULSE_TEST_SCALE && Math.abs(deviceScale - Number(process.env.PULSE_TEST_SCALE)) > 0.05) throw new Error("device scale mismatch: " + deviceScale);
    await page.evaluate(async () => {
      const sample = (await window.suanli.bootstrap()).status;
      sample.statisticsLoading = false;
      sample.weekly = {
        remainingPercent: 67,
        windowMinutes: 10080,
        resetsAt: new Date(Date.now() + 3 * 86400000).toISOString(),
      };
      sample.fiveHour = {
        remainingPercent: 42,
        windowMinutes: 300,
        resetsAt: new Date(Date.now() + 7200000).toISOString(),
      };
      sample.sourceStates = {
        quota: "fresh",
        fiveHour: "fresh",
        flexible: "fresh",
        reset: "fresh",
      };
      sample.flexible = { balanceCredits: 2500, amountUSD: 100 };
      sample.forecast = {
        risk: "healthy",
        reason: "按当前节奏，额度预计可撑到重置",
        ratePerHour: 0.4,
        balancedDailyPercent: 22.3,
        sampleCount: 18,
        estimatedExhaustion: new Date(Date.now() + 7 * 86400000).toISOString(),
        earliestExhaustion: new Date(Date.now() + 5 * 86400000).toISOString(),
        latestExhaustion: new Date(Date.now() + 9 * 86400000).toISOString(),
      };
      sample.rateLimitResetCredits = {
        availableCount: 2,
        availableCredits: [
          {
            title: "Full reset",
            grantedAt: new Date().toISOString(),
            expiresAt: new Date(Date.now() + 86400000).toISOString(),
          },
        ],
      };
      sample.tokenStats.rolling24HoursTokens = 1234567;
      sample.tokenStats.todayTokens = 700000;
      sample.tokenStats.monthTokens = 8250000;
      sample.tokenStats.last7DaysTokens = 4300000;
      sample.tokenStats.costMonth = {
        usd: 68,
        coverage: 0.8,
        isPartial: true,
        unpricedTokens: 1000,
        unpricedModels: ["future-model"],
        priceVersion: "fixture",
      };
      sample.tokenStats.cost24Hours = {
        usd: 13,
        coverage: 1,
        isPartial: false,
      };
      sample.tokenStats.cost7Days = { usd: 34, coverage: 1, isPartial: false };
      sample.tokenStats.daily.forEach(
        (r, i) => (r.totalTokens = (i + 1) * 10000),
      );
      window.__testSample = sample;
      renderStatus(sample);
    });
    for (const appearance of ["aurora", "glass", "graphite"]) {
      for (const palette of ["mintDawn", "seaSaltBlue", "forestSoda", "peachSunset", "wisteriaNight", "lemonHarbor"]) {
        await page.evaluate(values => window.suanli.setSettings(values), { appearance, palette });
        await page.waitForFunction(values => document.body.dataset.appearance === values.appearance && document.body.dataset.palette === values.palette, { appearance, palette });
      }
    }
    await page.evaluate(() => window.suanli.setSettings({ appearance: "aurora", palette: "mintDawn", themeMode: "system" }));
    for (const mode of ["dark", "light"]) {
      await app.evaluate(({nativeTheme}, mode) => { nativeTheme.themeSource = mode; }, mode);
      await page.waitForFunction(mode => document.body.dataset.theme === mode, mode);
    }
    await app.evaluate(({nativeTheme}) => { nativeTheme.themeSource = "system"; });
    for (const section of ["overview", "trends", "insights", "settings"]) {
      await page.locator('[data-section="' + section + '"]').click();
      await page.evaluate(() => renderStatus(window.__testSample));
      await page.screenshot({ path: path.join(output, section + ".png") });
    }
    await page.evaluate(() =>
      window.suanli.setSettings({ showFiveHour: true, themeMode: "light" }),
    );
    await page.locator('[data-section="overview"]').click();
    await page.screenshot({ path: path.join(output, "overview-light.png") });
    await app.evaluate(({ BrowserWindow }) => {
      const w = BrowserWindow.getAllWindows()[0];
      w.setSize(640, 760);
    });
    await page.waitForFunction(() => Math.abs(window.innerWidth - 640) <= 2);
    await page.evaluate(() => document.querySelector(".scroll-area").scrollTop = 0);
    await page.screenshot({ path: path.join(output, "overview-minimum.png") });
    await page.evaluate(() =>
      window.suanli.setSettings({ floatingEnabled: true, themeMode: "dark" }),
    );
    await page.waitForTimeout(400);
    let floating = app
      .windows()
      .find((w) => w.url().includes("surface=floating"));
    if (!floating) {
      await page.waitForTimeout(700);
      floating = app
        .windows()
        .find((w) => w.url().includes("surface=floating"));
    }
    if (!floating) throw new Error("floating window missing");
    await floating.waitForFunction(() =>
      document.body.classList.contains("compact"),
    );
    for (const style of [
      "rings",
      "circle",
      "square",
      "pill",
      "bars",
      "barsQuad",
      "badge",
      "badgeQuad",
    ]) {
      await page.evaluate(
        (style) => window.suanli.setSettings({ compactStyle: style }),
        style,
      );
      await page.waitForTimeout(150);
      await floating.evaluate(async () => {
        const data = (await window.suanli.bootstrap()).status;
        data.weekly = { remainingPercent: 67 };
        data.fiveHour = { remainingPercent: 42 };
        data.tokenStats.rolling24HoursTokens = 1234567;
        renderStatus(data);
      });
      await floating.screenshot({
        path: path.join(output, "floating-" + style + ".png"),
      });
    }
    for (const type of [
      "overview",
      "quota",
      "radar",
      "credits",
      "tokens",
      "trend",
      "projects",
    ]) {
      await page.evaluate(
        (type) => window.suanli.setCard({ type, enabled: true }),
        type,
      );
      await page.waitForTimeout(300);
      const card = app
        .windows()
        .find((w) => w.url().includes("card.html?surface=" + type));
      if (!card) throw new Error("card missing " + type);
      await card.waitForFunction(
        () =>
          document.querySelector("#cardTitle")?.textContent !== "Codex 脉动",
      );
      await card.evaluate(async () => {
        const data = (await window.suanli.bootstrap()).status;
        data.weekly = { remainingPercent: 67 };
        data.fiveHour = { remainingPercent: 42 };
        data.tokenStats.rolling24HoursTokens = 1234567;
        render(data);
      });
      await card.screenshot({
        path: path.join(output, "card-" + type + ".png"),
      });
      await card.locator("#pin").click();
      const actualBounds = await app.evaluate(({ BrowserWindow }, type) => {
        const w = BrowserWindow.getAllWindows().find(w => w.webContents.getURL().includes("card.html?surface=" + type));
        if (!w.isAlwaysOnTop()) throw new Error("pin was not applied");
        const b = w.getBounds();
        w.setBounds({ x: b.x + 20, y: b.y + 20, width: 420, height: 400 });
        return w.getBounds();
      }, type);
      await card.waitForTimeout(450);
      const savedBounds = await card.evaluate(async type => (await window.suanli.bootstrap()).settings.cards[type].bounds, type);
      if (!savedBounds || ["x", "y", "width", "height"].some(key => Math.abs(actualBounds[key] - savedBounds[key]) > 1)) throw new Error("card bounds were not saved: " + type + " actual=" + JSON.stringify(actualBounds) + " saved=" + JSON.stringify(savedBounds));
      await card.locator("#close").click();
    }
    const sandbox = await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().map((w) => ({
        sandbox: w.webContents.getLastWebPreferences().sandbox,
        contextIsolation:
          w.webContents.getLastWebPreferences().contextIsolation,
        nodeIntegration: w.webContents.getLastWebPreferences().nodeIntegration,
      })),
    );
    if (
      sandbox.some(
        (w) => !w.sandbox || !w.contextIsolation || w.nodeIntegration,
      )
    )
      throw new Error("sandbox mismatch");
    await page.evaluate(() =>
      window.suanli.setSettings({ floatingEnabled: false }),
    );
    await page.locator("#closeButton").click();
    const stillRunning = await app.evaluate(
      ({ BrowserWindow }) => BrowserWindow.getAllWindows().length > 0,
    );
    if (!stillRunning) throw new Error("tray lifecycle failure");
    fs.writeFileSync(
      path.join(output, "report.json"),
      JSON.stringify(
        {
          errors,
          deviceScale,
          sandbox,
          checks: [
            "four sections",
            "light mode",
            "system theme changes",
            "three appearances and six palettes",
            "minimum size",
            "eight floating styles",
            "seven desktop cards",
            "pin and hide",
            "card move/resize persistence",
            "tray lifecycle",
          ],
          completedAt: new Date().toISOString(),
        },
        null,
        2,
      ),
    );
    if (errors.length) throw new Error(errors.join("; "));
    console.log(JSON.stringify({ passed: true, screenshots: output, errors }));
  } finally {
    await app.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
