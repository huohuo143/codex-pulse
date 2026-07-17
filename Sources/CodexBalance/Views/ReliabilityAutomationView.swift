import CodexBalanceCore
import SwiftUI

struct ReliabilityAutomationSettingsView: View {
  @EnvironmentObject private var store: DashboardStore

  var body: some View {
    VStack(spacing: 14) {
      PanelCard {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
              Text("可靠性与自动化中心").font(.system(size: 15, weight: .bold))
              Text("健康巡检、受控恢复、本地备份、每日摘要和脱敏诊断")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DashboardColors.subtleText)
            }
            Spacer()
            statusBadge
          }

          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            ForEach(store.reliabilitySnapshot.checks) { check in
              checkRow(check)
            }
          }

          if let message = store.reliabilityMessage {
            Label(message, systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(DashboardColors.subtleText)
          }
        }
      }

      PanelCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("自动化规则").font(.system(size: 15, weight: .bold))
          Toggle("启用定时健康检查", isOn: $store.reliabilityHealthChecksEnabled)
          Picker("巡检间隔", selection: $store.reliabilityIntervalOption) {
            ForEach(ReliabilityIntervalOption.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .disabled(!store.reliabilityHealthChecksEnabled)

          Toggle("异常时受控自动恢复", isOn: $store.reliabilityAutoRecoveryEnabled)
            .disabled(!store.reliabilityHealthChecksEnabled)
          Text("只会重新读取额度、重新汇总 Token 或刷新快照；15 分钟冷却，每轮最多 2 次，不删除源日志。")
            .font(.caption)
            .foregroundStyle(DashboardColors.subtleText)

          Divider().overlay(DashboardColors.separator)
          Toggle("每日备份额度历史和项目预算", isOn: $store.reliabilityBackupsEnabled)
          Text("保留最近 7 天；仅复制关键本地 JSON，不备份对话或凭据。")
            .font(.caption)
            .foregroundStyle(DashboardColors.subtleText)

          Toggle("生成每日聚合摘要", isOn: $store.reliabilityDailySummaryEnabled)
          Stepper(
            "归档时间：\(String(format: "%02d:00", store.reliabilityDailySummaryHour))",
            value: $store.reliabilityDailySummaryHour,
            in: 0...23
          )
          .disabled(!store.reliabilityDailySummaryEnabled)
          Text("每日摘要默认关闭；开启后只保存额度、Token、风险和健康状态。")
            .font(.caption)
            .foregroundStyle(DashboardColors.subtleText)

          HStack {
            Button("立即自检", systemImage: "stethoscope") {
              store.runReliabilityCheck(manual: true)
            }
            Button("立即备份", systemImage: "archivebox") {
              store.performLocalBackup()
            }
            Button("导出脱敏诊断", systemImage: "doc.text.magnifyingglass") {
              store.exportDiagnosticReport()
            }
            Button("打开归档目录", systemImage: "folder") {
              store.openAutomationFolder()
            }
          }
        }
      }

      PanelCard {
        VStack(alignment: .leading, spacing: 11) {
          Text("最近可靠性事件").font(.system(size: 15, weight: .bold))
          if store.reliabilityEvents.isEmpty {
            Label("暂无恢复或异常事件", systemImage: "checkmark.circle")
              .font(.caption)
              .foregroundStyle(DashboardColors.subtleText)
              .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
          } else {
            ForEach(Array(store.reliabilityEvents.suffix(6).reversed())) { event in
              HStack(alignment: .top, spacing: 9) {
                Image(systemName: eventSymbol(event.kind))
                  .foregroundStyle(eventColor(event.kind))
                  .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                  HStack {
                    Text(event.title).font(.system(size: 11, weight: .bold))
                    Spacer()
                    Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                      .font(.system(size: 9.5, weight: .medium, design: .rounded))
                      .foregroundStyle(DashboardColors.subtleText)
                  }
                  Text(event.detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DashboardColors.subtleText)
                }
              }
            }
          }
        }
      }
    }
    .onAppear { store.runReliabilityCheck(allowAutomation: false) }
  }

  private var statusBadge: some View {
    HStack(spacing: 6) {
      Circle().fill(levelColor(store.reliabilitySnapshot.overall)).frame(width: 7, height: 7)
      Text(levelLabel(store.reliabilitySnapshot.overall))
        .font(.system(size: 10, weight: .bold))
    }
    .foregroundStyle(levelColor(store.reliabilitySnapshot.overall))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(levelColor(store.reliabilitySnapshot.overall).opacity(0.14), in: Capsule())
  }

  private func checkRow(_ check: ReliabilityCheck) -> some View {
    HStack(spacing: 9) {
      Image(systemName: levelSymbol(check.level))
        .foregroundStyle(levelColor(check.level))
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(check.title).font(.system(size: 10.5, weight: .bold))
        Text(check.detail)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(9)
    .background(DashboardColors.faintFill, in: RoundedRectangle(cornerRadius: 10))
  }

  private func levelLabel(_ level: ReliabilityHealthLevel) -> String {
    switch level {
    case .healthy: "系统健康"
    case .warning: "需要关注"
    case .critical: "存在异常"
    case .unknown: "正在学习"
    }
  }

  private func levelColor(_ level: ReliabilityHealthLevel) -> Color {
    switch level {
    case .healthy: .green
    case .warning: .orange
    case .critical: .red
    case .unknown: DashboardColors.subtleText
    }
  }

  private func levelSymbol(_ level: ReliabilityHealthLevel) -> String {
    switch level {
    case .healthy: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .critical: "exclamationmark.octagon.fill"
    case .unknown: "questionmark.circle.fill"
    }
  }

  private func eventSymbol(_ kind: ReliabilityEventKind) -> String {
    switch kind {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .recovery: "arrow.triangle.2.circlepath.circle.fill"
    case .failure: "xmark.octagon.fill"
    }
  }

  private func eventColor(_ kind: ReliabilityEventKind) -> Color {
    switch kind {
    case .info: .blue
    case .warning: .orange
    case .recovery: .green
    case .failure: .red
    }
  }
}
