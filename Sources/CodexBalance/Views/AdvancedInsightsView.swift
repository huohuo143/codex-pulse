import CodexBalanceCore
import SwiftUI

struct AdvancedInsightsView: View {
  @EnvironmentObject private var store: DashboardStore
  let stats: TokenStats
  let palette: DashboardPalette
  @State private var budgetEditorProject: TokenProjectBucket?

  var body: some View {
    VStack(spacing: 16) {
      comparisonCards
      diagnosisPanel
      budgetPanel
    }
    .sheet(item: $budgetEditorProject) { project in
      ProjectBudgetEditor(
        project: project,
        existingLimit: store.projectBudgets.first(where: { $0.id == project.id })?.monthlyTokenLimit
      ) { limit in
        store.setProjectBudget(project: project, monthlyTokenLimit: limit)
      }
    }
  }

  private var comparisonCards: some View {
    let analysis = store.usageAnalysis
    return VStack(alignment: .leading, spacing: 10) {
      sectionTitle("高级消耗分析", subtitle: "同期对比、月末推演与效率诊断均在本机完成")
      HStack(spacing: 12) {
        MetricCard(
          title: "近 7 天变化",
          value: changeText(analysis.sevenDayChangePercent),
          detail: "前 7 天 \(BalanceFormatters.compactNumber(analysis.previous7Tokens))",
          tint: changeColor(analysis.sevenDayChangePercent)
        )
        MetricCard(
          title: "月末预计",
          value: BalanceFormatters.compactNumber(analysis.projectedMonthTokens),
          detail: "当前 \(BalanceFormatters.compactNumber(stats.monthTokens)) Token",
          tint: .orange
        )
        MetricCard(
          title: "近 7 天日均",
          value: BalanceFormatters.compactNumber(analysis.averageDailyTokens),
          detail: "每日 Token",
          tint: palette.weekly
        )
        MetricCard(
          title: "缓存复用率",
          value: percentText(analysis.cacheHitRate),
          detail: "cached input / input",
          tint: palette.usage24h
        )
      }

      HStack(spacing: 18) {
        compactMetric("平均每次调用", value: analysis.averageTokensPerCall.map(BalanceFormatters.compactNumber) ?? "--")
        compactMetric("输出/输入", value: analysis.outputInputRatio.map { String(format: "%.2f%%", $0 * 100) } ?? "--")
        compactMetric("主要模型", value: modelText(analysis))
        compactMetric("最高项目占比", value: percentText(analysis.topProjectShare))
      }
      .padding(.horizontal, 2)
    }
  }

  private var diagnosisPanel: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        sectionTitle("智能诊断", subtitle: "规则化识别节奏变化、异常高峰、缓存效率和消耗集中度")
        ForEach(store.usageAnalysis.insights) { insight in
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: insightSymbol(insight.severity))
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(insightColor(insight.severity))
              .frame(width: 26, height: 26)
              .background(insightColor(insight.severity).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
              Text(insight.title).font(.system(size: 12, weight: .bold))
              Text(insight.detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DashboardColors.subtleText)
            }
            Spacer()
          }
        }

        if !store.usageAnalysis.anomalies.isEmpty {
          Divider().overlay(DashboardColors.separator)
          HStack(spacing: 12) {
            ForEach(store.usageAnalysis.anomalies.prefix(3)) { anomaly in
              VStack(alignment: .leading, spacing: 3) {
                Text(anomaly.label).font(.system(size: 11, weight: .bold))
                Text("\(BalanceFormatters.compactNumber(anomaly.totalTokens)) · 基线的 \(String(format: "%.1f", anomaly.multiple))×")
                  .font(.system(size: 9.5, weight: .medium, design: .rounded))
                  .foregroundStyle(DashboardColors.subtleText)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
  }

  private var budgetPanel: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          sectionTitle("项目月度预算", subtitle: "为本机已识别项目设置 Token 上限，并按当前月进度推演")
          Spacer()
          Menu("添加项目预算", systemImage: "plus") {
            if stats.monthTopProjects.isEmpty {
              Text("暂无已识别项目")
            } else {
              ForEach(stats.monthTopProjects) { project in
                Button(project.projectName) { budgetEditorProject = project }
              }
            }
          }
        }

        if store.usageAnalysis.projectBudgets.isEmpty {
          Label("尚未设置项目预算；可从右上角选择本月项目。", systemImage: "gauge.with.dots.needle.bottom.50percent")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DashboardColors.subtleText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        } else {
          ForEach(store.usageAnalysis.projectBudgets) { row in
            budgetRow(row)
          }
        }

        if let message = store.budgetMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(DashboardColors.subtleText)
        }
        Text("预算是用户自定义的本地管理目标，不代表官方 Token 或订阅额度；项目排名仅覆盖本月已识别的本机工作区。")
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  private func budgetRow(_ row: ProjectBudgetStatus) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.budget.projectName).font(.system(size: 12, weight: .bold))
          if !row.budget.projectPath.isEmpty {
            Text(row.budget.projectPath)
              .font(.system(size: 9, weight: .medium, design: .monospaced))
              .foregroundStyle(DashboardColors.subtleText)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer()
        Text(budgetRiskLabel(row.risk))
          .font(.system(size: 9.5, weight: .bold))
          .foregroundStyle(budgetColor(row.risk))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(budgetColor(row.risk).opacity(0.14), in: Capsule())
        Button("编辑") {
          budgetEditorProject = TokenProjectBucket(
            projectName: row.budget.projectName,
            projectPath: row.budget.projectPath,
            totalTokens: row.usedTokens
          )
        }
        .buttonStyle(.borderless)
        Button(role: .destructive) { store.removeProjectBudget(id: row.id) } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }
      ProgressView(value: min(1, row.progress))
        .tint(budgetColor(row.risk))
      HStack {
        Text("已用 \(BalanceFormatters.compactNumber(row.usedTokens)) / \(BalanceFormatters.compactNumber(row.budget.monthlyTokenLimit))")
        Spacer()
        Text(row.projectedMonthTokens > 0 ? "月末预计 \(BalanceFormatters.compactNumber(row.projectedMonthTokens))" : "本月暂无用量")
      }
      .font(.system(size: 9.5, weight: .medium, design: .rounded))
      .foregroundStyle(DashboardColors.subtleText)
    }
    .padding(.vertical, 2)
  }

  private func compactMetric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(DashboardColors.subtleText)
      Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sectionTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 15, weight: .bold))
      Text(subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(DashboardColors.subtleText)
    }
  }

  private func changeText(_ value: Double?) -> String {
    value.map { String(format: "%+.0f%%", $0) } ?? "学习中"
  }

  private func changeColor(_ value: Double?) -> Color {
    guard let value else { return DashboardColors.subtleText }
    if value >= 25 { return .orange }
    if value <= -20 { return .green }
    return palette.weekly
  }

  private func percentText(_ value: Double?) -> String {
    value.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
  }

  private func modelText(_ analysis: UsageAnalysis) -> String {
    guard let model = analysis.topModel else { return "--" }
    guard let share = analysis.topModelShare else { return model }
    return "\(model) · \(Int((share * 100).rounded()))%"
  }

  private func insightSymbol(_ severity: UsageAnalysisSeverity) -> String {
    switch severity {
    case .positive: "checkmark.circle.fill"
    case .neutral: "info.circle.fill"
    case .caution: "exclamationmark.triangle.fill"
    case .critical: "exclamationmark.octagon.fill"
    }
  }

  private func insightColor(_ severity: UsageAnalysisSeverity) -> Color {
    switch severity {
    case .positive: .green
    case .neutral: palette.weekly
    case .caution: .orange
    case .critical: .red
    }
  }

  private func budgetRiskLabel(_ risk: ProjectBudgetRisk) -> String {
    switch risk {
    case .healthy: "预算健康"
    case .caution: "预计超支"
    case .overBudget: "已超预算"
    case .noUsage: "暂无用量"
    }
  }

  private func budgetColor(_ risk: ProjectBudgetRisk) -> Color {
    switch risk {
    case .healthy: .green
    case .caution: .orange
    case .overBudget: .red
    case .noUsage: DashboardColors.subtleText
    }
  }
}

private struct ProjectBudgetEditor: View {
  @Environment(\.dismiss) private var dismiss
  let project: TokenProjectBucket
  let existingLimit: Int?
  let onSave: (Int) -> Void
  @State private var limitText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("项目月度预算").font(.system(size: 19, weight: .bold))
      VStack(alignment: .leading, spacing: 4) {
        Text(project.projectName).font(.system(size: 13, weight: .bold))
        if !project.projectPath.isEmpty {
          Text(project.projectPath)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      TextField("例如 2,000,000", text: $limitText)
        .textFieldStyle(.roundedBorder)
      Text("输入每月 Token 上限。可使用纯数字或千位分隔符。")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") {
          guard let value = parsedLimit, value > 0 else { return }
          onSave(value)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(parsedLimit == nil)
      }
    }
    .padding(22)
    .frame(width: 420)
    .onAppear {
      limitText = existingLimit.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) } ?? ""
    }
  }

  private var parsedLimit: Int? {
    let normalized = limitText.filter(\.isNumber)
    guard !normalized.isEmpty else { return nil }
    return Int(normalized)
  }
}
