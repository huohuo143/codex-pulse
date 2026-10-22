import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Credit record file safety")
struct CreditExpiryFileSafetyTests {
  @Test(arguments: [false, true])
  func primaryLinksAreNeverReadOrReplaced(dangling: Bool) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    let target = fixture.root.appendingPathComponent("outside.json")
    let bytes = try JSONEncoder().encode(fixture.ledger)
    if !dangling { try bytes.write(to: target) }
    try FileManager.default.createSymbolicLink(at: fixture.store.url, withDestinationURL: target)
    let state = fixture.store.loadResult()
    #expect(state.issue == .unreadableRecord)
    #expect(state.ledger.batches.isEmpty)
    #expect(state.recovery == nil)
    #expect(throws: (any Error).self) { try fixture.store.save(fixture.ledger) }
    #expect(throws: (any Error).self) { _ = try fixture.store.restorePrevious() }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.url.path)) == target.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.previousURL.path))
    if !dangling { #expect(try Data(contentsOf: target) == bytes) }
    else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
  }

  @Test(arguments: [false, true])
  func backupLinksCannotBeUsedOrReplaced(dangling: Bool) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    let target = fixture.root.appendingPathComponent("outside.json")
    let bytes = try JSONEncoder().encode(fixture.ledger)
    if !dangling { try bytes.write(to: target) }
    try FileManager.default.createSymbolicLink(at: fixture.store.previousURL, withDestinationURL: target)
    #expect(fixture.store.loadResult().issue == .noValidBackup)
    #expect(fixture.store.loadResult().recovery == nil)
    #expect(throws: (any Error).self) { try fixture.store.save(fixture.ledger) }
    #expect(throws: (any Error).self) { _ = try fixture.store.restorePrevious() }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    try bytes.write(to: fixture.store.url)
    #expect(throws: (any Error).self) { try fixture.store.save(.init()) }
    #expect(try Data(contentsOf: fixture.store.url) == bytes)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.previousURL.path)) == target.path)
    if !dangling { #expect(try Data(contentsOf: target) == bytes) }
    else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
  }

  @Test(arguments: [false, true])
  func legacyLinksAreNeverMigrated(dangling: Bool) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    let target = fixture.root.appendingPathComponent("outside.json")
    let bytes = try JSONEncoder().encode(fixture.ledger.batches[0].record)
    if !dangling { try bytes.write(to: target) }
    try FileManager.default.createSymbolicLink(at: fixture.store.legacyURL, withDestinationURL: target)
    #expect(fixture.store.loadResult().issue == .invalidLegacyRecord)
    #expect(fixture.store.load().batches.isEmpty)
    #expect(throws: (any Error).self) { try fixture.store.save(fixture.ledger) }
    #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.legacyURL.path)) == target.path)
    if !dangling { #expect(try Data(contentsOf: target) == bytes) }
  }

  @Test(arguments: ["primary", "backup", "legacy"])
  func oversizedDocumentsAreRejected(location: String) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    let url = location == "primary" ? fixture.store.url
      : (location == "backup" ? fixture.store.previousURL : fixture.store.legacyURL)
    var bytes = location == "legacy" ? try JSONEncoder().encode(fixture.ledger.batches[0].record)
      : try JSONEncoder().encode(fixture.ledger)
    bytes.append(Data(repeating: 0x20, count: 8 * 1024 * 1024))
    try bytes.write(to: url)
    let expected: CreditExpiryStorageError = location == "primary" ? .unreadableRecord
      : (location == "backup" ? .noValidBackup : .invalidLegacyRecord)
    #expect(fixture.store.loadResult().issue == expected)
    #expect(fixture.store.loadResult().recovery == nil)
    #expect(throws: (any Error).self) { try fixture.store.save(.init()) }
    #expect(try Data(contentsOf: url) == bytes)
  }

  @Test(arguments: ["primary", "backup", "legacy"])
  func fifoDoesNotWaitForAWriter(location: String) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    let url = location == "primary" ? fixture.store.url
      : (location == "backup" ? fixture.store.previousURL : fixture.store.legacyURL)
    #expect(mkfifo(url.path, 0o600) == 0)
    let expected: CreditExpiryStorageError = location == "primary" ? .unreadableRecord
      : (location == "backup" ? .noValidBackup : .invalidLegacyRecord)
    #expect(fixture.store.loadResult().issue == expected)
    #expect(throws: (any Error).self) { try fixture.store.save(.init()) }
    if location != "legacy" {
      #expect(throws: (any Error).self) { _ = try fixture.store.restorePrevious() }
    }
    var metadata = stat()
    #expect(lstat(url.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFIFO)
  }

  @Test(arguments: ["link", "oversized", "future", "corrupt"])
  func invalidRecoverySourceNeverChangesDamagedPrimary(kind: String) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    let original = Data("{keep damaged original".utf8)
    try original.write(to: fixture.store.url)
    switch kind {
    case "link":
      let target = fixture.root.appendingPathComponent("outside.json")
      try JSONEncoder().encode(fixture.ledger).write(to: target)
      try FileManager.default.createSymbolicLink(at: fixture.store.previousURL, withDestinationURL: target)
    case "oversized":
      var bytes = try JSONEncoder().encode(fixture.ledger)
      bytes.append(Data(repeating: 0x20, count: 8 * 1024 * 1024))
      try bytes.write(to: fixture.store.previousURL)
    default:
      try Data((kind == "future" ? #"{"schemaVersion":99,"future":[]}"# : "{broken backup").utf8)
        .write(to: fixture.store.previousURL)
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
    let backup = try Data(contentsOf: fixture.store.previousURL)
    #expect(fixture.store.loadResult().issue == .invalidRecord)
    #expect(fixture.store.loadResult().recovery == nil)
    #expect(throws: CreditExpiryStorageError.noValidBackup) { _ = try fixture.store.restorePrevious() }
    #expect(try Data(contentsOf: fixture.store.url) == original)
    #expect(try Data(contentsOf: fixture.store.previousURL) == backup)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
  }

  @Test func oversizedSaveKeepsBothExistingCopies() throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger)
    let original = try Data(contentsOf: fixture.store.url)
    var large = fixture.ledger
    large.batches[0].note = String(repeating: "x", count: 8 * 1024 * 1024)
    #expect(throws: CreditExpiryStorageError.recordTooLarge) { try fixture.store.save(large) }
    #expect(try Data(contentsOf: fixture.store.url) == original)
    #expect(try Data(contentsOf: fixture.store.previousURL) == original)
    #expect(fixture.store.load() == fixture.ledger)
  }

  @Test(arguments: ["primary", "backup", "legacy"])
  func changedRecordDuringSaveIsPreserved(location: String) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    if location != "legacy" { try fixture.store.save(fixture.ledger) }
    else { try JSONEncoder().encode(fixture.ledger.batches[0].record).write(to: fixture.store.legacyURL) }
    let target = location == "primary" ? fixture.store.url
      : (location == "backup" ? fixture.store.previousURL : fixture.store.legacyURL)
    let replacement = Data("external replacement that must survive".utf8)
    let guarded = CreditExpiryLedgerStore(url: fixture.store.url, legacyURL: fixture.store.legacyURL) { _ in
      try replacement.write(to: target, options: .atomic)
    }
    #expect(throws: CreditExpiryStorageError.changedOnDisk) { try guarded.save(.init()) }
    #expect(try Data(contentsOf: target) == replacement)
    if location == "backup" { #expect(fixture.store.load() == fixture.ledger) }
    if location == "legacy" { #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path)) }
  }

  @Test(arguments: [false, true])
  func changedFileDuringRecoveryCannotBeOverwritten(changeBackup: Bool) throws {
    let fixture = try CreditFileFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger)
    let original = Data("{damaged original".utf8)
    try original.write(to: fixture.store.url)
    let target = changeBackup ? fixture.store.previousURL : fixture.store.url
    let replacement = Data(#"{"schemaVersion":99,"future":[]}"#.utf8)
    let guarded = CreditExpiryLedgerStore(url: fixture.store.url, legacyURL: fixture.store.legacyURL) { _ in
      try replacement.write(to: target, options: .atomic)
    }
    #expect(throws: CreditExpiryStorageError.changedOnDisk) { _ = try guarded.restorePrevious() }
    #expect(try Data(contentsOf: target) == replacement)
    if changeBackup { #expect(try Data(contentsOf: fixture.store.url) == original) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 2)
  }
}

private struct CreditFileFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var store: CreditExpiryLedgerStore {
    .init(url: root.appendingPathComponent("credits-v2.json"), legacyURL: root.appendingPathComponent("credits-v1.json"))
  }
  var ledger: CreditExpiryLedger {
    .init(batches: [.init(id: "synthetic", title: "Synthetic record", expiryDate: "2027-07-24",
      record: .init(expiresAt: CreditExpiryBatch.localDate("2027-07-24")!, source: "Synthetic source"))])
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}
