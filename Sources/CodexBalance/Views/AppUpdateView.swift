import CodexBalanceCore
import Foundation
import SwiftUI

struct AppUpdateSettingsView: View {
  @EnvironmentObject private var store: DashboardStore

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text("版本更新")
              .font(.system(size: 15, weight: .bold))
            Text("自动检测 GitHub Releases 的正式版本，不会自动下载或安装")
              .font(.caption)
              .foregroundStyle(DashboardColors.subtleText)
          }
          Spacer()
          statusBadge
        }

        Toggle("自动检测版本更新", isOn: $store.automaticUpdateChecksEnabled)
          .font(.system(size: 12.5, weight: .bold))

        Text("开启后在 APP 启动时检查，成功检查后 24 小时内不重复请求；网络失败会保留上次结果并稍后重试。")
          .font(.caption)
          .foregroundStyle(DashboardColors.subtleText)

        Divider().overlay(DashboardColors.separator)

        HStack(spacing: 10) {
          Image(systemName: statusSymbol)
            .foregroundStyle(statusColor)
          VStack(alignment: .leading, spacing: 3) {
            Text(store.appUpdateStatusMessage)
              .font(.system(size: 12, weight: .bold))
            Text(checkDetail)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
          }
          Spacer()
        }

        if store.appUpdateAvailable, let release = store.latestAppRelease {
          VStack(alignment: .leading, spacing: 5) {
            if let publishedAt = release.publishedAt {
              Text("发布于 \(publishedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(DashboardColors.subtleText)
            }
            if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
              Text(notes)
                .font(.caption)
                .foregroundStyle(DashboardColors.subtleText)
                .lineLimit(4)
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DashboardColors.faintFill, in: RoundedRectangle(cornerRadius: 9))
        }

        HStack {
          Button("立即检查", systemImage: "arrow.triangle.2.circlepath") {
            store.checkForAppUpdate()
          }
          .disabled(store.appUpdateIsChecking)

          if store.latestAppRelease != nil {
            Button(store.appUpdateAvailable ? "查看并下载" : "查看发布页", systemImage: "safari") {
              store.openAppUpdatePage()
            }
          }
          Spacer()
          if store.appUpdateIsChecking {
            ProgressView().controlSize(.small)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var checkDetail: String {
    let current = "当前 v\(AppInfo.version)"
    guard let last = store.lastAppUpdateCheckAt else { return current + " · 尚无成功检查" }
    return current + " · 上次检查 " + last.formatted(date: .abbreviated, time: .shortened)
  }

  private var statusSymbol: String {
    if store.appUpdateIsChecking { return "arrow.clockwise" }
    return switch store.appUpdateAvailability {
    case .updateAvailable: "arrow.down.circle.fill"
    case .upToDate: "checkmark.seal.fill"
    case .localVersionNewer: "hammer.circle.fill"
    case nil: "questionmark.circle"
    }
  }

  private var statusColor: Color {
    switch store.appUpdateAvailability {
    case .updateAvailable: store.palette.weekly
    case .upToDate: .green
    case .localVersionNewer: .blue
    case nil: DashboardColors.subtleText
    }
  }

  private var statusBadge: some View {
    Text(badgeText)
      .font(.system(size: 9.5, weight: .bold))
      .foregroundStyle(statusColor)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(statusColor.opacity(0.12), in: Capsule())
  }

  private var badgeText: String {
    if store.appUpdateIsChecking { return "检查中" }
    return switch store.appUpdateAvailability {
    case .updateAvailable: "有新版本"
    case .upToDate: "已是最新"
    case .localVersionNewer: "开发版"
    case nil: "待检查"
    }
  }
}
