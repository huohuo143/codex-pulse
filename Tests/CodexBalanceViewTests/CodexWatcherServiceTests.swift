import Foundation
import Testing
@testable import CodexBalance

@Suite("Watcher registration recovery")
struct CodexWatcherServiceTests {
  @Test func transientBootstrapFailureRecoversWithoutBootingOutAgain() throws {
    let fake = FakeLaunchctl(prints: [113, 113, 113, 0], bootstraps: [5, 0])
    try fake.service.load()
    #expect(fake.bootstrapCount == 2)
    #expect(fake.bootoutCount == 0)
    #expect(fake.pauses == [0.5])
  }

  @Test func existingRegistrationIsLeftAlone() throws {
    let fake = FakeLaunchctl(prints: [0])
    try fake.service.load()
    #expect(fake.bootstrapCount == 0)
    #expect(fake.bootoutCount == 0)
    #expect(fake.pauses.isEmpty)
  }

  @Test func reportedFailureCanStillHaveRegisteredTheService() throws {
    let fake = FakeLaunchctl(prints: [113, 0], bootstraps: [5])
    try fake.service.load()
    #expect(fake.bootstrapCount == 1)
    #expect(fake.pauses.isEmpty)
  }

  @Test func successStatusWithoutRegistrationDoesNotReportSuccess() {
    let fake = FakeLaunchctl(prints: Array(repeating: 113, count: 6), bootstraps: [0, 0, 0])
    #expect(throws: CodexWatcherService.RegistrationError(action: "开启", status: 113)) {
      try fake.service.load()
    }
    #expect(fake.bootstrapCount == 3)
    #expect(fake.pauses == [0.5, 0.5])
  }

  @Test func persistentFailureStopsAfterThreeAttempts() {
    let fake = FakeLaunchctl(prints: Array(repeating: 113, count: 6), bootstraps: [5, 5, 5])
    #expect(throws: CodexWatcherService.RegistrationError(action: "开启", status: 5)) {
      try fake.service.load()
    }
    #expect(fake.bootstrapCount == 3)
    #expect(fake.bootoutCount == 0)
    #expect(fake.pauses.count == 2)
  }

  @Test func thirdBootstrapAttemptCanRecover() throws {
    let fake = FakeLaunchctl(prints: [113, 113, 113, 113, 113, 0], bootstraps: [5, 5, 0])
    try fake.service.load()
    #expect(fake.bootstrapCount == 3)
  }

  @Test func absentServiceNeedsNoBootout() throws {
    let fake = FakeLaunchctl(prints: [113])
    try fake.service.unload()
    #expect(fake.bootoutCount == 0)
    #expect(fake.pauses.isEmpty)
  }

  @Test func unloadWaitsForTheRegistrationToDisappear() throws {
    let fake = FakeLaunchctl(prints: [0, 0, 0, 113])
    try fake.service.unload()
    #expect(fake.bootoutCount == 1)
    #expect(fake.pauses == [0.5, 0.5])
  }

  @Test func serviceThatRemainsLoadedCannotBeReportedDisabled() {
    let fake = FakeLaunchctl(prints: Array(repeating: 0, count: 22), bootoutStatus: 5)
    #expect(throws: CodexWatcherService.RegistrationError(action: "关闭", status: 5)) {
      try fake.service.unload()
    }
    #expect(fake.bootoutCount == 1)
    #expect(fake.bootstrapCount == 0)
  }

  @Test func failedBootoutWithAnAlreadyGoneServiceIsSafe() throws {
    let fake = FakeLaunchctl(prints: [0, 113], bootoutStatus: 5)
    try fake.service.unload()
    #expect(fake.bootoutCount == 1)
    #expect(fake.pauses.isEmpty)
  }

  @Test func failedStatusQueryDoesNotAuthorizeRemovingTheService() {
    let fake = FakeLaunchctl(prints: [-1])
    #expect(throws: CodexWatcherService.RegistrationError(action: "关闭", status: -1)) {
      try fake.service.unload()
    }
    #expect(fake.bootoutCount == 0)
  }

  @Test func stoppingRegistrationIsNotEnabled() {
    let fake = FakeLaunchctl(prints: [0], stoppingAt: [0])
    #expect(!fake.service.isLoaded)
  }

  @Test func loadWaitsForStoppingJobBeforeRegisteringItsReplacement() throws {
    let fake = FakeLaunchctl(prints: [0, 0, 113, 0], bootstraps: [0], stoppingAt: [0, 1])
    try fake.service.load()
    #expect(fake.bootstrapCount == 1)
    #expect(fake.pauses == [0.5, 0.5])
  }

  @Test func permanentlyStoppingServiceHasABoundedWait() {
    let fake = FakeLaunchctl(prints: Array(repeating: 0, count: 21), stoppingAt: Set(0..<21))
    #expect(throws: CodexWatcherService.RegistrationError.self) { try fake.service.load() }
    #expect(fake.bootstrapCount == 0)
    #expect(fake.pauses.count == 20)
  }

  @Test func unloadAllowsTheExistingFiveSecondSleepToFinish() throws {
    let fake = FakeLaunchctl(prints: [0] + Array(repeating: 0, count: 10) + [113],
      stoppingAt: Set(1...10))
    try fake.service.unload()
    #expect(fake.bootoutCount == 1)
    #expect(fake.pauses.count == 10)
  }

  @Test func unloadingAnAlreadyStoppingJobDoesNotIssueAnotherBootout() throws {
    let fake = FakeLaunchctl(prints: [0, 0, 113], stoppingAt: [0, 1])
    try fake.service.unload()
    #expect(fake.bootoutCount == 0)
    #expect(fake.pauses.count == 1)
  }

  @MainActor @Test func waitingForTheServiceDoesNotBlockTheUIOrStartConcurrentOperations() async {
    let store = DashboardStore(startServices: false)
    let entered = WatcherTestFlag()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let start = Date()
    store.performWatcherOperation(successMessage: "已开启", failurePrefix: "失败") {
      entered.mark()
      #expect(release.wait(timeout: .now() + 2) == .success)
      return true
    }
    #expect(Date().timeIntervalSince(start) < 0.5)
    #expect(store.launchWatcherIsUpdating)
    store.performWatcherOperation(successMessage: nil, failurePrefix: "失败") {
      Issue.record("A concurrent watcher operation was allowed")
      return false
    }
    for _ in 0..<100 {
      if entered.value { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(entered.value)
    #expect(store.launchWatcherIsUpdating)
    release.signal()
    await waitForOperation(store)
    #expect(store.launchWithCodexEnabled)
    #expect(store.settingsMessage == "已开启")
  }

  @MainActor @Test func failureIsShownAndSuccessfulRecoveryClearsIt() async {
    let store = DashboardStore(startServices: false)
    store.launchWithCodexEnabled = true
    store.performWatcherOperation(successMessage: "已关闭", failurePrefix: "设置失败") {
      throw CodexWatcherService.RegistrationError(action: "关闭", status: 5)
    }
    await waitForOperation(store)
    #expect(store.launchWithCodexEnabled)
    #expect(store.settingsMessage?.contains("设置失败") == true)
    store.performWatcherOperation(successMessage: nil, failurePrefix: "修复失败") { true }
    await waitForOperation(store)
    #expect(store.settingsMessage == nil)
  }

  @MainActor private func waitForOperation(_ store: DashboardStore) async {
    for _ in 0..<200 {
      if !store.launchWatcherIsUpdating { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Watcher operation did not finish")
  }
}

private final class WatcherTestFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false
  var value: Bool { lock.withLock { entered } }
  func mark() { lock.withLock { entered = true } }
}

private final class FakeLaunchctl {
  var prints: [Int32]
  var bootstraps: [Int32]
  let bootoutStatus: Int32
  let stoppingAt: Set<Int>
  var printCount = 0
  var bootstrapCount = 0
  var bootoutCount = 0
  var pauses: [TimeInterval] = []
  let plistPath = "/synthetic/O'Brien 自动启动/agent.plist"

  init(prints: [Int32], bootstraps: [Int32] = [], bootoutStatus: Int32 = 0, stoppingAt: Set<Int> = []) {
    self.prints = prints
    self.bootstraps = bootstraps
    self.bootoutStatus = bootoutStatus
    self.stoppingAt = stoppingAt
  }

  var service: CodexWatcherService {
    CodexWatcherService(domain: "gui/777", label: "synthetic.watcher", plistPath: plistPath,
      run: { self.run($0) }, pause: { self.pauses.append($0) })
  }

  private func run(_ arguments: [String]) -> CodexWatcherService.CommandResult {
    switch arguments.first {
    case "print":
      #expect(arguments == ["print", "gui/777/synthetic.watcher"])
      guard !prints.isEmpty else { Issue.record("Unexpected registration query"); return .init(status: 113) }
      defer { printCount += 1 }
      return .init(status: prints.removeFirst(), output: stoppingAt.contains(printCount) ? "state = SIGTERMed" : "")
    case "bootstrap":
      #expect(arguments == ["bootstrap", "gui/777", plistPath])
      bootstrapCount += 1
      guard !bootstraps.isEmpty else { Issue.record("Unexpected registration attempt"); return .init(status: 5) }
      return .init(status: bootstraps.removeFirst())
    case "bootout":
      #expect(arguments == ["bootout", "gui/777/synthetic.watcher"])
      bootoutCount += 1
      return .init(status: bootoutStatus)
    default:
      Issue.record("Unexpected launchctl operation")
      return .init(status: -1)
    }
  }
}
