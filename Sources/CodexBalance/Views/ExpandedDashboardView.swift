import AppKit
import CodexBalanceCore
import SwiftUI

struct ExpandedDashboardView: View {
  private enum UsageTrendPeriod: String, CaseIterable, Identifiable {
    case hourly
    case daily

    var id: String { rawValue }
    var title: String { self == .hourly ? "24 小时" : "按天" }
  }

  @EnvironmentObject private var store: DashboardStore
  @State private var usageTrendPeriod: UsageTrendPeriod = .hourly

  private var stats: TokenStats { store.tokenStats }
  private var currentDeviceID: String? { stats.deviceUsage.first?.deviceID }

  private var orderedTrendDevices: [DeviceUsageTrendDevice] {
    DeviceUsageTrendBuilder.orderedDevices(
      from: stats.deviceUsage,
      currentDeviceID: currentDeviceID
    )
  }

  private var hourlyTrendData: DeviceUsageTrendData {
    DeviceUsageTrendBuilder.make(
      axisRows: stats.hourly,
      snapshots: stats.deviceUsage,
      currentDeviceID: currentDeviceID,
      granularity: .hourly
    )
  }

  private var dailyTrendData: DeviceUsageTrendData {
    DeviceUsageTrendBuilder.make(
      axisRows: DailyUsageChartSupport.visibleRows(stats.daily),
      snapshots: stats.deviceUsage,
      currentDeviceID: currentDeviceID,
      granularity: .daily
    )
  }

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
          .onChange(of: store.selectedSection) { _ in
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
      QuotaForecastCard(forecast: store.quotaForecast, tint: store.palette.weekly)
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
      usageTrendPanel
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
        ConcentricQuotaGaugeView(
          weeklyRemainingPercent: store.weekly?.remainingPercent,
          fiveHourRemainingPercent: store.fiveHour?.remainingPercent,
          showsWeekly: true,
          showsFiveHour: store.overviewShowsFiveHourQuota,
          weeklyTint: store.palette.weekly,
          fiveHourTint: .orange,
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
          VStack(alignment: .leading, spacing: 4) {
            quotaResetText(title: "7天", window: store.weekly)
            if store.overviewShowsFiveHourQuota {
              quotaResetText(title: "5小时", window: store.fiveHour)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .animation(.snappy(duration: 0.28), value: stats.rolling24HoursTokens)
    .animation(.snappy(duration: 0.28), value: store.overviewShowsFiveHourQuota)
  }

  private func quotaResetText(title: String, window: LimitWindow?) -> some View {
    Group {
      if let reset = window?.resetsAt {
        Text("\(title)额度刷新：\(reset.formatted(date: .abbreviated, time: .shortened))")
      } else {
        Text("\(title)额度暂无官方窗口数据")
      }
    }
    .font(.caption)
    .foregroundStyle(DashboardColors.subtleText)
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

  private var usageTrendPanel: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          sectionTitle(usageTrendTitle, subtitle: usageTrendSubtitle)
          Spacer()
          Picker("趋势粒度", selection: $usageTrendPeriod) {
            ForEach(UsageTrendPeriod.allCases) { period in
              Text(period.title).tag(period)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 160)
          .accessibilityLabel("趋势粒度")
        }

        if usageTrendPeriod == .hourly {
          HourlyUsageChart(data: hourlyTrendData, palette: store.palette)
          HStack {
            Text(stats.hourly.first?.label ?? "--")
            Spacer()
            Text(stats.hourly.last?.label ?? "--")
          }
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DashboardColors.subtleText)
        } else {
          DailyUsageChart(data: dailyTrendData, palette: store.palette)
        }
      }
    }
    .animation(.easeInOut(duration: 0.18), value: usageTrendPeriod)
  }

  private var usageTrendTitle: String {
    usageTrendPeriod == .hourly ? "最近24小时" : "最近30天"
  }

  private var usageTrendSubtitle: String {
    if usageTrendPeriod == .hourly {
      if hourlyTrendData.isMultiDevice {
        return "按本机时区对齐 \(hourlyTrendData.devices.count) 台设备；滚动值按精确时间戳计算"
      }
      return "按本机时区显示；滚动值按精确时间戳计算"
    }
    if dailyTrendData.isMultiDevice {
      return "按本机时区对齐 \(dailyTrendData.devices.count) 台设备；横向滚动查看完整月份"
    }
    return "按本机时区逐日汇总；横向滚动查看完整月份"
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
                .foregroundStyle(deviceColor(device.deviceID))
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

  private func deviceColor(_ deviceID: String) -> Color {
    let colorIndex = orderedTrendDevices.first(where: { $0.deviceID == deviceID })?.colorIndex ?? 0
    return DeviceUsageColorPalette.color(for: colorIndex, palette: store.palette)
  }

  private var modelTotals: [(name: String, tokens: Int)] {
    Dictionary(grouping: stats.modelHourly, by: \.model)
      .map { (name: $0.key, tokens: $0.value.reduce(0) { $0 + $1.totalTokens }) }
      .sorted { $0.tokens > $1.tokens }
  }
}
