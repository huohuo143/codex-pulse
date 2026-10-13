const LABELS = {
  fresh: "官方数据已更新",
  cached: "使用缓存 · 等待官方更新",
  expired: "数据已过期",
  waitingForReset: "等待新周期数据",
  unavailable: "数据状态待确认",
};
function freshness(meta, now = Date.now(), resetAt) {
  const sampled = Date.parse(meta?.sampledAt),
    success = Date.parse(meta?.lastSuccessAt);
  if (
    !Number.isFinite(sampled) ||
    !Number.isFinite(success) ||
    sampled > now + 5000 ||
    success > now + 5000
  )
    return "unavailable";
  if (resetAt && Date.parse(resetAt) <= now) return "waitingForReset";
  if (now - Math.min(sampled, success) > 1800000) return "expired";
  return meta.failure || now - success > 300000 ? "cached" : "fresh";
}
function succeed(
  source,
  now = Date.now(),
  sampledAt = new Date(now).toISOString(),
) {
  return {
    source,
    sampledAt,
    lastAttemptAt: new Date(now).toISOString(),
    lastSuccessAt: new Date(now).toISOString(),
    failure: null,
  };
}
function fail(meta, now = Date.now(), failure = "读取失败") {
  return { ...meta, lastAttemptAt: new Date(now).toISOString(), failure };
}
function visible(meta, now, resetAt) {
  return ["fresh", "cached"].includes(freshness(meta, now, resetAt));
}
module.exports = { freshness, succeed, fail, visible, LABELS };
