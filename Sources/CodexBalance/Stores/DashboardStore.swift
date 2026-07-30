import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

private let dashboardLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "dev.codex.balance-dashboard.codex",
  category: "DashboardStore"
)

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
  case system
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case en
  case ja
  case ko
  case es
  case fr
  case de
  case ru
  case ptBR = "pt-BR"

  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: "跟随系统".l10n
    case .zhHans: "简体中文"
    case .zhHant: "繁體中文"
    case .en: "English"
    case .ja: "日本語"
    case .ko: "한국어"
    case .es: "Español"
    case .fr: "Français"
    case .de: "Deutsch"
    case .ru: "Русский"
    case .ptBR: "Português (Brasil)"
    }
  }
}

enum CompactStyle: String, CaseIterable, Identifiable, Hashable {
  case rings
  case circle
  case square
  case pill
  case bars
  case barsQuad
  case badge
  case badgeQuad

  var id: String { rawValue }
  var title: String {
    switch self {
    case .rings: "额度环"
    case .circle: "圆形"
    case .square: "方形"
    case .pill: "胶囊"
    case .bars: "横条"
    case .barsQuad: "横条·详细"
    case .badge: "徽章"
    case .badgeQuad: "徽章·详细"
    }
  }
  var subtitle: String {
    switch self {
    case .rings: "7天余额 + 24h 消耗"
    case .circle: "纯圆双指标"
    case .square: "紧凑双指标"
    case .pill: "横向极简状态"
    case .bars: "7天余额横条"
    case .barsQuad: "余额、Token 与金额"
    case .badge: "只看7天余额"
    case .badgeQuad: "7天余额 + 24h Token"
    }
  }

  var systemImage: String {
    switch self {
    case .rings: "circle.dotted.circle"
    case .circle: "circle.fill"
    case .square: "square.fill"
    case .pill: "capsule.fill"
    case .bars: "rectangle.split.1x2"
    case .barsQuad: "rectangle.split.2x1"
    case .badge: "number.circle"
    case .badgeQuad: "rectangle.inset.filled"
    }
  }

  var usesCompactMenu: Bool {
    switch self {
    case .circle, .square, .pill, .badge, .badgeQuad: true
    default: false
    }
  }
}

enum TouchBarPanelStyle: String, CaseIterable, Identifiable, Hashable {
  case barsQuad
  case bars
  case badgeQuad
  case badge

  var id: String { rawValue }
  var title: String {
    switch self {
    case .barsQuad: "余额条 + 24h"
    case .bars: "余额条"
    case .badgeQuad: "双数字"
    case .badge: "余额数字"
    }
  }
}

enum CompactSizeMode: String, CaseIterable, Identifiable, Hashable {
  case standard
  case mini
  var id: String { rawValue }
  var title: String { self == .standard ? "标准".l10n : "迷你".l10n }
}

enum CompactRingOrientation: String, CaseIterable, Identifiable, Hashable {
  case horizontal
  case vertical

  var id: String { rawValue }
  var title: String { self == .horizontal ? "横向长方形" : "竖向长方形" }
}

enum RefreshIntervalOption: String, CaseIterable, Identifiable, Hashable {
  case five = "5"
  case ten = "10"
  case thirty = "30"
  var id: String { rawValue }
  var title: String { "\(rawValue)s" }
  var seconds: TimeInterval { TimeInterval(Double(rawValue) ?? 5) }
  static let recommended: RefreshIntervalOption = .thirty
}

enum ReliabilityIntervalOption: String, CaseIterable, Identifiable, Hashable {
  case fifteen = "15"
  case thirty = "30"
  case sixty = "60"

  var id: String { rawValue }
  var title: String { "\(rawValue) 分钟" }
  var seconds: TimeInterval { TimeInterval((Int(rawValue) ?? 30) * 60) }
}

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
  case overview
  case trends
  case insights
  case settings

  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "概览"
    case .trends: "趋势"
    case .insights: "分析"
    case .settings: "设置"
    }
  }
  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .trends: "chart.xyaxis.line"
    case .insights: "square.grid.2x2.fill"
    case .settings: "gearshape.fill"
    }
  }
}

@MainActor
final class DashboardStore: ObservableObject {
  @Published private(set) var status: CodexStatus?
  @Published private(set) var exchangeRate: ExchangeRateSnapshot?
  @Published private(set) var lastRefresh: Date?
  @Published private(set) var errorMessage: String?
  @Published private(set) var isLoading = false
  @Published private(set) var isFullRefreshing = false
  @Published private(set) var lastFullRefresh: Date?
  @Published private(set) var exportMessage: String?
  @Published private(set) var launchWithCodexEnabled = CodexWatcherManager.isEnabled()
  @Published private(set) var settingsMessage: String?
  @Published private(set) var clamshellActive = false
  @Published private(set) var codexRadarSnapshot: CodexRadarSnapshot?
  @Published private(set) var codexRadarIsLoading = false
  @Published private(set) var codexRadarStatusMessage = "正在连接重置雷达小程序公开源…"
  @Published private(set) var codexRadarLastSyncAt: Date?
  @Published private(set) var codexRadarNextSyncAt: Date?
  @Published private(set) var quotaForecast: QuotaForecast?
  @Published private(set) var usageAnalysis = UsageAnalysis()
  @Published private(set) var projectBudgets: [ProjectBudget] = []
  @Published private(set) var budgetMessage: String?
  @Published private(set) var reliabilitySnapshot = ReliabilitySnapshot()
  @Published private(set) var reliabilityEvents: [ReliabilityEvent] = []
  @Published private(set) var reliabilityMessage: String?
  @Published private(set) var latestAppRelease: AppRelease?
  @Published private(set) var appUpdateAvailability: AppUpdateAvailability?
  @Published private(set) var appUpdateIsChecking = false
  @Published private(set) var appUpdateStatusMessage = "尚未检查版本更新"
  @Published private(set) var lastAppUpdateCheckAt: Date?
  @Published private(set) var quotaAlertsEnabled: Bool
  @Published private(set) var notificationAuthorization: QuotaNotificationAuthorization = .notDetermined
  @Published var quotaAlertPreset: QuotaAlertPreset {
    didSet { save(quotaAlertPreset.rawValue, "quotaAlertPreset") }
  }
  @Published var quotaThresholdAlertsEnabled: Bool {
    didSet { save(quotaThresholdAlertsEnabled, "quotaThresholdAlertsEnabled") }
  }
  @Published var quotaForecastAlertsEnabled: Bool {
    didSet { save(quotaForecastAlertsEnabled, "quotaForecastAlertsEnabled") }
  }
  @Published var quotaResetCreditAlertsEnabled: Bool {
    didSet { save(quotaResetCreditAlertsEnabled, "quotaResetCreditAlertsEnabled") }
  }
  @Published var reliabilityHealthChecksEnabled: Bool {
    didSet { save(reliabilityHealthChecksEnabled, "reliabilityHealthChecksEnabled"); restartReliabilityAutomation() }
  }
  @Published var reliabilityAutoRecoveryEnabled: Bool {
    didSet { save(reliabilityAutoRecoveryEnabled, "reliabilityAutoRecoveryEnabled") }
  }
  @Published var reliabilityBackupsEnabled: Bool {
    didSet { save(reliabilityBackupsEnabled, "reliabilityBackupsEnabled"); restartReliabilityAutomation() }
  }
  @Published var reliabilityDailySummaryEnabled: Bool {
    didSet { save(reliabilityDailySummaryEnabled, "reliabilityDailySummaryEnabled"); restartReliabilityAutomation() }
  }
  @Published var reliabilityIntervalOption: ReliabilityIntervalOption {
    didSet { save(reliabilityIntervalOption.rawValue, "reliabilityIntervalOption"); restartReliabilityAutomation() }
  }
  @Published var reliabilityDailySummaryHour: Int {
    didSet {
      let clamped = min(23, max(0, reliabilityDailySummaryHour))
      if clamped != reliabilityDailySummaryHour { reliabilityDailySummaryHour = clamped; return }
      save(reliabilityDailySummaryHour, "reliabilityDailySummaryHour")
    }
  }
  @Published var automaticUpdateChecksEnabled: Bool {
    didSet {
      save(automaticUpdateChecksEnabled, "automaticUpdateChecksEnabled")
      restartAppUpdateChecks()
    }
  }

  @Published var floatingPanelEnabled: Bool {
    didSet {
      guard floatingPanelEnabled != oldValue else { return }
      save(floatingPanelEnabled, "floatingPanelEnabled")
      if !floatingPanelEnabled, isCompact {
        isCompact = false
      } else {
        applyWindowVisibility()
      }
    }
  }
  @Published var isCompact: Bool {
    didSet {
      if isCompact, !floatingPanelEnabled {
        isCompact = false
        return
      }
      applyWindowVisibility()
    }
  }
  @Published private(set) var isWindowVisible: Bool {
    didSet { applyWindowVisibility() }
  }
  @Published var selectedSection: DashboardSection = .overview
  @Published private(set) var floatingPanelMetrics: Set<FloatingPanelMetric> {
    didSet {
      save(FloatingPanelMetric.persistedRawValues(floatingPanelMetrics), FloatingPanelMetric.userDefaultsKey)
      // 保留旧键，避免从 2.5.0 之前的版本回退时丢失 Full reset 偏好。
      save(floatingPanelMetrics.contains(.resetCredits), "compactShowsResetCredits")
    }
  }
  @Published var widgetShowsFiveHourQuota: Bool {
    didSet {
      guard widgetShowsFiveHourQuota != oldValue else { return }
      save(widgetShowsFiveHourQuota, "widgetShowsFiveHourQuota")
      writeWidgetSnapshotFile()
    }
  }
  @Published var compactSizeMode: CompactSizeMode { didSet { save(compactSizeMode.rawValue, "compactSizeMode") } }
  @Published var compactStyle: CompactStyle { didSet { save(compactStyle.rawValue, "compactStyle") } }
  @Published var compactRingOrientation: CompactRingOrientation {
    didSet { save(compactRingOrientation.rawValue, "compactRingOrientation") }
  }
  @Published var autoDodgeEnabled: Bool { didSet { save(autoDodgeEnabled, "autoDodgeEnabled") } }
  @Published var palette: DashboardPalette { didSet { save(palette.rawValue, DashboardPalette.userDefaultsKey) } }
  @Published var themeMode: DashboardThemeMode {
    didSet { save(themeMode.rawValue, DashboardThemeMode.userDefaultsKey) }
  }
  @Published var appearance: DashboardAppearance {
    didSet { save(appearance.rawValue, DashboardAppearance.userDefaultsKey) }
  }
  @Published var compactBackgroundOpacity: Double {
    didSet {
      let clamped = min(0.94, max(0.30, compactBackgroundOpacity))
      if compactBackgroundOpacity != clamped { compactBackgroundOpacity = clamped; return }
      save(compactBackgroundOpacity, "compactBackgroundOpacity")
    }
  }
  @Published var refreshIntervalOption: RefreshIntervalOption {
    didSet { save(refreshIntervalOption.rawValue, "refreshIntervalOption"); restartAutoRefreshIfNeeded() }
  }
  @Published var touchBarEnabled: Bool {
    didSet {
      save(touchBarEnabled, "touchBarEnabled")
      TouchBarStripController.shared.setEnabled(touchBarEnabled)
      updateTouchBar()
      applyWindowVisibility()
    }
  }
  @Published var touchBarStyle: TouchBarPanelStyle {
    didSet {
      save(touchBarStyle.rawValue, "touchBarStyle")
      TouchBarStripController.shared.setPanelStyle(touchBarStyle)
      updateTouchBar()
    }
  }
  @Published var touchBarShowsSessions: Bool {
    didSet { save(touchBarShowsSessions, "touchBarShowsSessions"); pushSessionsToTouchBar() }
  }
  @Published var touchBarSessionCount: Int {
    didSet { touchBarSessionCount = min(3, max(1, touchBarSessionCount)); save(touchBarSessionCount, "touchBarSessionCount"); pushSessionsToTouchBar() }
  }
  @Published var appLanguage: AppLanguage {
    didSet {
      guard appLanguage != oldValue else { return }
      if appLanguage == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
      else { UserDefaults.standard.set([appLanguage.rawValue], forKey: "AppleLanguages") }
      relaunchApp()
    }
  }

  var enabledToolCount: Int { 1 }
  var touchBarSupported: Bool { TouchBarStripController.shared.isSupported }
  var compactShowsResetCredits: Bool { floatingPanelMetrics.contains(.resetCredits) }
  var weekly: LimitWindow? { status?.main?.sevenDayWindow }
  var fiveHour: LimitWindow? { status?.main?.fiveHourWindow }
  var rateLimitResetCredits: RateLimitResetCreditsSummary? { status?.rateLimitResetCredits }
  var tokenStats: TokenStats { status?.tokenStats ?? TokenStats() }
  var cnyAvailable: Bool { exchangeRate != nil }
  var menuBarTitle: String { weekly.map { "7天 \(Int($0.remainingPercent.rounded()))%" } ?? "7天 --" }
  var appUpdateAvailable: Bool { appUpdateAvailability == .updateAvailable }
  var latestAppReleaseVersionText: String? { latestAppRelease?.version.map { "v\($0)" } }

  private let fastReader = CodexStatusReader()
  private let fullReader = CodexStatusReader()
  private let exchangeRateService: ExchangeRateService
  private let codexRadarService = CodexRadarService()
  private let quotaHistoryStore = QuotaHistoryStore()
  private let projectBudgetStore = ProjectBudgetStore()
  private let reliabilityEventStore = ReliabilityEventStore()
  private let localAutomationArchive = LocalAutomationArchive()
  private let appUpdateService = GitHubReleaseUpdateService()
  private let quotaNotificationService = QuotaNotificationService.shared
  private var quotaAlertLedger: QuotaAlertLedger
  private var refreshTimer: Timer?
  private var codexRadarRefreshTimer: Timer?
  private var reliabilityTimer: Timer?
  private var appUpdateTimer: Timer?
  private var fullRefreshInFlight = false
  private var isWindowDragging = false
  private var refreshRequestedAfterDrag = false
  private var forceFullRefreshAfterDrag = false
  private var deferredFastStatus: (status: CodexStatus, forceFull: Bool)?
  private var deferredFullStatus: CodexStatus?
  private var deferredRefreshError: String?
  private var refreshRequestedWhileBusy = false
  private var forceFullRefreshWhileBusy = false
  private var lastWidgetReloadAt: Date?
  private var pendingWidgetReloadTask: Task<Void, Never>?
  private let widgetReloadPolicy = CodexWidgetReloadPolicy(minimumInterval: 10)
  private var lastReliabilityLevel: ReliabilityHealthLevel?
  private var lastAutomaticRecoveryAt: Date?
  private var automaticRecoveryAttempts = 0

  init() {
    let defaults = UserDefaults.standard
    quotaAlertsEnabled = defaults.object(forKey: "quotaAlertsEnabled") as? Bool ?? false
    quotaAlertPreset = defaults.string(forKey: "quotaAlertPreset").flatMap(QuotaAlertPreset.init) ?? .standard
    quotaThresholdAlertsEnabled = defaults.object(forKey: "quotaThresholdAlertsEnabled") as? Bool ?? true
    quotaForecastAlertsEnabled = defaults.object(forKey: "quotaForecastAlertsEnabled") as? Bool ?? true
    quotaResetCreditAlertsEnabled = defaults.object(forKey: "quotaResetCreditAlertsEnabled") as? Bool ?? true
    reliabilityHealthChecksEnabled = defaults.object(forKey: "reliabilityHealthChecksEnabled") as? Bool ?? true
    reliabilityAutoRecoveryEnabled = defaults.object(forKey: "reliabilityAutoRecoveryEnabled") as? Bool ?? true
    reliabilityBackupsEnabled = defaults.object(forKey: "reliabilityBackupsEnabled") as? Bool ?? true
    reliabilityDailySummaryEnabled = defaults.object(forKey: "reliabilityDailySummaryEnabled") as? Bool ?? false
    reliabilityIntervalOption = defaults.string(forKey: "reliabilityIntervalOption")
      .flatMap(ReliabilityIntervalOption.init) ?? .thirty
    reliabilityDailySummaryHour = min(23, max(0, defaults.object(forKey: "reliabilityDailySummaryHour") as? Int ?? 20))
    automaticUpdateChecksEnabled = defaults.object(forKey: "automaticUpdateChecksEnabled") as? Bool ?? true
    lastAutomaticRecoveryAt = defaults.object(forKey: "lastAutomaticRecoveryAt") as? Date
    automaticRecoveryAttempts = defaults.object(forKey: "automaticRecoveryAttempts") as? Int ?? 0
    quotaAlertLedger = defaults.data(forKey: "quotaAlertLedger")
      .flatMap { try? JSONDecoder().decode(QuotaAlertLedger.self, from: $0) } ?? QuotaAlertLedger()
    let persistedFloatingPanelEnabled = defaults.object(forKey: "floatingPanelEnabled") as? Bool ?? true
    let launchedInBackground = CommandLine.arguments.contains("--background")
    floatingPanelEnabled = persistedFloatingPanelEnabled
    isCompact = persistedFloatingPanelEnabled
    isWindowVisible = FloatingPanelStartupPolicy.shouldShowWindow(
      floatingPanelEnabled: persistedFloatingPanelEnabled,
      launchedInBackground: launchedInBackground
    )

    floatingPanelMetrics = FloatingPanelMetric.resolvedSelection(
      rawValues: defaults.stringArray(forKey: FloatingPanelMetric.userDefaultsKey),
      legacyShowsResetCredits: defaults.object(forKey: "compactShowsResetCredits") as? Bool
    )
    widgetShowsFiveHourQuota = defaults.object(forKey: "widgetShowsFiveHourQuota") as? Bool ?? false

    compactSizeMode = defaults.string(forKey: "compactSizeMode").flatMap(CompactSizeMode.init) ?? .standard
    compactStyle = defaults.string(forKey: "compactStyle").flatMap(CompactStyle.init) ?? .rings
    compactRingOrientation = defaults.string(forKey: "compactRingOrientation")
      .flatMap(CompactRingOrientation.init) ?? .horizontal
    autoDodgeEnabled = defaults.object(forKey: "autoDodgeEnabled") as? Bool ?? false
    touchBarEnabled = defaults.object(forKey: "touchBarEnabled") as? Bool ?? false
    touchBarStyle = defaults.string(forKey: "touchBarStyle").flatMap(TouchBarPanelStyle.init) ?? .barsQuad
    touchBarShowsSessions = defaults.object(forKey: "touchBarShowsSessions") as? Bool ?? true
    touchBarSessionCount = min(3, max(1, defaults.object(forKey: "touchBarSessionCount") as? Int ?? 3))
    palette = defaults.string(forKey: DashboardPalette.userDefaultsKey).flatMap(DashboardPalette.init) ?? .mintDawn
    themeMode = defaults.string(forKey: DashboardThemeMode.userDefaultsKey)
      .flatMap(DashboardThemeMode.init) ?? .defaultMode
    appearance = defaults.string(forKey: DashboardAppearance.userDefaultsKey)
      .flatMap(DashboardAppearance.init) ?? .aurora
    compactBackgroundOpacity = min(0.94, max(0.30, defaults.object(forKey: "compactBackgroundOpacity") as? Double ?? 0.78))
    let savedRefreshInterval = defaults.string(forKey: "refreshIntervalOption").flatMap(RefreshIntervalOption.init)
    let refreshMigrationKey = "v243FastRefreshMigrationApplied"
    if defaults.bool(forKey: refreshMigrationKey) == false, savedRefreshInterval == .five {
      refreshIntervalOption = .recommended
      defaults.set(RefreshIntervalOption.recommended.rawValue, forKey: "refreshIntervalOption")
    } else {
      refreshIntervalOption = savedRefreshInterval ?? .recommended
    }
    defaults.set(true, forKey: refreshMigrationKey)
    let languages = defaults.array(forKey: "AppleLanguages") as? [String]
    appLanguage = languages?.first.flatMap(AppLanguage.init) ?? .system

    let cacheURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter/exchange-rate-usd-cny.json")
    exchangeRateService = ExchangeRateService(cacheURL: cacheURL)
    projectBudgets = projectBudgetStore.load()
    reliabilityEvents = reliabilityEventStore.load()
    restoreCachedAppUpdate(defaults: defaults)
    updateUsageAnalysis()

    repairLaunchWatcherIfNeeded(showMessage: false)
    TouchBarStripController.shared.onOpenPanel = { [weak self] in self?.isCompact = false; self?.refresh() }
    TouchBarStripController.shared.setPanelStyle(touchBarStyle)
    TouchBarStripController.shared.setEnabled(touchBarEnabled)
    updateClamshellState(initial: true)
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.updateClamshellState(initial: false) } }
    NotificationCenter.default.addObserver(
      forName: .codexRequestMainWindow,
      object: nil,
      queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.showDashboard() } }
    NotificationCenter.default.addObserver(
      forName: .codexOpenOverview,
      object: nil,
      queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.showDashboard() } }
    installCodexRadarLifecycleObservers()
    #if DEBUG
    if let fixturePath = ProcessInfo.processInfo.environment["CODEX_RADAR_FIXTURE_PATH"],
       let data = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)),
       let fixture = try? CodexRadarSnapshot.decode(from: data) {
      codexRadarSnapshot = fixture
      codexRadarStatusMessage = "已载入本地 Codex 雷达 QA 数据"
    }
    #endif
    Task { [weak self] in await self?.loadExchangeRate() }
    Task { [weak self] in await self?.refreshNotificationAuthorization() }
    DispatchQueue.main.async { [weak self] in
      self?.startAutoRefresh()
      self?.refreshCodexRadar()
      self?.startReliabilityAutomation()
      self?.startAppUpdateChecks()
    }
  }

  func startAutoRefresh() {
    if refreshTimer == nil {
      refresh()
      refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshIntervalOption.seconds, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
      }
    }
    if codexRadarRefreshTimer == nil {
      let timer = Timer(
        timeInterval: CodexRadarService.refreshInterval,
        repeats: true
      ) { [weak self] _ in
        Task { @MainActor in
          self?.codexRadarNextSyncAt = Date().addingTimeInterval(CodexRadarService.refreshInterval)
          self?.refreshCodexRadar(force: true)
        }
      }
      timer.tolerance = 2
      RunLoop.main.add(timer, forMode: .common)
      codexRadarRefreshTimer = timer
      codexRadarNextSyncAt = timer.fireDate
    }
  }

  func stopAutoRefresh() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    codexRadarRefreshTimer?.invalidate()
    codexRadarRefreshTimer = nil
    codexRadarNextSyncAt = nil
  }

  func startReliabilityAutomation() {
    guard reliabilityTimer == nil else { return }
    runReliabilityCheck()
    guard reliabilityHealthChecksEnabled || reliabilityBackupsEnabled || reliabilityDailySummaryEnabled else { return }
    let timer = Timer(timeInterval: reliabilityIntervalOption.seconds, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.runReliabilityCheck() }
    }
    timer.tolerance = min(120, reliabilityIntervalOption.seconds * 0.1)
    RunLoop.main.add(timer, forMode: .common)
    reliabilityTimer = timer
  }

  func runReliabilityCheck(manual: Bool = false, allowAutomation: Bool = true) {
    let now = Date()
    let next = ReliabilityAuditor.audit(
      inputs: ReliabilityAuditor.Inputs(
        lastQuotaRefresh: lastRefresh,
        hasOfficialQuota: weekly != nil,
        lastUsageRefresh: lastFullRefresh,
        usageSampleCount: tokenStats.sampleCount,
        radarUpdatedAt: codexRadarLastSyncAt,
        launchWatcherEnabled: CodexWatcherManager.isEnabled()
      ),
      now: now
    )
    reliabilitySnapshot = next

    if manual {
      appendReliabilityEvent(.init(
        timestamp: now,
        kind: .info,
        title: "手动健康检查完成",
        detail: "\(next.criticalCount) 项异常，\(next.warningCount) 项需关注"
      ))
      reliabilityMessage = "健康检查已完成"
    } else if let previous = lastReliabilityLevel, previous != next.overall, next.overall != .unknown {
      let recovered = previous.rank > next.overall.rank
      appendReliabilityEvent(.init(
        timestamp: now,
        kind: recovered ? .recovery : .warning,
        title: recovered ? "可靠性状态恢复" : "可靠性状态变化",
        detail: "当前状态：\(reliabilityLevelLabel(next.overall))"
      ))
    }
    lastReliabilityLevel = next.overall

    guard allowAutomation else { return }
    if reliabilityBackupsEnabled, !localAutomationArchive.hasBackup(for: now) {
      performLocalBackup(manual: false, now: now)
    }
    if reliabilityDailySummaryEnabled,
       Calendar.current.component(.hour, from: now) >= reliabilityDailySummaryHour,
       !localAutomationArchive.hasDailySummary(for: now) {
      archiveDailySummary(now: now)
    }
    if reliabilityHealthChecksEnabled, reliabilityAutoRecoveryEnabled {
      attemptAutomaticRecovery(snapshot: next, now: now)
    }
  }

  func performLocalBackup(manual: Bool = true, now: Date = Date()) {
    do {
      let result = try localAutomationArchive.backup(
        sourceURLs: [QuotaHistoryStore.defaultURL, ProjectBudgetStore.defaultURL],
        now: now,
        retentionDays: 7
      )
      reliabilityMessage = result.itemCount > 0
        ? "已备份 \(result.itemCount) 个关键数据文件"
        : "当前没有可备份的关键数据文件"
      appendReliabilityEvent(.init(
        timestamp: now,
        kind: .info,
        title: manual ? "手动备份完成" : "每日备份完成",
        detail: "已保存 \(result.itemCount) 个文件，保留最近 7 天"
      ))
    } catch {
      reliabilityMessage = "备份失败：\(error.localizedDescription)"
      appendReliabilityEvent(.init(timestamp: now, kind: .failure, title: "关键数据备份失败", detail: "本地归档未完成"))
    }
  }

  func exportDiagnosticReport() {
    runReliabilityCheck(allowAutomation: false)
    let panel = NSSavePanel()
    panel.title = "导出脱敏诊断报告"
    panel.prompt = "导出"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    panel.nameFieldStringValue = "codex-pulse-diagnostics-\(formatter.string(from: Date())).md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let markdown = ReliabilityReportBuilder.diagnosticMarkdown(
      appVersion: AppInfo.version,
      snapshot: reliabilitySnapshot,
      recentEvents: reliabilityEvents
    )
    do {
      try markdown.write(to: url, atomically: true, encoding: .utf8)
      reliabilityMessage = "诊断报告已导出：\(url.lastPathComponent)"
    } catch {
      reliabilityMessage = "诊断报告导出失败：\(error.localizedDescription)"
    }
  }

  func openAutomationFolder() {
    do {
      try FileManager.default.createDirectory(at: LocalAutomationArchive.defaultRoot, withIntermediateDirectories: true)
      NSWorkspace.shared.open(LocalAutomationArchive.defaultRoot)
    } catch {
      reliabilityMessage = "无法打开自动化目录：\(error.localizedDescription)"
    }
  }

  func startAppUpdateChecks() {
    guard automaticUpdateChecksEnabled else { return }
    if appUpdateTimer == nil {
      let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.checkForAppUpdate(manual: false) }
      }
      timer.tolerance = 15 * 60
      RunLoop.main.add(timer, forMode: .common)
      appUpdateTimer = timer
    }
    checkForAppUpdate(manual: false)
  }

  func checkForAppUpdate(manual: Bool = true) {
    guard !appUpdateIsChecking else { return }
    if !manual,
       let lastAppUpdateCheckAt,
       Date().timeIntervalSince(lastAppUpdateCheckAt) < 24 * 60 * 60 {
      return
    }

    appUpdateIsChecking = true
    if manual { appUpdateStatusMessage = "正在检查 GitHub Releases…" }
    let service = appUpdateService
    Task {
      do {
        let result = try await service.check(currentVersion: AppInfo.version)
        applyAppUpdateResult(result)
      } catch {
        if manual || latestAppRelease == nil {
          appUpdateStatusMessage = "版本检查失败：\(error.localizedDescription)"
        }
      }
      appUpdateIsChecking = false
    }
  }

  func openAppUpdatePage() {
    let fallback = URL(string: AppInfo.releasesURL)
    let candidate = latestAppRelease?.htmlURL ?? fallback
    guard let candidate, candidate.scheme == "https",
          let host = candidate.host?.lowercased(),
          host == "github.com" || host.hasSuffix(".github.com")
    else {
      appUpdateStatusMessage = "更新页面地址无效"
      return
    }
    NSWorkspace.shared.open(candidate)
  }

  func refreshAll() {
    refresh(forceFull: true)
    refreshCodexRadar(force: true)
  }

  func refreshCodexRadar(force: Bool = false) {
    guard !codexRadarIsLoading else { return }
    codexRadarIsLoading = true
    codexRadarStatusMessage = "正在同步重置雷达小程序数据…"
    let service = codexRadarService
    Task {
      do {
        let snapshot = try await service.current(force: force)
        codexRadarSnapshot = snapshot
        codexRadarLastSyncAt = Date()
        codexRadarStatusMessage = snapshot.latestUpdate.map {
          "雷达更新于 \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "重置雷达小程序数据已更新"
        writeWidgetSnapshotFile()
      } catch {
        codexRadarStatusMessage = codexRadarSnapshot == nil
          ? error.localizedDescription
          : "更新失败，继续显示上次数据：\(error.localizedDescription)"
        dashboardLogger.error("Codex Radar refresh failed: \(error.localizedDescription, privacy: .public)")
      }
      codexRadarIsLoading = false
    }
  }

  func refresh(forceFull: Bool = false) {
    if isWindowDragging {
      refreshRequestedAfterDrag = true
      forceFullRefreshAfterDrag = forceFullRefreshAfterDrag || forceFull
      return
    }
    guard !isLoading else {
      refreshRequestedWhileBusy = true
      forceFullRefreshWhileBusy = forceFullRefreshWhileBusy || forceFull
      return
    }
    isLoading = true
    let reader = fastReader
    Task {
      do {
        let next = try await Task.detached(priority: .userInitiated) { try reader.readFast() }.value
        if isWindowDragging {
          deferredFastStatus = (next, forceFull)
        } else {
          applyFastStatus(next, forceFull: forceFull)
          isLoading = false
          runDeferredRefreshIfNeeded()
        }
      } catch {
        if isWindowDragging {
          deferredRefreshError = error.localizedDescription
        } else {
          errorMessage = error.localizedDescription
          isLoading = false
          runDeferredRefreshIfNeeded()
        }
        dashboardLogger.error("Fast refresh failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Keep the native window-server drag loop free of observable-object updates.
  /// Any refresh that finishes while the mouse is down is published once after
  /// `NSWindow.performDrag` returns.
  func beginWindowDrag() {
    isWindowDragging = true
  }

  func endWindowDrag() {
    guard isWindowDragging else { return }
    isWindowDragging = false

    let deferredFull = deferredFullStatus
    let deferredFast = deferredFastStatus
    let deferredError = deferredRefreshError
    deferredFullStatus = nil
    deferredFastStatus = nil
    deferredRefreshError = nil

    if let deferredFull {
      applyFullStatus(deferredFull)
      isFullRefreshing = false
    }
    if let deferredFast {
      applyFastStatus(deferredFast.status, forceFull: deferredFast.forceFull)
      isLoading = false
    } else if deferredError != nil {
      errorMessage = deferredError
      isLoading = false
    }

    runDeferredRefreshIfNeeded()

    let shouldRefresh = refreshRequestedAfterDrag
    let shouldForceFull = forceFullRefreshAfterDrag
    refreshRequestedAfterDrag = false
    forceFullRefreshAfterDrag = false
    if shouldRefresh {
      refresh(forceFull: shouldForceFull)
    }
  }

  func toggleCompactSizeMode() { compactSizeMode = compactSizeMode == .standard ? .mini : .standard }
  func refreshSettingsState() {
    repairLaunchWatcherIfNeeded(showMessage: false)
    Task { await refreshNotificationAuthorization() }
  }
  func syncWindowPresentation() { applyWindowVisibility() }

  func showsFloatingPanelMetric(_ metric: FloatingPanelMetric) -> Bool {
    floatingPanelMetrics.contains(metric)
  }

  func setFloatingPanelMetric(_ metric: FloatingPanelMetric, enabled: Bool) {
    var next = floatingPanelMetrics
    if enabled {
      next.insert(metric)
    } else {
      next.remove(metric)
    }
    guard !next.isEmpty else { return }
    floatingPanelMetrics = next
  }

  func showFloatingPanel() {
    guard floatingPanelEnabled else {
      showSettings()
      return
    }
    isCompact = true
    isWindowVisible = true
  }

  func hideWindow() {
    isWindowVisible = false
  }

  func requestCompactPanel() {
    if floatingPanelEnabled {
      isCompact = true
      isWindowVisible = true
    } else {
      showSettings()
    }
  }

  func showDashboard() {
    selectedSection = .overview
    isCompact = false
    isWindowVisible = true
    AppWindowRouter.shared.ensureMainWindow()
    refreshAll()
  }

  func showSettings() {
    selectedSection = .settings
    isCompact = false
    isWindowVisible = true
    AppWindowRouter.shared.ensureMainWindow()
    refreshSettingsState()
  }

  func showTrends() {
    selectedSection = .trends
    isCompact = false
    isWindowVisible = true
    AppWindowRouter.shared.ensureMainWindow()
  }

  func showInsights() {
    selectedSection = .insights
    isCompact = false
    isWindowVisible = true
    AppWindowRouter.shared.ensureMainWindow()
  }

  func setQuotaAlertsEnabled(_ enabled: Bool) {
    quotaAlertsEnabled = enabled
    save(enabled, "quotaAlertsEnabled")
    guard enabled else { return }
    Task {
      notificationAuthorization = await quotaNotificationService.requestAuthorization()
      if notificationAuthorization == .authorized {
        evaluateQuotaAlerts()
      }
    }
  }

  func refreshNotificationAuthorization() async {
    notificationAuthorization = await quotaNotificationService.authorizationStatus()
  }

  func openSystemNotificationSettings() {
    quotaNotificationService.openSystemNotificationSettings()
  }

  func setProjectBudget(project: TokenProjectBucket, monthlyTokenLimit: Int) {
    guard monthlyTokenLimit > 0 else {
      budgetMessage = "预算必须大于 0 Token"
      return
    }
    let budget = ProjectBudget(
      projectName: project.projectName,
      projectPath: project.projectPath,
      monthlyTokenLimit: monthlyTokenLimit
    )
    do {
      projectBudgets = try projectBudgetStore.upsert(budget)
      budgetMessage = "已保存 \(project.projectName) 的月度预算"
      updateUsageAnalysis()
    } catch {
      budgetMessage = "预算保存失败：\(error.localizedDescription)"
    }
  }

  func removeProjectBudget(id: String) {
    do {
      projectBudgets = try projectBudgetStore.remove(id: id)
      budgetMessage = "已移除项目预算"
      updateUsageAnalysis()
    } catch {
      budgetMessage = "预算移除失败：\(error.localizedDescription)"
    }
  }

  func setLaunchWithCodexEnabled(_ enabled: Bool) {
    do {
      try CodexWatcherManager.setEnabled(enabled, appURL: Bundle.main.bundleURL)
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = enabled ? "已开启：打开 Codex 时自动启动 Codex 脉动" : "已关闭自动启动"
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = "设置失败：\(error.localizedDescription)"
    }
  }

  func cnyValue(for estimate: CostEstimate) -> Double? { exchangeRate.map { estimate.usd * $0.rate } }

  func copyUsageSummary() {
    let stats = tokenStats
    let weeklyText = weekly.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--"
    var lines = [
      "Codex 脉动 · \(Date().formatted(date: .abbreviated, time: .shortened))",
      "7天剩余额度：\(weeklyText)",
      "滚动24h：\(BalanceFormatters.compactNumber(stats.rolling24HoursTokens)) Token",
      "近7天：\(BalanceFormatters.compactNumber(stats.last7DaysTokens)) Token",
      "本月：\(BalanceFormatters.compactNumber(stats.monthTokens)) Token",
      "API等价预估：$\(String(format: "%.2f", stats.costMonth.usd))"
    ]
    if let top = stats.categoryBreakdown.max(by: { $0.totalTokens < $1.totalTokens }), top.totalTokens > 0 {
      lines.append("主要工作类型：\(top.category.label)（\(BalanceFormatters.compactNumber(top.totalTokens)) Token）")
    }
    if let probability = codexRadarSnapshot?.probability24hPercent {
      let level = codexRadarSnapshot?.prediction?.levelLabel ?? "研判中"
      lines.append("Codex 24h 重置概率：\(probability)%（\(level)）")
      lines.append(CodexRadarService.attributionText)
    }
    if let forecast = quotaForecast {
      if let rate = forecast.ratePerDay {
        lines.append("额度节奏：\(String(format: "%.1f", rate)) 个百分点/天")
      }
      if let exhaustion = forecast.estimatedExhaustion {
        lines.append("预计耗尽：\(exhaustion.formatted(date: .abbreviated, time: .shortened))")
      } else if let reason = forecast.reason {
        lines.append("额度预测：\(reason)")
      }
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    exportMessage = "用量摘要已复制"
  }

  func exportUsageCSV() {
    let panel = NSSavePanel()
    panel.title = "导出 Codex 用量"
    panel.prompt = "导出"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.commaSeparatedText]
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    panel.nameFieldStringValue = "codex-usage-\(formatter.string(from: Date())).csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let csv = CodexUsageCSVExporter.makeCSV(
      stats: tokenStats,
      cnyRate: exchangeRate?.rate,
      generatedAt: Date()
    )
    do {
      try csv.write(to: url, atomically: true, encoding: .utf8)
      exportMessage = "已导出：\(url.lastPathComponent)"
    } catch {
      exportMessage = "导出失败：\(error.localizedDescription)"
    }
  }

  private func scheduleFullRefreshIfNeeded(force: Bool = false) {
    guard !fullRefreshInFlight else { return }
    if !force, let lastFullRefresh, Date().timeIntervalSince(lastFullRefresh) < 300 { return }
    fullRefreshInFlight = true
    isFullRefreshing = true
    let reader = fullReader
    Task {
      do {
        let full = try await Task.detached(priority: .utility) { try reader.read() }.value
        if isWindowDragging {
          deferredFullStatus = full
        } else {
          applyFullStatus(full)
          isFullRefreshing = false
        }
      } catch {
        if isWindowDragging {
          deferredRefreshError = error.localizedDescription
        } else {
          if status == nil { errorMessage = error.localizedDescription }
          isFullRefreshing = false
        }
        dashboardLogger.error("Full refresh failed: \(error.localizedDescription, privacy: .public)")
      }
      fullRefreshInFlight = false
    }
  }

  private func runDeferredRefreshIfNeeded() {
    guard !isLoading, !isWindowDragging, refreshRequestedWhileBusy else { return }
    let forceFull = forceFullRefreshWhileBusy
    refreshRequestedWhileBusy = false
    forceFullRefreshWhileBusy = false
    refresh(forceFull: forceFull)
  }

  private func applyFastStatus(_ next: CodexStatus, forceFull: Bool) {
    status = mergeFastStatus(next, withExisting: status)
    lastRefresh = next.generatedAt
    errorMessage = nil
    updateQuotaForecast()
    updateUsageAnalysis()
    updateTouchBar()
    if reliabilityHealthChecksEnabled { runReliabilityCheck(allowAutomation: false) }
    scheduleFullRefreshIfNeeded(force: forceFull)
  }

  private func applyFullStatus(_ full: CodexStatus) {
    status = mergeFullStatus(full, withExisting: status)
    lastRefresh = full.generatedAt
    // Keep the exact cutoff used by rolling 24-hour calculations. Using the
    // later UI-apply time can move a large boundary event in or out of range.
    lastFullRefresh = full.generatedAt
    errorMessage = nil
    updateQuotaForecast()
    updateUsageAnalysis(now: full.generatedAt)
    updateTouchBar()
    if reliabilityHealthChecksEnabled { runReliabilityCheck(allowAutomation: false) }
    Task { await loadExchangeRate() }
  }

  private func loadExchangeRate() async {
    exchangeRate = await exchangeRateService.current()
    writeWidgetSnapshotFile()
  }

  private func updateUsageAnalysis(now: Date = Date()) {
    usageAnalysis = UsageAnalyzer.analyze(stats: tokenStats, budgets: projectBudgets, now: now)
  }

  private func updateQuotaForecast(now: Date = Date()) {
    let mainEvent = status?.main
    let window = mainEvent?.sevenDayWindow
    var history = quotaHistoryStore.snapshots()
    let current: QuotaSnapshot?
    if let mainEvent, let window, let reset = window.resetsAt,
       window.inferredReset == false,
       abs(window.windowMinutes - QuotaHistoryStore.expectedWindowMinutes) <= 60 {
      let incoming = QuotaSnapshot(
        recordedAt: mainEvent.timestamp,
        remainingPercent: window.remainingPercent,
        resetsAt: reset,
        windowMinutes: window.windowMinutes
      )
      history = quotaHistoryStore.record(window: window, at: mainEvent.timestamp, now: now)
      current = history
        .filter { abs($0.resetsAt.timeIntervalSince(reset)) <= 300 }
        .max(by: { $0.recordedAt < $1.recordedAt }) ?? incoming
    } else {
      current = nil
    }
    quotaForecast = QuotaForecaster.forecast(
      snapshots: history,
      current: current,
      now: now
    )
    evaluateQuotaAlerts(now: now)
  }

  private func evaluateQuotaAlerts(now: Date = Date()) {
    guard quotaAlertsEnabled, notificationAuthorization == .authorized else { return }
    let evaluation = QuotaAlertEvaluator.evaluate(
      remainingPercent: weekly?.remainingPercent,
      resetAt: weekly?.resetsAt,
      forecast: quotaForecast,
      resetCredits: rateLimitResetCredits?.availableCredits ?? [],
      thresholds: quotaAlertPreset.thresholds,
      thresholdAlertsEnabled: quotaThresholdAlertsEnabled,
      forecastAlertsEnabled: quotaForecastAlertsEnabled,
      resetCreditAlertsEnabled: quotaResetCreditAlertsEnabled,
      ledger: quotaAlertLedger,
      now: now
    )
    quotaAlertLedger = evaluation.ledger
    if let data = try? JSONEncoder().encode(quotaAlertLedger) {
      UserDefaults.standard.set(data, forKey: "quotaAlertLedger")
    }
    guard !evaluation.candidates.isEmpty else { return }
    let remaining = weekly?.remainingPercent
    let forecast = quotaForecast
    Task {
      for candidate in evaluation.candidates {
        await quotaNotificationService.deliver(candidate, remainingPercent: remaining, forecast: forecast)
      }
    }
  }

  private func mergeFastStatus(_ fast: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    var result = fast
    if result.rateLimitResetCredits == nil {
      result.rateLimitResetCredits = existing?.rateLimitResetCredits
    }
    guard var stats = existing?.tokenStats, fast.tokenStats.sampleCount == 0 else { return result }
    if let account = fast.tokenStats.accountUsage { stats.accountUsage = account }
    if !fast.tokenStats.deviceUsage.isEmpty { stats.deviceUsage = fast.tokenStats.deviceUsage }
    result.tokenStats = stats
    if result.main == nil { result.main = existing?.main }
    return result
  }

  private func mergeFullStatus(_ full: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    var mergedFull = full
    if mergedFull.rateLimitResetCredits == nil {
      mergedFull.rateLimitResetCredits = existing?.rateLimitResetCredits
    }
    guard let existing, existing.generatedAt > mergedFull.generatedAt, existing.main != nil else { return mergedFull }
    var result = existing
    result.rateLimitResetCredits = mergedFull.rateLimitResetCredits
    result.tokenStats = mergedFull.tokenStats
    result.scannedFiles = mergedFull.scannedFiles
    result.eventCount = mergedFull.eventCount
    result.recentEvents = mergedFull.recentEvents
    return result
  }

  private func updateTouchBar() {
    writeLiveBalanceFile()
    writeWidgetSnapshotFile()
    guard touchBarEnabled else { return }
    TouchBarStripController.shared.update(codex: .init(
      color24h: NSColor(palette.usage24h),
      color7d: NSColor(palette.weekly),
      percent7d: weekly?.remainingPercent,
      reset7d: weekly?.resetsAt,
      tokens24h: tokenStats.rolling24HoursTokens,
      cost24hUSD: tokenStats.cost24Hours.usd
    ))
    pushSessionsToTouchBar()
  }

  private func pushSessionsToTouchBar() {
    guard touchBarEnabled else { return }
    guard touchBarShowsSessions else { TouchBarStripController.shared.updateSessions([]); return }
    let limit = touchBarSessionCount
    Task.detached(priority: .utility) {
      let sessions = RecentSessionScanner.shared.recentSessions(limit: limit)
      await MainActor.run { TouchBarStripController.shared.updateSessions(sessions) }
    }
  }

  private func writeLiveBalanceFile() {
    let stats = tokenStats
    var codex: [String: Any] = [
      "rolling24h": stats.rolling24HoursTokens,
      "week": stats.last7DaysTokens,
      "month": stats.monthTokens,
      "cost24hUSD": stats.cost24Hours.usd
    ]
    if let p7 = weekly?.remainingPercent { codex["p7"] = p7 }
    if let r7 = weekly?.resetsAt { codex["r7"] = r7.timeIntervalSince1970 }
    codex["categories"] = stats.categoryBreakdown
      .filter { $0.totalTokens > 0 }
      .map {
        [
          "id": $0.category.rawValue,
          "label": $0.category.label,
          "tokens": $0.totalTokens,
          "calls": $0.calls
        ] as [String: Any]
      }
    codex["todayProjects"] = stats.todayTopProjects.map {
      ["name": $0.projectName, "tokens": $0.totalTokens, "calls": $0.calls] as [String: Any]
    }
    codex["monthProjects"] = stats.monthTopProjects.map {
      ["name": $0.projectName, "tokens": $0.totalTokens, "calls": $0.calls] as [String: Any]
    }
    var root: [String: Any] = ["updatedAt": Date().timeIntervalSince1970, "codex": codex]
    if let lastFullRefresh { root["statsUpdatedAt"] = lastFullRefresh.timeIntervalSince1970 }
    guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent("live-balance.json"), options: [.atomic])
  }

  private func writeWidgetSnapshotFile() {
    let stats = tokenStats
    let radar = codexRadarSnapshot
    let credits = rateLimitResetCredits
    let snapshot = CodexWidgetSnapshot(
      updatedAt: Date(),
      remainingPercent: weekly?.remainingPercent,
      usedPercent: weekly?.usedPercent,
      resetsAt: weekly?.resetsAt,
      fiveHourRemainingPercent: fiveHour?.remainingPercent,
      fiveHourUsedPercent: fiveHour?.usedPercent,
      fiveHourResetsAt: fiveHour?.resetsAt,
      showsFiveHourQuota: widgetShowsFiveHourQuota,
      rolling24HoursTokens: stats.rolling24HoursTokens,
      todayTokens: stats.todayTokens,
      last7DaysTokens: stats.last7DaysTokens,
      monthTokens: stats.monthTokens,
      cost24HoursUSD: stats.cost24Hours.usd,
      cost7DaysUSD: stats.cost7Days.usd,
      costMonthUSD: stats.costMonth.usd,
      cnyRate: exchangeRate?.rate,
      resetProbability24h: radar?.probability24hPercent,
      radarLevel: radar?.latestLevelLabel,
      radarSummary: radar?.latestSummary,
      radarUpdatedAt: radar?.latestUpdate,
      resetCreditsAvailable: credits?.availableCount,
      resetCredits: credits?.availableCredits.prefix(3).map {
        CodexWidgetResetCredit(title: $0.title, expiresAt: $0.expiresAt)
      } ?? [],
      sampleCount: stats.sampleCount,
      deviceCount: stats.deviceUsage.count,
      hourly24: stats.hourly.suffix(24).map {
        CodexWidgetPoint(label: $0.label, tokens: $0.totalTokens)
      },
      daily14: stats.daily.suffix(14).map {
        CodexWidgetPoint(label: $0.label, tokens: $0.totalTokens)
      },
      topProjects: stats.todayTopProjects.prefix(3).map {
        CodexWidgetMetric(label: $0.projectName, tokens: $0.totalTokens)
      },
      topCategories: stats.categoryBreakdown
        .filter { $0.totalTokens > 0 }
        .sorted { $0.totalTokens > $1.totalTokens }
        .prefix(3)
        .map { CodexWidgetMetric(label: $0.category.label, tokens: $0.totalTokens) }
    )

    do {
      try CodexWidgetSnapshotStore.save(snapshot)
    } catch {
      dashboardLogger.error("Legacy widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
    }

    let widgetSnapshotURL = CodexWidgetSnapshotStore.widgetContainerURL()
    let previousWidgetSnapshot = try? CodexWidgetSnapshotStore.load(from: widgetSnapshotURL)
    do {
      try CodexWidgetSnapshotStore.save(
        snapshot,
        to: widgetSnapshotURL
      )
      let now = Date()
      let contentChanged = previousWidgetSnapshot.map { !$0.hasSameWidgetContent(as: snapshot) } ?? true
      requestWidgetReload(needsReload: contentChanged || lastWidgetReloadAt == nil, now: now)
    } catch {
      dashboardLogger.error("Widget container snapshot write failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func requestWidgetReload(needsReload: Bool, now: Date) {
    let decision = widgetReloadPolicy.decision(
      needsReload: needsReload,
      lastReloadAt: lastWidgetReloadAt,
      hasPendingReload: pendingWidgetReloadTask != nil,
      now: now
    )

    switch decision {
    case .none:
      return
    case .reloadNow:
      pendingWidgetReloadTask?.cancel()
      pendingWidgetReloadTask = nil
      reloadAllWidgetTimelines(at: now)
    case .schedule(let delay):
      pendingWidgetReloadTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self else { return }
        self.pendingWidgetReloadTask = nil
        self.reloadAllWidgetTimelines(at: Date())
      }
    }
  }

  private func reloadAllWidgetTimelines(at date: Date) {
    WidgetCenter.shared.reloadAllTimelines()
    lastWidgetReloadAt = date
  }

  private func restartReliabilityAutomation() {
    reliabilityTimer?.invalidate()
    reliabilityTimer = nil
    DispatchQueue.main.async { [weak self] in self?.startReliabilityAutomation() }
  }

  private func restartAppUpdateChecks() {
    appUpdateTimer?.invalidate()
    appUpdateTimer = nil
    guard automaticUpdateChecksEnabled else {
      appUpdateStatusMessage = lastAppUpdateCheckAt == nil
        ? "自动版本检查已关闭"
        : "自动版本检查已关闭 · 可手动检查"
      return
    }
    DispatchQueue.main.async { [weak self] in self?.startAppUpdateChecks() }
  }

  private func restoreCachedAppUpdate(defaults: UserDefaults) {
    guard let data = defaults.data(forKey: "cachedAppRelease"),
          let release = try? JSONDecoder().decode(AppRelease.self, from: data),
          let currentVersion = SemanticVersion(AppInfo.version),
          let checkedAt = defaults.object(forKey: "lastAppUpdateCheckAt") as? Date,
          let result = try? GitHubReleaseUpdateService.evaluate(
            release: release,
            currentVersion: currentVersion,
            checkedAt: checkedAt
          )
    else { return }
    applyAppUpdateResult(result, persist: false)
  }

  private func applyAppUpdateResult(_ result: AppUpdateResult, persist: Bool = true) {
    latestAppRelease = result.release
    appUpdateAvailability = result.availability
    lastAppUpdateCheckAt = result.checkedAt
    let remote = result.release.version.map { "v\($0)" } ?? result.release.tagName
    switch result.availability {
    case .updateAvailable:
      appUpdateStatusMessage = "发现新版本 \(remote)"
    case .upToDate:
      appUpdateStatusMessage = "当前已是最新版本 \(remote)"
    case .localVersionNewer:
      appUpdateStatusMessage = "当前 v\(AppInfo.version) 高于线上最新 \(remote)"
    }
    guard persist else { return }
    let defaults = UserDefaults.standard
    if let data = try? JSONEncoder().encode(result.release) {
      defaults.set(data, forKey: "cachedAppRelease")
    }
    defaults.set(result.checkedAt, forKey: "lastAppUpdateCheckAt")
  }

  private func attemptAutomaticRecovery(snapshot: ReliabilitySnapshot, now: Date) {
    let recoverable = snapshot.checks.filter {
      $0.level == .critical && [.officialQuota, .tokenAggregation, .radar, .widgetSnapshot].contains($0.id)
    }
    guard !recoverable.isEmpty else {
      if automaticRecoveryAttempts != 0 {
        automaticRecoveryAttempts = 0
        save(0, "automaticRecoveryAttempts")
      }
      return
    }
    guard automaticRecoveryAttempts < 2 else {
      reliabilityMessage = "自动恢复已达到本轮上限，等待下一次有效刷新"
      return
    }
    if let lastAutomaticRecoveryAt, now.timeIntervalSince(lastAutomaticRecoveryAt) < 15 * 60 { return }

    lastAutomaticRecoveryAt = now
    automaticRecoveryAttempts += 1
    save(now, "lastAutomaticRecoveryAt")
    save(automaticRecoveryAttempts, "automaticRecoveryAttempts")

    let ids = Set(recoverable.map(\.id))
    if ids.contains(.officialQuota) || ids.contains(.tokenAggregation) {
      refresh(forceFull: true)
    }
    if ids.contains(.radar) {
      refreshCodexRadar(force: true)
    }
    if ids.contains(.widgetSnapshot) {
      writeWidgetSnapshotFile()
    }
    appendReliabilityEvent(.init(
      timestamp: now,
      kind: .recovery,
      title: "已触发受控自动恢复",
      detail: "重新读取额度、汇总或刷新快照；第 \(automaticRecoveryAttempts)/2 次"
    ))
    reliabilityMessage = "已触发受控自动恢复"
  }

  private func archiveDailySummary(now: Date) {
    let markdown = ReliabilityReportBuilder.dailySummaryMarkdown(
      remainingPercent: weekly?.remainingPercent,
      rolling24hTokens: tokenStats.rolling24HoursTokens,
      monthTokens: tokenStats.monthTokens,
      projectedMonthTokens: usageAnalysis.projectedMonthTokens,
      quotaRisk: quotaForecast?.risk.rawValue ?? "insufficientData",
      health: reliabilitySnapshot.overall,
      generatedAt: now
    )
    do {
      _ = try localAutomationArchive.archiveDailySummary(markdown, now: now)
      appendReliabilityEvent(.init(timestamp: now, kind: .info, title: "每日摘要已归档", detail: "已保存本机聚合指标"))
      reliabilityMessage = "今日自动摘要已归档"
    } catch {
      appendReliabilityEvent(.init(timestamp: now, kind: .failure, title: "每日摘要归档失败", detail: "本地文件未写入"))
      reliabilityMessage = "每日摘要归档失败：\(error.localizedDescription)"
    }
  }

  private func appendReliabilityEvent(_ event: ReliabilityEvent) {
    do {
      reliabilityEvents = try reliabilityEventStore.append(event)
    } catch {
      dashboardLogger.error("Reliability event write failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func reliabilityLevelLabel(_ level: ReliabilityHealthLevel) -> String {
    switch level {
    case .healthy: "健康"
    case .warning: "需关注"
    case .critical: "异常"
    case .unknown: "学习中"
    }
  }

  private func restartAutoRefreshIfNeeded() { if refreshTimer != nil { stopAutoRefresh(); startAutoRefresh() } }
  private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

  private func installCodexRadarLifecycleObservers() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.startAutoRefresh()
        self?.refreshCodexRadar()
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.startAutoRefresh()
        self?.refreshCodexRadar()
      }
    }
  }

  private func repairLaunchWatcherIfNeeded(showMessage: Bool) {
    do {
      try CodexWatcherManager.refreshIfEnabled(appURL: Bundle.main.bundleURL)
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      if showMessage, launchWithCodexEnabled { settingsMessage = "自动启动已指向当前 Codex 脉动" }
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = "自动启动修复失败：\(error.localizedDescription)"
    }
  }

  private func applyWindowVisibility() {
    guard let window = NSApp.windows.first(where: { $0.title == AppInfo.appName }) else { return }
    guard isWindowVisible else {
      window.alphaValue = 1
      window.ignoresMouseEvents = false
      window.orderOut(nil)
      return
    }
    let hide = touchBarEnabled && isCompact && !clamshellActive
    window.alphaValue = hide ? 0 : 1
    window.ignoresMouseEvents = hide
    if !hide { window.makeKeyAndOrderFront(nil) }
  }

  private func updateClamshellState(initial: Bool) {
    let builtIn = NSScreen.screens.contains { screen in
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
      return CGDisplayIsBuiltin(id) != 0
    }
    let next = !NSScreen.screens.isEmpty && !builtIn
    guard next != clamshellActive || initial else { return }
    clamshellActive = next
    applyWindowVisibility()
  }

  private func relaunchApp() {
    let url = Bundle.main.bundleURL
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: url, configuration: configuration)
      NSApp.terminate(nil)
    }
  }
}
