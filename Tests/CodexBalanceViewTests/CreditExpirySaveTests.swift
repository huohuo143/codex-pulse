import Foundation
import Testing
import CodexBalanceCore
@testable import CodexBalance

@MainActor @Suite("Credit grant save reliability", .serialized)
struct CreditExpirySaveTests {
  @Test func overlappingSaveIsRejectedAndRetryRetainsBothGrants() async throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    let gate = SuspendedCreditWrite()
    let first = Task { await store.saveCreditExpiry(batch: grant("first"), confirmed: false) { ledger in
      try await gate.write(ledger, to: fixture.storage)
    } }
    await gate.waitUntilStarted()
    #expect(store.isSavingCreditExpiry)
    #expect(store.creditExpiry.batches.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.storage.url.path))
    #expect(await store.saveCreditExpiry(batch: grant("second"), confirmed: false) == false)
    await gate.release()
    #expect(await first.value)
    #expect(!store.isSavingCreditExpiry)
    #expect(await store.saveCreditExpiry(batch: grant("second"), confirmed: false))
    #expect(fixture.storage.load().batches.map(\.id) == ["first", "second"])
    #expect(store.creditExpiry == fixture.storage.load())
  }

  @Test func writeFailureRetainsCommittedDataAndReleasesSaveForRetry() async throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    let initial = CreditExpiryLedger(batches: [grant("existing")])
    try fixture.storage.save(initial)
    let original = try Data(contentsOf: fixture.storage.url)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    let failed = await store.saveCreditExpiry(batch: grant("new"), confirmed: false) { _ in
      throw CocoaError(.fileWriteNoPermission)
    }
    #expect(!failed)
    #expect(!store.isSavingCreditExpiry)
    #expect(store.creditExpiry == initial)
    #expect(try Data(contentsOf: fixture.storage.url) == original)
    #expect(store.expiryMessage?.hasPrefix("记录保存失败：") == true)
    #expect(await store.saveCreditExpiry(batch: grant("new"), confirmed: false))
    #expect(fixture.storage.load().batches.count == 2)
    #expect(store.expiryMessage?.hasPrefix("已保存") == true)
  }

  @Test func realStorageFailureDoesNotReplaceTheLedger() async throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let blocker = fixture.root.appendingPathComponent("blocker")
    let sentinel = Data("retain".utf8)
    try sentinel.write(to: blocker)
    let storage = CreditExpiryLedgerStore(url: blocker.appendingPathComponent("credits.json"), legacyURL: fixture.storage.legacyURL)
    let store = DashboardStore(startServices: false, expiryStore: storage)
    #expect(await store.saveCreditExpiry(batch: grant("new"), confirmed: false) == false)
    #expect(store.creditExpiry.batches.isEmpty)
    #expect(!store.isSavingCreditExpiry)
    #expect(try Data(contentsOf: blocker) == sentinel)
  }

  @Test func accountSwitchDuringWriteKeepsOriginalConfirmationScope() async throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    store.status = CodexStatus(codexHome: "", sessionsRoot: "")
    store.status?.accountScope = "account-a"
    let gate = SuspendedCreditWrite()
    let task = Task { await store.saveCreditExpiry(batch: grant("confirmed"), confirmed: true) { ledger in
      try await gate.write(ledger, to: fixture.storage)
    } }
    await gate.waitUntilStarted()
    store.status?.accountScope = "account-b"
    await gate.release()
    #expect(await task.value)
    #expect(fixture.storage.load().confirmedBatches(for: "account-a").count == 1)
    #expect(store.creditExpiry.confirmedBatches(for: "account-b").isEmpty)
    #expect(store.expiryMessage?.contains("提交时的账户") == true)
  }

  @Test func invalidValuesAndEmptyAccountDoNotReachStorage() async {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    for quantity in [-1.0, 0.0, Double.nan, Double.infinity] {
      var batch = grant("invalid")
      batch.grantedCredits = quantity
      #expect(await store.saveCreditExpiry(batch: batch, confirmed: false) == false)
    }
    store.status = CodexStatus(codexHome: "", sessionsRoot: "")
    store.status?.accountScope = ""
    #expect(await store.saveCreditExpiry(batch: grant("invalid"), confirmed: true) == false)
    #expect(!FileManager.default.fileExists(atPath: fixture.storage.url.path))
  }

  @Test func failedSaveAndAccountSwitchRetainDraftAndStableIdentity() throws {
    var form = CreditExpiryEditorState()
    form.title = "未保存的额度"
    form.credits = "62,500.5"
    form.source = "核对用来源"
    form.note = "尚未提交的说明"
    form.confirmed = true
    let batch = try form.makeBatch(existing: nil)
    form.finishSave(batch, succeeded: false)
    form.accountDidChange("account-b")
    #expect(!form.confirmed)
    #expect(form.title == "未保存的额度")
    #expect(form.credits == "62,500.5")
    #expect(form.source == "核对用来源")
    #expect(form.note == "尚未提交的说明")
    #expect(try form.makeBatch(existing: nil).id == batch.id)
    var saved = batch
    saved.record.confirmedAt = Date()
    saved.record.accountScope = "account-a"
    form.finishSave(saved, succeeded: true)
    #expect(!form.confirmed)
    #expect(form.selectedID == batch.id)
    #expect(try form.makeBatch(existing: saved).id == batch.id)
  }

  @Test func editingOnlyTheNoteDoesNotRoundExistingQuantityOrLoseItsUSDValue() throws {
    var batch = grant("existing")
    batch.grantedCredits = 12345678.9012345
    batch.grantedAmountUSD = 500
    var form = CreditExpiryEditorState()
    form.select(batch, account: nil)
    form.note = "更新说明"
    let saved = try form.makeBatch(existing: batch)
    #expect(saved.grantedCredits == batch.grantedCredits)
    #expect(saved.grantedAmountUSD == 500)
    #expect(saved.note == "更新说明")
    form.credits = "1,5"
    #expect(throws: CreditExpiryAmountInput.ValidationError.self) { try form.makeBatch(existing: batch) }
    #expect(form.credits == "1,5")
  }

  @Test func backupIncludesBothGrantFormatsAndDetectsMissingReceipt() throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    let batch = grant("current")
    try fixture.storage.save(.init(batches: [batch]))
    try CreditExpiryStore(url: fixture.storage.legacyURL).save(batch.record)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    let historyURL = fixture.root.appendingPathComponent("quota-history-test.json")
    store.quotaHistoryStore = QuotaHistoryStore(url: historyURL)
    store.status = CodexStatus(codexHome: "", sessionsRoot: "")
    store.status?.accountScope = "account-a"
    let archiveRoot = fixture.root.appendingPathComponent("archive")
    let archive = LocalAutomationArchive(root: archiveRoot)
    let now = Date()
    #expect(store.shouldPerformAutomaticBackup(now: now, archive: archive))
    store.performLocalBackup(now: now, archive: archive)
    #expect(!store.shouldPerformAutomaticBackup(now: now, archive: archive))
    let files = try #require(FileManager.default.enumerator(at: archiveRoot, includingPropertiesForKeys: nil))
      .allObjects.compactMap { $0 as? URL }
    for source in [fixture.storage.url, fixture.storage.legacyURL, fixture.storage.previousURL] {
      let copy = try #require(files.first { $0.lastPathComponent == source.lastPathComponent })
      #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
    }
    let copy = try #require(files.first { $0.lastPathComponent == fixture.storage.url.lastPathComponent })
    try FileManager.default.removeItem(at: copy)
    #expect(store.shouldPerformAutomaticBackup(now: now, archive: archive))
  }

  @Test func diskCorruptionAfterLoadingBlocksSaveUntilExplicitRecovery() async throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    let initial = CreditExpiryLedger(batches: [grant("existing")])
    try fixture.storage.save(initial)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    let broken = Data("damaged after initial read".utf8)
    try broken.write(to: fixture.storage.url)
    #expect(await store.saveCreditExpiry(batch: grant("new"), confirmed: false) == false)
    #expect(store.creditExpiry == initial)
    #expect(store.creditExpiryStorageIssue == .invalidRecord)
    #expect(store.creditExpiryRecovery?.batchCount == 1)
    #expect(!store.isSavingCreditExpiry)
    #expect(await store.reloadCreditExpiry() == nil)
    #expect(try Data(contentsOf: fixture.storage.url) == broken)
    #expect(await store.restoreCreditExpiryBackup() == initial)
    #expect(store.creditExpiryStorageIssue == nil)
    #expect(store.creditExpiryRecovery == nil)
    #expect(await store.saveCreditExpiry(batch: grant("new"), confirmed: false))
    #expect(store.creditExpiry.batches.map(\.id) == ["existing", "new"])
    let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
    let preserved = try #require(files.first { $0.lastPathComponent.contains(".damaged-") })
    #expect(try Data(contentsOf: preserved) == broken)
  }

  @Test func initialUnreadableStateIsVisibleAndReloadCanClearIt() async throws {
    let fixture = CreditSaveFixture()
    defer { fixture.clean() }
    try fixture.storage.save(.init(batches: [grant("existing")]))
    let original = try Data(contentsOf: fixture.storage.url)
    try Data("corrupt".utf8).write(to: fixture.storage.url)
    let store = DashboardStore(startServices: false, expiryStore: fixture.storage)
    #expect(store.creditExpiryStorageIssue == .invalidRecord)
    #expect(store.creditExpiry.batches.isEmpty)
    #expect(await store.saveCreditExpiry(batch: grant("new"), confirmed: false) == false)
    try original.write(to: fixture.storage.url, options: .atomic)
    #expect(await store.reloadCreditExpiry()?.batches.map(\.id) == ["existing"])
    #expect(store.creditExpiryStorageIssue == nil)
    #expect(await store.saveCreditExpiry(batch: grant("new"), confirmed: false))
  }

  @Test func recoveryKeepsUnsavedDraftAndIdentityWhenOlderBackupLacksItsRecord() throws {
    var form = CreditExpiryEditorState()
    let existing = grant("recent")
    form.select(existing, account: nil)
    #expect(!form.hasUnsavedChanges)
    form.note = "retain this edit"
    form.credits = "123,456.789"
    #expect(form.hasUnsavedChanges)
    form.receiveReloadedLedger(.init(batches: [grant("older")]))
    #expect(form.selectedID.isEmpty)
    #expect(form.note == "retain this edit")
    #expect(form.credits == "123,456.789")
    let batch = try form.makeBatch(existing: nil)
    #expect(batch.id == existing.id)
    form.finishSave(batch, succeeded: true)
    #expect(!form.hasUnsavedChanges)
    #expect(form.selectedID == existing.id)
  }

  @Test func uneditedFormFollowsRestoredDocument() {
    var form = CreditExpiryEditorState()
    form.select(grant("recent"), account: nil)
    form.receiveReloadedLedger(.init(batches: [grant("older")]))
    #expect(form.selectedID == "older")
    #expect(!form.hasUnsavedChanges)
  }

  @Test func recoveredDraftKeepsMetadataEvenWhenBackupHasNoMatchingRecord() throws {
    var recent = grant("recent")
    recent.grantedAmountUSD = 500
    recent.noticeAt = Date(timeIntervalSince1970: 1_800_000_000)
    var form = CreditExpiryEditorState()
    form.select(recent, account: nil)
    form.note = "keep this draft and its receipt"
    form.receiveReloadedLedger(.init())
    let saved = try form.makeBatch(existing: nil)
    #expect(saved.id == recent.id)
    #expect(saved.grantedAmountUSD == 500)
    #expect(saved.noticeAt == recent.noticeAt)
    // An older record with the same identity must not replace the draft's receipt.
    var older = recent
    older.grantedCredits = 100
    older.grantedAmountUSD = 1
    #expect(try form.makeBatch(existing: older).grantedAmountUSD == 500)
    form.credits = "12"
    #expect(try form.makeBatch(existing: older).grantedAmountUSD == nil)
  }
}

private func grant(_ id: String) -> CreditExpiryBatch {
  CreditExpiryBatch(id: id, title: id, grantedCredits: 62500, expiryDate: "2027-07-24",
    record: CreditExpiryRecord(expiresAt: CreditExpiryBatch.localDate("2027-07-24")!, source: "Synthetic receipt"))
}

private struct CreditSaveFixture: Sendable {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var storage: CreditExpiryLedgerStore { .init(url: root.appendingPathComponent("credit-expiry-v2.json"), legacyURL: root.appendingPathComponent("credit-expiry-v1.json")) }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private actor SuspendedCreditWrite {
  private var pending: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  func write(_ ledger: CreditExpiryLedger, to storage: CreditExpiryLedgerStore) async throws {
    await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil }
    try storage.save(ledger)
  }
  func waitUntilStarted() async {
    if pending != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() { pending?.resume(); pending = nil }
}
