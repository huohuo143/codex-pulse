import CodexBalanceCore
import Foundation
import Testing
@testable import CodexBalance

@MainActor
private final class FakeUsageCredentials: OpenAIAPICredentialStorage {
  var value: String?
  func save(_ value: String) -> Bool { self.value = value; return true }
  func read() -> String? { value }
  func remove() -> Bool { value = nil; return true }
}

@MainActor
private final class FakeExpiryReminders: APIExpiryReminderScheduling {
  var lastExpiry: OpenAIAPIGrantExpiry?
  var lastEnabled = true
  var lastRequestedPermission = false
  func synchronize(expiry: OpenAIAPIGrantExpiry?, enabled: Bool, requestPermission: Bool) async -> APIExpiryReminderStatus {
    lastExpiry = expiry; lastEnabled = enabled; lastRequestedPermission = requestPermission
    return enabled ? (expiry == nil ? .noDate : .scheduled(3)) : .disabled
  }
}

@Suite("API usage local settings", .serialized)
struct OpenAIAPIUsageStoreTests {
  @Test @MainActor func isolatedDashboardDoesNotStartBackgroundServices() {
    let store = DashboardStore(startServices: false)
    store.startAutoRefresh()
    #expect(store.refreshTimer == nil)
    #expect(store.codexRadarRefreshTimer == nil)
    #expect(store.codexRadarEvaluationTimer == nil)
  }
  @Test @MainActor func remindersFollowDateAndUserPreference() async throws {
    let suite = "APIExpiryReminders.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let reminders = FakeExpiryReminders()
    let store = OpenAIAPIUsageStore(defaults: defaults, credentials: FakeUsageCredentials(),
                                    publishToWidget: false, reminderService: reminders)
    let expiry = Date().addingTimeInterval(5 * 86400)
    #expect(store.confirmExpiry(expiry))
    await store.waitForReminderUpdate()
    #expect(reminders.lastExpiry?.expiresAt == expiry && reminders.lastEnabled && reminders.lastRequestedPermission)
    #expect(store.expiryReminderStatus == .scheduled(3))
    store.setExpiryNotificationsEnabled(false)
    await store.waitForReminderUpdate()
    #expect(!reminders.lastEnabled && store.expiryReminderStatus == .disabled)
    store.clearExpiry()
    await store.waitForReminderUpdate()
    #expect(reminders.lastExpiry == nil)
  }
  @Test @MainActor func expiryIsIndependentAndSurvivesRelaunch() throws {
    let suite = "APIExpiryTest.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = FakeUsageCredentials()
    let store = OpenAIAPIUsageStore(defaults: defaults, credentials: credentials, publishToWidget: false)
    let expiry = Date().addingTimeInterval(5 * 86400)
    #expect(store.grant == nil && store.grantExpiry == nil)
    #expect(store.confirmExpiry(expiry, requestPermission: false))
    #expect(store.grant == nil && store.grantExpiry?.expiresAt == expiry)
    #expect(store.confirmGrant(total: 200, remaining: 175, expiresAt: nil))
    #expect(store.grant?.remainingUSD == 175 && store.grantExpiry?.expiresAt == expiry)
    let restarted = OpenAIAPIUsageStore(defaults: defaults, credentials: credentials, publishToWidget: false)
    #expect(restarted.grantExpiry?.expiresAt == expiry)
    #expect(restarted.grant?.remainingUSD == 175)
    restarted.clearExpiry()
    #expect(restarted.grantExpiry == nil && restarted.grant?.remainingUSD == 175)
    restarted.setExpiryNotificationsEnabled(false)
    let again = OpenAIAPIUsageStore(defaults: defaults, credentials: credentials, publishToWidget: false)
    #expect(!again.expiryNotificationsEnabled)
  }

  @Test @MainActor func previouslyConfirmedGrantExpiryMigrates() throws {
    let suite = "APIExpiryMigration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let old = try #require(OpenAIAPIGrantConfirmation(totalUSD: 100, remainingUSD: 60, checkedAt: now,
                                                      expiresAt: now.addingTimeInterval(86400)))
    defaults.set(try JSONEncoder().encode(old), forKey: "openAIAPIGrantConfirmation")
    let store = OpenAIAPIUsageStore(defaults: defaults, credentials: FakeUsageCredentials(), publishToWidget: false)
    #expect(store.grantExpiry?.expiresAt == old.expiresAt)
    #expect(store.grantExpiry?.confirmedAt == now)
  }

  @Test @MainActor func connectionDoesNotInventGrantAndPreservesManualValues() async throws {
    let suite = "APIUsageTest.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let start = Int(OpenAIAPIUsageReader.monthStart(at: now).timeIntervalSince1970)
    let reader = OpenAIAPIUsageReader { request in
      let json = "{\"data\":[{\"start_time\":\(start),\"results\":[{\"amount\":{\"value\":7.5,\"currency\":\"usd\"}}]}],\"has_more\":false}"
      return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let credentials = FakeUsageCredentials()
    let store = OpenAIAPIUsageStore(defaults: defaults, credentials: credentials, reader: reader, publishToWidget: false)
    #expect(store.grant == nil)
    #expect(store.confirmGrant(total: 200, remaining: 125, expiresAt: nil))
    #expect(await store.connect(adminKey: "fixture-only"))
    #expect(store.currentReading?.costUSD == 7.5)
    #expect(store.grant?.remainingUSD == 125)
    let preferences = try #require(defaults.persistentDomain(forName: suite))
    let saved = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
    #expect(!String(decoding: saved, as: UTF8.self).contains("fixture-only"))
    let restarted = OpenAIAPIUsageStore(defaults: defaults, credentials: credentials, reader: reader, publishToWidget: false)
    #expect(restarted.isConnected)
    #expect(restarted.grant?.totalUSD == 200)
    #expect(restarted.grant?.remainingUSD == 125)
    restarted.disconnect()
    #expect(restarted.currentReading == nil)
    #expect(restarted.grant == nil)
    #expect(credentials.value == nil)
  }
}
