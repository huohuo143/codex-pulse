#if !XCODE_WIDGET_BUILD
import CodexBalanceCore
#endif
import AppIntents
import Charts
import SwiftUI
import WidgetKit

@available(macOS 14.0, *)
enum QuotaHistoryWidgetPeriod: String, AppEnum {
  case day, week, month

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "时间范围"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .day: "24 小时", .week: "7 天", .month: "30 天"
  ]
  var days: Int { self == .day ? 1 : self == .week ? 7 : 30 }
}

@available(macOS 14.0, *)
struct QuotaHistoryWidgetConfiguration: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "官方额度历史"
  static let description = IntentDescription("选择官方 7 天剩余额度曲线的时间范围。")

  @Parameter(title: "时间范围", default: .week)
  var period: QuotaHistoryWidgetPeriod
}

@available(macOS 14.0, *)
struct QuotaHistoryTimelineProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> CodexWidgetEntry {
    CodexWidgetEntry(date: Date(), snapshot: .preview, hasLiveData: true)
  }

  func snapshot(for configuration: QuotaHistoryWidgetConfiguration, in context: Context) async -> CodexWidgetEntry {
    let entry = CodexTimelineProvider().loadEntry(usePreviewWhenMissing: context.isPreview)
    return configured(entry, at: entry.date, days: configuration.period.days)
  }

  func timeline(for configuration: QuotaHistoryWidgetConfiguration, in context: Context) async -> Timeline<CodexWidgetEntry> {
    let entry = CodexTimelineProvider().loadEntry(usePreviewWhenMissing: false)
    let entries = entry.snapshot.timelineDates(after: entry.date).map {
      configured(entry, at: $0, days: configuration.period.days)
    }
    return Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(entry.hasLiveData ? 300 : 60)))
  }

  private func configured(_ entry: CodexWidgetEntry, at date: Date, days: Int) -> CodexWidgetEntry {
    CodexWidgetEntry(date: date, snapshot: entry.snapshot.effective(at: date),
      hasLiveData: entry.hasLiveData, quotaHistoryDays: days)
  }
}

struct QuotaHistoryWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var systemFamily
  @Environment(\.codexWidgetFamilyOverride) private var familyOverride
  private var isLarge: Bool { (familyOverride ?? systemFamily) == .systemLarge }
  private var days: Int { [1, 7, 30].contains(entry.quotaHistoryDays) ? entry.quotaHistoryDays : 7 }
  private var periodTitle: String { days == 1 ? "24 小时" : "\(days) 天" }
  private var points: [CodexWidgetQuotaPoint] {
    entry.snapshot.quotaHistory?.first { $0.days == days }?.visiblePoints(at: entry.date) ?? []
  }

  var body: some View {
    let samples = points
    VStack(alignment: .leading, spacing: isLarge ? 12 : 6) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Label("官方额度历史", systemImage: "chart.xyaxis.line")
            .font(.system(size: 12.5, weight: .heavy))
          Text("7 天剩余额度 · 近 \(periodTitle)")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if let last = samples.last {
          VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.1f%%", last.remainingPercent))
              .font(.system(size: isLarge ? 26 : 20, weight: .bold, design: .rounded)).monospacedDigit()
            Text("末次采样").font(.system(size: 8)).foregroundStyle(.secondary)
          }
        }
      }
      if samples.isEmpty {
        VStack(spacing: 5) {
          Text("暂无官方额度样本").font(.system(size: 12, weight: .semibold))
          Text("打开 Codex 脉动后自动记录")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        chart(samples)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if let last = samples.last {
          Text("末次 \(last.recordedAt.formatted(.dateTime.month().day().hour().minute())) · 历史采样")
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      if isLarge {
        Text("仅当前账户本机采样；重置、额度上调或缺测超过 90 分钟时断线。")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .codexWidgetBackground()
  }

  private func chart(_ samples: [CodexWidgetQuotaPoint]) -> some View {
    Chart(samples) { point in
      LineMark(x: .value("采样时间", point.recordedAt),
        y: .value("剩余额度", point.remainingPercent), series: .value("分段", point.segment))
        .interpolationMethod(.linear)
        .lineStyle(StrokeStyle(lineWidth: 2))
        .foregroundStyle(CodexWidgetTheme.weekly)
      PointMark(x: .value("采样时间", point.recordedAt), y: .value("剩余额度", point.remainingPercent))
        .symbolSize(isLarge ? 5 : 3)
        .foregroundStyle(CodexWidgetTheme.weekly)
    }
    .chartYScale(domain: 0...100)
    .chartXScale(domain: entry.date.addingTimeInterval(-Double(days) * 86_400)...entry.date)
    .chartYAxis {
      AxisMarks(position: .leading, values: [0, 50, 100]) { value in
        AxisGridLine().foregroundStyle(Color.primary.opacity(0.1))
        AxisValueLabel {
          if let percent = value.as(Int.self) { Text("\(percent)%").font(.system(size: 8)) }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: isLarge ? 5 : 3)) { value in
        AxisValueLabel(format: days == 1 ? .dateTime.hour().minute() : .dateTime.month().day())
          .font(.system(size: 8))
      }
    }
    .accessibilityLabel("近\(periodTitle)官方7天剩余额度历史，历史数值不代表实时余额")
  }
}
