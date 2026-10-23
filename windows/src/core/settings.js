const DEFAULTS = {
  compact: false,
  alwaysOnTop: true,
  launchWithCodex: false,
  launchAtLogin: false,
  refreshSeconds: 30,
  palette: "mintDawn",
  appearance: "aurora",
  opacity: 0.78,
  oneDriveSync: true,
  compactStyle: "rings",
  compactSizeMode: "standard",
  compactRingOrientation: "horizontal",
  compactShowsResetCredits: true,
  selectedSection: "overview",
  bounds: null,
  themeMode: "system",
  floatingEnabled: false,
  showFiveHour: false,
  cardFiveHour: false,
  showWeekly: true,
  showTokens: true,
  showRadar: true,
  notifications: false,
  alertPreset: "standard",
  thresholdAlerts: true,
  forecastAlerts: true,
  creditAlerts: true,
  dailyBackup: true,
  dailySummary: false,
  autoUpdates: true,
  cards: {},
  expandedDetails: {},
};
const enums = {
  palette: [
    "mintDawn",
    "seaSaltBlue",
    "forestSoda",
    "peachSunset",
    "wisteriaNight",
    "lemonHarbor",
  ],
  appearance: ["aurora", "glass", "graphite"],
  compactStyle: [
    "rings",
    "circle",
    "square",
    "pill",
    "bars",
    "barsQuad",
    "badge",
    "badgeQuad",
  ],
  compactSizeMode: ["standard", "mini"],
  compactRingOrientation: ["horizontal", "vertical"],
  selectedSection: ["overview", "trends", "insights", 'calendar', "settings"],
  themeMode: ["system", "light", "dark"],
  alertPreset: ["standard", "early", "urgentOnly"],
};
const CARD_TYPES = [
  "overview",
  "quota",
  "radar",
  "credits",
  "tokens",
  "trend",
  "projects",
];
function validatePatch(patch) {
  if (!patch || typeof patch !== "object" || Array.isArray(patch))
    throw new Error("设置格式无效");
  const out = {};
  for (const [k, v] of Object.entries(patch)) {
    if (!(k in DEFAULTS) || ["bounds", "cards", "expandedDetails"].includes(k))
      throw new Error("未知设置");
    if (enums[k]) {
      if (!enums[k].includes(v)) throw new Error("设置选项无效");
    } else if (k === "refreshSeconds") {
      if (![5, 10, 30, 60, 120].includes(v)) throw new Error("刷新间隔无效");
    } else if (k === "opacity") {
      if (typeof v !== "number" || !Number.isFinite(v) || v < 0.3 || v > 0.94)
        throw new Error("透明度无效");
    } else if (typeof DEFAULTS[k] === "boolean" && typeof v !== "boolean")
      throw new Error("设置类型无效");
    out[k] = v;
  }
  return out;
}
function visibleBounds(bounds, displays, min = { width: 320, height: 220 }) {
  const a =
    displays.find(
      (d) =>
        bounds &&
        bounds.x < d.x + d.width &&
        bounds.x + (bounds.width || min.width) > d.x &&
        bounds.y < d.y + d.height &&
        bounds.y + (bounds.height || min.height) > d.y,
    ) || displays[0];
  const width = Math.min(
      a.width,
      Math.max(min.width, bounds?.width || min.width),
    ),
    height = Math.min(
      a.height,
      Math.max(min.height, bounds?.height || min.height),
    );
  return {
    width: Math.round(width),
    height: Math.round(height),
    x: Math.round(
      Math.max(
        a.x,
        Math.min(
          bounds?.x ?? a.x + (a.width - width) / 2,
          a.x + a.width - width,
        ),
      ),
    ),
    y: Math.round(
      Math.max(
        a.y,
        Math.min(
          bounds?.y ?? a.y + (a.height - height) / 2,
          a.y + a.height - height,
        ),
      ),
    ),
  };
}
function migrateSettings(old = {}) {
  const result = { ...DEFAULTS };
  for (const [k, v] of Object.entries(old)) {
    try {
      Object.assign(result, validatePatch({ [k]: v }));
    } catch {}
  }
  result.bounds = old.bounds || null;
  result.cards = old.cards && typeof old.cards === "object" ? old.cards : {};
  result.expandedDetails = old.expandedDetails || {};
  result.floatingEnabled = old.floatingEnabled ?? old.compact ?? false;
  result.compact = false;
  result.schemaVersion = 2118;
  return result;
}
module.exports = {
  DEFAULTS,
  CARD_TYPES,
  validatePatch,
  visibleBounds,
  migrateSettings,
};
