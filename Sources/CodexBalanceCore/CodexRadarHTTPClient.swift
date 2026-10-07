import Foundation

enum CodexRadarHTTPClient {
  struct Options: Sendable {
    var maximumAttempts = 3
    var maximumDuration: TimeInterval = 30
    var requestTimeout: TimeInterval = 12
    var retryDelays: [TimeInterval] = [1, 3]

    static let primary = Options()
    static let ancillary = Options(maximumAttempts: 1, maximumDuration: 6, requestTimeout: 6)
  }

  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
  }()

  static func fetch(
    url: URL,
    accept: String,
    cacheBust: Bool,
    session: URLSession,
    options: Options
  ) async throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(options.maximumDuration))
    let attempts = max(1, options.maximumAttempts)
    for attempt in 0..<attempts {
      try Task.checkCancellation()
      let remaining = seconds(ContinuousClock.now.duration(to: deadline))
      guard remaining > 0 else { throw URLError(.timedOut) }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      if cacheBust {
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "pulse_check", value: UUID().uuidString))
        components?.queryItems = items
      }
      var request = URLRequest(
        url: components?.url ?? url,
        cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
        timeoutInterval: min(options.requestTimeout, remaining)
      )
      request.httpMethod = "GET"
      request.httpShouldHandleCookies = false
      request.setValue(accept, forHTTPHeaderField: "Accept")
      request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
      request.setValue("no-cache", forHTTPHeaderField: "Pragma")
      request.setValue("CodexPulse/2.11.3 (public-read-only-radar-sync)", forHTTPHeaderField: "User-Agent")
      do {
        let (data, response) = try await boundedResponse(
          for: request, session: session, timeout: min(options.requestTimeout, remaining)
        )
        guard let http = response as? HTTPURLResponse else { throw CodexRadarError.invalidPayload }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw CodexRadarError.accessDenied
        case 429:
          if let delay = retryAfter(http, now: Date()) {
            throw CodexRadarError.retryAfter(status: http.statusCode, seconds: delay)
          }
          throw CodexRadarError.rateLimited
        default:
          if let delay = retryAfter(http, now: Date()) {
            throw CodexRadarError.retryAfter(status: http.statusCode, seconds: delay)
          }
          throw CodexRadarError.server(http.statusCode)
        }
      } catch {
        try Task.checkCancellation()
        guard attempt + 1 < attempts, isTransient(error) else { throw error }
        let delay = options.retryDelays.isEmpty ? 0
          : options.retryDelays[min(attempt, options.retryDelays.count - 1)]
        guard ContinuousClock.now.advanced(by: .seconds(delay)) < deadline else { throw error }
        try await Task.sleep(for: .seconds(delay))
      }
    }
    throw URLError(.timedOut)
  }

  private static func boundedResponse(
    for request: URLRequest,
    session: URLSession,
    timeout: TimeInterval
  ) async throws -> (Data, URLResponse) {
    // A request timeout alone measures inactivity. Bound the whole transfer as
    // well so a slow or never-ending response cannot leave the refresh gate busy.
    try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
      group.addTask { try await session.data(for: request) }
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw URLError(.cancelled) }
      return result
    }
  }

  private static func isTransient(_ error: Error) -> Bool {
    if let error = error as? URLError {
      return [.networkConnectionLost, .timedOut, .cannotFindHost,
              .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
    if case .server(let status) = error as? CodexRadarError {
      return [408, 425, 500, 502, 503, 504].contains(status)
    }
    return false
  }

  private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = TimeInterval(value), seconds.isFinite {
      return min(24 * 60 * 60, max(0, seconds))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value).map { min(24 * 60 * 60, max(0, $0.timeIntervalSince(now))) }
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
