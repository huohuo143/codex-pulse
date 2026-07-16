import Dispatch
import Foundation

/// Read-only source for the account-level Full reset credits card.
/// Credentials and raw backend payloads stay in memory and are never logged or persisted.
final class CodexResetCreditsSource: @unchecked Sendable {
  private struct Credential {
    var accessToken: String
    var accountID: String?
  }

  private let codexHome: URL
  private let fileManager: FileManager
  private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
  private let lock = NSLock()
  private var cachedSummary: RateLimitResetCreditsSummary?
  private var cachedAt: Date?
  private var refreshInFlight = false
  private var failedUntil: Date?
  private var lastFailure: String?

  init(codexHome: URL, fileManager: FileManager = .default) {
    self.codexHome = codexHome
    self.fileManager = fileManager
  }

  func cached(now: Date, maxAge: TimeInterval = 300) -> RateLimitResetCreditsSummary? {
    lock.lock()
    defer { lock.unlock() }
    guard let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge else { return nil }
    return cachedSummary
  }

  func fresh(now: Date, maxAge: TimeInterval = 300) -> RateLimitResetCreditsSummary? {
    lock.lock()
    if let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge {
      let summary = cachedSummary
      lock.unlock()
      return summary
    }
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      let summary = cachedSummary
      lock.unlock()
      return summary
    }
    refreshInFlight = true
    lock.unlock()

    let summary = fetchSummary()
    finishRefresh(summary)
    return summary ?? cachedValue()
  }

  func refreshInBackground() {
    let now = Date()
    lock.lock()
    if let cachedAt, now.timeIntervalSince(cachedAt) <= 300 {
      lock.unlock()
      return
    }
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      lock.unlock()
      return
    }
    refreshInFlight = true
    lock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      self.finishRefresh(self.fetchSummary())
    }
  }

  func diagnosticFailure() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return lastFailure
  }

  private func cachedValue() -> RateLimitResetCreditsSummary? {
    lock.lock()
    defer { lock.unlock() }
    return cachedSummary
  }

  private func finishRefresh(_ summary: RateLimitResetCreditsSummary?) {
    lock.lock()
    if let summary {
      cachedSummary = summary
      cachedAt = Date()
      failedUntil = nil
      lastFailure = nil
    } else {
      // Avoid repeatedly hitting the login/backend path when Codex is signed out or rate-limited.
      failedUntil = Date().addingTimeInterval(60)
    }
    refreshInFlight = false
    lock.unlock()
  }

  private func fetchSummary() -> RateLimitResetCreditsSummary? {
    guard let credential = loadCredential() else {
      recordFailure("missing_auth")
      return nil
    }

    var request = URLRequest(
      url: endpoint,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 10
    )
    request.httpMethod = "GET"
    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
    request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("codex-reset-credit-readonly/1.0", forHTTPHeaderField: "User-Agent")
    if let accountID = credential.accountID, accountID.isEmpty == false {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let box = ResetCreditsHTTPResponseBox()
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      box.store(data: data, response: response, error: error)
      semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + 11) == .success else {
      task.cancel()
      recordFailure("timeout")
      return nil
    }

    let response = box.value()
    guard response.error == nil else {
      recordFailure("network_error")
      return nil
    }
    guard let http = response.response as? HTTPURLResponse else {
      recordFailure("invalid_response")
      return nil
    }
    guard (200..<300).contains(http.statusCode) else {
      recordFailure("http_\(http.statusCode)")
      return nil
    }
    guard let data = response.data else {
      recordFailure("empty_response")
      return nil
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do {
      let summary = try decoder.decode(RateLimitResetCreditsSummary.self, from: data)
      recordFailure(nil)
      return summary
    } catch {
      recordFailure("invalid_json")
      return nil
    }
  }

  private func recordFailure(_ failure: String?) {
    lock.lock()
    lastFailure = failure
    lock.unlock()
  }

  private func loadCredential() -> Credential? {
    let authURL = codexHome.appendingPathComponent("auth.json")
    guard fileManager.fileExists(atPath: authURL.path),
          let data = try? Data(contentsOf: authURL, options: .mappedIfSafe),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any],
          let accessToken = (tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String),
          accessToken.isEmpty == false
    else {
      return nil
    }

    let storedAccountID = (tokens["account_id"] as? String) ?? (tokens["accountId"] as? String)
    return Credential(
      accessToken: accessToken,
      accountID: accountID(fromJWT: accessToken) ?? storedAccountID
    )
  }

  private func accountID(fromJWT token: String) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
    guard let data = Data(base64Encoded: payload),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let auth = root["https://api.openai.com/auth"] as? [String: Any]
    else {
      return nil
    }
    return auth["chatgpt_account_id"] as? String
  }
}

/// Shared by the fast and full readers so normal 5-second UI refreshes produce at most
/// one read-only Reset Radar request per five-minute cache window.
let defaultCodexResetCreditsSource = CodexResetCreditsSource(
  codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
)

private final class ResetCreditsHTTPResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private var response: URLResponse?
  private var error: Error?

  func store(data: Data?, response: URLResponse?, error: Error?) {
    lock.lock()
    self.data = data
    self.response = response
    self.error = error
    lock.unlock()
  }

  func value() -> (data: Data?, response: URLResponse?, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (data, response, error)
  }
}
