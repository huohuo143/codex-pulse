import Foundation

public enum CodexApplicationPaths {
  public static func embeddedCLI(in appBundle: URL) -> URL {
    appBundle.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
  }
}

public struct SidebarVisibility: Equatable {
  public var quota: Bool
  public var radar: Bool
  public var credits: Bool
  public var reset: Bool
  public var apiUsage: Bool

  public init(quota: Bool = true, radar: Bool = true, credits: Bool = true, reset: Bool = true, apiUsage: Bool = true) {
    self.quota = quota; self.radar = radar; self.credits = credits; self.reset = reset; self.apiUsage = apiUsage
  }

  public static func load(from defaults: UserDefaults = .standard) -> SidebarVisibility {
    SidebarVisibility(quota: defaults.object(forKey: "sidebarShowsQuota") as? Bool ?? true,
                      radar: defaults.object(forKey: "sidebarShowsRadar") as? Bool ?? true,
                      credits: defaults.object(forKey: "sidebarShowsCredits") as? Bool ?? true,
                      reset: defaults.object(forKey: "sidebarShowsReset") as? Bool ?? true,
                      apiUsage: defaults.object(forKey: "sidebarShowsAPIUsage") as? Bool ?? true)
  }

  /// Migrate only explicit values from the former standalone app. Existing
  /// Pulse choices always take precedence and the old domain remains intact.
  public static func migrateAndLoad(from defaults: UserDefaults, legacy: [String: Any]?) -> SidebarVisibility {
    for key in ["sidebarShowsQuota", "sidebarShowsRadar", "sidebarShowsCredits", "sidebarShowsReset", "sidebarShowsAPIUsage"] {
      if defaults.object(forKey: key) == nil, let value = legacy?[key] as? Bool {
        defaults.set(value, forKey: key)
      }
    }
    return load(from: defaults)
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(quota, forKey: "sidebarShowsQuota")
    defaults.set(radar, forKey: "sidebarShowsRadar")
    defaults.set(credits, forKey: "sidebarShowsCredits")
    defaults.set(reset, forKey: "sidebarShowsReset")
    defaults.set(apiUsage, forKey: "sidebarShowsAPIUsage")
  }
}

public struct AccountSample: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let remaining: Double?
  public let balance: Double?
  public let sampledAt: TimeInterval?
  public let unlimited: Bool?
  public let resetCount: Int?

  public init(ok: Bool, remaining: Double?, balance: Double?, sampledAt: TimeInterval?,
              unlimited: Bool? = false, resetCount: Int? = nil) {
    self.ok = ok; self.remaining = remaining; self.balance = balance; self.sampledAt = sampledAt
    self.unlimited = unlimited; self.resetCount = resetCount
  }
}

/// Only the public, derived Tibo presentation fields written by Codex Pulse.
public struct RadarSnapshot: Decodable, Equatable {
  public var schemaVersion: Int?
  public var radarLevel: String?
  public var radarDeadlineAt: TimeInterval?
  public var radarCompletionUntil: TimeInterval?
  public var radarValidUntil: TimeInterval?
  public var radarLastSuccessAt: TimeInterval?
  public var radarIsStale: Bool?
  public var radarConsecutiveFailures: Int?
  public var radarAnnouncementActive: Bool?

  public init(schemaVersion: Int? = 4, radarLevel: String? = nil, radarDeadlineAt: TimeInterval? = nil,
              radarCompletionUntil: TimeInterval? = nil, radarValidUntil: TimeInterval? = nil,
              radarLastSuccessAt: TimeInterval? = nil, radarIsStale: Bool? = nil,
              radarConsecutiveFailures: Int? = nil, radarAnnouncementActive: Bool? = nil) {
    self.schemaVersion = schemaVersion; self.radarLevel = radarLevel; self.radarDeadlineAt = radarDeadlineAt
    self.radarCompletionUntil = radarCompletionUntil; self.radarValidUntil = radarValidUntil
    self.radarLastSuccessAt = radarLastSuccessAt; self.radarIsStale = radarIsStale
    self.radarConsecutiveFailures = radarConsecutiveFailures; self.radarAnnouncementActive = radarAnnouncementActive
  }
}

public struct RadarDisplay: Equatable {
  public enum Kind { case waiting, announced, completed, stale }
  public let title: String
  public let detail: String?
  public let kind: Kind

  public static func resolve(_ value: RadarSnapshot?, now: Date) -> RadarDisplay {
    guard let value, (value.schemaVersion ?? 0) >= 4 else {
      return .init(title: "等动态", detail: nil, kind: .waiting)
    }
    let epoch = now.timeIntervalSince1970
    if let completion = value.radarCompletionUntil {
      if completion > epoch {
        let title = value.radarLevel == "Tibo确认发卡" ? "确认发卡" :
          value.radarLevel == "Tibo确认重置" ? "确认重置" : "已落地"
        return .init(title: title, detail: nil, kind: .completed)
      }
      return .init(title: "待预告", detail: nil, kind: .waiting)
    }
    guard let success = value.radarLastSuccessAt, success <= epoch + 5 else {
      return .init(title: "等动态", detail: nil, kind: .waiting)
    }
    if value.radarIsStale == true || epoch - success > 90 * 60 ||
      (value.radarValidUntil.map { $0 <= epoch } ?? false) {
      return .init(title: "待刷新", detail: nil, kind: .stale)
    }
    if (value.radarConsecutiveFailures ?? 0) > 0 {
      return .init(title: "更新失败", detail: nil, kind: .stale)
    }
    switch value.radarLevel {
    case "重置已预告", "发卡已预告":
      guard value.radarAnnouncementActive == true else {
        return .init(title: "待分析", detail: nil, kind: .waiting)
      }
      let title = value.radarLevel == "发卡已预告" ? "发卡预告" : "已预告"
      return .init(title: title, detail: deadline(value.radarDeadlineAt), kind: .announced)
    case "等待新重置": return .init(title: "待预告", detail: nil, kind: .waiting)
    case "动态已更新": return .init(title: "动态更新", detail: nil, kind: .waiting)
    case "尚不能确认": return .init(title: "待确认", detail: nil, kind: .waiting)
    case "分析未成功": return .init(title: "分析失败", detail: nil, kind: .stale)
    case "动态未更新", "动态已过期": return .init(title: "待刷新", detail: nil, kind: .stale)
    case "等待分析": return .init(title: "待分析", detail: nil, kind: .waiting)
    default: return .init(title: "等动态", detail: nil, kind: .waiting)
    }
  }

  private static func deadline(_ epoch: TimeInterval?) -> String? {
    guard let epoch else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: epoch))
  }
}

public enum SidebarFormat {
  public static func percentage(_ number: Double?) -> String {
    guard let number, QuotaBand.classify(number) != .unavailable else { return "—" }
    if number.rounded() == number { return "\(Int(number))%" }
    return String(format: "%.1f%%", number)
  }

  public static func credits(_ number: Double?) -> String {
    guard let number, number.isFinite, number >= 0, number < 1_000_000_000_000 else { return "—" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.groupingSize = 3
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: number)) ?? "—"
  }
}
