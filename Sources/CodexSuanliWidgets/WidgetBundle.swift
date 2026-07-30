import SwiftUI
import WidgetKit

@main
struct CodexSuanliWidgetBundle: WidgetBundle {
  var body: some Widget {
    CodexOverviewWidget()
    QuotaWidget()
    RadarWidget()
    ResetCreditsWidget()
    TokenSummaryWidget()
    TokenTrendWidget()
    WorkloadWidget()
  }
}

private struct CodexOverviewWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.overview"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      CodexOverviewWidgetView(entry: entry)
    }
    .configurationDisplayName("Codex 算力总览")
    .description("复刻悬浮框核心信息；可选显示 7 天外环与 5 小时内环。")
    .supportedFamilies([.systemMedium, .systemLarge])
    .contentMarginsDisabled()
  }
}

private struct QuotaWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.quota"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      QuotaWidgetView(entry: entry)
    }
    .configurationDisplayName("Codex 额度")
    .description("显示 7 天额度外环；可在主 App 中开启 5 小时橙色内环。")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

private struct RadarWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.radar"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      RadarWidgetView(entry: entry)
    }
    .configurationDisplayName("Codex 重置雷达")
    .description("显示公开源的 24 小时重置概率与研判摘要。")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

private struct ResetCreditsWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.reset-credits"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      ResetCreditsWidgetView(entry: entry)
    }
    .configurationDisplayName("Full reset 权益")
    .description("只读显示可用次数与逐次到期时间。")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

private struct TokenSummaryWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.token-summary"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      TokenSummaryWidgetView(entry: entry)
    }
    .configurationDisplayName("Token 汇总")
    .description("显示滚动 24 小时、今日、近 7 天、本月 Token 与 API 等价预估。")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

private struct TokenTrendWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.token-trend"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      TokenTrendWidgetView(entry: entry)
    }
    .configurationDisplayName("Token 趋势")
    .description("显示滚动 24 小时柱状图；大尺寸同时显示最近 14 天。")
    .supportedFamilies([.systemMedium, .systemLarge])
    .contentMarginsDisabled()
  }
}

private struct WorkloadWidget: Widget {
  let kind = "dev.codex.balance-dashboard.codex.workload"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CodexTimelineProvider()) { entry in
      WorkloadWidgetView(entry: entry)
    }
    .configurationDisplayName("项目与用途")
    .description("显示今日项目与本月用途的 Token Top 3。")
    .supportedFamilies([.systemMedium, .systemLarge])
    .contentMarginsDisabled()
  }
}
