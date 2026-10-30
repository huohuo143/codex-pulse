import CodexBalanceCore
import Foundation
import UserNotifications

enum APIExpiryReminderStatus: Equatable {
  case noDate, disabled, needsPermission, denied, scheduled(Int), expired, unavailable

  var label: String {
    switch self {
    case .noDate: "保存账单到期时间后安排提醒"
    case .disabled: "系统通知已关闭"
    case .needsPermission: "需要允许 macOS 通知"
    case .denied: "macOS 通知未允许"
    case .scheduled: "系统到期提醒已安排"
    case .expired: "已到期，请核对新周期"
    case .unavailable: "无法安排通知，请检查系统设置"
    }
  }
}

@MainActor
protocol APIExpiryReminderScheduling {
  func synchronize(expiry: OpenAIAPIGrantExpiry?, enabled: Bool, requestPermission: Bool) async -> APIExpiryReminderStatus
}

@MainActor
struct APIExpiryReminderService: APIExpiryReminderScheduling {
  func synchronize(expiry: OpenAIAPIGrantExpiry?, enabled: Bool, requestPermission: Bool) async -> APIExpiryReminderStatus {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: OpenAIAPIExpiryReminderPlan.identifiers)
    guard enabled else { return .disabled }
    guard let expiry else { return .noDate }
    let now = Date()
    guard !expiry.hasExpired(at: now) else { return .expired }

    var authorization = await center.notificationSettings().authorizationStatus
    if authorization == .notDetermined && requestPermission {
      do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
      catch { return .unavailable }
      authorization = await center.notificationSettings().authorizationStatus
    }
    guard authorization == .authorized || authorization == .provisional else {
      return authorization == .denied ? .denied : .needsPermission
    }

    let events = OpenAIAPIExpiryReminderPlan.events(expiry: expiry.expiresAt, after: now)
    guard !events.isEmpty else { return .unavailable }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    do {
      for event in events {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: event.fireAt)
        components.timeZone = calendar.timeZone
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "账单记录的到期时间：\(expiry.longDate)（\(TimeZone.current.identifier)）。请核对 OpenAI 账单与新周期赠额。"
        content.sound = .default
        content.userInfo = ["route": "overview"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: event.identifier, content: content, trigger: trigger))
      }
      return .scheduled(events.count)
    } catch {
      center.removePendingNotificationRequests(withIdentifiers: OpenAIAPIExpiryReminderPlan.identifiers)
      return .unavailable
    }
  }
}

/// Rendering previews and tests must not create real system notifications.
@MainActor
struct APIExpiryReminderPreview: APIExpiryReminderScheduling {
  func synchronize(expiry: OpenAIAPIGrantExpiry?, enabled: Bool, requestPermission: Bool) async -> APIExpiryReminderStatus {
    guard enabled else { return .disabled }
    guard let expiry else { return .noDate }
    return expiry.hasExpired(at: Date()) ? .expired : .scheduled(OpenAIAPIExpiryReminderPlan.events(expiry: expiry.expiresAt, after: Date()).count)
  }
}
