import CodexBalanceCore
import SwiftUI

struct OpenAIAPIUsageCard: View {
  @ObservedObject private var api = OpenAIAPIUsageStore.shared

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Label("OpenAI API", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.system(size: 15, weight: .bold))
            Text("API 组织用量，与 Codex Credits 分开统计")
              .font(.caption).foregroundStyle(DashboardColors.subtleText)
          }
          Spacer()
          if api.isRefreshing { ProgressView().controlSize(.small) }
        }
        HStack(alignment: .top, spacing: 24) {
          value("本月 API 消费", api.costText, api.costDetail)
          value("API 赠额余额", api.grantText, api.grant.map {
            "手动确认 · " + $0.checkedAt.formatted(date: .abbreviated, time: .shortened)
          } ?? "尚未确认")
        }
        TimelineView(.periodic(from: .now, by: 60)) { context in
          if let expiry = api.grantExpiry {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: expiry.hasExpired(at: context.date) ? "exclamationmark.circle" : "calendar.badge.clock")
                .foregroundStyle(expiry.expiresAt.timeIntervalSince(context.date) <= 3 * 86400 ? Color.orange : DashboardColors.subtleText)
              VStack(alignment: .leading, spacing: 3) {
                Text("账单到期 · \(expiry.longDate)").font(.caption.weight(.semibold))
                Text(expiry.hasExpired(at: context.date) ? "已到期，请核对新周期赠额" : "距到期 \(expiry.countdown(at: context.date))")
                  .font(.caption2)
                  .foregroundStyle(expiry.expiresAt.timeIntervalSince(context.date) <= 3 * 86400 ? Color.orange : DashboardColors.subtleText)
              }
              Spacer()
              Text("手动确认").font(.caption2).foregroundStyle(DashboardColors.subtleText)
            }
          } else {
            Label("赠额到期时间待确认", systemImage: "calendar.badge.clock")
              .font(.caption).foregroundStyle(DashboardColors.subtleText)
          }
        }
        Text("API 用量按 UTC 自然月统计，可能有延迟；赠额余额以账单记录为准，不从消费推算。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func value(_ title: String, _ amount: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(DashboardColors.subtleText)
      Text(amount).font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
      Text(detail).font(.caption2).foregroundStyle(DashboardColors.subtleText)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct OpenAIAPIUsageSettingsView: View {
  @ObservedObject private var api = OpenAIAPIUsageStore.shared
  @State private var key = ""
  @State private var total = ""
  @State private var remaining = ""
  @State private var editingExpiry = false
  @State private var expiry = Date()
  @State private var verifiedExpiry = false
  @State private var grantMessage = ""
  @State private var expiryMessage = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("使用 OpenAI 组织用量接口，每 5 分钟检查一次；官方统计可能延迟。")
        .font(.caption).foregroundStyle(DashboardColors.subtleText)
      HStack {
        Link("创建管理员密钥", destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
        Link("打开 API 账单", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
        Spacer()
      }
      Text("请选择赠额所属的 API 组织。管理员密钥可能有较高权限；请尽量使用最小可用权限。密钥保存在本机钥匙串，脉动只用它读取组织用量；系统可能要求你授权钥匙串访问。")
        .font(.caption).foregroundStyle(DashboardColors.subtleText)
      HStack {
        SecureField("在此输入 API 管理员密钥", text: $key)
          .textFieldStyle(.roundedBorder)
        Button(api.isConnected ? "更换连接" : "连接用量") {
          let submitted = key
          key = ""
          Task { _ = await api.connect(adminKey: submitted) }
        }
        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || api.isRefreshing)
        if api.isConnected {
          Button("刷新") { api.refresh() }.disabled(api.isRefreshing)
          Button("断开连接") { api.disconnect() }
        }
      }
      Text(api.message).font(.caption).foregroundStyle(DashboardColors.subtleText)
      if api.isConnected {
        Text("更换或断开组织连接会清除本机保存的 API 用量和赠额确认，避免混用不同组织的数据。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
      }
      Divider().overlay(DashboardColors.separator)
      Text("确认 API 赠额").font(.system(size: 12.5, weight: .bold))
      Text("赠额尚未到账可留空。到账后可按 API 账单填写实际总额和余额；这是手动记录，不会随消费自动扣减。")
        .font(.caption).foregroundStyle(DashboardColors.subtleText)
      if let grant = api.grant {
        Text("上次确认：余额 \(OpenAIAPIUsageStore.money(grant.remainingUSD)) / 总额 \(OpenAIAPIUsageStore.money(grant.totalUSD)) · \(grant.checkedAt.formatted(date: .abbreviated, time: .shortened))" + (grant.isExpired(at: Date()) ? " · 已过期" : ""))
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
      }
      HStack {
        TextField("实际总额 USD", text: $total).textFieldStyle(.roundedBorder)
        TextField("账单余额 USD", text: $remaining).textFieldStyle(.roundedBorder)
      }
      HStack {
        Button("保存本次确认") {
          guard let a = Double(total.trimmingCharacters(in: .whitespacesAndNewlines)),
                let b = Double(remaining.trimmingCharacters(in: .whitespacesAndNewlines)),
                api.confirmGrant(total: a, remaining: b, expiresAt: nil) else {
            grantMessage = "请输入有效金额，余额不能大于总额。"
            return
          }
          total = ""; remaining = ""; grantMessage = "已保存，请在账单变化后重新确认。"
        }
        if api.grant != nil {
          Button("清除赠额金额") { api.clearGrant(); grantMessage = "已清除本机赠额金额。" }
        }
        Text(grantMessage).font(.caption).foregroundStyle(DashboardColors.subtleText)
      }
      Divider().overlay(DashboardColors.separator)
      Text("API 赠额到期与提醒").font(.system(size: 12.5, weight: .bold))
      Text("到期时间可单独记录。请以账单显示的确切日期、时间和时区为准；未到账或时间不明确时留空。")
        .font(.caption).foregroundStyle(DashboardColors.subtleText)
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let recorded = api.grantExpiry {
          Text("账单到期：\(recorded.longDate) · " + (recorded.hasExpired(at: context.date) ? "已到期，请核对新周期" : "剩余 \(recorded.countdown(at: context.date))") + " · 手动确认")
            .font(.caption).foregroundStyle(DashboardColors.subtleText)
        } else {
          Text("到期时间待确认").font(.caption).foregroundStyle(DashboardColors.subtleText)
        }
      }
      HStack {
        Button(api.grantExpiry == nil ? "记录账单到期时间" : "修改账单到期时间") {
          expiry = api.grantExpiry?.expiresAt ?? Date()
          verifiedExpiry = false
          editingExpiry = true
          expiryMessage = ""
        }
        if api.grantExpiry != nil {
          Button("清除到期时间") { api.clearExpiry(); editingExpiry = false; expiryMessage = "已清除本机到期时间。" }
        }
      }
      if editingExpiry {
        DatePicker("账单到期时间", selection: $expiry, displayedComponents: [.date, .hourAndMinute])
          .onChange(of: expiry) { _ in verifiedExpiry = false }
        Text("按本机时区输入：\(TimeZone.current.identifier)，精确到分钟。如账单未显示具体时间或时区，请先核对，不要猜测。")
          .font(.caption).foregroundStyle(DashboardColors.subtleText)
        Toggle("我已核对账单中的日期和具体时间", isOn: $verifiedExpiry)
        HStack {
          Button("保存到期时间") {
            guard verifiedExpiry, let minute = Calendar.current.dateInterval(of: .minute, for: expiry)?.start,
                  api.confirmExpiry(minute) else { expiryMessage = "请先核对账单时间。"; return }
            editingExpiry = false; verifiedExpiry = false; expiryMessage = "已记录账单时间。"
          }.disabled(!verifiedExpiry)
          Button("取消") { editingExpiry = false; verifiedExpiry = false }
        }
      }
      Toggle("系统通知：提前 3 天、1 天及到期时提醒", isOn: Binding(
        get: { api.expiryNotificationsEnabled }, set: { api.setExpiryNotificationsEnabled($0) }
      ))
      HStack {
        Text(api.expiryReminderStatus.label).font(.caption).foregroundStyle(DashboardColors.subtleText)
        if api.expiryReminderStatus == .denied {
          Button("打开系统通知设置") { QuotaNotificationService.shared.openSystemNotificationSettings() }
        } else if api.expiryReminderStatus == .needsPermission || api.expiryReminderStatus == .unavailable {
          Button("重新安排提醒") { api.retryExpiryReminders() }
        }
      }
      Text("保存时间或开启提醒时，macOS 可能请求通知权限；系统可能延迟投递。通知不包含密钥或余额。")
        .font(.caption).foregroundStyle(DashboardColors.subtleText)
      if !expiryMessage.isEmpty { Text(expiryMessage).font(.caption).foregroundStyle(DashboardColors.subtleText) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
