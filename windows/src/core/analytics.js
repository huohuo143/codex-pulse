// Algorithms and thresholds ported from QuotaForecast.swift / UsageAnalytics.swift 2.11.0.
const HOUR = 3600000,
  DAY = 24 * HOUR;
function percentile(values, p = 0.5) {
  const s = [...values].sort((a, b) => a - b);
  if (!s.length) return 0;
  const n = (s.length - 1) * p,
    l = Math.floor(n),
    r = Math.ceil(n);
  return s[l] * (1 - (n - l)) + s[r] * (n - l);
}
function rates(rows) {
  const out = [];
  for (let l = 0; l < rows.length - 1; l++)
    for (let r = l + 1; r < rows.length; r++) {
      const h =
          (Date.parse(rows[r].recordedAt) - Date.parse(rows[l].recordedAt)) /
          HOUR,
        d = rows[l].remainingPercent - rows[r].remainingPercent;
      if (h >= 0.5 && d > 0) out.push(d / h);
    }
  return out;
}
function forecast(snapshots, current, now = Date.now()) {
  const reset = Date.parse(current?.resetsAt),
    left = current?.remainingPercent;
  const result = {
    generatedAt: new Date(now).toISOString(),
    currentRemainingPercent: left ?? null,
    resetsAt: current?.resetsAt || null,
    risk: "insufficientData",
    confidence: "low",
    sampleCount: 0,
    dataSpanHours: 0,
    ratePerHour: null,
    balancedDailyPercent: reset > now ? (left / (reset - now)) * DAY : null,
    reason: "暂无官方 7 天额度数据",
  };
  if (!current) return result;
  if (reset <= now) {
    result.reason = "等待新的官方额度周期";
    return result;
  }
  if (now - Date.parse(current.recordedAt) > 1800000) {
    result.reason = "额度数据超过 30 分钟未更新";
    return result;
  }
  let rows = snapshots
    .filter(
      (s) =>
        Math.abs(Date.parse(s.resetsAt) - reset) <= 300000 &&
        Date.parse(s.recordedAt) >= now - 72 * HOUR &&
        Date.parse(s.recordedAt) <= now + 60000,
    )
    .sort((a, b) => Date.parse(a.recordedAt) - Date.parse(b.recordedAt));
  if (
    !rows.some(
      (s) =>
        Math.abs(Date.parse(s.recordedAt) - Date.parse(current.recordedAt)) <
        1000,
    )
  )
    rows.push(current);
  rows.sort((a, b) => Date.parse(a.recordedAt) - Date.parse(b.recordedAt));
  let start = 0;
  for (let i = 1; i < rows.length; i++)
    if (rows[i].remainingPercent - rows[i - 1].remainingPercent > 1) start = i;
  rows = rows.slice(start);
  rows = [
    ...new Map(
      rows.map((s) => [Math.floor(Date.parse(s.recordedAt) / 900000), s]),
    ).values(),
  ];
  const span = rows.length
    ? (Date.parse(rows.at(-1).recordedAt) - Date.parse(rows[0].recordedAt)) /
      HOUR
    : 0;
  Object.assign(result, {
    sampleCount: rows.length,
    dataSpanHours: span,
    reason: "正在学习额度节奏（至少需要 4 个样本、2 小时和 0.5 个百分点变化）",
  });
  if (rows.length < 4 || span < 2 || rows[0].remainingPercent - left < 0.5)
    return result;
  const wr = [];
  for (const [hours, weight] of [
    [6, 0.5],
    [24, 0.35],
    [72, 0.15],
  ]) {
    const subset = rows.filter(
      (s) =>
        Date.parse(s.recordedAt) >=
        Date.parse(current.recordedAt) - hours * HOUR,
    );
    if (
      subset.length >= 4 &&
      Date.parse(subset.at(-1).recordedAt) - Date.parse(subset[0].recordedAt) >=
        2 * HOUR
    ) {
      const v = rates(subset);
      if (v.length) wr.push({ rate: percentile(v), weight });
    }
  }
  const all = rates(rows);
  if (!wr.length || !all.length) {
    result.reason = "有效下降样本不足，暂不推断耗尽时间";
    return result;
  }
  const rate =
      wr.reduce((a, r) => a + r.rate * r.weight, 0) /
      wr.reduce((a, r) => a + r.weight, 0),
    slow = Math.max(0.0001, percentile(all, 0.25)),
    fast = Math.max(rate, percentile(all, 0.75));
  const estimated = now + (left / rate) * HOUR,
    early = now + (left / fast) * HOUR,
    late = now + (left / slow) * HOUR;
  const risk =
    left <= 5 || estimated <= reset - 6 * HOUR
      ? "critical"
      : left <= 15 || estimated < reset || (early <= reset && late >= reset)
        ? "caution"
        : early > reset
          ? "healthy"
          : "caution";
  return {
    ...result,
    ratePerHour: rate,
    earliestExhaustion: new Date(early).toISOString(),
    estimatedExhaustion: new Date(estimated).toISOString(),
    latestExhaustion: new Date(late).toISOString(),
    expectedRemainingAtReset: Math.max(
      0,
      Math.min(100, left - (rate * (reset - now)) / HOUR),
    ),
    risk,
    confidence:
      span >= 24 && rows.length >= 12 && (fast - slow) / rate <= 0.75
        ? "high"
        : span >= 6 && rows.length >= 6
          ? "medium"
          : "low",
    reason:
      estimated < reset
        ? "按当前节奏，额度可能撑不到重置"
        : left <= 15
          ? "按当前节奏可撑到重置，但剩余额度较低"
          : "按当前节奏，额度预计可撑到重置",
  };
}
function recordSnapshot(rows, window, recordedAt, now = Date.now()) {
  if (
    !window ||
    !Number.isFinite(Date.parse(recordedAt)) ||
    !Number.isFinite(Date.parse(window.resetsAt)) ||
    Math.abs(window.windowMinutes - 10080) > 60 ||
    Date.parse(window.resetsAt) <= Date.parse(recordedAt) ||
    !Number.isFinite(window.remainingPercent) || window.remainingPercent < 0 || window.remainingPercent > 100
  )
    return rows;
  const next = { ...window, recordedAt },
    last = rows.at(-1);
  if (last) {
    const elapsed = Date.parse(recordedAt) - Date.parse(last.recordedAt),
      changed = Math.abs(next.remainingPercent - last.remainingPercent) >= 0.1,
      resetChanged =
        Math.abs(Date.parse(next.resetsAt) - Date.parse(last.resetsAt)) >
        300000;
    if (elapsed < -60000 || (elapsed < 300000 && !changed && !resetChanged))
      return rows;
  }
  return [...rows, next]
    .filter(
      (s) =>
        Date.parse(s.recordedAt) >= now - 30 * DAY &&
        Date.parse(s.recordedAt) <= now + 300000,
    )
    .slice(-10000);
}
function alerts({
  weekly,
  forecast: prediction,
  credits,
  settings,
  ledger = {},
  fresh = true,
  creditsFresh = true,
  now = Date.now(),
}) {
  const out = [],
    deliveries = [],
    cycle = String(Math.floor(Date.parse(weekly?.resetsAt) / 60000)),
    sent = new Set(ledger.sentKeys || []),
    next = { ...ledger };
  if (!settings.notifications) return { candidates: out, deliveries, ledger };
  const thresholds = {
    standard: [30, 15, 5],
    early: [50, 30, 15],
    urgentOnly: [15, 5],
  }[settings.alertPreset] || [30, 15, 5];
  if (
    fresh &&
    weekly &&
    Date.parse(weekly.resetsAt) > now &&
    settings.thresholdAlerts !== false
  ) {
    const crossed = thresholds
        .filter((t) => weekly.remainingPercent <= t)
        .sort((a, b) => a - b),
      unsent = crossed.filter((t) => !sent.has("threshold." + cycle + "." + t));
    if (unsent.length) {
      out.push(
        "7 天额度剩余 " +
          Math.round(weekly.remainingPercent) +
          "%，已达到 " +
          unsent[0] +
          "% 提醒阈值",
      );
      deliveries.push({ id: "threshold." + cycle + "." + unsent[0], body: out.at(-1), keys: crossed.map(t => "threshold." + cycle + "." + t) });
    }
  }
  if (fresh && prediction && settings.forecastAlerts !== false) {
    if (prediction.risk === "critical" && next.lastRisk !== "critical") {
      next.forecastEpisode = (next.forecastEpisode || 0) + 1;
      next.forecastPending = true;
    }
    if (
      prediction.risk === "critical" &&
      (next.forecastPending ||
        next.lastForecastCycle !== cycle ||
        now - (next.lastForecastCriticalAt || 0) >= 6 * HOUR)
    ) {
      out.push("额度预测进入高风险：" + prediction.reason);
      deliveries.push({ id: "forecast." + cycle + "." + (next.forecastEpisode || 0), body: out.at(-1), forecastCycle: cycle, episode: next.forecastEpisode || 0 });
    }
    if (prediction.risk !== "critical") next.forecastPending = false;
    next.lastRisk = prediction.risk;
  }
  if (creditsFresh && settings.creditAlerts !== false)
    for (const c of credits?.availableCredits || []) {
      const expires = Date.parse(c.expiresAt),
        key = "credit." + [c.grantedAt, c.expiresAt, c.title].join(".");
      if (expires > now && expires - now <= DAY && !sent.has(key)) {
        out.push("Full reset 权益将在 24 小时内到期");
        deliveries.push({ id: key, body: out.at(-1), keys: [key] });
      }
    }
  next.sentKeys = [...sent].slice(-200);
  return { candidates: out, deliveries, ledger: next };
}
function commitAlert(ledger, delivery, now) {
  const next = { ...ledger, sentKeys: [...new Set([...(ledger.sentKeys || []), ...(delivery.keys || [])])].slice(-200) };
  if (delivery.forecastCycle) {
    next.lastForecastCriticalAt = now;
    next.lastForecastCycle = delivery.forecastCycle;
    if (next.forecastEpisode === delivery.episode) next.forecastPending = false;
  }
  return next;
}
function analyze(stats, budgets = [], now = new Date()) {
  const days = stats.daily.slice(-14),
    recent = days.slice(-7),
    previous = days.slice(0, -7).slice(-7),
    sum = (rows) => rows.reduce((s, r) => s + Math.max(0, r.totalTokens), 0),
    r7 = sum(recent),
    p7 = sum(previous),
    change = p7 ? ((r7 - p7) / p7) * 100 : null;
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1),
    monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 1),
    fraction = Math.min(
      1,
      Math.max(1 / 31, (now - monthStart) / (monthEnd - monthStart)),
    );
  const mh = stats.modelHourly || [],
    input = mh.reduce((s, r) => s + r.inputTokens, 0),
    cached = mh.reduce(
      (s, r) => s + Math.min(r.inputTokens, r.cachedInputTokens),
      0,
    ),
    models = new Map();
  for (const r of mh)
    models.set(r.model, (models.get(r.model) || 0) + r.totalTokens);
  const top = [...models].sort((a, b) => b[1] - a[1])[0],
    total = sum(mh),
    projects = stats.monthTopProjects || [],
    projectTotal = sum(projects),
    positive = days.map((r) => r.totalTokens).filter((v) => v > 0),
    baseline = percentile(positive),
    mad = percentile(positive.map((v) => Math.abs(v - baseline)));
  const anomalies =
    days.length >= 7 && positive.length >= 4
      ? recent
          .filter(
            (r) =>
              r.totalTokens >
              baseline + Math.max(3 * mad, baseline * 0.75, 10000),
          )
          .map((r) => ({
            ...r,
            baselineTokens: baseline,
            multiple: r.totalTokens / baseline,
          }))
          .sort((a, b) => b.totalTokens - a.totalTokens)
      : [];
  const projectBudgets = budgets
    .map((b) => {
      const used = projects.find((r) => r.id === b.id)?.totalTokens || 0,
        projected = Math.round(used / fraction),
        limit = b.monthlyTokenLimit;
      return {
        budget: b,
        usedTokens: used,
        remainingTokens: Math.max(0, limit - used),
        projectedMonthTokens: projected,
        progress: used / limit,
        projectedProgress: projected / limit,
        risk: !used
          ? "noUsage"
          : used >= limit
            ? "overBudget"
            : used / limit >= 0.8 || projected > limit
              ? "caution"
              : "healthy",
      };
    })
    .sort(
      (a, b) =>
        ({ overBudget: 3, caution: 2, healthy: 1, noUsage: 0 })[b.risk] -
        { overBudget: 3, caution: 2, healthy: 1, noUsage: 0 }[a.risk],
    );
  const insights = [];
  if (change != null)
    insights.push(
      change >= 25
        ? "近 7 天消耗明显上升"
        : change <= -20
          ? "近 7 天消耗回落"
          : "近 7 天消耗相对稳定",
    );
  if (input)
    insights.push(
      cached / input >= 0.5 ? "缓存复用表现良好" : "缓存复用仍有提升空间",
    );
  if (top && top[1] / total >= 0.65) insights.push("模型使用较集中：" + top[0]);
  if (projectTotal && projects[0].totalTokens / projectTotal >= 0.55)
    insights.push("单一项目消耗集中");
  if (anomalies.length) insights.push("检测到异常高峰：" + anomalies[0].label);
  if (projectBudgets.some((b) => ["overBudget", "caution"].includes(b.risk)))
    insights.push("项目预算需要关注");
  return {
    recent7Tokens: r7,
    previous7Tokens: p7,
    sevenDayChangePercent: change,
    averageDailyTokens: recent.length ? Math.floor(r7 / recent.length) : 0,
    projectedMonthTokens: Math.round(stats.monthTokens / fraction),
    cacheHitRate: input ? cached / input : null,
    topModel: top?.[0] || null,
    topModelShare: total ? top?.[1] / total : null,
    topProjectShare: projectTotal
      ? projects[0].totalTokens / projectTotal
      : null,
    anomalies,
    insights: insights.length ? insights : ["正在建立高级分析基线"],
    projectBudgets,
  };
}
module.exports = { forecast, recordSnapshot, alerts, commitAlert, analyze, percentile };
