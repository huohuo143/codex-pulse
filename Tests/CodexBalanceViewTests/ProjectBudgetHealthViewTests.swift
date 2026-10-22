import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Project budget health feedback", .serialized)
struct ProjectBudgetHealthViewTests {
  @Test func futureBackupBlocksSaveAndDeleteWithoutLosingDraftOrVisibleBudget() throws {
    let fixture = try BudgetHealthViewFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, budgetStore: fixture.storage)
    let primary = try Data(contentsOf: fixture.storage.storageURL)
    let future = Data(#"{"schemaVersion":99,"futureBudgets":[]}"#.utf8)
    try future.write(to: fixture.storage.previousURL)
    var form = ProjectBudgetEditorState(limitText: "2,000,001", originalBudget: fixture.budget)
    let save = { (value: Int) in store.setProjectBudget(project: .init(projectName: "manual"), monthlyTokenLimit: value) }
    let failedDismiss = form.save(using: save)
    #expect(!failedDismiss)
    #expect(form.limitText == "2,000,001")
    #expect(store.projectBudgets == [fixture.budget])
    #expect(store.projectBudgetStorageIssue == .unsupportedBackupVersion(99))
    #expect(fixture.check(store).level == .critical)
    #expect(throws: ProjectBudgetStorageIssue.unsupportedBackupVersion(99)) { try store.removeProjectBudget(id: "manual").get() }
    #expect(try Data(contentsOf: fixture.storage.storageURL) == primary)
    #expect(try Data(contentsOf: fixture.storage.previousURL) == future)
    try primary.write(to: fixture.storage.previousURL)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(fixture.check(store).level == .warning)
    #expect(fixture.check(store).detail.contains("重新读取"))
    #expect(store.reloadProjectBudgets())
    #expect(form.limitText == "2,000,001")
    #expect(fixture.check(store).level == .healthy)
    let savedDismiss = form.save(using: save)
    #expect(savedDismiss)
    #expect(fixture.storage.load().first?.monthlyTokenLimit == 2_000_001)
    #expect(fixture.storage.load().first?.createdAt == fixture.budget.createdAt)
  }

  @Test func writeFailuresRemainVisibleThroughReloadAndDoNotExposePrivatePaths() throws {
    let fixture = try BudgetHealthViewFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, budgetStore: fixture.storage)
    fixture.files.failWrites = true
    #expect(throws: (any Error).self) { try store.setProjectBudget(project: .init(projectName: "manual"), monthlyTokenLimit: 200).get() }
    #expect(store.projectBudgetWriteFailed)
    #expect(fixture.check(store).level == .warning)
    #expect(fixture.check(store).detail.contains("写入未完成"))
    #expect(store.reloadProjectBudgets())
    #expect(store.projectBudgetWriteFailed)
    #expect(fixture.check(store).level == .warning)
    try store.removeProjectBudget(id: "not-present").get()
    #expect(store.projectBudgetWriteFailed)
    let report = ReliabilityReportBuilder.diagnosticMarkdown(appVersion: "test", snapshot: store.reliabilitySnapshot, recentEvents: [])
    #expect(report.contains("项目预算文件"))
    #expect(!report.contains("private-sensitive-path"))
    #expect(!report.contains(fixture.root.path))
    fixture.files.failWrites = false
    try store.setProjectBudget(project: .init(projectName: "manual"), monthlyTokenLimit: 200).get()
    #expect(!store.projectBudgetWriteFailed)
    #expect(fixture.check(store).level == .healthy)
    fixture.files.failWrites = true
    #expect(throws: (any Error).self) { try store.removeProjectBudget(id: "manual").get() }
    #expect(store.projectBudgets.count == 1)
    #expect(fixture.check(store).level == .warning)
    fixture.files.failWrites = false
    try store.removeProjectBudget(id: "manual").get()
    #expect(store.projectBudgets.isEmpty)
    #expect(!store.projectBudgetWriteFailed)
    #expect(fixture.check(store).level == .healthy)
  }

  @Test func healthOnlyReportsCorruptBackupAndSuccessfulSaveRepairsIt() throws {
    let fixture = try BudgetHealthViewFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, budgetStore: fixture.storage)
    let primary = try Data(contentsOf: fixture.storage.storageURL)
    let damaged = Data("{damaged backup".utf8)
    try damaged.write(to: fixture.storage.previousURL)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(fixture.check(store).level == .warning)
    #expect(try Data(contentsOf: fixture.storage.storageURL) == primary)
    #expect(try Data(contentsOf: fixture.storage.previousURL) == damaged)
    try store.setProjectBudget(project: .init(projectName: "manual"), monthlyTokenLimit: 200).get()
    #expect(fixture.check(store).level == .healthy)
    #expect(try Data(contentsOf: fixture.storage.previousURL) == primary)
  }

  @Test func explicitRecoveryUpdatesHealthImmediatelyWithoutAutomaticRestore() throws {
    let fixture = try BudgetHealthViewFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, budgetStore: fixture.storage)
    let damaged = Data("{damaged primary".utf8)
    try damaged.write(to: fixture.storage.storageURL)
    #expect(!store.reloadProjectBudgets())
    #expect(fixture.check(store).level == .critical)
    store.automaticRecoveryAttempts = 0
    store.attemptAutomaticRecovery(snapshot: .init(checks: [fixture.check(store)]), now: Date())
    #expect(store.automaticRecoveryAttempts == 0)
    #expect(try Data(contentsOf: fixture.storage.storageURL) == damaged)
    #expect(store.restoreProjectBudgetBackup())
    #expect(fixture.check(store).level == .healthy)
    #expect(store.projectBudgets == [fixture.budget])
    let copies = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.contains(".damaged-") }
    #expect(copies.count == 1)
    #expect(try Data(contentsOf: #require(copies.first)) == damaged)
  }

  @Test func invalidInputDoesNotMakeReadableFilesUnhealthy() throws {
    let fixture = try BudgetHealthViewFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, budgetStore: fixture.storage)
    #expect(throws: (any Error).self) { try store.setProjectBudget(project: .init(projectName: "manual"), monthlyTokenLimit: 0).get() }
    #expect(!store.projectBudgetWriteFailed)
    #expect(fixture.check(store).level == .healthy)
    let name = String(repeating: "x", count: 8 * 1024 * 1024)
    #expect(throws: ProjectBudgetStorageIssue.recordTooLarge) {
      try store.setProjectBudget(project: .init(projectName: name), monthlyTokenLimit: 100).get()
    }
    #expect(!store.projectBudgetWriteFailed)
    #expect(fixture.check(store).level == .healthy)
    #expect(fixture.storage.load() == [fixture.budget])
  }
}

private struct BudgetHealthViewFixture {
  let root: URL
  let files = BudgetHealthFailureFileManager()
  let budget = ProjectBudget(projectName: "manual", monthlyTokenLimit: 100,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = try storage.upsert(budget)
  }
  var storage: ProjectBudgetStore { .init(url: root.appendingPathComponent("budgets.json"), fileManager: files) }
  @MainActor func check(_ store: DashboardStore) -> ReliabilityCheck { store.reliabilitySnapshot.checks.first { $0.id == .projectBudgets }! }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class BudgetHealthFailureFileManager: FileManager, @unchecked Sendable {
  var failWrites = false
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    if failWrites { throw NSError(domain: "QA", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-sensitive-path"]) }
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}
