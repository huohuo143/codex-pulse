import SwiftUI

enum DashboardPalette: String, CaseIterable, Identifiable {
  case mintDawn
  case seaSaltBlue
  case forestSoda
  case peachSunset
  case wisteriaNight
  case lemonHarbor

  static let userDefaultsKey = "dashboardPalette"
  var id: String { rawValue }

  var title: String {
    switch self {
    case .mintDawn: "薄荷晨光"
    case .seaSaltBlue: "海盐蓝风"
    case .forestSoda: "森林气泡"
    case .peachSunset: "桃桃晚霞"
    case .wisteriaNight: "紫藤星夜"
    case .lemonHarbor: "柠檬海岸"
    }
  }

  var usage24h: Color {
    switch self {
    case .mintDawn: Color(red: 0.39, green: 0.84, blue: 1)
    case .seaSaltBlue: Color(red: 0.38, green: 0.72, blue: 1)
    case .forestSoda: Color(red: 0.55, green: 0.88, blue: 1)
    case .peachSunset: Color(red: 1, green: 0.58, blue: 0.67)
    case .wisteriaNight: Color(red: 0.70, green: 0.62, blue: 1)
    case .lemonHarbor: Color(red: 0.47, green: 0.86, blue: 1)
    }
  }

  var weekly: Color {
    switch self {
    case .mintDawn: Color(red: 0.18, green: 0.91, blue: 0.72)
    case .seaSaltBlue: Color(red: 0.36, green: 0.94, blue: 0.84)
    case .forestSoda: Color(red: 0.38, green: 0.92, blue: 0.43)
    case .peachSunset: Color(red: 1, green: 0.76, blue: 0.36)
    case .wisteriaNight: Color(red: 0.44, green: 0.91, blue: 0.95)
    case .lemonHarbor: Color(red: 0.86, green: 0.93, blue: 0.32)
    }
  }

  var panel: Color {
    switch self {
    case .mintDawn: Color(red: 0.07, green: 0.10, blue: 0.12)
    case .seaSaltBlue: Color(red: 0.06, green: 0.10, blue: 0.16)
    case .forestSoda: Color(red: 0.06, green: 0.12, blue: 0.10)
    case .peachSunset: Color(red: 0.13, green: 0.08, blue: 0.10)
    case .wisteriaNight: Color(red: 0.08, green: 0.07, blue: 0.15)
    case .lemonHarbor: Color(red: 0.08, green: 0.11, blue: 0.10)
    }
  }

  var panelRaised: Color {
    switch self {
    case .mintDawn: Color(red: 0.10, green: 0.14, blue: 0.17)
    case .seaSaltBlue: Color(red: 0.10, green: 0.15, blue: 0.23)
    case .forestSoda: Color(red: 0.10, green: 0.16, blue: 0.13)
    case .peachSunset: Color(red: 0.18, green: 0.12, blue: 0.14)
    case .wisteriaNight: Color(red: 0.13, green: 0.11, blue: 0.22)
    case .lemonHarbor: Color(red: 0.13, green: 0.16, blue: 0.13)
    }
  }

  var gradientStart: Color { panel.opacity(0.98) }
  var gradientEnd: Color { Color.black.opacity(0.92) }
}

enum DashboardColors {
  static var selectedPalette: DashboardPalette {
    UserDefaults.standard.string(forKey: DashboardPalette.userDefaultsKey)
      .flatMap(DashboardPalette.init) ?? .mintDawn
  }
  static var usage24h: Color { selectedPalette.usage24h }
  static var weekly: Color { selectedPalette.weekly }
  static var panel: Color { selectedPalette.panel }
  static var panelRaised: Color { selectedPalette.panelRaised }
  static var track: Color { Color.primary.opacity(0.11) }
  static var text: Color { Color.primary }
  static var subtleText: Color { Color.secondary }
  static var separator: Color { Color.primary.opacity(0.10) }
  static var faintFill: Color { Color.primary.opacity(0.055) }
  static var border: Color { Color.primary.opacity(0.09) }
}

struct WeeklyGaugeView: View {
  var remainingPercent: Double?
  var tint: Color
  var size: CGFloat
  var lineWidth: CGFloat
  var label: String = "7天剩余"

  private var normalizedProgress: Double {
    max(0.008, min(1, (remainingPercent ?? 0) / 100))
  }

  var body: some View {
    ZStack {
      Circle().stroke(DashboardColors.track, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: normalizedProgress)
        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.smooth(duration: 0.42), value: normalizedProgress)
      VStack(spacing: 2) {
        Text(remainingPercent.map { "\(Int($0.rounded()))%" } ?? "--")
          .font(.system(size: size * 0.25, weight: .heavy, design: .rounded))
          .foregroundStyle(tint)
          .monospacedDigit()
          .contentTransition(.numericText())
        Text(label)
          .font(.system(size: max(8, size * 0.08), weight: .semibold))
          .foregroundStyle(DashboardColors.subtleText)
      }
    }
    .frame(width: size, height: size)
    .animation(.snappy(duration: 0.28), value: remainingPercent)
  }
}

struct ConcentricQuotaGaugeView: View {
  var weeklyRemainingPercent: Double?
  var fiveHourRemainingPercent: Double?
  var showsWeekly: Bool
  var showsFiveHour: Bool
  var weeklyTint: Color
  var fiveHourTint: Color
  var size: CGFloat
  var lineWidth: CGFloat

  private func progress(_ value: Double?) -> Double {
    max(0.008, min(1, (value ?? 0) / 100))
  }

  private func percentText(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "--"
  }

  var body: some View {
    let displaysBoth = showsWeekly && showsFiveHour
    let primaryValue = showsWeekly ? weeklyRemainingPercent : fiveHourRemainingPercent
    let primaryTint = showsWeekly ? weeklyTint : fiveHourTint
    let primaryLabel = showsWeekly ? "7天剩余" : "5小时剩余"

    ZStack {
      if showsWeekly {
        quotaCircle(
          value: weeklyRemainingPercent,
          tint: weeklyTint,
          diameter: size,
          width: lineWidth
        )
      }
      if showsFiveHour {
        quotaCircle(
          value: fiveHourRemainingPercent,
          tint: fiveHourTint,
          diameter: displaysBoth ? size * 0.72 : size,
          width: displaysBoth ? lineWidth * 0.72 : lineWidth
        )
      }

      if displaysBoth {
        VStack(spacing: max(2, size * 0.025)) {
          quotaValue(label: "7天", value: weeklyRemainingPercent, tint: weeklyTint)
          quotaValue(label: "5h", value: fiveHourRemainingPercent, tint: fiveHourTint)
        }
      } else {
        VStack(spacing: 2) {
          Text(percentText(primaryValue))
            .font(.system(size: size * 0.25, weight: .heavy, design: .rounded))
            .foregroundStyle(primaryTint)
            .monospacedDigit()
            .contentTransition(.numericText())
          Text(primaryLabel)
            .font(.system(size: max(8, size * 0.08), weight: .semibold))
            .foregroundStyle(DashboardColors.subtleText)
        }
      }
    }
    .frame(width: size, height: size)
    .animation(.smooth(duration: 0.42), value: weeklyRemainingPercent)
    .animation(.smooth(duration: 0.42), value: fiveHourRemainingPercent)
  }

  private func quotaCircle(value: Double?, tint: Color, diameter: CGFloat, width: CGFloat) -> some View {
    ZStack {
      Circle().stroke(DashboardColors.track, lineWidth: width)
      Circle()
        .trim(from: 0, to: progress(value))
        .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: diameter, height: diameter)
  }

  private func quotaValue(label: String, value: Double?, tint: Color) -> some View {
    HStack(spacing: max(3, size * 0.025)) {
      Circle()
        .fill(tint)
        .frame(width: max(5, size * 0.045), height: max(5, size * 0.045))
      Text(label)
        .foregroundStyle(DashboardColors.subtleText)
      Text(percentText(value))
        .foregroundStyle(tint)
    }
    .font(.system(size: max(8, size * 0.085), weight: .heavy, design: .rounded))
    .monospacedDigit()
    .lineLimit(1)
  }
}

struct MetricCard: View {
  @Environment(\.dashboardAppearance) private var appearance
  var title: String
  var value: String
  var detail: String
  var tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DashboardColors.subtleText)
        Spacer()
        Circle().fill(tint).frame(width: 7, height: 7)
      }
      Text(value)
        .font(.system(size: 25, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .contentTransition(.numericText())
      Text(detail)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(DashboardColors.subtleText)
        .lineLimit(1)
    }
    .padding(13)
    .background(DashboardCardSurface(appearance: appearance, tint: tint, radius: appearance == .graphite ? 8 : 12))
    .animation(.snappy(duration: 0.26), value: value)
  }
}

struct PanelCard<Content: View>: View {
  @Environment(\.dashboardAppearance) private var appearance
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(16)
      .background(DashboardCardSurface(appearance: appearance))
  }
}
