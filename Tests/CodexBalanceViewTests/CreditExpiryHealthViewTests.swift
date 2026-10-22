import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Credit record health feedback", .serialized)
struct CreditExpiryHealthViewTests {
  @Test func healthUsesTheInjectedRecordAndPreservesCorruptBytes() throws {
    let fixture = try CreditHealthViewFixture()
    defer { fixture.clean() }
    let damaged = Data("{synthetic damaged record".utf8)
    try damaged.write(to: fixture.storage.url)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    store.runReliabilityCheck(allowAutomation: false)
    let check = try #require(store.reliabilitySnapshot.checks.first { $0.id.rawValue == "creditExpiry" })
    #expect(check.level == .critical)
    #expect(check.detail.contains("格式无效"))
    #expect(try Data(contentsOf: fixture.storage.url) == damaged)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 1)
  }

  @Test func failedSaveImmediatelyUpdatesHealthAndSuccessfulReloadClearsIt() async throws {
    let fixture = try CreditHealthViewFixture()
    defer { fixture.clean() }
    try fixture.storage.save(fixture.ledger)
    let original = try Data(contentsOf: fixture.storage.url)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    try Data("{damaged after loading".utf8).write(to: fixture.storage.url)
    #expect(await store.saveCreditExpiry(batch: fixture.ledger.batches[0], confirmed: false) == false)
    #expect(store.reliabilitySnapshot.checks.first { $0.id.rawValue == "creditExpiry" }?.level == .critical)
    try original.write(to: fixture.storage.url)
    #expect(await store.reloadCreditExpiry() == fixture.ledger)
    #expect(store.reliabilitySnapshot.checks.first { $0.id.rawValue == "creditExpiry" }?.level == .healthy)
  }

  @Test func writeFailureRemainsVisibleAfterReloadUntilASaveCompletes() async throws {
    let fixture = try CreditHealthViewFixture()
    defer { fixture.clean() }
    try fixture.storage.save(fixture.ledger)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    #expect(await store.saveCreditExpiry(batch: fixture.ledger.batches[0], confirmed: false, persist: { _ in
      throw NSError(domain: "PrivateStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "/private/sensitive/path"])
    }) == false)
    #expect(store.creditExpiryWriteFailed)
    let check = try #require(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry })
    #expect(check.level == .warning)
    #expect(!check.detail.contains("/private/sensitive/path"))
    #expect(await store.reloadCreditExpiry() == fixture.ledger)
    #expect(store.creditExpiryWriteFailed)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .warning)
    #expect(await store.saveCreditExpiry(batch: fixture.ledger.batches[0], confirmed: false))
    #expect(!store.creditExpiryWriteFailed)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .healthy)
  }

  @Test func oversizedInputIsAnInputErrorNotARecordHealthFailure() async throws {
    let fixture = try CreditHealthViewFixture()
    defer { fixture.clean() }
    try fixture.storage.save(fixture.ledger)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    var draft = fixture.ledger.batches[0]
    draft.note = String(repeating: "x", count: 8 * 1024 * 1024)
    #expect(await store.saveCreditExpiry(batch: draft, confirmed: false) == false)
    #expect(!store.creditExpiryWriteFailed)
    #expect(store.creditExpiryStorageIssue == nil)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .healthy)
    #expect(fixture.storage.load() == fixture.ledger)
  }

  @Test func healthDoesNotSilentlyReloadTheEditorOrAutomaticallyRestoreRecords() async throws {
    let fixture = try CreditHealthViewFixture()
    defer { fixture.clean() }
    try fixture.storage.save(fixture.ledger)
    let original = try Data(contentsOf: fixture.storage.url)
    let damaged = Data("{synthetic damaged original".utf8)
    try damaged.write(to: fixture.storage.url)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    store.runReliabilityCheck(allowAutomation: false)
    let check = try #require(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry })
    store.automaticRecoveryAttempts = 0
    store.attemptAutomaticRecovery(snapshot: .init(checks: [check]), now: Date())
    #expect(store.automaticRecoveryAttempts == 0)
    #expect(try Data(contentsOf: fixture.storage.url) == damaged)
    try original.write(to: fixture.storage.url)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.creditExpiryStorageIssue == .invalidRecord)
    #expect(store.creditExpiry.batches.isEmpty)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .warning)
    #expect(await store.reloadCreditExpiry() == fixture.ledger)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .healthy)
  }

  @Test func explicitRestoreClearsCriticalHealthImmediately() async throws {
    let fixture = try CreditHealthViewFixture()
    defer { fixture.clean() }
    try fixture.storage.save(fixture.ledger)
    let damaged = Data("{synthetic damaged original".utf8)
    try damaged.write(to: fixture.storage.url)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    store.runReliabilityCheck(allowAutomation: false)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .critical)
    #expect(await store.restoreCreditExpiryBackup() == fixture.ledger)
    #expect(store.reliabilitySnapshot.checks.first { $0.id == .creditExpiry }?.level == .healthy)
    #expect(store.creditExpiryStorageIssue == nil)
    let copies = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.contains(".damaged-") }
    #expect(copies.count == 1)
    #expect(try Data(contentsOf: #require(copies.first)) == damaged)
  }
}

private struct CreditHealthViewFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  var storage: CreditExpiryLedgerStore {
    .init(url: root.appendingPathComponent("credits-v2.json"), legacyURL: root.appendingPathComponent("credits-v1.json"))
  }
  var ledger: CreditExpiryLedger {
    .init(batches: [.init(id: "health-test", title: "Synthetic record", expiryDate: "2027-07-24",
      record: .init(expiresAt: CreditExpiryBatch.localDate("2027-07-24")!, source: "Synthetic source"))])
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}
