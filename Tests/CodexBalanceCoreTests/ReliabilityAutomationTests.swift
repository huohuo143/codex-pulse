import Foundation
import Testing
@testable import CodexBalanceCore

@Suite
struct ReliabilityAutomationTests {
  @Test
  func auditorReportsHealthyFreshDataAndValidFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let history = root.appendingPathComponent("history.json")
    let budgets = root.appendingPathComponent("budgets.json")
    let widget = root.appendingPathComponent("widget.json")
    try Data("{\"schemaVersion\":1}".utf8).write(to: history)
    try Data("{\"schemaVersion\":1}".utf8).write(to: budgets)
    let now = Date()
    try CodexWidgetSnapshotStore.save(CodexWidgetSnapshot(updatedAt: now), to: widget)

    let result = ReliabilityAuditor.audit(
      inputs: .init(
        lastQuotaRefresh: now.addingTimeInterval(-60),
        hasOfficialQuota: true,
        lastUsageRefresh: now.addingTimeInterval(-5 * 60),
        usageSampleCount: 10,
        radarUpdatedAt: now.addingTimeInterval(-20 * 60),
        launchWatcherEnabled: true,
        quotaHistoryURL: history,
        projectBudgetsURL: budgets,
        widgetSnapshotURL: widget
      ),
      now: now
    )

    #expect(result.overall == .healthy)
    #expect(result.checks.count == 7)
    #expect(result.criticalCount == 0)
  }

  @Test
  func auditorEscalatesStaleAndCorruptData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let history = root.appendingPathComponent("history.json")
    try Data("broken".utf8).write(to: history)
    let now = Date()

    let result = ReliabilityAuditor.audit(
      inputs: .init(
        lastQuotaRefresh: now.addingTimeInterval(-3600),
        hasOfficialQuota: true,
        lastUsageRefresh: now.addingTimeInterval(-2 * 3600),
        usageSampleCount: 5,
        radarUpdatedAt: now.addingTimeInterval(-5 * 3600),
        launchWatcherEnabled: false,
        quotaHistoryURL: history,
        projectBudgetsURL: root.appendingPathComponent("budgets.json"),
        widgetSnapshotURL: root.appendingPathComponent("widget.json")
      ),
      now: now
    )

    #expect(result.overall == .critical)
    #expect(result.criticalCount >= 4)
    #expect(result.checks.first(where: { $0.id == .quotaHistory })?.level == .critical)
  }

  @Test
  func archiveCopiesOnlyExistingSourcesAndPrunesOldBackups() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/history.json")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"ok\":true}".utf8).write(to: source)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let archive = LocalAutomationArchive(root: root.appendingPathComponent("automation"), calendar: calendar)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z"))

    _ = try archive.backup(sourceURLs: [source], now: now.addingTimeInterval(-10 * 86400), retentionDays: 7)
    let current = try archive.backup(
      sourceURLs: [source, root.appendingPathComponent("missing.json")],
      now: now,
      retentionDays: 7
    )

    #expect(current.itemCount == 1)
    #expect(FileManager.default.fileExists(atPath: current.outputURL.appendingPathComponent("history.json").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("automation/backups/2026-07-07").path))
  }

  @Test
  func eventStoreIsBoundedAndRecoversFromCorruption() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("events.json")
    let store = ReliabilityEventStore(url: url)
    for index in 0..<505 {
      _ = try store.append(.init(
        timestamp: Date(timeIntervalSince1970: Double(index)),
        kind: .info,
        title: "Event \(index)",
        detail: "safe"
      ))
    }
    #expect(store.load().count == 500)
    #expect(store.load().first?.title == "Event 5")

    try Data("not-json".utf8).write(to: url)
    #expect(store.load().isEmpty)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(files.contains { $0.contains("corrupt-") })
  }

  @Test
  func diagnosticReportStatesPrivacyBoundary() {
    let snapshot = ReliabilitySnapshot(checks: [
      ReliabilityCheck(id: .officialQuota, title: "额度", level: .healthy, detail: "数据新鲜", checkedAt: Date())
    ])
    let report = ReliabilityReportBuilder.diagnosticMarkdown(
      appVersion: "2.8.0",
      snapshot: snapshot,
      recentEvents: []
    )

    #expect(report.contains("不包含账号、对话、项目路径、凭据或 API Key"))
    #expect(report.contains("2.8.0"))
  }
}
