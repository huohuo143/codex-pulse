import CodexBalanceCore
import Foundation
import Testing
@testable import CodexBalance

@Suite("Account-scoped late notification receipts", .serialized)
struct QuotaLateReceiptTests {
  @MainActor @Test func lateSuccessIsSavedToSubmittingAccountAndRestoredOnReturn() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    store.quotaAlertLedger.sentKeys = ["credit.account-b-only"]

    service.accept(0)
    await oldTask.value

    #expect(store.quotaAlertLedger.sentKeys == ["credit.account-b-only"])
    #expect(fixture.store.load(account: "account-a").sentKeys.count == 2)
    #expect(store.quotaAlertDeliveryTask == nil)
    #expect(!store.quotaAlertDeliveryState.isDelivering)
    selectAccount("account-a", on: store)
    store.evaluateQuotaAlerts()
    #expect(store.quotaAlertDeliveryTask == nil)
    #expect(service.deliveries.count == 1)

    let restarted = makeStore(service: SuspendedReceiptService(), fixture: fixture)
    #expect(restarted.quotaAlertLedger.sentKeys == store.quotaAlertLedger.sentKeys)
  }

  @MainActor @Test func returningBeforeLateSuccessMergesWithNewerReceipts() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    selectAccount("account-a", on: store)
    store.quotaAlertLedger.sentKeys = ["credit.accepted-by-newer-batch"]
    store.quotaAlertLedger.lastRisk = .healthy

    service.accept(0)
    await oldTask.value

    #expect(store.quotaAlertLedger.sentKeys.count == 3)
    #expect(store.quotaAlertLedger.sentKeys.contains("credit.accepted-by-newer-batch"))
    #expect(store.quotaAlertLedger.lastRisk == .healthy)
    #expect(fixture.store.load(account: "account-a") == store.quotaAlertLedger)
  }

  @MainActor @Test func oldBatchCompletionCannotReleaseNewActiveBatch() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    selectAccount("account-a", on: store)
    store.evaluateQuotaAlerts()
    let newTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(2)

    service.accept(0)
    await oldTask.value
    #expect(store.quotaAlertDeliveryState.isDelivering)
    #expect(store.quotaAlertDeliveryTask != nil)
    #expect(store.quotaAlertLedger.sentKeys.count == 2)
    service.accept(1)
    await newTask.value
    #expect(!store.quotaAlertDeliveryState.isDelivering)
    #expect(store.quotaAlertDeliveryTask == nil)
  }

  @MainActor @Test func lateFailureDoesNotCommitReceiptOrCooldownToEitherAccount() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    service.reject(0)
    await oldTask.value
    #expect(store.quotaAlertLedger.sentKeys.isEmpty)
    #expect(fixture.store.load(account: "account-a").sentKeys.isEmpty)
    #expect(store.quotaAlertDeliveryState.retryAfter == nil)
  }

  @MainActor @Test func invalidatedBatchRecordsAcceptedItemWithoutSubmittingRemainingItems() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.quotaForecastAlertsEnabled = true
    store.quotaForecast = QuotaForecast(generatedAt: Date(), resetsAt: store.weekly?.resetsAt, risk: .critical)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    service.accept(0)
    await oldTask.value
    #expect(service.deliveries.map(\.kind) == [.threshold(15)])
    let original = fixture.store.load(account: "account-a")
    #expect(original.sentKeys.count == 2)
    #expect(original.lastForecastCriticalAt == nil)
  }

  @MainActor @Test func lateForecastCannotOverwriteNewerCycleOrObservedHealthyRisk() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.quotaThresholdAlertsEnabled = false
    store.quotaForecastAlertsEnabled = true
    store.quotaForecast = QuotaForecast(generatedAt: Date(), resetsAt: store.weekly?.resetsAt, risk: .critical)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    selectAccount("account-a", on: store)
    let newerReceipt = Date().addingTimeInterval(-1)
    store.quotaAlertLedger = QuotaAlertLedger(sentKeys: ["credit.newer"],
      lastForecastCriticalAt: newerReceipt, lastForecastCycle: "newer-cycle", lastRisk: .healthy)
    service.accept(0)
    await oldTask.value
    #expect(store.quotaAlertLedger.lastForecastCriticalAt == newerReceipt)
    #expect(store.quotaAlertLedger.lastForecastCycle == "newer-cycle")
    #expect(store.quotaAlertLedger.lastRisk == .healthy)
    #expect(store.quotaAlertLedger.sentKeys == ["credit.newer"])
  }

  @MainActor @Test func lateForecastRecordsCooldownWithoutReplacingCurrentHealthyForecast() async throws {
    let fixture = LateReceiptFixture()
    defer { fixture.clean() }
    let service = SuspendedReceiptService()
    let store = makeStore(service: service, fixture: fixture)
    store.quotaThresholdAlertsEnabled = false
    store.quotaForecastAlertsEnabled = true
    store.quotaForecast = QuotaForecast(generatedAt: Date(), resetsAt: store.weekly?.resetsAt, risk: .critical)
    store.evaluateQuotaAlerts()
    let oldTask = try #require(store.quotaAlertDeliveryTask)
    await service.waitForDeliveries(1)
    selectAccount("account-b", on: store)
    selectAccount("account-a", on: store)
    store.quotaForecast = QuotaForecast(generatedAt: Date(), resetsAt: store.weekly?.resetsAt, risk: .healthy)
    service.accept(0)
    await oldTask.value
    #expect(store.quotaAlertLedger.lastForecastCriticalAt != nil)
    #expect(store.quotaAlertLedger.lastRisk == .healthy)
  }

  @MainActor private func makeStore(service: SuspendedReceiptService, fixture: LateReceiptFixture) -> DashboardStore {
    let now = Date()
    let store = DashboardStore(startServices: false, alertLedgerStore: fixture.store)
    store.quotaNotificationService = service
    store.quotaAlertsEnabled = true
    store.notificationAuthorization = .authorized
    store.quotaAlertPreset = .standard
    store.quotaThresholdAlertsEnabled = true
    store.quotaForecastAlertsEnabled = false
    store.quotaResetCreditAlertsEnabled = false
    let event = RateLimitEvent(timestamp: now, sourceName: "fixture", sourcePath: "", limitID: "quota",
      limitName: "quota", primary: .init(usedPercent: 86, remainingPercent: 14,
        windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)))
    var status = CodexStatus(generatedAt: now, codexHome: "", sessionsRoot: "", main: event)
    status.accountScope = "account-a"
    status.quotaRead = .init(sampledAt: now, lastSuccessAt: now)
    store.prepareAccount("account-a")
    store.status = status
    return store
  }

  @MainActor private func selectAccount(_ account: String, on store: DashboardStore) {
    store.prepareAccount(account)
    store.status?.accountScope = account
  }
}

@MainActor
private final class SuspendedReceiptService: QuotaNotificationServing {
  enum Failure: Error { case rejected }
  var deliveries: [QuotaAlertCandidate] = []
  private var suspended: [Int: CheckedContinuation<Void, Error>] = [:]
  private var deliveryWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

  func authorizationStatus() async -> QuotaNotificationAuthorization { .authorized }
  func requestAuthorization() async -> QuotaNotificationAuthorization { .authorized }
  func openSystemNotificationSettings() {}

  func deliver(_ candidate: QuotaAlertCandidate, remainingPercent: Double?, forecast: QuotaForecast?) async throws {
    let index = deliveries.count
    deliveries.append(candidate)
    if let waiter = deliveryWaiter, deliveries.count >= waiter.count {
      deliveryWaiter = nil
      waiter.continuation.resume()
    }
    try await withCheckedThrowingContinuation { suspended[index] = $0 }
  }

  func waitForDeliveries(_ count: Int) async {
    if deliveries.count < count {
      await withCheckedContinuation { deliveryWaiter = (count, $0) }
    }
  }

  func accept(_ index: Int) { suspended.removeValue(forKey: index)?.resume() }
  func reject(_ index: Int) { suspended.removeValue(forKey: index)?.resume(throwing: Failure.rejected) }
}

private struct LateReceiptFixture {
  let suite = "dev.codex.pulse.late-receipt-tests.\(UUID().uuidString)"
  var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
  var store: QuotaAlertLedgerStore { QuotaAlertLedgerStore(defaults: defaults) }
  func clean() { defaults.removePersistentDomain(forName: suite) }
}
