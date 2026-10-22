import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Credit record health accuracy")
struct CreditExpiryHealthTests {
  @Test func futureBackupCannotBeReplacedBySavingCurrentRecord() throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger)
    let primary = try Data(contentsOf: fixture.store.url)
    let future = Data(#"{"schemaVersion":99,"futureBackup":"preserve"}"#.utf8)
    try future.write(to: fixture.store.previousURL)
    #expect(fixture.store.loadResult().issue == .unsupportedBackupVersion(99))
    #expect(fixture.store.loadResult().ledger == fixture.ledger)
    #expect(fixture.check().level == .critical)
    #expect(fixture.check().detail.contains("备份使用暂不支持的版本"))
    #expect(throws: CreditExpiryStorageError.unsupportedBackupVersion(99)) { try fixture.store.save(.init()) }
    #expect(try Data(contentsOf: fixture.store.url) == primary)
    #expect(try Data(contentsOf: fixture.store.previousURL) == future)
  }

  @Test func unconfiguredRecordsAreHealthyWithoutCreatingFiles() throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    let check = fixture.check()
    #expect(check.level == .healthy)
    #expect(check.detail == "尚未设置到期记录")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
  }

  @Test(arguments: ["legacy", "current", "empty"])
  func validFormatsRemainReadOnlyAndDoNotConfirmSources(kind: String) throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    if kind == "legacy" {
      try JSONEncoder().encode(fixture.ledger.batches[0].record).write(to: fixture.store.legacyURL)
    } else {
      try JSONEncoder().encode(kind == "empty" ? CreditExpiryLedger() : fixture.ledger).write(to: fixture.store.url)
    }
    let before = try fixture.fingerprint()
    let check = fixture.check()
    #expect(check.level == .healthy)
    if kind != "empty" { #expect(check.detail.contains("到期日来源需自行核实")) }
    #expect(try fixture.fingerprint() == before)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.previousURL.path))
  }

  @Test(arguments: ["corrupt", "future", "missing-primary", "invalid-legacy", "primary-link",
    "backup-link", "oversized-legacy", "orphan-corrupt-backup", "primary-pipe"])
  func recordProblemsAreCriticalAndChecksDoNotChangeAnyFiles(kind: String) throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    switch kind {
    case "corrupt": try Data("{keep damaged original".utf8).write(to: fixture.store.url)
    case "future": try Data(#"{"schemaVersion":99,"future":[]}"#.utf8).write(to: fixture.store.url)
    case "missing-primary": try JSONEncoder().encode(fixture.ledger).write(to: fixture.store.previousURL)
    case "invalid-legacy": try Data("{broken old record".utf8).write(to: fixture.store.legacyURL)
    case "primary-link":
      try FileManager.default.createSymbolicLink(atPath: fixture.store.url.path, withDestinationPath: "missing.json")
    case "backup-link":
      try JSONEncoder().encode(fixture.ledger).write(to: fixture.store.url)
      try FileManager.default.createSymbolicLink(atPath: fixture.store.previousURL.path, withDestinationPath: "missing.json")
    case "oversized-legacy": try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: fixture.store.legacyURL)
    case "orphan-corrupt-backup": try Data("{broken only copy".utf8).write(to: fixture.store.previousURL)
    default: #expect(mkfifo(fixture.store.url.path, 0o600) == 0)
    }
    let before = try fixture.fingerprint()
    let result = fixture.audit()
    #expect(result.checks.first { $0.id == .creditExpiry }?.level == .critical)
    #expect(result.overall == .critical)
    #expect(try fixture.fingerprint() == before)
  }

  @Test func corruptBackupWarnsWhileValidPrimaryCanRepairItOnSave() throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger)
    try Data("{damaged old backup".utf8).write(to: fixture.store.previousURL)
    let before = try fixture.fingerprint()
    let read = fixture.store.loadResult()
    #expect(read.issue == nil)
    #expect(read.backupIssue == .invalidRecord)
    #expect(read.ledger == fixture.ledger)
    #expect(fixture.check().level == .warning)
    #expect(fixture.check().detail.contains("备份已损坏"))
    #expect(try fixture.fingerprint() == before)
    let primaryBeforeRepair = try Data(contentsOf: fixture.store.url)
    try fixture.store.save(fixture.ledger)
    #expect(fixture.check().level == .healthy)
    #expect(fixture.store.loadResult().backupIssue == nil)
    // JSON key order may differ on re-encoding; the backup must preserve the
    // actual previous bytes while the current record retains the same ledger.
    #expect(try Data(contentsOf: fixture.store.previousURL) == primaryBeforeRepair)
    #expect(fixture.store.loadResult().ledger == fixture.ledger)
  }

  @Test(arguments: [false, true])
  func readableDiskDoesNotHideUnresolvedUIOrWriteState(writeFailed: Bool) throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    try fixture.store.save(fixture.ledger)
    let before = try fixture.fingerprint()
    let result = fixture.audit(issue: writeFailed ? nil : .unreadableRecord, writeFailed: writeFailed)
    let check = try #require(result.checks.first { $0.id == .creditExpiry })
    #expect(check.level == .warning)
    #expect(check.detail.contains(writeFailed ? "写入未完成" : "重新读取"))
    #expect(try fixture.fingerprint() == before)
  }

  @Test func diagnosticIncludesRecordHealthWithoutRecordContentsOrPaths() throws {
    let fixture = try CreditHealthFixture()
    defer { fixture.clean() }
    var ledger = fixture.ledger
    ledger.batches[0].note = "private-note-should-not-export"
    ledger.batches[0].record.accountScope = "private-account-should-not-export"
    try fixture.store.save(ledger)
    for badBackup in [false, true] {
      if badBackup { try Data("{private-corrupt-contents".utf8).write(to: fixture.store.previousURL) }
      let report = ReliabilityReportBuilder.diagnosticMarkdown(appVersion: "test", snapshot: fixture.audit(), recentEvents: [])
      #expect(report.contains("到期记录文件"))
      for secret in [fixture.root.path, ledger.batches[0].id, ledger.batches[0].title,
        ledger.batches[0].record.source, ledger.batches[0].note, "private-account-should-not-export", "private-corrupt-contents"] {
        #expect(!report.contains(secret))
      }
    }
  }
}

private struct CreditHealthFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var store: CreditExpiryLedgerStore {
    .init(url: root.appendingPathComponent("credits-v2.json"), legacyURL: root.appendingPathComponent("credits-v1.json"))
  }
  var ledger: CreditExpiryLedger {
    .init(batches: [.init(id: "health-test", title: "Synthetic record", expiryDate: "2027-07-24",
      record: .init(expiresAt: CreditExpiryBatch.localDate("2027-07-24")!, source: "Synthetic source"))])
  }
  func audit(issue: CreditExpiryStorageError? = nil, writeFailed: Bool = false) -> ReliabilitySnapshot {
    ReliabilityAuditor.audit(inputs: .init(lastQuotaRefresh: nil, hasOfficialQuota: false, lastUsageRefresh: nil,
      usageSampleCount: 0, radarUpdatedAt: nil, launchWatcherEnabled: false,
      quotaHistoryURL: root.appendingPathComponent("history.json"), projectBudgetsURL: root.appendingPathComponent("budgets.json"),
      widgetSnapshotURL: root.appendingPathComponent("widget.json"), creditExpiryStore: store,
      creditExpiryStorageIssue: issue, creditExpiryWriteFailed: writeFailed))
  }
  func check() -> ReliabilityCheck { audit().checks.first { $0.id == .creditExpiry }! }
  func fingerprint() throws -> [String: String] {
    var result: [String: String] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
      let url = root.appendingPathComponent(name)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileReadUnknown) }
      let type = metadata.st_mode & S_IFMT
      if type == S_IFREG { result[name] = SHA256.hash(data: try Data(contentsOf: url)).description }
      else if type == S_IFLNK { result[name] = try FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
      else { result[name] = "\(type):\(metadata.st_ino)" }
    }
    return result
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}
