import Foundation

/// One shared threshold and palette for the sidebar, Pulse, and widgets.
public enum QuotaBand: Equatable {
  case green, yellow, pink, red, unavailable

  public static func classify(_ remaining: Double?) -> QuotaBand {
    guard let remaining, remaining.isFinite, (0...100).contains(remaining) else { return .unavailable }
    if remaining >= 50 { return .green }
    if remaining >= 25 { return .yellow }
    if remaining >= 10 { return .pink }
    return .red
  }

  public var colorComponents: (red: Double, green: Double, blue: Double)? {
    switch self {
    case .green: (0.13, 0.66, 0.48)
    case .yellow: (0.83, 0.61, 0.12)
    case .pink: (0.88, 0.32, 0.58)
    case .red: (0.84, 0.28, 0.29)
    case .unavailable: nil
    }
  }
}
