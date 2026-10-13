function csvCell(value) {
  let text = String(value ?? "");
  if (/^\s*[=+@-]/.test(text) && typeof value === "string") text = "'" + text;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function makeCSV(stats, { cnyRate, generatedAt = new Date() } = {}) {
  cnyRate = Number.isFinite(cnyRate) && cnyRate > 0 ? cnyRate : null;
  const rows = [];
  const add = (...cells) => rows.push(cells.map(csvCell).join(","));
  add("Codex 脉动 2.12.2 用量导出");
  add("生成时间", generatedAt.toISOString());
  add("说明", "金额为 API 等价预估，不是 ChatGPT/Codex 订阅实际账单；Reasoning 已包含在 Output 中，不重复计费");
  add("统计口径", "摘要、小时、日、模型和工作类型均为本机；模型和工作类型按本月统计；最近调用为保留记录");
  add("时间口径", "小时使用完整UTC日期时间；日统计保留源日历日期；无法识别的小时键保留原值，时间留空");
  if (cnyRate) add("USD/CNY", Number(cnyRate).toFixed(4), "Frankfurter");
  add();
  add("摘要", "Token", "USD", "CNY", "金额状态", "计价覆盖率", "价格版本", "未计价模型");
  const summary = [
    ["滚动24小时", stats.rolling24HoursTokens, stats.cost24Hours],
    ["近7天", stats.last7DaysTokens, stats.cost7Days],
    ["本月", stats.monthTokens, stats.costMonth],
  ];
  for (const [name, tokens, cost] of summary)
    add(
      name,
      tokens,
      cost.isUnavailable ? "" : cost.usd.toFixed(6),
      cnyRate && !cost.isUnavailable ? (cost.usd * cnyRate).toFixed(6) : "",
      cost.isUnavailable
        ? "暂无法估算"
        : cost.isPartial
          ? "部分估算"
          : "按当前价格表折算",
      cost.coverage,
      cost.priceVersion,
      (cost.unpricedModels || []).join("、"),
    );
  add();
  add("本机小时(UTC)", "原始小时键", "Token", "Input", "Cached Input", "Output", "Reasoning", "调用");
  for (const row of stats.hourly)
    add(
      hourTimestamp(row.key),
      row.key,
      row.totalTokens,
      row.inputTokens,
      row.cachedInputTokens,
      row.outputTokens,
      row.reasoningOutputTokens,
      row.calls,
    );
  add();
  add("本机逐日用量", "Token", "Input", "Cached Input", "Output", "Reasoning", "调用");
  for (const row of stats.daily || [])
    add(row.key, row.totalTokens, row.inputTokens, row.cachedInputTokens, row.outputTokens, row.reasoningOutputTokens, row.calls);
  add();
  add("设备快照说明", "设备区可能包含本机，不能叠加回本机总量；设备日历日期沿用来源，不推算时区");
  const devices = latestDevices(stats.devices || []);
  add("设备快照汇总", "设备ID", "更新时间(UTC)", "今日Token", "本月Token", "样本数");
  for (const d of devices) add(d.deviceName || d.hostName, d.deviceID, d.updatedAt, d.todayTokens, d.monthTokens, d.sampleCount);
  add();
  add("设备逐日用量", "设备ID", "源设备日期", "Token", "Input", "Cached Input", "Output", "Reasoning", "调用");
  for (const d of devices) for (const row of d.daily || [])
    add(d.deviceName || d.hostName, d.deviceID, row.key, row.totalTokens, row.inputTokens, row.cachedInputTokens, row.outputTokens, row.reasoningOutputTokens, row.calls);
  add();
  add("模型", "Token", "Input", "Cached Input", "Output", "调用");
  const models = new Map();
  for (const row of stats.modelHourly || []) {
    const total = models.get(row.model) || {
      totalTokens: 0,
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      calls: 0,
    };
    for (const field of Object.keys(total)) total[field] += row[field] || 0;
    models.set(row.model, total);
  }
  for (const [model, row] of [...models].sort(
    (a, b) => b[1].totalTokens - a[1].totalTokens,
  ))
    add(
      model,
      row.totalTokens,
      row.inputTokens,
      row.cachedInputTokens,
      row.outputTokens,
      row.calls,
    );
  add();
  add("工作类型", "Token", "调用");
  for (const row of stats.categoryBreakdown || [])
    if (row.totalTokens > 0) add(row.label, row.totalTokens, row.calls);
  add();
  add(
    "最近调用",
    "模型",
    "项目",
    "Input",
    "Cached Input",
    "Output",
    "Token",
    "类型",
  );
  for (const row of stats.recentUsageEvents || [])
    add(
      row.timestamp,
      row.model,
      row.projectName,
      row.inputTokens,
      row.cachedInputTokens,
      row.outputTokens,
      row.totalTokens,
      row.category,
    );
  return `\uFEFF${rows.join("\r\n")}\r\n`;
}

function hourTimestamp(key) {
  if (typeof key !== "string" || !key.trim()) return "";
  const epochHour = Number(key);
  if (/^-?\d+(?:\.\d+)?$/.test(key) && Number.isFinite(epochHour)) {
    const date = new Date(epochHour * 3600000);
    return Number.isFinite(date.getTime()) ? date.toISOString() : "";
  }
  // Swift schema 4 records may use an ISO UTC date-time as their hour key.
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?Z$/.test(key) && Number.isFinite(Date.parse(key)) ? new Date(key).toISOString() : "";
}
function latestDevices(devices) {
  const latest = new Map();
  for (const d of devices) {
    if (typeof d?.deviceID !== "string" || !d.deviceID.trim()) continue;
    const prior = latest.get(d.deviceID);
    if (!prior || (Date.parse(d.updatedAt) || 0) > (Date.parse(prior.updatedAt) || 0)) latest.set(d.deviceID, d);
  }
  return [...latest.values()].sort((a, b) => a.deviceID.localeCompare(b.deviceID));
}
module.exports = { makeCSV, csvCell, hourTimestamp, latestDevices };
