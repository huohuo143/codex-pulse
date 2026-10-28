import Foundation

/// Versioned, credential-free wire contract shared by the Mac publisher, iOS app and widget.
/// All timestamps describe the original source read, never the time iCloud downloaded a file.
public struct MobileAccountSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var schemaVersion: Int = currentVersion
  public var publishedAt: Date
  public var device: MobileDevice
  public var account: MobileAccount?
  public var quotaRead: MobileSourceRead
  public var windows: [MobileQuotaWindow]
  public var resetCredits: MobileResetCredits?

  public init(publishedAt: Date, device: MobileDevice, account: MobileAccount?,
              quotaRead: MobileSourceRead, windows: [MobileQuotaWindow], resetCredits: MobileResetCredits? = nil) {
    self.publishedAt = publishedAt; self.device = device; self.account = account
    self.quotaRead = quotaRead; self.windows = windows; self.resetCredits = resetCredits
  }

  public var preferredWindow: MobileQuotaWindow? {
    windows.sorted {
      if ($0.bucketID == "codex") != ($1.bucketID == "codex") { return $0.bucketID == "codex" }
      if $0.durationMinutes != $1.durationMinutes { return ($0.durationMinutes ?? 0) > ($1.durationMinutes ?? 0) }
      return $0.id < $1.id
    }.first
  }

  public func validate(now: Date = Date()) throws {
    guard schemaVersion == Self.currentVersion else { throw MobileSnapshotError.unsupportedVersion }
    guard publishedAt <= now.addingTimeInterval(300), !device.id.isEmpty, device.id.count <= 100,
          !device.name.isEmpty, device.name.count <= 160, windows.count <= 24,
          Set(windows.map(\.id)).count == windows.count else { throw MobileSnapshotError.invalidData }
    if let account {
      guard !account.id.isEmpty, account.id.count <= 128, (account.plan?.count ?? 0) <= 80 else {
        throw MobileSnapshotError.invalidData
      }
    } else if !windows.isEmpty || resetCredits != nil { throw MobileSnapshotError.invalidData }
    for window in windows {
      guard !window.id.isEmpty, window.id.count <= 160, window.bucketID.count <= 100,
            (window.bucketName?.count ?? 0) <= 160 else { throw MobileSnapshotError.invalidData }
      if let used = window.usedPercent, !used.isFinite || !(0...100).contains(used) { throw MobileSnapshotError.invalidData }
      if let duration = window.durationMinutes, !duration.isFinite || duration <= 0 || duration > 5_256_000 { throw MobileSnapshotError.invalidData }
    }
    if let resetCredits, resetCredits.availableCount < 0 { throw MobileSnapshotError.invalidData }
  }

  public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
    guard data.count <= 131_072 else { throw MobileSnapshotError.tooLarge }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(Self.self, from: data)
    try snapshot.validate(now: now)
    return snapshot
  }

  public func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}

public struct MobileDevice: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct MobileAccount: Codable, Equatable, Sendable {
  /// One-way identifier scoped to the source device; never an email or raw account ID.
  public var id: String
  public var plan: String?
  public init(id: String, plan: String? = nil) { self.id = id; self.plan = plan }
  public var label: String { "账号 · " + id.prefix(6) }
}

public enum MobileFreshness: String, Sendable {
  case fresh, cached, expired, waitingForReset, unavailable
  public var label: String {
    switch self {
    case .fresh: return "数据已更新"
    case .cached: return "上次采样 · 等待更新"
    case .expired: return "上次记录 · 等待同步"
    case .waitingForReset: return "等待新周期数据"
    case .unavailable: return "暂无额度数据"
    }
  }

  /// A source record remains useful after an idle period, but its timestamp and
  /// stale status must remain visible. Reset boundaries are handled separately.
  public var canDisplayValue: Bool { self == .fresh || self == .cached || self == .expired }
}

public struct MobileSourceRead: Codable, Equatable, Sendable {
  public var sampledAt: Date?
  public var lastSuccessAt: Date?
  public var failed: Bool
  public init(sampledAt: Date? = nil, lastSuccessAt: Date? = nil, failed: Bool = false) {
    self.sampledAt = sampledAt; self.lastSuccessAt = lastSuccessAt; self.failed = failed
  }
  public func state(at now: Date, resetsAt: Date? = nil) -> MobileFreshness {
    guard let sampledAt, let lastSuccessAt, sampledAt <= now.addingTimeInterval(5),
          lastSuccessAt <= now.addingTimeInterval(5) else { return .unavailable }
    if let resetsAt, resetsAt <= now { return .waitingForReset }
    let age = now.timeIntervalSince(min(sampledAt, lastSuccessAt))
    if age > 1800 { return .expired }
    if failed || age > 300 { return .cached }
    return .fresh
  }
}

public struct MobileQuotaWindow: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var bucketID: String
  public var bucketName: String?
  public var durationMinutes: Double?
  public var usedPercent: Double?
  public var resetsAt: Date?
  public init(id: String, bucketID: String, bucketName: String? = nil, durationMinutes: Double?,
              usedPercent: Double?, resetsAt: Date?) {
    self.id = id; self.bucketID = bucketID; self.bucketName = bucketName
    self.durationMinutes = durationMinutes; self.usedPercent = usedPercent; self.resetsAt = resetsAt
  }
  public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
  public var durationLabel: String {
    guard let minutes = durationMinutes else { return "额度周期" }
    if minutes.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(minutes / 1440)) 天额度" }
    if minutes.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(minutes / 60)) 小时额度" }
    return "\(minutes.formatted(.number.precision(.fractionLength(0...1)))) 分钟额度"
  }
  public func displayRemaining(read: MobileSourceRead, at now: Date) -> Double? {
    switch read.state(at: now, resetsAt: resetsAt) {
    case .fresh, .cached, .expired: return remainingPercent
    default: return nil
    }
  }
}

public struct MobileResetCredits: Codable, Equatable, Sendable {
  public var availableCount: Int
  public var nearestExpiry: Date?
  public var read: MobileSourceRead
  public init(availableCount: Int, nearestExpiry: Date?, read: MobileSourceRead) {
    self.availableCount = availableCount; self.nearestExpiry = nearestExpiry; self.read = read
  }
  public func isDisplayable(at now: Date) -> Bool {
    // A crossed expiry needs a fresh read; never subtract or redeem based on a countdown.
    if let nearestExpiry, nearestExpiry <= now { return false }
    return [.fresh, .cached].contains(read.state(at: now))
  }
}

public enum MobileSnapshotError: Error, LocalizedError {
  case unsupportedVersion, invalidData, tooLarge, sourceMissing, permissionLost, noSnapshots
  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion: return "快照版本暂不支持，请更新移动版。"
    case .invalidData: return "快照内容无效，已保留上次有效数据。"
    case .tooLarge: return "文件不是有效的移动快照。"
    case .sourceMissing: return "所选 Mac 尚无可读取的新快照，请检查 iCloud 同步。"
    case .permissionLost: return "同步目录访问已失效，请重新选择目录。"
    case .noSnapshots: return "目录中还没有移动快照，请先运行支持移动同步的 Mac 版。"
    }
  }
}

/// Selection is sticky: another device must never silently replace the chosen source.
public enum MobileSnapshotSelection {
  public static func select(_ snapshots: [MobileAccountSnapshot], deviceID: String?,
                            previous: MobileAccountSnapshot?) throws -> MobileAccountSnapshot? {
    let candidates = deviceID.map { id in snapshots.filter { $0.device.id == id } } ?? snapshots
    guard !candidates.isEmpty else { throw deviceID == nil ? MobileSnapshotError.noSnapshots : .sourceMissing }
    if deviceID == nil && Set(candidates.map { $0.device.id }).count > 1 { return nil }
    let newest = candidates.max { $0.publishedAt < $1.publishedAt }!
    if let previous, previous.device.id == newest.device.id, previous.publishedAt > newest.publishedAt { return previous }
    return newest
  }
}
