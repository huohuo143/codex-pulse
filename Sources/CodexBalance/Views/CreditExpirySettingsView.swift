import CodexBalanceCore
import SwiftUI

struct CreditExpirySettingsView: View {
  let ledger: CreditExpiryLedger
  let account: String?
  let message: String?
  let save: (CreditExpiryBatch, Bool) -> Void
  @State private var selectedID = ""
  @State private var date = Date()
  @State private var title = ""
  @State private var credits = ""
  @State private var source = ""
  @State private var note = ""
  @State private var basis = CreditExpiryBasis.explicitDate
  @State private var confirmed = false

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("灵活额度到期记录").font(.headline)
        Text(ledger.label(account: account)).font(.caption).foregroundStyle(DashboardColors.subtleText)
        Picker("选择记录", selection: $selectedID) {
          ForEach(ledger.batches) { batch in
            Text("\(batch.title) · \(batch.expiryDate)").tag(batch.id)
          }
          Text("新增一笔额度").tag("")
        }
        TextField("额度名称", text: $title)
        TextField("原发放 credits 数量（可留空）", text: $credits)
        DatePicker("到期日期", selection: $date, displayedComponents: .date)
        Picker("日期依据", selection: $basis) {
          ForEach(CreditExpiryBasis.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField("来源：例如官方邮件日期、主题或购买凭据", text: $source)
        TextField("说明：例如实际发放日期尚未核实", text: $note)
        Toggle("已核对来源，适用于当前账户", isOn: $confirmed)
          .disabled(account == nil)
        Text("每笔额度单独保存；账户变化后需要重新核对。推算日期不等同于官方明确的到期日，原发放数量不等于当前剩余量。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
        HStack {
          Button("保存这一笔记录") { saveSelected() }
          if let message { Text(message).font(.caption) }
        }
      }
    }
    .onAppear {
      selectedID = ledger.confirmedBatches(for: account).first?.id ?? ledger.batches.first?.id ?? ""
      loadSelected()
    }
    .onChange(of: selectedID) { _ in loadSelected() }
    .onChange(of: account) { _ in loadSelected() }
    .onChange(of: ledger) { _ in
      if selectedID.isEmpty { selectedID = ledger.batches.last?.id ?? "" }
      loadSelected()
    }
  }

  private var selected: CreditExpiryBatch? { ledger.batches.first { $0.id == selectedID } }

  private func loadSelected() {
    guard let batch = selected else {
      date = Date(); title = ""; credits = ""; source = ""; note = ""
      basis = .explicitDate; confirmed = false
      return
    }
    date = CreditExpiryBatch.localDate(batch.expiryDate) ?? batch.record.expiresAt
    title = batch.title
    credits = batch.grantedCredits.map { String(format: "%g", $0) } ?? ""
    source = batch.record.source; note = batch.note; basis = batch.basis
    confirmed = batch.record.isConfirmed(for: account)
  }

  private func saveSelected() {
    let text = credits.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
    // Invalid nonempty input reaches the store's validation rather than becoming an unknown amount.
    let quantity = text.isEmpty ? nil : Double(text) ?? .nan
    let old = selected
    let batch = CreditExpiryBatch(id: old?.id ?? UUID().uuidString,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines), grantedCredits: quantity,
      grantedAmountUSD: old?.grantedCredits == quantity ? old?.grantedAmountUSD : nil,
      noticeAt: old?.noticeAt, expiryDate: CreditExpiryBatch.dateString(date), basis: basis, note: note,
      record: CreditExpiryRecord(expiresAt: date, source: source))
    save(batch, confirmed)
  }
}
