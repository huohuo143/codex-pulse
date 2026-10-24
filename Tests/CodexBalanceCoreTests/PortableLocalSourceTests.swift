import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Portable local account and optional Tibo sources")
struct PortableLocalSourceTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func model(_ name: String = "account-model", isDefault: Bool = true) -> LocalCodexModel {
    .init(id: name, model: name, displayName: name, isDefault: isDefault,
      supportedReasoningEfforts: [.init(reasoningEffort: "medium"), .init(reasoningEffort: "high")],
      defaultReasoningEffort: "medium")
  }
  private func historyURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("portable-\(UUID().uuidString).json")
  }
  private func post(_ id: String = "123", text: String = "We will do a reset tomorrow.") -> XTiboTimeline.Post {
    .init(url: "https://x.com/thsottiaux/status/\(id)", date: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)), text: text)
  }
  private func page(_ posts: [XTiboTimeline.Post], url: String = XTiboTimeline.profileURL.absoluteString,
                    login: Bool = false) throws -> Data {
    try JSONEncoder().encode(XTiboTimeline.Page(pageURL: url, requiresLogin: login, posts: posts))
  }

  @Test func freshInstallDoesNotEnableModelOrXAndLegacyChoiceMigratesOnce() throws {
    let suite = "test.portable.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let url = historyURL()
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
    TiboAnalysisPreferences.migrate(defaults: defaults, historyURL: url)
    #expect(TiboAnalysisPreferences.load(defaults: defaults) == TiboAnalysisPreferences())
    var history = CodexRadarTiboHistory(resetAt: nil, posts: [])
    history.analysis = .init(state: .uncertain, kind: .uncertain, summaryZh: "previous", timingZh: "", evidenceIDs: [],
      analyzedAt: now, model: "gpt-6-astra", reasoningEffort: "high")
    CodexRadarTiboHistoryStore.save(history, to: url)
    TiboAnalysisPreferences.migrate(defaults: defaults, historyURL: url)
    #expect(TiboAnalysisPreferences.load(defaults: defaults) == .init(enabled: true, model: "gpt-6-astra", effort: "high"))
    TiboAnalysisPreferences(enabled: false, usesX: true).save(defaults: defaults)
    TiboAnalysisPreferences.migrate(defaults: defaults, historyURL: url)
    #expect(TiboAnalysisPreferences.load(defaults: defaults) == .init(enabled: false, usesX: true))
  }

  @Test func currentAccountSelectsItsOwnModelAndRejectsUnavailablePreviousChoice() throws {
    let capability = LocalCodexCapabilities(installed: true, accountType: "chatgpt", models: [model()])
    let selected = try TiboAnalysisPreferences(enabled: true).selection(from: capability)
    #expect(selected.model == "account-model")
    #expect(selected.effort == "medium")
    #expect(throws: LocalCodexAnalysisError.self) {
      try TiboAnalysisPreferences(enabled: true, model: "gpt-6-astra", effort: "high").selection(from: capability)
    }
    #expect(throws: LocalCodexAnalysisError.self) {
      try TiboAnalysisPreferences(enabled: true, effort: "ultra").selection(from: capability)
    }
    #expect(throws: LocalCodexAnalysisError.self) {
      try TiboAnalysisPreferences(enabled: true).selection(from: .init(installed: true))
    }
    #expect(throws: LocalCodexAnalysisError.self) {
      try TiboAnalysisPreferences(enabled: true).selection(from: .init(installed: false))
    }
    #expect(throws: LocalCodexAnalysisError.self) { try TiboAnalysisPreferences().selection(from: capability) }
  }

  @Test func accountMetadataDecodesWithoutPersonalFieldsAndFiltersHiddenModels() throws {
    let data = Data(#"{"id":"model-a","model":"model-a","displayName":"Model A","isDefault":true,"hidden":true,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"defaultReasoningEffort":"high","unrelated":"ignored"}"#.utf8)
    let decoded = try JSONDecoder().decode(LocalCodexModel.self, from: data)
    #expect(!decoded.availableForAnalysis)
    #expect(!LocalCodexCapabilities(installed: true).signedIn)
    #expect(LocalCodexCapabilities(installed: true, accountType: "apiKey").loginLabel.contains("API 计费"))
  }

  @Test func analysisCommandDisablesOnlySupportedToolsAndRequiresIsolation() throws {
    let help = "--ignore-user-config --ephemeral --output-schema --output-last-message"
    let args = try CodexAnalysisCommand.arguments(help: help,
      featureList: "shell_tool stable true\nunified_exec stable true\napps experimental true\nplugins stable true\nnew_unknown stable true",
      directory: "/tmp/isolated", model: "other-account-model", effort: "high")
    #expect(args.contains("--ignore-user-config")); #expect(args.contains("--ephemeral"))
    #expect(args.contains("read-only")); #expect(args.contains("web_search=\"disabled\""))
    #expect(args.contains("other-account-model")); #expect(!args.contains("gpt-6-astra"))
    #expect(args.contains("shell_tool")); #expect(args.contains("plugins"))
    #expect(!args.contains("new_unknown")); #expect(!args.contains("browser_use"))
    #expect(throws: LocalCodexAnalysisError.self) {
      try CodexAnalysisCommand.arguments(help: "--ephemeral", featureList: "", directory: "/tmp", model: "model", effort: "high")
    }
    #expect(throws: LocalCodexAnalysisError.self) {
      try CodexAnalysisCommand.arguments(help: help, featureList: "shell_tool\nunified_exec", directory: "/tmp", model: "model\" injected", effort: "high")
    }
  }

  @Test func xPostsAndRepliesRoundTripWithoutChangingSourceTimeOrExecutingText() throws {
    let posts = [post(text: "Reset <script>alert('x')</script> & reply \"yes\""), post("124", text: "Reply: tomorrow, by 7pm PT.")]
    let data = try XTiboTimeline.feedHTML(posts: posts, checkedAt: now)
    #expect(!String(decoding: data, as: UTF8.self).contains("<script>"))
    let decoded = try CodexRadarPublicPageParser.decode(data, now: now)
    #expect(Set(decoded.tiboFeed.posts.map(\.id)) == ["123", "124"])
    #expect(decoded.tiboFeed.posts.first(where: { $0.id == "123" })?.originalText == posts[0].text)
    #expect(decoded.tiboFeed.posts.first?.publishedAt == now.addingTimeInterval(-60))
    #expect(decoded.tiboFeed.updatedAt == now)
  }

  @Test func xRejectsOtherAuthorsDuplicateLinksStaleFutureAndCredentialURLs() throws {
    let good = post()
    var other = post("125"); other.url = "https://x.com/other/status/125"
    var stale = post("126"); stale.date = ISO8601DateFormatter().string(from: now.addingTimeInterval(-8 * 86400))
    var future = post("127"); future.date = ISO8601DateFormatter().string(from: now.addingTimeInterval(5))
    var credentials = post("128"); credentials.url = "https://secret@x.com/thsottiaux/status/128"
    var port = post("129"); port.url = "https://x.com:444/thsottiaux/status/129"
    let accepted = try XTiboTimeline.posts(from: page([good, good, other, stale, future, credentials, port]), at: now)
    #expect(accepted == [good])
    #expect(throws: XTiboTimeline.ReadError.self) { try XTiboTimeline.posts(from: page([other, stale]), at: now) }
  }

  @Test func loginWallsAndWrongPagesCannotBecomeNoAnnouncement() throws {
    #expect(throws: XTiboTimeline.ReadError.self) { try XTiboTimeline.posts(from: page([], login: true), at: now) }
    #expect(throws: XTiboTimeline.ReadError.self) { try XTiboTimeline.posts(from: page([post()], url: "https://x.com/home"), at: now) }
    #expect(throws: XTiboTimeline.ReadError.self) { try XTiboTimeline.posts(from: page([]), at: now) }
    #expect(!XTiboTimeline.isProfileURL(URL(string: "https://x.com.evil.test/thsottiaux/with_replies")))
    #expect(!XTiboTimeline.isProfileURL(URL(string: "https://secret@x.com/thsottiaux/with_replies")))
  }

  @Test func modelDisabledStillRefreshesFeedWithoutAnalysisOrThreadCalls() async throws {
    let data = try XTiboTimeline.feedHTML(posts: [post()], checkedAt: now)
    let clock = now
    let service = CodexRadarService(fetcher: { throw CodexRadarError.server(503) }, publicPageFetcher: { data },
      now: { clock }, analyzer: { _, _ in Issue.record("Disabled analysis was called"); throw CodexRadarError.invalidPayload },
      threadFetcher: { _ in Issue.record("Disabled thread enrichment was called"); return "" },
      analysisPreferences: { .init(enabled: false) })
    let snapshot = try await service.current(force: true)
    #expect(snapshot.tiboFeed?.posts.count == 1)
    #expect(snapshot.tiboStatusTitle(at: now) == "动态已更新")
    #expect(snapshot.tiboDisplayRefreshIsHealthy(at: now))
    #expect(!snapshot.tiboHasAnnouncement(at: now))
    #expect(snapshot.tiboStatusSummary(at: now).contains("未分析不代表没有预告"))
    #expect(snapshot.tiboAnalysis == nil)
    #expect(!snapshot.tiboDisplayRefreshIsHealthy(at: now.addingTimeInterval(661)))
    var completed = snapshot; completed.quotaResetConfirmedAt = now
    #expect(completed.tiboStatusTitle(at: now) == "重置已落地")
    #expect(completed.tiboCompletionUntil(at: now) == now.addingTimeInterval(86400))
  }

  @Test func switchingSourceClearsPreviousSuccessAndPreservesTenMinuteBudget() async throws {
    let url = historyURL()
    defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("calendar.json")) }
    let data = try XTiboTimeline.feedHTML(posts: [post()], checkedAt: now)
    let clock = now
    let first = CodexRadarService(fetcher: { throw CodexRadarError.server(503) }, publicPageFetcher: { data },
      now: { clock }, historyURL: url, minimumFetchInterval: 600)
    _ = try await first.current(force: true)
    let second = CodexRadarService(fetcher: { Issue.record("Budget bypassed"); throw CodexRadarError.server(503) },
      publicPageFetcher: { Issue.record("Source switch bypassed budget"); return data }, now: { clock.addingTimeInterval(30) },
      historyURL: url, minimumFetchInterval: 600, sourceIdentifier: { "x" })
    let waiting = try await second.current(force: true)
    #expect(waiting.syncState?.lastSuccessAt == nil)
    #expect(waiting.syncState?.lastAttemptAt == clock)
    #expect(waiting.tiboFeed?.posts.isEmpty != false)
    #expect(!waiting.tiboDisplayRefreshIsHealthy(at: clock.addingTimeInterval(30)))
    let history = try #require(CodexRadarTiboHistoryStore.load(from: url))
    #expect(history.sourceID == "x"); #expect(history.lastSuccessAt == nil)
  }

  @Test func sourceChangedDuringRequestCannotPublishPreviousSourcesResult() async throws {
    let selected = SourceSelection()
    let data = try XTiboTimeline.feedHTML(posts: [post()], checkedAt: now)
    let clock = now
    let service = CodexRadarService(fetcher: { throw CodexRadarError.server(503) },
      publicPageFetcher: { selected.set("x"); return data }, now: { clock },
      minimumFetchInterval: 600, sourceIdentifier: { selected.get() })
    let value = try await service.current(force: true)
    #expect(value.syncState?.lastSuccessAt == nil)
    #expect(value.tiboFeed?.posts.isEmpty != false)
    #expect(value.tiboStatusTitle(at: now) == "等待动态")
  }
}

private final class SourceSelection: @unchecked Sendable {
  private let lock = NSLock()
  private var value = "public"
  func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ value: String) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
