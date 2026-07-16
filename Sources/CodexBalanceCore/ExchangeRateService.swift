import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ExchangeRateService {
  public typealias Fetcher = @Sendable () async throws -> Data

  private let cacheURL: URL
  private let fetcher: Fetcher
  private let now: @Sendable () -> Date
  private let calendar: Calendar

  public init(
    cacheURL: URL,
    fetcher: Fetcher? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    calendar: Calendar = .current
  ) {
    self.cacheURL = cacheURL
    self.now = now
    self.calendar = calendar
    self.fetcher = fetcher ?? {
      let url = URL(string: "https://api.frankfurter.dev/v2/rate/USD/CNY")!
      let (data, response) = try await URLSession.shared.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
      return data
    }
  }

  public func current() async -> ExchangeRateSnapshot? {
    let cached = loadCache()
    if let cached, calendar.isDate(cached.fetchedAt, inSameDayAs: now()) { return cached }
    do {
      let data = try await fetcher()
      let payload = try JSONDecoder().decode(FrankfurterRate.self, from: data)
      guard payload.base == "USD", payload.quote == "CNY", payload.rate > 0 else { throw URLError(.cannotParseResponse) }
      let snapshot = ExchangeRateSnapshot(
        base: payload.base,
        quote: payload.quote,
        rate: payload.rate,
        rateDate: payload.date,
        fetchedAt: now()
      )
      try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(snapshot).write(to: cacheURL, options: .atomic)
      return snapshot
    } catch {
      return cached
    }
  }

  private func loadCache() -> ExchangeRateSnapshot? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ExchangeRateSnapshot.self, from: data)
  }
}

private struct FrankfurterRate: Decodable {
  var date: String
  var base: String
  var quote: String
  var rate: Double
}
