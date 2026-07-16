import AppKit
import CodexBalanceCore
import SwiftUI

struct ExpandedDashboardView: View {
  @EnvironmentObject private var store: DashboardStore

  private var stats: TokenStats { store.tokenStats }

  var body: some View {
    ZStack {
      DashboardBackdrop(appearance: store.appearance, palette: store.palette)
        .ignoresSafeArea()

      VStack(spacing: 0) {
        header
          .padding(.horizontal, 20)
          .padding(.top, 18)
          .padding(.bottom, 12)
        Divider().overlay(DashboardColors.separator)
        ScrollViewReader { proxy in
          ScrollView {
            Color.clear.frame(height: 0).id("section-top")
            sectionContent
              .padding(.horizontal, 20)
              .padding(.top, 14)
              .padding(.bottom, 20)
          }
          .onChange(of: store.selectedSection) { _, _ in
            proxy.scrollTo("section-top", anchor: .top)
          }
        }
      }
    }
    .foregroundStyle(DashboardColors.text)
    .onAppear { store.refreshSettingsState() }
  }

  private var header: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        ZStack(alignment: .leading) {
          VStack(alignment: .leading, spacing: 3) {
            Text(AppInfo.appName)
              .font(.system(size: 23, weight: .heavy, design: .rounded))
            Text("v\(AppInfo.version) · 顺滑浮窗与本地工作分析")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
          }
          .allowsHitTesting(false)
          WindowDragSurface(help: "拖动 Codex 脉动窗口")
        }
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
        if store.isLoading || store.isFullRefreshing { ProgressView().controlSize(.small) }
        iconButton("doc.on.doc", help: "复制用量摘要") { store.copyUsageSummary() }
        iconButton("square.and.arrow.up", help: "导出用量 CSV") { store.exportUsageCSV() }
        iconButton("arrow.clockwise", help: "刷新额度、完整用量与重置雷达") { store.refreshAll() }
        iconButton(
          store.floatingPanelEnabled ? "chevron.up" : "rectangle.on.rectangle.slash",
          help: store.floatingPanelEnabled ? "收起为悬浮框" : "悬浮框已关闭，前往设置"
        ) {
          store.requestCompactPanel()
        }
      }

      HStack(spacing: 12) {
        Picker("", selection: $store.selectedSection) {
          ForEach(DashboardSection.allCases) { section in
            Label(section.title, systemImage: section.systemImage).tag(section)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 420)
        Spacer()
        Label(refreshStatusText, systemImage: refreshStatusSymbol)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
          .lineLimit(1)
      }
    }
    .animation(.easeInOut(duration: 0.18), value: store.selectedSection)
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch store.selectedSection {
    case .overview:
      overviewSection
    case .trends:
      trendsSection
    case .insights:
      InsightsDashboardView(stats: stats, palette: store.palette)
    case .settings:
      DashboardSettingsView()
    }
  }

  private var overviewSection: some View {
    VStack(spacing: 16) {
      summaryPanel
      CodexRadarView()
      ExpandedResetCreditsView(
        summary: store.rateLimitResetCredits,
        isLoading: store.isLoading,
        tint: store.palette.weekly
      )
      costCards
      disclaimerPanel
      errorPanel
    }
  }

  private var trendsSection: some View {
    VStack(spacing: 16) {
      hourlyPanel
      modelPanel
      devicePanel
      disclaimerPanel
      errorPanel
    }
  }

  @ViewBuilder
  private var errorPanel: some View {
    if let error = store.errorMessage {
      Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var refreshStatusText: String {
    if let exportMessage = store.exportMessage { return exportMessage }
    if store.isFullRefreshing { return "正在增量汇总本月日志" }
    if store.isLoading { return "正在读取最新额度" }
    if let date = store.lastFullRefresh {
      return "完整统计更新于 \(date.formatted(date: .omitted, time: .shortened))"
    }
    return "额度已就绪 · 用量首次汇总中"
  }

  private var refreshStatusSymbol: String {
    if store.exportMessage != nil { return "checkmark.circle.fill" }
    if store.isLoading || store.isFullRefreshing { return "arrow.triangle.2.circlepath" }
    return "checkmark.circle"
  }

  private var summaryPanel: some View {
    PanelCard {
      HStack(spacing: 28) {
        WeeklyGaugeView(
          remainingPercent: store.weekly?.remainingPercent,
          tint: store.palette.weekly,
          size: 190,
          lineWidth: 18
        )
        VStack(alignment: .leading, spacing: 12) {
          Label("滚动24小时消耗", systemImage: "clock.arrow.circlepath")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
          Text(BalanceFormatters.compactNumber(stats.rolling24HoursTokens))
            .font(.system(size: 46, weight: .heavy, design: .rounded))
            .foregroundStyle(store.palette.usage24h)
            .monospacedDigit()
            .contentTransition(.numericText())
          Text("Token")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
          Divider().overlay(DashboardColors.separator)
          HStack(spacing: 18) {
            valuePair("USD", usd(stats.cost24Hours.usd))
            valuePair("CNY", cny(stats.cost24Hours))
          }
          if let reset = store.weekly?.resetsAt {
            Text("7天额度刷新：\(reset.formatted(date: .abbreviated, time: .shortened))")
              .font(.caption)
              .foregroundStyle(DashboardColors.subtleText)
          } else {
            Text("7天额度暂无官方窗口数据")
              .font(.caption)
              .foregroundStyle(DashboardColors.subtleText)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .animation(.snappy(duration: 0.28), value: stats.rolling24HoursTokens)
  }

  private var costCards: some View {
    HStack(spacing: 12) {
      costCard("滚动24h", tokens: stats.rolling24HoursTokens, estimate: stats.cost24Hours, tint: store.palette.usage24h)
      costCard("近7天", tokens: stats.last7DaysTokens, estimate: stats.cost7Days, tint: store.palette.weekly)
      costCard("本月", tokens: stats.monthTokens, estimate: stats.costMonth, tint: Color.orange)
    }
  }

  private func costCard(_ title: String, tokens: Int, estimate: CostEstimate, tint: Color) -> some View {
    MetricCard(
      title: title,
      value: BalanceFormatters.compactNumber(tokens),
      detail: "\(usd(estimate.usd)) · \(cny(estimate))\(estimate.isPartial ? " *" : "")",
      tint: tint
    )
  }

  private var hourlyPanel: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        sectionTitle("最近24小时", subtitle: "按本机时区显示；滚动值按精确时间戳计算")
        GeometryReader { proxy in
          let rows = stats.hourly
          let maximum = max(1, rows.map(\.totalTokens).max() ?? 1)
          HStack(alignment: .bottom, spacing: 3) {
            ForEach(rows) { row in
              RoundedRectangle(cornerRadius: 2)
                .fill(store.palette.usage24h.opacity(row.totalTokens > 0 ? 0.92 : 0.16))
                .frame(height: max(3, proxy.size.height * CGFloat(row.totalTokens) / CGFloat(maximum)))
                .help("\(row.label) · \(BalanceFormatters.compactNumber(row.totalTokens)) Token")
            }
          }
        }
        .frame(height: 96)
        HStack {
          Text(stats.hourly.first?.label ?? "--")
          Spacer()
          Text(stats.hourly.last?.label ?? "--")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  private var modelPanel: some View {
    let models = modelTotals
    return PanelCard {
      VStack(alignment: .leading, spacing: 11) {
        sectionTitle("本月模型构成", subtitle: "schema 4 按模型小时桶；未知模型不会猜价")
        if models.isEmpty {
          Text("暂无模型级用量").foregroundStyle(DashboardColors.subtleText)
        } else {
          ForEach(models, id: \.name) { row in
            HStack {
              Text(row.name).font(.system(size: 12, weight: .bold, design: .monospaced))
              Spacer()
              Text(BalanceFormatters.compactNumber(row.tokens))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(store.palette.usage24h)
            }
          }
        }
      }
    }
  }

  private var devicePanel: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 11) {
        sectionTitle("iCloud 设备统计", subtitle: "读取 schema 2/3/4；新版只写独立 codex-v2 文件")
        if stats.deviceUsage.isEmpty {
          Text("iCloud Drive 暂无设备统计").foregroundStyle(DashboardColors.subtleText)
        } else {
          ForEach(stats.deviceUsage) { device in
            HStack {
              Image(systemName: "desktopcomputer")
                .foregroundStyle(device.deviceID == stats.deviceUsage.first?.deviceID ? store.palette.weekly : DashboardColors.subtleText)
              VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName).font(.system(size: 12, weight: .bold))
                Text("schema \(device.schemaVersion) · \(device.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.system(size: 9)).foregroundStyle(DashboardColors.subtleText)
              }
              Spacer()
              Text("今日 \(BalanceFormatters.compactNumber(device.todayTokens))")
              Text("本月 \(BalanceFormatters.compactNumber(device.monthTokens))")
                .foregroundStyle(store.palette.usage24h)
            }
            .font(.system(size: 11, weight: .semibold))
          }
        }
      }
    }
  }

  private var disclaimerPanel: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("金额为 API 等价预估，不是 ChatGPT/Codex 订阅实际账单。reasoning token 已包含在 output 中，不重复计费。")
      if stats.costMonth.isPartial {
        Text("部分模型未计价：\(stats.costMonth.unpricedModels.joined(separator: ", "))；未计价 Token \(BalanceFormatters.compactNumber(stats.costMonth.unpricedTokens))。")
          .foregroundStyle(.orange)
      }
      if let rate = store.exchangeRate {
        Text("USD/CNY \(String(format: "%.4f", rate.rate)) · 汇率日期 \(rate.rateDate) · Frankfurter")
      } else {
        Text("人民币暂无数据；网络恢复后会每日刷新，已有成功汇率会离线回退。")
      }
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(DashboardColors.subtleText)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sectionTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 15, weight: .bold))
      Text(subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(DashboardColors.subtleText)
    }
  }

  private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 30) }
      .buttonStyle(.plain)
      .background(RoundedRectangle(cornerRadius: 9).fill(DashboardColors.faintFill))
      .help(help)
  }

  private func valuePair(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(DashboardColors.subtleText)
      Text(value).font(.system(size: 17, weight: .heavy, design: .rounded)).monospacedDigit()
    }
  }

  private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
  private func cny(_ estimate: CostEstimate) -> String {
    store.cnyValue(for: estimate).map { "¥\(String(format: "%.2f", $0))" } ?? "¥--"
  }

  private var modelTotals: [(name: String, tokens: Int)] {
    Dictionary(grouping: stats.modelHourly, by: \.model)
      .map { (name: $0.key, tokens: $0.value.reduce(0) { $0 + $1.totalTokens }) }
      .sorted { $0.tokens > $1.tokens }
  }
}
