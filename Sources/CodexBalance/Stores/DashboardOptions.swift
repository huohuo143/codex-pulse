import CodexBalanceCore
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
  case system
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case en
  case ja
  case ko
  case es
  case fr
  case de
  case ru
  case ptBR = "pt-BR"

  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: "跟随系统".l10n
    case .zhHans: "简体中文"
    case .zhHant: "繁體中文"
    case .en: "English"
    case .ja: "日本語"
    case .ko: "한국어"
    case .es: "Español"
    case .fr: "Français"
    case .de: "Deutsch"
    case .ru: "Русский"
    case .ptBR: "Português (Brasil)"
    }
  }
}

enum CompactStyle: String, CaseIterable, Identifiable, Hashable {
  case rings
  case circle
  case square
  case pill
  case bars
  case barsQuad
  case badge
  case badgeQuad

  var id: String { rawValue }
  var title: String {
    switch self {
    case .rings: "额度环"
    case .circle: "圆形"
    case .square: "方形"
    case .pill: "胶囊"
    case .bars: "横条"
    case .barsQuad: "横条·详细"
    case .badge: "徽章"
    case .badgeQuad: "徽章·详细"
    }
  }
  var subtitle: String {
    switch self {
    case .rings: "7天余额 + 24h 消耗"
    case .circle: "纯圆双指标"
    case .square: "紧凑双指标"
    case .pill: "横向极简状态"
    case .bars: "7天余额横条"
    case .barsQuad: "余额、Token 与金额"
    case .badge: "只看7天余额"
    case .badgeQuad: "7天余额 + 24h Token"
    }
  }

  var systemImage: String {
    switch self {
    case .rings: "circle.dotted.circle"
    case .circle: "circle.fill"
    case .square: "square.fill"
    case .pill: "capsule.fill"
    case .bars: "rectangle.split.1x2"
    case .barsQuad: "rectangle.split.2x1"
    case .badge: "number.circle"
    case .badgeQuad: "rectangle.inset.filled"
    }
  }

  var usesCompactMenu: Bool {
    switch self {
    case .circle, .square, .pill, .badge, .badgeQuad: true
    default: false
    }
  }
}

enum TouchBarPanelStyle: String, CaseIterable, Identifiable, Hashable {
  case barsQuad
  case bars
  case badgeQuad
  case badge

  var id: String { rawValue }
  var title: String {
    switch self {
    case .barsQuad: "余额条 + 24h"
    case .bars: "余额条"
    case .badgeQuad: "双数字"
    case .badge: "余额数字"
    }
  }
}

enum CompactSizeMode: String, CaseIterable, Identifiable, Hashable {
  case standard
  case mini
  var id: String { rawValue }
  var title: String { self == .standard ? "标准".l10n : "迷你".l10n }
}

enum CompactRingOrientation: String, CaseIterable, Identifiable, Hashable {
  case horizontal
  case vertical

  var id: String { rawValue }
  var title: String { self == .horizontal ? "横向长方形" : "竖向长方形" }
}

enum RefreshIntervalOption: String, CaseIterable, Identifiable, Hashable {
  case five = "5"
  case ten = "10"
  case thirty = "30"
  var id: String { rawValue }
  var title: String { "\(rawValue)s" }
  var seconds: TimeInterval { TimeInterval(Double(rawValue) ?? 5) }
  static let recommended: RefreshIntervalOption = .thirty
}

enum ReliabilityIntervalOption: String, CaseIterable, Identifiable, Hashable {
  case fifteen = "15"
  case thirty = "30"
  case sixty = "60"

  var id: String { rawValue }
  var title: String { "\(rawValue) 分钟" }
  var seconds: TimeInterval { TimeInterval((Int(rawValue) ?? 30) * 60) }
}

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
  case overview
  case trends
  case insights
  case settings

  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "概览"
    case .trends: "趋势"
    case .insights: "分析"
    case .settings: "设置"
    }
  }
  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .trends: "chart.xyaxis.line"
    case .insights: "square.grid.2x2.fill"
    case .settings: "gearshape.fill"
    }
  }
}

enum DashboardStatusMergePolicy {
  static func radarReliabilityTimestamp(from syncState: CodexRadarSyncState?) -> Date? {
    syncState?.lastSuccessAt
  }

  static func mergeQuota(from incoming: CodexStatus, with existing: CodexStatus?) -> CodexStatus {
    guard let existing, incoming.accountScope == existing.accountScope else { return incoming }

    var result = incoming
    result.main = preferredQuotaEvent(incoming.main, existing.main)
    result.quotaRead = SourceReadMetadata.newest(incoming.quotaRead, existing.quotaRead)
    result.flexibleCreditRead = SourceReadMetadata.newest(incoming.flexibleCreditRead, existing.flexibleCreditRead)
    result.resetCreditsRead = SourceReadMetadata.newest(incoming.resetCreditsRead, existing.resetCreditsRead)
    if (existing.flexibleCreditRead?.lastAttemptAt ?? .distantPast) > (incoming.flexibleCreditRead?.lastAttemptAt ?? .distantPast) {
      result.flexibleCreditBalance = existing.flexibleCreditBalance
    }
    if (existing.resetCreditsRead?.lastAttemptAt ?? .distantPast) > (incoming.resetCreditsRead?.lastAttemptAt ?? .distantPast) {
      result.rateLimitResetCredits = existing.rateLimitResetCredits
    }


    if let main = result.main {
      if let index = result.limits.firstIndex(where: { $0.limitID == main.limitID }) {
        result.limits[index] = main
      } else {
        result.limits.append(main)
      }
    }
    return result
  }

  static func preferredQuotaEvent(_ incoming: RateLimitEvent?, _ existing: RateLimitEvent?) -> RateLimitEvent? {
    guard let incoming else { return existing }
    guard let existing else { return incoming }

    if incoming.limitID == "codex", existing.limitID != "codex" { return incoming }
    if existing.limitID == "codex", incoming.limitID != "codex" { return existing }

    let incomingWindow = incoming.sevenDayWindow
    let existingWindow = existing.sevenDayWindow
    if incomingWindow != nil, existingWindow == nil { return incoming }
    if existingWindow != nil, incomingWindow == nil { return existing }

    // A later reset date identifies a newer official quota cycle. This check
    // prevents an old session-log value from replacing a freshly reset cycle,
    // even when the full log scan itself finishes later.
    if let incomingReset = incomingWindow?.resetsAt,
       let existingReset = existingWindow?.resetsAt {
      let resetDifference = incomingReset.timeIntervalSince(existingReset)
      if abs(resetDifference) > 300 {
        return resetDifference > 0 ? incoming : existing
      }

      // Within one quota cycle, account/rateLimits/read is authoritative.
      // Local session logs can be written a few seconds later during a
      // ChatGPT/App restart but may still carry the preceding percentage.
      let incomingIsLive = incoming.sourceName == "Codex app-server"
      let existingIsLive = existing.sourceName == "Codex app-server"
      if incomingIsLive != existingIsLive {
        return incomingIsLive ? incoming : existing
      }
    }

    if incoming.timestamp != existing.timestamp {
      return incoming.timestamp > existing.timestamp ? incoming : existing
    }

    let incomingIsLive = incoming.sourceName == "Codex app-server"
    let existingIsLive = existing.sourceName == "Codex app-server"
    if incomingIsLive != existingIsLive {
      return incomingIsLive ? incoming : existing
    }
    return incoming
  }
}

