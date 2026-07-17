import AppKit
import CodexBalanceCore
import SwiftUI

struct QuotaForecastCard: View {
  let forecast: QuotaForecast?
  let tint: Color

  var body: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text("额度节奏与预测")
              .font(.system(size: 15, weight: .bold))
            Text("仅根据官方 7 天额度百分点变化计算，不使用 Token 换算")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
          }
          Spacer()
          statusBadge
        }

        if let forecast, forecast.isUsable {
          HStack(spacing: 12) {
            forecastMetric(
              title: "当前速度",
              value: forecast.ratePerHour.map { String(format: "%.2f 点/h", $0) } ?? "--",
              detail: forecast.ratePerDay.map { String(format: "%.1f 点/天", $0) } ?? "--"
            )
            forecastMetric(
              title: "均衡日上限",
              value: forecast.balancedDailyPercent.map { String(format: "%.1f 点", $0) } ?? "--",
              detail: "均匀使用至官方重置"
            )
            forecastMetric(
              title: "重置时预计",
              value: forecast.expectedRemainingAtReset.map { String(format: "%.0f%%", $0) } ?? "--",
              detail: resetCountdown(forecast.resetsAt)
            )
          }

          Divider().overlay(DashboardColors.separator)

          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("预计耗尽", systemImage: "hourglass.bottomhalf.filled")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(DashboardColors.subtleText)
            Text(dateTime(forecast.estimatedExhaustion))
              .font(.system(size: 15, weight: .heavy, design: .rounded))
            Spacer()
            Text(exhaustionRange(forecast))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(DashboardColors.subtleText)
          }
        } else {
          HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
              .font(.system(size: 24, weight: .semibold))
              .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
              Text("正在学习额度节奏")
                .font(.system(size: 14, weight: .bold))
              Text(forecast?.reason ?? "等待官方 7 天额度数据")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DashboardColors.subtleText)
              if let forecast, forecast.sampleCount > 0 {
                Text("已有 \(forecast.sampleCount) 个样本 · 覆盖 \(String(format: "%.1f", forecast.dataSpanHours)) 小时")
                  .font(.system(size: 9.5, weight: .medium))
                  .foregroundStyle(DashboardColors.subtleText)
              }
            }
          }
          .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }

        Text("预测为本地趋势参考，不是 OpenAI 官方额度承诺；突发高强度任务会改变结果。")
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  private var statusBadge: some View {
    let risk = forecast?.risk ?? .insufficientData
    return HStack(spacing: 6) {
      Circle().fill(color(for: risk)).frame(width: 7, height: 7)
      Text(label(for: risk))
      if let forecast, forecast.isUsable {
        Text("· \(confidenceLabel(forecast.confidence))")
          .foregroundStyle(DashboardColors.subtleText)
      }
    }
    .font(.system(size: 10, weight: .bold))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(color(for: risk).opacity(0.12), in: Capsule())
  }

  private func forecastMetric(title: String, value: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(DashboardColors.subtleText)
      Text(value)
        .font(.system(size: 20, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
      Text(detail)
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(DashboardColors.faintFill, in: RoundedRectangle(cornerRadius: 10))
  }

  private func label(for risk: QuotaRiskLevel) -> String {
    switch risk {
    case .healthy: "节奏健康"
    case .caution: "需要关注"
    case .critical: "高风险"
    case .insufficientData: "学习中"
    }
  }

  private func color(for risk: QuotaRiskLevel) -> Color {
    switch risk {
    case .healthy: .green
    case .caution: .orange
    case .critical: .red
    case .insufficientData: tint
    }
  }

  private func confidenceLabel(_ confidence: ForecastConfidence) -> String {
    switch confidence {
    case .low: "低置信度"
    case .medium: "中置信度"
    case .high: "高置信度"
    }
  }

  private func dateTime(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .shortened) ?? "--"
  }

  private func exhaustionRange(_ forecast: QuotaForecast) -> String {
    guard let earliest = forecast.earliestExhaustion, let latest = forecast.latestExhaustion else { return "区间计算中" }
    return "区间 \(earliest.formatted(date: .numeric, time: .shortened)) – \(latest.formatted(date: .numeric, time: .shortened))"
  }

  private func resetCountdown(_ reset: Date?) -> String {
    guard let reset else { return "暂无官方重置时间" }
    let remaining = reset.timeIntervalSinceNow
    guard remaining > 0 else { return "等待新周期" }
    let hours = Int(remaining / 3600)
    return "距重置 \(hours / 24)天\(hours % 24)小时"
  }
}

struct MenuBarStatusView: View {
  @EnvironmentObject private var store: DashboardStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(AppInfo.appName).font(.system(size: 14, weight: .bold))
          Text("额度预测与本地用量")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        riskBadge
      }

      Divider()

      HStack(spacing: 18) {
        menuMetric("7 天剩余", store.weekly.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "--")
        menuMetric("滚动 24h", BalanceFormatters.compactNumber(store.tokenStats.rolling24HoursTokens))
      }

      VStack(alignment: .leading, spacing: 5) {
        Label(resetText, systemImage: "arrow.counterclockwise.circle")
        Label(exhaustionText, systemImage: "hourglass")
      }
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(.secondary)

      if store.appUpdateAvailable {
        Button {
          store.openAppUpdatePage()
        } label: {
          HStack {
            Label(
              "发现新版本 \(store.latestAppReleaseVersionText ?? "")",
              systemImage: "arrow.down.circle.fill"
            )
            Spacer()
            Text("查看更新")
          }
          .font(.system(size: 10.5, weight: .bold))
          .foregroundStyle(store.palette.weekly)
          .padding(9)
          .background(store.palette.weekly.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
      }

      Divider()

      HStack {
        Button("打开概览") {
          store.showDashboard()
        }
        Button("立即刷新") { store.refreshAll() }
        Button("提醒设置") { store.showSettings() }
        Spacer()
        Button("退出") { NSApplication.shared.terminate(nil) }
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 330)
  }

  private var riskBadge: some View {
    let risk = store.quotaForecast?.risk ?? .insufficientData
    return Text(riskLabel(risk))
      .font(.system(size: 9.5, weight: .bold))
      .foregroundStyle(riskColor(risk))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(riskColor(risk).opacity(0.12), in: Capsule())
  }

  private func menuMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var resetText: String {
    guard let reset = store.weekly?.resetsAt else { return "暂无官方重置时间" }
    return "官方重置：\(reset.formatted(date: .abbreviated, time: .shortened))"
  }

  private var exhaustionText: String {
    guard let forecast = store.quotaForecast else { return "预测：等待额度样本" }
    if let date = forecast.estimatedExhaustion {
      return "预计耗尽：\(date.formatted(date: .abbreviated, time: .shortened))"
    }
    return "预测：\(forecast.reason ?? "正在学习")"
  }

  private func riskLabel(_ risk: QuotaRiskLevel) -> String {
    switch risk {
    case .healthy: "健康"
    case .caution: "关注"
    case .critical: "高风险"
    case .insufficientData: "学习中"
    }
  }

  private func riskColor(_ risk: QuotaRiskLevel) -> Color {
    switch risk {
    case .healthy: .green
    case .caution: .orange
    case .critical: .red
    case .insufficientData: store.palette.weekly
    }
  }
}
