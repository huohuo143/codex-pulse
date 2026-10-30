import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("OpenAI API usage and confirmed grants")
struct OpenAIAPIUsageTests {
  private let now = Date(timeIntervalSince1970: 1_792_109_600) // 2026-10, UTC
  private let url = URL(string: "https://api.openai.com/v1/organization/costs")!

  private func response(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  @Test func followsPagesAndKeepsCalendarMonthSeparateFromGrant() async throws {
    let start = OpenAIAPIUsageReader.monthStart(at: now)
    let startSeconds = Int(start.timeIntervalSince1970)
    let reader = OpenAIAPIUsageReader { request in
      let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      let cursor = items.first(where: { $0.name == "page" })?.value
      #expect(request.url?.host == "api.openai.com")
      #expect(items.first(where: { $0.name == "start_time" })?.value == String(startSeconds))
      let raw = cursor == nil
        ? """
        {"data":[{"start_time":\(startSeconds),"results":[{"amount":{"value":1.25,"currency":"usd"}}]}],"has_more":true,"next_page":"next"}
        """
        : """
        {"data":[{"start_time":\(startSeconds + 86400),"results":[{"amount":{"value":2.50,"currency":"usd"}}]}],"has_more":false,"next_page":null}
        """
      return (Data(raw.utf8), response())
    }
    let reading = try await reader.fetch(adminKey: "fixture-only", at: now)
    #expect(reading.costUSD == 3.75)
    #expect(reading.periodStart == start)
    #expect(reading.isCurrentPeriod(at: now))
    #expect(!reading.isCurrentPeriod(at: now.addingTimeInterval(40 * 86400)))
  }

  @Test func rejectsMalformedAmountsAndOutOfPeriodBuckets() throws {
    let start = OpenAIAPIUsageReader.monthStart(at: now)
    let finish = start.addingTimeInterval(31 * 86400)
    for raw in [
      "{\"data\":[{\"start_time\":\(Int(start.timeIntervalSince1970)),\"results\":[{\"amount\":{\"value\":1,\"currency\":\"eur\"}}]}],\"has_more\":false}",
      "{\"data\":[{\"start_time\":\(Int(start.timeIntervalSince1970)),\"results\":[{}]}],\"has_more\":false}",
      "{\"data\":[{\"start_time\":\(Int(start.timeIntervalSince1970) - 86400),\"results\":[]}],\"has_more\":false}"
    ] {
      let page = try JSONDecoder().decode(OpenAIAPICostPage.self, from: Data(raw.utf8))
      #expect(throws: OpenAIAPIUsageError.invalidResponse) {
        try page.validatedTotal(from: start, before: finish)
      }
    }
  }

  @Test func authorizationAndRateLimitFailuresAreNotDisplayedAsZero() async {
    for (status, expected) in [(401, OpenAIAPIUsageError.unauthorized), (403, .forbidden), (429, .rateLimited(retryAfter: nil))] {
      let reader = OpenAIAPIUsageReader { _ in (Data(), response(status)) }
      await #expect(throws: expected) { try await reader.fetch(adminKey: "fixture-only", at: now) }
    }
  }

  @Test func rateLimitReportsServerRetryDelay() async {
    let reader = OpenAIAPIUsageReader { request in
      (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                              headerFields: ["Retry-After": "1200"])!)
    }
    await #expect(throws: OpenAIAPIUsageError.rateLimited(retryAfter: 1200)) {
      try await reader.fetch(adminKey: "fixture-only", at: now)
    }
  }

  @Test func rejectsMissingPaginationCursor() async {
    let reader = OpenAIAPIUsageReader { _ in
      (Data("{\"data\":[],\"has_more\":true,\"next_page\":null}".utf8), response())
    }
    await #expect(throws: OpenAIAPIUsageError.invalidResponse) { try await reader.fetch(adminKey: "fixture-only", at: now) }
  }

  @Test func grantAmountsAreDynamicAndNeverDerivedFromCosts() {
    #expect(OpenAIAPIGrantConfirmation(totalUSD: 100, remainingUSD: 75, checkedAt: now) != nil)
    #expect(OpenAIAPIGrantConfirmation(totalUSD: 200, remainingUSD: 12, checkedAt: now) != nil)
    #expect(OpenAIAPIGrantConfirmation(totalUSD: 0, remainingUSD: 0, checkedAt: now) == nil)
    #expect(OpenAIAPIGrantConfirmation(totalUSD: 100, remainingUSD: 101, checkedAt: now) == nil)
    #expect(OpenAIAPIGrantConfirmation(totalUSD: 100, remainingUSD: -1, checkedAt: now) == nil)
    #expect(OpenAIAPIAmountFormat.money(0.00003) == "<$0.0001")
    #expect(OpenAIAPIAmountFormat.money(0.0012) == "$0.0012")
    #expect(OpenAIAPIAmountFormat.money(0) == "$0.00")
  }

  @Test func widgetUsesItsOwnMonthAndManualGrantExpiry() {
    let start = OpenAIAPIUsageReader.monthStart(at: now)
    let snapshot = OpenAIAPIWidgetSnapshot(publishedAt: now, isConnected: true, monthlyCostUSD: 2.5,
      periodStart: start, costSampledAt: now, status: "ok", grantTotalUSD: 200, grantRemainingUSD: 175,
      grantCheckedAt: now, grantExpiresAt: now.addingTimeInterval(30))
    #expect(snapshot.cost(at: now) == 2.5)
    #expect(snapshot.grantRemaining(at: now) == 175)
    #expect(snapshot.grantRemaining(at: now.addingTimeInterval(31)) == nil)
    #expect(snapshot.cost(at: now.addingTimeInterval(40 * 86400)) == nil)
  }

  @Test func expiryAndRemindersUseOnlyConfirmedTime() {
    let expiry = OpenAIAPIGrantExpiry(expiresAt: now.addingTimeInterval(4 * 86400), confirmedAt: now)
    #expect(expiry.countdown(at: now) == "4天0小时")
    #expect(expiry.compactCountdown(at: now) == "余4天")
    #expect(expiry.compactCountdown(at: expiry.expiresAt.addingTimeInterval(-90000)) == "余1天1时")
    #expect(expiry.compactCountdown(at: expiry.expiresAt.addingTimeInterval(-60)) == "余1分")
    #expect(expiry.countdown(at: expiry.expiresAt.addingTimeInterval(-1)) == "1分钟")
    #expect(expiry.hasExpired(at: expiry.expiresAt))
    #expect(expiry.countdown(at: expiry.expiresAt) == "已到期")
    let events = OpenAIAPIExpiryReminderPlan.events(expiry: expiry.expiresAt, after: now)
    #expect(events.map(\.identifier) == OpenAIAPIExpiryReminderPlan.identifiers)
    #expect(events[0].fireAt == expiry.expiresAt.addingTimeInterval(-3 * 86400))
    #expect(events[1].fireAt == expiry.expiresAt.addingTimeInterval(-86400))
    #expect(events[2].fireAt == expiry.expiresAt)
    #expect(OpenAIAPIExpiryReminderPlan.events(expiry: expiry.expiresAt, after: expiry.expiresAt).isEmpty)
  }

  @Test func widgetCanShowExpiryWithoutInventingGrantAmount() throws {
    let expires = now.addingTimeInterval(4 * 86400)
    let snapshot = OpenAIAPIWidgetSnapshot(publishedAt: now, isConnected: false, monthlyCostUSD: nil,
      periodStart: nil, costSampledAt: nil, status: "未连接", grantTotalUSD: nil, grantRemainingUSD: nil,
      grantCheckedAt: nil, grantExpiresAt: expires, grantExpiryConfirmedAt: now)
    #expect(snapshot.confirmedExpiry?.expiresAt == expires)
    #expect(snapshot.grantRemaining(at: now) == nil)
    #expect(snapshot.timelineDates(after: now).contains(expires))
    let roundtrip = try JSONDecoder().decode(OpenAIAPIWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(roundtrip == snapshot)
    var legacy = snapshot
    legacy.grantExpiryConfirmedAt = nil
    legacy.grantCheckedAt = now
    #expect(legacy.confirmedExpiry?.expiresAt == expires)
    var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    oldJSON.removeValue(forKey: "grantExpiryConfirmedAt")
    let oldSnapshot = try JSONDecoder().decode(OpenAIAPIWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    #expect(oldSnapshot.confirmedExpiry?.expiresAt == expires)
  }
}
