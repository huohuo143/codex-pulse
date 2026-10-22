import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Background backup feedback", .serialized)
struct AutomationBackupFeedbackTests {
  @Test func backupLeavesMainActorAvailableAndRejectsDuplicateRequests() async throws {
    let f = try BackupFeedbackFixture()
    defer { f.clean() }
    let files = PausedBackupFileManager()
    let archive = LocalAutomationArchive(root: f.archiveRoot, fileManager: files)
    let store = f.dashboard()
    let operation = Task { await store.performLocalBackup(archive: archive) }
    defer { files.release.signal() }
    for _ in 0..<100 {
      if files.callCount > 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(files.callCount == 1)
    #expect(!files.ranOnMainThread)
    #expect(store.isBackingUp)
    await store.performLocalBackup(archive: archive)
    #expect(files.callCount == 1)
    #expect(store.isBackingUp)
    files.release.signal()
    await operation.value
    #expect(!store.isBackingUp)
    #expect(store.reliabilityMessage?.contains("已备份") == true)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .localBackup }?.level == .healthy)
    #expect(archive.hasBackup(for: Date(), sourceURLs: store.localBackupSourceURLs))
  }

  @Test func failedBackupKeepsReceiptAndCanRetryAfterSourceIsRepaired() async throws {
    let f = try BackupFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard()
    await store.performLocalBackup(archive: f.archive)
    let directory = try f.archive.backup(sourceURLs: [], now: Date()).outputURL
    let saved = directory.appendingPathComponent(f.budgets.storageURL.lastPathComponent)
    let original = try Data(contentsOf: saved)
    let manifest = try Data(contentsOf: directory.appendingPathComponent("backup-manifest-v1.json"))
    try FileManager.default.removeItem(at: f.budgets.storageURL)
    try FileManager.default.createSymbolicLink(at: f.budgets.storageURL, withDestinationURL: f.budgets.previousURL)
    await store.performLocalBackup(archive: f.archive)
    #expect(!store.isBackingUp)
    #expect(store.reliabilityMessage?.hasPrefix("备份失败：") == true)
    #expect(store.reliabilityMessage?.contains("已有备份未改动") == true)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .localBackup }?.level == .warning)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .projectBudgets }?.level == .critical)
    #expect(try Data(contentsOf: saved) == original)
    #expect(try Data(contentsOf: directory.appendingPathComponent("backup-manifest-v1.json")) == manifest)
    try FileManager.default.removeItem(at: f.budgets.storageURL)
    try original.write(to: f.budgets.storageURL)
    await store.performLocalBackup(archive: f.archive)
    #expect(store.reliabilityMessage?.contains("已备份") == true)
    #expect(!store.isBackingUp)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .localBackup }?.level == .healthy)
  }

  @Test func automaticBackupSkipsValidReceiptButRetriesMissingCopy() async throws {
    let f = try BackupFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard()
    let now = Date()
    await store.performLocalBackup(manual: false, now: now, archive: f.archive)
    let directory = try f.archive.backup(sourceURLs: [], now: now).outputURL
    let saved = directory.appendingPathComponent(f.budgets.storageURL.lastPathComponent)
    let original = try Data(contentsOf: saved)
    _ = try f.budgets.upsert(.init(projectName: "fixture", monthlyTokenLimit: 200))
    await store.performLocalBackup(manual: false, now: now, archive: f.archive)
    #expect(try Data(contentsOf: saved) == original)
    #expect(!store.isBackingUp)
    try FileManager.default.removeItem(at: saved)
    await store.performLocalBackup(manual: false, now: now, archive: f.archive)
    #expect(try Data(contentsOf: saved) == Data(contentsOf: f.budgets.storageURL))
    #expect(f.archive.hasBackup(for: now, sourceURLs: store.localBackupSourceURLs))
  }

  @Test func futureReceiptFailureDoesNotMasqueradeAsSuccessfulBackup() async throws {
    let f = try BackupFeedbackFixture()
    defer { f.clean() }
    let store = f.dashboard()
    await store.performLocalBackup(archive: f.archive)
    let directory = try f.archive.backup(sourceURLs: [], now: Date()).outputURL
    let manifest = directory.appendingPathComponent("backup-manifest-v1.json")
    let originalManifest = try Data(contentsOf: manifest)
    let future = Data(#"{"schemaVersion":99,"futureBackup":[]}"#.utf8)
    try future.write(to: manifest)
    let saved = directory.appendingPathComponent(f.budgets.storageURL.lastPathComponent)
    let original = try Data(contentsOf: saved)
    _ = try f.budgets.upsert(.init(projectName: "fixture", monthlyTokenLimit: 200))
    await store.performLocalBackup(manual: false, archive: f.archive)
    #expect(store.reliabilityMessage?.contains("暂不支持的版本（99）") == true)
    #expect(store.localBackupHealth == .failed)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .localBackup }?.level == .warning)
    #expect(!store.isBackingUp)
    #expect(try Data(contentsOf: manifest) == future)
    #expect(try Data(contentsOf: saved) == original)
    // A readable old receipt must not hide a failed request to back up newer data.
    try originalManifest.write(to: manifest)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .localBackup }?.level == .warning)
    await store.performLocalBackup(manual: false, archive: f.archive)
    #expect(try Data(contentsOf: saved) == Data(contentsOf: f.budgets.storageURL))
    #expect(store.localBackupHealth == .verified)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .localBackup }?.level == .healthy)
  }
}

private struct BackupFeedbackFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    _ = try budgets.upsert(.init(projectName: "fixture", monthlyTokenLimit: 100))
  }
  var budgets: ProjectBudgetStore { .init(url: root.appendingPathComponent("budgets.json")) }
  var archiveRoot: URL { root.appendingPathComponent("archive") }
  var archive: LocalAutomationArchive { .init(root: archiveRoot) }
  @MainActor func dashboard() -> DashboardStore {
    let store = DashboardStore(startServices: false, expiryStore: .init(url: root.appendingPathComponent("credits.json"),
      legacyURL: root.appendingPathComponent("legacy.json")), budgetStore: budgets)
    store.quotaHistoryStore = .init(url: root.appendingPathComponent("history.json"))
    return store
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class PausedBackupFileManager: FileManager, @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0
  private var wasMain = false
  var callCount: Int { lock.withLock { count } }
  var ranOnMainThread: Bool { lock.withLock { wasMain } }
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    lock.withLock { count += 1; wasMain = Thread.isMainThread }
    guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}
