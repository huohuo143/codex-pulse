import AppKit
import CodexBalanceCore
import Foundation
import Network
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

let dashboardLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "dev.codex.balance-dashboard.codex",
  category: "DashboardStore"
)

@MainActor
final class DashboardStore: ObservableObject {
  @Published var status: CodexStatus?
  @Published var exchangeRate: ExchangeRateSnapshot?
  @Published var lastRefresh: Date?
  @Published var errorMessage: String?
  @Published var isLoading = false
  @Published var isFullRefreshing = false
  @Published var lastFullRefresh: Date?
  @Published var exportMessage: String?
  @Published var radarEvaluation = RadarEvaluationSummary()
  @Published var radarEvaluationMessage: String?
  @Published var creditExpiry = CreditExpiryStore().load()
  @Published var expiryMessage: String?
  @Published var pricingMessage = ModelPricingStore.shared.snapshot().description
  @Published var launchWithCodexEnabled = CodexWatcherManager.isEnabled()
  @Published var settingsMessage: String?
  @Published var clamshellActive = false
  @Published var codexRadarSnapshot: CodexRadarSnapshot?
  @Published var codexRadarIsLoading = false
  @Published var codexRadarStatusMessage = "正在连接 Codex Radar 公开只读源…"
  @Published var codexRadarLastSyncAt: Date?
  @Published var codexRadarNextSyncAt: Date?
  @Published var quotaForecast: QuotaForecast?
  @Published var usageAnalysis = UsageAnalysis()
  @Published var projectBudgets: [ProjectBudget] = []
  @Published var budgetMessage: String?
  @Published var reliabilitySnapshot = ReliabilitySnapshot()
  @Published var reliabilityEvents: [ReliabilityEvent] = []
  @Published var reliabilityMessage: String?
  @Published var latestAppRelease: AppRelease?
  @Published var appUpdateAvailability: AppUpdateAvailability?
  @Published var appUpdateIsChecking = false
  @Published var appUpdateStatusMessage = "尚未检查版本更新"
  @Published var lastAppUpdateCheckAt: Date?
  @Published var quotaAlertsEnabled: Bool
  @Published var notificationAuthorization: QuotaNotificationAuthorization = .notDetermined
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
  @Published var isWindowVisible: Bool {
    didSet { applyWindowVisibility() }
  }
  @Published var selectedSection: DashboardSection = .overview
  @Published var floatingPanelMetrics: Set<FloatingPanelMetric> {
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
      if appLanguage == .system { PulsePreferences.shared.removeObject(forKey: "AppleLanguages") }
      else { PulsePreferences.shared.set([appLanguage.rawValue], forKey: "AppleLanguages") }
      relaunchApp()
    }
  }

  var enabledToolCount: Int { 1 }
  var touchBarSupported: Bool { TouchBarStripController.shared.isSupported }
  var compactShowsResetCredits: Bool { floatingPanelMetrics.contains(.resetCredits) }
  var overviewShowsFiveHourQuota: Bool {
    FloatingPanelMetric.showsFiveHourQuota(in: floatingPanelMetrics)
  }
  var quotaState: DataFreshnessState { status?.quotaRead?.state(at: Date(), resetAt: status?.main?.sevenDayWindow?.resetsAt) ?? .unavailable }
  var quotaStatusLabel: String { quotaState.label }
  var weekly: LimitWindow? { quotaState.canDisplayValue ? status?.main?.sevenDayWindow : nil }
  var fiveHour: LimitWindow? {
    let state = status?.quotaRead?.state(at: Date(), resetAt: status?.main?.fiveHourWindow?.resetsAt) ?? .unavailable
    return state.canDisplayValue ? status?.main?.fiveHourWindow : nil
  }
  var rateLimitResetCredits: RateLimitResetCreditsSummary? {
    status?.resetCreditsRead?.state(at: Date()).canDisplayValue == true ? status?.rateLimitResetCredits?.effective(at: Date()) : nil
  }
  var flexibleCreditBalance: CodexFlexibleCreditBalance? {
    status?.flexibleCreditRead?.state(at: Date()).canDisplayValue == true ? status?.flexibleCreditBalance : nil
  }
  var hasUsageData: Bool { lastFullRefresh != nil }
  var tokenStats: TokenStats { status?.tokenStats ?? TokenStats() }
  var cnyAvailable: Bool { exchangeRate != nil }
  var menuBarTitle: String { weekly.map { "7天 \(Int($0.remainingPercent.rounded()))%" + (quotaState == .cached ? " · 缓存" : "") } ?? "7天 --" }
  var appUpdateAvailable: Bool { appUpdateAvailability == .updateAvailable }
  var latestAppReleaseVersionText: String? { latestAppRelease?.version.map { "v\($0)" } }

  let fastReader = CodexStatusReader()
  let fullReader = CodexStatusReader()
  let exchangeRateService: ExchangeRateService
  let codexRadarService: CodexRadarService
  let radarEvaluationArchive = RadarEvaluationArchive()
  var quotaHistoryStore = QuotaHistoryStore()
  let creditExpiryStore = CreditExpiryStore()
  var analysisGeneration = 0
  var forecastGeneration = 0
  var lastAnalysisStats: TokenStats?
  var lastForecastEvent: RateLimitEvent?
  var lastForecastState: DataFreshnessState?
  var lastForecastAt: Date?
  var lastSessionActivity: Date?
  let pollingStartedAt = Date()
  var lastAutomaticPollAt: Date?
  var lastHeartbeatAt: Date?
  var previousAutomaticTick: Date?
  let snapshotPublisher = WidgetSnapshotPublisher()
  var pendingSnapshotTask: Task<Void, Never>?
  let projectBudgetStore = ProjectBudgetStore()
  let reliabilityEventStore = ReliabilityEventStore()
  let localAutomationArchive = LocalAutomationArchive()
  let appUpdateService = GitHubReleaseUpdateService()
  lazy var quotaNotificationService = QuotaNotificationService.shared
  let servicesEnabled: Bool
  var quotaAlertLedger: QuotaAlertLedger
  var refreshTimer: Timer?
  var codexRadarRefreshTimer: Timer?
  var codexRadarEvaluationTimer: Timer?
  var codexRadarRetryTask: Task<Void, Never>?
  var codexRadarRefreshGate = CodexRadarRefreshGate()
  var codexRadarNetworkMonitor: NWPathMonitor?
  var codexRadarNetworkRecoveryGate = CodexRadarNetworkRecoveryGate()
  var reliabilityTimer: Timer?
  var appUpdateTimer: Timer?
  var fullRefreshInFlight = false
  var isWindowDragging = false
  var refreshRequestedAfterDrag = false
  var forceFullRefreshAfterDrag = false
  var deferredFastStatus: (status: CodexStatus, forceFull: Bool)?
  var deferredFullStatus: CodexStatus?
  var deferredRefreshError: String?
  var refreshRequestedWhileBusy = false
  var forceFullRefreshWhileBusy = false
  var pendingWidgetKinds = Set<CodexWidgetKind>()
  var lastWidgetReloadAt: Date?
  var pendingWidgetReloadTask: Task<Void, Never>?
  let widgetReloadPolicy = CodexWidgetReloadPolicy(minimumInterval: 60)
  var lastReliabilityLevel: ReliabilityHealthLevel?
  var lastAutomaticRecoveryAt: Date?
  var automaticRecoveryAttempts = 0

  init(startServices: Bool = true, radarService: CodexRadarService = CodexRadarService()) {
    codexRadarService = radarService
    servicesEnabled = startServices
    let defaults = PulsePreferences.shared
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
    refreshIntervalOption = savedRefreshInterval ?? .recommended
    let languages = defaults.array(forKey: "AppleLanguages") as? [String]
    appLanguage = languages?.first.flatMap(AppLanguage.init) ?? .system

    let cacheURL = PulsePaths.support.appendingPathComponent("exchange-rate-usd-cny.json")
    exchangeRateService = ExchangeRateService(cacheURL: cacheURL)
    projectBudgets = projectBudgetStore.load()
    reliabilityEvents = reliabilityEventStore.load()
    restoreCachedAppUpdate(defaults: defaults)
    guard startServices else { return }
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
    installCodexRadarNetworkMonitor()
    if refreshTimer == nil {
      recordRuntimeEvent("started")
      refresh()
      refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.automaticTick() }
      }
    }
    if codexRadarRefreshTimer == nil {
      let timer = Timer(
        timeInterval: CodexRadarService.refreshInterval,
        repeats: true
      ) { [weak self] _ in
        Task { @MainActor in
          self?.recordRuntimeEvent("radar-auto-cycle")
          self?.codexRadarNextSyncAt = Date().addingTimeInterval(CodexRadarService.refreshInterval)
          self?.refreshCodexRadar(force: true)
        }
      }
      timer.tolerance = 2
      RunLoop.main.add(timer, forMode: .common)
      codexRadarRefreshTimer = timer
      codexRadarNextSyncAt = timer.fireDate
    }
    if codexRadarEvaluationTimer == nil {
      let timer = Timer(
        timeInterval: CodexRadarService.localEvaluationInterval,
        repeats: true
      ) { [weak self] _ in
        Task { @MainActor in self?.reevaluateCodexRadar() }
      }
      timer.tolerance = 10
      RunLoop.main.add(timer, forMode: .common)
      codexRadarEvaluationTimer = timer
    }
  }

  func automaticTick(now: Date = Date()) {
    recordRuntimeEvent("tick", lag: max(0, now.timeIntervalSince(previousAutomaticTick ?? now) - 5))
    previousAutomaticTick = now
    let interval = QuotaPollingPolicy.interval(selected: refreshIntervalOption.seconds,
      windowVisible: isWindowVisible && NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }), lastActivity: lastSessionActivity, startedAt: pollingStartedAt, now: now)
    if lastAutomaticPollAt.map({ now.timeIntervalSince($0) >= interval }) ?? true {
      lastAutomaticPollAt = now
      refresh()
    }
    // The indexed worker is cheap when idle. It also detects resumed sessions independently of quota polling.
    scheduleFullRefreshIfNeeded()
    if lastHeartbeatAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
      lastHeartbeatAt = now
      objectWillChange.send()
      updateQuotaForecast(now: now)
      updateTouchBar()
    }
  }

  func stopAutoRefresh() {
    codexRadarNetworkMonitor?.cancel()
    codexRadarNetworkMonitor = nil
    codexRadarNetworkRecoveryGate = CodexRadarNetworkRecoveryGate()
    refreshTimer?.invalidate()
    refreshTimer = nil
    codexRadarRefreshTimer?.invalidate()
    codexRadarRefreshTimer = nil
    codexRadarEvaluationTimer?.invalidate()
    codexRadarEvaluationTimer = nil
    codexRadarRetryTask?.cancel()
    codexRadarRetryTask = nil
    codexRadarNextSyncAt = nil
  }

  func refreshAll() {
    refresh(forceFull: true)
    refreshCodexRadar(force: true)
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
        let next = try await Task.detached(priority: .userInitiated) { try reader.readFast(forceOfficial: forceFull) }.value
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
    guard servicesEnabled else { return }
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
      lastAnalysisStats = nil
      updateUsageAnalysis()
    } catch {
      budgetMessage = "预算保存失败：\(error.localizedDescription)"
    }
  }

  func removeProjectBudget(id: String) {
    do {
      projectBudgets = try projectBudgetStore.remove(id: id)
      budgetMessage = "已移除项目预算"
      lastAnalysisStats = nil
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

  func cnyValue(for estimate: CostEstimate) -> Double? { estimate.hasEstimate ? exchangeRate.map { estimate.usd * $0.rate } : nil }

  func scheduleFullRefreshIfNeeded(force: Bool = false) {
    guard !fullRefreshInFlight else { return }
    if !force, let lastFullRefresh, Date().timeIntervalSince(lastFullRefresh) < 10 { return }
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

  func runDeferredRefreshIfNeeded() {
    guard !isLoading, !isWindowDragging, refreshRequestedWhileBusy else { return }
    let forceFull = forceFullRefreshWhileBusy
    refreshRequestedWhileBusy = false
    forceFullRefreshWhileBusy = false
    refresh(forceFull: forceFull)
  }

  func applyFastStatus(_ next: CodexStatus, forceFull: Bool) {
    prepareAccount(next.accountScope)
    status = mergeFastStatus(next, withExisting: status)
    lastRefresh = next.generatedAt
    errorMessage = nil
    updateQuotaForecast()
    updateTouchBar()
    if reliabilityHealthChecksEnabled { runReliabilityCheck(allowAutomation: false) }
    scheduleFullRefreshIfNeeded(force: forceFull)
  }

  func applyFullStatus(_ full: CodexStatus) {
    if let status, full.accountScope != status.accountScope, full.generatedAt < status.generatedAt { return }
    prepareAccount(full.accountScope)
    let previousActivity = lastSessionActivity
    lastSessionActivity = full.lastSessionActivity
    status = mergeFullStatus(full, withExisting: status)
    if let lastSessionActivity, lastSessionActivity > (previousActivity ?? pollingStartedAt),
       Date().timeIntervalSince(lastSessionActivity) < 300 { refresh() }
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

  func loadExchangeRate() async {
    exchangeRate = await exchangeRateService.current()
    writeWidgetSnapshotFile()
  }

  func mergeFastStatus(_ fast: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    let sameAccount = fast.accountScope == existing?.accountScope
    let previousStats = existing?.tokenStats
    let existing = sameAccount ? existing : nil
    var result = DashboardStatusMergePolicy.mergeQuota(from: fast, with: existing)
    if result.rateLimitResetCredits == nil {
      result.rateLimitResetCredits = existing?.rateLimitResetCredits
    }
    if result.flexibleCreditBalance == nil {
      result.flexibleCreditBalance = existing?.flexibleCreditBalance
    }
    guard var stats = previousStats, fast.tokenStats.sampleCount == 0 else { return result }
    if !sameAccount { stats.accountUsage = nil }
    if let account = fast.tokenStats.accountUsage { stats.accountUsage = account }
    if !fast.tokenStats.deviceUsage.isEmpty { stats.deviceUsage = fast.tokenStats.deviceUsage }
    result.tokenStats = stats
    result.usageValidUntil = existing?.usageValidUntil
    result.lastSessionActivity = existing?.lastSessionActivity
    result.readerDiagnostics = existing?.readerDiagnostics
    if result.main == nil { result.main = existing?.main }
    return result
  }

  func mergeFullStatus(_ full: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    let existing = full.accountScope == existing?.accountScope ? existing : nil
    var mergedFull = DashboardStatusMergePolicy.mergeQuota(from: full, with: existing)
    if mergedFull.rateLimitResetCredits == nil {
      mergedFull.rateLimitResetCredits = existing?.rateLimitResetCredits
    }
    if mergedFull.flexibleCreditBalance == nil {
      mergedFull.flexibleCreditBalance = existing?.flexibleCreditBalance
    }
    return mergedFull
  }

  func restartAutoRefreshIfNeeded() { if refreshTimer != nil { lastAutomaticPollAt = nil; refresh() } }
  func save(_ value: Any, _ key: String) { PulsePreferences.shared.set(value, forKey: key) }

  func repairLaunchWatcherIfNeeded(showMessage: Bool) {
    guard !PulsePreferences.isIsolated else { return }
    do {
      try CodexWatcherManager.refreshIfEnabled(appURL: Bundle.main.bundleURL)
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      if showMessage, launchWithCodexEnabled { settingsMessage = "自动启动已指向当前 Codex 脉动" }
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = "自动启动修复失败：\(error.localizedDescription)"
    }
  }

  func applyWindowVisibility() {
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

  func updateClamshellState(initial: Bool) {
    let builtIn = NSScreen.screens.contains { screen in
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
      return CGDisplayIsBuiltin(id) != 0
    }
    let next = !NSScreen.screens.isEmpty && !builtIn
    guard next != clamshellActive || initial else { return }
    clamshellActive = next
    applyWindowVisibility()
  }

  func relaunchApp() {
    let url = Bundle.main.bundleURL
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: url, configuration: configuration)
      NSApp.terminate(nil)
    }
  }
}
