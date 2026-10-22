import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Local record health accuracy")
struct LocalRecordHealthTests {
  @Test(arguments: [#"{"schemaVersion":99,"newPayload":[]}"#, #"{"schemaVersion":1}"#, "{broken"])
  func unsupportedOrIncompleteJSONIsNeverReportedHealthy(document: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json"), budgets = root.appendingPathComponent("budgets.json")
    let original = Data(document.utf8)
    try original.write(to: history); try original.write(to: budgets)
    let result = ReliabilityAuditor.audit(inputs: .init(lastQuotaRefresh: nil, hasOfficialQuota: false,
      lastUsageRefresh: nil, usageSampleCount: 0, radarUpdatedAt: nil, launchWatcherEnabled: false,
      quotaHistoryURL: history, projectBudgetsURL: budgets, widgetSnapshotURL: root.appendingPathComponent("widget.json")))
    for id in [ReliabilityCheckID.quotaHistory, .projectBudgets] {
      #expect(result.checks.first { $0.id == id }?.level == .critical)
    }
    #expect(try Data(contentsOf: history) == original)
    #expect(try Data(contentsOf: budgets) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
  }

  @Test func missingPrimaryWithBackupIsNotReportedAsUnconfigured() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProjectBudgetStore(url: root.appendingPathComponent("budgets.json"))
    _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
    try FileManager.default.removeItem(at: store.storageURL)
    let result = ReliabilityAuditor.audit(inputs: .init(lastQuotaRefresh: nil, hasOfficialQuota: false,
      lastUsageRefresh: nil, usageSampleCount: 0, radarUpdatedAt: nil, launchWatcherEnabled: false,
      quotaHistoryURL: root.appendingPathComponent("history.json"), projectBudgetsURL: store.storageURL,
      widgetSnapshotURL: root.appendingPathComponent("widget.json")))
    let check = try #require(result.checks.first { $0.id == .projectBudgets })
    #expect(check.level == .critical)
    #expect(check.detail.contains("主文件缺失"))
    #expect(!FileManager.default.fileExists(atPath: store.storageURL.path))
  }

  @Test func validDiskFormatDoesNotHidePendingWriteFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    try Data(#"{"schemaVersion":1,"snapshots":[]}"#.utf8).write(to: history)
    let message = QuotaHistoryStorageIssue.writeFailed.localizedDescription
    let result = ReliabilityAuditor.audit(inputs: .init(lastQuotaRefresh: nil, hasOfficialQuota: false,
      lastUsageRefresh: nil, usageSampleCount: 0, radarUpdatedAt: nil, launchWatcherEnabled: false,
      quotaHistoryURL: history, projectBudgetsURL: root.appendingPathComponent("budgets.json"),
      widgetSnapshotURL: root.appendingPathComponent("widget.json"), quotaHistoryStorageMessage: message))
    #expect(result.checks.first { $0.id == .quotaHistory }?.level == .warning)
    #expect(result.checks.first { $0.id == .quotaHistory }?.detail == message)
  }
}
