import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Separate flexible credit grants")
struct CreditExpiryLedgerTests {
  @Test func legacyMigrationPreservesOriginalAndNeverConfirmsAnUnknownDate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = CreditExpiryStore(url: root.appendingPathComponent("v1.json"))
    try legacy.save(CreditExpiryRecord(expiresAt: CreditExpiryBatch.localDate("2027-07-21")!, source: "旧版本历史记录，待核实"))
    let original = try Data(contentsOf: legacy.url)
    let store = CreditExpiryLedgerStore(url: root.appendingPathComponent("v2.json"), legacyURL: legacy.url)
    var ledger = store.load()
    #expect(ledger.batches.count == 1)
    #expect(ledger.confirmedBatches(for: "account-a").isEmpty)
    ledger.upsert(batch(id: "september", date: "2026-12-31", credits: 62_500))
    ledger.upsert(batch(id: "july", date: "2027-07-24", credits: 2_500, basis: .oneYearFromNotice))
    try store.save(ledger)
    #expect(try Data(contentsOf: legacy.url) == original)
    #expect(store.load() == ledger)
    #expect(store.load().confirmedBatches(for: "account-a").map(\.expiryDate) == ["2026-12-31", "2027-07-24"])
    #expect(store.load().confirmedBatches(for: "account-b").isEmpty)
    #expect(store.load().confirmedBatches(for: nil).isEmpty)
    #expect(store.load().label(account: "account-a").contains("含推算"))
  }

  @Test func editingOneGrantKeepsTheOtherAndEstimatedDatesStayOutOfOfficialExpiry() {
    let september = batch(id: "september", date: "2026-12-31", credits: 62_500)
    var july = batch(id: "july", date: "2027-07-24", credits: 2_500, basis: .oneYearFromNotice)
    var ledger = CreditExpiryLedger(batches: [july, september])
    july.expiryDate = "2026-11-30"
    july.record.expiresAt = CreditExpiryBatch.localDate(july.expiryDate)!
    ledger.upsert(july)
    #expect(ledger.batches.count == 2)
    #expect(ledger.batches.first { $0.id == "september" } == september)
    #expect(ledger.nextExplicitExpiry(for: "account-a", now: CreditExpiryBatch.localDate("2026-10-08")!) == CreditExpiryBatch.localDate("2026-12-31"))
    #expect(ledger.nextExplicitExpiry(for: "account-a", now: CreditExpiryBatch.localDate("2027-01-01")!) == nil)
    #expect(july.expiryLabel.contains("推算"))
    #expect(september.grantLabel == "原发放 62,500 credits")
  }

  @Test func dateOnlyEvidenceKeepsTheCivilDayAndRejectsImpossibleDates() {
    let date = CreditExpiryBatch.localDate("2026-12-31")!
    #expect(CreditExpiryBatch.dateString(date) == "2026-12-31")
    #expect(CreditExpiryBatch.dateString(date.addingTimeInterval(20 * 3600)) == "2026-12-31")
    #expect(CreditExpiryBatch.localDate("2027-02-29") == nil)
    #expect(CreditExpiryBatch.localDate("2026-13-01") == nil)
    #expect(CreditExpiryBatch.localDate("2026-7-24") == nil)
  }

  private func batch(id: String, date: String, credits: Double, basis: CreditExpiryBasis = .explicitDate) -> CreditExpiryBatch {
    CreditExpiryBatch(id: id, title: id, grantedCredits: credits, expiryDate: date, basis: basis,
      record: CreditExpiryRecord(expiresAt: CreditExpiryBatch.localDate(date)!, source: "官方邮件",
        confirmedAt: Date(), accountScope: "account-a"))
  }
}
