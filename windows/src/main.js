const {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Tray,
  nativeImage,
  screen,
  shell,
  dialog,
  clipboard,
  Notification,
  powerMonitor,
  nativeTheme,
} = require("electron");
const path = require("node:path");
const fs = require("node:fs");
const { execFile } = require("node:child_process");
const { Runtime } = require("./core/runtime");
const { Store, writeJSON } = require("./core/storage");
const {
  DEFAULTS,
  CARD_TYPES,
  validatePatch,
  visibleBounds,
  migrateSettings,
} = require("./core/settings");
const pricing = require("./core/model-pricing");
const { makeCSV } = require("./core/csv-exporter");
const quotaHistory = require("./core/quota-history");
const APP_NAME = "Codex 脉动",
  APP_ID = "dev.codex.balance-dashboard.codex.windows";
const CARD_LABELS = {
  overview: "Codex 算力总览",
  quota: "Codex 额度",
  radar: "Codex 重置雷达",
  credits: "Full reset 权益",
  tokens: "Token 汇总",
  trend: "Token 趋势",
  projects: "项目与用途",
};
const windows = new Map();
let tray,
  runtime,
  store,
  settings = { ...DEFAULTS },
  quitting = false,
  boundsTimer,
  watcherTimer,
  monitorTimer,
  previewPending = null;
const isolation = process.env.CODEX_PULSE_SUPPORT_DIR;
const oldRoots = ["Codex算力码表", "suanli-dashboard-windows"].map((n) =>
  path.join(app.getPath("appData"), n),
);
const dataRoot =
  isolation ||
  oldRoots.find((d) => fs.existsSync(path.join(d, "settings.json"))) ||
  oldRoots[0];
app.setPath("userData", dataRoot);
app.setName(APP_NAME);
app.setAppUserModelId(APP_ID);
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => showMain());
  app
    .whenReady()
    .then(start)
    .catch((error) => {
      dialog.showErrorBox("Codex 脉动启动失败", error.message);
      app.quit();
    });
}
function workAreas() {
  return screen.getAllDisplays().map((d) => d.workArea);
}
function safeSend(win, channel, value) {
  if (win && !win.isDestroyed() && !win.webContents.isDestroyed())
    win.webContents.send(channel, value);
}
function broadcast(channel, value) {
  for (const [key, win] of windows)
    safeSend(
      win,
      channel,
      channel === "settings-changed" ? windowSettings(key) : value,
    );
}
function windowSettings(key) {
  return {
    ...settings,
    compact: key === "floating",
    surface: key,
    systemDark: nativeTheme.shouldUseDarkColors,
  };
}
function compactSize() {
  const mini = settings.compactSizeMode === "mini",
    vertical = settings.compactRingOrientation === "vertical";
  const sizes = {
    rings: vertical
      ? [mini ? 210 : 250, mini ? 365 : 450]
      : [mini ? 330 : 400, mini ? 240 : 290],
    circle: [mini ? 164 : 210, mini ? 164 : 210],
    square: [mini ? 190 : 225, mini ? 230 : 270],
    pill: [mini ? 360 : 440, mini ? 90 : 110],
    bars: [mini ? 335 : 405, mini ? 95 : 120],
    barsQuad: [mini ? 350 : 435, mini ? 118 : 150],
    badge: [mini ? 205 : 235, mini ? 70 : 85],
    badgeQuad: [mini ? 320 : 385, mini ? 70 : 85],
  };
  const [width, height] = sizes[settings.compactStyle] || sizes.rings;
  return { width, height: height + (settings.showRadar ? 72 : 0) };
}
function newWindow(key) {
  if (windows.has(key)) return windows.get(key);
  const isMain = key === "main",
    isFloat = key === "floating",
    card = settings.cards[key] || {},
    size = isFloat
      ? compactSize()
      : isMain
        ? { width: 880, height: 860 }
        : { width: 380, height: 360 };
  const saved = isMain
    ? settings.mainBounds || settings.bounds
    : isFloat
      ? settings.floatingBounds
      : card.bounds;
  const bounds = visibleBounds(
    { ...size, ...saved },
    workAreas(),
    isMain
      ? { width: 640, height: 760 }
      : isFloat
        ? size
        : { width: 280, height: 220 },
  );
  const win = new BrowserWindow({
    ...bounds,
    minWidth: isMain ? 640 : isFloat ? size.width : 280,
    minHeight: isMain
      ? Math.min(760, bounds.height)
      : isFloat
        ? size.height
        : 220,
    frame: false,
    transparent: !isMain,
    backgroundColor: isMain ? "#10191f" : "#00000000",
    resizable: !isFloat,
    show: false,
    alwaysOnTop: isMain
      ? false
      : isFloat
        ? settings.alwaysOnTop
        : !!card.alwaysOnTop,
    skipTaskbar: !isMain,
    title: isMain ? APP_NAME : CARD_LABELS[key] || APP_NAME,
    icon: path.join(__dirname, "../assets/icon.png"),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  windows.set(key, win);
  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", (e) => e.preventDefault());
  win.webContents.on("will-attach-webview", (e) => e.preventDefault());
  win.loadFile(
    path.join(
      __dirname,
      "renderer",
      CARD_TYPES.includes(key) ? "card.html" : "index.html",
    ),
    { query: { surface: key } },
  );
  win.once("ready-to-show", () => {
    if (isMain && process.argv.includes("--watch-codex")) return;
    win.show();
  });
  win.on("close", (e) => {
    if (quitting) return;
    e.preventDefault();
    win.hide();
    if (isFloat) saveSettings({ floatingEnabled: false });
    else if (!isMain) {
      settings.cards[key] = { ...settings.cards[key], enabled: false };
      saveSettings();
    }
    broadcast("settings-changed", settings);
  });
  const saveBounds = () => {
    clearTimeout(boundsTimer);
    boundsTimer = setTimeout(() => {
      for (const [k, w] of windows) {
        if (w.isDestroyed() || w.isMinimized()) continue;
        const b = w.getNormalBounds();
        if (k === "main") settings.mainBounds = b;
        else if (k === "floating") settings.floatingBounds = b;
        else settings.cards[k] = { ...settings.cards[k], bounds: b };
      }
      saveSettings();
    }, 300);
  };
  win.on("move", saveBounds);
  win.on("resize", saveBounds);
  win.webContents.on("render-process-gone", () => {
    runtime?.event("failure", "显示进程中断，已重新加载");
    if (!quitting) win.reload();
  });
  return win;
}
function showMain(section) {
  const w = newWindow("main");
  if (section) {
    saveSettings({ selectedSection: section });
    broadcast("settings-changed", settings);
  }
  w.show();
  if (w.isMinimized()) w.restore();
  w.focus();
}
function showFloating(enabled) {
  saveSettings({ floatingEnabled: enabled });
  const w = enabled ? newWindow("floating") : windows.get("floating");
  if (w) {
    if (enabled) w.show();
    else w.hide();
  }
  broadcast("settings-changed", settings);
  return enabled;
}
function setCard({ type, enabled, alwaysOnTop }) {
  if (
    !CARD_TYPES.includes(type) ||
    (enabled !== undefined && typeof enabled !== "boolean") ||
    (alwaysOnTop !== undefined && typeof alwaysOnTop !== "boolean")
  )
    throw new Error("桌面卡片选项无效");
  const item = { ...(settings.cards[type] || {}) };
  if (enabled !== undefined) item.enabled = enabled;
  if (alwaysOnTop !== undefined) item.alwaysOnTop = alwaysOnTop;
  settings.cards[type] = item;
  saveSettings();
  let w = windows.get(type);
  if (item.enabled) w = newWindow(type);
  if (w) {
    w.setAlwaysOnTop(!!item.alwaysOnTop);
    if (item.enabled) w.show();
    else w.hide();
  }
  broadcast("settings-changed", settings);
  return item;
}
function saveSettings(patch = {}) {
  settings = { ...settings, ...patch };
  store.write("settings", settings);
  if (runtime) runtime.settings = settings;
  return settings;
}
function applySettings(patch) {
  patch = validatePatch(patch);
  if (
    patch.showWeekly === false &&
    patch.showTokens === false &&
    patch.showRadar === false &&
    patch.showFiveHour === false &&
    patch.compactShowsResetCredits === false
  )
    throw new Error("至少保留一个悬浮指标");
  const merged = { ...settings, ...patch };
  if (
    ![
      merged.showWeekly,
      merged.showTokens,
      merged.showRadar,
      merged.showFiveHour,
      merged.compactShowsResetCredits,
    ].some(Boolean)
  )
    throw new Error("至少保留一个悬浮指标");
  saveSettings(patch);
  const floating = windows.get("floating");
  if (floating) {
    floating.setAlwaysOnTop(settings.alwaysOnTop);
    const s = compactSize();
    floating.setMinimumSize(s.width, s.height);
    floating.setSize(s.width, s.height);
  }
  if ("floatingEnabled" in patch) showFloating(settings.floatingEnabled);
  if ("launchAtLogin" in patch || "launchWithCodex" in patch) {
    if (!isolation) {
      const exe = process.env.PORTABLE_EXECUTABLE_FILE || process.execPath;
      app.setLoginItemSettings({
        openAtLogin: settings.launchAtLogin || settings.launchWithCodex,
        path: exe,
        args: ["--watch-codex"],
      });
    }
    setupWatcher();
  }
  broadcast("settings-changed", settings);
  runtime?.publish();
  updateTray();
  return settings;
}
function updateTray() {
  if (!tray) return;
  const state = runtime?.state;
  const remaining = state?.weekly?.remainingPercent;
  tray.setToolTip(
    APP_NAME +
      " · " +
      (remaining == null
        ? "等待额度数据"
        : "7 天剩余 " + Math.round(remaining) + "%"),
  );
  tray.setContextMenu(
    Menu.buildFromTemplate([
      {
        label:
          remaining == null
            ? "暂无当前额度"
            : "7 天剩余 " +
              Math.round(remaining) +
              "% · " +
              ({
                healthy: "充足",
                caution: "需关注",
                critical: "高风险",
                insufficientData: "学习中",
              }[state?.forecast?.risk] || "学习中"),
        enabled: false,
      },
      { label: "打开主窗口", click: () => showMain() },
      {
        label: "显示悬浮框",
        type: "checkbox",
        checked: settings.floatingEnabled,
        click: (i) => showFloating(i.checked),
      },
      {
        label: "桌面卡片",
        submenu: CARD_TYPES.map((type) => ({
          label: CARD_LABELS[type],
          type: "checkbox",
          checked: !!settings.cards[type]?.enabled,
          click: (i) => setCard({ type, enabled: i.checked }),
        })),
      },
      {
        label: "立即刷新",
        click: () => runtime.refresh({ force: true, forceRadar: true }),
      },
      { label: '打开重置日历', click: () => showMain('calendar') },
      { label: "复制用量摘要", click: copySummary },
      { label: "提醒设置", click: () => showMain("settings") },
      { type: "separator" },
      ...(state?.updates?.available
        ? [
            {
              label: "查看更新 " + state.updates.version,
              click: () => openExternal(state.updates.url),
            },
          ]
        : []),
      {
        label: "退出 Codex 脉动",
        click: () => {
          quitting = true;
          app.quit();
        },
      },
    ]),
  );
}
function copySummary() {
  const s = runtime.state,
    t = s.tokenStats,
    c = t.costMonth;
  const cost = c.isUnavailable
    ? "暂无法估算"
    : "$" +
      c.usd.toFixed(2) +
      (c.isPartial
        ? "（部分估算，覆盖 " + Math.round(c.coverage * 100) + "%）"
        : "");
  clipboard.writeText(
    [
      APP_NAME + " " + app.getVersion(),
      "7 天剩余：" +
        (s.weekly ? Math.round(s.weekly.remainingPercent) + "%" : "--"),
      "滚动 24h：" +
        (s.statisticsLoading
          ? "统计中"
          : t.rolling24HoursTokens.toLocaleString()) +
        " Token",
      "近 7 天：" + t.last7DaysTokens.toLocaleString() + " Token",
      "本月：" + t.monthTokens.toLocaleString() + " Token",
      "按当前价格表折算：" + cost,
      "价格版本：" + c.priceVersion,
      "API 等价估算，不是订阅账单",
    ].join("\n"),
  );
  broadcast("toast", "用量摘要已复制");
  return true;
}
async function exportCSV() {
  const r = await dialog.showSaveDialog(windows.get("main"), {
    title: "导出 Codex 用量",
    defaultPath: "codex-usage.csv",
    filters: [{ name: "CSV", extensions: ["csv"] }],
  });
  if (r.canceled) return null;
  fs.writeFileSync(
    r.filePath,
    makeCSV(runtime.state.tokenStats, {
      cnyRate: runtime.state.exchangeRate?.rate,
    }),
  );
  return r.filePath;
}
function openExternal(target) {
  if (typeof target !== "string" || target.length > 2048)
    throw new Error("无效链接");
  const u = new URL(target);
  if (
    u.protocol !== "https:" ||
    u.username ||
    u.password ||
    ![
      "github.com",
      "codexradar.com",
      "x.com",
      "www.x.com",
      'codex-reset.com',
      'resetcue.com',
      'tibo.modelyard.dev',
      'creativecommons.org',
      "developers.openai.com",
      "help.openai.com",
      "frankfurter.dev",
    ].includes(u.hostname)
  )
    throw new Error("不支持此链接");
  return shell.openExternal(u.href);
}
const capabilities = require('./core/local-capabilities');
const xSource = new (require('./core/x-source').XSource)();
function register() {
  const handle = (name, fn) =>
    ipcMain.handle(name, async (e, ...args) => {
      const entry = [...windows].find(([, w]) => w.webContents === e.sender);
      if (!entry) throw new Error("未知窗口");
      return fn(entry[0], ...args);
    });
  runtime.radar.xSource = () => xSource.fetch();
  handle('local-capabilities', () => capabilities.inspect());
  handle('tibo-preferences', (_, value) => {
    if (value) { capabilities.save(store, value); if (!value.enabled) runtime.radar.analysisController?.abort(); runtime.radar.synchronizeSource(); runtime.publish(); }
    return capabilities.preferences(store);
  });
  handle('open-x', () => xSource.show());
  handle("get-bootstrap", (key) => ({
    settings: windowSettings(key),
    platform: process.platform,
    version: app.getVersion(),
    build: 2157,
    status: runtime.state,
    radar: runtime.state.radar,
    exchangeRate: runtime.state.exchangeRate,
  }));
  handle("refresh", (_, options) =>
    runtime.refresh({ force: true, forceRadar: !!options?.forceRadar }),
  );
  handle("refresh-radar", (_, force) => runtime.refreshRadar(!!force));
  handle("set-compact", (_, value) => {
    if (value) showFloating(true);
    else showMain();
    return !!value;
  });
  handle("set-settings", (_, patch) => applySettings(patch));
  handle("set-card", (_, patch) => setCard(patch));
  handle("copy-summary", copySummary);
  handle("export-csv", exportCSV);
  handle("export-quota-history", async (_, days) => {
    if (![1, 7, 30].includes(days)) throw new Error("未知历史范围");
    const scope = runtime.scope;
    const rows = quotaHistory.points(runtime.history, days, runtime.now());
    if (!rows.length) throw new Error("当前范围暂无官方额度样本");
    const r = await dialog.showSaveDialog(windows.get("main"), {
      title: "导出官方额度历史", defaultPath: "codex-quota-history-" + days + "d.csv", filters: [{ name: "CSV", extensions: ["csv"] }],
    });
    if (r.canceled) return null;
    if (scope !== runtime.scope) throw new Error("账户已切换，请重新导出");
    fs.writeFileSync(r.filePath, quotaHistory.makeCSV(rows));
    return r.filePath;
  });
  handle("window-action", (key, action) => {
    const w = windows.get(key);
    if (action === "close") w.close();
    else if (action === "minimize") w.minimize();
    else if (action === "maximize") w.isMaximized() ? w.unmaximize() : w.maximize();
    else if (action === "main") showMain();
  });
  handle("open-path", () =>
    shell.openPath(
      runtime.official.home
        ? path.join(runtime.official.home, "sessions")
        : dataRoot,
    ),
  );
  handle("open-external", (_, url) => openExternal(url));
  handle("show-section", (_, section) => {
    if (!["overview", "trends", "insights", 'calendar', "settings"].includes(section))
      throw new Error("未知页面");
    showMain(section);
  });
  handle("set-budget", (_, value) => runtime.setBudget(value));
  handle("set-expiry", (_, value) => runtime.setExpiry(value));
  handle("set-expiry-batch", (_, value) => runtime.setExpiryBatch(value));
  handle('record-action', (_, value) => runtime.recordAction(value));
  handle('open-records', () => shell.openPath(dataRoot));
  handle("network-online", () => { runtime.radar.networkRestored(); return runtime.refreshRadar(); });
  handle("mark-radar", (_, value) => {
    const result = runtime.radar.mark(value);
    runtime.publish();
    return result;
  });
  handle("check-updates", () => runtime.checkUpdates(true));
  handle("set-detail", (_, value) => {
    if (
      !["evidence", "tibo", "models"].includes(value?.id) ||
      typeof value.open !== "boolean"
    )
      throw new Error("未知详情");
    settings.expandedDetails[value.id] = value.open;
    saveSettings();
    broadcast("settings-changed", settings);
  });
  handle("preview-prices", async () => {
    const r = await dialog.showOpenDialog(windows.get("main"), {
      title: "导入模型价格表",
      properties: ["openFile"],
      filters: [{ name: "JSON", extensions: ["json"] }],
    });
    if (r.canceled) return null;
    const file = r.filePaths[0];
    if (fs.statSync(file).size > 1048576) throw new Error("价格文件过大");
    const result = pricing.preview(JSON.parse(fs.readFileSync(file, "utf8")));
    previewPending = { ...result, token: require("node:crypto").randomUUID() };
    return { token: previewPending.token, changes: result.changes };
  });
  handle("apply-prices", async (_, token) => {
    if (!previewPending || token !== previewPending.token)
      throw new Error("请重新预览价格表");
    const table = previewPending.table;
    store.write("model-prices-v1", table);
    pricing.setPriceTable(table);
    previewPending = null;
    await runtime.statistics(true);
    return true;
  });
  handle("export-diagnostics", async () => {
    const r = await dialog.showSaveDialog(windows.get("main"), {
      title: "导出脱敏诊断",
      defaultPath: "codex-pulse-diagnostics.json",
      filters: [{ name: "JSON", extensions: ["json"] }],
    });
    if (r.canceled) return null;
    writeJSON(r.filePath, runtime.diagnostics());
    return r.filePath;
  });
  handle("recover", async () => {
    runtime.event("recovery", "用户发起重新检查");
    await Promise.allSettled([
      runtime.refresh({ force: true }),
      runtime.statistics(true),
      runtime.refreshRadar(true),
    ]);
    return runtime.diagnostics();
  });
}
async function codexRunning() {
  return new Promise((resolve) =>
    execFile(
      "tasklist.exe",
      ["/FO", "CSV", "/NH"],
      { windowsHide: true, timeout: 5000 },
      (err, out = "") => {
        runtime.launchWatcherFailure = !!err;
        resolve(!err && /"(?:Codex|ChatGPT)\.exe"/i.test(out));
      },
    ),
  );
}
function setupWatcher() {
  clearInterval(watcherTimer);
  let previous = false;
  const check = async () => {
    if (!settings.launchWithCodex) return;
    const running = await codexRunning();
    if (running && !previous && settings.floatingEnabled)
      newWindow("floating").showInactive();
    previous = running;
  };
  if (settings.launchWithCodex) {
    check();
    watcherTimer = setInterval(check, 10000);
  }
}
function restoreWindows() {
  for (const [key, w] of windows) {
    const b = visibleBounds(
      w.getBounds(),
      workAreas(),
      key === "main"
        ? {
            width: 640,
            height: Math.min(760, screen.getPrimaryDisplay().workArea.height),
          }
        : key === "floating"
          ? compactSize()
          : { width: 280, height: 220 },
    );
    w.setBounds(b);
  }
}
async function start() {
  require('./core/upgrade-backup').backupBeforeUpgrade(dataRoot, app.getVersion(), 2157);
  store = new Store(dataRoot);
  const old = store.read("settings", {});
  if (old.schemaVersion !== 2118 && fs.existsSync(store.file("settings"))) {
    const dir = path.join(dataRoot, "migration-backup-" + Date.now());
    fs.mkdirSync(dir, { recursive: true });
    for (const name of [
      "settings.json",
      "session-cache-v5.json",
      "session-cache-v4.json",
    ]) {
      const file = path.join(dataRoot, name);
      if (!fs.existsSync(file)) continue;
      if (name === "settings.json") fs.copyFileSync(file, path.join(dir, name));
      else {
        try {
          const cache = JSON.parse(fs.readFileSync(file, "utf8"));
          if (!Array.isArray(cache.files)) throw new Error("unknown cache format");
          cache.files = cache.files.map(([key, value]) => [key, require("./core/codex-reader").cacheStateForDisk(value)]);
          writeJSON(path.join(dir, name), cache);
        } catch {
          // Invalid caches can be rebuilt from the original logs. Do not copy
          // unknown raw contents into the backup.
          writeJSON(path.join(dir, name + ".rebuild.json"), { rebuildRequired: true });
        }
      }
    }
  }
  settings = migrateSettings(old);
  settings.mainBounds = old.mainBounds;
  settings.floatingBounds = old.floatingBounds;
  saveSettings();
  if (!isolation && old.schemaVersion !== 2118 && (settings.launchAtLogin || settings.launchWithCodex)) {
    // The executable name changed in 2.11.0; preserve enabled login startup by
    // updating the existing AppUserModelId registry entry during migration.
    app.setLoginItemSettings({
      openAtLogin: true,
      path: process.env.PORTABLE_EXECUTABLE_FILE || process.execPath,
      args: ["--watch-codex"],
    });
  }
  runtime = new Runtime(dataRoot, settings, {
    isVisible: () =>
      [...windows.values()].some((w) => w.isVisible() && !w.isMinimized()),
    sessionRoots: process.env.CODEX_PULSE_SESSION_ROOT
      ? [process.env.CODEX_PULSE_SESSION_ROOT]
      : undefined,
    notify: body => new Promise(resolve => {
      if (!Notification.isSupported()) return resolve(false);
      let note;
      try { note = new Notification({ title: APP_NAME, body }); } catch { return resolve(false); }
      let timer;
      const finish = accepted => { clearTimeout(timer); note.removeListener("show", shown); note.removeListener("failed", failed); resolve(accepted); };
      const shown = () => finish(true), failed = () => finish(false);
      note.once("show", shown);
      note.once("failed", failed);
      note.on("click", () => showMain("overview"));
      timer = setTimeout(() => finish(false), 10000);
      try { note.show(); } catch { finish(false); }
    }),
  });
  if (process.env.CODEX_PULSE_OFFLINE === "1") {
    runtime.official.read = async () => runtime.official.snapshot();
    runtime.exchange.current = async () => null;
    runtime.radar.fetcher = async () => {
      throw new Error("隔离离线测试");
    };
    runtime.settings.autoUpdates = false;
    runtime.settings.oneDriveSync = false;
  }
  register();
  newWindow("main");
  if (settings.floatingEnabled && !process.argv.includes("--watch-codex"))
    newWindow("floating");
  for (const type of CARD_TYPES)
    if (settings.cards[type]?.enabled) newWindow(type);
  const icon = nativeImage.createFromPath(
    path.join(__dirname, "../assets/icon.png"),
  );
  tray = new Tray(icon.resize({ width: 16, height: 16 }));
  tray.on("click", () => showMain());
  updateTray();
  Menu.setApplicationMenu(null);
  runtime.on("status", (s) => {
    broadcast("status", s);
    broadcast("radar-status", { snapshot: s.radar, error: s.radar?.error });
    updateTray();
  });
  nativeTheme.on("updated", () => broadcast("settings-changed", settings));
  screen.on("display-removed", restoreWindows);
  screen.on("display-metrics-changed", restoreWindows);
  powerMonitor.on("resume", () => {
    runtime.refresh({ force: true });
    runtime.statistics(true);
    runtime.radar.networkRestored();
    runtime.refreshRadar();
  });
  setupWatcher();
  runtime.start();
  if (process.env.CODEX_PULSE_ACCEPTANCE === "1") {
    const begin = Date.now();
    let lastPulse = Date.now();
    monitorTimer = setInterval(() => {
      const sampleNow = Date.now();
      const delayMs = Math.max(0, sampleNow - lastPulse - 60000);
      lastPulse = sampleNow;
      const record = {
        sourceHash: require("node:crypto")
          .createHash("sha256")
          .update(fs.readFileSync(__filename))
          .digest("hex")
          .slice(0, 16),
        delayMs,
        processes: app
          .getAppMetrics()
          .map((p) => ({ type: p.type, cpu: p.cpu, memory: p.memory })),
        at: new Date().toISOString(),
        elapsedMs: Date.now() - begin,
        cpu: process.getCPUUsage(),
        memory: process.memoryUsage(),
        diagnostics: runtime.diagnostics(),
      };
      fs.appendFileSync(
        path.join(dataRoot, "runtime-acceptance.jsonl"),
        JSON.stringify(record) + "\n",
      );
    }, 60000);
  }
  app.on("activate", () => showMain());
}
app.on("before-quit", () => {
  xSource.stop();
  quitting = true;
  clearTimeout(boundsTimer);
  clearInterval(watcherTimer);
  clearInterval(monitorTimer);
  runtime?.stop();
  tray?.destroy();
});
app.on("window-all-closed", () => {});
