import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Project budget backup health")
struct ProjectBudgetHealthTests {
  @Test(arguments: [false, true])
  func futureBackupCannotBeOverwrittenBySaveOrDelete(delete: Bool) throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    let primary = try Data(contentsOf: fixture.store.storageURL)
    let future = Data(#"{"schemaVersion":99,"futureBudgets":{"preserve":true}}"#.utf8)
    try future.write(to: fixture.store.previousURL)
    let read = fixture.store.loadResult()
    #expect(read.issue == .unsupportedBackupVersion(99))
    #expect(read.budgets == [fixture.budget])
    #expect(fixture.check().level == .critical)
    #expect(throws: ProjectBudgetStorageIssue.unsupportedBackupVersion(99)) {
      if delete { _ = try fixture.store.remove(id: fixture.budget.id) }
      else { _ = try fixture.store.upsert(.init(projectName: "manual", monthlyTokenLimit: 200)) }
    }
    #expect(try Data(contentsOf: fixture.store.storageURL) == primary)
    #expect(try Data(contentsOf: fixture.store.previousURL) == future)
    #expect(throws: ProjectBudgetStorageIssue.unsupportedBackupVersion(99)) { _ = try fixture.store.remove(id: "missing") }
  }

  @Test func corruptBackupIsReportedWithoutChangingReadablePrimary() throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    let primary = try Data(contentsOf: fixture.store.storageURL)
    let corrupt = Data("{preserve until next successful save".utf8)
    try corrupt.write(to: fixture.store.previousURL)
    #expect(fixture.check().level == .warning)
    #expect(fixture.store.loadResult().backupIssue == .invalidRecord)
    #expect(fixture.store.loadResult().issue == nil)
    #expect(fixture.store.loadResult().budgets == [fixture.budget])
    #expect(try Data(contentsOf: fixture.store.storageURL) == primary)
    #expect(try Data(contentsOf: fixture.store.previousURL) == corrupt)
    _ = try fixture.store.upsert(fixture.budget)
    #expect(fixture.check().level == .healthy)
    #expect(try Data(contentsOf: fixture.store.previousURL) == primary)
  }

  @Test(arguments: ["link", "directory", "pipe", "oversized"])
  func unsafeBackupBlocksChangesButRetainsVisibleBudgets(kind: String) throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    let store = fixture.store
    let primary = try Data(contentsOf: store.storageURL)
    try FileManager.default.removeItem(at: store.previousURL)
    switch kind {
    case "link": try FileManager.default.createSymbolicLink(at: store.previousURL, withDestinationURL: store.storageURL)
    case "directory": try FileManager.default.createDirectory(at: store.previousURL, withIntermediateDirectories: false)
    case "pipe": #expect(mkfifo(store.previousURL.path, 0o600) == 0)
    default: try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: store.previousURL)
    }
    let inode = try FileManager.default.attributesOfItem(atPath: store.previousURL.path)[.systemFileNumber] as? NSNumber
    let state = store.loadResult()
    #expect(state.issue == .unreadableBackup)
    #expect(state.budgets == [fixture.budget])
    #expect(fixture.check().level == .critical)
    #expect(throws: ProjectBudgetStorageIssue.unreadableBackup) { _ = try store.remove(id: fixture.budget.id) }
    #expect(throws: ProjectBudgetStorageIssue.unreadableBackup) { _ = try store.upsert(fixture.budget) }
    #expect(try Data(contentsOf: store.storageURL) == primary)
    #expect(try FileManager.default.attributesOfItem(atPath: store.previousURL.path)[.systemFileNumber] as? NSNumber == inode)
  }

  @Test(arguments: ["save", "delete", "new"])
  func backupChangesDuringSavePreparationCannotBeOverwritten(operation: String) throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    if operation == "new" {
      try FileManager.default.removeItem(at: fixture.store.storageURL)
      try FileManager.default.removeItem(at: fixture.store.previousURL)
    }
    let original = try LocalRecordFile.read(at: fixture.store.storageURL)
    let replacement = Data(#"{"schemaVersion":99,"externalBackup":true}"#.utf8)
    let store = ProjectBudgetStore(url: fixture.store.storageURL,
      fileManager: BudgetBackupReplacingFileManager(backup: fixture.store.previousURL, replacement: replacement))
    #expect(throws: ProjectBudgetStorageIssue.changedOnDisk) {
      if operation == "delete" { _ = try store.remove(id: fixture.budget.id) }
      else { _ = try store.upsert(fixture.budget) }
    }
    #expect(try LocalRecordFile.read(at: store.storageURL) == original)
    #expect(try Data(contentsOf: store.previousURL) == replacement)
  }

  @Test func backupChangesDuringRecoveryCannotReplaceDamagedPrimary() throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    let damaged = Data("{keep damaged primary".utf8)
    try damaged.write(to: fixture.store.storageURL)
    let replacement = Data(#"{"schemaVersion":99,"externalBackup":true}"#.utf8)
    let store = ProjectBudgetStore(url: fixture.store.storageURL,
      fileManager: BudgetBackupReplacingFileManager(backup: fixture.store.previousURL, replacement: replacement))
    #expect(throws: ProjectBudgetStorageIssue.changedOnDisk) { _ = try store.restorePrevious() }
    #expect(try Data(contentsOf: store.storageURL) == damaged)
    #expect(try Data(contentsOf: store.previousURL) == replacement)
    let copies = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.contains(".damaged-") }
    #expect(copies.count == 1)
    #expect(try Data(contentsOf: #require(copies.first)) == damaged)
  }

  @Test func oversizedInputCannotCreateAnUnreadableRecord() throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    let primary = try Data(contentsOf: fixture.store.storageURL)
    let backup = try Data(contentsOf: fixture.store.previousURL)
    let huge = ProjectBudget(projectName: String(repeating: "x", count: 8 * 1024 * 1024), monthlyTokenLimit: 100)
    #expect(throws: ProjectBudgetStorageIssue.recordTooLarge) { _ = try fixture.store.upsert(huge) }
    #expect(try Data(contentsOf: fixture.store.storageURL) == primary)
    #expect(try Data(contentsOf: fixture.store.previousURL) == backup)
    #expect(fixture.check().level == .healthy)
  }

  @Test func missingBackupIsOptionalAndHealthNeverCreatesIt() throws {
    let fixture = try BudgetHealthFixture()
    defer { fixture.clean() }
    try FileManager.default.removeItem(at: fixture.store.previousURL)
    #expect(fixture.check().level == .healthy)
    #expect(fixture.store.loadResult().budgets == [fixture.budget])
    #expect(!FileManager.default.fileExists(atPath: fixture.store.previousURL.path))
    try FileManager.default.removeItem(at: fixture.store.storageURL)
    #expect(fixture.check().level == .healthy)
    #expect(fixture.check().detail == "尚未设置项目预算")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
  }
}

private struct BudgetHealthFixture {
  let root: URL
  let budget = ProjectBudget(projectName: "manual", monthlyTokenLimit: 100,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try store.upsert(budget)
  }
  var store: ProjectBudgetStore { .init(url: root.appendingPathComponent("budgets.json")) }
  func check() -> ReliabilityCheck {
    ReliabilityAuditor.audit(inputs: .init(lastQuotaRefresh: nil, hasOfficialQuota: false, lastUsageRefresh: nil,
      usageSampleCount: 0, radarUpdatedAt: nil, launchWatcherEnabled: false,
      quotaHistoryURL: root.appendingPathComponent("history.json"), projectBudgetsURL: store.storageURL,
      widgetSnapshotURL: root.appendingPathComponent("widget.json"),
      creditExpiryStore: .init(url: root.appendingPathComponent("credits.json"), legacyURL: root.appendingPathComponent("legacy.json"))))
      .checks.first { $0.id == .projectBudgets }!
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class BudgetBackupReplacingFileManager: FileManager, @unchecked Sendable {
  let backup: URL
  let replacement: Data
  init(backup: URL, replacement: Data) { self.backup = backup; self.replacement = replacement; super.init() }
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    try replacement.write(to: backup, options: .atomic)
  }
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try super.copyItem(at: srcURL, to: dstURL)
    try replacement.write(to: backup, options: .atomic)
  }
}
