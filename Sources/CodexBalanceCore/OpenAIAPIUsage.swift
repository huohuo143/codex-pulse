import Foundation

/// OpenAI's organization cost report, separate from ChatGPT/Codex credits.
public struct OpenAIAPICostReading: Codable, Equatable, Sendable {
  public var costUSD: Double
  public var periodStart: Date
  public var sampledAt: Date

  public init(costUSD: Double, periodStart: Date, sampledAt: Date) {
    self.costUSD = costUSD
    self.periodStart = periodStart
    self.sampledAt = sampledAt
  }

  public func isCurrentPeriod(at now: Date) -> Bool {
    periodStart == OpenAIAPIUsageReader.monthStart(at: now)
  }
}

/// User-confirmed billing data. This is never inferred from organization costs.
public struct OpenAIAPIGrantConfirmation: Codable, Equatable, Sendable {
  public var totalUSD: Double
  public var remainingUSD: Double
  public var checkedAt: Date
  public var expiresAt: Date?

  public init?(totalUSD: Double, remainingUSD: Double, checkedAt: Date, expiresAt: Date? = nil) {
    guard totalUSD.isFinite, totalUSD > 0, totalUSD <= 1_000_000_000,
          remainingUSD.isFinite, remainingUSD >= 0, remainingUSD <= totalUSD else { return nil }
    self.totalUSD = totalUSD
    self.remainingUSD = remainingUSD
    self.checkedAt = checkedAt
    self.expiresAt = expiresAt
  }

  public func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

public enum OpenAIAPIUsageError: Error, Equatable, Sendable {
  case unauthorized, forbidden, rateLimited(retryAfter: TimeInterval?), unavailable, invalidResponse
}

public struct OpenAIAPICostPage: Decodable, Sendable {
  public struct Amount: Decodable, Sendable { public let value: Double?; public let currency: String? }
  public struct Entry: Decodable, Sendable { public let amount: Amount? }
  public struct Bucket: Decodable, Sendable {
    public let start_time: Int64
    public let results: [Entry]
  }
  public let data: [Bucket]
  public let has_more: Bool
  public let next_page: String?

  public func validatedTotal(from periodStart: Date, before periodEnd: Date) throws -> Double {
    var total = 0.0
    for bucket in data {
      let start = Date(timeIntervalSince1970: TimeInterval(bucket.start_time))
      guard start >= periodStart, start < periodEnd else { throw OpenAIAPIUsageError.invalidResponse }
      for item in bucket.results {
        guard let amount = item.amount, amount.currency?.lowercased() == "usd",
              let value = amount.value, value.isFinite else { throw OpenAIAPIUsageError.invalidResponse }
        total += value
        guard total.isFinite else { throw OpenAIAPIUsageError.invalidResponse }
      }
    }
    return total
  }
}

private final class RejectAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Fetches only the official organization cost endpoint. Never logs credentials
/// or raw responses, and rejects redirects so credentials cannot be forwarded.
public struct OpenAIAPIUsageReader: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let transport: Transport

  public init(transport: Transport? = nil) {
    if let transport {
      self.transport = transport
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 20
      configuration.urlCache = nil
      let session = URLSession(configuration: configuration, delegate: RejectAPIRedirects(), delegateQueue: nil)
      self.transport = { request in try await session.data(for: request) }
    }
  }

  public static func monthStart(at now: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
  }

  public func fetch(adminKey: String, at now: Date = Date()) async throws -> OpenAIAPICostReading {
    guard !adminKey.isEmpty else { throw OpenAIAPIUsageError.unauthorized }
    let start = Self.monthStart(at: now)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let end = calendar.date(byAdding: .month, value: 1, to: start) else {
      throw OpenAIAPIUsageError.invalidResponse
    }
    var cursor: String?
    var seen = Set<String>()
    var total = 0.0
    for _ in 0..<4 {
      var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
      components.queryItems = [
        URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
        URLQueryItem(name: "bucket_width", value: "1d"),
        URLQueryItem(name: "limit", value: "31")
      ]
      if let cursor { components.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
      guard let url = components.url else { throw OpenAIAPIUsageError.invalidResponse }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
      request.httpMethod = "GET"
      request.setValue("Bearer " + adminKey, forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let data: Data
      let response: URLResponse
      do { (data, response) = try await transport(request) }
      catch { throw OpenAIAPIUsageError.unavailable }
      guard let http = response as? HTTPURLResponse else { throw OpenAIAPIUsageError.invalidResponse }
      switch http.statusCode {
      case 200: break
      case 401: throw OpenAIAPIUsageError.unauthorized
      case 403: throw OpenAIAPIUsageError.forbidden
      case 429: throw OpenAIAPIUsageError.rateLimited(retryAfter: Self.retryAfter(http, now: now))
      default: throw OpenAIAPIUsageError.unavailable
      }
      guard data.count <= 2_000_000,
            let page = try? JSONDecoder().decode(OpenAIAPICostPage.self, from: data) else {
        throw OpenAIAPIUsageError.invalidResponse
      }
      total += try page.validatedTotal(from: start, before: end)
      guard total.isFinite else { throw OpenAIAPIUsageError.invalidResponse }
      if !page.has_more { return OpenAIAPICostReading(costUSD: total, periodStart: start, sampledAt: now) }
      guard let next = page.next_page, !next.isEmpty, seen.insert(next).inserted else {
        throw OpenAIAPIUsageError.invalidResponse
      }
      cursor = next
    }
    throw OpenAIAPIUsageError.invalidResponse
  }

  private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
  }
}
