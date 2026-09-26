import Foundation
import CFNetwork
import Darwin

struct LiveAccountRateLimitSnapshot: Sendable {
  var events: [RateLimitEvent]
  var resetCredits: RateLimitResetCreditsSummary?
  var flexibleCreditBalance: CodexFlexibleCreditBalance?
  var quotaRead = SourceReadMetadata(source: "Codex app-server")
  var flexibleRead = SourceReadMetadata(source: "Codex app-server")
  var resetRead = SourceReadMetadata(source: "Codex app-server")
  var accountScope: String? = nil

  static let empty = LiveAccountRateLimitSnapshot(
    events: [],
    resetCredits: nil,
    flexibleCreditBalance: nil
  )
  var hasContent: Bool { !events.isEmpty || resetCredits != nil || flexibleCreditBalance != nil }
}

enum CodexAppServerProcessEnvironment {
  static func resolved(
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    systemProxySettings: [String: Any] = currentSystemProxySettings(),
    bypassProxyForChatGPT: Bool = false
  ) -> [String: String] {
    var environment = baseEnvironment

    mirrorProxy(
      upperKey: "HTTP_PROXY",
      lowerKey: "http_proxy",
      enableKey: "HTTPEnable",
      hostKey: "HTTPProxy",
      portKey: "HTTPPort",
      settings: systemProxySettings,
      environment: &environment
    )
    mirrorProxy(
      upperKey: "HTTPS_PROXY",
      lowerKey: "https_proxy",
      enableKey: "HTTPSEnable",
      hostKey: "HTTPSProxy",
      portKey: "HTTPSPort",
      settings: systemProxySettings,
      environment: &environment
    )

    let existingBypasses = [environment["NO_PROXY"], environment["no_proxy"]]
      .compactMap { $0 }
      .flatMap { $0.split(separator: ",").map(String.init) }
    let systemBypasses = (systemProxySettings["ExceptionsList"] as? [String]) ?? []
    let chatGPTBypasses = bypassProxyForChatGPT
      ? ["chatgpt.com", ".chatgpt.com"]
      : []
    let mergedBypasses = orderedUnique(
      (existingBypasses + systemBypasses + chatGPTBypasses).compactMap(normalizeBypassHost)
    )
    if mergedBypasses.isEmpty == false {
      let value = mergedBypasses.joined(separator: ",")
      environment["NO_PROXY"] = value
      environment["no_proxy"] = value
    }
    return environment
  }

  static func currentSystemProxySettings() -> [String: Any] {
    #if canImport(CFNetwork)
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
      as? [String: Any]
    else {
      return [:]
    }
    return settings
    #else
    return [:]
    #endif
  }

  private static func mirrorProxy(
    upperKey: String,
    lowerKey: String,
    enableKey: String,
    hostKey: String,
    portKey: String,
    settings: [String: Any],
    environment: inout [String: String]
  ) {
    if let existing = environment[upperKey] ?? environment[lowerKey],
       existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      environment[upperKey] = existing
      environment[lowerKey] = existing
      return
    }
    guard isEnabled(settings[enableKey]),
          let host = settings[hostKey] as? String,
          host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          let port = integerValue(settings[portKey]),
          port > 0
    else {
      return
    }
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlHost = trimmedHost.contains(":") && trimmedHost.hasPrefix("[") == false
      ? "[\(trimmedHost)]"
      : trimmedHost
    let value = "http://\(urlHost):\(port)"
    environment[upperKey] = value
    environment[lowerKey] = value
  }

  private static func isEnabled(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String {
      return ["1", "true", "yes"].contains(text.lowercased())
    }
    return false
  }

  private static func integerValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }

  private static func normalizeBypassHost(_ rawValue: String) -> String? {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.isEmpty == false else { return nil }
    if value.hasPrefix("*.") {
      value.removeFirst()
    } else if value.hasPrefix("*") {
      value.removeFirst()
    }
    return value.isEmpty ? nil : value
  }

  private static func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.lowercased()).inserted }
  }
}

final class CodexAppServerRateLimitSource: @unchecked Sendable {
  static let shared = CodexAppServerRateLimitSource()
  private struct RPCErrorPayload: Decodable {
    var code: Int?
    var message: String
  }

  private struct RPCResponse<Result: Decodable>: Decodable {
    var id: Int
    var result: Result?
    var error: RPCErrorPayload?
  }

  private struct LiveRateLimitsPayload: Decodable {
    var rateLimits: LiveRateLimitSnapshot
    var rateLimitsByLimitId: [String: LiveRateLimitSnapshot]?
    var rateLimitResetCredits: RateLimitResetCreditsSummary?
  }

  private struct LiveRateLimitSnapshot: Decodable {
    var limitId: String?
    var limitName: String?
    var primary: LiveRateLimitWindow?
    var secondary: LiveRateLimitWindow?
    var credits: CodexFlexibleCreditBalance?
    var planType: String?
    var rateLimitReachedType: String?
  }

  private struct LiveRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Double?
    var resetsAt: Double?
  }

  private let condition = NSCondition()
  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var outputBuffer = Data()
  private var responses: [Int: Data] = [:]
  private var nextRequestID = 1
  private var initialized = false
  private var completedLiveRead = false
  private let cacheLock = NSLock()
  private var cachedSnapshot = LiveAccountRateLimitSnapshot.empty
  private var cachedAt: Date?
  private var refreshInFlight = false
  private var failedUntil: Date?
  private var bypassProxyForChatGPT = false

  deinit {
    stop()
  }

  private var accountScope: String?
  func useAccount(_ scope: String?) {
    cacheLock.lock()
    let changed = accountScope != scope
    if changed {
      accountScope = scope; cachedSnapshot = .empty; cachedSnapshot.accountScope = scope
      cachedAt = nil; failedUntil = nil
    }
    cacheLock.unlock()
    if changed { stop() }
  }

  func cachedSnapshot(now: Date, maxAge: TimeInterval = 45) -> LiveAccountRateLimitSnapshot {
    cacheLock.lock(); defer { cacheLock.unlock() }
    return cachedSnapshot
  }

  func freshSnapshot(now: Date, maxAge: TimeInterval = 45) -> LiveAccountRateLimitSnapshot {
    cacheLock.lock()
    if refreshInFlight || (maxAge > 0 && (failedUntil.map { $0 > now } ?? false))
      || (cachedAt.map { now.timeIntervalSince($0) <= maxAge } ?? false) {
      let result = cachedSnapshot
      cacheLock.unlock()
      return result
    }
    refreshInFlight = true
    let scope = accountScope
    cacheLock.unlock()
    var next = fetchSnapshot(now: now)
    next.accountScope = scope
    return finishSnapshot(next, at: Date())
  }

  func finishSnapshot(_ next: LiveAccountRateLimitSnapshot, at date: Date) -> LiveAccountRateLimitSnapshot {
    cacheLock.lock(); defer { cacheLock.unlock() }
    guard next.accountScope == accountScope else { refreshInFlight = false; return cachedSnapshot }
    if !next.events.isEmpty {
      cachedSnapshot.events = next.events
      cachedSnapshot.quotaRead.succeed(at: date, sampledAt: next.events.map(\.timestamp).max())
    } else { cachedSnapshot.quotaRead.fail(at: date, reason: "official_quota_unavailable") }
    if let balance = next.flexibleCreditBalance {
      cachedSnapshot.flexibleCreditBalance = balance
      cachedSnapshot.flexibleRead.succeed(at: date)
    } else { cachedSnapshot.flexibleRead.fail(at: date, reason: "official_balance_unavailable") }
    if let credits = next.resetCredits {
      cachedSnapshot.resetCredits = credits
      cachedSnapshot.resetRead.succeed(at: date)
    } else { cachedSnapshot.resetRead.fail(at: date, reason: "official_credits_unavailable") }
    if next.hasContent { cachedAt = date }
    refreshInFlight = false
    return cachedSnapshot
  }

  func refreshInBackground() {
    let now = Date()
    cacheLock.lock()
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false)
      || (cachedAt.map { now.timeIntervalSince($0) <= 45 } ?? false) {
      cacheLock.unlock()
      return
    }
    refreshInFlight = true
    cacheLock.unlock()
    let scope = accountScope
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      var next = self.fetchSnapshot(now: Date())
      next.accountScope = scope
      _ = self.finishSnapshot(next, at: Date())
    }
  }

  private func fetchSnapshot(now: Date) -> LiveAccountRateLimitSnapshot {
    do {
      return try fetchSnapshotAttempt(now: now)
    } catch {
      let firstError = error
      stop()

      if LiveRateLimitError.shouldRetryWithAlternateProxyPath(firstError) {
        bypassProxyForChatGPT.toggle()
        do {
          let snapshot = try fetchSnapshotAttempt(now: now)
          NSLog("CodexBalance live rate limit source recovered using alternate proxy path")
          return snapshot
        } catch {
          NSLog(
            "CodexBalance live rate limit source failed after alternate proxy path: " +
            "\(error.localizedDescription)"
          )
          stop()
        }
      } else {
        NSLog("CodexBalance live rate limit source failed: \(firstError.localizedDescription)")
      }
      markFailureCooldown(seconds: 15)
      return .empty
    }
  }

  private func fetchSnapshotAttempt(now: Date) throws -> LiveAccountRateLimitSnapshot {
    try ensureInitialized()
    let id = nextID()
    try send([
      "jsonrpc": "2.0",
      "id": id,
      "method": "account/rateLimits/read"
    ])
    let data = try waitForResponse(id: id, timeout: completedLiveRead ? 3.0 : 12.0)
    let response = try JSONDecoder().decode(RPCResponse<LiveRateLimitsPayload>.self, from: data)
    if let error = response.error {
      throw LiveRateLimitError.server(error.message)
    }
    guard let payload = response.result else {
      throw LiveRateLimitError.emptyResponse
    }
    clearFailureCooldown()
    completedLiveRead = true
    return LiveAccountRateLimitSnapshot(
      events: events(from: payload, now: now),
      resetCredits: payload.rateLimitResetCredits,
      flexibleCreditBalance: payload.rateLimits.credits
    )
  }

  private func ensureInitialized() throws {
    if initialized, process?.isRunning == true {
      return
    }

    try start()
    let id = nextID()
    try send([
      "jsonrpc": "2.0",
      "id": id,
      "method": "initialize",
      "params": [
        "clientInfo": [
          "name": "CodexBalance",
          "version": "1"
        ]
      ]
    ])
    _ = try waitForResponse(id: id, timeout: 8)
    try send([
      "jsonrpc": "2.0",
      "method": "initialized"
    ])
    initialized = true
  }

  private func start() throws {
    if process?.isRunning == true {
      return
    }

    guard let executableURL = Self.codexExecutableURL() else {
      NSLog("CodexBalance live rate limit source failed: codex executable missing")
      throw LiveRateLimitError.codexExecutableMissing
    }

    let nextProcess = Process()
    let nextInputPipe = Pipe()
    let nextOutputPipe = Pipe()
    let nextErrorPipe = Pipe()
    nextProcess.executableURL = executableURL
    nextProcess.arguments = ["app-server", "--listen", "stdio://"]
    nextProcess.environment = CodexAppServerProcessEnvironment.resolved(
      bypassProxyForChatGPT: bypassProxyForChatGPT
    )
    nextProcess.standardInput = nextInputPipe
    nextProcess.standardOutput = nextOutputPipe
    nextProcess.standardError = nextErrorPipe

    nextOutputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak nextProcess] handle in
      let data = handle.availableData
      guard data.isEmpty == false else {
        self?.handleProcessExit(nextProcess)
        return
      }
      self?.appendOutput(data)
    }
    nextErrorPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    nextProcess.terminationHandler = { [weak self] terminatedProcess in
      self?.handleProcessExit(terminatedProcess)
    }

    condition.lock()
    process = nextProcess
    inputPipe = nextInputPipe
    outputPipe = nextOutputPipe
    errorPipe = nextErrorPipe
    outputBuffer.removeAll(keepingCapacity: true)
    responses.removeAll()
    initialized = false
    completedLiveRead = false
    condition.unlock()

    try nextProcess.run()
  }

  private func stop() {
    condition.lock()
    let currentProcess = process
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    outputBuffer.removeAll(keepingCapacity: true)
    responses.removeAll()
    initialized = false
    completedLiveRead = false
    condition.broadcast()
    condition.unlock()

    if let currentProcess, currentProcess.isRunning {
      currentProcess.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        guard currentProcess.isRunning else { return }
        #if canImport(Darwin)
        Darwin.kill(currentProcess.processIdentifier, SIGKILL)
        #else
        currentProcess.terminate()
        #endif
      }
    }
  }

  private func handleProcessExit(_ exitedProcess: Process?) {
    condition.lock()
    guard let exitedProcess, process === exitedProcess else {
      condition.unlock()
      return
    }
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    initialized = false
    completedLiveRead = false
    condition.broadcast()
    condition.unlock()
  }

  private func appendOutput(_ data: Data) {
    condition.lock()
    outputBuffer.append(data)
    while let newlineIndex = outputBuffer.firstIndex(of: 10) {
      let lineData = outputBuffer[..<newlineIndex]
      outputBuffer.removeSubrange(...newlineIndex)
      guard lineData.isEmpty == false,
            let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
            let id = Self.integerID(object["id"])
      else {
        continue
      }
      responses[id] = Data(lineData)
      condition.broadcast()
    }
    condition.unlock()
  }

  private func nextID() -> Int {
    condition.lock()
    defer { condition.unlock() }
    let id = nextRequestID
    nextRequestID += 1
    return id
  }

  private func send(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else {
      throw LiveRateLimitError.encodingFailed
    }
    line.append(10)
    guard let inputPipe else {
      throw LiveRateLimitError.processExited
    }
    try inputPipe.fileHandleForWriting.write(contentsOf: line)
  }

  private func waitForResponse(id: Int, timeout: TimeInterval) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }

    while responses[id] == nil {
      if process?.isRunning != true {
        throw LiveRateLimitError.processExited
      }
      if Date() >= deadline {
        throw LiveRateLimitError.timeout
      }
      condition.wait(until: deadline)
    }

    return responses.removeValue(forKey: id) ?? Data()
  }

  private func events(from payload: LiveRateLimitsPayload, now: Date) -> [RateLimitEvent] {
    var snapshots = payload.rateLimitsByLimitId ?? [:]
    let mainID = payload.rateLimits.limitId ?? "codex"
    snapshots[mainID] = payload.rateLimits

    return snapshots
      .values
      .compactMap { snapshot in
        guard let limitID = snapshot.limitId, limitID.isEmpty == false else {
          return nil
        }
        return RateLimitEvent(
          timestamp: now,
          sourceName: "Codex app-server",
          sourcePath: "account/rateLimits/read",
          limitID: limitID,
          limitName: snapshot.limitName ?? (limitID == "codex" ? "Codex 默认额度".coreL10n : limitID),
          planType: snapshot.planType,
          primary: normalize(snapshot.primary),
          secondary: normalize(snapshot.secondary),
          reachedType: snapshot.rateLimitReachedType
        )
      }
  }

  private func normalize(_ window: LiveRateLimitWindow?) -> LimitWindow? {
    guard let window else { return nil }
    let used = clamp(window.usedPercent)
    return LimitWindow(
      usedPercent: used,
      remainingPercent: clamp(100 - used),
      windowMinutes: window.windowDurationMins ?? 0,
      resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
    )
  }

  // Finder/LaunchAgent launches do not inherit the desktop app's CLI PATH.
  // Resolve both current nested CLI bundles and legacy resource layouts directly.
  static func bundledCodexExecutableURL(
    applicationDirectories: [URL] = [
      URL(fileURLWithPath: "/Applications"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ],
    fileManager: FileManager = .default
  ) -> URL? {
    let relativePaths = [
      "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
      "Contents/Resources/codex"
    ]
    for directory in applicationDirectories {
      for appName in ["ChatGPT.app", "Codex.app"] {
        for relativePath in relativePaths {
          let candidate = directory.appendingPathComponent(appName).appendingPathComponent(relativePath)
          var isDirectory: ObjCBool = false
          if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
             !isDirectory.boolValue, fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
          }
        }
      }
    }
    return nil
  }

  private static func codexExecutableURL() -> URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    if let bundled = bundledCodexExecutableURL(fileManager: fm) { return bundled }
    var candidates = [
      // npm 全局安装（-g）常见位置
      "\(home)/.npm-global/bin/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      "/usr/bin/codex"
    ]
    // nvm 各 node 版本下的 bin/codex
    let nvmVersions = "\(home)/.nvm/versions/node"
    if let entries = try? fm.contentsOfDirectory(atPath: nvmVersions) {
      candidates.append(contentsOf: entries.map { "\(nvmVersions)/\($0)/bin/codex" })
    }
    if let direct = candidates.map(URL.init(fileURLWithPath:))
      .first(where: { fm.isExecutableFile(atPath: $0.path) }) {
      return direct
    }
    // 兜底：用 login shell 解析 PATH 里的 codex（覆盖任意自定义安装位置）
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/bin/zsh")
    which.arguments = ["-lc", "command -v codex"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = FileHandle.nullDevice
    try? which.run()
    which.waitUntilExit()
    if let data = try? pipe.fileHandleForReading.readToEnd(),
       let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty, fm.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    return nil
  }

  private static func integerID(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private func markFailureCooldown(seconds: TimeInterval) {
    cacheLock.lock()
    failedUntil = Date().addingTimeInterval(seconds)
    cacheLock.unlock()
  }

  private func clearFailureCooldown() {
    cacheLock.lock()
    failedUntil = nil
    cacheLock.unlock()
  }
}

private enum LiveRateLimitError: LocalizedError {
  case codexExecutableMissing
  case encodingFailed
  case processExited
  case timeout
  case emptyResponse
  case server(String)

  static func shouldRetryWithAlternateProxyPath(_ error: Error) -> Bool {
    guard case let LiveRateLimitError.server(message) = error else { return false }
    let normalized = message.lowercased()
    return normalized.contains("failed to fetch codex rate limits")
      || normalized.contains("error sending request")
  }

  var errorDescription: String? {
    switch self {
    case .codexExecutableMissing: "找不到 Codex 可执行文件".coreL10n
    case .encodingFailed: "无法编码 Codex app-server 请求".coreL10n
    case .processExited: "Codex app-server 已退出".coreL10n
    case .timeout: "Codex app-server 响应超时".coreL10n
    case .emptyResponse: "Codex app-server 返回空结果".coreL10n
    case let .server(message): message
    }
  }
}

private func integer(_ value: Any?) -> Int {
  if let value = value as? Int { return value }
  if let value = value as? Double { return Int(value) }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) ?? 0 }
  return 0
}

private func double(_ value: Any?) -> Double {
  if let value = value as? Double { return value }
  if let value = value as? Int { return Double(value) }
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) ?? 0 }
  return 0
}

private func clamp(_ value: Double) -> Double {
  guard value.isFinite else { return 0 }
  return max(0, min(100, value))
}
