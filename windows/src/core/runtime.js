const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { Store } = require("./storage");
const { UsageClient } = require("./usage-client");
const { OfficialSource } = require("./official-source");
const { RadarService } = require("./radar-v2110");
const { ExchangeRateService } = require("./exchange-rate");
const { OneDriveSync } = require("./onedrive-sync");
const { UpdateService } = require("./update-service");
const { buildStats } = require("./codex-reader");
const { forecast, recordSnapshot, alerts, commitAlert, analyze } = require("./analytics");
const quotaHistory = require("./quota-history");
const expiryLedger = require("./credit-expiry");
const pricing = require("./model-pricing");
const { freshness } = require("./data-freshness");
const { BackupArchive } = require("./backup-archive");
class Runtime extends EventEmitter {
  constructor(
    root,
    settings,
    {
      isVisible = () => true,
      sessionRoots,
      official,
      radar,
      now = () => Date.now(),
      notify = async () => false,
    } = {},
  ) {
    super();
    this.root = root;
    this.store = new Store(root);
    this.settings = settings;
    this.now = now;
    this.notify = notify;
    this.accountEpoch = 0;
    this.notificationBatch = null;
    this.notificationRetries = new Map();
    this.accountLedgers = new Map();
    this.pendingLedgerWrites = new Map();
    this.isVisible = isVisible;
    this.usage = new UsageClient({
      cachePath: path.join(root, "session-cache-v5.json"),
      sessionRoots,
    });
    this.official = official || new OfficialSource();
    this.radar = radar || new RadarService({ store: this.store });
    this.exchange = new ExchangeRateService({
      cachePath: path.join(root, "exchange-rate-usd-cny.json"),
    });
    this.sync = new OneDriveSync();
    this.updates = new UpdateService(this.store);
    this.budgets = this.store.read("project-budgets-v1", []);
    this.events = [];
    this.state = {
      generatedAt: new Date().toISOString(),
      statisticsLoading: true,
      scannedFiles: 0,
      eventCount: 0,
      tokenStats: buildStats([]),
      sourceStates: {
        quota: "unavailable",
        flexible: "unavailable",
        reset: "unavailable",
      },
    };
    this.timers = [];
    this.scope = null;
    this.history = [];
    this.ledger = {};
    this.lastOfficialAt = 0;
    this.backupArchive = new BackupArchive(root);
    this.stopped = false;
    this.statisticsPending = null;
    this.lastUsageKey = null;
    try {
      pricing.setPriceTable(this.store.read("model-prices-v1", null));
    } catch {
      this.event("warning", "价格覆盖表无效，使用内置价格");
    }
  }
  event(level, message) {
    this.events.push({
      at: new Date(this.now()).toISOString(),
      level,
      message,
    });
    this.events = this.events.slice(-100);
  }
  start() {
    this.refresh();
    this.refreshRadar();
    this.statistics();
    if (this.settings.autoUpdates) this.checkUpdates();
    this.timers.push(
      setInterval(() => this.tick(), 5000),
      setInterval(() => this.statistics(), 10000),
      setInterval(() => this.refreshRadar(), 60000),
      setInterval(() => {
        this.publish();
        this.maintenance();
      }, 60000),
    );
  }
  tick() {
    const idle =
        !this.isVisible() &&
        this.now() - (this.state.metrics?.lastActivityAt || 0) >= 300000,
      interval = idle ? 120000 : this.settings.refreshSeconds * 1000;
    const resumed = this.idle === true && !idle;
    this.idle = idle;
    if (resumed || this.now() - this.lastOfficialAt >= interval) this.refresh();
    else this.publish();
  }
  async refresh({ force = false, forceRadar = false } = {}) {
    if (this.refreshPromise) return this.refreshPromise;
    this.lastOfficialAt = this.now();
    this.refreshPromise = (async () => {
      try {
        const account = await this.official.read({ force });
        this.changeScope(account.accountScope);
        const meta = account.quotaRead;
        if (
          this.scope &&
          account.sourceStates.quota === "fresh" &&
          account.weekly
        ) {
          const next = recordSnapshot(
            this.history,
            account.weekly,
            meta.sampledAt,
            this.now(),
          );
          if (next !== this.history) {
            this.history = next;
            this.store.write("quota-history-" + this.scope, next);
          }
        }
        this.state.exchangeRate = await this.exchange.current();
        this.publish();
        if (force) {
          this.statistics(true);
        }
        if (forceRadar) this.refreshRadar(true);
      } catch {
        this.event("failure", "官方数据刷新失败");
        this.publish();
        if (force) throw new Error("官方数据刷新失败");
      } finally {
        this.refreshPromise = null;
      }
    })();
    return this.refreshPromise;
  }
  async statistics(force = false) {
    if (this.statisticsPending) return this.statisticsPending;
    this.statisticsPending = (async () => {
      try {
        const result = await this.usage.read({
          force,
          prices: pricing.getPriceTable(),
        });
        if (this.stopped) return;
        Object.assign(this.state, {
          tokenStats: result.tokenStats,
          statisticsLoading: false,
          scannedFiles: result.scannedFiles,
          eventCount: result.eventCount,
          metrics: result.metrics,
          sessionsRoot: result.sessionsRoot,
          codexHome: result.codexHome,
          statisticsAt: result.generatedAt,
        });
        const key =
          result.metrics.analysisCount + ":" + this.settings.oneDriveSync;
        if (this.settings.oneDriveSync && key !== this.lastUsageKey) {
          try {
            this.state.tokenStats.devices = await this.sync.persistAndRead(
              result.tokenStats,
            );
            this.syncFailure = null;
          } catch {
            this.syncFailure = "OneDrive 同步暂不可用";
            this.event("warning", this.syncFailure);
          }
        } else this.state.tokenStats.devices = this.devices || [];
        this.devices = this.state.tokenStats.devices;
        this.lastUsageKey = key;
        this.usageFailure = null;
        if (this.analysisSignature !== result.metrics.analysisCount) {
          this.state.analysis = analyze(
            this.state.tokenStats,
            this.budgets,
            new Date(this.now()),
          );
          this.analysisSignature = result.metrics.analysisCount;
        }
        this.publish();
      } catch {
        this.usageFailure = "会话统计失败，保留上次统计";
        this.event("failure", this.usageFailure);
        this.publish();
      } finally {
        this.statisticsPending = null;
      }
    })();
    return this.statisticsPending;
  }
  async refreshRadar(force = false) {
    await this.radar.current({ force });
    this.publish();
  }
  changeScope(scope) {
    if ((scope || null) === this.scope) return;
    if (this.scope) this.accountLedgers.set(this.scope, this.ledger);
    this.accountEpoch++;
    this.scope = scope || null;
    this.notificationRetries.clear();
    this.history = this.scope ? this.store.read("quota-history-" + this.scope, []) : [];
    this.ledger = this.scope ? this.accountLedgers.get(this.scope) || this.store.read("alert-ledger-" + this.scope, {}) : {};
    this.state.quotaHistory = [];
    this.state.forecast = null;
    this.event("info", "账户状态变化，已隔离历史记录");
  }
  persistAlertLedger(scope, ledger) {
    this.accountLedgers.set(scope, ledger);
    if (this.scope === scope) this.ledger = ledger;
    try {
      this.store.write("alert-ledger-" + scope, ledger);
      this.pendingLedgerWrites.delete(scope);
    } catch {
      if (!this.pendingLedgerWrites.has(scope))
        this.event("warning", "提醒回执写入失败，保留已接受状态并在巡检时重试");
      this.pendingLedgerWrites.set(scope, ledger);
    }
  }
  deliverAlerts(deliveries) {
    if (this.notificationBatch || !this.scope || !this.settings.notifications || this.stopped) return;
    const eligible = deliveries.filter(d => this.now() >= (this.notificationRetries.get(d.id) || 0));
    if (!eligible.length) return;
    const epoch = this.accountEpoch, scope = this.scope;
    this.notificationBatch = (async () => {
      for (const item of eligible) {
        if (this.stopped || this.accountEpoch !== epoch || !this.settings.notifications) break;
        const submittedLedger = this.ledger;
        let accepted = false;
        try { accepted = await this.notify(item.body); } catch {}
        if (accepted === true) {
          // The system may accept a submitted notification after an account
          // switch. Record that receipt only in its originating account.
          const ledger = this.scope === scope ? this.ledger
            : this.accountLedgers.get(scope) || this.store.read("alert-ledger-" + scope, {});
          const stale = this.stopped || this.accountEpoch !== epoch;
          const newerForecastReceipt = stale && item.forecastCycle &&
            (ledger.lastForecastCriticalAt !== submittedLedger.lastForecastCriticalAt ||
              ledger.lastForecastCycle !== submittedLedger.lastForecastCycle);
          // A new forecast receipt may already have been committed after
          // switching back. Preserve that cycle, cooldown and current risk.
          const receipt = newerForecastReceipt ? { keys: item.keys } : item;
          this.persistAlertLedger(scope, commitAlert(ledger, receipt, this.now()));
          if (this.accountEpoch === epoch) this.notificationRetries.delete(item.id);
        } else if (!this.stopped && this.accountEpoch === epoch) {
          this.notificationRetries.set(item.id, this.now() + 60000);
          this.event("warning", "系统通知未被接受，至少 60 秒后重试");
        }
      }
    })().finally(() => { this.notificationBatch = null; });
  }
  publish() {
    if (this.stopped) return;
    const now = this.now(),
      account = this.official.snapshot(now);
    this.changeScope(account.accountScope);
    Object.assign(this.state, account);
    const current = account.weekly
      ? { ...account.weekly, recordedAt: account.quotaRead.sampledAt }
      : null;
    const prediction = forecast(this.history, current, now);
    this.state.forecast = prediction;
    this.state.quotaHistory = quotaHistory.points(this.history, 30, now);
    this.state.radar = this.radar.snapshot();
    this.state.updates = this.updates.state;
    this.state.budgets = this.budgets;
    this.state.creditExpiry = this.store.read("credit-expiry-v1", null);
    if (
      this.state.creditExpiry &&
      this.state.creditExpiry.accountScope !== this.scope
    )
      this.state.creditExpiry = {
        ...this.state.creditExpiry,
        confirmed: false,
      };
    this.state.creditExpiryBatches = expiryLedger.forAccount(this.store.read("credit-expiry-batches-v1", []), this.scope);
    const alert = alerts({
      weekly: account.weekly,
      forecast: prediction,
      credits: account.rateLimitResetCredits,
      settings: this.settings,
      ledger: this.ledger,
      fresh: account.sourceStates.quota === "fresh",
      creditsFresh: account.sourceStates.reset === "fresh",
      now,
    });
    if (this.scope && JSON.stringify(this.ledger) !== JSON.stringify(alert.ledger))
      this.persistAlertLedger(this.scope, alert.ledger);
    this.ledger = alert.ledger;
    this.deliverAlerts(alert.deliveries);
    this.state.generatedAt = new Date(now).toISOString();
    this.state.health = this.health();
    this.state.events = this.events;
    this.emit("status", this.state);
  }
  health() {
    const fileHealth = (name, missing = "healthy") => {
      const file = this.store.file(name);
      if (!fs.existsSync(file)) return missing;
      try {
        JSON.parse(fs.readFileSync(file, "utf8"));
        return "healthy";
      } catch {
        return "critical";
      }
    };
    return [
      {
        id: "officialQuota",
        label: "官方额度",
        state:
          this.state.sourceStates.quota === "fresh"
            ? "healthy"
            : this.state.sourceStates.quota === "expired"
              ? "critical"
              : "warning",
      },
      {
        id: "tokenAggregation",
        label: "Token 统计",
        state: this.usageFailure
          ? "critical"
          : this.state.statisticsLoading
            ? "unknown"
            : "healthy",
      },
      {
        id: "radar",
        label: "重置雷达",
        state:
          this.state.radar?.sourceState === "fresh" ? "healthy" : "warning",
      },
      {
        id: "quotaHistory",
        label: "账户额度历史",
        state: this.scope
          ? fileHealth("quota-history-" + this.scope, "unknown")
          : "unknown",
      },
      {
        id: "projectBudgets",
        label: "项目预算",
        state: fileHealth("project-budgets-v1"),
      },
      {
        id: "widgetSnapshot",
        label: "共享快照与桌面卡片",
        state: this.snapshotFailure
          ? "critical"
          : fileHealth("widget-snapshot", "unknown"),
      },
      {
        id: "launchWatcher",
        label: "后台启动监测",
        state: this.launchWatcherFailure ? "warning" : "healthy",
      },
    ];
  }
  maintenance() {
    for (const [scope, ledger] of this.pendingLedgerWrites)
      this.persistAlertLedger(scope, ledger);
    try {
      this.store.write("widget-snapshot", {
        schemaVersion: 4,
        generatedAt: this.state.generatedAt,
        weekly: this.state.weekly,
        fiveHour: this.state.fiveHour,
        sourceStates: this.state.sourceStates,
        quotaRead: this.state.quotaRead,
        flexibleRead: this.state.flexibleRead,
        resetRead: this.state.resetRead,
        tokens: {
          today: this.state.tokenStats.todayTokens,
          month: this.state.tokenStats.monthTokens,
          rolling24: this.state.tokenStats.rolling24HoursTokens,
        },
        radar: this.state.radar
          ? {
              prediction: this.state.radar.prediction,
              lastSuccessAt: this.state.radar.lastSuccessAt,
            }
          : null,
      });
      this.snapshotFailure = null;
    } catch {
      this.snapshotFailure = true;
      this.event("failure", "共享快照写入失败");
    }
    const day = new Date(this.now()).toLocaleDateString("sv-SE");
    if (this.settings.dailyBackup && this.scope) {
      try {
        const sources = ["settings", "quota-history-" + this.scope,
          "alert-ledger-" + this.scope, "project-budgets-v1", "model-prices-v1",
          "credit-expiry-v1", "credit-expiry-batches-v1"].map(name => this.store.file(name));
        const now = new Date(this.now());
        if (!this.backupArchive.hasBackup(now, sources)) {
          const result = this.backupArchive.backup(sources, now);
          if (result.itemCount) this.event("info", "每日关键数据备份完成并通过完整性校验");
        }
      } catch {
        this.event("failure", "每日备份失败，下次巡检重试");
      }
    }
    if (
      !this.state.statisticsLoading &&
      this.settings.dailySummary &&
      this.store.read("last-summary-day", "") !== day
    ) {
      this.store.write("daily-summary-" + day, {
        day,
        todayTokens: this.state.tokenStats.todayTokens,
        monthTokens: this.state.tokenStats.monthTokens,
        costMonth: this.state.tokenStats.costMonth,
      });
      this.store.write("last-summary-day", day);
    }
  }
  setBudget({ id, limit, remove = false }) {
    if (typeof id !== "string" || typeof remove !== "boolean" || (!remove && (!Number.isSafeInteger(limit) || limit <= 0)))
      throw new Error("预算必须为正整数；删除请使用删除预算操作");
    const project = this.state.tokenStats.monthTopProjects.find(
        (p) => p.id === id,
      ),
      old = this.budgets.find((b) => b.id === id);
    if (!project && !old) throw new Error("请选择已识别项目");
    if (remove && !old) throw new Error("预算不存在");
    const next = this.budgets.filter((b) => b.id !== id);
    if (!remove)
      next.push({
        id,
        projectName: project?.projectName || old.projectName,
        projectPath: project?.projectPath || old.projectPath,
        monthlyTokenLimit: limit,
      });
    this.store.write("project-budgets-v1", next);
    this.budgets = next;
    this.state.analysis = analyze(this.state.tokenStats, this.budgets);
    this.publish();
    return this.budgets;
  }
  setExpiry({ date, evidence, confirmed }) {
    if (
      !/^\d{4}-\d{2}-\d{2}$/.test(date) ||
      !Number.isFinite(Date.parse(date)) ||
      typeof evidence !== "string" ||
      evidence.length > 1000 ||
      typeof confirmed !== "boolean" ||
      (confirmed && (!this.scope || evidence.trim().length < 5))
    )
      throw new Error("请填写有效日期和核实依据，确认需要当前账户");
    this.store.write("credit-expiry-v1", {
      date,
      evidence: evidence.trim(),
      confirmed,
      accountScope: this.scope,
    });
    this.publish();
  }
  setExpiryBatch(value) {
    const rows = expiryLedger.save(this.store.read("credit-expiry-batches-v1", []), value, this.scope);
    this.store.write("credit-expiry-batches-v1", rows);
    this.publish();
    return this.state.creditExpiryBatches;
  }
  async checkUpdates(force = false) {
    await this.updates.check(force);
    this.publish();
    return this.updates.state;
  }
  diagnostics() {
    return {
      version: require("../../package.json").version,
      build: 2128,
      platform: process.platform,
      arch: process.arch,
      generatedAt: new Date().toISOString(),
      sourceStates: this.state.sourceStates,
      health: this.health(),
      metrics: this.state.metrics,
      scannedFiles: this.state.scannedFiles,
      events: this.events,
      pricing: {
        version: pricing.version(),
        coverage: this.state.tokenStats.costMonth.coverage,
      },
      radar: this.state.radar
        ? {
            state: this.state.radar.sourceState,
            lastSuccessAt: this.state.radar.lastSuccessAt,
            evaluation: {
              n: this.state.radar.evaluation.n,
              brier: this.state.radar.evaluation.brier,
            },
          }
        : null,
    };
  }
  stop() {
    this.stopped = true;
    this.accountEpoch++;
    this.timers.forEach(clearInterval);
    this.usage.close();
  }
}
module.exports = { Runtime };
