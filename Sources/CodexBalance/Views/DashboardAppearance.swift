import CodexBalanceCore
import SwiftUI

extension DashboardThemeMode {
  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .day: .light
    case .night: .dark
    }
  }
}

enum DashboardAppearance: String, CaseIterable, Identifiable, Hashable {
  case aurora
  case glass
  case graphite

  static let userDefaultsKey = "dashboardAppearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .aurora: "极光"
    case .glass: "玻璃"
    case .graphite: "石墨"
    }
  }

  var subtitle: String {
    switch self {
    case .aurora: "渐变、鲜明、层次丰富"
    case .glass: "通透、轻盈、细描边"
    case .graphite: "克制、紧凑、低干扰"
    }
  }

  var cardRadius: CGFloat {
    switch self {
    case .aurora: 14
    case .glass: 18
    case .graphite: 9
    }
  }
}

private struct DashboardAppearanceKey: EnvironmentKey {
  static let defaultValue: DashboardAppearance = .aurora
}

extension EnvironmentValues {
  var dashboardAppearance: DashboardAppearance {
    get { self[DashboardAppearanceKey.self] }
    set { self[DashboardAppearanceKey.self] = newValue }
  }
}

struct DashboardBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme
  let appearance: DashboardAppearance
  let palette: DashboardPalette

  @ViewBuilder
  var body: some View {
    switch appearance {
    case .aurora:
      if colorScheme == .light {
        ZStack {
          Color(red: 0.955, green: 0.975, blue: 0.98)
          LinearGradient(
            colors: [palette.weekly.opacity(0.16), .clear, palette.usage24h.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
      } else {
        LinearGradient(
          colors: [palette.gradientStart, palette.gradientEnd],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    case .glass:
      ZStack {
        if colorScheme == .light {
          Color(red: 0.965, green: 0.98, blue: 0.99)
        } else {
          Color(red: 0.035, green: 0.055, blue: 0.07)
        }
        RadialGradient(
          colors: [palette.usage24h.opacity(colorScheme == .light ? 0.13 : 0.16), .clear],
          center: .topLeading,
          startRadius: 10,
          endRadius: 580
        )
        RadialGradient(
          colors: [palette.weekly.opacity(colorScheme == .light ? 0.10 : 0.10), .clear],
          center: .bottomTrailing,
          startRadius: 20,
          endRadius: 520
        )
      }
    case .graphite:
      LinearGradient(
        colors: colorScheme == .light
          ? [Color(red: 0.91, green: 0.925, blue: 0.935), Color(red: 0.985, green: 0.988, blue: 0.99)]
          : [Color(red: 0.055, green: 0.06, blue: 0.065), Color.black.opacity(0.98)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }
}

struct DashboardCardSurface: View {
  @Environment(\.colorScheme) private var colorScheme
  let appearance: DashboardAppearance
  var tint: Color = .primary
  var radius: CGFloat? = nil

  private var resolvedRadius: CGFloat { radius ?? appearance.cardRadius }

  @ViewBuilder
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
    switch appearance {
    case .aurora:
      if colorScheme == .light {
        shape
          .fill(Color.white.opacity(0.76))
          .overlay(shape.stroke(tint.opacity(0.18), lineWidth: 1))
      } else {
        shape
          .fill(DashboardColors.panelRaised.opacity(0.76))
          .overlay(shape.stroke(tint.opacity(0.09), lineWidth: 1))
      }
    case .glass:
      shape
        .fill(.ultraThinMaterial)
        .overlay(
          shape.stroke(
            LinearGradient(
              colors: [Color.primary.opacity(0.20), tint.opacity(0.12), Color.primary.opacity(0.06)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
        )
    case .graphite:
      if colorScheme == .light {
        shape
          .fill(Color(red: 0.965, green: 0.97, blue: 0.975).opacity(0.96))
          .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 1))
      } else {
        shape
          .fill(Color(red: 0.085, green: 0.09, blue: 0.095).opacity(0.96))
          .overlay(shape.stroke(Color.primary.opacity(0.075), lineWidth: 1))
      }
    }
  }
}

struct DashboardAppearancePicker: View {
  @Binding var selection: DashboardAppearance
  let palette: DashboardPalette

  var body: some View {
    HStack(spacing: 10) {
      ForEach(DashboardAppearance.allCases) { appearance in
        Button {
          withAnimation(.easeOut(duration: 0.18)) { selection = appearance }
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            appearancePreview(appearance)
              .frame(height: 46)
            Text(appearance.title)
              .font(.system(size: 12, weight: .bold))
            Text(appearance.subtitle)
              .font(.system(size: 9.5, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(
            DashboardCardSurface(
              appearance: appearance,
              tint: selection == appearance ? palette.weekly : DashboardColors.text,
              radius: 12
            )
          )
          .overlay {
            if selection == appearance {
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.weekly.opacity(0.82), lineWidth: 1.5)
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("全局视觉方案：\(appearance.title)")
      }
    }
  }

  @ViewBuilder
  private func appearancePreview(_ appearance: DashboardAppearance) -> some View {
    ZStack {
      DashboardBackdrop(appearance: appearance, palette: palette)
      HStack(spacing: 5) {
        Circle()
          .trim(from: 0, to: 0.72)
          .stroke(palette.weekly, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: 28, height: 28)
        VStack(spacing: 4) {
          Capsule().fill(palette.usage24h).frame(width: 42, height: 5)
          Capsule().fill(Color.primary.opacity(0.16)).frame(width: 42, height: 5)
          Capsule().fill(Color.primary.opacity(0.10)).frame(width: 30, height: 5)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
