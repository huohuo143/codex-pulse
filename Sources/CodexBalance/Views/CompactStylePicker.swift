import SwiftUI

struct CompactStylePicker: View {
  @Binding var selection: CompactStyle
  let palette: DashboardPalette

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(CompactStyle.allCases) { style in
        Button {
          withAnimation(.easeOut(duration: 0.16)) { selection = style }
        } label: {
          VStack(spacing: 7) {
            preview(for: style)
              .frame(height: 30)
            Text(style.title)
              .font(.system(size: 10.5, weight: .bold))
              .lineLimit(1)
            Text(style.subtitle)
              .font(.system(size: 8.5, weight: .medium))
              .foregroundStyle(DashboardColors.subtleText)
              .lineLimit(1)
              .minimumScaleFactor(0.75)
          }
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 6)
          .padding(.vertical, 9)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(selection == style ? palette.weekly.opacity(0.12) : DashboardColors.faintFill)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(selection == style ? palette.weekly.opacity(0.85) : DashboardColors.border, lineWidth: selection == style ? 1.5 : 1)
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("悬浮框样式：\(style.title)，\(style.subtitle)")
      }
    }
  }

  @ViewBuilder
  private func preview(for style: CompactStyle) -> some View {
    switch style {
    case .circle:
      Circle()
        .stroke(palette.weekly, lineWidth: 4)
        .frame(width: 28, height: 28)
    case .square:
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.primary.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.weekly, lineWidth: 2))
        .frame(width: 30, height: 30)
    case .pill:
      Capsule()
        .fill(Color.primary.opacity(0.08))
        .overlay(Capsule().stroke(palette.weekly.opacity(0.8), lineWidth: 2))
        .frame(width: 54, height: 22)
    case .rings:
      HStack(spacing: 4) {
        Circle().stroke(palette.weekly, lineWidth: 3).frame(width: 27, height: 27)
        VStack(spacing: 3) {
          Capsule().fill(palette.usage24h).frame(width: 25, height: 4)
          Capsule().fill(Color.primary.opacity(0.15)).frame(width: 25, height: 4)
        }
      }
    case .bars, .barsQuad:
      VStack(spacing: 5) {
        Capsule().fill(palette.weekly).frame(width: 54, height: 5)
        if style == .barsQuad {
          HStack(spacing: 4) {
            Capsule().fill(palette.usage24h).frame(width: 25, height: 4)
            Capsule().fill(Color.primary.opacity(0.14)).frame(width: 25, height: 4)
          }
        }
      }
    case .badge, .badgeQuad:
      HStack(spacing: 4) {
        RoundedRectangle(cornerRadius: 4).fill(palette.weekly).frame(width: 18, height: 18)
        Capsule().fill(palette.weekly.opacity(0.75)).frame(width: 24, height: 7)
        if style == .badgeQuad {
          Capsule().fill(palette.usage24h.opacity(0.75)).frame(width: 18, height: 7)
        }
      }
    }
  }
}
