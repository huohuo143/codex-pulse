const { levelLabel } = require("./radar-service");
const { request } = require("./radar-http");
const SITE_URL = "https://codexradar.com/";
const REFRESH_INTERVAL_MS = 1800000;
const RULE_VERSION = "2.12.0-2126";
function clean(s) {
  return String(s || "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}
function attr(html, name) {
  return html.match(new RegExp("(?:^|\\s)" + name + "\\s*=\\s*([\"'])(.*?)\\1"))?.[2] || null;
}
function classText(html, name) {
  return clean(
    html.match(
      new RegExp(
        '<([a-z0-9]+)\\b[^>]*class\\s*=\\s*[\"\'][^\"\']*(?<![\\w-])' +
          name +
          '(?![\\w-])[^\"\']*[\"\'][^>]*>([\\s\\S]*?)</\\1>',
      ),
    )?.[2],
  );
}
function parsePage(html) {
  const section = html.match(
    /<section\b[^>]*class\s*=\s*["'][^"']*\b(?:reset-judgement|desktop-tibo-radar)\b[^"']*["'][^>]*>[\s\S]*?<\/section>/,
  )?.[0];
  if (!section) throw new Error("公开雷达格式暂不支持");
  const tag = section.slice(0, section.indexOf(">") + 1),
    elements =
      section.match(/<li\b[^>]*reset-tibo-post[^>]*>[\s\S]*?<\/li>/g) || [];
  const posts = elements.map((item) => {
    const id = attr(item, "data-tibo-post-id"),
      url = attr(item, "href"),
      originalText = classText(item, "reset-tibo-post-original").replace(
        /^英文原文\s*/,
        "",
      ),
      translationZh = classText(item, "reset-tibo-post-translation").replace(
        /^中文翻译\s*/,
        "",
      ),
      publishedAt = attr(item, "datetime");
    if (
      !id || !/^\d+$/.test(id) ||
      !originalText ||
      !url ||
      !new RegExp(
        "^https://(?:www\\.)?x\\.com/thsottiaux/status/" + id + "$",
      ).test(url)
    )
      throw new Error("公开动态验证失败");
    return {
      id,
      url,
      originalText,
      translationZh,
      publishedAt,
      isReply: originalText.trim().startsWith("@"),
    };
  });
  const ids = (attr(tag, "data-tibo-post-ids") || "")
    .split(",")
    .filter(Boolean);
  if (tag.includes("desktop-tibo-radar") && !posts.length)
    throw new Error("公开动态内容为空");
  if (
    ids.length &&
    (ids.length !== posts.length ||
      !ids.every((id) => posts.some((p) => p.id === id)))
  )
    throw new Error("公开动态内容不完整");
  const article = (
    section.match(
      /<article\b[^>]*reset-judgement-card[^>]*>[\s\S]*?<\/article>/g,
    ) || []
  ).find(
    (s) => clean(s.match(/<span[^>]*>([\s\S]*?)<\/span>/)?.[1]) === "硬重置",
  );
  let updatedAt =
    attr(tag, "data-tibo-posts-updated-at") ||
    attr(tag, "data-reset-radar-updated-at") ||
    posts
      .map((p) => p.publishedAt)
      .filter(Boolean)
      .sort()
      .at(-1);
  if (!Number.isFinite(Date.parse(updatedAt)))
    throw new Error("公开数据缺少时间戳");
  const challenge = (html.match(/<section\b[^>]*id\s*=\s*["']tibo-challenge["'][^>]*>[\s\S]*?<\/section>/)?.[0] || "");
  for (const item of challenge.match(/<article\b[^>]*>[\s\S]*?<\/article>/g) || []) {
    const url = attr(item, "href"), match = url?.match(/^https:\/\/(?:www\.)?x\.com\/thsottiaux\/status\/(\d+)$/);
    const publishedAt = attr(item, "datetime"), title = clean(item.match(/<h3\b[^>]*>([\s\S]*?)<\/h3>/)?.[1]), summary = clean(item.match(/<p\b[^>]*>([\s\S]*?)<\/p>/)?.[1]);
    if (match && Number.isFinite(Date.parse(publishedAt)) && title && summary && !posts.some(p => p.id === match[1]))
      posts.push({ id: match[1], url, publishedAt, originalText: "", publicSummaryZh: title + "：" + summary, isReply: false });
  }
  posts.sort((a, b) => (Date.parse(b.publishedAt) || 0) - (Date.parse(a.publishedAt) || 0));
  if (posts[0] && Date.parse(posts[0].publishedAt) > Date.parse(updatedAt)) updatedAt = posts[0].publishedAt;
  return {
    updatedAt,
    eventKind: attr(tag, "data-reset-radar-event-kind"),
    eventStatus: attr(tag, "data-reset-radar-event-status"),
    resetAt: null,
    headline: clean(article?.match(/<strong[^>]*>([\s\S]*?)<\/strong>/)?.[1]),
    summary: clean(article?.match(/<p[^>]*>([\s\S]*?)<\/p>/)?.[1]),
    posts,
  };
}
function ptDay(date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(date));
  const get = (k) => Number(parts.find((p) => p.type === k).value);
  return [get("year"), get("month"), get("day")];
}
function ptMidnight(y, m, d) {
  const normalized = new Date(Date.UTC(y, m - 1, d));
  const wanted = normalized.getTime();
  let t = wanted + 8 * 3600000;
  for (let i = 0; i < 3; i++) {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: "America/Los_Angeles",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(t));
    const get = (k) => Number(parts.find((p) => p.type === k).value);
    const local = Date.UTC(
      get("year"),
      get("month") - 1,
      get("day"),
      get("hour"),
      get("minute"),
      get("second"),
    );
    t += wanted - local;
  }
  return t;
}
function lifetime(post, now, tomorrow = false) {
  const published = Date.parse(post.publishedAt),
    age = now - published;
  if (!Number.isFinite(published) || age < -3600000) return 0;
  if (tomorrow) {
    const [y, m, d] = ptDay(published),
      start = ptMidnight(y, m, d + 1),
      end = ptMidnight(y, m, d + 2);
    return now >= end ? 0 : now < start ? 1 : (end - now) / (end - start);
  }
  return age >= 86400000
    ? 0
    : age <= 21600000
      ? 1
      : (86400000 - age) / 64800000;
}
function semantics(post, now) {
  const t = (
      post.originalText +
      " " +
      (post.translationZh || "")
    ).toLowerCase(),
    has = (...v) => v.some((s) => t.includes(s));
  const banked = has(
      "banked reset",
      "banked my friend",
      "可储存的重置",
      "可存起来的重置",
      "可储存重置",
    ),
    tomorrow = has("tomorrow", "明天"),
    deferred =
      !banked &&
      tomorrow &&
      has(
        "moved to tomorrow",
        "move to tomorrow",
        "postponed until tomorrow",
        "deferred until tomorrow",
        "移到明天",
        "改到明天",
        "延期到明天",
        "延至明天",
      ) &&
      has("button", "按钮") &&
      has("pressed", "按下", "按过") &&
      has("today", "今天");
  const contextual =
      !banked &&
      !deferred &&
      has("tomorrow", "明天", "within 24 hours", "24小时内", "24 小时内") &&
      has(
        "reset button",
        "press reset",
        "pressed reset",
        "按下重置",
        "按过重置",
        "重置按钮",
      ),
    explicit =
      !banked &&
      has(
        "usage reset",
        "reset usage",
        "reset the limit",
        "hard reset",
        "global reset",
        "硬重置",
        "全局重置",
        "统一清零",
        "重置额度",
        "额度重置",
      ),
    release =
      has("tomorrow", "明天", "soon", "很快") &&
      has("ship", "roll out", "launch", "release", "发布", "上线"),
    abundance = has(
      "too cheap to meter",
      "无需计量",
      "几乎无需计量",
      "unmetered",
      "more capacity",
      "更多容量",
      "高供给",
    );
  const timed = lifetime(post, now, tomorrow),
    general = lifetime(post, now);
  return {
    post,
    banked,
    supports: contextual || deferred || explicit,
    release: release ? timed : 0,
    abundance: abundance ? general : 0,
    contextual: contextual ? timed : 0,
    deferred: deferred ? timed : 0,
    explicit: explicit ? timed : 0,
  };
}
function score(page, now = Date.now()) {
  const completed =
    page.eventStatus === "completed" ||
    page.eventKind === "window_closed" ||
    page.headline?.includes("完成");
  const anchor = Date.parse(
    page.resetAt || (completed ? page.updatedAt : null),
  );
  const rows = page.posts
    .filter(p => p.originalText && !p.publicSummaryZh)
    .filter(
      (p) =>
        !Number.isFinite(anchor) ||
        Date.parse(p.publishedAt) > anchor ||
        (Date.parse(p.publishedAt) === anchor &&
          semantics(p, now).deferred > 0),
    )
    .map((p) => semantics(p, now));
  const supported = rows.filter((r) => r.supports),
    max = (key, list = rows) => Math.max(0, ...list.map((r) => r[key])),
    release = max("release", supported),
    abundance = max("abundance", supported),
    contextual = max("contextual"),
    deferred = max("deferred"),
    explicit = max("explicit");
  let semantic = Math.round(30 * release) + Math.round(20 * abundance);
  if (release && abundance)
    semantic += Math.round(20 * Math.min(release, abundance));
  semantic = Math.max(
    semantic,
    Math.round(55 * contextual),
    Math.round(70 * deferred),
  );
  const standalone = Math.max(
    0,
    ...supported
      .filter((r) => !r.post.isReply)
      .map((r) =>
        Math.max(r.release, r.abundance, r.contextual, r.deferred, r.explicit),
      ),
  );
  semantic += Math.round(5 * standalone);
  if (explicit)
    semantic = Math.max(
      semantic,
      Math.round(
        (rows.some((r) => r.explicit && !r.post.isReply) ? 65 : 55) * explicit,
      ),
    );
  const base = completed
    ? 0
    : ["open", "active", "announced", "confirmed"].includes(page.eventStatus) ||
        ["window_open", "reset_announced"].includes(page.eventKind)
      ? 90
      : ["probing", "polling", "monitoring"].includes(page.eventStatus) ||
          ["probe", "poll"].includes(page.eventKind)
        ? 25
        : 0;
  const percent = Math.min(95, base + semantic),
    level =
      percent >= 90
        ? "very_high"
        : percent >= 75
          ? "high"
          : percent >= 60
            ? "medium_high"
            : percent >= 45
              ? "medium"
              : percent >= 30
                ? "medium_low"
                : percent >= 15
                  ? "low"
                  : "very_low";
  return {
    probability24h: percent / 100,
    probability24hPercent: percent,
    level,
    levelLabel: levelLabel(level),
    updatedAt: new Date(now).toISOString(),
    evaluatedAt: new Date(now).toISOString(),
    ruleVersion: RULE_VERSION,
    signals: [
      "窗口基准 " + base + "%",
      "有效 Tibo 信号 " + semantic + "%",
      "同类信号只计一次；BANKED reset 与产品发布不单独计入硬重置",
    ],
    summary: explicit
      ? "出现明确重置措辞，请核对原帖语境"
      : contextual || deferred
        ? "出现近时重置暗示，尚未明确承诺全局重置"
        : rows.some((r) => r.banked)
          ? "BANKED reset 是可储存权益，当前没有新的全局硬重置信号"
          : "尚未发现有效的新重置信号",
  };
}
class RadarService {
  constructor({ fetcher = global.fetch, now = () => Date.now(), store, sleep, auxiliary = fetcher === global.fetch } = {}) {
    this.fetcher = fetcher;
    this.now = now;
    this.store = store;
    this.sleep = sleep;
    this.auxiliary = auxiliary;
    this.saved = store?.read("radar-source-v1", null);
    this.page = this.saved?.page || null;
    this.lastSuccessAt = this.saved?.lastSuccessAt || 0;
    this.lastAttemptAt = this.saved?.lastAttemptAt || 0;
    this.lastFailure = this.saved?.lastFailure || null;
    this.nextFetchAt = this.saved?.nextFetchAt || this.lastSuccessAt + REFRESH_INTERVAL_MS;
    this.failures = this.saved?.failures || 0;
    this.serverWaitUntil = this.saved?.serverWaitUntil || 0;
    this.syncHistory = this.saved?.syncHistory || [];
    this.inFlight = null;
    this.archive = store?.read("radar-evaluation-v1", []) || [];
    this.lastEvaluationAt = 0;
  }
  async current({ force = false } = {}) {
    if (this.inFlight) return this.inFlight;
    if (this.now() < this.serverWaitUntil) return this.snapshot();
    if (!force && this.now() < this.nextFetchAt) return this.snapshot();
    this.inFlight = this.fetch().finally(() => (this.inFlight = null));
    return this.inFlight;
  }
  async fetch() {
    this.lastAttemptAt = this.now();
    try {
      const anchorPromise = this.auxiliary ? request(this.fetcher, SITE_URL + "current.json", { type: "json", timeout: 6000, attempts: 1, now: this.now }).catch(() => null) : Promise.resolve(null);
      const page = parsePage(await request(this.fetcher, SITE_URL + "?pulse=" + this.now(), { now: this.now, sleep: this.sleep }));
      {
        const raw = await anchorPromise;
        if (raw) {
            const
              base = raw.data || raw.current || raw.result || raw,
              closed = base.window?.closed_at || base.window?.closedAt;
            if (
              Number.isFinite(Date.parse(closed)) &&
              Date.parse(closed) <= this.now()
            ) {
              page.resetAt = closed;
              if (!page.eventKind) {
                page.eventKind = "window_closed";
                page.eventStatus = "completed";
              }
            }
        }
      }
      if (
        this.page?.resetAt &&
        (!page.resetAt ||
          Date.parse(page.resetAt) < Date.parse(this.page.resetAt))
      )
        page.resetAt = this.page.resetAt;
      if (Date.parse(page.updatedAt) > this.now() + 60000)
        throw new Error("公开源时间异常");
      if (
        this.page &&
        Date.parse(page.updatedAt) < Date.parse(this.page.updatedAt)
      )
        throw new Error("公开源返回旧数据");
      const prior = this.page?.posts || [];
      page.posts = [
        ...new Map([...prior, ...page.posts].map((p) => [p.id, p])).values(),
      ]
        .filter((p) => Date.parse(p.publishedAt) >= this.now() - 7 * 86400000)
        .sort((a, b) => Date.parse(b.publishedAt) - Date.parse(a.publishedAt));
      this.page = page;
      this.cachedPrediction = null;
      this.lastSuccessAt = this.now();
      this.lastFailure = null;
      this.failures = 0;
      this.serverWaitUntil = 0;
      this.nextFetchAt = this.now() + REFRESH_INTERVAL_MS;
      this.syncHistory.push({ at: this.lastAttemptAt, success: true });
    } catch (e) {
      this.lastFailure = e.message;
      this.failures++;
      this.serverWaitUntil = e.retryAt || 0;
      this.nextFetchAt =
        this.now() +
        ([60000, 300000, 900000][this.failures - 1] || REFRESH_INTERVAL_MS);
      this.nextFetchAt = Math.max(this.nextFetchAt, this.serverWaitUntil);
      this.syncHistory.push({ at: this.lastAttemptAt, success: false, reason: this.lastFailure });
    }
    this.syncHistory = this.syncHistory.slice(-48);
    this.store?.write("radar-source-v1", { page: this.page, lastSuccessAt: this.lastSuccessAt, lastAttemptAt: this.lastAttemptAt,
      lastFailure: this.lastFailure, nextFetchAt: this.nextFetchAt, failures: this.failures, serverWaitUntil: this.serverWaitUntil, syncHistory: this.syncHistory });
    return this.snapshot();
  }
  networkRestored() {
    if (this.failures && this.now() >= this.serverWaitUntil) this.nextFetchAt = this.now();
  }
  snapshot() {
    const now = this.now();
    if (!this.page) return { prediction: null, latestLevelLabel: "等待数据", latestSummary: this.lastFailure || "等待公开源首次同步", sourceState: "unavailable",
      lastSuccessAt: null, lastAttemptAt: this.lastAttemptAt, error: this.lastFailure, nextSyncAt: this.nextFetchAt, posts: [], evaluation: this.evaluation() };
    const expired = now - this.lastSuccessAt > 5400000;
    if (!this.cachedPrediction || now - this.lastEvaluationAt >= 300000)
      this.cachedPrediction = score(this.page, now);
    const prediction = { ...this.cachedPrediction };
    if (expired) {
      prediction.probability24h = null;
      prediction.probability24hPercent = null;
      prediction.summary = "公开源超过 90 分钟未成功更新，停止展示概率";
    }
    if (!expired && now - this.lastEvaluationAt >= 300000) {
      this.lastEvaluationAt = now;
      this.archive.push({
        id: String(now),
        generatedAt: new Date(now).toISOString(),
        endsAt: new Date(now + 86400000).toISOString(),
        probability: prediction.probability24h,
        ruleVersion: RULE_VERSION,
        evidence: this.page.posts.map((p) => ({
          id: p.id,
          publishedAt: p.publishedAt,
        })),
        outcome: null,
        source: null,
      });
      this.archive = this.archive.slice(-10000);
      this.store?.write("radar-evaluation-v1", this.archive);
    }
    const post = this.page.posts[0];
    return {
      prediction,
      latestLevelLabel: expired ? "数据已过期" : prediction.levelLabel,
      latestSummary: prediction.summary,
      latestUpdate: new Date(this.lastSuccessAt).toISOString(),
      sourceState: expired ? "expired" : this.lastFailure ? "cached" : "fresh",
      lastAttemptAt: this.lastAttemptAt,
      lastSuccessAt: this.lastSuccessAt,
      nextSyncAt: this.nextFetchAt,
      error: this.lastFailure,
      tiboPresence: {
        timezone: "America/Los_Angeles",
        locationLabelZh: "旧金山湾区 / PT",
        latestActivityZh:
          post?.translationZh || post?.originalText || (post?.publicSummaryZh ? "公开页面摘要：" + post.publicSummaryZh : "暂无公开动态"),
        evidenceSummaryZh: "PT 时间仅用于时段参考，非实际位置",
      },
      posts: this.page.posts,
      sourceURL: SITE_URL,
      evaluation: this.evaluation(),
    };
  }
  mark({ id, outcome, source }) {
    const row = this.archive.find((r) => r.id === id);
    if (
      !row ||
      Date.parse(row.endsAt) > this.now() ||
      typeof outcome !== "boolean" ||
      typeof source !== "string" ||
      source.trim().length < 5 ||
      source.length > 500
    )
      throw new Error("只能标注已结束的 24 小时窗口，并填写核实依据");
    row.outcome = outcome;
    row.source = source.trim();
    this.store?.write("radar-evaluation-v1", this.archive);
    return this.evaluation();
  }
  evaluation() {
    const complete = this.archive.filter(
      (r) =>
        typeof r.outcome === "boolean" &&
        r.source &&
        Date.parse(r.endsAt) <= this.now(),
    );
    return {
      n: complete.length,
      brier: complete.length
        ? complete.reduce(
            (s, r) => s + (r.probability - Number(r.outcome)) ** 2,
            0,
          ) / complete.length
        : null,
      records: this.archive.slice(-100).reverse(),
    };
  }
}
module.exports = {
  RadarService,
  score,
  semantics,
  lifetime,
  parsePage,
  ptMidnight,
  SITE_URL,
  REFRESH_INTERVAL_MS,
  RULE_VERSION,
};
