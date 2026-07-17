import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexRadarError: Error, Equatable, LocalizedError, Sendable {
  case accessDenied
  case rateLimited
  case invalidPayload
  case server(Int)

  public var errorDescription: String? {
    switch self {
    case .accessDenied:
      "Codex 雷达公开摘要暂不可访问"
    case .rateLimited:
      "Codex 雷达请求过于频繁，请稍后再试"
    case .invalidPayload:
      "Codex 雷达返回的数据格式无法识别"
    case .server(let status):
      "Codex 雷达服务暂不可用（HTTP \(status)）"
    }
  }
}

public actor CodexRadarService {
  public typealias Fetcher = @Sendable () async throws -> Data

  public static let attributionText = "数据来自 重置雷达小程序公开源"
  public static let endpointURL = URL(string: "https://api.tangka.online/radar-api/dashboard")!
  public static let siteURL = endpointURL
  public static let legacyPublicJSONURL = URL(string: "https://codexradar.com/current.json")!
  public static let fullAPIURL = URL(string: "https://codexradar.com/api/v1/current")!
  public static let refreshInterval: TimeInterval = 30 * 60
  public static let publicSummaryModeText = "重置雷达小程序公开源，无需 API Key"

  private let fetcher: Fetcher
  private let publicPageFetcher: Fetcher?
  private let now: @Sendable () -> Date
  private let cacheDuration: TimeInterval
  private var cachedSnapshot: CodexRadarSnapshot?
  private var cachedAt: Date?

  public init(
    fetcher: Fetcher? = nil,
    publicPageFetcher: Fetcher? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    cacheDuration: TimeInterval = CodexRadarService.refreshInterval
  ) {
    self.now = now
    self.cacheDuration = cacheDuration
    if let fetcher {
      self.fetcher = fetcher
      self.publicPageFetcher = publicPageFetcher
    } else {
      self.fetcher = {
        try await CodexRadarService.fetch(
          url: CodexRadarService.endpointURL,
          accept: "application/json"
        )
      }
      self.publicPageFetcher = publicPageFetcher
    }
  }

  public func current(force: Bool = false) async throws -> CodexRadarSnapshot {
    if !force,
       let cachedSnapshot,
       let cachedAt,
       now().timeIntervalSince(cachedAt) < cacheDuration {
      return cachedSnapshot
    }
    let data = try await fetcher()
    var snapshot = try CodexRadarCodec.decode(data)
    if let publicPageFetcher,
       let pageData = try? await publicPageFetcher(),
       let judgement = try? CodexRadarPublicPageParser.decode(pageData, now: now()) {
      snapshot.publicJudgement = judgement
    }
    if let cachedSnapshot,
       let cachedUpdate = cachedSnapshot.latestUpdate,
       let incomingUpdate = snapshot.latestUpdate,
       incomingUpdate < cachedUpdate {
      cachedAt = now()
      return cachedSnapshot
    }
    cachedSnapshot = snapshot
    cachedAt = now()
    return snapshot
  }

  public func clearCache() {
    cachedSnapshot = nil
    cachedAt = nil
  }

  private static func fetch(url: URL, accept: String) async throws -> Data {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 12
    )
    request.httpMethod = "GET"
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("CodexSuanliMeter/2.9.0 (personal-read-only-reset-radar)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw CodexRadarError.invalidPayload }
    switch http.statusCode {
    case 200..<300:
      return data
    case 401, 403:
      throw CodexRadarError.accessDenied
    case 429:
      throw CodexRadarError.rateLimited
    default:
      throw CodexRadarError.server(http.statusCode)
    }
  }
}
