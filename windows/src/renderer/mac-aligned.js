// Layout and chart semantics follow the local macOS 2.12.2 dashboard.
const flexibleCard = document.createElement("article");
flexibleCard.className = "card flexible-card";
flexibleCard.innerHTML = '<div class="flexible-symbol" aria-hidden="true">▰</div><div class="flexible-copy"><h3>Codex 灵活额度</h3><p>ChatGPT/Codex 灵活额度 · 非 API 余额</p><small id="flexibleState"></small><div id="flexibleExpiry"></div></div><div class="flexible-value"><strong id="flexibleUSD">--</strong><span id="flexibleCredits">等待余额数据</span></div>';
overviewPanel.querySelector(".summary-card").after(flexibleCard);
$("#flexibleBalance").hidden = true;
for (const node of [forecastCard, overviewPanel.querySelector(".radar-stack"), overviewPanel.querySelector(".credits-card"), overviewPanel.querySelector(".metric-grid"), $("#costNote")]) overviewPanel.append(node);
$("#maximizeButton").addEventListener("click", () => window.suanli.windowAction("maximize"));
window.addEventListener("online", () => window.suanli.networkOnline());
for (const gauge of $$(".compact-gauge")) {
  const group = document.createElement("div");
  group.className = "compact-quota";
  gauge.before(group);
  group.append(gauge);
  const reset = document.createElement("small");
  reset.className = "gauge-reset";
  reset.dataset.bind = "compactReset";
  group.append(reset);
}
for (const center of $$(".gauge-center")) {
  const percent = center.querySelector('[data-bind="weekly"]');
  if (!percent) continue;
  const caption = document.createElement("div"); caption.className = "quota-caption";
  const label = percent.nextElementSibling;
  label.textContent = "7天";
  percent.before(caption); caption.append(percent, label);
}
const forecastMetrics = document.createElement("div");
forecastMetrics.className = "forecast-metrics";
forecastMetrics.innerHTML = '<div><label>当前速度</label><strong id="forecastRate">--</strong></div><div><label>均衡日上限</label><strong id="forecastDaily">--</strong></div><div><label>重置时预计</label><strong id="forecastRemaining">--</strong></div>';
$("#forecastSummary").after(forecastMetrics);

const batchSettings = document.createElement("article");
batchSettings.className = "card settings-card";
batchSettings.innerHTML = '<h3>灵活额度批次</h3><p>分别记录发放数量、到期日期和来源；推算日期会明确标注，原有单笔记录继续保留。</p><div id="expiryBatches"></div><form id="batchForm" class="batch-form"><label>发放数量（credits）<input name="credits" type="number" min="0.01" step="any" required></label><label>发放日期<input name="grantedOn" type="date" required></label><label>到期日期<input name="expiresOn" type="date" required></label><label>日期依据<select name="kind"><option value="confirmed">已核实官方日期</option><option value="estimated">个人推算日期</option></select></label><label class="batch-evidence">来源依据<input name="evidence" minlength="5" maxlength="1000" placeholder="填写官方来源或推算依据" required></label><button type="submit" class="text-button">添加批次</button></form>';
$("#newSettings").children[3].after(batchSettings);
$("#batchForm").addEventListener("submit", async e => {
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target));
  try {
    await window.suanli.setExpiryBatch({ ...data, credits: Number(data.credits) });
    e.target.reset(); showToast("批次已保存");
  } catch (error) { showToast(ErrorMessages.readable(error, "批次保存失败"), "error"); }
});

const historyCard = document.createElement("article");
historyCard.className = "card chart-card quota-history-card";
historyCard.innerHTML = '<div class="section-heading"><div><h3>官方额度历史</h3><p id="quotaHistoryCount">7 天剩余额度 · 0 个采样点</p></div><button id="exportHistory" class="text-button" disabled>导出样本</button></div><div class="period-toggle history-period" role="group" aria-label="官方额度历史范围"><button data-history-days="1">24 小时</button><button data-history-days="7" class="selected">7 天</button><button data-history-days="30">30 天</button></div><div id="quotaHistoryChart" tabindex="0" aria-label="官方额度历史，左右方向键查看样本"></div><div id="quotaHistoryInspection" aria-live="polite"></div><p class="history-note">仅当前账户本机采样。周期变化、额度上调或超过 90 分钟无采样时断线；历史数值不代表实时余额。</p>';
$('[data-panel="trends"]').prepend(historyCard);
let historyDays = 7, historyRows = [], historyAt = Date.now(), historySelected = null;
$$("[data-history-days]").forEach(b => b.addEventListener("click", () => {
  historyDays = Number(b.dataset.historyDays);
  $$("[data-history-days]").forEach(n => { const selected = n === b; n.classList.toggle("selected", selected); n.setAttribute("aria-pressed", String(selected)); });
  historySelected = null; renderQuotaHistory(status);
}));
$("#exportHistory").addEventListener("click", async () => {
  const file = await window.suanli.exportQuotaHistory(historyDays);
  if (file) showToast("官方额度样本已导出");
});
function svgNode(tag, attrs, label) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (label != null) node.textContent = label;
  return node;
}
function inspectHistory(row) {
  const target = $("#quotaHistoryInspection");
  target.replaceChildren();
  if (!row) return;
  const title = document.createElement("strong"), detail = document.createElement("span");
  title.textContent = `${historySelected ? "采样" : "末次采样"} ${formatDate(row.recordedAt, { year: "numeric" })} · 剩余 ${row.remainingPercent.toFixed(1)}%`;
  detail.textContent = "当时的官方重置时间：" + formatDate(row.resetsAt, { year: "numeric" });
  target.append(title, detail);
  const marker = $("#historyMarker");
  if (marker) {
    marker.setAttribute("cx", 8 + ((Date.parse(row.recordedAt) - (historyAt - historyDays * 86400000)) / (historyDays * 86400000)) * 640);
    marker.setAttribute("cy", 12 + (1 - row.remainingPercent / 100) * 184);
    marker.setAttribute("visibility", historySelected ? "visible" : "hidden");
  }
}
function renderQuotaHistory(next) {
  if (!next) return;
  historyAt = Date.parse(next.generatedAt) || Date.now();
  historyRows = QuotaHistory.points(next.quotaHistory || [], historyDays, historyAt);
  $("#quotaHistoryCount").textContent = "7 天剩余额度 · " + historyRows.length + " 个采样点";
  $("#exportHistory").disabled = !historyRows.length;
  const target = $("#quotaHistoryChart");
  target.replaceChildren();
  if (!historyRows.length) {
    target.innerHTML = '<div class="history-empty"><span aria-hidden="true">⌁</span><b>暂无官方额度历史</b><p>保持应用运行，成功读取官方额度后会积累样本。</p></div>';
    inspectHistory(null); return;
  }
  const svg = svgNode("svg", { viewBox: "0 0 700 235", role: "img", "aria-label": `官方7天剩余额度，${historyRows.length}个采样点` });
  for (let p = 0; p <= 100; p += 25) {
    const y = 12 + (1 - p / 100) * 184;
    svg.append(svgNode("line", { x1: 8, x2: 648, y1: y, y2: y, class: "history-grid" }), svgNode("text", { x: 655, y: y + 4, class: "history-axis" }, p + "%"));
  }
  for (let i = 0; i < 4; i++) {
    const x = 8 + i * 640 / 3, at = historyAt - historyDays * 86400000 + i * historyDays * 86400000 / 3;
    const label = new Date(at).toLocaleString("zh-CN", historyDays === 1 ? { hour: "2-digit", minute: "2-digit" } : { month: "numeric", day: "numeric" });
    svg.append(svgNode("text", { x, y: 223, "text-anchor": i === 0 ? "start" : i === 3 ? "end" : "middle", class: "history-axis" }, label));
  }
  const segments = new Map();
  for (const row of QuotaHistory.displayPoints(historyRows)) {
    const x = 8 + (Date.parse(row.recordedAt) - (historyAt - historyDays * 86400000)) / (historyDays * 86400000) * 640,
      y = 12 + (1 - row.remainingPercent / 100) * 184;
    if (!segments.has(row.segment)) segments.set(row.segment, []);
    segments.get(row.segment).push([x, y]);
  }
  for (const rows of segments.values()) {
    if (rows.length === 1) svg.append(svgNode("circle", { cx: rows[0][0], cy: rows[0][1], r: 3, class: "history-point" }));
    else svg.append(svgNode("polyline", { points: rows.map(p => p.join(",")).join(" "), class: "history-line" }));
  }
  svg.append(svgNode("circle", { id: "historyMarker", r: 5, visibility: "hidden", class: "history-marker" }));
  target.append(svg);
  const previous = historyRows.find(r => r.recordedAt === historySelected);
  historySelected = previous ? historySelected : null;
  inspectHistory(previous || historyRows.at(-1));
}
$("#quotaHistoryChart").addEventListener("pointermove", e => {
  const svg = $("#quotaHistoryChart svg");
  if (!svg || !historyRows.length) return;
  const rect = svg.getBoundingClientRect(), x = (e.clientX - rect.left) / rect.width * 700;
  const row = QuotaHistory.nearestPoint(historyRows, historyAt - historyDays * 86400000 + Math.max(0, Math.min(1, (x - 8) / 640)) * historyDays * 86400000);
  historySelected = row.recordedAt; inspectHistory(row);
});
$("#quotaHistoryChart").addEventListener("pointerleave", () => { historySelected = null; inspectHistory(historyRows.at(-1)); });
$("#quotaHistoryChart").addEventListener("keydown", e => {
  if (!["ArrowLeft", "ArrowRight"].includes(e.key) || !historyRows.length) return;
  e.preventDefault();
  let index = historyRows.findIndex(r => r.recordedAt === historySelected);
  if (index < 0) index = historyRows.length - 1;
  index = Math.max(0, Math.min(historyRows.length - 1, index + (e.key === "ArrowLeft" ? -1 : 1)));
  historySelected = historyRows[index].recordedAt; inspectHistory(historyRows[index]);
});

const hourlyCard = $("#hourlyChart").closest("article"), dailyCard = $("#stackedDaily").closest("article");
const usageToggle = document.createElement("div");
usageToggle.className = "period-toggle";
usageToggle.innerHTML = '<button data-usage-period="hourly" class="selected">24 小时</button><button data-usage-period="daily">按天</button>';
hourlyCard.querySelector(".section-heading").append(usageToggle);
const dailyPane = document.createElement("div");
dailyPane.hidden = true;
for (const child of [...dailyCard.children]) if (!child.classList.contains("section-heading")) dailyPane.append(child);
dailyPane.append($("#dailyPeak"));
hourlyCard.append(dailyPane); dailyCard.remove();
$$("[data-usage-period]").forEach(b => b.addEventListener("click", () => {
  const daily = b.dataset.usagePeriod === "daily";
  dailyPane.hidden = !daily; $("#hourlyChart").hidden = daily;
  hourlyCard.querySelector("h3").textContent = daily ? "最近30天" : "最近24小时";
  hourlyCard.querySelector("p").textContent = daily ? "按源设备日期逐日汇总；横向滚动查看完整月份" : "按本机时区显示；滚动值按精确时间戳计算";
  $$("[data-usage-period]").forEach(n => n.classList.toggle("selected", n === b));
}));
let batchesSignature = "";
function renderMacAligned(next) {
  const q = stateLabels[next.sourceStates?.quota] || stateLabels.unavailable;
  $("#summaryQuotaState").textContent = "✓ " + q;
  $("#summaryResetState").textContent = stateLabels[next.sourceStates?.reset] || stateLabels.unavailable;
  const f = next.forecast;
  $("#quotaFreshness").textContent = (riskLabels[f?.risk] || "学习中") + " · " + ({ low: "低置信度", medium: "中置信度", high: "高置信度" }[f?.confidence] || "低置信度");
  $("#quotaFreshness").dataset.risk = f?.risk || "insufficientData";
  $("#forecastRate").textContent = f?.ratePerHour != null ? f.ratePerHour.toFixed(2) + " 点/h" : "--";
  $("#forecastDaily").textContent = f?.balancedDailyPercent != null && Number.isFinite(f.balancedDailyPercent) ? f.balancedDailyPercent.toFixed(1) + "%" : "--";
  $("#forecastRemaining").textContent = f?.expectedRemainingAtReset != null ? f.expectedRemainingAtReset.toFixed(1) + "%" : "--";
  const cost = next.tokenStats.cost24Hours;
  $("#summaryCostCoverage").textContent = next.statisticsLoading ? "首次统计中，金额暂未就绪" : "按当前价格表折算 · 计价覆盖 " + Math.round((cost?.coverage || 0) * 100) + "%";
  $("#summaryUnpriced").textContent = cost?.unpricedModels?.length ? "未计价：" + cost.unpricedModels.join("、") : "";
  setAll("fiveReset", next.fiveHour?.resetsAt ? "5小时重置倒计时 " + countdown(next.fiveHour.resetsAt) : "5小时额度暂无官方窗口数据");
  const windowQuota = settings.showWeekly ? next.weekly : settings.showFiveHour ? next.fiveHour : null;
  const remaining = Date.parse(windowQuota?.resetsAt) - Date.now();
  setAll("compactReset", Number.isFinite(remaining) ? remaining > 0 ? `距重置 ${Math.floor(remaining / 86400000)}天 ${Math.floor(remaining % 86400000 / 3600000)}小时` : "等待新周期" : "重置时间待更新");
  $("#flexibleUSD").textContent = next.flexible?.unlimited ? "不限额" : next.flexible?.amountUSD != null ? "US" + money(next.flexible.amountUSD) : "--";
  $("#flexibleCredits").textContent = next.flexible?.balanceCredits != null ? next.flexible.balanceCredits.toLocaleString() + " credits" : "等待余额数据";
  $("#flexibleState").textContent = "✓ " + (stateLabels[next.sourceStates?.flexible] || stateLabels.unavailable);
  const batches = next.creditExpiryBatches || [];
  $("#flexibleExpiry").replaceChildren();
  const dates = batches.filter(b => b.expiresOn >= new Date().toLocaleDateString("sv-SE"));
  for (const row of dates) {
    const line = document.createElement("small");
    line.textContent = `${row.credits.toLocaleString()} credits · ${row.expiresOn} 到期${row.kind === "estimated" ? "（个人推算）" : "（已核实）"}`;
    line.title = row.evidence; $("#flexibleExpiry").append(line);
  }
  if (!dates.length) $("#flexibleExpiry").textContent = next.creditExpiry?.confirmed ? "已核实到期日：" + next.creditExpiry.date : "暂无已确认到期日";
  const signature = JSON.stringify(batches);
  if (signature !== batchesSignature) {
    batchesSignature = signature; $("#expiryBatches").replaceChildren();
    for (const row of batches) {
      const item = document.createElement("div"); item.className = "batch-row";
      const text = document.createElement("span");
      text.textContent = `${row.credits.toLocaleString()} credits · ${row.grantedOn} 发放 · ${row.expiresOn} 到期 · ${row.kind === "confirmed" ? "已核实" : "个人推算"}\n${row.evidence}`;
      const button = document.createElement("button"); button.className = "text-button"; button.textContent = "删除";
      button.addEventListener("click", () => window.suanli.setExpiryBatch({ id: row.id, remove: true }));
      item.append(text, button); $("#expiryBatches").append(item);
    }
    if (!batches.length) $("#expiryBatches").textContent = "当前账户暂无批次记录";
  }
  renderQuotaHistory(next);
}
setInterval(() => { if (status) renderMacAligned(status); }, 60000);
if (status) renderMacAligned(status);
