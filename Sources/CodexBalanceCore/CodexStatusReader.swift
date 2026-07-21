import Foundation
#if canImport(Darwin)
import Darwin
#endif

private struct ParsedFileCache: Codable {
  var modified: Date
  var fileSize: Int
  var pendingScores: [TokenUsageCategory: Int]
  var pendingProjectName: String
  var pendingProjectPath: String
  var pendingModel: String
  var pendingCategory: TokenUsageCategory
  var pendingLine: String
  var events: [RateLimitEvent]
}

private struct PersistentEventCache: Codable {
  // v5 invalidates caches produced before cumulative-total deduplication.
  static let currentSchemaVersion = 5

  var schemaVersion: Int
  var files: [String: ParsedFileCache]
}

private struct TokenStatsCache {
  var signature: String
  var dayKey: String
  var stats: TokenStats
}

private struct UsageKeywordRule {
  var bytes: [UInt8]
  var weight: Int

  init(_ keyword: String, _ weight: Int) {
    bytes = Array(keyword.utf8)
    self.weight = weight
  }
}

private let tokenCountNeedle = Array(#""type":"token_count""#.utf8)
private let developerRoleNeedle = Array(#""role":"developer""#.utf8)
private let systemRoleNeedle = Array(#""role":"system""#.utf8)
private let turnContextNeedle = Array(#""type":"turn_context""#.utf8)
private let sessionMetaNeedle = Array(#""type":"session_meta""#.utf8)
private let functionOutputNeedle = Array(#""type":"function_call_output""#.utf8)
private let cwdNeedle = Array(#""cwd""#.utf8)
private let userRoleNeedle = Array(#""role":"user""#.utf8)
private let assistantRoleNeedle = Array(#""role":"assistant""#.utf8)
private let userMessageNeedle = Array(#""type":"user_message""#.utf8)
private let functionCallNeedle = Array(#""type":"function_call""#.utf8)
private let presentationKeywordRules = [
  UsageKeywordRule("pptx", 10),
  UsageKeywordRule("powerpoint", 10),
  UsageKeywordRule("演示文稿", 10),
  UsageKeywordRule("幻灯片", 10),
  UsageKeywordRule("slide deck", 9),
  UsageKeywordRule("presentation deck", 9),
  UsageKeywordRule("slides", 7),
  UsageKeywordRule("slide", 5),
  UsageKeywordRule("presentations:", 7),
  UsageKeywordRule("presentations", 6),
  UsageKeywordRule("generate_deck", 7),
  UsageKeywordRule("powerpoint:", 7),
  UsageKeywordRule("ppt", 4)
]
private let imageKeywordRules = [
  UsageKeywordRule("imagegen", 10),
  UsageKeywordRule("生成图片", 9),
  UsageKeywordRule("做图", 9),
  UsageKeywordRule("图片", 5),
  UsageKeywordRule("图像", 5),
  UsageKeywordRule("海报", 5),
  UsageKeywordRule("插画", 5),
  UsageKeywordRule("视觉", 4),
  UsageKeywordRule("figma", 6),
  UsageKeywordRule("canva", 6),
  UsageKeywordRule("png", 3),
  UsageKeywordRule("jpg", 3)
]
private let documentKeywordRules = [
  UsageKeywordRule("docx", 10),
  UsageKeywordRule("word", 7),
  UsageKeywordRule("申请表", 9),
  UsageKeywordRule("文档", 5),
  UsageKeywordRule("表格", 5),
  UsageKeywordRule("填写", 4),
  UsageKeywordRule("documents", 6),
  UsageKeywordRule("render_docx", 8),
  UsageKeywordRule("xlsx", 7),
  UsageKeywordRule("spreadsheet", 6),
  UsageKeywordRule("excel", 6)
]
private let codingKeywordRules = [
  UsageKeywordRule("apply_patch", 10),
  UsageKeywordRule("swift test", 8),
  UsageKeywordRule("npm run", 7),
  UsageKeywordRule("package.swift", 6),
  UsageKeywordRule(".swift", 4),
  UsageKeywordRule(".jsx", 4),
  UsageKeywordRule(".tsx", 4),
  UsageKeywordRule("代码", 5),
  UsageKeywordRule("编程", 6),
  UsageKeywordRule("修复", 3),
  UsageKeywordRule("bug", 4),
  UsageKeywordRule("构建", 3),
  UsageKeywordRule("git diff", 5)
]
private let researchKeywordRules = [
  UsageKeywordRule("search_query", 8),
  UsageKeywordRule("web.run", 8),
  UsageKeywordRule("pubmed", 10),
  UsageKeywordRule("zotero", 9),
  UsageKeywordRule("doi", 7),
  UsageKeywordRule("literature", 8),
  UsageKeywordRule("文献", 9),
  UsageKeywordRule("检索", 8),
  UsageKeywordRule("browse", 5),
  UsageKeywordRule("搜索", 5),
  UsageKeywordRule("调研", 6),
  UsageKeywordRule("引用", 4),
  UsageKeywordRule("citations", 5),
  UsageKeywordRule("sourceurl", 4),
  UsageKeywordRule("联网", 4)
]
private let videoKeywordRules = [
  UsageKeywordRule("剪映", 10),
  UsageKeywordRule("jianying", 10),
  UsageKeywordRule("premiere", 10),
  UsageKeywordRule("after effects", 10),
  UsageKeywordRule("视频制作", 10),
  UsageKeywordRule("生成视频", 9),
  UsageKeywordRule("字幕", 7),
  UsageKeywordRule("配音", 7),
  UsageKeywordRule("video", 5),
  UsageKeywordRule("mp4", 5)
]
private let manuscriptKeywordRules = [
  UsageKeywordRule("manuscript", 10),
  UsageKeywordRule("response letter", 10),
  UsageKeywordRule("reviewer", 8),
  UsageKeywordRule("abstract", 8),
  UsageKeywordRule("discussion", 7),
  UsageKeywordRule("润色", 10),
  UsageKeywordRule("改写", 8),
  UsageKeywordRule("论文", 8),
  UsageKeywordRule("综述", 9),
  UsageKeywordRule("摘要", 8),
  UsageKeywordRule("审稿", 9),
  UsageKeywordRule("基金", 7),
  UsageKeywordRule("申请书", 8),
  UsageKeywordRule("翻译", 6)
]
private let dataAnalysisKeywordRules = [
  UsageKeywordRule("pandas", 10),
  UsageKeywordRule("numpy", 9),
  UsageKeywordRule("matplotlib", 9),
  UsageKeywordRule("scipy", 9),
  UsageKeywordRule("jupyter", 8),
  UsageKeywordRule("heatmap", 8),
  UsageKeywordRule("volcano", 8),
  UsageKeywordRule("pca", 7),
  UsageKeywordRule("统计分析", 10),
  UsageKeywordRule("数据分析", 10),
  UsageKeywordRule("数据清洗", 9),
  UsageKeywordRule("可视化", 6),
  UsageKeywordRule("作图", 5),
  UsageKeywordRule("绘图", 5)
]
private let lifeScienceKeywordRules = [
  UsageKeywordRule("rna-seq", 10),
  UsageKeywordRule("single-cell", 10),
  UsageKeywordRule("transcriptome", 9),
  UsageKeywordRule("proteome", 9),
  UsageKeywordRule("metabolome", 9),
  UsageKeywordRule("fasta", 8),
  UsageKeywordRule("gff", 8),
  UsageKeywordRule("vcf", 8),
  UsageKeywordRule("kegg", 8),
  UsageKeywordRule("bioinformatics", 10),
  UsageKeywordRule("水稻", 10),
  UsageKeywordRule("褐飞虱", 10),
  UsageKeywordRule("病毒", 8),
  UsageKeywordRule("基因", 7),
  UsageKeywordRule("蛋白", 7),
  UsageKeywordRule("转录组", 9),
  UsageKeywordRule("代谢组", 9),
  UsageKeywordRule("组学", 8),
  UsageKeywordRule("生物信息", 10)
]
private let webDevelopmentKeywordRules = [
  UsageKeywordRule("astro", 10),
  UsageKeywordRule("next.js", 10),
  UsageKeywordRule("react", 8),
  UsageKeywordRule("cloudflare", 9),
  UsageKeywordRule("website", 8),
  UsageKeywordRule("网页", 9),
  UsageKeywordRule("网站", 9),
  UsageKeywordRule("部署", 7),
  UsageKeywordRule("路由", 6),
  UsageKeywordRule("css", 6),
  UsageKeywordRule("html", 6)
]
private let systemOperationsKeywordRules = [
  UsageKeywordRule("launchagent", 10),
  UsageKeywordRule("launchctl", 10),
  UsageKeywordRule("synology", 10),
  UsageKeywordRule("cloudflare tunnel", 10),
  UsageKeywordRule("dns", 8),
  UsageKeywordRule("nas920", 8),
  UsageKeywordRule("terminal", 6),
  UsageKeywordRule("群晖", 10),
  UsageKeywordRule("内网穿透", 10),
  UsageKeywordRule("网络问题", 9),
  UsageKeywordRule("电脑维护", 9),
  UsageKeywordRule("服务器", 7),
  UsageKeywordRule("自动启动", 7),
  UsageKeywordRule("安装", 5),
  UsageKeywordRule("权限", 5)
]

public final class CodexStatusReader: @unchecked Sendable {
  private let fileManager: FileManager
  private let codexHome: URL
  private let sessionRoots: [URL]
  private let maxSessionFiles: Int
  private let liveRateLimitSource: CodexAppServerRateLimitSource?
  private let resetCreditsSource: CodexResetCreditsSource?
  private let accountUsageSource: CodexProfileUsageSource?
  private let usageSyncStore: CodexUsageSyncStore?
  private let persistentEventCacheURL: URL?
  private var eventCache: [String: ParsedFileCache] = [:]
  private var tokenStatsCache: TokenStatsCache?
  private var workspaceRootLabels: [String: String] = [:]
  private var didLoadPersistentEventCache = false
  private var persistentEventCacheDirty = false

  public init(
    codexHome: URL? = nil,
    sessionsRoot: URL? = nil,
    maxSessionFiles: Int = 1000,
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
    self.maxSessionFiles = maxSessionFiles
    self.liveRateLimitSource = preferLiveStatus && codexHome == nil && sessionsRoot == nil
      ? CodexAppServerRateLimitSource()
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
      self.persistentEventCacheURL = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexSuanliMeter/session-event-cache-v5.plist")
    } else {
      self.persistentEventCacheURL = nil
    }
  }

  public func read(now: Date = Date()) throws -> CodexStatus {
    loadPersistentEventCacheIfNeeded()
    workspaceRootLabels = loadWorkspaceRootLabels()
    let files = listJSONLFiles()
    let activePaths = Set(files.map(\.path))
    let filteredCache = eventCache.filter { activePaths.contains($0.key) }
    if filteredCache.count != eventCache.count {
      eventCache = filteredCache
      persistentEventCacheDirty = true
    }
    let events = files
      .flatMap { parseEvents(in: $0, now: now) }
      .sorted { $0.timestamp < $1.timestamp }
    persistEventCacheIfNeeded()
    let liveSnapshot = liveRateLimitSource?.cachedSnapshot(now: now) ?? .empty
    let liveEvents = liveSnapshot.events
    liveRateLimitSource?.refreshInBackground()
    let resetCredits = resetCreditsSource?.cached(now: now) ?? liveSnapshot.resetCredits
    resetCreditsSource?.refreshInBackground()
    let accountUsage = accountUsageSource?.cachedUsage(now: now)
    accountUsageSource?.refreshInBackground(now: now)
    let combinedEvents = (events + liveEvents).sorted { $0.timestamp < $1.timestamp }

    let latestByLimit = Self.latestByLimit(from: combinedEvents)

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
    tokenStats.deviceUsage = usageSyncStore?.persistAndReadSnapshots(from: tokenStats, now: now) ?? []

    return CodexStatus(
      generatedAt: now,
      codexHome: codexHome.path,
      sessionsRoot: sessionRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: limits,
      trend: Array(trend),
      rateLimitResetCredits: resetCredits,
      tokenStats: tokenStats,
      recentEvents: Array(recentEvents.suffix(18).reversed())
    )
  }

  public func readFast(
    now: Date = Date(),
    fileLimit: Int = 8,
    tailBytes: Int = 768 * 1024
  ) throws -> CodexStatus {
    workspaceRootLabels = loadWorkspaceRootLabels()
    let files = Array(listJSONLFiles().prefix(fileLimit))
    let events = files
      .flatMap { parseRecentEvents(in: $0, now: now, tailBytes: tailBytes) }
      .sorted { $0.timestamp < $1.timestamp }
    let liveSnapshot = liveRateLimitSource?.freshSnapshot(now: now) ?? .empty
    let liveEvents = liveSnapshot.events
    let resetCredits = resetCreditsSource?.fresh(now: now) ?? liveSnapshot.resetCredits
    let accountUsage = accountUsageSource?.cachedUsage(now: now)
    accountUsageSource?.refreshInBackground(now: now)
    let combinedEvents = (events + liveEvents).sorted { $0.timestamp < $1.timestamp }

    let latestByLimit = Self.latestByLimit(from: combinedEvents)
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

    return CodexStatus(
      generatedAt: now,
      codexHome: codexHome.path,
      sessionsRoot: sessionRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: limits,
      trend: Array(trend),
      rateLimitResetCredits: resetCredits,
      tokenStats: tokenStats,
      recentEvents: Array(combinedEvents.suffix(18).reversed())
    )
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

  private static func shouldKeep(existing: RateLimitEvent, over candidate: RateLimitEvent) -> Bool {
    let existingIsLive = existing.sourceName == "Codex app-server"
    let candidateIsLive = candidate.sourceName == "Codex app-server"
    let freshStatusGrace: TimeInterval = 120

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

  private func listJSONLFiles() -> [URL] {
    var files: [(url: URL, modified: Date)] = []
    var seenPaths = Set<String>()

    for root in sessionRoots {
      guard fileManager.fileExists(atPath: root.path),
            let enumerator = fileManager.enumerator(
              at: root,
              includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
              options: [.skipsHiddenFiles]
            )
      else {
        continue
      }

      for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        let path = url.standardizedFileURL.path
        guard seenPaths.insert(path).inserted,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true
        else {
          continue
        }
        files.append((url, values.contentModificationDate ?? .distantPast))
      }
    }

    return files
      .sorted { $0.modified > $1.modified }
      .prefix(maxSessionFiles)
      .map(\.url)
  }

  private static func discoverSessionRoots(fileManager: FileManager) -> [URL] {
    let home = fileManager.homeDirectoryForCurrentUser
    let candidates = [
      home.appendingPathComponent(".codex/sessions"),
      home.appendingPathComponent(".codex/browser/sessions"),
      home.appendingPathComponent("Library/Application Support/Codex/sessions"),
      home.appendingPathComponent("Library/Application Support/com.openai.codex/sessions")
    ]

    return candidates.filter { containsJSONL(in: $0, fileManager: fileManager) }
  }

  private static func containsJSONL(in root: URL, fileManager: FileManager) -> Bool {
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

  private func parseEvents(in file: URL, now: Date) -> [RateLimitEvent] {
    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modified = values?.contentModificationDate ?? .distantPast
    let fileSize = values?.fileSize ?? -1
    let cacheKey = file.path
    if let cached = eventCache[cacheKey],
       cached.modified == modified,
       cached.fileSize == fileSize {
      return cached.events
    }

    if let cached = eventCache[cacheKey],
       fileSize >= cached.fileSize,
       let appendedText = readText(in: file, fromOffset: cached.fileSize) {
      let split = splitCompleteJSONLines(cached.pendingLine + appendedText)
      let parsed = autoreleasepool {
        parseEventLines(
          split.complete,
          file: file,
          initialScores: cached.pendingScores,
          initialProjectName: cached.pendingProjectName,
          initialProjectPath: cached.pendingProjectPath,
          initialModel: cached.pendingModel,
          initialCategory: cached.pendingCategory
        )
      }
      let newEvents = parsed.events
      let nextEvents = newEvents.isEmpty ? cached.events : cached.events + newEvents
      eventCache[cacheKey] = ParsedFileCache(
        modified: modified,
        fileSize: fileSize,
        pendingScores: parsed.pendingScores,
        pendingProjectName: parsed.pendingProjectName,
        pendingProjectPath: parsed.pendingProjectPath,
        pendingModel: parsed.pendingModel,
        pendingCategory: parsed.pendingCategory,
        pendingLine: split.pending,
        events: nextEvents
      )
      persistentEventCacheDirty = true
      return nextEvents
    }

    let parsedCache: ParsedFileCache? = autoreleasepool {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
      let split = splitCompleteJSONLines(text)
      let fallbackProjectName = projectName(fromPath: file.deletingPathExtension().lastPathComponent)
      let parsed = parseEventLines(
        split.complete,
        file: file,
        initialScores: emptyCategoryScores(),
        initialProjectName: fallbackProjectName,
        initialProjectPath: file.path,
        initialModel: "unknown",
        initialCategory: .other
      )
      return ParsedFileCache(
        modified: modified,
        fileSize: fileSize,
        pendingScores: parsed.pendingScores,
        pendingProjectName: parsed.pendingProjectName,
        pendingProjectPath: parsed.pendingProjectPath,
        pendingModel: parsed.pendingModel,
        pendingCategory: parsed.pendingCategory,
        pendingLine: split.pending,
        events: parsed.events
      )
    }
    guard let parsedCache else {
      return []
    }
    eventCache[cacheKey] = parsedCache
    persistentEventCacheDirty = true
    return parsedCache.events
  }

  /// Keep an in-progress final JSONL record and resume from the previous byte offset.
  private func splitCompleteJSONLines(_ text: String) -> (complete: String, pending: String) {
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

  private func loadPersistentEventCacheIfNeeded() {
    guard !didLoadPersistentEventCache else { return }
    didLoadPersistentEventCache = true
    guard let persistentEventCacheURL,
          let data = try? Data(contentsOf: persistentEventCacheURL),
          let cache = try? PropertyListDecoder().decode(PersistentEventCache.self, from: data),
          cache.schemaVersion == PersistentEventCache.currentSchemaVersion
    else { return }
    eventCache = cache.files
  }

  private func persistEventCacheIfNeeded() {
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

  private func parseRecentEvents(in file: URL, now: Date, tailBytes: Int) -> [RateLimitEvent] {
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

  private func parseEventLines(
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

  private func updateModelContextIfPresent(_ line: Substring, model: inout String) {
    guard asciiContains(line.utf8, turnContextNeedle),
          let parsed = Self.jsonStringField("model", in: String(line))?.trimmingCharacters(in: .whitespacesAndNewlines),
          !parsed.isEmpty
    else { return }
    model = parsed
  }

  private func readText(in file: URL, fromOffset offset: Int) -> String? {
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

  private func readTailText(in file: URL, maxBytes: Int) -> String? {
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

  private func updateProjectContextIfPresent(
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

  private static func projectName(fromPath path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "未知项目".coreL10n }
    let name = URL(fileURLWithPath: trimmed).lastPathComponent
    return name.isEmpty ? trimmed : name
  }

  private func projectName(fromPath path: String) -> String {
    Self.projectName(fromPath: path)
  }

  private func loadWorkspaceRootLabels() -> [String: String] {
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

  private func workspaceLabel(for path: String) -> String? {
    let normalizedPath = Self.standardizedPath(path)
    if let label = workspaceRootLabels[normalizedPath] {
      return label
    }

    return workspaceRootLabels
      .filter { root, _ in normalizedPath == root || normalizedPath.hasPrefix(root + "/") }
      .max { lhs, rhs in lhs.key.count < rhs.key.count }?
      .value
  }

  private func workspaceLabelSignature() -> String {
    workspaceRootLabels
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "\u{1f}")
  }

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func jsonStringField(_ key: String, in text: String) -> String? {
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

  private func normalizeWindow(_ window: [String: Any]?) -> LimitWindow? {
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

  private func percentValue(in dictionary: [String: Any], keys: [String]) -> Double? {
    for key in keys where dictionary.keys.contains(key) {
      return double(dictionary[key])
    }
    return nil
  }

  private func normalizeUsage(_ info: [String: Any]?) -> TokenUsage {
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

  private func emptyCategoryScores() -> [TokenUsageCategory: Int] {
    Dictionary(uniqueKeysWithValues: TokenUsageCategory.allCases.map { ($0, 0) })
  }

  private func scoreContextLineIfRelevant(
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

  private func isScorableContextLine<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
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

  private func category(from scores: [TokenUsageCategory: Int]) -> TokenUsageCategory {
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

  private func addScore(
    _ scores: inout [TokenUsageCategory: Int],
    _ category: TokenUsageCategory,
    _ text: String.UTF8View,
    _ rules: [UsageKeywordRule]
  ) {
    for rule in rules where asciiContains(text, rule.bytes) {
      scores[category, default: 0] += rule.weight
    }
  }

  private func categoryPriority(_ category: TokenUsageCategory) -> Int {
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

  private func resolvedCategory(
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

  private func categoryFromProject(name: String, path: String) -> TokenUsageCategory {
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

  private func buildCachedTokenStats(from events: [RateLimitEvent], now: Date) -> TokenStats {
    let dayKey = hourKey(now)
    let signature = tokenStatsSignature(for: events)
    if let cached = tokenStatsCache,
       cached.signature == signature,
       cached.dayKey == dayKey {
      return cached.stats
    }

    let stats = buildTokenStats(from: events, now: now)
    tokenStatsCache = TokenStatsCache(signature: signature, dayKey: dayKey, stats: stats)
    return stats
  }

  private func tokenStatsSignature(for events: [RateLimitEvent]) -> String {
    guard let last = events.last else { return "empty" }
    return [
      String(events.count),
      last.sourcePath,
      String(last.timestamp.timeIntervalSince1970),
      String(last.usage.totalTokens),
      String(last.usage.lastTotalTokens),
      last.model,
      String(last.usage.lastCachedInputTokens),
      workspaceLabelSignature()
    ].joined(separator: "|")
  }

  private func buildTokenStats(from events: [RateLimitEvent], now: Date) -> TokenStats {
    let usageEvents = buildTokenUsageEvents(from: events)
    var daily: [String: TokenBucket] = [:]
    var monthly: [String: TokenBucket] = [:]
    var hourly: [String: TokenBucket] = [:]
    var modelHourly: [String: ModelHourlyBucket] = [:]

    for event in usageEvents {
      add(event, to: &daily, key: periodKey(event.timestamp, period: .day))
      add(event, to: &monthly, key: periodKey(event.timestamp, period: .month))
      let hour = hourKey(event.timestamp)
      add(event, to: &hourly, key: hour, label: formatHourLabel(event.timestamp))
      add(event, to: &modelHourly, hourKey: hour)
    }

    let dailyRows = fillDailyRows(daily, count: 30, now: now)
    let monthlyRows = fillMonthlyRows(monthly, count: 6, now: now)
    let todayKey = periodKey(now, period: .day)
    let monthKey = periodKey(now, period: .month)
    let cutoff24h = now.addingTimeInterval(-24 * 60 * 60)
    let cutoff7d = now.addingTimeInterval(-7 * 24 * 60 * 60)
    let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? .distantPast
    let events24h = usageEvents.filter { $0.timestamp >= cutoff24h && $0.timestamp <= now }
    let events7d = usageEvents.filter { $0.timestamp >= cutoff7d && $0.timestamp <= now }
    let eventsMonth = usageEvents.filter { $0.timestamp >= monthStart && $0.timestamp <= now }
    let last7Keys = Set(fillDailyKeys(count: 7, now: now))
    let last7Tokens = daily
      .filter { last7Keys.contains($0.key) }
      .reduce(0) { $0 + $1.value.totalTokens }
    let categoryBreakdown = buildCategoryBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .month) == monthKey }
    )
    let todayTopProjects = buildProjectBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .day) == todayKey },
      limit: 3
    )
    let monthTopProjects = buildProjectBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .month) == monthKey },
      limit: 3
    )

    return TokenStats(
      rolling24HoursTokens: events24h.reduce(0) { $0 + $1.totalTokens },
      todayTokens: daily[todayKey]?.totalTokens ?? 0,
      monthTokens: monthly[monthKey]?.totalTokens ?? 0,
      last7DaysTokens: last7Tokens,
      sampleCount: usageEvents.count,
      hourly: fillHourlyRows(hourly, count: 24, now: now),
      modelHourly: modelHourly.values
        .filter { Int($0.hourKey).map { Date(timeIntervalSince1970: Double($0 * 3600)) >= monthStart } ?? false }
        .sorted { $0.id < $1.id },
      daily: dailyRows,
      monthly: monthlyRows,
      cost24Hours: ModelPricingCatalog.current.estimate(events: events24h),
      cost7Days: ModelPricingCatalog.current.estimate(events: events7d),
      costMonth: ModelPricingCatalog.current.estimate(events: eventsMonth),
      categoryBreakdown: categoryBreakdown,
      todayTopProjects: todayTopProjects,
      monthTopProjects: monthTopProjects,
      recentUsageEvents: Array(usageEvents.suffix(12).reversed())
    )
  }

  private func buildTokenUsageEvents(from events: [RateLimitEvent]) -> [TokenUsageEvent] {
    var unique: [String: TokenUsageEvent] = [:]
    for event in events where event.usage.lastTotalTokens > 0 && event.usage.totalTokens > 0 {
      // `totalTokens` is cumulative within one rollout file. Codex can emit
      // multiple quota snapshots without advancing that cumulative counter,
      // sometimes with a different `lastTotalTokens` value. Count the first
      // occurrence only so a status-only refresh never becomes new usage.
      let key = "\(event.sourcePath):\(event.usage.totalTokens)"
      let displayProjectName = workspaceLabel(for: event.projectPath) ?? event.projectName
      let usageEvent = TokenUsageEvent(
        timestamp: event.timestamp,
        sourceName: event.sourceName,
        model: event.model,
        totalTokens: event.usage.lastTotalTokens,
        inputTokens: event.usage.lastInputTokens,
        cachedInputTokens: event.usage.lastCachedInputTokens,
        outputTokens: event.usage.lastOutputTokens,
        reasoningOutputTokens: event.usage.lastReasoningOutputTokens,
        category: event.usageCategory,
        projectName: displayProjectName,
        projectPath: event.projectPath
      )
      if unique[key]?.timestamp ?? .distantFuture > usageEvent.timestamp {
        unique[key] = usageEvent
      }
    }
    return unique.values.sorted { $0.timestamp < $1.timestamp }
  }

  private func add(_ event: TokenUsageEvent, to buckets: inout [String: TokenBucket], key: String) {
    var bucket = buckets[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.cachedInputTokens += event.cachedInputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  private func add(
    _ event: TokenUsageEvent,
    to buckets: inout [String: TokenBucket],
    key: String,
    label: String
  ) {
    var bucket = buckets[key] ?? TokenBucket(key: key, label: label)
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.cachedInputTokens += event.cachedInputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  private func add(
    _ event: TokenUsageEvent,
    to buckets: inout [String: ModelHourlyBucket],
    hourKey: String
  ) {
    let model = event.model.isEmpty ? "unknown" : event.model
    let key = "\(hourKey)|\(model)"
    var bucket = buckets[key] ?? ModelHourlyBucket(hourKey: hourKey, model: model)
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.cachedInputTokens += event.cachedInputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  private func buildCategoryBreakdown(from events: [TokenUsageEvent]) -> [TokenCategoryBucket] {
    var rows = Dictionary(
      uniqueKeysWithValues: TokenUsageCategory.allCases.map {
        ($0, TokenCategoryBucket(category: $0))
      }
    )

    for event in events {
      var bucket = rows[event.category] ?? TokenCategoryBucket(category: event.category)
      bucket.totalTokens += event.totalTokens
      bucket.inputTokens += event.inputTokens
      bucket.outputTokens += event.outputTokens
      bucket.reasoningOutputTokens += event.reasoningOutputTokens
      bucket.calls += 1
      rows[event.category] = bucket
    }

    return TokenUsageCategory.allCases.compactMap { rows[$0] }
  }

  private func buildProjectBreakdown(from events: [TokenUsageEvent], limit: Int) -> [TokenProjectBucket] {
    var rows: [String: TokenProjectBucket] = [:]
    for event in events {
      let key = event.projectPath.isEmpty ? event.projectName : event.projectPath
      var bucket = rows[key] ?? TokenProjectBucket(
        projectName: event.projectName,
        projectPath: event.projectPath
      )
      bucket.totalTokens += event.totalTokens
      bucket.calls += 1
      rows[key] = bucket
    }

    return rows.values
      .sorted {
        if $0.totalTokens == $1.totalTokens {
          return $0.projectName < $1.projectName
        }
        return $0.totalTokens > $1.totalTokens
      }
      .prefix(limit)
      .map { $0 }
  }

  private func fillDailyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    fillDailyKeys(count: count, now: now).map { rows[$0] ?? TokenBucket(key: $0, label: formatPeriodLabel($0)) }
  }

  private func fillHourlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    let currentHour = Int(floor(now.timeIntervalSince1970 / 3600))
    return (0..<count).map { index in
      let value = currentHour - (count - 1 - index)
      let key = String(value)
      let date = Date(timeIntervalSince1970: Double(value * 3600))
      return rows[key] ?? TokenBucket(key: key, label: formatHourLabel(date))
    }
  }

  private func hourKey(_ date: Date) -> String {
    String(Int(floor(date.timeIntervalSince1970 / 3600)))
  }

  private func formatHourLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M/d HH时"
    return formatter.string(from: date)
  }

  private func fillDailyKeys(count: Int, now: Date) -> [String] {
    let calendar = Calendar.current
    return (0..<count).compactMap { index in
      let offset = count - 1 - index
      return calendar.date(byAdding: .day, value: -offset, to: now).map { periodKey($0, period: .day) }
    }
  }

  private func fillMonthlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    let calendar = Calendar.current
    return (0..<count).compactMap { index -> TokenBucket? in
      let offset = count - 1 - index
      guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { return nil }
      let key = periodKey(date, period: .month)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  private enum Period {
    case day
    case month
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

private final class CodexProfileUsageSource: @unchecked Sendable {
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

private struct LiveAccountRateLimitSnapshot: Sendable {
  var events: [RateLimitEvent]
  var resetCredits: RateLimitResetCreditsSummary?

  static let empty = LiveAccountRateLimitSnapshot(events: [], resetCredits: nil)
  var hasContent: Bool { !events.isEmpty || resetCredits != nil }
}

private final class CodexAppServerRateLimitSource: @unchecked Sendable {
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

  deinit {
    stop()
  }

  func cachedSnapshot(now: Date, maxAge: TimeInterval = 20) -> LiveAccountRateLimitSnapshot {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    guard let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge else {
      return .empty
    }
    return cachedSnapshot
  }

  func freshSnapshot(now: Date, maxAge: TimeInterval = 20) -> LiveAccountRateLimitSnapshot {
    cacheLock.lock()
    if let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge {
      let snapshot = cachedSnapshot
      cacheLock.unlock()
      return snapshot
    }
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      let snapshot = cachedSnapshot
      cacheLock.unlock()
      return snapshot
    }
    refreshInFlight = true
    cacheLock.unlock()

    let snapshot = fetchSnapshot(now: now)
    cacheLock.lock()
    if snapshot.hasContent {
      cachedSnapshot = snapshot
      cachedAt = Date()
    }
    refreshInFlight = false
    cacheLock.unlock()
    return snapshot
  }

  func refreshInBackground() {
    let now = Date()
    cacheLock.lock()
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      cacheLock.unlock()
      return
    }
    refreshInFlight = true
    cacheLock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let snapshot = self.fetchSnapshot(now: Date())

      self.cacheLock.lock()
      if snapshot.hasContent {
        self.cachedSnapshot = snapshot
        self.cachedAt = Date()
      }
      self.refreshInFlight = false
      self.cacheLock.unlock()
    }
  }

  private func fetchSnapshot(now: Date) -> LiveAccountRateLimitSnapshot {
    do {
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
        resetCredits: payload.rateLimitResetCredits
      )
    } catch {
      NSLog("CodexBalance live rate limit source failed: \(error.localizedDescription)")
      stop()
      markFailureCooldown(seconds: 15)
      return .empty
    }
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
    nextProcess.standardInput = nextInputPipe
    nextProcess.standardOutput = nextOutputPipe
    nextProcess.standardError = nextErrorPipe

    nextOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard data.isEmpty == false else {
        self?.handleProcessExit()
        return
      }
      self?.appendOutput(data)
    }
    nextErrorPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    nextProcess.terminationHandler = { [weak self] _ in
      self?.handleProcessExit()
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

  private func handleProcessExit() {
    condition.lock()
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

  private static func codexExecutableURL() -> URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates = [
      // Codex 2026 起打包进 ChatGPT.app；旧 Codex.app 仍兼容
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
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
