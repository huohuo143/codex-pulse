#if !XCODE_WIDGET_BUILD
import CodexBalanceCore
#endif
import SwiftUI
import WidgetKit

struct CodexOverviewWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WidgetHeader(title: "Codex 算力总览", symbol: "sparkles", tint: CodexWidgetTheme.weekly)
      HStack(spacing: 12) {
        QuotaRing(snapshot: entry.snapshot, size: family == .systemMedium ? 82 : 102)
        VStack(alignment: .leading, spacing: 6) {
          KeyValueRow(
            title: "滚动 24h",
            value: BalanceFormatters.compactNumber(entry.snapshot.rolling24HoursTokens),
            tint: CodexWidgetTheme.usage
          )
          KeyValueRow(
            title: "重置概率",
            value: entry.snapshot.resetProbability24h.map { "\($0)%" } ?? "--",
            tint: radarTint(entry.snapshot.resetProbability24h)
          )
          KeyValueRow(
            title: "Full reset",
            value: entry.snapshot.resetCreditsAvailable.map { "\($0) 次" } ?? "--",
            tint: CodexWidgetTheme.credit
          )
          ResetText(snapshot: entry.snapshot)
        }
      }
      if family == .systemLarge {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
          MetricTile(title: "今日", value: entry.snapshot.todayTokens, tint: CodexWidgetTheme.usage, compact: true)
          MetricTile(title: "近 7 天", value: entry.snapshot.last7DaysTokens, tint: CodexWidgetTheme.weekly, compact: true)
          MetricTile(title: "本月", value: entry.snapshot.monthTokens, tint: CodexWidgetTheme.text, compact: true)
          CurrencyTile(title: "月度等价", usd: entry.snapshot.costMonthUSD, cnyRate: entry.snapshot.cnyRate)
        }
        UsageBars(points: entry.snapshot.hourly24, tint: CodexWidgetTheme.usage, labelStride: 4)
      }
      UpdatedText(entry: entry)
    }
    .padding(family == .systemMedium ? 12 : 14)
    .codexWidgetBackground()
  }
}

struct QuotaWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    Group {
      if family == .systemSmall {
        VStack(spacing: 7) {
          QuotaRing(snapshot: entry.snapshot, size: 90)
          ResetText(snapshot: entry.snapshot)
        }
      } else {
        HStack(spacing: 18) {
          QuotaRing(snapshot: entry.snapshot, size: 112)
          VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "7 天额度", symbol: "gauge.with.dots.needle.50percent", tint: CodexWidgetTheme.weekly)
            KeyValueRow(title: "剩余", value: BalanceFormatters.percent(entry.snapshot.remainingPercent), tint: CodexWidgetTheme.weekly)
            KeyValueRow(title: "已用", value: BalanceFormatters.percent(entry.snapshot.usedPercent), tint: CodexWidgetTheme.usage)
            ResetText(snapshot: entry.snapshot)
            UpdatedText(entry: entry)
          }
        }
      }
    }
    .padding(14)
    .codexWidgetBackground()
  }
}

struct RadarWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var family

  private var probabilityText: String {
    entry.snapshot.resetProbability24h.map { "\($0)%" } ?? "--"
  }

  var body: some View {
    Group {
      if family == .systemSmall {
        VStack(alignment: .leading, spacing: 8) {
          WidgetHeader(title: "重置雷达", symbol: "scope", tint: CodexWidgetTheme.radar)
          Spacer(minLength: 0)
          Text(probabilityText)
            .font(.system(size: 42, weight: .heavy, design: .rounded))
            .foregroundStyle(radarTint(entry.snapshot.resetProbability24h))
            .monospacedDigit()
          Text(entry.snapshot.radarLevel ?? "等待公开研判")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(CodexWidgetTheme.text)
            .lineLimit(1)
          RadarAttribution(updatedAt: entry.snapshot.radarUpdatedAt)
        }
      } else {
        HStack(spacing: 16) {
          ZStack {
            Circle().stroke(CodexWidgetTheme.track, lineWidth: 10)
            Circle()
              .trim(from: 0, to: max(0.01, CGFloat(entry.snapshot.resetProbability24h ?? 0) / 100))
              .stroke(radarTint(entry.snapshot.resetProbability24h), style: StrokeStyle(lineWidth: 10, lineCap: .round))
              .rotationEffect(.degrees(-90))
            Text(probabilityText)
              .font(.system(size: 28, weight: .heavy, design: .rounded))
              .foregroundStyle(radarTint(entry.snapshot.resetProbability24h))
              .monospacedDigit()
          }
          .frame(width: 96, height: 96)
          VStack(alignment: .leading, spacing: 7) {
            WidgetHeader(title: "Codex 24h 重置雷达", symbol: "scope", tint: CodexWidgetTheme.radar)
            Text(entry.snapshot.radarLevel ?? "等待公开研判")
              .font(.system(size: 13, weight: .heavy))
              .foregroundStyle(CodexWidgetTheme.text)
            Text(entry.snapshot.radarSummary ?? "打开 Codex 脉动同步公开雷达数据。")
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(CodexWidgetTheme.subtle)
              .lineLimit(3)
            RadarAttribution(updatedAt: entry.snapshot.radarUpdatedAt)
          }
        }
      }
    }
    .padding(14)
    .codexWidgetBackground()
  }
}

struct ResetCreditsWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      WidgetHeader(title: "Full reset 权益", symbol: "arrow.counterclockwise.circle.fill", tint: CodexWidgetTheme.credit)
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(entry.snapshot.resetCreditsAvailable.map(String.init) ?? "--")
          .font(.system(size: family == .systemSmall ? 40 : 34, weight: .heavy, design: .rounded))
          .foregroundStyle(CodexWidgetTheme.credit)
          .monospacedDigit()
        Text("次可用")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(CodexWidgetTheme.subtle)
      }
      if family == .systemSmall {
        if let next = entry.snapshot.resetCredits.first {
          CreditExpiryRow(credit: next, compact: true)
        } else {
          EmptyWidgetText("暂无到期明细")
        }
      } else if entry.snapshot.resetCredits.isEmpty {
        EmptyWidgetText("官方本次未返回可用权益到期明细")
      } else {
        ForEach(Array(entry.snapshot.resetCredits.prefix(3).enumerated()), id: \.offset) { _, credit in
          CreditExpiryRow(credit: credit, compact: false)
        }
      }
      Spacer(minLength: 0)
      UpdatedText(entry: entry)
    }
    .padding(14)
    .codexWidgetBackground()
  }
}

struct TokenSummaryWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WidgetHeader(title: "Token 汇总", symbol: "sum", tint: CodexWidgetTheme.usage)
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
        MetricTile(title: "滚动 24h", value: entry.snapshot.rolling24HoursTokens, tint: CodexWidgetTheme.usage, compact: true)
        MetricTile(title: "今日", value: entry.snapshot.todayTokens, tint: CodexWidgetTheme.usage, compact: true)
        MetricTile(title: "近 7 天", value: entry.snapshot.last7DaysTokens, tint: CodexWidgetTheme.weekly, compact: true)
        MetricTile(title: "本月", value: entry.snapshot.monthTokens, tint: CodexWidgetTheme.text, compact: true)
      }
      if family == .systemMedium {
        HStack {
          Text("API 等价预估")
          Spacer()
          Text(currencyText(entry.snapshot.costMonthUSD, cnyRate: entry.snapshot.cnyRate))
            .foregroundStyle(CodexWidgetTheme.credit)
            .monospacedDigit()
        }
        .font(.system(size: 10, weight: .bold))
      }
      UpdatedText(entry: entry)
    }
    .padding(family == .systemSmall ? 12 : 14)
    .codexWidgetBackground()
  }
}

struct TokenTrendWidgetView: View {
  let entry: CodexWidgetEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        WidgetHeader(title: "滚动 24h 趋势", symbol: "chart.bar.fill", tint: CodexWidgetTheme.usage)
        Spacer()
        Text(BalanceFormatters.compactNumber(entry.snapshot.rolling24HoursTokens))
          .font(.system(size: 17, weight: .heavy, design: .rounded))
          .foregroundStyle(CodexWidgetTheme.usage)
      }
      UsageBars(points: entry.snapshot.hourly24, tint: CodexWidgetTheme.usage, labelStride: 4)
      if family == .systemLarge {
        Divider().overlay(Color.primary.opacity(0.1))
        Text("最近 14 天")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(CodexWidgetTheme.subtle)
        UsageBars(points: entry.snapshot.daily14, tint: CodexWidgetTheme.weekly, labelStride: 2)
      }
      UpdatedText(entry: entry)
    }
    .padding(14)
    .codexWidgetBackground()
  }
}

struct WorkloadWidgetView: View {
  let entry: CodexWidgetEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WidgetHeader(title: "项目与用途", symbol: "square.grid.2x2.fill", tint: CodexWidgetTheme.weekly)
      HStack(alignment: .top, spacing: 10) {
        RankedMetrics(title: "今日项目 Top 3", metrics: entry.snapshot.topProjects, tint: CodexWidgetTheme.usage)
        RankedMetrics(title: "本月用途 Top 3", metrics: entry.snapshot.topCategories, tint: CodexWidgetTheme.weekly)
      }
      UpdatedText(entry: entry)
    }
    .padding(12)
    .codexWidgetBackground()
  }
}

private struct WidgetHeader: View {
  let title: String
  let symbol: String
  let tint: Color

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.system(size: 12.5, weight: .heavy))
      .foregroundStyle(tint)
      .lineLimit(1)
  }
}

private struct QuotaRing: View {
  let snapshot: CodexWidgetSnapshot
  let size: CGFloat

  private var progress: Double { max(0, min(1, (snapshot.remainingPercent ?? 0) / 100)) }

  var body: some View {
    ZStack {
      Circle().stroke(CodexWidgetTheme.track, lineWidth: size * 0.105)
      Circle()
        .trim(from: 0, to: max(0.01, progress))
        .stroke(CodexWidgetTheme.weekly, style: StrokeStyle(lineWidth: size * 0.105, lineCap: .round))
        .rotationEffect(.degrees(-90))
      VStack(spacing: 1) {
        Text(BalanceFormatters.percent(snapshot.remainingPercent))
          .font(.system(size: size * 0.27, weight: .heavy, design: .rounded))
          .foregroundStyle(CodexWidgetTheme.weekly)
          .monospacedDigit()
        Text("7 天剩余")
          .font(.system(size: size * 0.085, weight: .bold))
          .foregroundStyle(CodexWidgetTheme.subtle)
      }
    }
    .frame(width: size, height: size)
  }
}

private struct KeyValueRow: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    HStack(spacing: 7) {
      Text(title).foregroundStyle(CodexWidgetTheme.subtle)
      Spacer(minLength: 4)
      Text(value).foregroundStyle(tint).monospacedDigit()
    }
    .font(.system(size: 10.5, weight: .heavy))
  }
}

private struct MetricTile: View {
  let title: String
  let value: Int
  let tint: Color
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: compact ? 8.5 : 9.5, weight: .bold))
        .foregroundStyle(CodexWidgetTheme.subtle)
        .lineLimit(1)
      Text(BalanceFormatters.compactNumber(value))
        .font(.system(size: compact ? 14.5 : 17, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(compact ? 5 : 7)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
  }
}

private struct CurrencyTile: View {
  let title: String
  let usd: Double
  let cnyRate: Double?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 8.5, weight: .bold))
        .foregroundStyle(CodexWidgetTheme.subtle)
      Text(currencyText(usd, cnyRate: cnyRate))
        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
        .foregroundStyle(CodexWidgetTheme.credit)
        .lineLimit(1)
        .minimumScaleFactor(0.58)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(5)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
  }
}

private struct ResetText: View {
  let snapshot: CodexWidgetSnapshot

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "clock.arrow.circlepath")
      if let resetsAt = snapshot.resetsAt {
        Text("重置")
        Text(resetsAt, style: .relative)
      } else {
        Text("等待重置时间")
      }
    }
    .font(.system(size: 9.5, weight: .bold))
    .foregroundStyle(CodexWidgetTheme.subtle)
    .lineLimit(1)
  }
}

private struct RadarAttribution: View {
  let updatedAt: Date?

  var body: some View {
    HStack(spacing: 4) {
      Text("数据来自重置雷达公开源")
      if let updatedAt {
        Text("·")
        Text(updatedAt, style: .relative)
      }
    }
    .font(.system(size: 8.5, weight: .semibold))
    .foregroundStyle(CodexWidgetTheme.subtle)
    .lineLimit(1)
  }
}

private struct CreditExpiryRow: View {
  let credit: CodexWidgetResetCredit
  let compact: Bool

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(CodexWidgetTheme.credit).frame(width: 5, height: 5)
      Text(credit.title).lineLimit(1)
      Spacer(minLength: 3)
      if let expiresAt = credit.expiresAt {
        Text(expiresAt, style: .relative)
      } else {
        Text("无到期时间")
      }
    }
    .font(.system(size: compact ? 9 : 10.5, weight: .semibold))
    .foregroundStyle(CodexWidgetTheme.subtle)
  }
}

private struct EmptyWidgetText: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(CodexWidgetTheme.subtle)
      .lineLimit(2)
  }
}

private struct UsageBars: View {
  let points: [CodexWidgetPoint]
  let tint: Color
  let labelStride: Int

  private var maximum: Int { max(1, points.map(\.tokens).max() ?? 0) }

  var body: some View {
    if points.isEmpty {
      EmptyWidgetText("打开 Codex 脉动生成趋势数据")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HStack(alignment: .bottom, spacing: 3) {
        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
          VStack(spacing: 3) {
            GeometryReader { proxy in
              VStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                  .fill(LinearGradient(colors: [tint.opacity(0.5), tint], startPoint: .bottom, endPoint: .top))
                  .frame(height: max(2, proxy.size.height * CGFloat(point.tokens) / CGFloat(maximum)))
              }
            }
            Text(index.isMultiple(of: labelStride) || index == points.count - 1 ? shortLabel(point.label) : "")
              .font(.system(size: 7, weight: .bold, design: .rounded))
              .foregroundStyle(CodexWidgetTheme.subtle)
              .frame(height: 8)
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 66)
    }
  }

  private func shortLabel(_ label: String) -> String {
    label.replacingOccurrences(of: ":00", with: "")
  }
}

private struct RankedMetrics: View {
  let title: String
  let metrics: [CodexWidgetMetric]
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.system(size: 10.5, weight: .heavy))
        .foregroundStyle(CodexWidgetTheme.subtle)
      if metrics.isEmpty {
        EmptyWidgetText("暂无数据")
      } else {
        ForEach(Array(metrics.prefix(3).enumerated()), id: \.offset) { index, metric in
          HStack(spacing: 5) {
            Text("\(index + 1)")
              .font(.system(size: 8.5, weight: .heavy, design: .rounded))
              .foregroundStyle(tint)
              .frame(width: 14, height: 14)
              .background(tint.opacity(0.12), in: Circle())
            Text(metric.label).lineLimit(1)
            Spacer(minLength: 4)
            Text(BalanceFormatters.compactNumber(metric.tokens))
              .foregroundStyle(tint)
              .monospacedDigit()
          }
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(CodexWidgetTheme.text)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(8)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct UpdatedText: View {
  let entry: CodexWidgetEntry

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(entry.hasLiveData ? CodexWidgetTheme.weekly : Color.orange)
        .frame(width: 5, height: 5)
      if entry.hasLiveData {
        Text("更新")
        Text(entry.snapshot.updatedAt, style: .relative)
        if entry.snapshot.deviceCount > 0 {
          Text("· \(entry.snapshot.deviceCount) 台设备")
        }
      } else {
        Text("打开 Codex 脉动刷新数据")
      }
    }
    .font(.system(size: 8.5, weight: .semibold))
    .foregroundStyle(CodexWidgetTheme.subtle)
    .lineLimit(1)
  }
}

private func radarTint(_ probability: Int?) -> Color {
  guard let probability else { return CodexWidgetTheme.subtle }
  switch probability {
  case 70...: return CodexWidgetTheme.weekly
  case 40...: return .orange
  default: return CodexWidgetTheme.usage
  }
}

private func currencyText(_ usd: Double, cnyRate: Double?) -> String {
  let usdText = String(format: "$%.2f", usd)
  guard let cnyRate else { return usdText }
  return "\(usdText) · ¥\(String(format: "%.0f", usd * cnyRate))"
}
