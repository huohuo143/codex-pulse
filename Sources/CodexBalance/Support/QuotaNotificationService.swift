import AppKit
import CodexBalanceCore
import Foundation
import UserNotifications

enum QuotaNotificationAuthorization: Equatable {
  case notDetermined
  case denied
  case authorized

  var label: String {
    switch self {
    case .notDetermined: "尚未请求系统通知权限"
    case .denied: "系统通知权限已关闭"
    case .authorized: "系统通知权限已允许"
    }
  }
}

@MainActor
final class QuotaNotificationService: NSObject, UNUserNotificationCenterDelegate {
  static let shared = QuotaNotificationService()

  private override init() {
    super.init()
    UNUserNotificationCenter.current().delegate = self
  }

  func authorizationStatus() async -> QuotaNotificationAuthorization {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return QuotaNotificationAuthorization.authorized
    case .denied:
      return QuotaNotificationAuthorization.denied
    case .notDetermined:
      return QuotaNotificationAuthorization.notDetermined
    @unknown default:
      return QuotaNotificationAuthorization.notDetermined
    }
  }

  func requestAuthorization() async -> QuotaNotificationAuthorization {
    do {
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    } catch {
      return .denied
    }
    return await authorizationStatus()
  }

  func deliver(_ candidate: QuotaAlertCandidate, remainingPercent: Double?, forecast: QuotaForecast?) async {
    let content = UNMutableNotificationContent()
    content.sound = .default
    content.userInfo = ["route": "overview"]

    switch candidate.kind {
    case .threshold(let threshold):
      content.title = "Codex 7 天额度提醒"
      let remaining = remainingPercent.map { String(format: "%.0f%%", $0) } ?? "--"
      content.body = "当前剩余 \(remaining)，已进入 \(threshold)% 提醒区间。"
    case .forecastCritical:
      content.title = "Codex 额度预计提前耗尽"
      if let exhaustion = forecast?.estimatedExhaustion {
        content.body = "按当前节奏预计于 \(exhaustion.formatted(date: .abbreviated, time: .shortened)) 耗尽，请降低消耗速度。"
      } else {
        content.body = "当前额度消耗速度较高，预计会在官方重置前耗尽。"
      }
    case .resetCreditExpiring(let title, let expiresAt):
      content.title = "Full reset 即将到期"
      content.body = "\(title) 将于 \(expiresAt.formatted(date: .abbreviated, time: .shortened)) 到期。"
    }

    let request = UNNotificationRequest(identifier: candidate.identifier, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }

  func openSystemNotificationSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await MainActor.run {
      NotificationCenter.default.post(name: .codexOpenOverview, object: nil)
    }
  }
}
