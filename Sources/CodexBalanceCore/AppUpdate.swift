import Foundation

public struct SemanticVersion: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int
  public let prerelease: String?

  public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease?.isEmpty == false ? prerelease : nil
  }

  public init?(_ rawValue: String) {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.first == "v" || value.first == "V" {
      value.removeFirst()
    }
    value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
    let releaseParts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let numberParts = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(numberParts.count),
          numberParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    else { return nil }

    let numbers = numberParts.compactMap { Int($0) }
    guard numbers.count == numberParts.count else { return nil }
    major = numbers[0]
    minor = numbers.count > 1 ? numbers[1] : 0
    patch = numbers.count > 2 ? numbers[2] : 0
    prerelease = releaseParts.count > 1 && !releaseParts[1].isEmpty ? String(releaseParts[1]) : nil
  }

  public var description: String {
    let base = "\(major).\(minor).\(patch)"
    return prerelease.map { "\(base)-\($0)" } ?? base
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    let left = [lhs.major, lhs.minor, lhs.patch]
    let right = [rhs.major, rhs.minor, rhs.patch]
    if left != right {
      return left.lexicographicallyPrecedes(right)
    }
    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil): return false
    case (nil, _): return false
    case (_, nil): return true
    case let (left?, right?): return prereleaseIsLower(left, than: right)
    }
  }

  private static func prereleaseIsLower(_ lhs: String, than rhs: String) -> Bool {
    let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
    let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
    for index in 0..<max(left.count, right.count) {
      guard index < left.count else { return true }
      guard index < right.count else { return false }
      let l = String(left[index])
      let r = String(right[index])
      if l == r { continue }
      if let li = Int(l), let ri = Int(r) { return li < ri }
      if Int(l) != nil { return true }
      if Int(r) != nil { return false }
      return l.localizedStandardCompare(r) == .orderedAscending
    }
    return false
  }
}

public struct AppReleaseAsset: Codable, Hashable, Sendable {
  public let name: String
  public let browserDownloadURL: URL
  public let contentType: String?
  public let size: Int?
  public let state: String?

  enum CodingKeys: String, CodingKey {
    case name
    case browserDownloadURL = "browser_download_url"
    case contentType = "content_type"
    case size
    case state
  }

  public init(
    name: String,
    browserDownloadURL: URL,
    contentType: String? = nil,
    size: Int? = nil,
    state: String? = nil
  ) {
    self.name = name
    self.browserDownloadURL = browserDownloadURL
    self.contentType = contentType
    self.size = size
    self.state = state
  }
}

public struct AppRelease: Codable, Hashable, Sendable {
  public let tagName: String
  public let name: String?
  public let body: String?
  public let htmlURL: URL
  public let publishedAt: Date?
  public let draft: Bool
  public let prerelease: Bool
  public let assets: [AppReleaseAsset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case name
    case body
    case htmlURL = "html_url"
    case publishedAt = "published_at"
    case draft
    case prerelease
    case assets
  }

  public init(
    tagName: String,
    name: String? = nil,
    body: String? = nil,
    htmlURL: URL,
    publishedAt: Date? = nil,
    draft: Bool = false,
    prerelease: Bool = false,
    assets: [AppReleaseAsset] = []
  ) {
    self.tagName = tagName
    self.name = name
    self.body = body
    self.htmlURL = htmlURL
    self.publishedAt = publishedAt
    self.draft = draft
    self.prerelease = prerelease
    self.assets = assets
  }

  public var version: SemanticVersion? { SemanticVersion(tagName) }

  public var preferredDMGURL: URL? {
    assets.first {
      $0.name.lowercased().hasSuffix(".dmg")
        && $0.browserDownloadURL.scheme == "https"
        && ($0.state == nil || $0.state == "uploaded")
    }?.browserDownloadURL
  }
}

public enum AppUpdateAvailability: String, Codable, Hashable, Sendable {
  case updateAvailable
  case upToDate
  case localVersionNewer
}

public struct AppUpdateResult: Codable, Hashable, Sendable {
  public let availability: AppUpdateAvailability
  public let currentVersion: SemanticVersion
  public let release: AppRelease
  public let checkedAt: Date

  public init(
    availability: AppUpdateAvailability,
    currentVersion: SemanticVersion,
    release: AppRelease,
    checkedAt: Date
  ) {
    self.availability = availability
    self.currentVersion = currentVersion
    self.release = release
    self.checkedAt = checkedAt
  }
}

public enum AppUpdateError: LocalizedError, Sendable {
  case invalidCurrentVersion
  case invalidEndpoint
  case invalidResponse
  case httpStatus(Int)
  case invalidReleaseVersion
  case draftRelease
  case rateLimited(Date)
  case retryDeferred(Date)

  public var errorDescription: String? {
    switch self {
    case .invalidCurrentVersion: "当前 APP 版本格式无效"
    case .invalidEndpoint: "版本更新地址无效"
    case .invalidResponse: "更新服务器返回了无法识别的响应"
    case let .httpStatus(code): "更新服务器返回 HTTP \(code)"
    case .invalidReleaseVersion: "线上版本号格式无效"
    case .draftRelease: "线上最新版本仍是草稿"
    case let .rateLimited(date): "GitHub 暂时限流，可在 " + date.formatted(date: .omitted, time: .shortened) + " 后重试"
    case let .retryDeferred(date): "请在 " + date.formatted(date: .omitted, time: .shortened) + " 后重试"
    }
  }
}

public struct AppUpdateRetryState: Codable, Hashable, Sendable {
  public var apiRetryAt: Date?
  public var nextAttemptAt: Date?
  public var failureCount: Int = 0

  public init(apiRetryAt: Date? = nil, nextAttemptAt: Date? = nil, failureCount: Int = 0) {
    self.apiRetryAt = apiRetryAt
    self.nextAttemptAt = nextAttemptAt
    self.failureCount = min(6, max(0, failureCount))
  }

  public init(data: Data?) {
    self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
  }
}

public actor GitHubReleaseUpdateService {
  public static let defaultEndpoint = URL(string: "https://api.github.com/repos/huohuo143/codex-pulse/releases/latest")!
  public static let defaultManifestEndpoint = URL(string: "https://raw.githubusercontent.com/huohuo143/codex-pulse/main/updates/latest.json")!
  public static let repositoryURL = "https://github.com/huohuo143/codex-pulse"

  private let endpoint: URL
  private let manifestEndpoint: URL?
  private let session: URLSession
  private var retryState: AppUpdateRetryState
  private var inFlight: Task<AppUpdateResult, Error>?

  public init(endpoint: URL = defaultEndpoint, session: URLSession = .shared,
              manifestEndpoint: URL? = defaultManifestEndpoint, retryState: AppUpdateRetryState = .init()) {
    self.endpoint = endpoint
    self.session = session
    self.manifestEndpoint = manifestEndpoint
    self.retryState = retryState
  }

  public func retryStateSnapshot() -> AppUpdateRetryState { retryState }

  public func check(currentVersion rawCurrentVersion: String, now: Date = Date()) async throws -> AppUpdateResult {
    guard let currentVersion = SemanticVersion(rawCurrentVersion) else { throw AppUpdateError.invalidCurrentVersion }
    if let inFlight { return try await inFlight.value }
    if let retryAt = retryState.nextAttemptAt, retryAt > now { throw AppUpdateError.retryDeferred(retryAt) }
    let task = Task { try await self.performCheck(currentVersion: currentVersion, now: now) }
    inFlight = task
    defer { inFlight = nil }
    return try await task.value
  }

  private func performCheck(currentVersion: SemanticVersion, now: Date) async throws -> AppUpdateResult {
    do {
      if let manifestEndpoint,
         let release = try? await fetchRelease(url: manifestEndpoint, manifest: true, currentVersion: currentVersion, now: now) {
        retryState.failureCount = 0
        retryState.nextAttemptAt = nil
        return try Self.evaluate(release: release, currentVersion: currentVersion, checkedAt: now)
      }
      if let retryAt = retryState.apiRetryAt, retryAt > now { throw AppUpdateError.rateLimited(retryAt) }
      let release = try await fetchRelease(url: endpoint, manifest: false, currentVersion: currentVersion, now: now)
      retryState.failureCount = 0
      retryState.nextAttemptAt = nil
      return try Self.evaluate(release: release, currentVersion: currentVersion, checkedAt: now)
    } catch {
      retryState.failureCount = min(5, max(0, retryState.failureCount)) + 1
      let delay = min(3600, 60 * pow(2, Double(retryState.failureCount - 1)))
      var next = now.addingTimeInterval(delay)
      if manifestEndpoint == nil, let apiRetryAt = retryState.apiRetryAt { next = max(next, apiRetryAt) }
      retryState.nextAttemptAt = next
      throw error
    }
  }

  private func fetchRelease(url: URL, manifest: Bool, currentVersion: SemanticVersion, now: Date) async throws -> AppRelease {
    guard url.scheme == "https" else { throw AppUpdateError.invalidEndpoint }
    var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 8)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("Codex-Pulse/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
    if http.statusCode != 200 {
      let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
      let limited = http.statusCode == 429 || http.statusCode == 403 && (remaining == "0" || http.value(forHTTPHeaderField: "retry-after") != nil || String(decoding: data.prefix(4096), as: UTF8.self).lowercased().contains("rate limit"))
      if !manifest && limited {
        let retryAt = Self.rateLimitRetryAt(response: http, now: now)
        retryState.apiRetryAt = retryAt
        throw AppUpdateError.rateLimited(retryAt)
      }
      throw AppUpdateError.httpStatus(http.statusCode)
    }
    if manifest {
      struct ManifestSchema: Decodable { let schemaVersion: Int }
      guard (try? JSONDecoder().decode(ManifestSchema.self, from: data).schemaVersion) == 1 else { throw AppUpdateError.invalidResponse }
    }
    let release = try Self.decodeRelease(from: data)
    guard !release.draft, !release.prerelease, release.version?.prerelease == nil,
          release.version != nil, release.publishedAt != nil else { throw AppUpdateError.invalidReleaseVersion }
    let page = Self.repositoryURL + "/releases/tag/" + release.tagName
    guard release.htmlURL.absoluteString == page else { throw AppUpdateError.invalidResponse }
    let prefix = Self.repositoryURL + "/releases/download/" + release.tagName + "/"
    guard release.assets.allSatisfy({ asset in
      asset.browserDownloadURL.scheme == "https" && asset.browserDownloadURL.host == "github.com"
        && asset.browserDownloadURL.user == nil && asset.browserDownloadURL.password == nil
        && asset.browserDownloadURL.absoluteString.hasPrefix(prefix)
    }) else { throw AppUpdateError.invalidResponse }
    return release
  }

  public static func rateLimitRetryAt(response: HTTPURLResponse, now: Date) -> Date {
    var dates = [now.addingTimeInterval(60)]
    if let raw = response.value(forHTTPHeaderField: "retry-after") {
      if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { dates.append(now.addingTimeInterval(seconds)) }
      else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: raw) { dates.append(date) }
      }
    }
    if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
       let raw = response.value(forHTTPHeaderField: "x-ratelimit-reset"), let seconds = Double(raw), seconds.isFinite {
      dates.append(Date(timeIntervalSince1970: seconds))
    }
    return dates.max() ?? now.addingTimeInterval(60)
  }

  public static func decodeRelease(from data: Data) throws -> AppRelease {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(AppRelease.self, from: data)
  }

  public static func evaluate(
    release: AppRelease,
    currentVersion: SemanticVersion,
    checkedAt: Date = Date()
  ) throws -> AppUpdateResult {
    guard !release.draft else { throw AppUpdateError.draftRelease }
    guard let remoteVersion = release.version else { throw AppUpdateError.invalidReleaseVersion }
    let availability: AppUpdateAvailability
    if remoteVersion > currentVersion {
      availability = .updateAvailable
    } else if remoteVersion == currentVersion {
      availability = .upToDate
    } else {
      availability = .localVersionNewer
    }
    return AppUpdateResult(
      availability: availability,
      currentVersion: currentVersion,
      release: release,
      checkedAt: checkedAt
    )
  }
}
