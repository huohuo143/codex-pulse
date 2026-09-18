import Foundation

private final class ProfileUsageFetchResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: AccountTokenUsage?

  var value: AccountTokenUsage? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func set(_ usage: AccountTokenUsage) {
    lock.lock()
    storage = usage
    lock.unlock()
  }
}

final class CodexProfileUsageSource: @unchecked Sendable {
  private struct AuthFile: Decodable {
    var tokens: Tokens?

    struct Tokens: Decodable {
      var accessToken: String?

      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
      }
    }
  }

  private struct ProfilePayload: Decodable {
    var stats: Stats?

    struct Stats: Decodable {
      var dailyUsageBuckets: [DailyUsageBucket]?

      enum CodingKeys: String, CodingKey {
        case dailyUsageBuckets = "daily_usage_buckets"
      }
    }
  }

  private struct DailyUsageBucket: Decodable {
    var tokens: Int
    var startDate: String

    enum CodingKeys: String, CodingKey {
      case tokens
      case startDate = "start_date"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      startDate = try container.decode(String.self, forKey: .startDate)
      if let integerValue = try? container.decode(Int.self, forKey: .tokens) {
        tokens = integerValue
      } else if let doubleValue = try? container.decode(Double.self, forKey: .tokens) {
        tokens = Int(doubleValue)
      } else {
        tokens = 0
      }
    }
  }

  private enum Period {
    case day
    case month
  }

  private let codexHome: URL
  private let fileManager: FileManager
  private let cacheLock = NSLock()
  private var cachedUsage: AccountTokenUsage?
  private var cachedAt: Date?
  private var refreshInFlight = false
  private var failedUntil: Date?

  init(codexHome: URL, fileManager: FileManager) {
    self.codexHome = codexHome
    self.fileManager = fileManager
  }

  func cachedUsage(now: Date, maxAge: TimeInterval = 120) -> AccountTokenUsage? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    guard let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge else {
      return nil
    }
    return cachedUsage
  }

  func refreshInBackground(now: Date) {
    cacheLock.lock()
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      cacheLock.unlock()
      return
    }
    if let cachedAt, now.timeIntervalSince(cachedAt) < 45 {
      cacheLock.unlock()
      return
    }
    refreshInFlight = true
    cacheLock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let usage = self.fetchUsage(now: Date())

      self.cacheLock.lock()
      if let usage {
        self.cachedUsage = usage
        self.cachedAt = Date()
        self.failedUntil = nil
      } else {
        self.failedUntil = Date().addingTimeInterval(60)
      }
      self.refreshInFlight = false
      self.cacheLock.unlock()
    }
  }

  private func fetchUsage(now: Date) -> AccountTokenUsage? {
    guard let accessToken = readAccessToken() else {
      return nil
    }
    guard let url = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me") else {
      return nil
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 12
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("en", forHTTPHeaderField: "OAI-Language")
    request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
    request.setValue("codex_desktop", forHTTPHeaderField: "OpenAI-Beta")

    let semaphore = DispatchSemaphore(value: 0)
    let result = ProfileUsageFetchResult()
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let data,
            let payload = try? JSONDecoder().decode(ProfilePayload.self, from: data)
      else {
        return
      }
      result.set(self.usage(from: payload, now: now))
    }.resume()

    _ = semaphore.wait(timeout: .now() + 12)
    return result.value
  }

  private func readAccessToken() -> String? {
    let authFile = codexHome.appendingPathComponent("auth.json")
    guard fileManager.fileExists(atPath: authFile.path),
          let data = try? Data(contentsOf: authFile),
          let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
          let token = auth.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
          token.isEmpty == false
    else {
      return nil
    }
    return token
  }

  private func usage(from payload: ProfilePayload, now: Date) -> AccountTokenUsage {
    let buckets = payload.stats?.dailyUsageBuckets ?? []
    var daily: [String: TokenBucket] = [:]
    var monthly: [String: TokenBucket] = [:]

    for bucket in buckets {
      let key = normalizedDayKey(bucket.startDate)
      guard key.isEmpty == false else { continue }
      let tokens = max(0, bucket.tokens)
      var dayBucket = daily[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
      dayBucket.totalTokens += tokens
      daily[key] = dayBucket

      let monthKey = String(key.prefix(7))
      var monthBucket = monthly[monthKey] ?? TokenBucket(key: monthKey, label: formatPeriodLabel(monthKey))
      monthBucket.totalTokens += tokens
      monthly[monthKey] = monthBucket
    }

    return AccountTokenUsage(
      daily: fillDailyRows(daily, count: 14, now: now),
      monthly: fillMonthlyRows(monthly, count: 6, now: now),
      updatedAt: now
    )
  }

  private func normalizedDayKey(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 10 else { return "" }
    let candidate = String(trimmed.prefix(10))
    let parts = candidate.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          parts[0] > 2000,
          (1...12).contains(parts[1]),
          (1...31).contains(parts[2])
    else {
      return ""
    }
    return String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
  }

  private func fillDailyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    (0..<count).compactMap { index in
      let offset = count - 1 - index
      guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else {
        return nil
      }
      let key = periodKey(date, period: .day)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  private func fillMonthlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    (0..<count).compactMap { index in
      let offset = count - 1 - index
      guard let date = Calendar.current.date(byAdding: .month, value: -offset, to: now) else {
        return nil
      }
      let key = periodKey(date, period: .month)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  private func periodKey(_ date: Date, period: Period) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let year = components.year ?? 0
    let month = components.month ?? 0
    if period == .month {
      return String(format: "%04d-%02d", year, month)
    }
    return String(format: "%04d-%02d-%02d", year, month, components.day ?? 0)
  }

  private func formatPeriodLabel(_ key: String) -> String {
    let parts = key.split(separator: "-")
    if parts.count == 2 {
      return "\(parts[0])/\(parts[1])"
    }
    if parts.count == 3 {
      return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }
    return key
  }
}

