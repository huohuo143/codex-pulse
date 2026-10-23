const bundled = require('./resources/codex-reset-history.json');
const { validDate } = require('./credit-expiry');
const text = html => String(html || '').replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, "'").replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
const attr = (html, name) => html.match(new RegExp('\\b' + name + '\\s*=\\s*["\']([^"\']*)["\']', 'i'))?.[1];
const day = at => new Date(Date.parse(at) + 8 * 3600000).toISOString().slice(0, 10);
function verifiedURL(raw) {
  try {
    const u = new URL(raw);
    return u.protocol === 'https:' && !u.username && !u.password && !u.port && /^(www\.)?(x|twitter)\.com$/.test(u.hostname) && /^\/thsottiaux\/status\/\d+$/.test(u.pathname) ? 'https://x.com' + u.pathname : null;
  } catch { return null; }
}
const postID = url => url ? 'x:' + url.split('/').at(-1) : null;
function completion(raw, now) {
  const e = raw?.completion_observation;
  if (!e || e.status !== 'completed' || typeof e.event_id !== 'string' || !['direct_reset', 'banked_reset', 'reset_card'].includes(e.kind) || !['official_confirmed', 'official', 'stationmaster_confirmed'].includes(e.confirmation_level) || !validDate(e.occurred_on) || e.occurred_on > day(new Date(now).toISOString()) || e.timezone !== 'Asia/Shanghai') return null;
  const announcementURL = verifiedURL(e.announcement_url), completionURL = verifiedURL(e.official_completion_url);
  const at = Date.parse(e.occurred_at);
  return { id: e.event_id, aliases: [e.announcement_event_id, postID(announcementURL), postID(completionURL)].filter(Boolean),
    kind: e.kind === 'direct_reset' ? 'hardReset' : 'resetCard', day: e.occurred_on, usesConfirmationDate: false,
    occurredAt: ['second', 'minute', 'exact'].includes(e.time_precision) && at <= now && day(e.occurred_at) === e.occurred_on ? e.occurred_at : null,
    confirmedAt: e.official_confirmation_published_at || null, confirmation: e.confirmation_level === 'stationmaster_confirmed' ? 'community' : 'official',
    title: e.title_zh || '已完成重置', summary: e.evidence_zh || e.source || '', announcementURL, completionURL, sourceURL: 'https://codexradar.com/current.json' };
}
function parsePage(html, now) {
  if (Buffer.byteLength(html) > 4 * 1024 * 1024) throw new Error('日历来源超过大小上限');
  const section = html.match(/<section\b[^>]*\bid\s*=\s*["']tibo-challenge["'][^>]*>([\s\S]*?)<\/section>/i)?.[1];
  const events = [], monthlyTotals = [];
  for (const article of section?.match(/<article\b[^>]*>[\s\S]*?<\/article>/gi) || []) {
    const type = text(article.match(/<span\b[^>]*class\s*=\s*["'][^"']*t28-event-type[^"']*["'][^>]*>([\s\S]*?)<\/span>/i)?.[1]);
    const title = text(article.match(/<h3\b[^>]*>([\s\S]*?)<\/h3>/i)?.[1]);
    const summary = (article.match(/<p\b[^>]*>[\s\S]*?<\/p>/gi) || []).map(text).join(' ');
    const hard = type.includes('已确认重置'), card = title.includes('重置卡') && /确认已到|已到所有账号|已发放|发放完成/.test(summary);
    if ((!hard && !card) || /尚未确认完成|当前未见完成确认|未核实完成/.test(summary) || !title) continue;
    const links = (article.match(/<a\b[^>]*>[\s\S]*?<\/a>/gi) || []).map(a => ({ url: verifiedURL(attr(a, 'href')), label: text(a) })).filter(a => a.url);
    const times = (article.match(/<time\b[^>]*>[\s\S]*?<\/time>/gi) || []).map(t => attr(t, 'datetime')).filter(t => Number.isFinite(Date.parse(t)));
    const publishedAt = times[0];
    if (!links.length || !publishedAt || Date.parse(publishedAt) > now) continue;
    const community = /社区反馈/.test(type + title + summary) || title.includes('站长确认');
    const explicit = summary.match(/北京时间\s*(\d{1,2})月(\d{1,2})日\s*(\d{2}:\d{2}:\d{2})/);
    const confirmedAt = explicit ? `${new Date(publishedAt).getUTCFullYear()}-${explicit[1].padStart(2, '0')}-${explicit[2].padStart(2, '0')}T${explicit[3]}+08:00` : times.length > 1 ? times.at(-1) : community ? null : publishedAt;
    if (confirmedAt && (!Number.isFinite(Date.parse(confirmedAt)) || Date.parse(confirmedAt) > now)) continue;
    const completionURL = links.find(a => a.label.includes('完成确认'))?.url || (!community && !card ? links[0].url : null);
    events.push({ id: postID(links[0].url) + (hard ? ':hardReset' : ':resetCard'), aliases: links.map(a => postID(a.url)), kind: hard ? 'hardReset' : 'resetCard', day: day(confirmedAt || publishedAt), publishedAt, confirmedAt, usesConfirmationDate: true, confirmation: community ? 'community' : 'official', title, summary, announcementURL: links[0].url, completionURL, sourceURL: 'https://codexradar.com/#tibo-challenge' });
  }
  for (const row of html.match(/<div\b[^>]*\bdata-month\s*=\s*["'][^"']+["'][^>]*>[\s\S]*?<\/div>/gi) || []) {
    const month = attr(row, 'data-month');
    const hardResets = row.match(/monthly-count-direct[^>]*>\s*<strong\b[^>]*>(\d+)/i)?.[1], resetCards = row.match(/monthly-count-card[^>]*>\s*<strong\b[^>]*>(\d+)/i)?.[1];
    if (validDate(month + '-01') && hardResets != null && resetCards != null) monthlyTotals.push({ month, hardResets: +hardResets, resetCards: +resetCards });
  }
  if (section === undefined && !monthlyTotals.length) throw new Error('公开日历格式暂不支持');
  return { events, monthlyTotals };
}
function mergeEvents(existing, incoming) {
  const rows = [...existing];
  for (const event of incoming) {
    if (!event || !validDate(event.day) || !['hardReset', 'resetCard'].includes(event.kind)) continue;
    const ids = new Set([event.id, ...(event.aliases || [])]);
    const index = rows.findIndex(r => r.kind === event.kind && [r.id, ...(r.aliases || [])].some(id => ids.has(id)));
    if (index < 0) rows.push(event);
    else rows[index] = { ...rows[index], ...event, aliases: [...new Set([rows[index].id, ...(rows[index].aliases || []), ...(event.aliases || [])])] };
  }
  return rows.sort((a, b) => b.day.localeCompare(a.day) || a.id.localeCompare(b.id));
}
class ResetCalendar {
  constructor(store) {
    this.store = store;
    const saved = store?.read('reset-calendar-v1', null);
    this.state = { schemaVersion: 1, events: mergeEvents(bundled.events, saved?.events || []), monthlyTotals: [...new Map([...(bundled.monthlyTotals || []), ...(saved?.monthlyTotals || [])].map(r => [r.month, r])).values()], lastSuccessAt: saved?.lastSuccessAt || null, error: null, attribution: bundled.attribution || null };
  }
  update(html, raw, now) {
    try {
      const page = parsePage(html, now), observed = completion(raw, now);
      this.state.events = mergeEvents(this.state.events, [...page.events, ...(observed ? [observed] : [])]);
      this.state.monthlyTotals = [...new Map([...this.state.monthlyTotals, ...page.monthlyTotals].map(r => [r.month, r])).values()];
      this.state.lastSuccessAt = now; this.state.error = null;
      this.store?.write('reset-calendar-v1', this.state);
    } catch { this.state.error = '日历同步失败，保留离线历史'; }
  }
  snapshot() { return this.state; }
}
module.exports = { ResetCalendar, parsePage, completion, mergeEvents, verifiedURL, day };
