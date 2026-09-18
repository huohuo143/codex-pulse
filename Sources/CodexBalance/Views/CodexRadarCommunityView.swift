import CodexBalanceCore
import SwiftUI

struct CodexRadarCommunityView: View {
  @EnvironmentObject private var store: DashboardStore
  let snapshot: CodexRadarSnapshot?

  var body: some View {
    VStack(spacing: 14) {
      if let insights = snapshot?.stationInsights,
         insights.recommendations.isEmpty == false {
        stationRecommendations(insights)
      }
      if let efficiency = snapshot?.efficiency,
         efficiency.points.isEmpty == false {
        intelligenceEfficiency(efficiency)
      }
    }
  }

  private func stationRecommendations(_ insights: CodexRadarStationInsights) -> some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 14) {
        sectionHeader(
          title: "站长推荐",
          symbol: "scope",
          subtitle: "按最新分布式实测结果，为不同任务选择模型",
          updatedAt: insights.sourceUpdatedAt ?? insights.generatedAt
        )

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 285), spacing: 12)],
          alignment: .leading,
          spacing: 12
        ) {
          ForEach(insights.recommendations) { group in
            recommendationGroup(group)
          }
        }

        sourceFooter("推荐会随公共实测数据变化；IQ、费用与时长均为样本统计。")
      }
    }
  }

  private func recommendationGroup(_ group: CodexRadarRecommendationGroup) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: groupSymbol(group.key))
          .foregroundStyle(store.palette.weekly)
        Text(groupTitle(group))
          .font(.system(size: 14, weight: .bold))
        Spacer()
      }
      .padding(11)

      Divider().overlay(store.palette.weekly.opacity(0.28))

      ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Divider().overlay(DashboardColors.separator)
        }
        recommendationRow(item)
      }
    }
    .background(DashboardColors.faintFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(store.palette.weekly.opacity(0.34), lineWidth: 1)
    }
    .help(group.rule ?? "")
  }

  private func recommendationRow(_ item: CodexRadarRecommendation) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(item.modelLabel) \(item.effortLabel)")
          .font(.system(size: 12, weight: .bold, design: .rounded))
        if let slot = slotLabel(item.slot) {
          Text(slot)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(DashboardColors.subtleText)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(String(format: "%.1f", item.iq))
        .font(.system(size: 21, weight: .heavy, design: .rounded))
        .foregroundStyle(store.palette.weekly)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(width: 58, alignment: .trailing)
      Text(item.averageCostUsd.map { String(format: "$%.1f", $0) } ?? "--")
        .frame(width: 48, alignment: .trailing)
      Text(item.averageDurationMinutes.map { "\(Int($0.rounded()))分" } ?? "--")
        .frame(width: 40, alignment: .trailing)
    }
    .font(.system(size: 10, weight: .semibold, design: .rounded))
    .foregroundStyle(DashboardColors.subtleText)
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
  }

  private func intelligenceEfficiency(_ efficiency: CodexRadarEfficiencySnapshot) -> some View {
    PanelCard {
      VStack(alignment: .leading, spacing: 14) {
        sectionHeader(
          title: "智力效率",
          symbol: "brain.head.profile",
          subtitle: "同一任务集下的 IQ、平均费用与平均完成时间",
          updatedAt: efficiency.sourceUpdatedAt
        )

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
          alignment: .leading,
          spacing: 10
        ) {
          ForEach(efficiency.points) { point in
            efficiencyCard(point)
          }
        }

        sourceFooter("IQ = 最新有效任务通过率 × 150；不同模型与 effort 按同一公共口径展示。")
      }
    }
  }

  private func efficiencyCard(_ point: CodexRadarEfficiencyPoint) -> some View {
    let tint = modelTint(point.model)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 5) {
        Text(point.modelLabel)
          .font(.system(size: 11, weight: .bold, design: .rounded))
        Text(point.effortLabel)
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(DashboardColors.subtleText)
          .lineLimit(1)
        Spacer(minLength: 0)
      }

      Text(String(format: "%.1f", point.iq))
        .font(.system(size: 27, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()

      HStack(spacing: 7) {
        Text(point.averagePriceUsd.map { String(format: "$%.1f", $0) } ?? "--")
        Text(point.averageMinutes.map { "\(Int($0.rounded()))分钟" } ?? "--")
      }
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .foregroundStyle(DashboardColors.subtleText)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(tint.opacity(0.45), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(point.modelLabel) \(point.effortLabel)")
    .accessibilityValue("IQ \(String(format: "%.1f", point.iq))")
  }

  private func sectionHeader(
    title: String,
    symbol: String,
    subtitle: String,
    updatedAt: Date?
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 9) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(store.palette.weekly)
      Text(title)
        .font(.system(size: 20, weight: .heavy, design: .rounded))
      Text(subtitle)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DashboardColors.subtleText)
      Spacer()
      if let updatedAt {
        Text(updatedAt.formatted(.dateTime.month().day().hour().minute()))
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(DashboardColors.subtleText)
      }
    }
  }

  private func sourceFooter(_ note: String) -> some View {
    HStack(spacing: 8) {
      Link("Codex Radar 公开数据", destination: CodexRadarService.siteURL)
      Text("·")
      Text(note)
        .lineLimit(2)
      Spacer()
    }
    .font(.system(size: 9, weight: .medium))
    .foregroundStyle(DashboardColors.subtleText)
  }

  private func groupSymbol(_ key: String) -> String {
    switch key {
    case "daily_development": "keyboard"
    case "hard_problems": "diamond.fill"
    case "background_automation": "arrow.triangle.2.circlepath"
    case "lobster_tasks": "clock"
    default: "sparkles"
    }
  }

  private func groupTitle(_ group: CodexRadarRecommendationGroup) -> String {
    group.key == "lobster_tasks" ? "龙虾类任务" : group.title
  }

  private func slotLabel(_ slot: String?) -> String? {
    switch slot {
    case "value": "性价比位"
    case "smart": "聪明位"
    default: nil
    }
  }

  private func modelTint(_ model: String) -> Color {
    switch model.lowercased() {
    case "gpt-5.6-sol": .yellow
    case "gpt-5.6-terra": .blue
    case "gpt-5.6-luna": Color(red: 0.70, green: 0.76, blue: 0.84)
    case "gpt-5.5": .cyan
    default: store.palette.weekly
    }
  }
}
