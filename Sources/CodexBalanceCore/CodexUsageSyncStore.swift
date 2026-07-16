import Foundation

public final class CodexUsageSyncStore: @unchecked Sendable {
  public let syncRoot: URL?
  public let app: ToolID
  public let deviceID: String
  public let deviceName: String
  public let hostName: String

  private let fileManager: FileManager

  public init(
    syncRoot: URL? = nil,
    app: ToolID = .codex,
    deviceID: String? = nil,
    deviceName: String? = nil,
    hostName: String? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager
    self.app = app
    self.syncRoot = syncRoot ?? Self.resolveSyncRoot(fileManager: fileManager, environment: environment)
    self.hostName = hostName ?? Self.currentHostName()
    let computerName = Self.currentComputerName() ?? self.hostName
    let resolvedID = deviceID
      ?? environment["CODEX_BALANCE_DEVICE_ID"].map { DeviceIdentity.slug(from: $0) }
      ?? Self.legacyDeviceID(hostName: self.hostName, syncRoot: self.syncRoot, app: app, fileManager: fileManager)
      ?? DeviceIdentity.slug(from: computerName)
    self.deviceID = resolvedID
    // 显示名优先级：显式参数 > 环境变量 > 本机已有同步文件里的名字（保持两台机器图例稳定）> 电脑名
    self.deviceName = deviceName
      ?? environment["CODEX_BALANCE_DEVICE_NAME"]
      ?? Self.existingDeviceName(deviceID: resolvedID, syncRoot: self.syncRoot, app: app, fileManager: fileManager)
      ?? computerName
  }

  /// 老用户平滑升级：本机主机名匹配旧的两台设备命名时，沿用旧 deviceID，
  /// 这样历史 iCloud 文件（macbook-pro-*.json / mac-studio-*.json）继续归属本机。
  private static func legacyDeviceID(
    hostName: String,
    syncRoot: URL?,
    app: ToolID,
    fileManager: FileManager
  ) -> String? {
    guard let syncRoot else { return nil }
    let normalized = hostName.lowercased()
    let candidate: String
    if normalized.contains("macbook") || normalized.contains("book") || normalized.contains("mbp") {
      candidate = "macbook-pro"
    } else if normalized.contains("studio") {
      candidate = "mac-studio"
    } else {
      return nil
    }
    let v2 = syncRoot.appendingPathComponent(DeviceIdentity.v2FileName(deviceID: candidate))
    let legacy = syncRoot.appendingPathComponent(DeviceIdentity.legacyFileName(deviceID: candidate))
    return fileManager.fileExists(atPath: v2.path) || fileManager.fileExists(atPath: legacy.path) ? candidate : nil
  }

  private static func existingDeviceName(
    deviceID: String,
    syncRoot: URL?,
    app: ToolID,
    fileManager: FileManager
  ) -> String? {
    guard let syncRoot else { return nil }
    let candidates = [
      syncRoot.appendingPathComponent(DeviceIdentity.v2FileName(deviceID: deviceID)),
      syncRoot.appendingPathComponent(DeviceIdentity.legacyFileName(deviceID: deviceID))
    ]
    for file in candidates {
      guard let data = try? Data(contentsOf: file),
            let snapshot = try? decoder.decode(CodexDeviceTokenUsage.self, from: data),
            !snapshot.deviceName.isEmpty
      else { continue }
      return snapshot.deviceName
    }
    return nil
  }

  private static func currentComputerName() -> String? {
    Host.current().localizedName
  }

  public func makeSnapshot(from stats: TokenStats, now: Date = Date()) -> CodexDeviceTokenUsage {
    CodexDeviceTokenUsage(
      schemaVersion: 4,
      app: app,
      deviceID: deviceID,
      deviceName: deviceName,
      hostName: hostName,
      updatedAt: now,
      todayTokens: stats.todayTokens,
      monthTokens: stats.monthTokens,
      sampleCount: stats.sampleCount,
      hourly: stats.hourly,
      modelHourly: stats.modelHourly,
      daily: stats.daily,
      monthly: stats.monthly
    )
  }

  public func persistAndReadSnapshots(
    from stats: TokenStats,
    now: Date = Date()
  ) -> [CodexDeviceTokenUsage] {
    let localSnapshot = makeSnapshot(from: stats, now: now)
    try? write(localSnapshot)
    return readSnapshots(including: localSnapshot)
  }

  public func write(_ snapshot: CodexDeviceTokenUsage) throws {
    guard let syncRoot else { return }
    try fileManager.createDirectory(at: syncRoot, withIntermediateDirectories: true)
    let data = try Self.encoder.encode(snapshot)
    try data.write(
      to: syncRoot.appendingPathComponent(DeviceIdentity.v2FileName(deviceID: snapshot.deviceID)),
      options: [.atomic]
    )
  }

  public func readSnapshots(including localSnapshot: CodexDeviceTokenUsage? = nil) -> [CodexDeviceTokenUsage] {
    var snapshots: [String: (snapshot: CodexDeviceTokenUsage, priority: Int)] = [:]
    if let localSnapshot, localSnapshot.app == app {
      snapshots[localSnapshot.deviceID] = (localSnapshot, 3)
    }

    guard let syncRoot else {
      return orderedSnapshots(snapshots.mapValues(\.snapshot))
    }

    let urls = (try? fileManager.contentsOfDirectory(
      at: syncRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []

    for url in urls where url.pathExtension.lowercased() == "json" {
      guard
        let data = try? Data(contentsOf: url),
        let snapshot = try? Self.decoder.decode(CodexDeviceTokenUsage.self, from: data),
        snapshot.app == app
      else { continue }

      let isV2File = url.lastPathComponent.hasSuffix("-codex-v2.json")
      let priority = isV2File ? 2 : 1
      if let existing = snapshots[snapshot.deviceID] {
        if existing.priority > priority { continue }
        if existing.priority == priority, existing.snapshot.updatedAt >= snapshot.updatedAt { continue }
      }
      snapshots[snapshot.deviceID] = (snapshot, priority)
    }

    return orderedSnapshots(snapshots.mapValues(\.snapshot))
  }

  /// 本机排最前，其余按显示名排序（支持任意台数设备）
  private func orderedSnapshots(_ snapshots: [String: CodexDeviceTokenUsage]) -> [CodexDeviceTokenUsage] {
    snapshots.values.sorted { lhs, rhs in
      if lhs.deviceID == deviceID { return true }
      if rhs.deviceID == deviceID { return false }
      return lhs.deviceName.localizedStandardCompare(rhs.deviceName) == .orderedAscending
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func resolveSyncRoot(fileManager: FileManager, environment: [String: String]) -> URL? {
    if let override = environment["CODEX_BALANCE_SYNC_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
    }

    guard let cloudDocs = cloudDocsRoot(fileManager: fileManager) else { return nil }

    return cloudDocs
      .appendingPathComponent("算力码表")
      .appendingPathComponent("设备统计")
  }

  private static func cloudDocsRoot(fileManager: FileManager) -> URL? {
    let cloudDocs = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Mobile Documents")
      .appendingPathComponent("com~apple~CloudDocs")
    guard fileManager.fileExists(atPath: cloudDocs.path) else { return nil }
    return cloudDocs
  }

  private static func currentHostName() -> String {
    let processHost = ProcessInfo.processInfo.hostName
    if !processHost.isEmpty { return processHost }
    return Host.current().localizedName ?? "unknown-mac"
  }
}
