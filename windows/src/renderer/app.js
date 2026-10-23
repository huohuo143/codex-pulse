const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
let settings = {};
let status = null;
let radar = null;
let radarLoading = false;
let projectPeriod = "today";
let toastTimer;
let toastSequence = 0;
let refreshErrorToast = null;
let refreshRequest = null;
let refreshFailure = "";
let appSubtitle = "";

function compactNumber(value) {
  const number = Number(value) || 0;
  if (number >= 100_000_000)
    return `${(number / 100_000_000).toFixed(number >= 1_000_000_000 ? 1 : 2).replace(/\.0+$/, "")}亿`;
  if (number >= 10_000)
    return `${(number / 10_000).toFixed(number >= 1_000_000 ? 1 : 2).replace(/\.0+$/, "")}万`;
  return Math.round(number).toLocaleString("zh-CN");
}

function percentage(value) {
  return value == null || !Number.isFinite(Number(value))
    ? "--%"
    : `${Math.round(Number(value))}%`;
}
function money(value, symbol = "$") {
  return Number.isFinite(Number(value))
    ? `${symbol}${Number(value).toFixed(2)}`
    : `${symbol}--`;
}
function cny(cost) {
  return status?.exchangeRate?.rate
    ? money(Number(cost?.usd || 0) * status.exchangeRate.rate, "¥")
    : "¥--";
}
function costText(cost) {
  if (!cost || cost.isUnavailable) return "暂无法估算";
  return `${money(cost.usd)} · ${cny(cost)}${cost.isPartial ? " · 部分估算" : ""}`;
}
function setAll(binding, value) {
  $$(`[data-bind="${binding}"]`).forEach((element) => {
    element.textContent = value;
  });
}

function relativeTime(value) {
  const seconds = Math.max(0, (Date.now() - Date.parse(value)) / 1000);
  if (!Number.isFinite(seconds)) return "--";
  if (seconds < 60) return "刚刚";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  return `${Math.floor(seconds / 86400)} 天前`;
}

function formatDate(value, options = {}) {
  if (!value || !Number.isFinite(Date.parse(value))) return "--";
  return new Date(value).toLocaleString("zh-CN", {
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    ...options,
  });
}

function countdown(value) {
  if (!value) return "--";
  let seconds = Math.max(0, (Date.parse(value) - Date.now()) / 1000);
  const days = Math.floor(seconds / 86400);
  seconds -= days * 86400;
  const hours = Math.floor(seconds / 3600);
  seconds -= hours * 3600;
  return days
    ? `${days} 天 ${hours} 小时`
    : `${hours} 小时 ${Math.floor(seconds / 60)} 分钟`;
}

function setGauge(selector, progress, circumference) {
  $$(selector).forEach((element) => {
    const normalized = Math.max(0, Math.min(1, Number(progress) || 0));
    element.style.strokeDasharray = String(circumference);
    element.style.strokeDashoffset = String(circumference * (1 - normalized));
  });
}

function clearAndAppend(target, rows, emptyText) {
  target.replaceChildren();
  if (!rows.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = emptyText;
    target.append(empty);
    return false;
  }
  rows.forEach((row) => target.append(row));
  return true;
}

function renderStatus(next) {
  status = next;
  if (!refreshRequest) document.body.classList.remove("loading");
  const weekly = next.weekly;
  const remaining = weekly?.remainingPercent;
  const stats = next.tokenStats;
  setAll("weekly", percentage(remaining));
  setAll(
    "weeklyNumber",
    remaining == null ? "--" : String(Math.round(remaining)),
  );
  setGauge(".js-gauge", (remaining || 0) / 100, 2 * Math.PI * 68);
  setGauge(".js-hero-gauge", (remaining || 0) / 100, 2 * Math.PI * 84);
  $$(".js-quota-bar").forEach((bar) => {
    bar.style.width = `${Math.max(0, Math.min(100, Number(remaining) || 0))}%`;
  });
  setAll("rolling24", compactNumber(stats.rolling24HoursTokens));
  setAll("last7", compactNumber(stats.last7DaysTokens));
  setAll("month", compactNumber(stats.monthTokens));
  setAll("cost24", costText(stats.cost24Hours));
  setAll("cost7", costText(stats.cost7Days));
  setAll("costMonth", costText(stats.costMonth));
  setAll(
    "cost24Usd",
    stats.cost24Hours.isUnavailable
      ? "暂无法估算"
      : money(stats.cost24Hours.usd),
  );
  setAll(
    "cost24Cny",
    stats.cost24Hours.isUnavailable ? "--" : cny(stats.cost24Hours),
  );
  setAll(
    "weeklyReset",
    weekly?.resetsAt
      ? `7天重置倒计时 ${countdown(weekly.resetsAt)}`
      : "7天额度暂无官方窗口数据",
  );
  const source =
    next.main?.sourceName === "Codex app-server"
      ? "实时读取 Codex"
      : `扫描 ${next.scannedFiles} 个日志文件`;
  $("#subtitle").title =
    `${source} · ${stats.sampleCount} 条 Token 样本 · ${relativeTime(next.generatedAt)}更新`;
  if (!refreshRequest) {
    refreshFailure = "";
    $("#subtitle").textContent = appSubtitle;
  }
  renderRefreshState();
  renderCredits(next.rateLimitResetCredits);
  renderHourly(stats.hourly || []);
  renderDaily(stats.daily || []);
  renderModels(stats.modelHourly || []);
  renderDevices(stats.devices || []);
  renderInsights(stats);
  renderProjects(stats);
  renderRecent(stats.recentUsageEvents || []);
  if (typeof renderExtras === "function") renderExtras(next);
  if (typeof renderMacAligned === "function") renderMacAligned(next);
  if (next.statisticsLoading) {
    [
      "rolling24",
      "last7",
      "month",
      "cost24",
      "cost7",
      "costMonth",
      "cost24Usd",
      "cost24Cny",
    ].forEach((key) => setAll(key, "统计中"));
  }
  const partial = stats.costMonth?.isPartial;
  $("#costNote").textContent = partial
    ? `按当前价格表折算 · 覆盖率 ${Math.round(stats.costMonth.coverage * 100)}%。部分模型未计价：${stats.costMonth.unpricedModels.join(", ")}；未计价 Token ${compactNumber(stats.costMonth.unpricedTokens)}。`
    : `金额为 API 等价预估，不是 ChatGPT/Codex 订阅实际账单。reasoning token 已包含在 output 中，不重复计费。${status.exchangeRate ? ` USD/CNY ${status.exchangeRate.rate.toFixed(4)} · Frankfurter` : ""}`;
}

function renderCredits(summary) {
  setAll("creditCount", summary ? `${summary.availableCount} 次` : "-- 次");
  const available = summary?.availableCredits || [];
  setAll(
    "creditExpiry",
    available[0]?.expiresAt
      ? `最近 ${formatDate(available[0].expiresAt, { hour: undefined, minute: undefined })} 到期`
      : summary
        ? "暂无详细到期时间"
        : "等待权益数据",
  );
  const rows = available.map((credit, index) => {
    const item = document.createElement("div");
    item.className = "credit-item";
    const title = document.createElement("b");
    title.textContent = `Full reset #${index + 1}`;
    const grant = document.createElement("span");
    grant.textContent = `发放 ${formatDate(credit.grantedAt)}`;
    const expiry = document.createElement("span");
    expiry.textContent = credit.expiresAt
      ? `到期 ${formatDate(credit.expiresAt)}`
      : "未提供到期时间";
    item.append(title, grant, expiry);
    return item;
  });
  if (summary?.missingDetailCount > 0) {
    const item = document.createElement("div");
    item.className = "credit-item";
    item.innerHTML = `<b>另有 ${summary.missingDetailCount} 次</b><span>官方未返回详细时间</span>`;
    rows.push(item);
  }
  clearAndAppend(
    $("#creditsList"),
    rows,
    summary ? "当前无可用 Full reset 权益" : "等待权益数据",
  );
}

function renderRadar(payload) {
  if (payload?.snapshot !== undefined) radar = payload.snapshot;
  const error = payload?.error;
  if (typeof renderRadarExtras === "function") renderRadarExtras();
  const display = RadarDisplay.clock(radar);
  setAll('radarProbability', display.title);
  setAll('radarMicro', display.title);
  setAll('radarClock', display.detail);
  setAll(
    "radarLevel",
    radar?.latestLevelLabel ||
      (error ? "同步失败，继续显示上次数据" : "等待公开摘要"),
  );
  setAll(
    "radarSummary",
    radar?.latestSummary || error || "正在读取 Codex Radar / Tibo 公开动态…",
  );
  setAll(
    "radarUpdated",
    radar?.latestUpdate
      ? `${radar.refreshHealthy ? '✓ 来源与分析成功' : '刷新待完成'} · ${formatDate(radar.latestUpdate)}`
      : "暂无更新时间",
  );
  setAll(
    "tiboLocation",
    radar?.tiboPresence?.locationLabelZh || "旧金山湾区 / PT",
  );
  setAll(
    "tiboEvidence",
    radar?.tiboPresence?.evidenceSummaryZh || "公开摘要尚未返回时区依据",
  );
  setAll(
    "tiboActivity",
    radar?.tiboPresence?.latestActivityZh ||
      radar?.latestSummary ||
      "公开摘要尚未返回最新动态或研判摘要。",
  );
  $("#radarStatusText").textContent = error
    ? `更新失败：${error}`
    : radar?.latestUpdate
      ? `公开源成功于 ${formatDate(radar.latestUpdate)} · 可选本机模型 · 每 10 分钟检查${radar.analysisError ? ' · ' + radar.analysisError : ''}`
      : '每 10 分钟检查 · 可选本机模型 分析公开动态';
}

function renderHourly(rows) {
  const peak = Math.max(1, ...rows.map((row) => row.totalTokens));
  clearAndAppend(
    $("#hourlyChart"),
    rows.map((row) => {
      const column = document.createElement("div");
      column.className = "bar-column";
      const space = document.createElement("div");
      space.className = "bar-space";
      const bar = document.createElement("div");
      bar.className = "bar";
      bar.style.height = `${Math.max(row.totalTokens ? 4 : 1, (row.totalTokens / peak) * 100)}%`;
      bar.title = `${row.label} · ${row.totalTokens.toLocaleString("zh-CN")} Token`;
      const label = document.createElement("label");
      label.textContent = row.label.replace("时", "").split(" ").at(-1);
      space.append(bar);
      column.append(space, label);
      return column;
    }),
    "暂无小时用量",
  );
}

function renderDaily(rows) {
  if (typeof renderStacked === "function") renderStacked(rows);
  const canvas = $("#dailyChart");
  if (!canvas || canvas.hidden || !rows.length) return;
  const width = Math.max(500, canvas.clientWidth);
  const height = Math.max(170, canvas.clientHeight);
  const ratio = window.devicePixelRatio || 1;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  const context = canvas.getContext("2d");
  context.scale(ratio, ratio);
  const style = getComputedStyle(document.body);
  const accent = style.getPropertyValue("--usage").trim();
  const muted = style.getPropertyValue("--muted").trim();
  const values = rows.map((row) => row.totalTokens);
  const max = Math.max(1, ...values);
  $("#dailyPeak").textContent = `峰值 ${compactNumber(max)}`;
  const padding = { left: 14, right: 10, top: 16, bottom: 27 };
  const chartWidth = width - padding.left - padding.right;
  const chartHeight = height - padding.top - padding.bottom;
  context.strokeStyle = "rgba(255,255,255,.07)";
  context.lineWidth = 1;
  for (let i = 0; i <= 3; i += 1) {
    const y = padding.top + (chartHeight * i) / 3;
    context.beginPath();
    context.moveTo(padding.left, y);
    context.lineTo(width - padding.right, y);
    context.stroke();
  }
  const points = values.map((value, index) => ({
    x: padding.left + (chartWidth * index) / Math.max(1, values.length - 1),
    y: padding.top + chartHeight * (1 - value / max),
  }));
  const gradient = context.createLinearGradient(
    0,
    padding.top,
    0,
    height - padding.bottom,
  );
  gradient.addColorStop(0, `${accent}66`);
  gradient.addColorStop(1, `${accent}00`);
  context.beginPath();
  context.moveTo(points[0].x, height - padding.bottom);
  points.forEach((point) => context.lineTo(point.x, point.y));
  context.lineTo(points.at(-1).x, height - padding.bottom);
  context.closePath();
  context.fillStyle = gradient;
  context.fill();
  context.beginPath();
  points.forEach((point, index) =>
    index ? context.lineTo(point.x, point.y) : context.moveTo(point.x, point.y),
  );
  context.strokeStyle = accent;
  context.lineWidth = 2;
  context.stroke();
  context.fillStyle = muted;
  context.font = `12px ${getComputedStyle(document.body).fontFamily}`;
  context.textAlign = "center";
  [0, 6, 13].forEach((index) =>
    context.fillText(
      rows[index]?.label || "",
      points[index]?.x || 0,
      height - 7,
    ),
  );
}

function renderModels(rows) {
  const totals = new Map();
  rows.forEach((row) => {
    const current = totals.get(row.model) || 0;
    totals.set(row.model, current + row.totalTokens);
  });
  const items = [...totals]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8)
    .map(([model, tokens]) => {
      const row = document.createElement("div");
      row.className = "model-row";
      const name = document.createElement("b");
      name.textContent = model;
      const value = document.createElement("span");
      value.textContent = compactNumber(tokens);
      row.append(name, value);
      return row;
    });
  clearAndAppend($("#models"), items, "暂无模型级用量");
}

function renderDevices(rows) {
  $("#deviceCount").textContent = rows.length
    ? `${rows.length} 台设备`
    : "本机";
  const items = rows.map((device) => {
    const row = document.createElement("div");
    row.className = "device-row";
    const dot = document.createElement("i");
    const copy = document.createElement("div");
    const name = document.createElement("b");
    name.textContent = device.deviceName || device.deviceID;
    const detail = document.createElement("small");
    detail.textContent = `schema ${device.schemaVersion} · ${relativeTime(device.updatedAt)}`;
    const value = document.createElement("span");
    value.textContent = `今日 ${compactNumber(device.todayTokens)} · 本月 ${compactNumber(device.monthTokens)}`;
    copy.append(name, detail);
    row.append(dot, copy, value);
    return row;
  });
  clearAndAppend($("#devices"), items, "未检测到 OneDrive，当前仅统计本机");
}

function renderInsights(stats) {
  const calls = (stats.categoryBreakdown || []).reduce(
    (sum, row) => sum + row.calls,
    0,
  );
  $("#monthCalls").textContent = compactNumber(calls);
  const activeModels = new Set(
    (stats.modelHourly || [])
      .filter((row) => row.totalTokens > 0)
      .map((row) => row.model),
  );
  $("#modelCount").textContent = `已识别 ${activeModels.size} 个模型`;
  const input = (stats.modelHourly || []).reduce(
    (sum, row) => sum + row.inputTokens,
    0,
  );
  const cached = (stats.modelHourly || []).reduce(
    (sum, row) => sum + row.cachedInputTokens,
    0,
  );
  $("#cacheRate").textContent = input
    ? `${Math.round((cached / input) * 100)}%`
    : "--";
  const categories = [...(stats.categoryBreakdown || [])]
    .filter((row) => row.totalTokens > 0)
    .sort((a, b) => b.totalTokens - a.totalTokens);
  const top = categories[0];
  $("#topCategory").textContent = top?.label || "--";
  $("#topCategoryDetail").textContent = top
    ? `${compactNumber(top.totalTokens)} Token`
    : "等待完整统计";
  const total = Math.max(
    1,
    categories.reduce((sum, row) => sum + row.totalTokens, 0),
  );
  const max = Math.max(1, ...categories.map((row) => row.totalTokens));
  const items = categories.map((category) => {
    const row = document.createElement("div");
    row.className = "category-row";
    const label = document.createElement("label");
    label.textContent = category.label;
    const track = document.createElement("div");
    track.className = "category-track";
    const fill = document.createElement("i");
    fill.style.width = `${(category.totalTokens / max) * 100}%`;
    track.append(fill);
    const value = document.createElement("span");
    value.textContent = `${((category.totalTokens / total) * 100).toFixed(1)}% · ${compactNumber(category.totalTokens)} · ${category.calls} 次`;
    row.append(label, track, value);
    return row;
  });
  clearAndAppend($("#categories"), items, "正在建立本月工作类型统计…");
}

function renderProjects(stats) {
  const rows =
    projectPeriod === "today"
      ? stats.todayTopProjects || []
      : stats.monthTopProjects || [];
  const items = rows.map((project, index) => {
    const row = document.createElement("div");
    row.className = "rank-row";
    const rank = document.createElement("i");
    rank.textContent = String(index + 1);
    const copy = document.createElement("div");
    const name = document.createElement("b");
    name.textContent = DisplayLabels.projectName(project.projectName, project.projectPath);
    const detail = document.createElement("small");
    detail.textContent = DisplayLabels.projectPath(project.projectPath);
    detail.title = project.projectPath || "";
    const value = document.createElement("span");
    value.textContent = `${project.calls} 次 · ${compactNumber(project.totalTokens)}`;
    copy.append(name, detail);
    row.append(rank, copy, value);
    return row;
  });
  clearAndAppend($("#projects"), items, "当前时段暂无项目数据");
}

function renderRecent(rows) {
  const items = rows.slice(0, 8).map((event) => {
    const row = document.createElement("div");
    row.className = "usage-row";
    const time = document.createElement("time");
    time.textContent = new Date(event.timestamp).toLocaleTimeString("zh-CN", {
      hour: "2-digit",
      minute: "2-digit",
    });
    const model = document.createElement("b");
    model.textContent = event.model;
    const project = document.createElement("b");
    project.textContent = DisplayLabels.projectName(event.projectName, event.projectPath);
    const input = document.createElement("span");
    input.textContent = `in ${compactNumber(event.inputTokens)}`;
    const cached = document.createElement("span");
    cached.textContent = `cache ${compactNumber(event.cachedInputTokens)}`;
    const output = document.createElement("span");
    output.textContent = `out ${compactNumber(event.outputTokens)}`;
    row.append(time, model, project, input, cached, output);
    return row;
  });
  clearAndAppend($("#recentUsage"), items, "正在读取 Codex 会话日志…");
}

function applySettings(next) {
  settings = { ...settings, ...next };
  const body = document.body;
  body.classList.toggle("compact", Boolean(settings.compact));
  body.classList.toggle(
    "hide-compact-credits",
    !settings.compactShowsResetCredits,
  );
  body.dataset.palette = settings.palette || "mintDawn";
  body.dataset.appearance = settings.appearance || "aurora";
  body.dataset.compactStyle = settings.compactStyle || "rings";
  body.dataset.ringOrientation =
    settings.compactRingOrientation || "horizontal";
  body.dataset.size = settings.compactSizeMode || "standard";
  body.style.setProperty("--opacity", Number(settings.opacity || 0.78));
  $("#alwaysOnTop").checked = Boolean(settings.alwaysOnTop);
  $("#launchWithCodex").checked = Boolean(settings.launchWithCodex);
  $("#oneDriveSync").checked = Boolean(settings.oneDriveSync);
  $("#showCredits").checked = Boolean(settings.compactShowsResetCredits);
  $("#refreshSeconds").value = String(settings.refreshSeconds || 30);
  $("#compactSize").value = settings.compactSizeMode || "standard";
  $("#ringOrientation").value = settings.compactRingOrientation || "horizontal";
  $("#opacity").value = String(
    Math.round(Number(settings.opacity || 0.78) * 100),
  );
  $("#ringSettings").style.display =
    settings.compactStyle === "rings" ? "" : "none";
  $$("[data-palette-value]").forEach((button) =>
    button.classList.toggle(
      "selected",
      button.dataset.paletteValue === settings.palette,
    ),
  );
  $$("[data-appearance-value]").forEach((button) =>
    button.classList.toggle(
      "selected",
      button.dataset.appearanceValue === settings.appearance,
    ),
  );
  $$("[data-style-value]").forEach((button) =>
    button.classList.toggle(
      "selected",
      button.dataset.styleValue === settings.compactStyle,
    ),
  );
  if (typeof applyExtraSettings === "function") applyExtraSettings();
  showSection(settings.selectedSection || "overview", false);
  if (status && !settings.compact) renderDaily(status.tokenStats.daily);
}

function showSection(section, persist = true) {
  $$("[data-section]").forEach((button) =>
    button.classList.toggle("selected", button.dataset.section === section),
  );
  $$("[data-panel]").forEach((panel) =>
    panel.classList.toggle("selected", panel.dataset.panel === section),
  );
  if (persist && section !== settings.selectedSection)
    window.suanli.setSettings({ selectedSection: section });
}

function showToast(message, kind = "success") {
  const toast = $("#toast");
  const messageId = ++toastSequence;
  kind = ["success", "error", "info"].includes(kind) ? kind : "info";
  toast.dataset.kind = kind;
  toast.dataset.messageId = String(messageId);
  toast.setAttribute("role", kind === "error" ? "alert" : "status");
  toast.setAttribute("aria-live", kind === "error" ? "assertive" : "polite");
  toast.textContent = ErrorMessages.readable(message);
  toast.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("show"), kind === "error" ? 5000 : 2600);
  return messageId;
}
function renderRefreshState() {
  const target = $("#refreshState");
  target.dataset.state = refreshFailure ? "error" : refreshRequest || status?.statisticsLoading ? "loading" : "ready";
  target.textContent = refreshRequest
    ? "正在刷新额度、用量与重置雷达…"
    : refreshFailure
      ? "刷新失败 · 可重试"
      : status?.statisticsLoading
        ? "正在统计本机用量…"
        : status
          ? `完整统计更新于 ${formatDate(status.statisticsAt || status.generatedAt, { month: undefined, day: undefined })}`
          : "正在读取额度";
  for (const id of ["#refreshButton", "#compactRefresh", "#settingsRefresh"])
    $(id).disabled = !!refreshRequest;
}
function requestRefresh() {
  if (refreshRequest) return refreshRequest;
  refreshFailure = "";
  document.body.classList.add("loading");
  refreshRequest = Promise.resolve().then(() => window.suanli.refresh({ forceRadar: true }))
    .catch((error) => {
      refreshFailure = ErrorMessages.readable(error, "刷新失败，请重试");
      refreshErrorToast = showToast(refreshFailure, "error");
    }).finally(() => {
      refreshRequest = null;
      document.body.classList.remove("loading");
      $("#subtitle").textContent = refreshFailure ? `读取失败：${refreshFailure}` : appSubtitle;
      if (!refreshFailure && refreshErrorToast !== null) {
        const toast = $("#toast");
        if (toast.dataset.messageId === String(refreshErrorToast) && toast.dataset.kind === "error") {
          clearTimeout(toastTimer);
          toast.classList.remove("show");
          toast.textContent = "";
        }
        refreshErrorToast = null;
      }
      renderRefreshState();
    });
  renderRefreshState();
  return refreshRequest;
}

function updateTiboClock() {
  const parts = new Intl.DateTimeFormat("zh-CN", {
    timeZone: radar?.tiboPresence?.timezone || "America/Los_Angeles",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(new Date());
  const hour = Number(parts.find((part) => part.type === "hour")?.value || 0);
  $("#tiboTime").textContent = parts
    .filter((part) => ["hour", "minute", "literal"].includes(part.type))
    .map((part) => part.value)
    .join("");
  $("#tiboPeriod").textContent =
    hour < 7
      ? "可能睡眠 · PT"
      : hour < 9
        ? "清晨 · PT"
        : hour < 18
          ? "工作时段 · PT"
          : hour < 23
            ? "晚间 · PT"
            : "深夜 · PT";
}

function bindEvents() {
  $("#compactExpand").addEventListener("click", () =>
    window.suanli.setCompact(false),
  );
  $("#compactRefresh").addEventListener("click", requestRefresh);
  $("#collapseButton").addEventListener("click", () =>
    window.suanli.setCompact(true),
  );
  $("#refreshButton").addEventListener("click", requestRefresh);
  $("#copyButton").addEventListener("click", () => window.suanli.copySummary());
  $("#exportButton").addEventListener("click", () => window.suanli.exportCSV());
  $("#minimizeButton").addEventListener("click", () =>
    window.suanli.windowAction("minimize"),
  );
  $("#closeButton").addEventListener("click", () =>
    window.suanli.windowAction("close"),
  );
  $$("[data-section]").forEach((button) =>
    button.addEventListener("click", () => showSection(button.dataset.section)),
  );
  $("#radarRefresh").addEventListener("click", () =>
    window.suanli.refreshRadar(true),
  );
  $("#settingsRadarRefresh").addEventListener("click", () =>
    window.suanli.refreshRadar(true),
  );
  $$(".radarSource").forEach((button) =>
    button.addEventListener("click", () =>
      window.suanli.openExternal("https://codexradar.com/"),
    ),
  );
  $("#openLogs").addEventListener(
    "click",
    () => status && window.suanli.openPath(status.sessionsRoot.split(" | ")[0]),
  );
  $("#settingsRefresh").addEventListener("click", requestRefresh);
  $("#settingsCopy").addEventListener("click", () =>
    window.suanli.copySummary(),
  );
  $$("[data-period]").forEach((button) =>
    button.addEventListener("click", () => {
      projectPeriod = button.dataset.period;
      $$("[data-period]").forEach((item) =>
        item.classList.toggle("selected", item === button),
      );
      if (status) renderProjects(status.tokenStats);
    }),
  );
  $$("[data-palette-value]").forEach((button) =>
    button.addEventListener("click", () =>
      window.suanli.setSettings({ palette: button.dataset.paletteValue }),
    ),
  );
  $$("[data-appearance-value]").forEach((button) =>
    button.addEventListener("click", () =>
      window.suanli.setSettings({ appearance: button.dataset.appearanceValue }),
    ),
  );
  $$("[data-style-value]").forEach((button) =>
    button.addEventListener("click", () =>
      window.suanli.setSettings({ compactStyle: button.dataset.styleValue }),
    ),
  );
  $("#alwaysOnTop").addEventListener("change", (event) =>
    window.suanli.setSettings({ alwaysOnTop: event.target.checked }),
  );
  $("#launchWithCodex").addEventListener("change", (event) =>
    window.suanli.setSettings({ launchWithCodex: event.target.checked }),
  );
  $("#oneDriveSync").addEventListener("change", (event) =>
    window.suanli.setSettings({ oneDriveSync: event.target.checked }),
  );
  $("#showCredits").addEventListener("change", (event) =>
    window.suanli.setSettings({
      compactShowsResetCredits: event.target.checked,
    }),
  );
  $("#refreshSeconds").addEventListener("change", (event) =>
    window.suanli.setSettings({ refreshSeconds: Number(event.target.value) }),
  );
  $("#compactSize").addEventListener("change", (event) =>
    window.suanli.setSettings({ compactSizeMode: event.target.value }),
  );
  $("#ringOrientation").addEventListener("change", (event) =>
    window.suanli.setSettings({ compactRingOrientation: event.target.value }),
  );
  $("#opacity").addEventListener("input", (event) =>
    window.suanli.setSettings({ opacity: Number(event.target.value) / 100 }),
  );
  window.addEventListener(
    "resize",
    () =>
      status &&
      !document.body.classList.contains("compact") &&
      renderDaily(status.tokenStats.daily),
  );
  window.addEventListener("keydown", (event) => {
    if (
      (event.ctrlKey || event.metaKey) &&
      event.shiftKey &&
      event.key.toLowerCase() === "c"
    ) {
      event.preventDefault();
      window.suanli.copySummary();
    }
  });
}

async function start() {
  bindEvents();
  const bootstrap = await window.suanli.bootstrap();
  appSubtitle = `v${bootstrap.version} · build ${bootstrap.build || 2157} · Windows`;
  $("#subtitle").textContent = appSubtitle;
  applySettings(bootstrap.settings);
  if (bootstrap.status) renderStatus(bootstrap.status);
  radar = bootstrap.radar;
  if (radar) renderRadar({ snapshot: radar });
  window.suanli.onStatus(renderStatus);
  window.suanli.onStatusError((message) => {
    refreshFailure = ErrorMessages.readable(message, "读取失败，请重试");
    if (!refreshRequest) document.body.classList.remove("loading");
    $("#subtitle").textContent = `读取失败：${refreshFailure}`;
    renderRefreshState();
  });
  window.suanli.onRadarStatus(renderRadar);
  window.suanli.onRadarLoading((value) => {
    radarLoading = value;
    $("#radarRefresh").disabled = value;
    $("#settingsRadarRefresh").disabled = value;
  });
  window.suanli.onSettings(applySettings);
  window.suanli.onCompact((compact) => applySettings({ compact }));
  window.suanli.onToast(showToast);
  updateTiboClock();
  setInterval(updateTiboClock, 30_000);
}

start().catch((error) => showToast(ErrorMessages.readable(error, "初始化失败"), "error"));
window.addEventListener("unhandledrejection", (event) => {
  event.preventDefault();
  showToast(ErrorMessages.readable(event.reason), "error");
});
