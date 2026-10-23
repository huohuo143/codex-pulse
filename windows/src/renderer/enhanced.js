const CARD_LABELS = {
  overview: "Codex 算力总览",
  quota: "Codex 额度",
  radar: "Codex 重置雷达",
  credits: "Full reset 权益",
  tokens: "Token 汇总",
  trend: "Token 趋势",
  projects: "项目与用途",
};
const stateLabels = {
  fresh: "官方数据已更新",
  cached: "使用缓存 · 等待官方更新",
  expired: "数据已过期",
  waitingForReset: "等待新周期数据",
  unavailable: "数据状态待确认",
};
const riskLabels = {
  healthy: "充足",
  caution: "需关注",
  critical: "高风险",
  insufficientData: "学习中",
  noUsage: "暂无用量",
  overBudget: "已超预算",
};
const htmlEscape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
function checkbox(id, label, detail = "") {
  return (
    '<label class="setting-row"><span>' +
    label +
    (detail ? "<small>" + detail + "</small>" : "") +
    '</span><input id="' +
    id +
    '" type="checkbox"></label>'
  );
}
$("#newSettings").innerHTML =
  '<article class="card settings-card"><h3>Windows 显示</h3><div class="setting-row"><label for="themeMode">背景模式</label><select id="themeMode"><option value="system">跟随系统</option><option value="light">白天</option><option value="dark">夜晚</option></select></div>' +
  checkbox("floatingEnabled", "启用独立悬浮框") +
  checkbox("showWeekly", "悬浮框显示 7 天额度") +
  checkbox(
    "showFiveHour",
    "显示 5 小时额度",
    "主窗口与悬浮框同步；内环为橙色",
  ) +
  checkbox("showTokens", "悬浮框显示滚动 24h Token") +
  checkbox("showRadar", "悬浮框显示重置雷达") +
  checkbox("cardFiveHour", "桌面卡片显示 5 小时内环") +
  checkbox("launchAtLogin", "Windows 登录后后台运行") +
  "</article>" +
  '<article class="card settings-card"><h3>桌面卡片</h3><p>卡片可独立移动、缩放和置顶，关闭主窗口后仍保持显示。</p><div id="cardSettings"></div></article>' +
  '<article class="card settings-card"><h3>额度提醒</h3>' +
  checkbox(
    "notifications",
    "启用 Windows 通知",
    "默认关闭；按账户和重置周期去重",
  ) +
  '<div class="setting-row"><label>阈值方案</label><select id="alertPreset"><option value="standard">标准：30 / 15 / 5%</option><option value="early">提前：50 / 30 / 15%</option><option value="urgentOnly">紧急：15 / 5%</option></select></div>' +
  checkbox("thresholdAlerts", "额度阈值提醒") +
  checkbox("forecastAlerts", "预测高风险提醒") +
  checkbox("creditAlerts", "Full reset 24 小时内到期提醒") +
  "</article>" +
  '<article class="card settings-card"><h3>价格与灵活额度到期记录</h3><p>按当前价格表折算，金额不是订阅账单。未知缓存输入单价不按零计价。</p><button id="previewPrices">导入价格表并预览差异</button><div id="pricePreview"></div><div class="expiry-form"><label>余额到期日期 <input id="expiryDate" type="date"></label><input id="expiryEvidence" placeholder="填写官方日期的核实依据" maxlength="1000"><label><input id="expiryConfirmed" type="checkbox"> 已核实当前账户</label><button id="saveExpiry">保存到期记录</button></div><small id="expiryStatus">未核实的日期不会作为官方到期时间</small></article>' +
  '<article class="card settings-card"><h3>可靠性与自动化</h3><div id="healthChecks"></div>' +
  checkbox("dailyBackup", "每日备份关键数据", "本机保留最近 7 份备份") +
  checkbox("dailySummary", "保存每日聚合摘要") +
  '<div class="button-row"><button id="recover">重新检查</button><button id="diagnostics">导出脱敏诊断</button></div><details><summary>最近状态事件</summary><div id="healthEvents"></div></details></article>' +
  '<article class="card settings-card"><h3>版本更新</h3>' +
  checkbox(
    "autoUpdates",
    "启动时检查更新",
    "自动检查间隔至少 24 小时，不静默安装",
  ) +
  '<p id="updateState">尚未检查更新</p><div class="button-row"><button id="checkUpdates">检查更新</button><button id="downloadUpdate" disabled>查看下载</button></div></article>' +
  '<article class="card settings-card"><h3>雷达预测验证</h3><p>仅对已结束且有核实依据的 24 小时窗口评分，未知结果不视为未发生。重叠窗口并非独立样本。</p><p id="brierScore">暂无已核实样本</p><select id="radarRecord" aria-label="预测记录"></select><div class="budget-form"><select id="radarOutcome"><option value="true">已发生全局硬重置</option><option value="false">未发生全局硬重置</option></select><input id="radarEvidence" placeholder="核实依据或来源链接" maxlength="500"><button id="markRadar">保存标注</button></div></article>';
for (const [type, label] of Object.entries(CARD_LABELS)) {
  const row = document.createElement("div");
  row.className = "setting-row";
  row.innerHTML =
    "<span>" +
    label +
    '</span><div><label><input type="checkbox" data-card="' +
    type +
    '"> 显示</label> <label><input type="checkbox" data-pin="' +
    type +
    '"> 置顶</label></div>';
  $("#cardSettings").append(row);
}
const bools = [
  "floatingEnabled",
  "showWeekly",
  "showFiveHour",
  "showTokens",
  "showRadar",
  "cardFiveHour",
  "launchAtLogin",
  "notifications",
  "thresholdAlerts",
  "forecastAlerts",
  "creditAlerts",
  "dailyBackup",
  "dailySummary",
  "autoUpdates",
];
for (const id of bools)
  $("#" + id).addEventListener("change", (e) =>
    window.suanli.setSettings({ [id]: e.target.checked }),
  );
for (const id of ["themeMode", "alertPreset"])
  $("#" + id).addEventListener("change", (e) =>
    window.suanli.setSettings({ [id]: e.target.value }),
  );
$$("[data-card]").forEach((el) =>
  el.addEventListener("change", () =>
    window.suanli.setCard({ type: el.dataset.card, enabled: el.checked }),
  ),
);
$$("[data-pin]").forEach((el) =>
  el.addEventListener("change", () =>
    window.suanli.setCard({ type: el.dataset.pin, alwaysOnTop: el.checked }),
  ),
);
$("#floatingClose").addEventListener("click", () =>
  window.suanli.windowAction("close"),
);
const budgetEditor = PulseBudgetEditor.mount({
  document, api: window.suanli, notify: showToast,
});
$("#saveExpiry").addEventListener("click", async () => {
  await window.suanli.setExpiry({
    date: $("#expiryDate").value,
    evidence: $("#expiryEvidence").value,
    confirmed: $("#expiryConfirmed").checked,
  });
  showToast("到期记录已保存");
});
$("#recover").addEventListener("click", async () => {
  await window.suanli.recover();
  showToast("检查完成");
});
$("#diagnostics").addEventListener("click", () =>
  window.suanli.exportDiagnostics(),
);
$("#checkUpdates").addEventListener("click", async () => {
  const button = $("#checkUpdates");
  button.disabled = true;
  let updates;
  try {
    updates = await window.suanli.checkUpdates();
  } finally {
    button.disabled =
      Date.parse(updates?.nextRetryAt || status?.updates?.nextRetryAt) > Date.now();
  }
});
$("#downloadUpdate").addEventListener("click", () =>
  window.suanli.openExternal(
    status?.updates?.url || "https://github.com/huohuo143/codex-pulse/releases",
  ),
);
$("#previewPrices").addEventListener("click", async () => {
  const result = await window.suanli.previewPrices();
  if (!result) return;
  const target = $("#pricePreview");
  target.replaceChildren();
  const pre = document.createElement("pre");
  pre.textContent = result.changes
    .map(
      (c) =>
        c.model +
        "\n旧：" +
        JSON.stringify(c.before) +
        "\n新：" +
        JSON.stringify(c.after),
    )
    .join("\n\n");
  const apply = document.createElement("button");
  apply.textContent = "确认应用上述价格";
  apply.addEventListener("click", async () => {
    await window.suanli.applyPrices(result.token);
    target.replaceChildren();
    showToast("价格已应用，金额已重新计算");
  });
  target.append(pre, apply);
});
$("#markRadar").addEventListener("click", async () => {
  await window.suanli.markRadar({
    id: $("#radarRecord").value,
    outcome: $("#radarOutcome").value === "true",
    source: $("#radarEvidence").value,
  });
  showToast("核实结果已保存");
});
$("#forecastDetails").addEventListener("toggle", () => {
  if ($("#forecastDetails").open !== !!settings.expandedDetails?.evidence)
    window.suanli.setDetail({
      id: "evidence",
      open: $("#forecastDetails").open,
    });
});
function applyExtraSettings() {
  for (const id of bools) $("#" + id).checked = !!settings[id];
  for (const id of ["themeMode", "alertPreset"])
    $("#" + id).value =
      settings[id] || { themeMode: "system", alertPreset: "standard" }[id];
  document.body.dataset.theme =
    settings.themeMode === "system"
      ? settings.systemDark
        ? "dark"
        : "light"
      : settings.themeMode;
  document.body.classList.toggle("show-five", !!settings.showFiveHour);
  document.body.classList.toggle("hide-weekly", !settings.showWeekly);
  document.body.classList.toggle("hide-tokens", !settings.showTokens);
  document.body.classList.toggle("hide-radar", !settings.showRadar);
  $("#forecastDetails").open = !!settings.expandedDetails?.evidence;
  if (typeof tiboDetail !== "undefined")
    tiboDetail.open = !!settings.expandedDetails?.tibo;
  $$("[data-card]").forEach(
    (el) => (el.checked = !!settings.cards?.[el.dataset.card]?.enabled),
  );
  $$("[data-pin]").forEach(
    (el) => (el.checked = !!settings.cards?.[el.dataset.pin]?.alwaysOnTop),
  );
}
const overviewPanel = $('[data-panel="overview"]'),
  forecastCard = $("#forecastSummary").closest("article");
for (const node of [
  overviewPanel.querySelector(".summary-card"),
  overviewPanel.querySelector(".metric-grid"),
  overviewPanel.querySelector(".credits-card"),
  forecastCard,
  overviewPanel.querySelector(".radar-stack"),
  $("#costNote"),
])
  overviewPanel.append(node);
const evidence = document.createElement("details");
evidence.id = "radarEvidenceDetails";
evidence.innerHTML =
  '<summary>研判依据与公开原帖</summary><div id="radarEvidence"></div>';
$(".radar-card").append(evidence);
const tiboDetail = document.createElement("details");
tiboDetail.innerHTML = "<summary>最新公开动态 / 翻译</summary>";
$(".tibo-latest").before(tiboDetail);
tiboDetail.append($(".tibo-latest"));
tiboDetail.addEventListener("toggle", () => {
  if (tiboDetail.open !== !!settings.expandedDetails?.tibo)
    window.suanli.setDetail({ id: "tibo", open: tiboDetail.open });
});
const metricBar = document.createElement("div");
metricBar.className = "compact-flex-metrics";
metricBar.innerHTML =
  '<span data-metric="five">5h <b data-bind="fiveHour">--%</b></span><span data-metric="tokens">24h <b data-bind="rolling24">--</b></span><span data-metric="credits">Full reset <b data-bind="creditCount">-- 次</b></span>';
$(".compact-view").append(metricBar);
$("#collapseButton").title = "打开独立悬浮框";
let expirySignature = "",
  radarSignature = "";
function renderExtras(next) {
  $("#resetFreshness").textContent =
    stateLabels[next.sourceStates?.reset] || stateLabels.unavailable;
  setAll("fiveHour", percentage(next.fiveHour?.remainingPercent));
  setGauge(
    ".js-five",
    Number(next.fiveHour?.remainingPercent || 0) / 100,
    2 * Math.PI * 49,
  );
  setGauge(
    ".js-five-hero",
    Number(next.fiveHour?.remainingPercent || 0) / 100,
    2 * Math.PI * 65,
  );
  const q = stateLabels[next.sourceStates?.quota] || stateLabels.unavailable;
  $("#quotaFreshness").textContent = q;
  $("#quotaFreshness").dataset.state = next.sourceStates?.quota;
  const balance = next.flexible;
  $("#flexibleBalance").textContent =
    "灵活额度：" +
    (balance?.unlimited
      ? "不限额"
      : balance?.balanceCredits != null
        ? balance.balanceCredits.toLocaleString() +
          " credits · " +
          money(balance.amountUSD)
        : "--") +
    " · " +
    (stateLabels[next.sourceStates?.flexible] || stateLabels.unavailable);
  const forecast = next.forecast;
  $("#forecastSummary").textContent =
    forecast?.reason || "等待更多官方额度样本";
  $("#forecastSummary").dataset.risk = forecast?.risk;
  $("#forecastEvidence").textContent =
    forecast?.ratePerHour != null
      ? "消耗速度 " +
        forecast.ratePerHour.toFixed(2) +
        " 百分点/小时 · 均衡日上限 " +
        forecast.balancedDailyPercent.toFixed(1) +
        "% · 预计耗尽 " +
        formatDate(forecast.estimatedExhaustion) +
        " · 区间 " +
        formatDate(forecast.earliestExhaustion) +
        " 至 " +
        formatDate(forecast.latestExhaustion) +
        " · " +
        forecast.sampleCount +
        " 个样本"
      : "至少需要 4 个官方样本、跨度 2 小时及 0.5 个百分点变化。";
  const a = next.analysis;
  $("#advancedAnalysis").innerHTML = a
    ? '<div class="analysis-numbers"><span>近 7 天对比 <b>' +
      (a.sevenDayChangePercent == null
        ? "--"
        : a.sevenDayChangePercent.toFixed(1) + "%") +
      "</b></span><span>月末预计 <b>" +
      compactNumber(a.projectedMonthTokens) +
      "</b></span><span>日均 <b>" +
      compactNumber(a.averageDailyTokens) +
      "</b></span></div><ul>" +
      a.insights.map((t) => "<li>" + htmlEscape(t) + "</li>").join("") +
      "</ul>"
    : "正在建立分析基线";
  budgetEditor.sync(next);
  $("#budgetStatuses").innerHTML =
    (a?.projectBudgets || [])
      .map(
        (r) =>
          '<div class="budget-row"><b>' +
          htmlEscape(DisplayLabels.projectName(r.budget.projectName, r.budget.projectPath)) +
          "</b><span>" +
          riskLabels[r.risk] +
          " · 已用 " +
          compactNumber(r.usedTokens) +
          " / " +
          compactNumber(r.budget.monthlyTokenLimit) +
          " · 剩余 " +
          compactNumber(r.remainingTokens) +
          " · 月末预计 " +
          compactNumber(r.projectedMonthTokens) +
          "</span></div>",
      )
      .join("") || "<p>尚未设置预算</p>";
  $("#healthChecks").innerHTML = (next.health || [])
    .map(
      (h) =>
        '<div class="health-row"><span>' +
        htmlEscape(h.label) +
        '</span><b data-health="' +
        h.state +
        '">' +
        ({
          healthy: "正常",
          warning: "需关注",
          critical: "异常",
          unknown: "待确认",
        }[h.state] || "待确认") +
        "</b></div>",
    )
    .join("");
  $("#healthEvents").textContent = (next.events || [])
    .slice(-15)
    .map((e) => formatDate(e.at) + " " + e.message)
    .join("\n");
  $("#updateState").textContent = next.updates?.message || "尚未检查更新";
  $("#downloadUpdate").disabled = false;
  $("#checkUpdates").disabled = Date.parse(next.updates?.nextRetryAt) > Date.now();
  const expiry = next.creditExpiry,
    es = JSON.stringify(expiry);
  if (es !== expirySignature) {
    expirySignature = es;
    $("#expiryDate").value = expiry?.date || "";
    $("#expiryEvidence").value = expiry?.evidence || "";
    $("#expiryConfirmed").checked = !!expiry?.confirmed;
  }
  $("#expiryStatus").textContent = expiry?.confirmed
    ? "已核实当前账户；更换账户后需重新确认"
    : "未核实：不会作为官方到期日期";
  renderStacked(next.tokenStats.daily || []);
  renderRadarExtras();
}
function renderRadarExtras() {
  if ($("#radarEvidence")) {
    $("#radarEvidence").replaceChildren();
    const signals = document.createElement("p");
    signals.textContent = (radar?.prediction?.signals || []).join("；");
    $("#radarEvidence").append(signals);
    for (const post of (radar?.posts || [])) {
      const item = document.createElement("div");
      item.className = "public-post";
      const original = document.createElement("p");
      original.textContent = post.originalText || "公开页面摘要：" + (post.publicSummaryZh || "");
      const translation = document.createElement("p");
      translation.textContent = post.publicSummaryZh ? "公开摘要不作为模型分析依据；英文全文请查看原帖。" : post.translationZh || "";
      const button = document.createElement("button");
      button.textContent = "查看原帖 ↗";
      button.addEventListener("click", () =>
        window.suanli.openExternal(post.url),
      );
      item.append(original, translation, button);
      $("#radarEvidence").append(item);
    }
  }
  const e = radar?.evaluation;
  $("#brierScore").textContent = e?.n
    ? "Brier score " + e.brier.toFixed(4) + " · n = " + e.n
    : "暂无已核实样本 · n = 0";
  const rows = e?.records || [],
    sig = rows.map((r) => r.id + ":" + r.outcome).join(",");
  if (sig !== radarSignature) {
    radarSignature = sig;
    const prev = $("#radarRecord").value;
    $("#radarRecord").replaceChildren(
      ...rows
        .filter((r) => Date.parse(r.endsAt) <= Date.now())
        .map((r) => {
          const o = document.createElement("option");
          o.value = r.id;
          o.textContent =
            formatDate(r.generatedAt) +
            " · " +
            Math.round(r.probability * 100) +
            "%" +
            (r.outcome == null ? " · 未标注" : " · 已标注");
          return o;
        }),
    );
    if (rows.some((r) => r.id === prev)) $("#radarRecord").value = prev;
  }
}
function renderStacked(rows) {
  const target = $("#stackedDaily");
  if (!target || !rows.length) return;
  const devices = status?.tokenStats?.devices?.length
    ? status.tokenStats.devices
    : [{ deviceName: "本机", daily: rows }];
  const colors = [
    "#28b7a0",
    "#5a9beb",
    "#a186dc",
    "#eb9b64",
    "#d87eab",
    "#afbf59",
  ];
  const totals = rows.map((row) =>
      devices.reduce(
        (sum, d) =>
          sum + (d.daily?.find((r) => r.key === row.key)?.totalTokens || 0),
        0,
      ),
    ),
    peak = Math.max(1, ...totals);
  $("#dailyPeak").textContent = "峰值 " + compactNumber(Math.max(...totals));
  target.replaceChildren(
    ...rows.map((row, i) => {
      const col = document.createElement("div");
      col.className = "stack-column";
      const stack = document.createElement("div");
      stack.className = "stack-bars";
      const details = [];
      devices.forEach((d, index) => {
        const tokens =
          d.daily?.find((r) => r.key === row.key)?.totalTokens || 0;
        const bar = document.createElement("i");
        bar.style.height = (tokens / peak) * 160 + "px";
        bar.style.background = colors[index % colors.length];
        stack.append(bar);
        details.push(
          (d.deviceName || d.deviceID) +
            ": " +
            tokens.toLocaleString() +
            " Token",
        );
      });
      col.title = row.key + "\n" + details.join("\n");
      const label = document.createElement("small");
      label.textContent = row.label;
      col.append(stack, label);
      return col;
    }),
  );
  $("#deviceLegend").replaceChildren(
    ...devices.map((d, i) => {
      const label = document.createElement("span");
      const dot = document.createElement("i");
      dot.style.background = colors[i % colors.length];
      label.append(dot, document.createTextNode(d.deviceName || d.deviceID));
      return label;
    }),
  );
}

if (status) renderExtras(status);
if (settings.surface) applyExtraSettings();
