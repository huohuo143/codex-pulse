import CodexBalanceCore
import SwiftUI

struct CreditExpirySettingsView: View {
  let record: CreditExpiryRecord
  let account: String?
  let message: String?
  let save: (Date, String, Bool) -> Void
  @State private var date = Date()
  @State private var source = ""
  @State private var confirmed = false

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("灵活额度到期记录").font(.headline)
        Text(record.label(account: account)).font(.caption).foregroundStyle(DashboardColors.subtleText)
        DatePicker("到期日期", selection: $date, displayedComponents: .date)
        TextField("来源：例如购买凭据或官方到期页面", text: $source)
        Toggle("已核对来源，确认适用于当前账户", isOn: $confirmed)
          .disabled(account == nil)
        Text("旧版本日期仅保留为历史记录。账户变化后需要重新确认；记录保存在本机。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
        HStack {
          Button("保存到期记录") { save(date, source, confirmed) }
          if let message { Text(message).font(.caption) }
        }
      }
    }
    .onAppear { load() }
    .onChange(of: account) { _ in load() }
  }

  private func load() {
    date = record.expiresAt; source = record.source; confirmed = record.isConfirmed(for: account)
  }
}
