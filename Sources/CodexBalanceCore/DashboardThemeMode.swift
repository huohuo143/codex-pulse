import Foundation

/// 主 App 的背景明暗策略。桌面小组件仍由 macOS 自身外观控制。
public enum DashboardThemeMode: String, CaseIterable, Identifiable, Hashable, Sendable {
  case system
  case day
  case night

  public static let userDefaultsKey = "dashboardThemeMode"
  public static let defaultMode: DashboardThemeMode = .system

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .system: "跟随系统"
    case .day: "白天"
    case .night: "夜晚"
    }
  }

  public var subtitle: String {
    switch self {
    case .system: "随 macOS 外观自动切换"
    case .day: "固定使用明亮背景"
    case .night: "固定使用深色背景"
    }
  }

  public var systemImage: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .day: "sun.max.fill"
    case .night: "moon.stars.fill"
    }
  }
}
