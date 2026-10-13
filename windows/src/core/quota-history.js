(function (root) {
  const DAY = 86400000;
  function points(snapshots, days = 7, now = Date.now()) {
    if (![1, 7, 30].includes(days)) throw new Error("未知历史范围");
    const unique = new Map();
    for (const row of snapshots || []) {
      const at = Date.parse(row.recordedAt), reset = Date.parse(row.resetsAt);
      if (Number.isFinite(at) && Number.isFinite(reset) && at >= now - days * DAY && at <= now && reset > at &&
          Number.isFinite(row.remainingPercent) && row.remainingPercent >= 0 && row.remainingPercent <= 100 &&
          Number.isFinite(row.windowMinutes) && Math.abs(row.windowMinutes - 10080) <= 60)
        unique.set(at, { recordedAt: row.recordedAt, resetsAt: row.resetsAt, remainingPercent: row.remainingPercent, windowMinutes: row.windowMinutes });
    }
    const rows = [...unique.values()].sort((a, b) => Date.parse(a.recordedAt) - Date.parse(b.recordedAt));
    let segment = 0;
    return rows.map((row, i) => {
      const prev = rows[i - 1];
      if (prev && (Math.abs(Date.parse(row.resetsAt) - Date.parse(prev.resetsAt)) > 300000 ||
          row.remainingPercent > prev.remainingPercent + 0.1 || Date.parse(row.recordedAt) - Date.parse(prev.recordedAt) > 5400000)) segment++;
      return { ...row, segment };
    });
  }
  function displayPoints(rows) {
    if (rows.length <= 1200) return rows;
    const stride = Math.ceil(rows.length / 300), output = [];
    for (let start = 0; start < rows.length;) {
      let end = start + 1, low = start, high = start;
      while (end < rows.length && end - start < stride && rows[end].segment === rows[start].segment) end++;
      for (let i = start; i < end; i++) {
        if (rows[i].remainingPercent < rows[low].remainingPercent) low = i;
        if (rows[i].remainingPercent > rows[high].remainingPercent) high = i;
      }
      output.push(...[...new Set([start, low, high, end - 1])].sort((a, b) => a - b).map(i => rows[i]));
      start = end;
    }
    return output;
  }
  function nearestPoint(rows, at) {
    if (!rows.length) return null;
    let lo = 0, hi = rows.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (Date.parse(rows[mid].recordedAt) < at) lo = mid + 1; else hi = mid; }
    if (!lo) return rows[0];
    if (lo === rows.length) return rows.at(-1);
    return at - Date.parse(rows[lo - 1].recordedAt) <= Date.parse(rows[lo].recordedAt) - at ? rows[lo - 1] : rows[lo];
  }
  function makeCSV(rows, generatedAt = new Date()) {
    return "\uFEFF" + ["Codex 脉动官方额度历史", "生成时间," + generatedAt.toISOString(),
      "说明,仅当前账户本机记录的官方7天额度样本；时间为UTC；不包含账户标识或会话内容",
      "采样时间(UTC),剩余额度(%),官方重置时间(UTC),窗口(分钟),曲线分段",
      ...rows.map(r => [new Date(r.recordedAt).toISOString(), r.remainingPercent.toFixed(3), new Date(r.resetsAt).toISOString(), Math.round(r.windowMinutes), r.segment + 1].join(","))].join("\r\n") + "\r\n";
  }
  const api = { points, displayPoints, nearestPoint, makeCSV };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.QuotaHistory = api;
})(globalThis);
