import Foundation

/// 可由用户自由组合的悬浮框信息模块。
public enum FloatingPanelMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
  case weeklyQuota
  case fiveHourQuota
  case rolling24Tokens
  case resetRadar
  case resetCredits

  /// 新增的 5 小时额度保持可选且默认关闭，避免升级后改变现有悬浮框布局。
  public static let defaults: Set<FloatingPanelMetric> = [
    .weeklyQuota,
    .rolling24Tokens,
    .resetRadar,
    .resetCredits
  ]
  public static let userDefaultsKey = "floatingPanelMetrics"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .weeklyQuota: "7 天额度"
    case .fiveHourQuota: "5 小时额度"
    case .rolling24Tokens: "滚动 24h Token"
    case .resetRadar: "重置雷达"
    case .resetCredits: "Full reset 权益"
    }
  }

  public var subtitle: String {
    switch self {
    case .weeklyQuota: "官方 7 天窗口的剩余比例"
    case .fiveHourQuota: "官方 5 小时窗口的剩余比例"
    case .rolling24Tokens: "最近 24 小时 Token 与金额预估"
    case .resetRadar: "Codex 24 小时重置概率"
    case .resetCredits: "可用次数与最近到期信息"
    }
  }

  public var systemImage: String {
    switch self {
    case .weeklyQuota: "gauge.with.dots.needle.50percent"
    case .fiveHourQuota: "timer"
    case .rolling24Tokens: "clock.arrow.circlepath"
    case .resetRadar: "scope"
    case .resetCredits: "arrow.counterclockwise.circle.fill"
    }
  }

  /// 恢复新版本选择；没有新键时兼容 2.5.0 之前独立的 Full reset 开关。
  public static func resolvedSelection(
    rawValues: [String]?,
    legacyShowsResetCredits: Bool?
  ) -> Set<FloatingPanelMetric> {
    let parsed = Set((rawValues ?? []).compactMap(FloatingPanelMetric.init(rawValue:)))
    guard parsed.isEmpty else { return parsed }

    var migrated = defaults
    if legacyShowsResetCredits == false {
      migrated.remove(.resetCredits)
    }
    return migrated
  }

  public static func persistedRawValues(_ selection: Set<FloatingPanelMetric>) -> [String] {
    let safeSelection = selection.isEmpty ? defaults : selection
    return safeSelection.map(\.rawValue).sorted()
  }
}

/// 区分用户手动打开与 Codex watcher 后台唤起，避免关闭悬浮框后弹出完整主窗口。
public enum FloatingPanelStartupPolicy {
  public static func shouldShowWindow(
    floatingPanelEnabled: Bool,
    launchedInBackground: Bool
  ) -> Bool {
    floatingPanelEnabled || !launchedInBackground
  }
}
