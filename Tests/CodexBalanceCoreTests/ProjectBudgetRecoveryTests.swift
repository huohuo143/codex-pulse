import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Project budget data protection")
struct ProjectBudgetRecoveryTests {
  private func withStore(_ body: (URL, ProjectBudgetStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("budgets.json")
    try body(url, ProjectBudgetStore(url: url))
  }

  @Test func readingCorruptBudgetNeverMovesTheOnlyOriginal() throws {
    try withStore { url, store in
      let original = Data("{unrecoverable manual budget".utf8)
      try original.write(to: url)
      #expect(store.load().isEmpty)
      #expect(FileManager.default.fileExists(atPath: url.path))
      #expect((try? Data(contentsOf: url)) == original)
    }
  }

  @Test(arguments: [false, true])
  func corruptBudgetBlocksSaveAndDelete(delete: Bool) throws {
    try withStore { url, _ in
      let original = Data("{retain damaged manual entries".utf8)
      try original.write(to: url)
      let store = ProjectBudgetStore(url: url, fileManager: BudgetPreservationFailureFileManager())
      #expect(throws: (any Error).self) {
        if delete { _ = try store.remove(id: "existing") }
        else { _ = try store.upsert(.init(projectName: "new", monthlyTokenLimit: 200)) }
      }
      #expect(try Data(contentsOf: url) == original)
    }
  }

  @Test(arguments: [#"{"schemaVersion":99,"budgets":[]}"#,
    #"{"schemaVersion":99,"futureBudgets":{"custom":true}}"#])
  func futureBudgetFormatCannotBeDowngraded(document: String) throws {
    try withStore { url, store in
      let original = Data(document.utf8)
      try original.write(to: url)
      #expect(throws: (any Error).self) { _ = try store.upsert(.init(projectName: "new", monthlyTokenLimit: 200)) }
      #expect(try Data(contentsOf: url) == original)
      #expect(throws: (any Error).self) { _ = try store.remove(id: "new") }
      #expect(try Data(contentsOf: url) == original)
    }
  }

  @Test func recoveryPreservesEveryDamagedOriginalAndRetainsMetadata() throws {
    try withStore { url, store in
      let created = Date(timeIntervalSince1970: 1_700_000_000)
      let budget = ProjectBudget(projectName: "manual", projectPath: "/qa/manual", monthlyTokenLimit: 100,
        createdAt: created, updatedAt: created)
      _ = try store.upsert(budget)
      var edited = budget; edited.monthlyTokenLimit = 200
      _ = try store.upsert(edited)
      let backup = try Data(contentsOf: store.previousURL)
      var preserved: [URL] = []
      for text in ["{first corruption", "{second corruption"] {
        let damaged = Data(text.utf8)
        try damaged.write(to: url)
        let state = store.loadResult()
        #expect(state.issue == .invalidRecord)
        #expect(state.recovery?.budgetCount == 1)
        #expect(try Data(contentsOf: url) == damaged)
        let restored = try store.restorePrevious()
        let copy = try #require(restored.preservedOriginalURL)
        preserved.append(copy)
        #expect(try Data(contentsOf: copy) == damaged)
        #expect(restored.budgets == [budget])
        #expect(try Data(contentsOf: store.previousURL) == backup)
      }
      #expect(Set(preserved).count == 2)
      #expect(try Data(contentsOf: preserved[0]) == Data("{first corruption".utf8))
      _ = try store.upsert(.init(projectName: "manual", projectPath: "/qa/manual", monthlyTokenLimit: 300))
      #expect(store.load().first?.createdAt == created)
      #expect(store.load().first?.monthlyTokenLimit == 300)
      #expect(store.loadResult().issue == nil)
    }
  }

  @Test func missingPrimaryPreservesTheOnlyBackupUntilExplicitRecovery() throws {
    try withStore { url, store in
      _ = try store.upsert(.init(projectName: "existing", monthlyTokenLimit: 100))
      let backup = try Data(contentsOf: store.previousURL)
      try FileManager.default.removeItem(at: url)
      #expect(store.loadResult().issue == .missingRecord)
      #expect(store.loadResult().recovery?.budgetCount == 1)
      #expect(throws: ProjectBudgetStorageIssue.missingRecord) { _ = try store.remove(id: "existing") }
      #expect(throws: ProjectBudgetStorageIssue.missingRecord) { _ = try store.upsert(.init(projectName: "new", monthlyTokenLimit: 200)) }
      #expect(try Data(contentsOf: store.previousURL) == backup)
      #expect(!FileManager.default.fileExists(atPath: url.path))
      let result = try store.restorePrevious()
      #expect(result.preservedOriginalURL == nil)
      #expect(result.budgets.map(\.id) == ["existing"])
    }
  }

  @Test(arguments: [false, true])
  func restoreNeverReplacesValidOrFutureFormatPrimary(future: Bool) throws {
    try withStore { url, store in
      _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
      if future { try Data(#"{"schemaVersion":99,"futureBudgets":[]}"#.utf8).write(to: url) }
      let original = try Data(contentsOf: url)
      let backup = try Data(contentsOf: store.previousURL)
      #expect(throws: future ? ProjectBudgetStorageIssue.unsupportedVersion(99) : .alreadyValid) {
        _ = try store.restorePrevious()
      }
      #expect(try Data(contentsOf: url) == original)
      #expect(try Data(contentsOf: store.previousURL) == backup)
    }
  }

  @Test(arguments: [false, true])
  func failedPreservationOrVerificationBlocksRestore(incorrectCopy: Bool) throws {
    try withStore { url, store in
      _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
      let damaged = Data("{original to protect".utf8)
      try damaged.write(to: url)
      let backup = try Data(contentsOf: store.previousURL)
      let files: FileManager = incorrectCopy ? BudgetIncorrectCopyFileManager() : BudgetPreservationFailureFileManager()
      let failing = ProjectBudgetStore(url: url, fileManager: files)
      #expect(throws: (any Error).self) { _ = try failing.restorePrevious() }
      #expect(try Data(contentsOf: url) == damaged)
      #expect(try Data(contentsOf: store.previousURL) == backup)
      #expect(failing.loadResult().recovery?.budgetCount == 1)
    }
  }

  @Test func rollingBackupFailureLeavesPrimaryUntouchedAndCanRetry() throws {
    try withStore { url, store in
      _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
      let primary = try Data(contentsOf: url)
      let backup = try Data(contentsOf: store.previousURL)
      try FileManager.default.removeItem(at: store.previousURL)
      try FileManager.default.createDirectory(at: store.previousURL, withIntermediateDirectories: false)
      #expect(throws: (any Error).self) { _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 200)) }
      #expect(try Data(contentsOf: url) == primary)
      try FileManager.default.removeItem(at: store.previousURL)
      try backup.write(to: store.previousURL)
      _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 200))
      #expect(store.load().first?.monthlyTokenLimit == 200)
      #expect(try Data(contentsOf: store.previousURL) == primary)
    }
  }

  @Test(arguments: ["duplicate", "zero", "empty-id"])
  func invalidRecordsAreNeverSilentlyDropped(kind: String) throws {
    try withStore { url, store in
      _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
      var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      var rows = try #require(payload["budgets"] as? [[String: Any]])
      if kind == "duplicate" { rows.append(rows[0]) }
      else if kind == "zero" { rows[0]["monthlyTokenLimit"] = 0 }
      else { rows[0]["id"] = "" }
      payload["budgets"] = rows
      let original = try JSONSerialization.data(withJSONObject: payload)
      try original.write(to: url)
      #expect(store.loadResult().issue == .invalidRecord)
      #expect(throws: ProjectBudgetStorageIssue.invalidRecord) { _ = try store.upsert(.init(projectName: "new", monthlyTokenLimit: 200)) }
      #expect(try Data(contentsOf: url) == original)
    }
  }

  @Test(arguments: ["symlink", "fifo", "oversized"])
  func unsafeFilesCannotBeReadOrReplaced(kind: String) throws {
    try withStore { url, store in
      switch kind {
      case "symlink": try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "missing.json")
      case "fifo": #expect(mkfifo(url.path, 0o600) == 0)
      default: try Data(repeating: 123, count: 8 * 1024 * 1024 + 1).write(to: url)
      }
      let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
      #expect(store.loadResult().issue == .unreadableRecord)
      #expect(throws: ProjectBudgetStorageIssue.unreadableRecord) { _ = try store.remove(id: "manual") }
      #expect(throws: ProjectBudgetStorageIssue.unreadableRecord) { _ = try store.upsert(.init(projectName: "new", monthlyTokenLimit: 200)) }
      #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber == inode)
    }
  }

  @Test(arguments: ["{invalid backup", #"{"schemaVersion":99,"budgets":[]}"#])
  func invalidOrFutureBackupCannotReplacePrimary(backupDocument: String) throws {
    try withStore { url, store in
      let primary = Data("{damaged primary".utf8), backup = Data(backupDocument.utf8)
      try primary.write(to: url); try backup.write(to: store.previousURL)
      #expect(store.loadResult().recovery == nil)
      #expect(throws: ProjectBudgetStorageIssue.noValidBackup) { _ = try store.restorePrevious() }
      #expect(try Data(contentsOf: url) == primary)
      #expect(try Data(contentsOf: store.previousURL) == backup)
      #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 2)
    }
  }

  @Test func externalReplacementDuringPreservationCannotBeOverwritten() throws {
    try withStore { url, store in
      _ = try store.upsert(.init(projectName: "manual", monthlyTokenLimit: 100))
      let original = Data("{original before concurrent replacement".utf8)
      try original.write(to: url)
      let external = Data(#"{"schemaVersion":99,"futureBudgets":[]}"#.utf8)
      let racing = ProjectBudgetStore(url: url, fileManager: BudgetReplacingCopyFileManager(replacement: external))
      #expect(throws: ProjectBudgetStorageIssue.changedOnDisk) { _ = try racing.restorePrevious() }
      #expect(try Data(contentsOf: url) == external)
      let copies = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.contains(".damaged-") }
      #expect(copies.count == 1)
      #expect(try Data(contentsOf: #require(copies.first)) == original)
    }
  }
}

private final class BudgetPreservationFailureFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
  override func moveItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class BudgetIncorrectCopyFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { try Data("incorrect".utf8).write(to: dstURL) }
}

private final class BudgetReplacingCopyFileManager: FileManager, @unchecked Sendable {
  let replacement: Data
  init(replacement: Data) { self.replacement = replacement; super.init() }
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try super.copyItem(at: srcURL, to: dstURL)
    try replacement.write(to: srcURL, options: .atomic)
  }
}
