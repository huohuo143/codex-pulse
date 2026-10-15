import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Credit record preservation and explicit recovery")
struct CreditExpiryRecoveryTests {
  @Test func savesKeepThePreviousCommittedDocument() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    let first = fixture.ledger("first")
    try fixture.store.save(first)
    let original = try Data(contentsOf: fixture.store.url)
    #expect(try Data(contentsOf: fixture.store.previousURL) == original)
    let second = fixture.ledger("second")
    try fixture.store.save(second)
    #expect(fixture.store.load() == second)
    #expect(try Data(contentsOf: fixture.store.previousURL) == original)
    #expect(fixture.store.loadResult().issue == nil)
    #expect(throws: CreditExpiryStorageError.alreadyValid) { try fixture.store.restorePrevious() }
    #expect(fixture.store.load() == second)
  }

  @Test func corruptPrimaryNeverFallsBackToLegacyAndRecoveryPreservesOriginalBytes() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    let first = fixture.ledger("first")
    try fixture.store.save(first)
    try CreditExpiryStore(url: fixture.store.legacyURL).save(first.batches[0].record)
    let backup = try Data(contentsOf: fixture.store.previousURL)
    let broken = Data("{\"schemaVersion\":2,\"batches\":[incomplete".utf8)
    try broken.write(to: fixture.store.url)
    let read = fixture.store.loadResult()
    #expect(read.issue == .invalidRecord)
    #expect(read.ledger.batches.isEmpty)
    #expect(read.recovery?.batchCount == 1)
    #expect(throws: CreditExpiryStorageError.invalidRecord) { try fixture.store.save(fixture.ledger("new")) }
    #expect(try Data(contentsOf: fixture.store.url) == broken)
    #expect(try Data(contentsOf: fixture.store.previousURL) == backup)
    let restored = try fixture.store.restorePrevious()
    let preserved = try #require(restored.preservedOriginalURL)
    #expect(try Data(contentsOf: preserved) == broken)
    #expect(restored.ledger == first)
    #expect(fixture.store.load() == first)
    #expect(try Data(contentsOf: fixture.store.previousURL) == backup)
    try fixture.store.save(fixture.ledger("retry"))
    #expect(fixture.store.load().batches[0].id == "retry")
    #expect(try Data(contentsOf: preserved) == broken)
  }

  @Test func missingPrimaryRequiresExplicitRecoveryBeforeSaving() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    let ledger = fixture.ledger("recoverable")
    try fixture.store.save(ledger)
    try FileManager.default.removeItem(at: fixture.store.url)
    #expect(fixture.store.loadResult().issue == .missingRecord)
    #expect(throws: CreditExpiryStorageError.missingRecord) { try fixture.store.save(fixture.ledger("new")) }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    let result = try fixture.store.restorePrevious()
    #expect(result.preservedOriginalURL == nil)
    #expect(result.ledger == ledger)
    #expect(fixture.store.loadResult().issue == nil)
  }

  @Test func unreadablePrimaryAndInvalidBackupCannotBeReplaced() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger("existing"))
    try FileManager.default.removeItem(at: fixture.store.url)
    try FileManager.default.createDirectory(at: fixture.store.url, withIntermediateDirectories: false)
    #expect(fixture.store.loadResult().issue == .unreadableRecord)
    #expect(fixture.store.loadResult().recovery == nil)
    #expect(throws: CreditExpiryStorageError.unreadableRecord) { try fixture.store.restorePrevious() }
    try FileManager.default.removeItem(at: fixture.store.url)
    let brokenBackup = Data("unreadable backup".utf8)
    try brokenBackup.write(to: fixture.store.previousURL)
    #expect(fixture.store.loadResult().issue == .noValidBackup)
    #expect(throws: CreditExpiryStorageError.noValidBackup) { try fixture.store.save(fixture.ledger("new")) }
    #expect(throws: CreditExpiryStorageError.noValidBackup) { try fixture.store.restorePrevious() }
    #expect(try Data(contentsOf: fixture.store.previousURL) == brokenBackup)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
  }

  @Test func futurePrimaryIsNeverDowngradedToAnOlderBackup() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger("old"))
    let future = Data("{\"schemaVersion\":99,\"newRecordType\":\"preserve\"}".utf8)
    try future.write(to: fixture.store.url)
    #expect(fixture.store.loadResult().issue == .unsupportedVersion(99))
    #expect(fixture.store.loadResult().recovery == nil)
    #expect(throws: CreditExpiryStorageError.unsupportedVersion(99)) { try fixture.store.save(fixture.ledger("new")) }
    #expect(throws: CreditExpiryStorageError.unsupportedVersion(99)) { try fixture.store.restorePrevious() }
    #expect(try Data(contentsOf: fixture.store.url) == future)
  }

  @Test func invalidDocumentsAreRejectedWithoutChangingEitherCopy() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    let valid = fixture.ledger("existing")
    try fixture.store.save(valid)
    let original = try Data(contentsOf: fixture.store.url)
    var duplicate = valid; duplicate.batches.append(valid.batches[0])
    var impossibleDate = valid; impossibleDate.batches[0].expiryDate = "2027-02-29"
    var negativeQuantity = valid; negativeQuantity.batches[0].grantedCredits = -1
    var emptyName = valid; emptyName.batches[0].title = "  "
    var infiniteQuantity = valid; infiniteQuantity.batches[0].grantedCredits = .infinity
    for invalid in [duplicate, impossibleDate, negativeQuantity, emptyName, infiniteQuantity] {
      #expect(throws: CreditExpiryStorageError.invalidRecord) { try fixture.store.save(invalid) }
      #expect(try Data(contentsOf: fixture.store.url) == original)
      #expect(try Data(contentsOf: fixture.store.previousURL) == original)
    }
    // A structurally decodable but semantically corrupt file is also blocked.
    try JSONEncoder().encode(duplicate).write(to: fixture.store.url)
    #expect(fixture.store.loadResult().issue == .invalidRecord)
  }

  @Test func backupWriteFailureLeavesCurrentDocumentUntouched() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    let initial = fixture.ledger("existing")
    try fixture.store.save(initial)
    let original = try Data(contentsOf: fixture.store.url)
    try FileManager.default.removeItem(at: fixture.store.previousURL)
    try FileManager.default.createDirectory(at: fixture.store.previousURL, withIntermediateDirectories: false)
    let sentinel = fixture.store.previousURL.appendingPathComponent("keep")
    try Data("preserve".utf8).write(to: sentinel)
    #expect(throws: (any Error).self) { try fixture.store.save(fixture.ledger("new")) }
    #expect(try Data(contentsOf: fixture.store.url) == original)
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
  }

  @Test func corruptLegacyIsNotSilentlyMigrated() throws {
    let fixture = RecoveryFixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let original = Data("truncated legacy".utf8)
    try original.write(to: fixture.store.legacyURL)
    #expect(fixture.store.loadResult().issue == .invalidLegacyRecord)
    #expect(throws: CreditExpiryStorageError.invalidLegacyRecord) { try fixture.store.save(fixture.ledger("new")) }
    #expect(try Data(contentsOf: fixture.store.legacyURL) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
  }
}

private struct RecoveryFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var store: CreditExpiryLedgerStore {
    .init(url: root.appendingPathComponent("credits-v2.json"), legacyURL: root.appendingPathComponent("credits-v1.json"))
  }
  func ledger(_ id: String) -> CreditExpiryLedger {
    .init(batches: [.init(id: id, title: id, grantedCredits: 1234.56789, expiryDate: "2027-07-24",
      record: .init(expiresAt: CreditExpiryBatch.localDate("2027-07-24")!, source: "Synthetic test record"))])
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}
