const { parsePage, SITE_URL } = require('./radar-v2110');
const { request } = require('./radar-http');
const tibo = require('./tibo-analysis');
const { ResetCalendar, verifiedURL } = require('./reset-calendar');
const REFRESH_INTERVAL_MS = 600000;
class RadarService {
  constructor({ fetcher = global.fetch, now = () => Date.now(), store, sleep, analyzer = tibo.analyze, auxiliary = fetcher === global.fetch } = {}) {
    Object.assign(this, { fetcher, now, store, sleep, analyzer, auxiliary });
    const saved = store?.read('radar-announcements-v2', {}) || {};
    this.page = saved.page || store?.read('radar-source-v1', null)?.page || null;
    this.analysis = saved.analysis || null;
    this.analysisError = saved.analysisError || null;
    this.lastSuccessAt = saved.lastSuccessAt || 0;
    this.lastAttemptAt = saved.lastAttemptAt || 0;
    this.nextFetchAt = Math.max(saved.nextFetchAt || 0, this.lastAttemptAt + (this.lastAttemptAt ? REFRESH_INTERVAL_MS : 0));
    this.serverWaitUntil = saved.serverWaitUntil || 0;
    this.error = saved.error || null;
    this.failures = saved.failures || 0;
    this.threads = saved.threads || {};
    this.calendar = new ResetCalendar(store);
    this.inFlight = null;
  }
  async current() {
    if (this.stopped) return this.snapshot();
    if (this.inFlight) return this.inFlight;
    // Manual refresh, restart and resume share the same persisted ten-minute floor.
    if (this.now() < Math.max(this.nextFetchAt, this.serverWaitUntil)) return this.snapshot();
    this.inFlight = this.fetch().finally(() => { this.inFlight = null; });
    return this.inFlight;
  }
  persist() {
    this.store?.write('radar-announcements-v2', { page: this.page, analysis: this.analysis, analysisError: this.analysisError, lastSuccessAt: this.lastSuccessAt, lastAttemptAt: this.lastAttemptAt, nextFetchAt: this.nextFetchAt, serverWaitUntil: this.serverWaitUntil, error: this.error, failures: this.failures, threads: this.threads });
  }
  async context(posts) {
    for (const post of posts) {
      const cached = this.threads[post.id];
      if (cached?.originalText === post.originalText) post.threadContext = cached.text;
      else delete this.threads[post.id];
    }
    const candidates = posts.filter(p => p.originalText && verifiedURL(p.url)).slice(0, 6);
    // At most three new public threads per cycle. Retain the active deadline's cached context.
    await Promise.all(candidates.filter(p => !this.threads[p.id]).slice(0, 3).map(async p => {
        if (this.auxiliary) {
          try {
            const body = await request(this.fetcher, 'https://r.jina.ai/' + p.url, { timeout: 6000, attempts: 1, now: this.now });
            if (Buffer.byteLength(body) > 100000 || !body.split(/\r?\n/).includes('URL Source: ' + p.url) || !body.includes('Markdown Content:')) return;
            const context = body.slice(body.indexOf('Markdown Content:') + 'Markdown Content:'.length).slice(0, 6000);
            if (context.includes(p.originalText)) this.threads[p.id] = { text: context, originalText: p.originalText, at: this.now() };
          } catch {}
        }
        if (this.threads[p.id]) p.threadContext = this.threads[p.id].text;
      }));
    const ids = new Set(posts.map(p => p.id));
    this.threads = Object.fromEntries(Object.entries(this.threads).filter(([id]) => ids.has(id)));
  }
  async fetch() {
    this.lastAttemptAt = this.now();
    this.nextFetchAt = this.lastAttemptAt + REFRESH_INTERVAL_MS;
    this.persist();
    try {
      const [html, raw] = await Promise.all([
        request(this.fetcher, SITE_URL + '?pulse=' + this.now(), { now: this.now, sleep: this.sleep }),
        this.auxiliary ? request(this.fetcher, SITE_URL + 'current.json', { type: 'json', timeout: 6000, attempts: 1, now: this.now }).catch(() => null) : null,
      ]);
      if (Buffer.byteLength(html) > 4 * 1024 * 1024) throw new Error('公开源超过大小上限');
      const page = parsePage(html);
      if (Date.parse(page.updatedAt) > this.now() + 60000 || (this.page && Date.parse(page.updatedAt) < Date.parse(this.page.updatedAt))) throw new Error('公开源时间异常或返回旧数据');
      page.posts = tibo.retained([...new Map([...(this.page?.posts || []), ...page.posts].map(p => [p.id, p])).values()], this.now()).sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt));
      this.page = page;
      this.lastSuccessAt = this.now(); this.error = null; this.failures = 0; this.serverWaitUntil = 0;
      this.calendar.update(html, raw, this.now());
      await this.context(page.posts);
      try {
        this.analysisController = new AbortController();
        const result = await this.analyzer(page.posts, this.now(), { signal: this.analysisController.signal });
        this.analysis = tibo.validate(result, page.posts, this.now());
        this.analysisError = null;
      } catch (error) { this.analysisError = error.message || 'GPT-6 Astra · High 分析未成功'; }
    } catch (error) {
      this.error = error.message || '公开动态刷新失败'; this.failures++;
      this.serverWaitUntil = error.retryAt || 0;
    }
    this.nextFetchAt = Math.max(this.nextFetchAt, this.serverWaitUntil);
    if (!this.stopped) this.persist();
    return this.snapshot();
  }
  networkRestored() { /* The ten-minute minimum and Retry-After still apply. */ }
  stop() { this.stopped = true; this.analysisController?.abort(); }
  snapshot() {
    const now = this.now(), posts = tibo.retained(this.page?.posts, now);
    if (this.analysis && Date.parse(this.analysis.analyzedAt) < now - 7 * 86400000) this.analysis = null;
    return { prediction: null, analysis: this.analysis, analysisError: this.analysisError, posts, error: this.error,
      lastAttemptAt: this.lastAttemptAt, lastSuccessAt: this.lastSuccessAt, nextSyncAt: this.nextFetchAt,
      latestUpdate: this.lastSuccessAt ? new Date(this.lastSuccessAt).toISOString() : null,
      sourceState: !this.lastSuccessAt ? 'unavailable' : now >= this.lastSuccessAt + 660000 ? 'expired' : this.error ? 'cached' : 'fresh',
      refreshHealthy: !this.error && !this.analysisError && !!this.analysis && Date.parse(this.analysis.analyzedAt) >= Math.max(this.lastSuccessAt, this.lastAttemptAt) && now < this.lastSuccessAt + 660000,
      loading: !!this.inFlight, sourceURL: SITE_URL, calendar: this.calendar.snapshot(),
      latestLevelLabel: '等待分析', latestSummary: this.error || this.analysisError || '等待公开动态分析',
      tiboPresence: { timezone: 'America/Los_Angeles', locationLabelZh: '太平洋时间 / PT', latestActivityZh: posts[0]?.translationZh || posts[0]?.originalText || '暂无公开动态', evidenceSummaryZh: 'PT 时间仅供时段参考；公开源可能未收录全部动态' },
      evaluation: { n: 0, brier: null, records: [] } };
  }
  mark() { throw new Error('本版已取消概率评分，请查看重置预告和历史日历'); }
}
module.exports = { RadarService, REFRESH_INTERVAL_MS };
