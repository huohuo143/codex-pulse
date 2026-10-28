import Foundation

/// Records the source actually used, independently of the user's preference.
public struct TiboReadRoute: Codable, Equatable, Sendable {
  public enum XState: String, Codable, Sendable {
    case notChecked, success, loginRequired, busy, incomplete, unavailable
  }
  public var checkedAt: Date?
  public var xState: XState
  public var xLatestPostAt: Date?
  public var xPostIDs: [String]? = nil
  public var xMissingKnownPostIDs: [String]? = nil
  public var usedBackup: Bool
  public var backupSucceeded: Bool

  public var message: String {
    switch xState {
    case .notChecked: return "X 优先已启用，等待下一次检查；当前显示已保存动态。"
    case .success: return "本轮已直接读取 X 的发帖与回复；三个网站待命。"
    default:
      let reason: String
      switch xState {
      case .loginRequired: reason = "X 要求登录"
      case .busy: reason = "X 窗口正在使用"
      case .incomplete: reason = "X 本轮未加载出已知的较新动态"
      default: reason = "X 暂时无法读取"
      }
      return reason + (backupSucceeded ? "，本轮已自动使用备用网站。" : "，备用网站也未读取成功，保留上次动态。")
    }
  }
}

struct TiboRoutedPage: Codable, Sendable {
  var format = "codex-pulse-x-first-v1"
  var route: TiboReadRoute
  var directData: Data?
  var backupData: Data?

  static func decode(_ data: Data) -> TiboRoutedPage? {
    guard let value = try? JSONDecoder().decode(Self.self, from: data), value.format == "codex-pulse-x-first-v1" else { return nil }
    return value
  }
}

enum CodexRadarXFirstSource {
  typealias Fetcher = @Sendable () async throws -> Data

  /// The service owns the persisted ten-minute budget. A successful X fetch
  /// never calls the standby feed; failures and detectably incomplete timelines do.
  static func fetch(x: Fetcher, backup: Fetcher, now: Date, knownLatest: Date? = nil, knownRecentPostIDs: [String] = []) async throws -> Data {
    var route = TiboReadRoute(checkedAt: now, xState: .unavailable, usedBackup: false, backupSucceeded: false)
    var directData: Data?
    do {
      let data = try await x()
      try Task.checkCancellation()
      let page = try CodexRadarPublicPageParser.decode(data, now: now)
      guard let latest = page.tiboFeed.posts.compactMap(\.publishedAt).max(), !page.tiboFeed.posts.isEmpty else { throw XTiboTimeline.ReadError.empty }
      directData = data; route.xLatestPostAt = latest
      route.xPostIDs = page.tiboFeed.posts.map(\.id)
      let actualIDs = Set(route.xPostIDs ?? [])
      let missing = knownRecentPostIDs.filter { !actualIDs.contains($0) }
      route.xMissingKnownPostIDs = missing
      if !missing.isEmpty || knownLatest.map({ latest < $0.addingTimeInterval(-1) }) == true {
        route.xState = .incomplete
      } else {
        route.xState = .success
        return try JSONEncoder().encode(TiboRoutedPage(route: route, directData: data))
      }
    } catch is CancellationError { throw CancellationError() }
    catch {
      switch error as? XTiboTimeline.ReadError {
      case .loginRequired: route.xState = .loginRequired
      case .busy: route.xState = .busy
      default: route.xState = .unavailable
      }
    }
    try Task.checkCancellation()
    route.usedBackup = true
    var backupData: Data?
    do {
      let data = try await backup()
      try Task.checkCancellation()
      backupData = data
      route.backupSucceeded = (try? CodexRadarPublicPageParser.decode(data, now: now)) != nil
    } catch is CancellationError { throw CancellationError() }
    catch { /* Keep the route even when every source fails; never invent a success. */ }
    return try JSONEncoder().encode(TiboRoutedPage(route: route, directData: directData, backupData: backupData))
  }
}
