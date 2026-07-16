import CodexBalanceCore
import Foundation
import SwiftUI

struct InsightsDashboardView: View {
  private enum ProjectPeriod: String, CaseIterable, Identifiable {
    case today
    case month

    var id: String { rawValue }
    var title: String { self == .today ? "今日" : "本月" }
  }

  let stats: TokenStats
  let palette: DashboardPalette
  @State private var projectPeriod: ProjectPeriod = .today

  var body: some View {
    VStack(spacing: 16) {
      efficiencyCards
      categoryPanel
      projectPanel
      recentPanel
    }
  }

  private var efficiencyCards: some View {
    HStack(spacing: 12) {
      MetricCard(
        title: "本月调用",
        value: BalanceFormatters.compactNumber(totalCalls),
        detail: "已识别 \(activeModelCount) 个模型",
        tint: palette.weekly
      )
      MetricCard(
        title: "缓存输入占比",
        value: cacheHitRateText,
        detail: "cached input / input",
        tint: palette.usage24h
      )
      MetricCard(
        title: "主要工作类型",
        value: topCategory?.category.label ?? "--",
        detail: topCategory.map { "\(BalanceFormatters.compactNumber($0.totalTokens)) Token" } ?? "等待完整统计",
        tint: .orange
      )
    }
  }

  private var categoryPanel: some View {
    let rows = stats.categoryBreakdown
      .filter { $0.totalTokens > 0 }
      .sorted { $0.totalTokens > $1.totalTokens }
    let maximum = max(1, rows.map(\.totalTokens).max() ?? 1)
    let total = max(1, rows.reduce(0) { $0 + $1.totalTokens })
    return PanelCard {
      VStack(alignment: .leading, spacing: 13) {
        sectionTitle("工作类型构成", subtitle: "根据本月会话上下文在本机归类，仅用于趋势参考")
        if rows.isEmpty {
          emptyState("正在建立本月工作类型统计…", symbol: "chart.bar.xaxis")
        } else {
          ForEach(rows) { row in
            HStack(spacing: 11) {
              Image(systemName: symbol(for: row.category))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color(for: row.category))
                .frame(width: 26, height: 26)
                .background(color(for: row.category).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(row.category.label).font(.system(size: 12, weight: .bold))
                  Spacer()
                  Text("\(percentage(row.totalTokens, total: total)) · \(BalanceFormatters.compactNumber(row.totalTokens)) · \(row.calls) 次")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DashboardColors.subtleText)
                }
                ProgressView(value: Double(row.totalTokens), total: Double(maximum))
                  .tint(color(for: row.category))
              }
            }
          }
        }
      }
    }
  }

  private var projectPanel: some View {
    let rows = projectPeriod == .today ? stats.todayTopProjects : stats.monthTopProjects
    return PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          sectionTitle("项目 Top", subtitle: "按 Token 汇总本机 Codex 工作区")
          Spacer()
          Picker("", selection: $projectPeriod) {
            ForEach(ProjectPeriod.allCases) { period in
              Text(period.title).tag(period)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 150)
        }

        if rows.isEmpty {
          emptyState("当前时段暂无项目数据", symbol: "folder.badge.questionmark")
        } else {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 12) {
              Text("\(index + 1)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(index == 0 ? Color.black : DashboardColors.text)
                .frame(width: 25, height: 25)
                .background(index == 0 ? palette.weekly : DashboardColors.faintFill, in: Circle())
              VStack(alignment: .leading, spacing: 2) {
                Text(row.projectName)
                  .font(.system(size: 12, weight: .bold))
                  .lineLimit(1)
                if !row.projectPath.isEmpty {
                  Text(row.projectPath)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(DashboardColors.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
              }
              Spacer()
              Text("\(row.calls) 次")
                .foregroundStyle(DashboardColors.subtleText)
              Text(BalanceFormatters.compactNumber(row.totalTokens))
                .foregroundStyle(palette.usage24h)
                .frame(width: 74, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
          }
        }
      }
    }
    .animation(.easeInOut(duration: 0.18), value: projectPeriod)
  }

  private var recentPanel: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("最近调用", subtitle: "模型、项目与输入/缓存/输出 Token")
        if stats.recentUsageEvents.isEmpty {
          emptyState("正在读取 Codex 会话日志…", symbol: "clock.arrow.circlepath")
        } else {
          ForEach(stats.recentUsageEvents.prefix(8)) { event in
            HStack(spacing: 9) {
              Image(systemName: symbol(for: event.category))
                .foregroundStyle(color(for: event.category))
                .frame(width: 18)
              Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(DashboardColors.subtleText)
                .frame(width: 48, alignment: .leading)
              Text(event.model)
                .lineLimit(1)
                .frame(width: 108, alignment: .leading)
              Text(event.projectName).lineLimit(1)
              Spacer()
              Text("in \(BalanceFormatters.compactNumber(event.inputTokens))")
              Text("cache \(BalanceFormatters.compactNumber(event.cachedInputTokens))")
              Text("out \(BalanceFormatters.compactNumber(event.outputTokens))")
            }
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
          }
        }
      }
    }
  }

  private var totalCalls: Int {
    stats.categoryBreakdown.reduce(0) { $0 + $1.calls }
  }

  private var activeModelCount: Int {
    Set(stats.modelHourly.filter { $0.totalTokens > 0 }.map(\.model)).count
  }

  private var cacheHitRateText: String {
    let input = stats.modelHourly.reduce(0) { $0 + $1.inputTokens }
    let cached = stats.modelHourly.reduce(0) { $0 + $1.cachedInputTokens }
    guard input > 0 else { return "--" }
    return "\(Int((Double(cached) / Double(input) * 100).rounded()))%"
  }

  private var topCategory: TokenCategoryBucket? {
    stats.categoryBreakdown.max { $0.totalTokens < $1.totalTokens }
  }

  private func percentage(_ value: Int, total: Int) -> String {
    String(format: "%.1f%%", Double(value) / Double(total) * 100)
  }

  private func sectionTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 15, weight: .bold))
      Text(subtitle)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
    }
  }

  private func emptyState(_ message: String, symbol: String) -> some View {
    Label(message, systemImage: symbol)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(DashboardColors.subtleText)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
  }

  private func symbol(for category: TokenUsageCategory) -> String {
    switch category {
    case .coding: "chevron.left.forwardslash.chevron.right"
    case .presentation: "rectangle.on.rectangle.angled"
    case .imageDesign: "paintbrush.pointed.fill"
    case .videoProduction: "film.stack.fill"
    case .documents: "doc.text.fill"
    case .manuscript: "pencil.and.outline"
    case .dataAnalysis: "chart.bar.xaxis"
    case .lifeScience: "leaf.fill"
    case .webDevelopment: "globe"
    case .systemOperations: "wrench.and.screwdriver.fill"
    case .research: "book.pages.fill"
    case .general: "bubble.left.and.bubble.right.fill"
    case .other: "ellipsis.circle.fill"
    }
  }

  private func color(for category: TokenUsageCategory) -> Color {
    switch category {
    case .coding: palette.usage24h
    case .presentation: .purple
    case .imageDesign: .pink
    case .videoProduction: .red
    case .documents: .orange
    case .manuscript: .teal
    case .dataAnalysis: .cyan
    case .lifeScience: .green
    case .webDevelopment: .indigo
    case .systemOperations: .yellow
    case .research: palette.weekly
    case .general: Color(red: 0.62, green: 0.70, blue: 0.88)
    case .other: DashboardColors.subtleText
    }
  }
}
