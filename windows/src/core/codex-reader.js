const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { StringDecoder } = require("node:string_decoder");
const { createHash } = require("node:crypto");
const { fetchLiveRateLimits } = require("./codex-app-server");
const { SessionFileIndex } = require("./session-file-index");

// v5 invalidates caches produced before cumulative-total deduplication.
const CACHE_SCHEMA = 5;
const WEEK_MINUTES = 10_080;
const WEEK_WINDOW_TOLERANCE = 60;

const CATEGORIES = [
  "coding",
  "presentation",
  "imageDesign",
  "videoProduction",
  "documents",
  "manuscript",
  "dataAnalysis",
  "lifeScience",
  "webDevelopment",
  "systemOperations",
  "research",
  "general",
  "other",
];

const CATEGORY_LABELS = {
  coding: "编程/APP",
  presentation: "PPT/演示",
  imageDesign: "图片/视觉",
  videoProduction: "视频制作",
  documents: "文档/表格",
  manuscript: "论文/稿件",
  dataAnalysis: "数据/组学分析",
  lifeScience: "生命科学",
  webDevelopment: "网站开发",
  systemOperations: "系统运维",
  research: "调研/文献",
  general: "通用对话",
  other: "其他",
};

const RULES = {
  presentation: [
    ["pptx", 10],
    ["powerpoint", 10],
    ["演示文稿", 10],
    ["幻灯片", 10],
    ["slide deck", 9],
    ["slides", 7],
    ["presentation", 6],
    ["ppt", 4],
  ],
  imageDesign: [
    ["imagegen", 10],
    ["生成图片", 9],
    ["做图", 9],
    ["photoshop", 9],
    ["illustrator", 8],
    ["图片", 5],
    ["图像", 5],
    ["海报", 5],
    ["插画", 5],
    ["视觉", 4],
    ["figma", 6],
    ["png", 3],
    ["jpg", 3],
  ],
  videoProduction: [
    ["hyperframes", 10],
    ["剪映", 10],
    ["jianying", 10],
    ["remotion", 9],
    ["视频制作", 9],
    ["video", 5],
    ["分镜", 5],
    ["动画", 4],
  ],
  documents: [
    ["docx", 10],
    ["word", 7],
    ["申请表", 9],
    ["文档", 5],
    ["表格", 5],
    ["填写", 4],
    ["documents", 6],
    ["xlsx", 7],
    ["spreadsheet", 6],
    ["excel", 6],
  ],
  manuscript: [
    ["manuscript", 10],
    ["peer review", 9],
    ["reviewer", 8],
    ["论文", 8],
    ["稿件", 8],
    ["综述", 7],
    ["投稿", 7],
    ["nature", 4],
  ],
  dataAnalysis: [
    ["scanpy", 10],
    ["deseq2", 10],
    ["anndata", 9],
    ["nextflow", 8],
    ["rna-seq", 8],
    ["scrna", 8],
    ["组学", 8],
    ["数据分析", 7],
    ["statistical", 6],
    ["matplotlib", 5],
    ["seaborn", 5],
  ],
  lifeScience: [
    ["alphafold", 10],
    ["clinvar", 9],
    ["gnomad", 9],
    ["biopython", 8],
    ["pubchem", 7],
    ["uniprot", 7],
    ["生命科学", 7],
    ["水稻", 7],
    ["褐飞虱", 7],
    ["bph", 5],
    ["基因", 4],
    ["蛋白", 4],
  ],
  webDevelopment: [
    ["sites-building", 10],
    ["website", 8],
    ["web development", 8],
    ["html", 5],
    ["css", 5],
    ["javascript", 5],
    ["react", 5],
    ["网站构建", 8],
    ["网页", 5],
  ],
  coding: [
    ["apply_patch", 10],
    ["swift test", 8],
    ["npm run", 7],
    ["package.swift", 6],
    [".swift", 4],
    [".jsx", 4],
    [".tsx", 4],
    ["python", 4],
    ["代码", 5],
    ["编程", 6],
    ["修复", 3],
    ["bug", 4],
    ["构建", 3],
    ["git diff", 5],
  ],
  systemOperations: [
    ["synology", 10],
    ["群晖", 10],
    ["内网穿透", 9],
    ["nas", 8],
    ["ssh", 5],
    ["docker", 5],
    ["电脑维护", 8],
    ["网络问题", 7],
    ["系统运维", 7],
  ],
  research: [
    ["pubmed", 10],
    ["zotero", 10],
    ["search_query", 8],
    ["web.run", 8],
    ["literature", 7],
    ["browse", 5],
    ["搜索", 5],
    ["调研", 6],
    ["文献", 7],
    ["引用", 4],
    ["citations", 5],
    ["联网", 4],
  ],
};

const PRIORITY = {
  presentation: 13,
  videoProduction: 12,
  imageDesign: 11,
  manuscript: 10,
  documents: 9,
  dataAnalysis: 8,
  lifeScience: 7,
  webDevelopment: 6,
  coding: 5,
  systemOperations: 4,
  research: 3,
  general: 2,
  other: 1,
};

const EXCLUDED_CONTEXT = [
  '"role":"developer"',
  '"role":"system"',
  '"type":"session_meta"',
  '"type":"function_call_output"',
];
const INCLUDED_CONTEXT = [
  '"role":"user"',
  '"role":"assistant"',
  '"type":"user_message"',
  '"type":"function_call"',
];

const { estimateCost } = require("./model-pricing");
const PRICE_CATALOG = require("./model-pricing").builtin;

function emptyScores() {
  return Object.fromEntries(CATEGORIES.map((key) => [key, 0]));
}

function normalizedContext(line) {
  return String(line).toLowerCase().replace(/\s+/g, " ");
}

function scoreContext(line, scores) {
  const normalized = normalizedContext(line);
  if (EXCLUDED_CONTEXT.some((needle) => normalized.includes(needle))) return;
  if (!INCLUDED_CONTEXT.some((needle) => normalized.includes(needle))) return;
  for (const [category, rules] of Object.entries(RULES)) {
    for (const [keyword, weight] of rules)
      if (normalized.includes(keyword)) scores[category] += weight;
  }
  if (
    normalized.includes('"role":"user"') ||
    normalized.includes('"type":"user_message"')
  )
    scores.general += 1;
}

function categoryFromProject(value = "") {
  const sample = String(value).toLowerCase();
  const mappings = [
    ["presentation", ["课题汇报ppt", "汇报ppt", "presentation", "slides"]],
    ["videoProduction", ["视频制作", "剪映", "jianying", "video"]],
    ["imageDesign", ["ps 抠图", "photoshop", "illustrator", "图片", "figure"]],
    ["manuscript", ["投稿中论文", "论文", "manuscript", "review", "综述"]],
    ["dataAnalysis", ["组学分析", "数据分析", "analysis", "omics"]],
    ["lifeScience", ["wu lab 课题", "水稻", "褐飞虱", "bph", "bcat", "病毒"]],
    [
      "webDevelopment",
      ["网站构建", "sites-project", "sites-plugin", "website"],
    ],
    [
      "systemOperations",
      ["电脑维护", "群晖", "内网穿透", "网络问题", "synology", "routine"],
    ],
    ["documents", ["重点研发", "项目合集", "高层次人才", "国重重组", "docx"]],
    [
      "coding",
      [
        "app 开发",
        "app开发",
        "算力码表",
        "/skills",
        "nature skill",
        "zotero_memory_builder",
      ],
    ],
  ];
  return (
    mappings.find(([, needles]) =>
      needles.some((needle) => sample.includes(needle)),
    )?.[0] || null
  );
}

function bestCategory(scores, projectPath = "", previousCategory = null) {
  const specific = CATEGORIES.filter(
    (item) => !["general", "other"].includes(item),
  ).sort((a, b) => scores[b] - scores[a] || PRIORITY[b] - PRIORITY[a])[0];
  if (specific && scores[specific] > 0) return specific;
  return (
    categoryFromProject(projectPath) ||
    previousCategory ||
    (scores.general > 0 ? "general" : "other")
  );
}

function number(value) {
  const result = Number(value);
  return Number.isFinite(result) ? result : 0;
}
function clamp(value) {
  return Math.max(0, Math.min(100, number(value)));
}

function dateFromEpoch(value) {
  const raw = number(value);
  if (raw <= 0) return null;
  return new Date(raw > 10_000_000_000 ? raw : raw * 1000).toISOString();
}

function normalizeWindow(window) {
  if (!window) return null;
  const used = clamp(
    window.used_percent ??
      window.usedPercent ??
      window.used_percentage ??
      window.used,
  );
  const remainingKeys = [
    "remaining_percent",
    "remainingPercent",
    "remaining_percentage",
    "available_percent",
    "availablePercent",
    "left_percent",
    "balance_percent",
    "remaining",
    "available",
    "left",
  ];
  const remainingKey = remainingKeys.find((key) => Object.hasOwn(window, key));
  return {
    usedPercent: used,
    remainingPercent: remainingKey
      ? clamp(window[remainingKey])
      : clamp(100 - used),
    windowMinutes: number(window.window_minutes ?? window.windowDurationMins),
    resetsAt: dateFromEpoch(window.resets_at ?? window.resetsAt),
  };
}

function normalizeUsage(info = {}) {
  const total = info.total_token_usage || info.totalTokenUsage || {};
  const last = info.last_token_usage || info.lastTokenUsage || {};
  return {
    totalTokens: number(total.total_tokens ?? total.totalTokens),
    inputTokens: number(total.input_tokens ?? total.inputTokens),
    cachedInputTokens: number(
      total.cached_input_tokens ?? total.cachedInputTokens,
    ),
    outputTokens: number(total.output_tokens ?? total.outputTokens),
    reasoningOutputTokens: number(
      total.reasoning_output_tokens ?? total.reasoningOutputTokens,
    ),
    lastTotalTokens: number(last.total_tokens ?? last.totalTokens),
    lastInputTokens: number(last.input_tokens ?? last.inputTokens),
    lastCachedInputTokens: number(
      last.cached_input_tokens ?? last.cachedInputTokens,
    ),
    lastOutputTokens: number(last.output_tokens ?? last.outputTokens),
    lastReasoningOutputTokens: number(
      last.reasoning_output_tokens ?? last.reasoningOutputTokens,
    ),
  };
}

function extractCwd(line) {
  const match = line.match(/"cwd"\s*:\s*"((?:\\.|[^"\\])*)"/);
  if (!match) return null;
  try {
    return JSON.parse(`"${match[1]}"`);
  } catch {
    return match[1].replace(/\\\\/g, "\\");
  }
}

function projectNameFromPath(value) {
  return (
    String(value)
      .replace(/[\\/]+$/, "")
      .split(/[\\/]/)
      .filter(Boolean)
      .at(-1) || String(value)
  );
}

function parseModel(line, fallback) {
  if (!line.includes('"model"')) return fallback;
  try {
    const value = JSON.parse(line);
    return value?.payload?.model || value?.model || fallback;
  } catch {
    const match = line.match(/"model"\s*:\s*"([^"\\]+)"/);
    return match?.[1] || fallback;
  }
}

function periodKey(date, period) {
  const pad = (value) => String(value).padStart(2, "0");
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  if (period === "month") return day.slice(0, 7);
  if (period === "hour")
    return String(
      new Date(
        date.getFullYear(),
        date.getMonth(),
        date.getDate(),
        date.getHours(),
      ).getTime() / 3_600_000,
    );
  return day;
}

function formatLabel(key, period) {
  if (period === "hour") {
    const date = new Date(Number(key) * 3_600_000);
    return `${date.getMonth() + 1}/${date.getDate()} ${String(date.getHours()).padStart(2, "0")}时`;
  }
  const parts = key.split("-");
  if (parts.length === 2) return `${parts[0]}/${parts[1]}`;
  if (parts.length === 3) return `${Number(parts[1])}/${Number(parts[2])}`;
  return key;
}

function bucket(key, period) {
  return {
    key,
    label: formatLabel(key, period),
    totalTokens: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    reasoningOutputTokens: 0,
    calls: 0,
  };
}

function addBucket(map, key, event, period) {
  const row = map.get(key) || bucket(key, period);
  row.totalTokens += event.totalTokens;
  row.inputTokens += event.inputTokens;
  row.cachedInputTokens += event.cachedInputTokens;
  row.outputTokens += event.outputTokens;
  row.reasoningOutputTokens += event.reasoningOutputTokens;
  row.calls += 1;
  map.set(key, row);
}

function shiftDate(now, unit, amount) {
  const result = new Date(now);
  if (unit === "hour") result.setHours(result.getHours() + amount, 0, 0, 0);
  if (unit === "day") {
    result.setHours(0, 0, 0, 0);
    result.setDate(result.getDate() + amount);
  }
  if (unit === "month") {
    result.setDate(1);
    result.setHours(0, 0, 0, 0);
    result.setMonth(result.getMonth() + amount);
  }
  return result;
}

function fillRows(map, count, now, period) {
  return Array.from({ length: count }, (_, index) => {
    const key = periodKey(shiftDate(now, period, index - count + 1), period);
    return map.get(key) || bucket(key, period);
  });
}

function selectSevenDayWindow(event) {
  return (
    [event?.primary, event?.secondary]
      .filter(
        (window) =>
          window &&
          Math.abs(window.windowMinutes - WEEK_MINUTES) <=
            WEEK_WINDOW_TOLERANCE,
      )
      .sort(
        (a, b) =>
          Math.abs(a.windowMinutes - WEEK_MINUTES) -
          Math.abs(b.windowMinutes - WEEK_MINUTES),
      )[0] || null
  );
}

function buildStats(events, now = new Date()) {
  const unique = new Map();
  for (const event of events) {
    const usage = event.usage || {};
    if (number(usage.lastTotalTokens) <= 0 || number(usage.totalTokens) <= 0)
      continue;
    const item = {
      timestamp: event.timestamp,
      sourceName: event.sourceName,
      totalTokens: number(usage.lastTotalTokens),
      inputTokens: number(usage.lastInputTokens),
      cachedInputTokens: number(usage.lastCachedInputTokens),
      outputTokens: number(usage.lastOutputTokens),
      reasoningOutputTokens: number(usage.lastReasoningOutputTokens),
      category: event.usageCategory,
      projectName: event.projectName,
      projectPath: event.projectPath,
      model: event.model || "unknown",
    };
    // totalTokens is cumulative per rollout file. A quota-only refresh may
    // repeat that cumulative value with a different lastTotalTokens payload;
    // it is still the same usage point and must only be counted once.
    const key = `${event.sourcePath}:${usage.totalTokens}`;
    if (
      !unique.has(key) ||
      Date.parse(item.timestamp) < Date.parse(unique.get(key).timestamp)
    )
      unique.set(key, item);
  }

  const usageEvents = [...unique.values()]
    .filter(
      (event) =>
        Number.isFinite(Date.parse(event.timestamp)) &&
        Date.parse(event.timestamp) <= now.getTime(),
    )
    .sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
  const dailyMap = new Map();
  const monthlyMap = new Map();
  const hourlyMap = new Map();
  const modelHourlyMap = new Map();
  for (const event of usageEvents) {
    const date = new Date(event.timestamp);
    const hourKey = periodKey(date, "hour");
    addBucket(dailyMap, periodKey(date, "day"), event, "day");
    addBucket(monthlyMap, periodKey(date, "month"), event, "month");
    addBucket(hourlyMap, hourKey, event, "hour");
    const modelKey = `${hourKey}\u0000${event.model}`;
    const modelRow = modelHourlyMap.get(modelKey) || {
      key: modelKey,
      hourKey,
      label: formatLabel(hourKey, "hour"),
      model: event.model,
      totalTokens: 0,
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      calls: 0,
    };
    for (const field of [
      "totalTokens",
      "inputTokens",
      "cachedInputTokens",
      "outputTokens",
      "reasoningOutputTokens",
    ])
      modelRow[field] += event[field];
    modelRow.calls += 1;
    modelHourlyMap.set(modelKey, modelRow);
  }

  const daily = fillRows(dailyMap, 30, now, "day");
  const monthly = fillRows(monthlyMap, 6, now, "month");
  const hourly = fillRows(hourlyMap, 24, now, "hour");
  const todayKey = periodKey(now, "day");
  const monthKey = periodKey(now, "month");
  const last7Keys = new Set(
    fillRows(new Map(), 7, now, "day").map((row) => row.key),
  );
  const cutoff24h = now.getTime() - 24 * 3_600_000;
  const cutoff7d = now.getTime() - 7 * 86_400_000;
  const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1).getTime();
  const events24h = usageEvents.filter(
    (event) =>
      Date.parse(event.timestamp) >= cutoff24h &&
      Date.parse(event.timestamp) <= now.getTime(),
  );
  const events7d = usageEvents.filter(
    (event) =>
      last7Keys.has(periodKey(new Date(event.timestamp), "day")) &&
      Date.parse(event.timestamp) <= now.getTime(),
  );
  const monthEvents = usageEvents.filter(
    (event) =>
      Date.parse(event.timestamp) >= startOfMonth &&
      Date.parse(event.timestamp) <= now.getTime(),
  );
  const sumTokens = (selected) =>
    selected.reduce((sum, event) => sum + event.totalTokens, 0);
  const categoryBreakdown = CATEGORIES.map((category) => {
    const selected = monthEvents.filter((event) => event.category === category);
    return {
      category,
      label: CATEGORY_LABELS[category],
      calls: selected.length,
      totalTokens: sumTokens(selected),
    };
  });
  const projects = (selected, limit = 3) => {
    const map = new Map();
    for (const event of selected) {
      const key = event.projectPath || event.projectName;
      const row = map.get(key) || {
        id: key,
        projectName: event.projectName,
        projectPath: event.projectPath,
        totalTokens: 0,
        calls: 0,
      };
      row.totalTokens += event.totalTokens;
      row.calls += 1;
      map.set(key, row);
    }
    return [...map.values()]
      .sort(
        (a, b) =>
          b.totalTokens - a.totalTokens ||
          a.projectName.localeCompare(b.projectName),
      )
      .slice(0, limit);
  };

  return {
    rolling24HoursTokens: sumTokens(events24h),
    todayTokens: dailyMap.get(todayKey)?.totalTokens || 0,
    monthTokens: monthlyMap.get(monthKey)?.totalTokens || 0,
    last7DaysTokens: [...dailyMap]
      .filter(([key]) => last7Keys.has(key))
      .reduce((sum, [, row]) => sum + row.totalTokens, 0),
    sampleCount: usageEvents.length,
    daily,
    monthly,
    hourly,
    modelHourly: [...modelHourlyMap.values()]
      .filter((row) => Number(row.hourKey) * 3_600_000 >= startOfMonth)
      .sort(
        (a, b) =>
          Number(a.hourKey) - Number(b.hourKey) ||
          a.model.localeCompare(b.model),
      ),
    cost24Hours: estimateCost(events24h),
    cost7Days: estimateCost(events7d),
    costMonth: estimateCost(monthEvents),
    categoryBreakdown,
    todayTopProjects: projects(
      usageEvents.filter(
        (event) => periodKey(new Date(event.timestamp), "day") === todayKey,
      ),
    ),
    monthTopProjects: projects(monthEvents, Infinity),
    recentUsageEvents: usageEvents.slice(-12).reverse(),
    devices: [],
  };
}

async function listJsonlFiles(roots, maxFiles) {
  const index = new SessionFileIndex(roots, { maxFiles });
  await index.refresh();
  return index.files();
}

async function readSegment(filePath, start, end) {
  if (end <= start) return "";
  const handle = await fsp.open(filePath, "r");
  try {
    const buffer = Buffer.alloc(end - start);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, start);
    return buffer.subarray(0, bytesRead).toString("utf8");
  } finally {
    await handle.close();
  }
}

class CodexReader {
  constructor({
    codexHome,
    sessionRoots,
    maxFiles = Infinity,
    liveReader = fetchLiveRateLimits,
    cachePath,
    watch = false,
  } = {}) {
    this.codexHome =
      codexHome || process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
    const appData = process.env.APPDATA || "";
    this.sessionRoots =
      sessionRoots ||
      [
        path.join(this.codexHome, "sessions"),
        path.join(this.codexHome, "browser", "sessions"),
        appData && path.join(appData, "Codex", "sessions"),
        appData && path.join(appData, "com.openai.codex", "sessions"),
      ].filter(Boolean);
    this.maxFiles = maxFiles;
    this.liveReader = liveReader;
    this.cachePath = cachePath;
    this.cache = new Map();
    this.isReading = false;
    this.loadCache();
    this.watchEnabled = watch;
    this.files = [];
    this.fileIndex = new SessionFileIndex(this.sessionRoots, { maxFiles });
    this.indexDirty = true;
    this.indexAt = 0;
    this.lastActivityAt = Date.now();
    this.parseCount = 0;
    this.analysisCount = 0;
    this.watchers = [];
    this.lastSignature = null;
    this.lastStats = null;
  }

  loadCache() {
    if (!this.cachePath) return;
    try {
      const stored = JSON.parse(fs.readFileSync(this.cachePath, "utf8"));
      if (stored.schemaVersion !== CACHE_SCHEMA) return;
      // Older v5 caches omitted token_count rows without rate_limits; rebuild them once.
      if (stored.parserVersion !== 2118) return;
      this.cache = new Map(
        (stored.files || [])
          .filter(([, value]) => value?.events)
          .map(([key, value]) => [key, value]),
      );
    } catch {
      /* first run or old cache */
    }
  }

  async saveCache() {
    if (!this.cachePath) return;
    const payload = {
      schemaVersion: CACHE_SCHEMA,
      parserVersion: 2118,
      updatedAt: new Date().toISOString(),
      files: [...this.cache.entries()].map(([file, state]) => [file, cacheStateForDisk(state)]),
    };
    await fsp.mkdir(path.dirname(this.cachePath), { recursive: true });
    const temp = `${this.cachePath}.tmp`;
    await fsp.writeFile(temp, JSON.stringify(payload));
    await fsp.rename(temp, this.cachePath).catch(async () => {
      await fsp.copyFile(temp, this.cachePath);
      await fsp.unlink(temp).catch(() => {});
    });
  }

  startWatching() {
    if (!this.watchEnabled) return;
    for (const root of this.sessionRoots) {
      if (this.watchers.some((w) => w.root === root)) continue;
      try {
        const watcher = fs.watch(root, { recursive: true }, (_event, filename) => {
          this.fileIndex.markDirty(root, filename);
          this.lastActivityAt = Date.now();
        });
        watcher.unref();
        watcher.on("error", () => {
          this.indexDirty = true;
          watcher.close();
          this.watchers = this.watchers.filter((w) => w.watcher !== watcher);
        });
        this.watchers.push({ root, watcher });
      } catch {
        /* Reconcile creates missing roots later. */
      }
    }
  }
  close() {
    this.watchers.forEach((w) => w.watcher.close());
    this.watchers = [];
  }
  invalidate() {
    this.indexDirty = true;
    this.lastSignature = null;
  }
  async read(now = new Date()) {
    this.isReading = true;
    try {
      const reconcile =
        this.indexDirty ||
        now.getTime() - this.indexAt >= 300000 ||
        !this.watchers.length;
      this.indexDirty = false;
      if (await this.fileIndex.refresh(reconcile)) this.files = this.fileIndex.files();
      if (reconcile) {
        this.indexAt = now.getTime();
        this.startWatching();
      }
      const files = this.files;
      const signature =
        JSON.stringify(files) + ":" + require("./model-pricing").version();
      const changed =
        this.lastSignature !== signature ||
        now.getTime() >= (this.nextStatsAt || 0);
      const parsedBefore = this.parseCount;
      const cacheSizeBefore = this.cache.size;
      const active = new Set(files.map((file) => file.path));
      for (const key of this.cache.keys())
        if (!active.has(key)) this.cache.delete(key);
      const batches = [];
      for (const file of files) batches.push(await this.parseFile(file));
      if (
        this.parseCount !== parsedBefore ||
        this.cache.size !== cacheSizeBefore
      )
        await this.saveCache().catch(() => {});
      const events = batches
        .flat()
        .sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
      const liveEvents = await this.liveReader().catch(() => []);
      const combined = [...events, ...liveEvents].sort(
        (a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp),
      );
      const latest = new Map();
      for (const event of combined) latest.set(event.limitID, event);
      const limits = [...latest.values()].sort(
        (a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp),
      );
      const main = latest.get("codex") || limits[0] || null;
      const weekly = selectSevenDayWindow(main);
      if (changed || !this.lastStats) {
        this.lastStats = buildStats(events, now);
        this.lastSignature = signature;
        this.analysisCount++;
        const expiries = events
          .map((e) => Date.parse(e.timestamp) + 86400000 + 1)
          .filter((t) => t > now.getTime());
        this.nextStatsAt = Math.min(
          new Date(
            now.getFullYear(),
            now.getMonth(),
            now.getDate(),
            now.getHours() + 1,
          ).getTime(),
          ...expiries.slice(0, 100000),
        );
      }
      return {
        generatedAt: now.toISOString(),
        codexHome: this.codexHome,
        sessionsRoot: this.sessionRoots.join(" | "),
        scannedFiles: files.length,
        eventCount: events.length,
        main,
        weekly,
        limits,
        metrics: {
          parseCount: this.parseCount,
          analysisCount: this.analysisCount,
          lastActivityAt: this.lastActivityAt,
        },
        tokenStats: this.lastStats,
        recentEvents: combined.slice(-18).reverse(),
      };
    } finally {
      this.isReading = false;
    }
  }

  initialState(file) {
    return {
      mtimeMs: 0,
      size: 0,
      offset: 0,
      partial: "",
      events: [],
      scores: emptyScores(),
      projectPath: file.path,
      projectName: path.basename(file.path, path.extname(file.path)),
      model: "unknown",
      previousCategory: null,
    };
  }

  async parseFile(file) {
    const cached = this.cache.get(file.path);
    if (
      cached &&
      cached.mtimeMs === file.mtimeMs &&
      cached.size === file.size &&
      (!cached.identity || cached.identity === file.identity)
    )
      return cached.events;
    let prefix;
    try {
      const h = await fsp.open(file.path, "r");
      try {
        const b = Buffer.alloc(Math.min(256, file.size));
        await h.read(b, 0, b.length, 0);
        prefix = createHash("sha256").update(b).digest("hex");
      } finally {
        await h.close();
      }
    } catch {
      return cached?.events || [];
    }
    // A prefix signature and file identity distinguish append from replacement.
    const append =
      cached &&
      file.size > cached.size &&
      (!cached.identity || cached.identity === file.identity) &&
      (cached.size < 256 || !cached.prefix || cached.prefix === prefix);
    const state = append
      ? {
          ...cached,
          events: [...cached.events],
          scores: { ...emptyScores(), ...cached.scores },
        }
      : this.initialState(file);
    let offset = state.offset || 0,
      partial = state.partial || "";
    try {
      const decoder = new StringDecoder("utf8");
      const stream = fs.createReadStream(file.path, {
        start: offset,
        end: Math.max(offset, file.size - 1),
        highWaterMark: 256 * 1024,
      });
      if (file.size > offset)
        for await (const buffer of stream) {
          offset += buffer.length;
          const text = partial + decoder.write(buffer);
          const lines = text.split(/\r?\n/);
          partial = lines.pop() || "";
          for (const line of lines) this.consumeLine(line, state, file.path);
        }
      else stream.destroy();
      // Do not advance past an incomplete UTF-8 sequence; read it again on append.
      const pending = decoder.lastNeed
        ? decoder.lastTotal - decoder.lastNeed
        : 0;
      offset -= pending;
    } catch {
      return cached?.events || [];
    }
    state.partial = partial;
    state.offset = offset;
    state.size = file.size;
    state.mtimeMs = file.mtimeMs;
    state.identity = file.identity;
    state.prefix = prefix;
    this.cache.set(file.path, state);
    this.parseCount++;
    this.lastActivityAt = Date.now();
    return state.events;
  }

  consumeLine(line, state, sourcePath) {
    if (!line) return;
    if (!/"type"\s*:\s*"token_count"/.test(line)) {
      const cwd = line.includes('"cwd"') ? extractCwd(line) : null;
      if (cwd) {
        state.projectPath = cwd;
        state.projectName = projectNameFromPath(cwd);
      }
      if (line.includes('"model"')) state.model = parseModel(line, state.model);
      scoreContext(line.slice(0, 16_384), state.scores);
      return;
    }
    let root;
    try {
      root = JSON.parse(line);
    } catch {
      return;
    }
    const payload = root.payload || {};
    const rate = payload.rate_limits || payload.rateLimits;
    if (
      payload.type !== "token_count" ||
      !root.timestamp ||
      !Number.isFinite(Date.parse(root.timestamp))
    )
      return;
    const safeRate = rate || {};
    const usageCategory = bestCategory(
      state.scores,
      state.projectPath,
      state.previousCategory,
    );
    state.events.push({
      timestamp: new Date(root.timestamp).toISOString(),
      sourceName: path.basename(sourcePath),
      sourcePath,
      limitID: safeRate.limit_id || safeRate.limitId || "codex",
      limitName: safeRate.limit_name || safeRate.limitName || "Codex 默认额度",
      planType: safeRate.plan_type || safeRate.planType || null,
      primary: normalizeWindow(safeRate.primary),
      secondary: normalizeWindow(safeRate.secondary),
      reachedType:
        safeRate.rate_limit_reached_type ||
        safeRate.rateLimitReachedType ||
        null,
      usage: normalizeUsage(payload.info),
      usageCategory,
      projectName: state.projectName,
      projectPath: state.projectPath,
      model: state.model || "unknown",
    });
    state.previousCategory = usageCategory;
    state.scores = emptyScores();
  }
}

// Re-read an unfinished line from the source file after restart instead of
// persisting conversation text in the statistics cache or migration backups.
function cacheStateForDisk(state) {
  return {
    ...state,
    offset: Math.max(0, (state.offset || 0) - Buffer.byteLength(state.partial || "", "utf8")),
    partial: "",
  };
}

module.exports = {
  cacheStateForDisk,
  CodexReader,
  buildStats,
  normalizeWindow,
  normalizeUsage,
  periodKey,
  estimateCost,
  selectSevenDayWindow,
  bestCategory,
  categoryFromProject,
  scoreContext,
  emptyScores,
  listJsonlFiles,
  CATEGORIES,
  CATEGORY_LABELS,
  PRICE_CATALOG,
};
