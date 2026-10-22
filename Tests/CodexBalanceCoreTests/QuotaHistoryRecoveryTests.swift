import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Quota history recovery")
struct QuotaHistoryRecoveryTests {
  private func withHistory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.appendingPathComponent("quota-history.json"))
  }

  @discardableResult
  private func record(_ store: QuotaHistoryStore, at now: Date = Date()) -> [QuotaSnapshot] {
    store.record(window: .init(usedPercent: 20, remainingPercent: 80, windowMinutes: 10080,
      resetsAt: now.addingTimeInterval(86400)), at: now, now: now)
  }

  @Test func repeatedCorruptionPreservesEveryOriginal() throws {
    try withHistory { url in
      let originals = [Data("{first broken record".utf8), Data("{second broken record".utf8)]
      for original in originals {
        try original.write(to: url)
        #expect(record(QuotaHistoryStore(url: url)).count == 1)
      }
      let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
        includingPropertiesForKeys: nil).filter { $0.lastPathComponent != url.lastPathComponent }
      #expect(backups.count == 2)
      let preserved = try backups.map { try Data(contentsOf: $0) }
      #expect(originals.allSatisfy(preserved.contains))
      #expect(QuotaHistoryStore(url: url).snapshots().count == 1)
    }
  }

  @Test func failedPreservationDoesNotOverwriteOriginal() throws {
    try withHistory { url in
      let original = Data("{irreplaceable damaged history".utf8)
      try original.write(to: url)
      let store = QuotaHistoryStore(url: url, fileManager: FailingHistoryBackupFileManager())
      #expect(record(store).count == 1)
      #expect(try Data(contentsOf: url) == original)
      #expect(store.storageIssue == .preservationFailed)
      #expect(store.preservedOriginalURL == nil)
    }
  }

  @Test(arguments: [#"{"schemaVersion":2,"snapshots":[]}"#,
    #"{"schemaVersion":2,"newStructure":{"value":42}}"#])
  func futureSchemaIsNeverReplaced(document: String) throws {
    try withHistory { url in
      let original = Data(document.utf8)
      try original.write(to: url)
      let store = QuotaHistoryStore(url: url)
      #expect(record(store).count == 1)
      #expect(try Data(contentsOf: url) == original)
      #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
      #expect(store.storageIssue == .unsupportedVersion(2))
    }
  }

  @Test func externalEditAfterLoadingIsPreserved() throws {
    try withHistory { url in
      let store = QuotaHistoryStore(url: url)
      #expect(store.snapshots().isEmpty)
      let original = Data(#"{"schemaVersion":2,"newStructure":[]}"#.utf8)
      try original.write(to: url)
      #expect(record(store).count == 1)
      #expect(try Data(contentsOf: url) == original)
      #expect(store.storageIssue == .changedOnDisk)
    }
  }

  @Test func symbolicLinkIsNotReplacedOrFollowed() throws {
    try withHistory { url in
      let target = url.deletingLastPathComponent().appendingPathComponent("other.json")
      let original = Data("{damaged unrelated file".utf8)
      try original.write(to: target)
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
      #expect(record(QuotaHistoryStore(url: url)).count == 1)
      #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == target.path)
      #expect(try Data(contentsOf: target) == original)
    }
  }

  @Test func legacyFixedNameBackupSurvivesNewRecovery() throws {
    try withHistory { url in
      let legacy = url.deletingPathExtension().appendingPathExtension("corrupt-(formatter.string(from: Date())).json")
      let previous = Data("{earlier original".utf8)
      try previous.write(to: legacy)
      let original = Data("{new original".utf8)
      try original.write(to: url)
      let store = QuotaHistoryStore(url: url)
      #expect(record(store).count == 1)
      let backup = try #require(store.preservedOriginalURL)
      #expect(backup != legacy)
      #expect(try Data(contentsOf: backup) == original)
      #expect(try Data(contentsOf: legacy) == previous)
      #expect(store.storageIssue == nil)
      #expect(store.storageMessage?.contains("独立备份") == true)
    }
  }

  @Test func failedBackupVerificationProtectsPrimary() throws {
    try withHistory { url in
      let original = Data("{original before incorrect copy".utf8)
      try original.write(to: url)
      let store = QuotaHistoryStore(url: url, fileManager: IncorrectHistoryBackupFileManager())
      #expect(record(store).count == 1)
      #expect(try Data(contentsOf: url) == original)
      #expect(store.storageIssue == .preservationFailed)
    }
  }

  @Test(arguments: [false, true])
  func identicalSampleRetriesAfterWriteFailure(withCorruptOriginal: Bool) throws {
    try withHistory { url in
      let original = Data("{retained during a write failure".utf8)
      if withCorruptOriginal { try original.write(to: url) }
      let store = QuotaHistoryStore(url: url, fileManager: FailFirstHistoryWriteFileManager())
      let now = Date()
      #expect(record(store, at: now).count == 1)
      #expect(store.storageIssue == .writeFailed)
      if withCorruptOriginal {
        #expect(try Data(contentsOf: url) == original)
        #expect(try Data(contentsOf: #require(store.preservedOriginalURL)) == original)
      } else {
        #expect(!FileManager.default.fileExists(atPath: url.path))
      }
      #expect(record(store, at: now).count == 1)
      #expect(store.storageIssue == nil)
      #expect(QuotaHistoryStore(url: url).snapshots().count == 1)
    }
  }

  @Test(arguments: ["directory", "fifo", "dangling-link", "oversized", "unreadable"])
  func unsafeOrUnreadableFileRemainsUntouched(kind: String) throws {
    try withHistory { url in
      switch kind {
      case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      case "fifo": #expect(mkfifo(url.path, 0o600) == 0)
      case "dangling-link": try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "missing.json")
      case "oversized": try Data(repeating: 0x7B, count: 8 * 1024 * 1024 + 1).write(to: url)
      default:
        try Data("{unreadable original".utf8).write(to: url)
        #expect(chmod(url.path, 0) == 0)
      }
      defer { if kind == "unreadable" { _ = chmod(url.path, 0o600) } }
      let before = try FileManager.default.attributesOfItem(atPath: url.path)
      let store = QuotaHistoryStore(url: url)
      #expect(record(store).count == 1)
      #expect(store.storageIssue == .unreadableHistory)
      #expect(store.preservedOriginalURL == nil)
      let after = try FileManager.default.attributesOfItem(atPath: url.path)
      #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
      #expect(before[.size] as? NSNumber == after[.size] as? NSNumber)
      #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }
  }

  @Test func validHistorySurvivesReloadAndLaterExternalReplacement() throws {
    try withHistory { url in
      let now = Date()
      let first = QuotaHistoryStore(url: url)
      #expect(record(first, at: now.addingTimeInterval(-600)).count == 1)
      let reloaded = QuotaHistoryStore(url: url)
      #expect(reloaded.snapshots().count == 1)
      #expect(record(reloaded, at: now).count == 2)
      #expect(QuotaHistoryStore(url: url).snapshots().count == 2)
      let external = Data("{external replacement".utf8)
      try external.write(to: url, options: .atomic)
      #expect(record(reloaded, at: now.addingTimeInterval(600)).count == 3)
      #expect(try Data(contentsOf: url) == external)
      #expect(reloaded.storageIssue == .changedOnDisk)
    }
  }
}

private final class FailingHistoryBackupFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
  override func moveItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class IncorrectHistoryBackupFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try Data("incorrect backup".utf8).write(to: dstURL)
  }
}

private final class FailFirstHistoryWriteFileManager: FileManager, @unchecked Sendable {
  private var shouldFail = true
  override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil) throws {
    if shouldFail { shouldFail = false; throw CocoaError(.fileWriteNoPermission) }
    try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
  }
}
