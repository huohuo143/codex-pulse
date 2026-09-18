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

  public static let attributionText = "公开资料来自 Codex Radar / Tibo X · 概率由 App 本地规则估算"
  public static let endpointURL = URL(string: "https://codexradar.com/")!
  public static let siteURL = endpointURL
  public static let legacyPublicJSONURL = URL(string: "https://codexradar.com/current.json")!
  public static let fullAPIURL = URL(string: "https://codexradar.com/api/v1/current")!
  public static let stationInsightsURL = URL(string: "https://codexradar.com/api/radar-insights")!
  public static let efficiencyURL = URL(string: "https://codexradar.com/data/intelligence-efficiency.json")!
  public static let refreshInterval: TimeInterval = 30 * 60
  public static let localEvaluationInterval: TimeInterval = 5 * 60
  public static let sourceStaleInterval: TimeInterval = 90 * 60
  public static let publicSummaryModeText = "Codex Radar 公开只读源，无需 API Key 或 X Cookie"

  private let fetcher: Fetcher
  private let publicPageFetcher: Fetcher?
  private let stationInsightsFetcher: Fetcher?
  private let efficiencyFetcher: Fetcher?
  private let now: @Sendable () -> Date
  private let cacheDuration: TimeInterval
  private let historyURL: URL?
  private let usesLegacyPublicSummary: Bool
  private var cachedSnapshot: CodexRadarSnapshot?
  private var cachedAt: Date?
  private var historyLoaded = false
  private var tiboHistory = CodexRadarTiboHistory(resetAt: nil, posts: [])

  public init(
    fetcher: Fetcher? = nil,
    publicPageFetcher: Fetcher? = nil,
    stationInsightsFetcher: Fetcher? = nil,
    efficiencyFetcher: Fetcher? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    cacheDuration: TimeInterval = CodexRadarService.refreshInterval,
    historyURL: URL? = nil
  ) {
    self.now = now
    self.cacheDuration = cacheDuration
    self.usesLegacyPublicSummary = fetcher == nil
    self.historyURL = historyURL ?? (fetcher == nil ? CodexRadarTiboHistoryStore.defaultURL : nil)
    if let fetcher {
      self.fetcher = fetcher
      self.publicPageFetcher = publicPageFetcher
      self.stationInsightsFetcher = stationInsightsFetcher
      self.efficiencyFetcher = efficiencyFetcher
    } else {
      self.fetcher = {
        try await CodexRadarService.fetch(
          url: CodexRadarService.legacyPublicJSONURL,
          accept: "application/json"
        )
      }
      self.publicPageFetcher = publicPageFetcher ?? {
        try await CodexRadarService.fetch(
          url: CodexRadarService.endpointURL,
          accept: "text/html",
          cacheBust: true
        )
      }
      self.stationInsightsFetcher = stationInsightsFetcher ?? {
        try await CodexRadarService.fetch(
          url: CodexRadarService.stationInsightsURL,
          accept: "application/json"
        )
      }
      self.efficiencyFetcher = efficiencyFetcher ?? {
        try await CodexRadarService.fetch(
          url: CodexRadarService.efficiencyURL,
          accept: "application/json"
        )
      }
    }
  }

  public func current(force: Bool = false) async throws -> CodexRadarSnapshot {
    let checkedAt = now()
    if !force,
       let cachedSnapshot,
       let cachedAt,
       checkedAt.timeIntervalSince(cachedAt) < cacheDuration {
      return reevaluate(snapshot: cachedSnapshot, at: checkedAt)
    }

    async let stationData = optionalFetch(stationInsightsFetcher)
    async let efficiencyData = optionalFetch(efficiencyFetcher)

    var storedHistory = loadTiboHistory()
    var baseError: Error?
    var snapshot: CodexRadarSnapshot?
    do {
      snapshot = try CodexRadarCodec.decode(try await fetcher())
      if usesLegacyPublicSummary {
        // The production current.json percentage is a stale remote judgement.
        // Keep only its reset-window anchor; all displayed probability is local.
        snapshot?.prediction = nil
      }
    } catch {
      baseError = error
    }

    var page: CodexRadarPublicPageSnapshot?
    var pageError: Error?
    if let publicPageFetcher {
      do {
        let pageData = try await publicPageFetcher()
        let decoded = try CodexRadarPublicPageParser.decode(pageData, now: checkedAt)
        if let incomingUpdate = decoded.tiboFeed.updatedAt,
           let storedUpdate = storedHistory.feedUpdatedAt,
           incomingUpdate < storedUpdate.addingTimeInterval(-60) {
          throw CodexRadarError.invalidPayload
        }
        page = decoded
      } catch {
        pageError = error
      }
    }
    if var enrichedPage = page {
      if let completedAt = snapshot?.window?.closedAt {
        enrichedPage.resetAt = [enrichedPage.resetAt, completedAt]
          .compactMap { $0 }
          .max()
        if enrichedPage.eventKind == nil {
          enrichedPage.eventKind = "window_closed"
          enrichedPage.eventStatus = "completed"
        }
      }
      let pageResetAt = CodexRadarVerifiedTiboSignals.resetAnchor(for: enrichedPage)
      let resetAt = [storedHistory.resetAt, pageResetAt]
        .compactMap { $0 }
        .max()
      enrichedPage.resetAt = resetAt
      enrichedPage.tiboFeed.posts = CodexRadarVerifiedTiboSignals.mergedPosts(
        current: enrichedPage.tiboFeed.posts,
        previous: (cachedSnapshot?.tiboFeed?.posts ?? []) + storedHistory.posts,
        resetAt: resetAt,
        now: checkedAt
      )
      storedHistory = CodexRadarTiboHistory(
        resetAt: resetAt,
        posts: enrichedPage.tiboFeed.posts,
        lastAttemptAt: checkedAt,
        lastSuccessAt: checkedAt,
        feedUpdatedAt: maxDate(storedHistory.feedUpdatedAt, enrichedPage.tiboFeed.updatedAt),
        feedFingerprint: enrichedPage.feedFingerprint ?? storedHistory.feedFingerprint,
        consecutiveFailures: 0
      )
      persistTiboHistory(storedHistory)
      page = enrichedPage
    } else if publicPageFetcher != nil {
      storedHistory.lastAttemptAt = checkedAt
      storedHistory.consecutiveFailures = (storedHistory.consecutiveFailures ?? 0) + 1
      persistTiboHistory(storedHistory)
      page = cachedPage(
        base: snapshot,
        cached: cachedSnapshot,
        history: storedHistory,
        at: checkedAt
      )
    }
    if snapshot == nil, let page {
      snapshot = makePublicSnapshot(from: page)
    }
    guard var snapshot else {
      throw baseError ?? CodexRadarError.invalidPayload
    }

    if let page {
      snapshot.publicJudgement = page.judgement
      snapshot.tiboFeed = page.tiboFeed
      if page.eventKind != nil || page.eventStatus != nil || page.tiboFeed.posts.isEmpty == false {
        snapshot.localResetEstimate = CodexRadarResetScorer.estimate(from: page, now: checkedAt)
      }
      snapshot.tiboPresence = makeTiboPresence(from: page)
      snapshot.monitoredAt = max(snapshot.monitoredAt ?? .distantPast, page.tiboFeed.updatedAt ?? page.judgement.updatedAt)
      snapshot.links = CodexRadarLinks(
        html: Self.siteURL.absoluteString,
        rss: snapshot.links?.rss,
        fullAPI: Self.fullAPIURL.absoluteString
      )
    }

    if snapshot.service == "codex-reset-radar",
       snapshot.localResetEstimate == nil,
       let updatedAt = snapshot.prediction?.updatedAt,
       checkedAt.timeIntervalSince(updatedAt) > 72 * 60 * 60 {
      snapshot.prediction = nil
    }

    if let data = await stationData {
      snapshot.stationInsights = try? CodexRadarStationInsights.decode(from: data)
    }
    if let data = await efficiencyData {
      snapshot.efficiency = try? CodexRadarEfficiencySnapshot.decode(from: data)
    }

    if let cachedSnapshot {
      preserveLastGoodOptionalData(from: cachedSnapshot, in: &snapshot)
    }
    if publicPageFetcher != nil {
      snapshot.syncState = syncState(
        from: storedHistory,
        at: checkedAt,
        usingCache: pageError != nil,
        failureMessage: pageError?.localizedDescription
      )
    }
    cachedSnapshot = snapshot
    cachedAt = checkedAt
    return snapshot
  }

  public func reevaluate() -> CodexRadarSnapshot? {
    guard let cachedSnapshot else { return nil }
    return reevaluate(snapshot: cachedSnapshot, at: now())
  }

  public static func retryDelay(afterConsecutiveFailures failures: Int) -> TimeInterval {
    switch max(1, failures) {
    case 1: 60
    case 2: 5 * 60
    case 3: 15 * 60
    default: refreshInterval
    }
  }

  public func clearCache() {
    cachedSnapshot = nil
    cachedAt = nil
  }

  private func optionalFetch(_ fetcher: Fetcher?) async -> Data? {
    guard let fetcher else { return nil }
    return try? await fetcher()
  }

  private func loadTiboHistory() -> CodexRadarTiboHistory {
    if historyLoaded { return tiboHistory }
    historyLoaded = true
    if let historyURL,
       let stored = CodexRadarTiboHistoryStore.load(from: historyURL) {
      tiboHistory = stored
    }
    return tiboHistory
  }

  private func persistTiboHistory(_ history: CodexRadarTiboHistory) {
    historyLoaded = true
    tiboHistory = history
    if let historyURL {
      CodexRadarTiboHistoryStore.save(history, to: historyURL)
    }
  }

  private func reevaluate(
    snapshot original: CodexRadarSnapshot,
    at date: Date
  ) -> CodexRadarSnapshot {
    guard publicPageFetcher != nil else { return original }
    var snapshot = original
    let history = loadTiboHistory()
    if let page = cachedPage(base: snapshot, cached: snapshot, history: history, at: date) {
      snapshot.localResetEstimate = CodexRadarResetScorer.estimate(from: page, now: date)
      snapshot.tiboFeed = page.tiboFeed
    }
    snapshot.syncState = syncState(
      from: history,
      at: date,
      usingCache: (history.consecutiveFailures ?? 0) > 0,
      failureMessage: snapshot.syncState?.failureMessage
    )
    cachedSnapshot = snapshot
    return snapshot
  }

  private func cachedPage(
    base: CodexRadarSnapshot?,
    cached: CodexRadarSnapshot?,
    history: CodexRadarTiboHistory,
    at date: Date
  ) -> CodexRadarPublicPageSnapshot? {
    let posts = (cached?.tiboFeed?.posts ?? []) + history.posts
    let resetAt = [history.resetAt, base?.window?.closedAt]
      .compactMap { $0 }
      .max()
    guard posts.isEmpty == false || resetAt != nil || cached?.publicJudgement != nil else {
      return nil
    }
    let merged = CodexRadarVerifiedTiboSignals.mergedPosts(
      current: posts,
      resetAt: resetAt,
      now: date
    )
    let judgement = cached?.publicJudgement ?? CodexRadarPublicJudgement(
      updatedAt: history.feedUpdatedAt ?? resetAt ?? date,
      kind: "Tibo 动态",
      level: nil,
      headline: "根据 Tibo 公开动态本地估算",
      summary: "正在使用上次成功同步的 Tibo 公开动态重新评估。"
    )
    let completed = resetAt != nil
    return CodexRadarPublicPageSnapshot(
      judgement: judgement,
      eventKind: completed ? "window_closed" : nil,
      eventStatus: completed ? "completed" : nil,
      confirmation: nil,
      resetAt: resetAt,
      tiboFeed: CodexRadarTiboFeed(
        updatedAt: history.feedUpdatedAt ?? cached?.tiboFeed?.updatedAt,
        posts: merged
      ),
      feedFingerprint: history.feedFingerprint
    )
  }

  private func syncState(
    from history: CodexRadarTiboHistory,
    at date: Date,
    usingCache: Bool,
    failureMessage: String?
  ) -> CodexRadarSyncState {
    let stale = history.lastSuccessAt.map {
      date.timeIntervalSince($0) >= Self.sourceStaleInterval
    } ?? true
    return CodexRadarSyncState(
      lastAttemptAt: history.lastAttemptAt,
      lastSuccessAt: history.lastSuccessAt,
      feedUpdatedAt: history.feedUpdatedAt,
      consecutiveFailures: history.consecutiveFailures ?? 0,
      isUsingCachedFeed: usingCache,
      isStale: stale,
      failureMessage: failureMessage
    )
  }

  private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    [lhs, rhs].compactMap { $0 }.max()
  }

  private func makePublicSnapshot(
    from page: CodexRadarPublicPageSnapshot
  ) -> CodexRadarSnapshot {
    CodexRadarSnapshot(
      schemaVersion: "codexradar-public-page-v1",
      service: "codex-radar-public",
      type: "public-page",
      monitoredAt: page.tiboFeed.updatedAt ?? page.judgement.updatedAt,
      timezone: "Asia/Shanghai",
      windowOpen: page.eventStatus?.lowercased() == "active",
      status: page.eventStatus,
      recommendedAction: "verify-source",
      window: nil,
      prediction: nil,
      tiboPresence: nil,
      links: CodexRadarLinks(
        html: Self.siteURL.absoluteString,
        rss: nil,
        fullAPI: Self.fullAPIURL.absoluteString
      ),
      publicJudgement: page.judgement,
      tiboFeed: page.tiboFeed,
      localResetEstimate: CodexRadarResetScorer.estimate(from: page, now: now()),
      stationInsights: nil,
      efficiency: nil
    )
  }

  private func makeTiboPresence(
    from page: CodexRadarPublicPageSnapshot
  ) -> CodexRadarTiboPresence {
    let latest = page.tiboFeed.posts.first
    return CodexRadarTiboPresence(
      handle: "@thsottiaux",
      timezone: "America/Los_Angeles",
      locationLabelZh: "旧金山湾区 / PT",
      locationLabelEn: "San Francisco Bay Area / PT",
      probability: nil,
      confidence: "public-timezone",
      evidenceSummaryZh: "显示公开页面收录的 Posts 与 Replies；未读取 X 登录态、Cookie 或关注列表。",
      evidenceSummaryEn: nil,
      sourceURLs: page.tiboFeed.posts.compactMap { $0.url?.absoluteString },
      shouldDisplay: true,
      safetyNoteZh: "仅展示与重置判断有关的公开动态。",
      updatedAt: page.tiboFeed.updatedAt,
      observedAt: latest?.publishedAt,
      staleAt: nil,
      latestActivityZh: latest?.translationZh ?? latest?.originalText,
      latestActivityEn: latest?.originalText,
      latestActivityAt: latest?.publishedAt
    )
  }

  private func preserveLastGoodOptionalData(
    from cached: CodexRadarSnapshot,
    in incoming: inout CodexRadarSnapshot
  ) {
    // Merge every source on its own clock. A newer, unrelated efficiency payload
    // must never make us reject (or accept) a Tibo/window/probability component.
    incoming.monitoredAt = maxDate(cached.monitoredAt, incoming.monitoredAt)

    if shouldKeepCached(cached.prediction?.updatedAt, over: incoming.prediction?.updatedAt) {
      incoming.prediction = cached.prediction
    }
    if shouldKeepCached(windowEventDate(cached.window), over: windowEventDate(incoming.window)) {
      incoming.window = cached.window
      incoming.windowOpen = cached.windowOpen
      incoming.status = cached.status
      incoming.recommendedAction = cached.recommendedAction
    }
    if shouldKeepCached(cached.publicJudgement?.updatedAt, over: incoming.publicJudgement?.updatedAt) {
      incoming.publicJudgement = cached.publicJudgement
    }
    if shouldKeepCached(cached.tiboFeed?.updatedAt, over: incoming.tiboFeed?.updatedAt) {
      incoming.tiboFeed = cached.tiboFeed
    }
    if shouldKeepCached(
      cached.localResetEstimate?.evaluatedAt ?? cached.localResetEstimate?.updatedAt,
      over: incoming.localResetEstimate?.evaluatedAt ?? incoming.localResetEstimate?.updatedAt
    ) {
      incoming.localResetEstimate = cached.localResetEstimate
    }
    if shouldKeepCached(
      cached.stationInsights?.sourceUpdatedAt,
      over: incoming.stationInsights?.sourceUpdatedAt
    ) {
      incoming.stationInsights = cached.stationInsights
    }
    if shouldKeepCached(
      cached.efficiency?.sourceUpdatedAt,
      over: incoming.efficiency?.sourceUpdatedAt
    ) {
      incoming.efficiency = cached.efficiency
    }
    let cachedPresenceDate = maxDate(
      cached.tiboPresence?.updatedAt,
      cached.tiboPresence?.latestActivityAt
    )
    let incomingPresenceDate = maxDate(
      incoming.tiboPresence?.updatedAt,
      incoming.tiboPresence?.latestActivityAt
    )
    if shouldKeepCached(cachedPresenceDate, over: incomingPresenceDate) {
      incoming.tiboPresence = cached.tiboPresence
    }

    if incoming.links == nil { incoming.links = cached.links }
  }

  private func shouldKeepCached(_ cachedDate: Date?, over incomingDate: Date?) -> Bool {
    guard let cachedDate else { return false }
    guard let incomingDate else { return true }
    return cachedDate > incomingDate
  }

  private func windowEventDate(_ window: CodexRadarWindow?) -> Date? {
    maxDate(window?.openedAt, window?.closedAt)
  }

  private static func fetch(
    url: URL,
    accept: String,
    cacheBust: Bool = false
  ) async throws -> Data {
    let requestURL: URL
    if cacheBust, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      var items = components.queryItems ?? []
      items.append(URLQueryItem(name: "pulse_check", value: UUID().uuidString))
      components.queryItems = items
      requestURL = components.url ?? url
    } else {
      requestURL = url
    }
    var request = URLRequest(
      url: requestURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 12
    )
    request.httpMethod = "GET"
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.setValue("CodexSuanliMeter/2.10.10 (public-read-only-radar-sync)", forHTTPHeaderField: "User-Agent")
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
