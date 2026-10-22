import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Project budget recovery feedback", .serialized)
struct ProjectBudgetRecoveryViewTests {
  @Test func failedSaveAndRecoveryPreserveDraftUntilSuccessfulRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ProjectBudgetStore(url: root.appendingPathComponent("budgets.json"))
    _ = try storage.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
    let store = DashboardStore(startServices: false, budgetStore: storage)
    var form = ProjectBudgetEditorState(limitText: "2,000,000")
    let damaged = Data("{original while editor is open".utf8)
    try damaged.write(to: storage.storageURL)
    let save = { (value: Int) in store.setProjectBudget(project: .init(projectName: "manual"), monthlyTokenLimit: value) }
    let failedDismiss = form.save(using: save)
    #expect(!failedDismiss)
    #expect(form.limitText == "2,000,000")
    #expect(store.projectBudgets.first?.monthlyTokenLimit == 100)
    #expect(store.projectBudgetStorageIssue == .invalidRecord)
    #expect(store.projectBudgetRecovery?.budgetCount == 1)
    #expect(try Data(contentsOf: storage.storageURL) == damaged)
    #expect(store.restoreProjectBudgetBackup())
    #expect(form.limitText == "2,000,000")
    #expect(store.projectBudgetStorageIssue == nil)
    let successfulDismiss = form.save(using: save)
    #expect(successfulDismiss)
    #expect(form.saveError == nil)
    #expect(storage.load().first?.monthlyTokenLimit == 2_000_000)
  }

  @Test func failedDeleteRetainsVisibleBudgetAndReportsFutureFormat() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ProjectBudgetStore(url: root.appendingPathComponent("budgets.json"))
    _ = try storage.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
    let store = DashboardStore(startServices: false, budgetStore: storage)
    let future = Data(#"{"schemaVersion":99,"newBudgets":[]}"#.utf8)
    try future.write(to: storage.storageURL)
    guard case .failure = store.removeProjectBudget(id: "manual") else { Issue.record("Delete must be blocked"); return }
    #expect(store.projectBudgets.first?.monthlyTokenLimit == 100)
    #expect(store.projectBudgetStorageIssue == .unsupportedVersion(99))
    #expect(store.projectBudgetRecovery == nil)
    #expect(store.budgetMessage?.hasPrefix("预算移除失败：") == true)
    #expect(!store.reloadProjectBudgets())
    #expect(try Data(contentsOf: storage.storageURL) == future)
  }

  @Test func dailyBackupIncludesCurrentAndPreviousBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ProjectBudgetStore(url: root.appendingPathComponent("budgets.json"))
    _ = try storage.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
    _ = try storage.upsert(.init(projectName: "manual", monthlyTokenLimit: 200))
    let store = DashboardStore(startServices: false, budgetStore: storage)
    #expect(store.localBackupSourceURLs.contains(storage.storageURL))
    #expect(store.localBackupSourceURLs.contains(storage.previousURL))
    let archiveRoot = root.appendingPathComponent("archive")
    await store.performLocalBackup(manual: false, archive: LocalAutomationArchive(root: archiveRoot))
    let files = try #require(FileManager.default.enumerator(at: archiveRoot, includingPropertiesForKeys: nil))
      .allObjects.compactMap { $0 as? URL }
    for source in [storage.storageURL, storage.previousURL] {
      let copy = try #require(files.first { $0.lastPathComponent == source.lastPathComponent })
      #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
    }
  }

  @Test func olderBackupWithoutEditedProjectRetainsDraftIdentityAndCreationDate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ProjectBudgetStore(url: root.appendingPathComponent("budgets.json"))
    _ = try storage.upsert(.init(projectName: "earlier", monthlyTokenLimit: 100))
    let original = ProjectBudget(projectName: "editing", projectPath: "/qa/editing", monthlyTokenLimit: 200,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    _ = try storage.upsert(original)
    let store = DashboardStore(startServices: false, budgetStore: storage)
    var form = ProjectBudgetEditorState(limitText: "2,000,001", originalBudget: original)
    try Data("{corrupt while editing".utf8).write(to: storage.storageURL)
    let prior = form.originalBudget
    let save = { (value: Int) in store.setProjectBudget(project: .init(projectName: original.projectName,
      projectPath: original.projectPath), monthlyTokenLimit: value, originalBudget: prior) }
    let failed = form.save(using: save)
    #expect(!failed)
    #expect(store.restoreProjectBudgetBackup())
    #expect(store.projectBudgets.map(\.id) == ["earlier"])
    #expect(form.limitText == "2,000,001")
    #expect(form.originalBudget == original)
    let succeeded = form.save(using: save)
    #expect(succeeded)
    let restored = try #require(storage.load().first { $0.id == original.id })
    #expect(restored.monthlyTokenLimit == 2_000_001)
    #expect(restored.createdAt == original.createdAt)
    #expect(restored.projectPath == original.projectPath)
  }
}
