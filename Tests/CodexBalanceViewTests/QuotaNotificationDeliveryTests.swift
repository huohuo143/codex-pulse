import CodexBalanceCore
import Foundation
import Testing
@testable import CodexBalance

@Suite("Dashboard notification delivery", .serialized)
struct QuotaNotificationDeliveryTests {
  @MainActor @Test func failedSystemRequestKeepsThresholdEligibleUntilAccepted() async throws {
    let now = Date()
    let service = TestQuotaNotificationService()
    service.shouldFail = true
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let store = makeStore(service: service, now: now, ledgerStore: ledger.store)
    store.evaluateQuotaAlerts(now: now)
    let first = try #require(store.quotaAlertDeliveryTask)
    await first.value
    #expect(service.deliveries.count == 1)
    #expect(store.quotaAlertLedger.sentKeys.isEmpty)
    let retryAt = try #require(store.quotaAlertDeliveryState.retryAfter)
    store.evaluateQuotaAlerts(now: retryAt.addingTimeInterval(-1))
    #expect(store.quotaAlertDeliveryTask == nil)
    service.shouldFail = false
    store.evaluateQuotaAlerts(now: retryAt)
    let retry = try #require(store.quotaAlertDeliveryTask)
    await retry.value
    #expect(service.deliveries.count == 2)
    #expect(store.quotaAlertLedger.sentKeys.count == 2)
    store.evaluateQuotaAlerts(now: retryAt.addingTimeInterval(60))
    #expect(store.quotaAlertDeliveryTask == nil)
  }

  @MainActor @Test func repeatedRefreshDoesNotSubmitAnOverlappingRequest() async throws {
    let now = Date()
    let service = TestQuotaNotificationService()
    service.suspendDelivery = true
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let store = makeStore(service: service, now: now, ledgerStore: ledger.store)
    store.evaluateQuotaAlerts(now: now)
    let pending = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDelivery()
    #expect(store.quotaAlertLedger.sentKeys.isEmpty)
    store.evaluateQuotaAlerts(now: now.addingTimeInterval(10))
    #expect(service.deliveries.count == 1)
    service.resumeDelivery()
    await pending.value
    #expect(store.quotaAlertLedger.sentKeys.count == 2)
  }

  @MainActor @Test func failedCriticalReentryRetriesWithinPriorSixHourCooldownThenDeduplicates() async throws {
    let now = Date()
    let service = TestQuotaNotificationService()
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let store = makeStore(service: service, now: now, ledgerStore: ledger.store)
    store.quotaThresholdAlertsEnabled = false
    store.quotaForecastAlertsEnabled = true
    let reset = try #require(store.weekly?.resetsAt)
    let cycle = String(Int64(reset.timeIntervalSince1970 / 60))
    let priorDelivery = now.addingTimeInterval(-3600)
    store.quotaAlertLedger = QuotaAlertLedger(lastForecastCriticalAt: priorDelivery,
      lastForecastCycle: cycle, lastRisk: .critical)

    store.quotaForecast = QuotaForecast(generatedAt: now, resetsAt: reset, risk: .healthy)
    store.evaluateQuotaAlerts(now: now)
    #expect(store.quotaAlertLedger.lastRisk == .healthy)
    #expect(store.quotaAlertDeliveryTask == nil)

    service.shouldFail = true
    store.quotaForecast = QuotaForecast(generatedAt: now, resetsAt: reset, risk: .critical)
    store.evaluateQuotaAlerts(now: now)
    let failed = try #require(store.quotaAlertDeliveryTask)
    await failed.value
    #expect(service.deliveries.map(\.kind) == [.forecastCritical])
    #expect(store.quotaAlertLedger.lastRisk == .healthy)
    #expect(store.quotaAlertLedger.lastForecastCriticalAt == priorDelivery)

    let retryAt = try #require(store.quotaAlertDeliveryState.retryAfter)
    store.evaluateQuotaAlerts(now: retryAt.addingTimeInterval(-1))
    #expect(store.quotaAlertDeliveryTask == nil)
    #expect(store.quotaAlertLedger.lastRisk == .healthy)
    service.shouldFail = false
    store.evaluateQuotaAlerts(now: retryAt)
    let retry = try #require(store.quotaAlertDeliveryTask)
    await retry.value
    #expect(service.deliveries.map(\.kind) == [.forecastCritical, .forecastCritical])
    #expect(store.quotaAlertLedger.lastRisk == .critical)
    #expect(store.quotaAlertLedger.lastForecastCriticalAt != priorDelivery)

    store.evaluateQuotaAlerts(now: retryAt.addingTimeInterval(60))
    #expect(store.quotaAlertDeliveryTask == nil)
    #expect(service.deliveries.count == 2)
  }

  @MainActor @Test func lateOldAccountSuccessCannotPolluteNewAccountLedger() async throws {
    let now = Date()
    let service = TestQuotaNotificationService()
    service.suspendDelivery = true
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let store = makeStore(service: service, now: now, ledgerStore: ledger.store)
    store.quotaHistory = [.init(recordedAt: now, remainingPercent: 14,
      resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080)]
    store.quotaForecast = QuotaForecast(generatedAt: now)
    store.lastForecastAt = now
    store.evaluateQuotaAlerts(now: now)
    let old = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDelivery()
    store.prepareAccount("new-account")
    store.status?.accountScope = "new-account"
    #expect(store.quotaHistory.isEmpty)
    #expect(store.quotaForecast == nil)
    #expect(store.lastForecastAt == nil)
    service.resumeDelivery()
    await old.value
    #expect(store.quotaAlertLedger.sentKeys.isEmpty)
    #expect(store.quotaAlertDeliveryState.retryAfter == nil)
    #expect(!store.quotaAlertDeliveryState.isDelivering)
  }

  @MainActor @Test func disabledAlertsNeverSubmitOrRequestAuthorization() {
    let service = TestQuotaNotificationService()
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let store = makeStore(service: service, now: Date(), ledgerStore: ledger.store)
    store.quotaAlertsEnabled = false
    store.evaluateQuotaAlerts()
    #expect(store.quotaAlertDeliveryTask == nil)
    #expect(service.deliveries.isEmpty)
    #expect(service.authorizationRequests == 0)
  }

  @MainActor @Test func acceptedThresholdSurvivesRestartAndAccountRoundTrip() async throws {
    let now = Date()
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let firstService = TestQuotaNotificationService()
    let first = makeStore(service: firstService, now: now, ledgerStore: ledger.store, account: "account-a")
    first.evaluateQuotaAlerts(now: now)
    await (try #require(first.quotaAlertDeliveryTask)).value
    #expect(firstService.deliveries.count == 1)

    let restartedService = TestQuotaNotificationService()
    let restarted = makeStore(service: restartedService, now: now, ledgerStore: ledger.store, account: "account-a")
    restarted.evaluateQuotaAlerts(now: now)
    #expect(restartedService.deliveries.isEmpty)
    #expect(restarted.quotaAlertLedger.sentKeys == first.quotaAlertLedger.sentKeys)

    restarted.prepareAccount("account-b")
    restarted.status?.accountScope = "account-b"
    restarted.evaluateQuotaAlerts(now: now)
    await (try #require(restarted.quotaAlertDeliveryTask)).value
    #expect(restartedService.deliveries.count == 1)
    restarted.prepareAccount("account-a")
    restarted.status?.accountScope = "account-a"
    restarted.evaluateQuotaAlerts(now: now)
    #expect(restarted.quotaAlertDeliveryTask == nil)
    #expect(restartedService.deliveries.count == 1)
  }

  @MainActor @Test func unscopedLegacyReceiptsArePreservedWithoutBindingToNewAccount() async throws {
    let now = Date()
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let cycle = String(Int64(now.addingTimeInterval(86400).timeIntervalSince1970 / 60))
    let old = QuotaAlertLedger(sentKeys: ["threshold.\(cycle).30", "threshold.\(cycle).15"])
    let legacyData = try JSONEncoder().encode(old)
    ledger.defaults.set(legacyData, forKey: "quotaAlertLedger")
    let service = TestQuotaNotificationService()
    let store = makeStore(service: service, now: now, ledgerStore: ledger.store, account: "new-account")
    #expect(store.quotaAlertLedger.sentKeys.isEmpty)
    store.evaluateQuotaAlerts(now: now)
    await (try #require(store.quotaAlertDeliveryTask)).value
    #expect(service.deliveries.count == 1)
    #expect(ledger.defaults.data(forKey: "quotaAlertLedger") == legacyData)
  }

  @MainActor @Test func unconfirmedAccountDoesNotDeliverOrAdoptReceipts() {
    let ledger = TestQuotaLedgerDefaults()
    defer { ledger.clean() }
    let service = TestQuotaNotificationService()
    let store = makeStore(service: service, now: Date(), ledgerStore: ledger.store, account: nil)
    store.evaluateQuotaAlerts()
    #expect(store.quotaAlertDeliveryTask == nil)
    #expect(service.deliveries.isEmpty)
    #expect(store.quotaAlertLedger.sentKeys.isEmpty)
  }

  @MainActor private func makeStore(service: TestQuotaNotificationService, now: Date,
                                    ledgerStore: QuotaAlertLedgerStore, account: String? = "test-account") -> DashboardStore {
    let store = DashboardStore(startServices: false, alertLedgerStore: ledgerStore)
    store.quotaNotificationService = service
    store.quotaAlertsEnabled = true
    store.notificationAuthorization = .authorized
    store.quotaAlertPreset = .standard
    store.quotaThresholdAlertsEnabled = true
    store.quotaForecastAlertsEnabled = false
    store.quotaResetCreditAlertsEnabled = false
    let event = RateLimitEvent(timestamp: now, sourceName: "test", sourcePath: "", limitID: "quota",
      limitName: "quota", primary: .init(usedPercent: 86, remainingPercent: 14,
        windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)))
    var status = CodexStatus(generatedAt: now, codexHome: "", sessionsRoot: "", main: event)
    status.accountScope = account
    status.quotaRead = .init(sampledAt: now, lastSuccessAt: now)
    store.prepareAccount(account)
    store.status = status
    return store
  }
}

@MainActor
private final class TestQuotaNotificationService: QuotaNotificationServing {
  enum Failure: Error { case rejected }
  var shouldFail = false
  var suspendDelivery = false
  var deliveries: [QuotaAlertCandidate] = []
  var authorizationRequests = 0
  private var deliveryWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?

  func authorizationStatus() async -> QuotaNotificationAuthorization { .authorized }
  func requestAuthorization() async -> QuotaNotificationAuthorization {
    authorizationRequests += 1
    return .authorized
  }
  func openSystemNotificationSettings() {}

  func deliver(_ candidate: QuotaAlertCandidate, remainingPercent: Double?, forecast: QuotaForecast?) async throws {
    deliveries.append(candidate)
    deliveryWaiter?.resume()
    deliveryWaiter = nil
    if suspendDelivery { await withCheckedContinuation { resumeWaiter = $0 } }
    if shouldFail { throw Failure.rejected }
  }

  func waitForDelivery() async {
    if deliveries.isEmpty { await withCheckedContinuation { deliveryWaiter = $0 } }
  }

  func resumeDelivery() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }
}

private struct TestQuotaLedgerDefaults {
  let suiteName: String
  let defaults: UserDefaults

  init() {
    suiteName = "dev.codex.pulse.notification-tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  var store: QuotaAlertLedgerStore { QuotaAlertLedgerStore(defaults: defaults) }
  func clean() { defaults.removePersistentDomain(forName: suiteName) }
}
