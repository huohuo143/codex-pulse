import SwiftUI

enum CodexWidgetTheme {
  static let weekly = Color(red: 0.18, green: 0.91, blue: 0.72)
  static let usage = Color(red: 0.39, green: 0.84, blue: 1.0)
  static let radar = Color(red: 0.72, green: 0.62, blue: 1.0)
  static let credit = Color(red: 1.0, green: 0.76, blue: 0.36)
  static let text = Color.primary
  static let subtle = Color.secondary
  static let track = Color.primary.opacity(0.11)
}

struct CodexWidgetBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      if colorScheme == .light {
        Color(red: 0.955, green: 0.975, blue: 0.98)
      } else {
        Color(red: 0.045, green: 0.058, blue: 0.07)
      }
      LinearGradient(
        colors: [
          CodexWidgetTheme.weekly.opacity(colorScheme == .light ? 0.16 : 0.12),
          Color.clear,
          CodexWidgetTheme.usage.opacity(colorScheme == .light ? 0.12 : 0.08)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }
}

extension View {
  @ViewBuilder
  func codexWidgetBackground() -> some View {
    if #available(macOS 14.0, *) {
      containerBackground(for: .widget) {
        CodexWidgetBackground()
      }
    } else {
      background(CodexWidgetBackground())
    }
  }
}
