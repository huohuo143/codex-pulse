const ENDPOINT = "https://api.tangka.online/radar-api/dashboard";
const SITE_URL = ENDPOINT;
const REFRESH_INTERVAL_MS = 30 * 60 * 1000;

function dateValue(value) {
  if (!value) return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

function levelFrom(statusLabel, probability) {
  const label = String(statusLabel || "").toLowerCase();
  if (label.includes("极高") || label.includes("very high")) return "very_high";
  if (label.includes("中高")) return "medium_high";
  if (label.includes("高") || label.includes("high")) return "high";
  if (label.includes("中低")) return "medium_low";
  if (label.includes("中") || label.includes("medium")) return "medium";
  if (label.includes("极低") || label.includes("very low")) return "very_low";
  if (label.includes("低") || label.includes("low")) return "low";
  if (probability >= 0.85) return "very_high";
  if (probability >= 0.7) return "high";
  if (probability >= 0.55) return "medium_high";
  if (probability >= 0.4) return "medium";
  if (probability >= 0.25) return "medium_low";
  if (probability >= 0.1) return "low";
  return "very_low";
}

function levelLabel(level) {
  return (
    {
      very_high: "极高概率",
      high: "高概率",
      medium_high: "中高概率",
      medium: "中等概率",
      medium_low: "中低概率",
      low: "低概率",
      very_low: "极低概率",
    }[level] || "研判中"
  );
}

function normalizePrediction(value = {}) {
  const raw = Number(
    value.probability24h ?? value.probability_24h ?? value.probability24H,
  );
  const probability24h = Number.isFinite(raw)
    ? Math.max(0, Math.min(1, raw > 1 ? raw / 100 : raw))
    : null;
  const raw48 = Number(
    value.probability48h ?? value.probability_48h ?? value.probability48H,
  );
  const level =
    value.level || levelFrom(value.statusLabel, probability24h || 0);
  return {
    level,
    levelLabel: levelLabel(level),
    probability24h,
    probability24hPercent:
      probability24h == null ? null : Math.round(probability24h * 100),
    probability48h: Number.isFinite(raw48)
      ? Math.max(0, Math.min(1, raw48 > 1 ? raw48 / 100 : raw48))
      : null,
    summary: value.summary || null,
    updatedAt: dateValue(value.updatedAt ?? value.updated_at),
  };
}

function parseDashboard(root) {
  const platform = root.platforms?.find(
    (item) => String(item.id).toLowerCase() === "codex",
  );
  if (!platform) return null;
  const summary =
    platform.summary ||
    platform.summaryBlocks
      ?.map((item) => item.text)
      .filter(Boolean)
      .join("；") ||
    null;
  const prediction = normalizePrediction({
    ...platform,
    summary,
    probability24h: platform.probability,
    updatedAt: platform.updatedAt || root.generatedAt,
  });
  const post = root.accountPosts?.codex;
  return {
    schemaVersion: "mini-program-dashboard-v1",
    service: "reset-radar-mini-program",
    type: "public-dashboard",
    monitoredAt: dateValue(root.generatedAt),
    timezone: "Asia/Shanghai",
    windowOpen: false,
    prediction,
    tiboPresence: post
      ? {
          handle: post.handle || "@thsottiaux",
          timezone: "America/Los_Angeles",
          locationLabelZh: "旧金山湾区 / PT",
          confidence: "public-timezone",
          evidenceSummaryZh:
            "公开动态未明确披露当前位置，因此采用默认 PT 时区；作息状态仅按当地时间推测。",
          shouldDisplay: true,
          latestActivityZh: post.text || null,
          latestActivityAt: dateValue(post.publishedAt),
          updatedAt: dateValue(root.generatedAt),
        }
      : null,
    sourceURL: SITE_URL,
  };
}

function camelizeDirect(root) {
  const prediction = normalizePrediction(root.prediction || {});
  if (
    prediction.probability24h == null &&
    !root.tibo_presence &&
    !root.tiboPresence
  )
    return null;
  const presence = root.tiboPresence || root.tibo_presence;
  return {
    schemaVersion: root.schemaVersion || root.schema_version || null,
    service: root.service || "codex-reset-radar",
    type: root.type || "public_summary",
    monitoredAt: dateValue(root.monitoredAt || root.monitored_at),
    timezone: root.timezone || "Asia/Shanghai",
    windowOpen: root.windowOpen ?? root.window_open ?? false,
    prediction,
    tiboPresence: presence
      ? {
          handle: presence.handle || "@thsottiaux",
          timezone: presence.timezone || "America/Los_Angeles",
          locationLabelZh:
            presence.locationLabelZh ||
            presence.location_label_zh ||
            "旧金山湾区 / PT",
          confidence: presence.confidence || null,
          evidenceSummaryZh:
            presence.evidenceSummaryZh || presence.evidence_summary_zh || null,
          shouldDisplay:
            presence.shouldDisplay ?? presence.should_display ?? true,
          latestActivityZh:
            presence.latestActivityZh || presence.latest_activity_zh || null,
          latestActivityAt: dateValue(
            presence.latestActivityAt || presence.latest_activity_at,
          ),
          updatedAt: dateValue(presence.updatedAt || presence.updated_at),
        }
      : null,
    sourceURL: root.links?.html || SITE_URL,
  };
}

function parseRadarPayload(input) {
  const root =
    typeof input === "string" || Buffer.isBuffer(input)
      ? JSON.parse(String(input))
      : input;
  const value = root?.data || root?.current || root?.result || root;
  const snapshot = Array.isArray(value?.platforms)
    ? parseDashboard(value)
    : camelizeDirect(value || {});
  if (!snapshot?.prediction || snapshot.prediction.probability24h == null)
    throw new Error("重置雷达返回了无效数据");
  const candidates = [
    snapshot.prediction.updatedAt,
    snapshot.monitoredAt,
    snapshot.tiboPresence?.latestActivityAt,
  ].filter(Boolean);
  snapshot.latestUpdate =
    candidates.sort((a, b) => Date.parse(b) - Date.parse(a))[0] || null;
  snapshot.probabilityUpdate =
    snapshot.prediction.updatedAt || snapshot.monitoredAt;
  snapshot.latestLevelLabel = snapshot.prediction.levelLabel;
  snapshot.latestSummary = snapshot.prediction.summary;
  return snapshot;
}

class RadarService {
  constructor({
    fetcher = global.fetch,
    now = () => Date.now(),
    cacheDuration = REFRESH_INTERVAL_MS,
  } = {}) {
    this.fetcher = fetcher;
    this.now = now;
    this.cacheDuration = cacheDuration;
    this.snapshot = null;
    this.cachedAt = 0;
  }

  async current({ force = false } = {}) {
    if (
      !force &&
      this.snapshot &&
      this.now() - this.cachedAt < this.cacheDuration
    )
      return this.snapshot;
    const response = await this.fetcher(ENDPOINT, {
      headers: {
        Accept: "application/json",
        "User-Agent": "CodexSuanliMeter-Windows/2.4.7",
      },
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) {
      if ([401, 403].includes(response.status))
        throw new Error("重置雷达公开数据暂时无法访问");
      if (response.status === 429) throw new Error("重置雷达请求过于频繁");
      throw new Error(`重置雷达同步失败 (${response.status})`);
    }
    const candidate = parseRadarPayload(await response.text());
    const existingTime = Date.parse(this.snapshot?.probabilityUpdate || 0);
    const candidateTime = Date.parse(candidate.probabilityUpdate || 0);
    if (
      this.snapshot &&
      Number.isFinite(existingTime) &&
      (!Number.isFinite(candidateTime) || candidateTime < existingTime)
    ) {
      this.cachedAt = this.now();
      return this.snapshot;
    }
    this.snapshot = candidate;
    this.cachedAt = this.now();
    return candidate;
  }
}

module.exports = {
  RadarService,
  parseRadarPayload,
  levelFrom,
  levelLabel,
  ENDPOINT,
  SITE_URL,
  REFRESH_INTERVAL_MS,
};
