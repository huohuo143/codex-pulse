import CodexBalanceCore
import SwiftUI

struct CodexRadarView: View {
  @EnvironmentObject private var store: DashboardStore

  var body: some View {
    VStack(spacing: 14) {
      resetOverviewCard
      tiboCard
    }
  }

  private var resetOverviewCard: some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text("重置概览雷达")
            .font(.system(size: 24, weight: .heavy, design: .rounded))
          Spacer()
          Text("24H RESET")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2.1)
            .foregroundStyle(store.palette.weekly)
        }

        if let snapshot = store.codexRadarSnapshot {
          HStack(alignment: .center, spacing: 28) {
            radarGraphic(snapshot)
              .frame(width: 174, height: 174)
            codexProbability(snapshot)
              .frame(maxWidth: .infinity)
          }
        } else {
          HStack(alignment: .center, spacing: 28) {
            radarGraphic(nil)
              .frame(width: 174, height: 174)
            unavailableOverview
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        Divider().overlay(DashboardColors.separator)
        HStack(spacing: 10) {
          Link(CodexRadarService.attributionText, destination: CodexRadarService.siteURL)
          Spacer()
          if store.codexRadarIsLoading {
            ProgressView().controlSize(.small)
          }
          Label("每 30 分钟自动同步", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
          if let nextSync = store.codexRadarNextSyncAt {
            Text("下次 \(shortTime(nextSync))")
              .monospacedDigit()
          }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  private func codexProbability(_ snapshot: CodexRadarSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Codex")
            .font(.system(size: 27, weight: .heavy, design: .rounded))
          Text(snapshot.latestLevelLabel)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(DashboardColors.subtleText)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          probabilityText(snapshot.probability24hPercent, tint: probabilityTint(snapshot.prediction?.level))
          if let probabilityUpdate = snapshot.probabilityUpdate {
            Text("重置雷达 · \(radarUpdateTime(probabilityUpdate))")
              .font(.system(size: 8, weight: .semibold, design: .rounded))
              .foregroundStyle(DashboardColors.subtleText)
          }
        }
      }

      Divider().overlay(DashboardColors.separator)

      if let summary = snapshot.latestSummary, summary.isEmpty == false {
        Text(summary)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(DashboardColors.text.opacity(0.88))
          .lineSpacing(2)
          .lineLimit(3)
      }

      HStack(spacing: 12) {
        if let probability48h = snapshot.prediction?.probability48h {
          Text("48h  \(Int((min(1, max(0, probability48h)) * 100).rounded()))%")
        }
        if snapshot.windowOpen == true || snapshot.window?.open == true {
          Label("窗口已开", systemImage: "bolt.fill")
            .foregroundStyle(.green)
        }
        Spacer()
        if let judgement = snapshot.publicJudgement,
           snapshot.publicJudgementIsNewer {
          Label("最新研判", systemImage: "sparkles")
            .foregroundStyle(.green)
          Text(judgement.updatedAt.formatted(.dateTime.month().day().hour().minute()))
        } else if let updated = snapshot.latestUpdate {
          Text("最新更新 \(radarUpdateTime(updated))")
        }
      }
      .font(.system(size: 10, weight: .semibold, design: .rounded))
      .foregroundStyle(DashboardColors.subtleText)
    }
  }

  private var unavailableOverview: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Codex")
        .font(.system(size: 27, weight: .heavy, design: .rounded))
      Text("等待公开摘要")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
      Divider().overlay(DashboardColors.separator)
      Text(store.codexRadarStatusMessage)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("重新同步") { store.refreshCodexRadar(force: true) }
          .disabled(store.codexRadarIsLoading)
        Link("打开数据源", destination: CodexRadarService.siteURL)
      }
      .font(.caption)
    }
  }

  private var tiboCard: some View {
    let snapshot = store.codexRadarSnapshot
    let presence = snapshot?.tiboPresence
    let timezoneID = presence?.timezone ?? "America/Los_Angeles"
    return PanelCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text("Tibo 雷达")
            .font(.system(size: 20, weight: .heavy, design: .rounded))
            .foregroundStyle(store.palette.weekly)
          Spacer()
          Text("\(presence?.handle ?? "@thsottiaux") · PT")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
        }

        TiboClockView(
          timezoneID: timezoneID,
          hasRadarData: presence != nil,
          tint: store.palette.weekly
        )

        HStack(alignment: .top, spacing: 13) {
          ZStack {
            Circle()
              .fill(store.palette.weekly.opacity(0.13))
            Circle()
              .stroke(store.palette.weekly.opacity(0.55), lineWidth: 1.5)
            Image(systemName: "person.fill")
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(store.palette.weekly)
          }
          .frame(width: 52, height: 52)

          VStack(alignment: .leading, spacing: 4) {
            Text(presence?.locationLabelZh ?? "旧金山湾区 / PT")
              .font(.system(size: 16, weight: .bold))
            Text(presence == nil ? "等待公开摘要" : "公开推测时区")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(DashboardColors.subtleText)
            Text(presence?.evidenceSummaryZh ?? "公开摘要尚未返回时区依据；未获取数据时不推测实时状态。")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
              .lineSpacing(2)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider().overlay(DashboardColors.separator)

        latestTiboUpdate(snapshot: snapshot, presence: presence)

        HStack {
          Link(CodexRadarService.attributionText, destination: CodexRadarService.siteURL)
          Spacer()
          Text("仅显示 Codex 相关内容")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  @ViewBuilder
  private func latestTiboUpdate(
    snapshot: CodexRadarSnapshot?,
    presence: CodexRadarTiboPresence?
  ) -> some View {
    let publicJudgement = snapshot?.publicJudgement
    let presenceActivityAt = presence?.latestActivityAt
    let usesPublicJudgement = publicJudgement.map { judgement in
      presenceActivityAt.map { judgement.updatedAt > $0 } ?? true
    } ?? false
    let activity = usesPublicJudgement ? publicJudgement?.summary : presence?.latestActivityZh
    let fallback = snapshot?.latestSummary
    let activityDate = usesPublicJudgement ? publicJudgement?.updatedAt : presenceActivityAt
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(usesPublicJudgement || activity == nil ? "最新研判" : "最新动态")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(store.palette.weekly)
        Spacer()
        if let date = activityDate ?? snapshot?.latestUpdate {
          Text(date.formatted(.dateTime.month().day().hour().minute()))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(DashboardColors.subtleText)
        }
      }
      Text(activity ?? fallback ?? "公开摘要尚未返回最新动态或研判摘要。")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DashboardColors.text.opacity(0.90))
        .lineSpacing(3)
        .lineLimit(3)
    }
  }

  private func radarGraphic(_ snapshot: CodexRadarSnapshot?) -> some View {
    let rawProbability = snapshot?.prediction?.probability24h
    let probability = min(1, max(0, rawProbability ?? 0))
    let tint = probabilityTint(snapshot?.prediction?.level)
    return ZStack {
      ForEach([0.28, 0.52, 0.76, 1.0], id: \.self) { scale in
        Circle()
          .stroke(tint.opacity(0.28), lineWidth: 1)
          .scaleEffect(scale)
      }
      Rectangle().fill(tint.opacity(0.22)).frame(width: 1)
      Rectangle().fill(tint.opacity(0.22)).frame(height: 1)
      if rawProbability != nil {
        Circle()
          .trim(from: 0, to: probability)
          .stroke(tint.opacity(0.48), style: StrokeStyle(lineWidth: 22, lineCap: .butt))
          .rotationEffect(.degrees(-90))
          .scaleEffect(0.78)
        Circle()
          .fill(tint)
          .frame(width: 8, height: 8)
          .offset(y: -64)
          .rotationEffect(.degrees(probability * 360))
          .shadow(color: tint.opacity(0.70), radius: 5)
      }
      VStack(spacing: 1) {
        Text(rawProbability == nil ? "--" : "\(Int((probability * 100).rounded()))%")
          .font(.system(size: 25, weight: .heavy, design: .rounded))
          .monospacedDigit()
        Text("24H")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(DashboardColors.subtleText)
      }
      .foregroundStyle(tint)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Codex 24 小时重置概率")
    .accessibilityValue(rawProbability == nil ? "等待数据" : "\(Int((probability * 100).rounded()))%")
  }

  private func probabilityText(_ percent: Int?, tint: Color) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: 2) {
      Text(percent.map(String.init) ?? "--")
        .font(.system(size: 45, weight: .heavy, design: .rounded))
      if percent != nil {
        Text("%")
          .font(.system(size: 20, weight: .heavy, design: .rounded))
      }
    }
    .foregroundStyle(tint)
    .monospacedDigit()
  }

  private func probabilityTint(_ level: String?) -> Color {
    switch level?.lowercased() {
    case "very_high", "high": store.palette.weekly
    case "medium_high", "medium": .orange
    case "medium_low": .yellow
    case "low", "very_low": store.palette.usage24h
    default: store.palette.weekly
    }
  }

  private func shortTime(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
  }

  private func radarUpdateTime(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
      return shortTime(date)
    }
    return date.formatted(.dateTime.month().day().hour().minute())
  }

}

private struct TiboClockView: View {
  let timezoneID: String
  let hasRadarData: Bool
  let tint: Color

  private let timeFormatter: DateFormatter
  private let weekdayFormatter: DateFormatter
  private let calendar: Calendar

  init(timezoneID: String, hasRadarData: Bool, tint: Color) {
    self.timezoneID = timezoneID
    self.hasRadarData = hasRadarData
    self.tint = tint

    let timezone = TimeZone(identifier: timezoneID) ?? TimeZone(identifier: "America/Los_Angeles")!
    let timeFormatter = DateFormatter()
    timeFormatter.timeZone = timezone
    timeFormatter.dateFormat = "HH:mm:ss"
    self.timeFormatter = timeFormatter

    let weekdayFormatter = DateFormatter()
    weekdayFormatter.locale = Locale(identifier: "zh_CN")
    weekdayFormatter.timeZone = timezone
    weekdayFormatter.dateFormat = "EEE"
    self.weekdayFormatter = weekdayFormatter

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    self.calendar = calendar
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(timeFormatter.string(from: context.date))
          .font(.system(size: 34, weight: .heavy, design: .rounded))
          .monospacedDigit()
        Text(weekdayFormatter.string(from: context.date))
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(DashboardColors.subtleText)
        Text(hasRadarData ? period(context.date) : "等待雷达数据")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(tint)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(tint.opacity(0.10), in: Capsule())
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func period(_ date: Date) -> String {
    switch calendar.component(.hour, from: date) {
    case 0..<7: "可能睡眠"
    case 7..<9: "清晨"
    case 9..<18: "工作时段"
    case 18..<23: "晚间"
    default: "可能休息"
    }
  }
}
