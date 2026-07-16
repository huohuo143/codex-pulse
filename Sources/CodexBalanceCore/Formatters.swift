import Foundation

public struct CompactNumberParts: Equatable, Sendable {
  public var value: String
  public var unit: String

  public init(value: String, unit: String = "") {
    self.value = value
    self.unit = unit
  }

  public var combined: String { value + unit }
}

public enum BalanceFormatters {
  public static func percent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    return "\(Int(value.rounded()))%"
  }

  /// 中日韩用 万/亿 位制，其余语言用 K/M/B
  private static var usesMyriadUnits: Bool {
    let language = Locale.preferredLanguages.first ?? ""
    return language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
  }

  public static func compactNumber(_ value: Int?) -> String {
    compactNumberParts(value).combined
  }

  public static func compactNumberParts(_ value: Int?) -> CompactNumberParts {
    compactNumberParts(value, usesMyriadUnits: usesMyriadUnits)
  }

  static func compactNumberParts(_ value: Int?, usesMyriadUnits: Bool) -> CompactNumberParts {
    guard let value else { return CompactNumberParts(value: "--") }
    if usesMyriadUnits {
      if value >= 100_000_000 {
        return compactUnitParts(Double(value) / 100_000_000, unit: "亿".coreL10n)
      }
      if value >= 10_000 {
        return compactUnitParts(Double(value) / 10_000, unit: "万".coreL10n)
      }
    } else {
      if value >= 1_000_000_000 {
        return compactUnitParts(Double(value) / 1_000_000_000, unit: "B")
      }
      if value >= 1_000_000 {
        return compactUnitParts(Double(value) / 1_000_000, unit: "M")
      }
      if value >= 10_000 {
        return compactUnitParts(Double(value) / 1_000, unit: "K")
      }
    }
    return CompactNumberParts(
      value: NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    )
  }

  private static func compactUnitParts(_ value: Double, unit: String) -> CompactNumberParts {
    if value >= 100 || value.rounded(.down) == value {
      return CompactNumberParts(value: "\(Int(value.rounded()))", unit: unit)
    }
    return CompactNumberParts(value: String(format: "%.1f", value), unit: unit)
  }

  public static func exactNumber(_ value: Int?) -> String {
    guard let value else { return "--" }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
  }

  public static func resetCountdown(_ date: Date?, mode: CountdownMode = .auto, now: Date = Date()) -> String {
    guard let date else { return "--" }
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24

    switch mode {
    case .hours:
      if hours <= 0 {
        return LC("%d分钟", max(1, minutes))
      }
      return LC("%d小时%d分钟", hours, minutes % 60)
    case .days:
      if days <= 0 {
        return LC("%d小时", hours)
      }
      return LC("%d天%d小时", days, hours % 24)
    case .auto:
      if days > 0 {
        return LC("%d天%d小时", days, hours % 24)
      }
      if hours > 0 {
        return LC("%d小时%d分钟", hours, minutes % 60)
      }
      return LC("%d分钟", max(1, minutes))
    }
  }

  public static func resetCountdownShort(_ date: Date?, mode: CountdownMode = .auto, now: Date = Date()) -> String {
    guard let date else { return "--" }
    let seconds = max(0, Int(date.timeIntervalSince(now)))
    let minutes = seconds / 60
    let hours = minutes / 60
    let days = hours / 24

    switch mode {
    case .hours:
      if hours <= 0 {
        return LC("%d分", max(1, minutes))
      }
      return LC("%d时%d分", hours, minutes % 60)
    case .days:
      if days <= 0 {
        return LC("%d时", hours)
      }
      return LC("%d天%d时", days, hours % 24)
    case .auto:
      if days > 0 {
        return LC("%d天%d时", days, hours % 24)
      }
      if hours > 0 {
        return LC("%d时%d分", hours, minutes % 60)
      }
      return LC("%d分", max(1, minutes))
    }
  }

  public static func time(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  public static func relativeAge(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "无余额事件".coreL10n }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
      return "刚刚".coreL10n
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return LC("%d分钟前", minutes)
    }
    let hours = minutes / 60
    if hours < 24 {
      return LC("%d小时%d分钟前", hours, minutes % 60)
    }
    let days = hours / 24
    return LC("%d天前", days)
  }

  public static func dateTime(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter.string(from: date)
  }

  public static func resetExpiryDate(_ date: Date?, timeZone: TimeZone = .current) -> String {
    guard let date else { return "无到期时间".coreL10n }
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.dateFormat = "M/d"
    return formatter.string(from: date)
  }

  public static func resetExpiryDateTime(_ date: Date?, timeZone: TimeZone = .current) -> String {
    guard let date else { return "无到期时间".coreL10n }
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy/M/d HH:mm"
    return formatter.string(from: date)
  }
}

public enum CountdownMode: Sendable {
  case auto
  case hours
  case days
}
