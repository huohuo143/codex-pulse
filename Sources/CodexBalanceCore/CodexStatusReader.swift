import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif
#if canImport(Darwin)
import Darwin
#endif

struct ParsedFileCache: Codable {
  var modified: Date
  var identity: String?
  var prefix: Data?
  var pendingBytes: Data? = nil
  var fileSize: Int
  var pendingScores: [TokenUsageCategory: Int]
  var pendingProjectName: String
  var pendingProjectPath: String
  var pendingModel: String
  var pendingCategory: TokenUsageCategory
  var pendingLine: String
  var events: [RateLimitEvent]
}

struct PersistentEventCache: Codable {
  // v5 invalidates caches produced before cumulative-total deduplication.
  static let currentSchemaVersion = 6

  var schemaVersion: Int
  var files: [String: ParsedFileCache]
}

struct TokenStatsCache {
  var signature: String
  var validUntil: Date
  var stats: TokenStats
}

public final class CodexStatusReader: @unchecked Sendable {
  let clock: @Sendable () -> Date
  let officialRead: (@Sendable (Date) throws -> CodexStatus)?
  let fileManager: FileManager
  let codexHome: URL
  let sessionRoots: [URL]
  var injectedFileIndex: SessionFileIndex?
  lazy var fileIndex = injectedFileIndex ?? SessionFileIndex(roots: sessionRoots,
    reconciliationInterval: liveRateLimitSource == nil ? 0 : 300, watch: liveRateLimitSource != nil)
  var lastSyncAt: Date?
  var lastSyncedStats: TokenStats?
  var deviceSnapshots: [CodexDeviceTokenUsage] = []
  var cachedLogEvents: [RateLimitEvent] = []
  var lastIndexRevision = -1
  public internal(set) var diagnostics = SessionReadDiagnostics()
  public var lastSessionActivity: Date? { fileIndex.lastActivityAt }
  let liveRateLimitSource: CodexAppServerRateLimitSource?
  let resetCreditsSource: CodexResetCreditsSource?
  let accountUsageSource: CodexProfileUsageSource?
  let usageSyncStore: CodexUsageSyncStore?
  let persistentEventCacheURL: URL?
  var eventCache: [String: ParsedFileCache] = [:]
  var tokenStatsCache: TokenStatsCache?
  var workspaceMetadataStamp: Date?
  var workspaceMetadataLoaded = false
  var workspaceRootLabels: [String: String] = [:]
  var didLoadPersistentEventCache = false
  var persistentEventCacheDirty = false

  public init(
    codexHome: URL? = nil,
    sessionsRoot: URL? = nil,
    maxSessionFiles: Int = 1000,
    fileIndex: SessionFileIndex? = nil,
    clock: @escaping @Sendable () -> Date = { Date() },
    officialRead: (@Sendable (Date) throws -> CodexStatus)? = nil,
    preferLiveStatus: Bool = true,
    persistentEventCacheURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
      .flatMap { URL(fileURLWithPath: $0).standardizedFileURL }
    let defaultHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let resolvedHome = codexHome
      ?? environmentHome
      ?? defaultHome

    self.clock = clock
    self.officialRead = officialRead
    self.fileManager = fileManager
    if let sessionsRoot {
      self.codexHome = resolvedHome
      self.sessionRoots = [sessionsRoot]
    } else if codexHome != nil || environmentHome != nil {
      self.codexHome = resolvedHome
      self.sessionRoots = [resolvedHome.appendingPathComponent("sessions")]
    } else {
      self.codexHome = resolvedHome
      let discoveredRoots = Self.discoverSessionRoots(fileManager: fileManager)
      self.sessionRoots = discoveredRoots.isEmpty ? [resolvedHome.appendingPathComponent("sessions")] : discoveredRoots
    }
    // Retained initializer argument for source compatibility; complete statistics never truncate.
    self.injectedFileIndex = fileIndex
    self.liveRateLimitSource = preferLiveStatus && codexHome == nil && sessionsRoot == nil
      ? CodexAppServerRateLimitSource.shared
      : nil
    self.resetCreditsSource = preferLiveStatus && codexHome == nil && sessionsRoot == nil
      ? (environmentHome == nil
        ? defaultCodexResetCreditsSource
        : CodexResetCreditsSource(codexHome: resolvedHome, fileManager: fileManager))
      : nil
    self.accountUsageSource = preferLiveStatus && sessionsRoot == nil
      ? CodexProfileUsageSource(codexHome: resolvedHome, fileManager: fileManager)
      : nil
    self.usageSyncStore = preferLiveStatus && codexHome == nil && sessionsRoot == nil
      ? CodexUsageSyncStore(fileManager: fileManager)
      : nil
    if let persistentEventCacheURL {
      self.persistentEventCacheURL = persistentEventCacheURL
    } else if preferLiveStatus && codexHome == nil && sessionsRoot == nil {
      self.persistentEventCacheURL = PulsePaths.support.appendingPathComponent("session-event-cache-v6.plist")
    } else {
      self.persistentEventCacheURL = nil
    }
  }

  public func read(now: Date? = nil) throws -> CodexStatus {
    let now = now ?? clock()
    loadPersistentEventCacheIfNeeded()
    let labelURL = codexHome.appendingPathComponent(".codex-global-state.json")
    let labelStamp = (try? labelURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if !workspaceMetadataLoaded || labelStamp != workspaceMetadataStamp {
      workspaceRootLabels = loadWorkspaceRootLabels()
      workspaceMetadataStamp = labelStamp; workspaceMetadataLoaded = true
    }
    let entries = fileIndex.read(at: now)
    let files = entries.map(\.url)
    if lastIndexRevision != fileIndex.revision {
      let activePaths = Set(files.map(\.path))
      let filteredCache = eventCache.filter { activePaths.contains($0.key) }
      if filteredCache.count != eventCache.count { eventCache = filteredCache; persistentEventCacheDirty = true }
      cachedLogEvents = entries.flatMap { parseEvents(in: $0.url, entry: $0, now: now) }.sorted { $0.timestamp < $1.timestamp }
      lastIndexRevision = fileIndex.revision
      tokenStatsCache = nil
      persistEventCacheIfNeeded()
    }
    let events = cachedLogEvents
    let accountScope = synchronizeAccount()
    let liveSnapshot = liveRateLimitSource?.cachedSnapshot(now: now) ?? .empty
    let liveEvents = liveSnapshot.events
    let flexibleCreditBalance = liveSnapshot.flexibleCreditBalance
    liveRateLimitSource?.refreshInBackground()
    let resetCredits = resetCreditsSource?.cached(now: now) ?? liveSnapshot.resetCredits
    resetCreditsSource?.refreshInBackground()
    let accountUsage = accountUsageSource?.cachedUsage(now: now)
    accountUsageSource?.refreshInBackground(now: now)
    let combinedEvents = (events + liveEvents).sorted { $0.timestamp < $1.timestamp }
    let selectionEvents = Self.quotaSelectionEvents(
      sessionEvents: events,
      liveEvents: liveEvents,
      requiresOfficialLive: liveRateLimitSource != nil
    )

    let latestByLimit = Self.latestByLimit(from: selectionEvents)

    let limits = latestByLimit.values.sorted {
      let lhsUsed = $0.primary?.usedPercent ?? 0
      let rhsUsed = $1.primary?.usedPercent ?? 0
      if lhsUsed == rhsUsed { return $0.timestamp > $1.timestamp }
      return lhsUsed > rhsUsed
    }
    let main = limits.first { $0.limitID == "codex" } ?? limits.first
    let trend = main.map { selected in
      combinedEvents.filter { $0.limitID == selected.limitID }.suffix(48)
    } ?? []
    let recentEvents = combinedEvents
    var tokenStats = buildCachedTokenStats(from: events, now: now)
    tokenStats.accountUsage = accountUsage
    var syncInput = tokenStats
    syncInput.accountUsage = nil
    if syncInput != lastSyncedStats || lastSyncAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
      deviceSnapshots = usageSyncStore?.persistAndReadSnapshots(from: tokenStats, now: now) ?? []
      lastSyncedStats = syncInput; lastSyncAt = now
    }
    tokenStats.deviceUsage = deviceSnapshots

    var result = CodexStatus(
      generatedAt: now,
      codexHome: codexHome.path,
      sessionsRoot: sessionRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: limits,
      trend: Array(trend),
      rateLimitResetCredits: resetCredits,
      flexibleCreditBalance: flexibleCreditBalance,
      tokenStats: tokenStats,
      recentEvents: Array(recentEvents.suffix(18).reversed())
    )
    result.readerDiagnostics = diagnostics
    result.usageValidUntil = tokenStatsCache?.validUntil
    result.lastSessionActivity = fileIndex.lastActivityAt
    let finalScope = resetCreditsSource?.anonymousAccountScope()
    result.accountScope = finalScope
    if finalScope != accountScope {
      result.main = nil; result.limits = []; result.trend = []
      result.flexibleCreditBalance = nil; result.rateLimitResetCredits = nil
      result.quotaRead = SourceReadMetadata(source: "Codex app-server")
      result.flexibleCreditRead = SourceReadMetadata(source: "Codex app-server")
      result.resetCreditsRead = SourceReadMetadata(source: "Full reset 官方接口")
      return result
    }
    result.quotaRead = liveRateLimitSource == nil ? nil : liveSnapshot.quotaRead
    result.flexibleCreditRead = liveRateLimitSource == nil ? nil : liveSnapshot.flexibleRead
    result.resetCreditsRead = resetCreditsSource?.readMetadata() ?? liveSnapshot.resetRead
    return result

  }

  public func readFast(
    now: Date? = nil,
    fileLimit: Int = 8,
    tailBytes: Int = 768 * 1024,
    forceOfficial: Bool = false
  ) throws -> CodexStatus {
    let now = now ?? clock()
    if let officialRead { return try officialRead(now) }
    // Quota refresh never enumerates or reads session files.
    let files: [URL] = []
    let events: [RateLimitEvent] = []
    let accountScope = synchronizeAccount()
    let liveSnapshot = liveRateLimitSource?.freshSnapshot(now: now, maxAge: forceOfficial ? 0 : 45) ?? .empty
    let liveEvents = liveSnapshot.events
    let flexibleCreditBalance = liveSnapshot.flexibleCreditBalance
    let resetCredits = resetCreditsSource?.fresh(now: now, maxAge: forceOfficial ? 0 : 300) ?? liveSnapshot.resetCredits
    let accountUsage = accountUsageSource?.cachedUsage(now: now)
    accountUsageSource?.refreshInBackground(now: now)
    let combinedEvents = (events + liveEvents).sorted { $0.timestamp < $1.timestamp }
    let selectionEvents = Self.quotaSelectionEvents(
      sessionEvents: events,
      liveEvents: liveEvents,
      requiresOfficialLive: liveRateLimitSource != nil
    )

    let latestByLimit = Self.latestByLimit(from: selectionEvents)
    let limits = latestByLimit.values.sorted {
      let lhsUsed = $0.primary?.usedPercent ?? 0
      let rhsUsed = $1.primary?.usedPercent ?? 0
      if lhsUsed == rhsUsed { return $0.timestamp > $1.timestamp }
      return lhsUsed > rhsUsed
    }
    let main = limits.first { $0.limitID == "codex" } ?? limits.first
    let trend = main.map { selected in
      combinedEvents.filter { $0.limitID == selected.limitID }.suffix(48)
    } ?? []
    var tokenStats = TokenStats()
    tokenStats.accountUsage = accountUsage
    tokenStats.deviceUsage = usageSyncStore?.readSnapshots() ?? []

    var result = CodexStatus(
      generatedAt: now,
      codexHome: codexHome.path,
      sessionsRoot: sessionRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: limits,
      trend: Array(trend),
      rateLimitResetCredits: resetCredits,
      flexibleCreditBalance: flexibleCreditBalance,
      tokenStats: tokenStats,
      recentEvents: Array(combinedEvents.suffix(18).reversed())
    )
    let finalScope = resetCreditsSource?.anonymousAccountScope()
    result.accountScope = finalScope
    if finalScope != accountScope {
      result.main = nil; result.limits = []; result.trend = []
      result.flexibleCreditBalance = nil; result.rateLimitResetCredits = nil
      result.quotaRead = SourceReadMetadata(source: "Codex app-server")
      result.flexibleCreditRead = SourceReadMetadata(source: "Codex app-server")
      result.resetCreditsRead = SourceReadMetadata(source: "Full reset 官方接口")
      return result
    }
    result.quotaRead = liveRateLimitSource == nil ? nil : liveSnapshot.quotaRead
    result.flexibleCreditRead = liveRateLimitSource == nil ? nil : liveSnapshot.flexibleRead
    result.resetCreditsRead = resetCreditsSource?.readMetadata() ?? liveSnapshot.resetRead
    return result

  }

  static func latestByLimit(from events: [RateLimitEvent]) -> [String: RateLimitEvent] {
    var latestByLimit: [String: RateLimitEvent] = [:]
    for event in events {
      if let existing = latestByLimit[event.limitID],
         shouldKeep(existing: existing, over: event) {
        continue
      }
      latestByLimit[event.limitID] = event
    }
    return latestByLimit
  }

  /// Production dashboards have access to the account API. During process or
  /// computer startup, do not publish a session-log percentage while that
  /// authoritative source is still connecting. A temporary `--` is safer than
  /// presenting an old percentage as the current account quota.
  static func quotaSelectionEvents(
    sessionEvents: [RateLimitEvent],
    liveEvents: [RateLimitEvent],
    requiresOfficialLive: Bool
  ) -> [RateLimitEvent] {
    requiresOfficialLive ? liveEvents : (sessionEvents + liveEvents)
  }

  static func shouldKeep(existing: RateLimitEvent, over candidate: RateLimitEvent) -> Bool {
    let existingIsLive = existing.sourceName == "Codex app-server"
    let candidateIsLive = candidate.sourceName == "Codex app-server"
    let freshStatusGrace: TimeInterval = 120

    // When both samples identify the same official seven-day cycle, the
    // account API is authoritative even if a nearby session-log line has a
    // slightly newer local timestamp. This is the restart race that could show
    // 77% while account/rateLimits/read already reported 76%.
    if let existingReset = existing.sevenDayWindow?.resetsAt,
       let candidateReset = candidate.sevenDayWindow?.resetsAt {
      let resetDifference = candidateReset.timeIntervalSince(existingReset)
      if abs(resetDifference) > 300 {
        return resetDifference < 0
      }
      if existingIsLive != candidateIsLive {
        return existingIsLive
      }
    }

    if existing.timestamp == candidate.timestamp {
      return !existingIsLive || candidateIsLive
    }

    if existing.timestamp > candidate.timestamp {
      if existingIsLive,
         !candidateIsLive,
         existing.timestamp.timeIntervalSince(candidate.timestamp) <= freshStatusGrace {
        return false
      }
      return true
    }

    if !existingIsLive,
       candidateIsLive,
       candidate.timestamp.timeIntervalSince(existing.timestamp) <= freshStatusGrace {
      return true
    }
    return false
  }

  func synchronizeAccount() -> String? {
    let scope = resetCreditsSource?.anonymousAccountScope()
    liveRateLimitSource?.useAccount(scope)
    resetCreditsSource?.useAccount(scope)
    return scope
  }

  static func discoverSessionRoots(fileManager: FileManager) -> [URL] {
    let home = fileManager.homeDirectoryForCurrentUser
    let candidates = [
      home.appendingPathComponent(".codex/sessions"),
      home.appendingPathComponent(".codex/browser/sessions"),
      home.appendingPathComponent("Library/Application Support/Codex/sessions"),
      home.appendingPathComponent("Library/Application Support/com.openai.codex/sessions")
    ]

    return candidates.filter { fileManager.fileExists(atPath: $0.path) }
  }

  static func containsJSONL(in root: URL, fileManager: FileManager) -> Bool {
    guard fileManager.fileExists(atPath: root.path),
          let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
    else {
      return false
    }

    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
      else {
        continue
      }
      return true
    }

    return false
  }

  func parseEvents(in file: URL, entry: SessionFileEntry, now: Date) -> [RateLimitEvent] {
    let cacheKey = file.path
    if var cached = eventCache[cacheKey], (cached.identity == nil || cached.identity == entry.identity),
       cached.modified == entry.modified, cached.fileSize == entry.size {
      // Adopt legacy v5 parses only when metadata is unchanged. The first changed
      // file is verified or streamed again before any new accounting is appended.
      if cached.identity == nil {
        cached.identity = entry.identity
        cached.prefix = readPrefix(in: file, length: min(4096, entry.size))
        eventCache[cacheKey] = cached; persistentEventCacheDirty = true
      }
      return cached.events
    }
    let old = eventCache[cacheKey]
    let canAppend: Bool
    if let old, old.identity == entry.identity, entry.size > old.fileSize, let prefix = old.prefix {
      canAppend = readPrefix(in: file, length: prefix.count) == prefix
    } else { canAppend = false }
    var cache = canAppend ? old! : ParsedFileCache(modified: entry.modified, identity: entry.identity,
      prefix: nil, fileSize: 0, pendingScores: emptyCategoryScores(),
      pendingProjectName: projectName(fromPath: file.deletingPathExtension().lastPathComponent),
      pendingProjectPath: file.path, pendingModel: "unknown", pendingCategory: .other, pendingLine: "", events: [])
    do {
      let streamed = try SessionLogStream.read(file: file, offset: cache.fileSize, endOffset: max(0, entry.size),
        pending: cache.pendingBytes ?? Data(cache.pendingLine.utf8)) { text in
        let parsed = autoreleasepool {
          parseEventLines(text, file: file, initialScores: cache.pendingScores,
            initialProjectName: cache.pendingProjectName, initialProjectPath: cache.pendingProjectPath,
            initialModel: cache.pendingModel, initialCategory: cache.pendingCategory)
        }
        cache.events.append(contentsOf: parsed.events)
        cache.pendingScores = parsed.pendingScores; cache.pendingProjectName = parsed.pendingProjectName
        cache.pendingProjectPath = parsed.pendingProjectPath; cache.pendingModel = parsed.pendingModel
        cache.pendingCategory = parsed.pendingCategory
      }
      diagnostics.parsedFiles += 1; diagnostics.bytesRead += streamed.bytesRead
      cache.fileSize = streamed.offset; cache.pendingBytes = streamed.pending; cache.pendingLine = ""
      cache.modified = entry.modified; cache.identity = entry.identity
      cache.prefix = readPrefix(in: file, length: min(4096, cache.fileSize))
      eventCache[cacheKey] = cache; persistentEventCacheDirty = true
      return cache.events
    } catch { return old?.events ?? [] }
  }

  /// Keep an in-progress final JSONL record and resume from the previous byte offset.
  func splitCompleteJSONLines(_ text: String) -> (complete: String, pending: String) {
    guard !text.isEmpty else { return ("", "") }
    if text.hasSuffix("\n") { return (text, "") }

    let finalLineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    let finalLine = String(text[finalLineStart...])
    if let data = finalLine.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data)) != nil {
      return (text, "")
    }

    guard finalLineStart != text.startIndex else { return ("", text) }
    return (String(text[..<finalLineStart]), finalLine)
  }

  func loadPersistentEventCacheIfNeeded() {
    guard !didLoadPersistentEventCache else { return }
    didLoadPersistentEventCache = true
    guard let persistentEventCacheURL else { return }
    let legacyURL = persistentEventCacheURL.deletingLastPathComponent().appendingPathComponent("session-event-cache-v5.plist")
    let selectedURL = fileManager.fileExists(atPath: persistentEventCacheURL.path) ? persistentEventCacheURL : legacyURL
    guard let data = try? Data(contentsOf: selectedURL),
          let cache = try? PropertyListDecoder().decode(PersistentEventCache.self, from: data),
          [5, PersistentEventCache.currentSchemaVersion].contains(cache.schemaVersion) else { return }
    eventCache = cache.files
    persistentEventCacheDirty = cache.schemaVersion != PersistentEventCache.currentSchemaVersion
  }

  func persistEventCacheIfNeeded() {
    guard persistentEventCacheDirty, let persistentEventCacheURL else { return }
    let cache = PersistentEventCache(
      schemaVersion: PersistentEventCache.currentSchemaVersion,
      files: eventCache
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    guard let data = try? encoder.encode(cache) else { return }
    do {
      try fileManager.createDirectory(
        at: persistentEventCacheURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: persistentEventCacheURL, options: .atomic)
      persistentEventCacheDirty = false
    } catch {
      // Cache failure must never block live quota or usage reads.
    }
  }

  func parseRecentEvents(in file: URL, now: Date, tailBytes: Int) -> [RateLimitEvent] {
    guard let text = readTailText(in: file, maxBytes: tailBytes) else {
      return []
    }
    let fallbackProjectName = projectName(fromPath: file.deletingPathExtension().lastPathComponent)
    return parseEventLines(
      text,
      file: file,
      initialScores: emptyCategoryScores(),
      initialProjectName: fallbackProjectName,
      initialProjectPath: file.path,
      initialModel: "unknown",
      initialCategory: .other
    ).events
  }

  func parseEventLines(
    _ text: String,
    file: URL,
    initialScores: [TokenUsageCategory: Int],
    initialProjectName: String,
    initialProjectPath: String,
    initialModel: String,
    initialCategory: TokenUsageCategory
  ) -> (
    events: [RateLimitEvent],
    pendingScores: [TokenUsageCategory: Int],
    pendingProjectName: String,
    pendingProjectPath: String,
    pendingModel: String,
    pendingCategory: TokenUsageCategory
  ) {
    var events: [RateLimitEvent] = []
    var contextScores = initialScores
    var currentProjectName = initialProjectName
    var currentProjectPath = initialProjectPath
    var currentModel = initialModel
    var currentCategory = initialCategory

    for lineSlice in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let linePrefix = lineSlice.prefix(8192)
      guard asciiContains(linePrefix.utf8, tokenCountNeedle) else {
        updateProjectContextIfPresent(
          linePrefix,
          projectName: &currentProjectName,
          projectPath: &currentProjectPath
        )
        updateModelContextIfPresent(linePrefix, model: &currentModel)
        scoreContextLineIfRelevant(linePrefix, into: &contextScores)
        continue
      }

      let line = String(lineSlice)
      let scoredCategory = category(from: contextScores)
      let usageCategory = resolvedCategory(
        scored: scoredCategory,
        previous: currentCategory,
        projectName: currentProjectName,
        projectPath: currentProjectPath
      )
      guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let rateLimits = payload["rate_limits"] as? [String: Any],
            rateLimits["primary"] is [String: Any],
            let timestampString = object["timestamp"] as? String,
            let timestamp = ISO8601DateFormatter.codexDate(from: timestampString)
      else {
        continue
      }

      let limitID = rateLimits["limit_id"] as? String ?? "codex"
      let limitName = rateLimits["limit_name"] as? String ?? (limitID == "codex" ? "Codex 默认额度".coreL10n : limitID)
      let event = RateLimitEvent(
        timestamp: timestamp,
        sourceName: file.lastPathComponent,
        sourcePath: file.path,
        limitID: limitID,
        limitName: limitName,
        planType: rateLimits["plan_type"] as? String,
        primary: normalizeWindow(rateLimits["primary"] as? [String: Any]),
        secondary: normalizeWindow(rateLimits["secondary"] as? [String: Any]),
        reachedType: rateLimits["rate_limit_reached_type"] as? String,
        model: currentModel,
        usage: normalizeUsage(payload["info"] as? [String: Any]),
        usageCategory: usageCategory,
        projectName: currentProjectName,
        projectPath: currentProjectPath
      )
      events.append(event)
      currentCategory = usageCategory
      contextScores = emptyCategoryScores()
    }

    return (events, contextScores, currentProjectName, currentProjectPath, currentModel, currentCategory)
  }

  func updateModelContextIfPresent(_ line: Substring, model: inout String) {
    guard asciiContains(line.utf8, turnContextNeedle),
          let parsed = Self.jsonStringField("model", in: String(line))?.trimmingCharacters(in: .whitespacesAndNewlines),
          !parsed.isEmpty
    else { return }
    model = parsed
  }

  func readPrefix(in file: URL, length: Int) -> Data? {
    guard length >= 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    let data = try? handle.read(upToCount: length)
    diagnostics.bytesRead += data?.count ?? 0
    return data
  }

  func readText(in file: URL, fromOffset offset: Int) -> String? {
    guard offset > 0 else { return try? String(contentsOf: file, encoding: .utf8) }
    do {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      guard let data = try handle.readToEnd(), !data.isEmpty else { return "" }
      return String(data: data, encoding: .utf8)
    } catch {
      return nil
    }
  }

  func readTailText(in file: URL, maxBytes: Int) -> String? {
    guard maxBytes > 0 else { return nil }

    do {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
      try handle.seek(toOffset: offset)
      guard let data = try handle.readToEnd(), !data.isEmpty else {
        return ""
      }
      var text = String(data: data, encoding: .utf8) ?? ""
      if offset > 0,
         let firstLineBreak = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstLineBreak)...])
      }
      return text
    } catch {
      return nil
    }
  }

  func updateProjectContextIfPresent(
    _ line: Substring,
    projectName: inout String,
    projectPath: inout String
  ) {
    guard asciiContains(line.utf8, cwdNeedle),
          let cwd = Self.jsonStringField("cwd", in: String(line)),
          cwd.isEmpty == false
    else {
      return
    }

    projectPath = cwd
    projectName = Self.projectName(fromPath: cwd)
  }

  static func projectName(fromPath path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "未知项目".coreL10n }
    let name = URL(fileURLWithPath: trimmed).lastPathComponent
    return name.isEmpty ? trimmed : name
  }

  func projectName(fromPath path: String) -> String {
    Self.projectName(fromPath: path)
  }

  func loadWorkspaceRootLabels() -> [String: String] {
    let stateFile = codexHome.appendingPathComponent(".codex-global-state.json")
    guard let data = try? Data(contentsOf: stateFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    let persistedState = object["electron-persisted-atom-state"] as? [String: Any] ?? [:]
    guard let labels = object["electron-workspace-root-labels"] as? [String: Any]
            ?? persistedState["electron-workspace-root-labels"] as? [String: Any]
    else {
      return [:]
    }

    var normalized: [String: String] = [:]
    for (path, value) in labels {
      guard let label = value as? String else { continue }
      let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedLabel.isEmpty == false else { continue }
      normalized[Self.standardizedPath(path)] = trimmedLabel
    }
    return normalized
  }

  func workspaceLabel(for path: String) -> String? {
    let normalizedPath = Self.standardizedPath(path)
    if let label = workspaceRootLabels[normalizedPath] {
      return label
    }

    return workspaceRootLabels
      .filter { root, _ in normalizedPath == root || normalizedPath.hasPrefix(root + "/") }
      .max { lhs, rhs in lhs.key.count < rhs.key.count }?
      .value
  }

  func workspaceLabelSignature() -> String {
    workspaceRootLabels
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "\u{1f}")
  }

  static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  static func jsonStringField(_ key: String, in text: String) -> String? {
    guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
    var value = ""
    var isEscaping = false

    for character in text[range.upperBound...] {
      if isEscaping {
        switch character {
        case "n": value.append("\n")
        case "r": value.append("\r")
        case "t": value.append("\t")
        default: value.append(character)
        }
        isEscaping = false
      } else if character == "\\" {
        isEscaping = true
      } else if character == "\"" {
        return value
      } else {
        value.append(character)
      }
    }

    return nil
  }

  func normalizeWindow(_ window: [String: Any]?) -> LimitWindow? {
    guard let window else { return nil }
    let used = clamp(percentValue(in: window, keys: ["used_percent", "usedPercent", "used_percentage", "used"]) ?? 0)
    let remaining = percentValue(
      in: window,
      keys: [
        "remaining_percent",
        "remainingPercent",
        "remaining_percentage",
        "available_percent",
        "availablePercent",
        "available_percentage",
        "left_percent",
        "balance_percent",
        "remaining",
        "available",
        "left"
      ]
    ).map(clamp) ?? clamp(100 - used)
    let windowMinutes = double(window["window_minutes"])
    let resetsAtSeconds = double(window["resets_at"])
    return LimitWindow(
      usedPercent: used,
      remainingPercent: remaining,
      windowMinutes: windowMinutes,
      resetsAt: resetsAtSeconds > 0 ? Date(timeIntervalSince1970: resetsAtSeconds) : nil
    )
  }

  func percentValue(in dictionary: [String: Any], keys: [String]) -> Double? {
    for key in keys where dictionary.keys.contains(key) {
      return double(dictionary[key])
    }
    return nil
  }

  func normalizeUsage(_ info: [String: Any]?) -> TokenUsage {
    let total = info?["total_token_usage"] as? [String: Any] ?? [:]
    let last = info?["last_token_usage"] as? [String: Any] ?? [:]
    return TokenUsage(
      totalTokens: integer(total["total_tokens"]),
      inputTokens: integer(total["input_tokens"]),
      cachedInputTokens: integer(total["cached_input_tokens"]),
      outputTokens: integer(total["output_tokens"]),
      reasoningOutputTokens: integer(total["reasoning_output_tokens"]),
      lastTotalTokens: integer(last["total_tokens"]),
      lastInputTokens: integer(last["input_tokens"]),
      lastCachedInputTokens: integer(last["cached_input_tokens"]),
      lastOutputTokens: integer(last["output_tokens"]),
      lastReasoningOutputTokens: integer(last["reasoning_output_tokens"])
    )
  }

  func emptyCategoryScores() -> [TokenUsageCategory: Int] {
    Dictionary(uniqueKeysWithValues: TokenUsageCategory.allCases.map { ($0, 0) })
  }

  func scoreContextLineIfRelevant(
    _ line: Substring,
    into scores: inout [TokenUsageCategory: Int]
  ) {
    let bytes = line.utf8
    guard isScorableContextLine(bytes) else { return }

    let sample = String(line).lowercased()

    addScore(&scores, .presentation, sample.utf8, presentationKeywordRules)
    addScore(&scores, .imageDesign, sample.utf8, imageKeywordRules)
    addScore(&scores, .videoProduction, sample.utf8, videoKeywordRules)
    addScore(&scores, .documents, sample.utf8, documentKeywordRules)
    addScore(&scores, .manuscript, sample.utf8, manuscriptKeywordRules)
    addScore(&scores, .dataAnalysis, sample.utf8, dataAnalysisKeywordRules)
    addScore(&scores, .lifeScience, sample.utf8, lifeScienceKeywordRules)
    addScore(&scores, .webDevelopment, sample.utf8, webDevelopmentKeywordRules)
    addScore(&scores, .systemOperations, sample.utf8, systemOperationsKeywordRules)
    addScore(&scores, .coding, sample.utf8, codingKeywordRules)
    addScore(&scores, .research, sample.utf8, researchKeywordRules)
    if asciiContains(bytes, userRoleNeedle) || asciiContains(bytes, userMessageNeedle) {
      scores[.general, default: 0] += 1
    }
  }

  func isScorableContextLine<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
    if asciiContains(bytes, developerRoleNeedle) ||
       asciiContains(bytes, systemRoleNeedle) ||
       asciiContains(bytes, turnContextNeedle) ||
       asciiContains(bytes, sessionMetaNeedle) ||
       asciiContains(bytes, functionOutputNeedle) {
      return false
    }

    return asciiContains(bytes, userRoleNeedle) ||
      asciiContains(bytes, assistantRoleNeedle) ||
      asciiContains(bytes, userMessageNeedle) ||
      asciiContains(bytes, functionCallNeedle)
  }

  func category(from scores: [TokenUsageCategory: Int]) -> TokenUsageCategory {
    return scores
      .filter { $0.key != .other }
      .max { lhs, rhs in
        if lhs.value == rhs.value {
          return categoryPriority(lhs.key) < categoryPriority(rhs.key)
        }
        return lhs.value < rhs.value
      }
      .flatMap { $0.value > 0 ? $0.key : nil } ?? .other
  }

  func addScore(
    _ scores: inout [TokenUsageCategory: Int],
    _ category: TokenUsageCategory,
    _ text: String.UTF8View,
    _ rules: [UsageKeywordRule]
  ) {
    for rule in rules where asciiContains(text, rule.bytes) {
      scores[category, default: 0] += rule.weight
    }
  }

  func categoryPriority(_ category: TokenUsageCategory) -> Int {
    switch category {
    case .presentation: 13
    case .videoProduction: 12
    case .imageDesign: 11
    case .manuscript: 10
    case .documents: 9
    case .dataAnalysis: 8
    case .lifeScience: 7
    case .webDevelopment: 6
    case .coding: 5
    case .systemOperations: 4
    case .research: 3
    case .general: 2
    case .other: 1
    }
  }

  func resolvedCategory(
    scored: TokenUsageCategory,
    previous: TokenUsageCategory,
    projectName: String,
    projectPath: String
  ) -> TokenUsageCategory {
    if scored != .other, scored != .general {
      return scored
    }

    let projectCategory = categoryFromProject(name: projectName, path: projectPath)
    if projectCategory != .other {
      return projectCategory
    }
    if previous != .other {
      return previous
    }
    return scored
  }

  func categoryFromProject(name: String, path: String) -> TokenUsageCategory {
    let value = "\(name) \(path)".lowercased()
    let rules: [(TokenUsageCategory, [String])] = [
      (.presentation, ["课题汇报ppt", "汇报ppt", "presentation", "slides"]),
      (.videoProduction, ["视频制作", "剪映", "jianying", "video"]),
      (.imageDesign, ["ps 抠图", "photoshop", "illustrator", "图片", "figure"]),
      (.manuscript, ["投稿中论文", "论文", "manuscript", "review", "综述"]),
      (.dataAnalysis, ["组学分析", "数据分析", "analysis", "omics"]),
      (.lifeScience, ["wu lab 课题", "水稻", "褐飞虱", "bph", "bcat", "病毒"]),
      (.webDevelopment, ["网站构建", "sites-project", "sites-plugin", "website"]),
      (.systemOperations, ["电脑维护", "群晖", "内网穿透", "网络问题", "synology", "routine"]),
      (.documents, ["重点研发", "项目合集", "高层次人才", "国重重组", "docx"]),
      (.coding, ["app 开发", "app开发", "算力码表", "codex 脉动", "/skills", "nature skill", "zotero_memory_builder"])
    ]

    for (category, keywords) in rules where keywords.contains(where: value.contains) {
      return category
    }
    return .other
  }

}

private extension ISO8601DateFormatter {
  static func codexDate(from string: String) -> Date? {
    let withFractionalSeconds = ISO8601DateFormatter()
    withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractionalSeconds.date(from: string) {
      return date
    }

    let withoutFractionalSeconds = ISO8601DateFormatter()
    withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
    return withoutFractionalSeconds.date(from: string)
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

private func asciiContains<S: Sequence>(_ haystack: S, _ needle: [UInt8]) -> Bool where S.Element == UInt8 {
  guard !needle.isEmpty else { return true }
  var matched = 0
  for byte in haystack {
    if byte == needle[matched] {
      matched += 1
      if matched == needle.count {
        return true
      }
    } else {
      matched = byte == needle[0] ? 1 : 0
    }
  }
  return false
}
