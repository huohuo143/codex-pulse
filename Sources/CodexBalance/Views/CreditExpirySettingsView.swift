import CodexBalanceCore
import SwiftUI

struct CreditExpiryEditorState {
  var selectedID = ""
  var draftID = UUID().uuidString
  var date = Date()
  var title = ""
  var credits = ""
  var source = ""
  var note = ""
  var basis = CreditExpiryBasis.explicitDate
  var confirmed = false
  var activeAccount: String?
  var validationMessage: String?
  private var loadedValues: [String]?
  private var loadedBatch: CreditExpiryBatch?

  private var editableValues: [String] {
    [selectedID, CreditExpiryBatch.dateString(date), title, credits, source, note, basis.rawValue, String(confirmed)]
  }

  var hasUnsavedChanges: Bool {
    loadedValues.map { $0 != editableValues }
      ?? (!title.isEmpty || !credits.isEmpty || !source.isEmpty || !note.isEmpty || confirmed)
  }

  mutating func select(_ batch: CreditExpiryBatch?, account: String?) {
    guard let batch else {
      self = Self(); activeAccount = account; loadedValues = editableValues
      return
    }
    activeAccount = account
    selectedID = batch.id
    draftID = batch.id
    date = CreditExpiryBatch.localDate(batch.expiryDate) ?? batch.record.expiresAt
    title = batch.title
    // %g truncates to six significant digits, which changes an existing amount
    // when only its note or date is edited. Keep the full round-trip value.
    credits = batch.grantedCredits.map { String($0) } ?? ""
    source = batch.record.source
    note = batch.note
    basis = batch.basis
    confirmed = batch.record.isConfirmed(for: account)
    validationMessage = nil
    loadedValues = editableValues
    loadedBatch = batch
  }

  mutating func accountDidChange(_ account: String?) {
    activeAccount = account
    confirmed = false
    validationMessage = "账户已变化，输入已保留；请重新核对来源后确认。"
  }

  func makeBatch(existing: CreditExpiryBatch?) throws -> CreditExpiryBatch {
    let quantity = try CreditExpiryAmountInput.parse(credits)
    // Recovery can remove this record or restore older metadata. Keep the
    // metadata belonging to the draft that the user is still editing.
    let reference = loadedBatch ?? existing
    return CreditExpiryBatch(id: selectedID.isEmpty ? draftID : selectedID,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines), grantedCredits: quantity,
      grantedAmountUSD: reference?.grantedCredits == quantity ? reference?.grantedAmountUSD : nil,
      noticeAt: reference?.noticeAt, expiryDate: CreditExpiryBatch.dateString(date), basis: basis, note: note,
      record: CreditExpiryRecord(expiresAt: date, source: source))
  }

  mutating func finishSave(_ batch: CreditExpiryBatch, succeeded: Bool) {
    // Failed writes retain every field and the draft identity for a retry.
    guard succeeded else { return }
    select(batch, account: activeAccount)
  }

  mutating func receiveReloadedLedger(_ ledger: CreditExpiryLedger) {
    guard !hasUnsavedChanges else {
      // Recovery may restore an older document that does not contain this draft.
      // Keep the draft and its identity, rather than discarding unsaved work.
      if !selectedID.isEmpty, !ledger.batches.contains(where: { $0.id == selectedID }) {
        draftID = selectedID
        selectedID = ""
      }
      return
    }
    select(ledger.batches.first { $0.id == selectedID } ?? ledger.batches.first, account: activeAccount)
  }
}

struct CreditExpirySettingsView: View {
  let ledger: CreditExpiryLedger
  let account: String?
  let message: String?
  let isSaving: Bool
  let storageIssue: CreditExpiryStorageError?
  let recovery: CreditExpiryRecovery?
  let reload: () async -> CreditExpiryLedger?
  let restore: () async -> CreditExpiryLedger?
  let openFolder: () -> Void
  let save: (CreditExpiryBatch, Bool) async -> CreditExpiryBatch?
  @State private var form = CreditExpiryEditorState()
  @State private var isSubmitting = false

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("灵活额度到期记录").font(.headline)
        Text(ledger.label(account: account)).font(.caption).foregroundStyle(DashboardColors.subtleText)
        if let storageIssue {
          VStack(alignment: .leading, spacing: 8) {
            Label(storageIssue.localizedDescription, systemImage: "exclamationmark.triangle.fill")
              .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let recovery {
              Text("可恢复 \(recovery.batchCount) 笔记录"
                + (recovery.backedUpAt.map { " · 备份于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                .font(.caption)
            }
            HStack {
              Button("重新读取") { loadRecords(recover: false) }
              if recovery != nil { Button("恢复上次有效记录") { loadRecords(recover: true) } }
              Button("打开记录文件夹", action: openFolder)
            }
            .disabled(isSaving || isSubmitting)
          }
        }
        Group {
          Picker("选择记录", selection: Binding(
            get: { form.selectedID },
            set: { id in form.select(ledger.batches.first { $0.id == id }, account: account) }
          )) {
            ForEach(ledger.batches) { batch in
              Text("\(batch.title) · \(batch.expiryDate)").tag(batch.id)
            }
            Text("新增一笔额度").tag("")
          }
          TextField("额度名称", text: $form.title)
          TextField("原发放 credits 数量（可留空）", text: $form.credits)
          DatePicker("到期日期", selection: $form.date, displayedComponents: .date)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
          Picker("日期依据", selection: $form.basis) {
            ForEach(CreditExpiryBasis.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          TextField("来源：例如官方邮件日期、主题或购买凭据", text: $form.source)
          TextField("说明：例如实际发放日期尚未核实", text: $form.note)
          Toggle("已核对来源，适用于当前账户", isOn: $form.confirmed)
            .disabled(account?.isEmpty != false)
        }
        .disabled(isSaving || isSubmitting || storageIssue != nil)
        Text("每笔额度单独保存；账户变化后需要重新核对。推算日期不等同于官方明确的到期日，原发放数量不等于当前剩余量。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
        Button(isSaving || isSubmitting ? "正在处理…" : "保存这一笔记录") { saveSelected() }
          .disabled(isSaving || isSubmitting || storageIssue != nil)
        if form.hasUnsavedChanges { Text("当前输入尚未保存").font(.caption).foregroundStyle(DashboardColors.subtleText) }
        if let feedback = form.validationMessage ?? message {
          Text(feedback).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear {
      form.select(ledger.confirmedBatches(for: account).first ?? ledger.batches.first, account: account)
    }
    // Only a user picker change reloads a record. Observing selectedID here
    // would also reload a successful insert from the previous ledger snapshot.
    .onChange(of: account) { form.accountDidChange($0) }
  }

  private func saveSelected() {
    guard !isSubmitting, !isSaving, storageIssue == nil else { return }
    do {
      let batch = try form.makeBatch(existing: ledger.batches.first { $0.id == form.selectedID })
      let confirmed = form.confirmed
      form.validationMessage = nil
      isSubmitting = true
      Task { @MainActor in
        defer { isSubmitting = false }
        if let persisted = await save(batch, confirmed) {
          form.finishSave(persisted, succeeded: true)
        }
      }
    } catch {
      form.validationMessage = error.localizedDescription
    }
  }

  private func loadRecords(recover: Bool) {
    guard !isSubmitting, !isSaving else { return }
    form.validationMessage = nil
    isSubmitting = true
    Task { @MainActor in
      defer { isSubmitting = false }
      let ledger = recover ? await restore() : await reload()
      if let ledger { form.receiveReloadedLedger(ledger) }
    }
  }
}
