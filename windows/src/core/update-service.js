const ENDPOINT = 'https://api.github.com/repos/huohuo143/codex-pulse/releases';
const MANIFEST = 'https://raw.githubusercontent.com/huohuo143/codex-pulse/main/updates/latest.json';
const REPOSITORY = 'https://github.com/huohuo143/codex-pulse';
function parse(v) {
  const m = String(v).match(/^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/);
  return m ? { parts: m.slice(1, 4).map(Number), pre: m[4] || null } : null;
}
function compare(a, b) {
  a = parse(a); b = parse(b); if (!a || !b) return null;
  for (let i = 0; i < 3; i++) if (a.parts[i] !== b.parts[i]) return Math.sign(a.parts[i] - b.parts[i]);
  if (a.pre === b.pre) return 0; if (!a.pre) return 1; if (!b.pre) return -1;
  const x = a.pre.split('.'), y = b.pre.split('.');
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if (x[i] === undefined) return -1; if (y[i] === undefined) return 1;
    if (x[i] === y[i]) continue;
    const xn = /^\d+$/.test(x[i]), yn = /^\d+$/.test(y[i]);
    if (xn && yn) return Math.sign(Number(x[i]) - Number(y[i]));
    if (xn !== yn) return xn ? -1 : 1;
    return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}
function time(value) { const n = Date.parse(value); return Number.isFinite(n) ? n : 0; }
function trustedURL(value, prefix) {
  try { const u = new URL(value); return u.protocol === 'https:' && u.hostname === 'github.com' && !u.username && !u.password && !u.search && !u.hash && u.href.startsWith(prefix); }
  catch { return false; }
}
function windowsAsset(r) {
  const prefix = REPOSITORY + '/releases/download/' + r.tag_name + '/';
  const assets = (r.assets || []).filter(a => a && (!a.state || a.state === 'uploaded') && trustedURL(a.browser_download_url, prefix));
  return assets.find(a => /windows.*x64.*(?:安装版|installer|setup)\.exe$/i.test(a.name) && !/portable|免安装/i.test(a.name)) || assets.find(a => /windows.*x64.*\.exe$/i.test(a.name));
}
function validRelease(r) {
  if (!r || r.draft || r.prerelease || !parse(r.tag_name) || parse(r.tag_name).pre) return false;
  const page = REPOSITORY + '/releases/tag/' + r.tag_name;
  return !r.html_url || trustedURL(r.html_url, page) && new URL(r.html_url).pathname === new URL(page).pathname;
}
function retryAt(response, now) {
  const get = key => response.headers?.get?.(key);
  const retry = get('retry-after'), reset = get('x-ratelimit-reset');
  const dates = [now + 60000];
  if (retry && /^\d+(?:\.\d+)?$/.test(retry)) dates.push(now + Number(retry) * 1000);
  else if (retry && time(retry)) dates.push(time(retry));
  if (get('x-ratelimit-remaining') === '0' && reset && Number.isFinite(Number(reset))) dates.push(Number(reset) * 1000);
  return Math.max(...dates.filter(Number.isFinite));
}
class UpdateService {
  constructor(store, { fetcher = global.fetch, version = require('../../package.json').version, now = () => Date.now(), manifestEndpoint = MANIFEST } = {}) {
    this.store = store; this.fetcher = fetcher; this.version = version; this.now = now; this.manifestEndpoint = manifestEndpoint;
    this.state = store.read('updates-v1', { checkedAt: null, message: '尚未检查更新' });
    if (this.state.version && compare(this.state.version, this.version) !== null && compare(this.state.version, this.version) <= 0)
      this.state = { ...this.state, available: false, url: null, message: this.state.error ? (this.state.message || this.state.error) : '已是最新 Windows 功能基线' };
    this.pending = null;
  }
  async check(force = false) {
    if (this.pending) return this.pending;
    if (time(this.state.nextRetryAt) > this.now()) return this.state;
    if (!force && !this.state.error && this.now() - time(this.state.checkedAt) < 86400000) return this.state;
    this.pending = this.fetch().finally(() => { this.pending = null; });
    return this.pending;
  }
  async request(url) {
    const r = await this.fetcher(url, { headers: { Accept: 'application/json', 'Cache-Control': 'no-cache' }, signal: AbortSignal.timeout(8000) });
    if (!r.ok) {
      const body = url === ENDPOINT && r.status === 403 ? await r.json().catch(() => ({})) : {};
      if (url === ENDPOINT && (r.status === 429 || r.status === 403 && (r.headers?.get?.('x-ratelimit-remaining') === '0' || r.headers?.get?.('retry-after') || /rate limit/i.test(String(body.message || ''))))) {
        this.state = { ...this.state, apiRetryAt: new Date(retryAt(r, this.now())).toISOString() };
        const error = new Error('GitHub 版本接口暂时限流'); error.rateLimited = true; throw error;
      }
      throw new Error('版本来源暂不可用');
    }
    return r.json();
  }
  async fetch() {
    const attemptedAt = new Date(this.now()).toISOString();
    try {
      let release, source;
      if (this.manifestEndpoint) {
        try {
          const manifest = await this.request(this.manifestEndpoint);
          if (manifest.schemaVersion !== 1 || !validRelease(manifest) || !time(manifest.published_at)) throw new Error('公开版本清单无效');
          if (!windowsAsset(manifest)) throw new Error('该版本没有 Windows 安装包');
          release = manifest; source = 'manifest';
        } catch { /* The API is a bounded fallback, never a parallel extra request. */ }
      }
      if (!release) {
        if (time(this.state.apiRetryAt) > this.now()) { const e = new Error('GitHub 版本接口暂时限流'); e.rateLimited = true; throw e; }
        const rows = await this.request(ENDPOINT);
        if (!Array.isArray(rows)) throw new Error('版本信息无效');
        release = rows.filter(r => validRelease(r) && windowsAsset(r)).sort((a, b) => compare(b.tag_name, a.tag_name))[0] || rows.filter(validRelease).sort((a,b)=>compare(b.tag_name,a.tag_name))[0]; source = 'api';
        if (!release) throw new Error('暂无正式版本信息');
      }
      const prefix = REPOSITORY + '/releases/download/' + release.tag_name + '/';
      const assets = (Array.isArray(release.assets) ? release.assets : []).filter(a => a && typeof a.name === 'string' && (!a.state || a.state === 'uploaded') && trustedURL(a.browser_download_url, prefix));
      const asset = assets.find(a => /windows.*x64.*(?:安装版|installer|setup)\.exe$/i.test(a.name) && !/portable|免安装/i.test(a.name)) || assets.find(a => /windows.*x64.*\.exe$/i.test(a.name));
      const newer = compare(release.tag_name, this.version) > 0;
      this.state = { checkedAt: attemptedAt, attemptedAt, version: release.tag_name, available: newer && !!asset, url: newer && asset ? asset.browser_download_url : null, page: release.html_url || REPOSITORY + '/releases/tag/' + release.tag_name, source, apiRetryAt: this.state.apiRetryAt, failureCount: 0,
        message: newer ? asset ? '发现 Windows 新版 ' + release.tag_name : '发现新版 ' + release.tag_name + '，暂无 Windows x64 安装包' : '已是最新 Windows 功能基线' };
    } catch (error) {
      const failureCount = Math.min(6, (Number(this.state.failureCount) || 0) + 1);
      let next = this.now() + Math.min(3600000, 60000 * 2 ** (failureCount - 1));
      if (!this.manifestEndpoint && error.rateLimited) next = Math.max(next, time(this.state.apiRetryAt));
      const retained = this.state.version ? ' · 已保留 ' + this.state.version + ' 的上次结果' : '';
      const message = (error.rateLimited ? 'GitHub 暂时限流' : '暂时无法刷新版本信息') + retained + ' · ' + new Date(next).toLocaleTimeString('zh-CN', {hour:'2-digit',minute:'2-digit'}) + ' 后可重试';
      this.state = { ...this.state, attemptedAt, nextRetryAt: new Date(next).toISOString(), failureCount, error: message, message };
    }
    this.store.write('updates-v1', this.state);
    return this.state;
  }
}
module.exports = { UpdateService, compare, parse, ENDPOINT, MANIFEST, retryAt };
