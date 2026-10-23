(function(root) {
  function beijing(value) {
    return new Date(value).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });
  }
  function clock(radar, now = Date.now()) {
    const until = Date.parse(radar?.completionUntil);
    if (Number.isFinite(until)) {
      if (now >= until) return { title: '等待新预告', detail: '上一轮到账确认已展示 24 小时', kind: 'waiting' };
      const seconds = Math.ceil((until - now) / 1000), hours = Math.floor(seconds / 3600), minutes = Math.floor(seconds % 3600 / 60);
      return { title: radar.latestLevelLabel, detail: `到账展示剩余 ${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`, kind: 'completed' };
    }
    if (radar?.deadline) return { title: radar.latestLevelLabel, detail: '北京时间 ' + beijing(radar.deadline.at) + (Date.parse(radar.deadline.at) <= now ? ' · 期限已过，等待确认' : ' 前到账'), kind: 'announced' };
    return { title: radar?.latestLevelLabel || '等待动态', detail: '', kind: 'waiting' };
  }
  const api = { clock, beijing };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.RadarDisplay = api;
})(globalThis);
