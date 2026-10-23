const $ = (s) => document.querySelector(s);
let config = {},
  status = null;
const type = new URLSearchParams(location.search).get("surface");
const labels = {
  overview: "Codex 算力总览",
  quota: "Codex 额度",
  radar: "Codex 重置雷达",
  credits: "Full reset 权益",
  tokens: "Token 汇总",
  trend: "Token 趋势",
  projects: "项目与用途",
};
const esc = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const n = (v) => Number(v || 0).toLocaleString("zh-CN");
const percent = (v) => (v == null ? "--%" : Math.round(v) + "%");
const date = (v) =>
  v
    ? new Date(v).toLocaleString("zh-CN", {
        month: "numeric",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "--";
const fresh = {
  fresh: "官方数据已更新",
  cached: "使用缓存 · 等待更新",
  expired: "数据已过期",
  waitingForReset: "等待新周期数据",
  unavailable: "数据状态待确认",
};
function apply(s) {
  config = s;
  document.body.dataset.palette = s.palette;
  document.body.dataset.appearance = s.appearance;
  document.body.dataset.theme =
    s.themeMode === "system" ? (s.systemDark ? "dark" : "light") : s.themeMode;
  $("#pin").textContent = s.cards?.[type]?.alwaysOnTop ? "◆" : "◇";
  if (status) render(status);
}
function ring(s) {
  return (
    '<div class="card-ring' + (config.cardFiveHour ? ' with-five' : '') + '"><svg viewBox="0 0 180 180"><circle class="track" cx="90" cy="90" r="72"/><circle class="value" cx="90" cy="90" r="72" stroke-dasharray="' +
    2 * Math.PI * 72 +
    '" stroke-dashoffset="' +
    2 * Math.PI * 72 * (1 - (s.weekly?.remainingPercent || 0) / 100) +
    '"/>' +
    (config.cardFiveHour
      ? '<circle class="track" cx="90" cy="90" r="56"/><circle class="inner" cx="90" cy="90" r="56" stroke-dasharray="' +
        2 * Math.PI * 56 +
        '" stroke-dashoffset="' +
        2 * Math.PI * 56 * (1 - (s.fiveHour?.remainingPercent || 0) / 100) +
        '"/>'
      : "") +
    '</svg><div class="center"><b>' +
    percent(s.weekly?.remainingPercent) +
    "</b><small>7 天剩余</small>" +
    (config.cardFiveHour
      ? "<small>5h " + percent(s.fiveHour?.remainingPercent) + "</small>"
      : "") +
    "</div></div>"
  );
}
function tokens(s) {
  const t = s.tokenStats;
  return (
    '<div class="card-grid">' +
    [
      ["滚动 24h", t.rolling24HoursTokens],
      ["今日", t.todayTokens],
      ["近 7 天", t.last7DaysTokens],
      ["本月", t.monthTokens],
    ]
      .map(
        ([k, v]) =>
          "<div><small>" +
          k +
          "</small><b>" +
          (s.statisticsLoading ? "统计中" : n(v)) +
          "</b></div>",
      )
      .join("") +
    "</div>"
  );
}
function cost(c) {
  return !c || c.isUnavailable
    ? "暂无法估算"
    : "$" +
        c.usd.toFixed(2) +
        (c.isPartial
          ? " · 部分估算（" + Math.round(c.coverage * 100) + "%）"
          : "");
}
function render(s) {
  status = s;
  document.body.dataset.card = type;
  document.body.dataset.resetState = s.radar?.latestLevelLabel?.includes("预告") ? "announced" : s.radar?.localCompletion && s.radar?.completionUntil ? "completed" : "waiting";
  $("#cardTitle").textContent = labels[type] || "Codex 脉动";
  const t = s.tokenStats,
    r = s.radar;
  let html = "";
  if (type === "quota" || type === "overview")
    html =
      ring(s) +
      '<p class="card-caption">重置时间 ' +
      date(s.weekly?.resetsAt) +
      "</p>";
  if (type === "overview")
    html +=
      tokens(s) +
      '<div class="card-row"><b>重置动态</b><span>' +
      esc(RadarDisplay.clock(r).title) +
      '</span></div><p class="reset-clock">' + esc(RadarDisplay.clock(r).detail) +
      '</p><div class="card-row"><b>Full reset</b><span>' +
      (s.rateLimitResetCredits
        ? n(s.rateLimitResetCredits.availableCount)
        : "--") +
      " 次</span></div>";
  if (type === "tokens")
    html =
      tokens(s) +
      '<p class="card-note">本月按当前价格表折算<br>' +
      cost(t.costMonth) +
      "<br>API 等价预估，不是订阅账单</p>";
  if (type === "radar")
    html =
      '<div class="card-value">' +
      esc(RadarDisplay.clock(r).title) +
      '</div><p class="reset-clock">' + esc(RadarDisplay.clock(r).detail) + '</p><p class="card-note">' +
      esc(r?.latestSummary || "等待公开动态") +
      '</p><p class="card-caption">公开资料：Codex Radar / Tibo<br>可选本机模型；以本账号官方额度为准</p>';
  if (type === "credits")
    html =
      '<div class="card-value">' +
      (s.rateLimitResetCredits
        ? n(s.rateLimitResetCredits.availableCount)
        : "--") +
      ' 次</div><p class="card-caption">只读权益</p>' +
      (s.rateLimitResetCredits?.availableCredits || [])
        .slice(0, 3)
        .map(
          (c) =>
            '<div class="card-row"><b>Full reset</b><span>' +
            date(c.expiresAt) +
            " 到期</span></div>",
        )
        .join("");
  if (type === "projects")
    html =
      "<small>今日项目 Top 3</small>" +
      (t.todayTopProjects || [])
        .slice(0, 3)
        .map(
          (p) =>
            '<div class="card-row"><b>' +
            esc(DisplayLabels.projectName(p.projectName, p.projectPath)) +
            "</b><span>" +
            n(p.totalTokens) +
            "</span></div>",
        )
        .join("") +
      '<p class="card-caption">本月用途 Top 3</p>' +
      (t.categoryBreakdown || [])
        .filter((c) => c.totalTokens > 0)
        .sort((a, b) => b.totalTokens - a.totalTokens)
        .slice(0, 3)
        .map(
          (c) =>
            '<div class="card-row"><b>' +
            esc(c.label) +
            "</b><span>" +
            n(c.totalTokens) +
            "</span></div>",
        )
        .join("");
  if (type === "trend")
    html =
      '<div class="card-value">' +
      (s.statisticsLoading ? "统计中" : n(t.rolling24HoursTokens)) +
      '</div><p class="card-caption">滚动 24 小时 Token</p><div class="mini-bars" id="hourBars"></div><p class="card-caption">最近 14 天</p><div class="mini-bars" id="dayBars"></div>';
  $("#content").innerHTML = html;
  if (type === 'radar') $('#content').classList.add('announcement-card');
  const state =
    type === "radar"
      ? r?.sourceState
      : type === "credits"
        ? s.sourceStates?.reset
        : s.sourceStates?.quota;
  $("#freshness").textContent = ["tokens", "trend", "projects"].includes(type)
    ? s.statisticsLoading
      ? "统计中"
      : "统计更新 " + date(s.statisticsAt)
    : type === 'radar' ? (r?.refreshHealthy ? '✓ 来源与分析成功' : r?.analysisError || r?.error || '等待动态与分析') : fresh[state] || fresh.unavailable;
  if (type === "trend")
    for (const [id, rows] of [
      ["hourBars", t.hourly],
      ["dayBars", t.daily.slice(-14)],
    ]) {
      const max = Math.max(1, ...rows.map((r) => r.totalTokens));
      for (const row of rows) {
        const bar = document.createElement("i");
        bar.style.height = (row.totalTokens / max) * 100 + "%";
        bar.title = row.label + " · " + n(row.totalTokens) + " Token";
        $("#" + id).append(bar);
      }
    }
}
$("#close").onclick = () => window.suanli.windowAction("close");
$("#open").onclick = () => window.suanli.windowAction("main");
$("#pin").onclick = () =>
  window.suanli.setCard({
    type,
    alwaysOnTop: !config.cards?.[type]?.alwaysOnTop,
  });
window.suanli.onSettings(apply);
window.suanli.onStatus(render);
window.suanli.bootstrap().then((b) => {
  apply(b.settings);
  if (b.status) render(b.status);
});
window.addEventListener("unhandledrejection", (e) => {
  $("#freshness").textContent = ErrorMessages.readable(e.reason, "操作失败");
});

setInterval(() => { if (status && ["overview", "radar"].includes(type)) render(status); }, 1000);
