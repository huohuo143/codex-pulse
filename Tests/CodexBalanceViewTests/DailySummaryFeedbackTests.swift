import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Daily summary background feedback", .serialized)
struct DailySummaryFeedbackTests {
  @Test func backgroundArchiveKeepsInterfaceAvailableAndCoalescesRequests() async throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    let files = PausedSummaryFileManager()
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: files)
    let store = f.dashboard()
    let task = Task { await store.archiveDailySummary(archive: archive) }
    defer { files.release.signal() }
    for _ in 0..<100 {
      if files.callCount > 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.isArchivingDailySummary)
    #expect(!files.ranOnMainThread)
    await store.archiveDailySummary(archive: archive)
    #expect(files.callCount == 1)
    files.release.signal(); await task.value
    #expect(!store.isArchivingDailySummary)
    #expect(store.dailySummaryHealth == .verified)
    #expect(store.dailySummaryMessage?.contains("已生成并验证") == true)
    #expect(archive.hasDailySummary(for: Date()))
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .dailySummary }?.level == .healthy)
  }

  @Test func unsafeTargetFailureIsVisibleInDiagnosticsAndCanRetry() async throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    let original = Data("private unrelated report sentinel".utf8)
    let sentinel = f.root.appendingPathComponent("external.md"); try original.write(to: sentinel)
    try FileManager.default.createDirectory(at: f.target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: f.target, withDestinationURL: sentinel)
    let store = f.dashboard()
    await store.archiveDailySummary(archive: f.archive)
    #expect(store.dailySummaryHealth == .failed)
    #expect(store.dailySummaryMessage?.contains("无法安全访问") == true)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .dailySummary }?.level == .warning)
    #expect(try Data(contentsOf: sentinel) == original)
    let report = ReliabilityReportBuilder.diagnosticMarkdown(appVersion: "test",
      snapshot: store.reliabilitySnapshot, recentEvents: store.reliabilityEvents)
    #expect(report.contains("每日聚合摘要"))
    #expect(report.contains("最近一次摘要归档未完成"))
    #expect(!report.contains(f.root.path) && !report.contains("private unrelated"))
    try FileManager.default.removeItem(at: f.target)
    await store.archiveDailySummary(archive: f.archive)
    #expect(store.dailySummaryHealth == .verified)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .dailySummary }?.level == .healthy)
  }

  @Test func incompleteSummaryIsKeptWhenCopyFailsAndRecoveredOnRetry() async throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    try FileManager.default.createDirectory(at: f.target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("incomplete source report".utf8); try original.write(to: f.target)
    let files = SummaryCopyFailureFileManager(); files.failCopies = true
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: files)
    let store = f.dashboard()
    await store.archiveDailySummary(archive: archive)
    #expect(store.dailySummaryHealth == .failed)
    #expect(store.dailySummaryMessage?.contains("未能验证保存原摘要副本") == true)
    #expect(try Data(contentsOf: f.target) == original)
    files.failCopies = false
    await store.archiveDailySummary(archive: archive)
    #expect(store.dailySummaryMessage?.contains("已保留不完整摘要原件") == true)
    let copies = try FileManager.default.contentsOfDirectory(at: f.target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.contains("incomplete-") }
    #expect(copies.count == 1)
    #expect(try Data(contentsOf: #require(copies.first)) == original)
    #expect(archive.hasDailySummary(for: Date()))
  }

  @Test func validSameDaySummaryIsCheckedWithoutAnotherWriteOrEvent() async throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard()
    await store.archiveDailySummary(archive: f.archive)
    let bytes = try Data(contentsOf: f.target)
    let events = store.reliabilityEvents.filter { $0.title == "每日摘要已归档" }.map(\.id)
    store.dailySummaryHealth = .failed
    await store.archiveDailySummary(archive: f.archive)
    #expect(store.dailySummaryHealth == .verified)
    #expect(store.dailySummaryMessage?.contains("保持原样") == true)
    #expect(try Data(contentsOf: f.target) == bytes)
    #expect(store.reliabilityEvents.filter { $0.title == "每日摘要已归档" }.map(\.id) == events)
  }

  @Test func scheduledSummaryWaitsForBothQuotaAndUsageAndHonorsTime() async throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard(ready: false)
    store.reliabilityDailySummaryEnabled = true
    store.reliabilityDailySummaryHour = 0
    defer { store.reliabilityDailySummaryEnabled = false; store.reliabilityTimer?.invalidate() }
    #expect(!store.canRunAutomaticDailySummary(at: Date()))
    await store.archiveDailySummary(archive: f.archive)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    #expect(store.dailySummaryMessage?.contains("等待读取") == true || store.dailySummaryMessage?.contains("等待本次启动") == true)
    f.prepareQuota(store)
    #expect(!store.canRunAutomaticDailySummary(at: Date()))
    store.lastFullRefresh = Date()
    #expect(store.canRunAutomaticDailySummary(at: Date()))
    store.reliabilityDailySummaryHour = 12
    let early = try #require(Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date()))
    let late = try #require(Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date()))
    #expect(!store.canRunAutomaticDailySummary(at: early))
    #expect(store.canRunAutomaticDailySummary(at: late))
    store.isArchivingDailySummary = true
    #expect(!store.canRunAutomaticDailySummary(at: late))
    store.isArchivingDailySummary = false
    store.status?.accountScope = nil
    #expect(!store.canRunAutomaticDailySummary(at: late))
  }

  @Test func previousDayResultDoesNotMasqueradeAsTodaysSummary() throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard()
    store.dailySummaryHealth = .verified
    store.dailySummaryMessage = "yesterday was checked"
    store.lastDailySummaryAttempt = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.dailySummaryHealth == .notChecked)
    #expect(store.dailySummaryMessage == nil)
    #expect(store.lastDailySummaryAttempt == nil)
    #expect(!store.reliabilitySnapshot.checks.contains { $0.id == .dailySummary })
  }

  @Test func summaryProjectionUsesCapturedUsageInsteadOfPendingAnalysis() async throws {
    let f = try SummaryFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard()
    let now = Date()
    store.status?.tokenStats = .init(rolling24HoursTokens: 1234, monthTokens: 5678, sampleCount: 1)
    store.usageAnalysis.projectedMonthTokens = 999_999
    let expected = UsageAnalyzer.analyze(stats: store.tokenStats, budgets: [], now: now).projectedMonthTokens
    #expect(expected != 999_999)
    await store.archiveDailySummary(now: now, archive: f.archive)
    let markdown = try String(contentsOf: f.target, encoding: .utf8)
    #expect(markdown.contains("- 滚动 24h Token：1234"))
    #expect(markdown.contains("- 本月 Token：5678"))
    #expect(markdown.contains("- 月末预计 Token：\(expected)"))
    #expect(!markdown.contains("999999"))
    #expect(!markdown.contains("/private/fixture"))
  }
}

private struct SummaryFeedbackFixture {
  let root: URL
  private let preferenceKeys = ["reliabilityHealthChecksEnabled", "reliabilityBackupsEnabled", "reliabilityDailySummaryEnabled", "reliabilityDailySummaryHour"]
  private let savedPreferences: [String: Any]
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    savedPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
      PulsePreferences.shared.object(forKey: key).map { (key, $0) }
    })
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var archiveRoot: URL { root.appendingPathComponent("archive") }
  var archive: LocalAutomationArchive { .init(root: archiveRoot) }
  var target: URL {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    return archiveRoot.appendingPathComponent("daily-reports/codex-daily-summary-\(formatter.string(from: Date())).md")
  }
  @MainActor func prepareQuota(_ store: DashboardStore) {
    let now = Date()
    let window = LimitWindow(usedPercent: 20, remainingPercent: 80, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
    let event = RateLimitEvent(timestamp: now, sourceName: "fixture", sourcePath: "/private/fixture", limitID: "codex",
      limitName: "Codex", secondary: window)
    var status = CodexStatus(codexHome: "/private/fixture", sessionsRoot: "/private/fixture", main: event)
    status.accountScope = "isolated-summary-account"
    status.quotaRead = .init(sampledAt: now, lastAttemptAt: now, lastSuccessAt: now)
    store.status = status
  }
  @MainActor func dashboard(ready: Bool = true) -> DashboardStore {
    let store = DashboardStore(startServices: false,
      expiryStore: .init(url: root.appendingPathComponent("credit.json"), legacyURL: root.appendingPathComponent("legacy.json")),
      budgetStore: .init(url: root.appendingPathComponent("budgets.json")),
      eventStore: .init(url: root.appendingPathComponent("events.json")))
    store.quotaHistoryStore = .init(url: root.appendingPathComponent("quota.json"))
    store.reliabilityHealthChecksEnabled = false; store.reliabilityBackupsEnabled = false; store.reliabilityDailySummaryEnabled = false
    if ready { prepareQuota(store); store.lastFullRefresh = Date() }
    return store
  }
  func clean() {
    for key in preferenceKeys {
      if let value = savedPreferences[key] { PulsePreferences.shared.set(value, forKey: key) }
      else { PulsePreferences.shared.removeObject(forKey: key) }
    }
    try? FileManager.default.removeItem(at: root)
  }
}

private final class PausedSummaryFileManager: FileManager, @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0
  private var main = false
  var callCount: Int { lock.withLock { count } }
  var ranOnMainThread: Bool { lock.withLock { main } }
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    lock.withLock { count += 1; main = Thread.isMainThread }
    guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}

private final class SummaryCopyFailureFileManager: FileManager, @unchecked Sendable {
  var failCopies = false
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    if failCopies { throw CocoaError(.fileWriteNoPermission) }
    try super.copyItem(at: srcURL, to: dstURL)
  }
}
