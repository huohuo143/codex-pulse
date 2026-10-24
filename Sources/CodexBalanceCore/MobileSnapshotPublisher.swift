import Foundation
import CryptoKit
import CodexMobileCore

/// The adapter is deliberately outside the mobile module: filesystem/log readers and
/// desktop account authentication never become dependencies of the iOS app.
public enum MobileSnapshotAdapter {
  public static func make(status: CodexStatus, device: MobileDevice) -> MobileAccountSnapshot {
    let scope = status.accountScope
    let official = status.limits.filter { $0.sourceName == "Codex app-server" }
    let events = official.isEmpty ? [status.main].compactMap { $0 }.filter { $0.sourceName == "Codex app-server" } : official
    let account = scope.map {
      MobileAccount(id: SHA256.hash(data: Data(("mobile-v1:" + $0).utf8)).map { String(format: "%02x", $0) }.joined(),
                    plan: (status.main?.planType ?? events.compactMap(\.planType).first))
    }
    var windows: [MobileQuotaWindow] = []
    if account != nil {
      var seen = Set<String>()
      for event in events.sorted(by: { $0.timestamp > $1.timestamp }) {
        for (slot, value) in [("primary", event.primary), ("secondary", event.secondary)] {
          guard let value, seen.insert(event.limitID + ":" + slot).inserted else { continue }
          windows.append(MobileQuotaWindow(id: event.limitID + ":" + slot, bucketID: event.limitID,
            bucketName: event.limitName.isEmpty ? nil : event.limitName,
            durationMinutes: value.windowMinutes > 0 ? value.windowMinutes : nil,
            usedPercent: value.usedPercent.isFinite ? min(100, max(0, value.usedPercent)) : nil,
            resetsAt: value.inferredReset ? nil : value.resetsAt))
        }
      }
    }
    let credits = account == nil ? nil : status.rateLimitResetCredits
    return MobileAccountSnapshot(publishedAt: status.generatedAt, device: device, account: account,
      quotaRead: account == nil ? MobileSourceRead() : read(status.quotaRead), windows: windows,
      resetCredits: credits.map { MobileResetCredits(availableCount: $0.availableCount,
        nearestExpiry: $0.availableCredits.compactMap(\.expiresAt).min(), read: read(status.resetCreditsRead)) })
  }

  private static func read(_ metadata: SourceReadMetadata?) -> MobileSourceRead {
    MobileSourceRead(sampledAt: metadata?.sampledAt, lastSuccessAt: metadata?.lastSuccessAt,
                     failed: metadata?.failure != nil)
  }
}

public actor MobileSnapshotPublisher {
  private let root: URL?
  private let environment: [String: String]
  private let device: MobileDevice
  private var previous: MobileAccountSnapshot?
  private var previousDetail: MobileDetailSnapshot?

  public init(root: URL? = nil, deviceID: String? = nil, deviceName: String? = nil,
              environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.root = root; self.environment = environment
    let preferences = PulsePreferences.shared
    let id = deviceID ?? preferences.string(forKey: "mobileSnapshotDeviceID") ?? UUID().uuidString.lowercased()
    if deviceID == nil { preferences.set(id, forKey: "mobileSnapshotDeviceID") }
    device = MobileDevice(id: id, name: deviceName ?? Host.current().localizedName ?? "Mac")
  }

  public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    if let isolated = environment["CODEX_PULSE_SUPPORT_DIR"] {
      return URL(fileURLWithPath: isolated).appendingPathComponent("mobile-snapshots", isDirectory: true)
    }
    if let override = environment["CODEX_PULSE_MOBILE_SYNC_DIR"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let cloud = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    guard FileManager.default.fileExists(atPath: cloud.path) else { return nil }
    return cloud.appendingPathComponent("算力码表/移动快照", isDirectory: true)
  }

  @discardableResult
  public func publish(_ status: CodexStatus) throws -> URL? {
    guard let directory = root ?? Self.defaultRoot(environment: environment) else { return nil }
    let next = MobileSnapshotAdapter.make(status: status, device: device)
    if let previous, next.publishedAt < previous.publishedAt || next == previous { return nil }
    // Avoid turning fast desktop polling into continuous iCloud writes. Changed
    // account/quota/failure states publish immediately; stable readings heartbeat once a minute.
    if let previous, next.publishedAt.timeIntervalSince(previous.publishedAt) < 60,
       samePresentation(next, previous) { return nil }
    let fileID = SHA256.hash(data: Data(device.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    let url = directory.appendingPathComponent("device-" + fileID + ".json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if previous == nil, let data = try? Data(contentsOf: url), let saved = try? MobileAccountSnapshot.decode(data),
       saved.device.id == next.device.id, saved.publishedAt > next.publishedAt { return nil }
    let data = try next.encoded()
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
      do { try data.write(to: target, options: .atomic) } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError as NSError? { throw error }
    previous = next
    return url
  }

  public func publishDetails(status: CodexStatus, usageAt: Date?, history: [QuotaSnapshot], forecast: QuotaForecast?, budgets: [ProjectBudget], radar: CodexRadarSnapshot?, rate: ExchangeRateSnapshot?, health: ReliabilitySnapshot) throws {
    guard let directory = root ?? Self.defaultRoot(environment: environment) else { return }
    let account = MobileSnapshotAdapter.make(status: status, device: device).account?.id
    if let previousDetail, previousDetail.publishedAt > status.generatedAt { return }
    let next = MobileDetailAdapter.make(status: status, device: device, usageAt: usageAt, history: history,
      forecast: forecast, budgets: budgets, radar: radar, rate: rate, health: health)
    if let previousDetail, previousDetail.accountID == account,
      status.generatedAt.timeIntervalSince(previousDetail.publishedAt) < 60,
      next.radar == previousDetail.radar { return }
    let id = SHA256.hash(data: Data(device.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    let url = directory.appendingPathComponent("detail-" + id + ".json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if previousDetail == nil, let data = try? Data(contentsOf: url), let saved = try? MobileDetailSnapshot.decode(data), saved.publishedAt > next.publishedAt { return }
    let data = try next.encoded()
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
      do { try data.write(to: target, options: .atomic) } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError as NSError? { throw error }
    previousDetail = next
  }

  private func samePresentation(_ lhs: MobileAccountSnapshot, _ rhs: MobileAccountSnapshot) -> Bool {
    lhs.account == rhs.account && lhs.device == rhs.device && lhs.windows == rhs.windows
      && lhs.quotaRead.failed == rhs.quotaRead.failed
      && (lhs.quotaRead.sampledAt == nil) == (rhs.quotaRead.sampledAt == nil)
      && (lhs.quotaRead.lastSuccessAt == nil) == (rhs.quotaRead.lastSuccessAt == nil)
      && lhs.resetCredits?.availableCount == rhs.resetCredits?.availableCount
      && lhs.resetCredits?.nearestExpiry == rhs.resetCredits?.nearestExpiry
      && lhs.resetCredits?.read.failed == rhs.resetCredits?.read.failed
      && (lhs.resetCredits?.read.sampledAt == nil) == (rhs.resetCredits?.read.sampledAt == nil)
      && (lhs.resetCredits?.read.lastSuccessAt == nil) == (rhs.resetCredits?.read.lastSuccessAt == nil)
  }
}
