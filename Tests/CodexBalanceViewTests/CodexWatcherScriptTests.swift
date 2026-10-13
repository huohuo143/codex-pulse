import Darwin
import Foundation
import Testing
@testable import CodexBalance

@Suite("Watcher process locking", .serialized)
struct CodexWatcherScriptTests {
  @Test func kernelLockExcludesConcurrentWatcherAndReleasesAfterForcedExit() throws {
    try verifyLockRelease(signal: SIGKILL)
  }

  @Test func kernelLockReleasesAfterNormalTermination() throws {
    try verifyLockRelease(signal: SIGTERM)
  }

  @Test func scriptVersionDetectsLegacyInstallationAndQuotedAppPath() throws {
    let appURL = URL(fileURLWithPath: "/Applications/Fixture's 脉动.app")
    let script = CodexWatcherManager.watcherScript(appPath: appURL.path)
    #expect(CodexWatcherManager.isCurrentInstallation(script: script, appURL: appURL))
    #expect(!CodexWatcherManager.isCurrentInstallation(
      script: script.replacingOccurrences(of: "WATCHER_SCRIPT_VERSION=2", with: "WATCHER_SCRIPT_VERSION=1"),
      appURL: appURL))
    #expect(!CodexWatcherManager.isCurrentInstallation(script: script,
      appURL: URL(fileURLWithPath: "/Applications/Another.app")))
    #expect(!script.contains("WATCH_LOCK_DIR="))
    let validation = try run(script: script, syntaxOnly: true)
    validation.process.waitUntilExit()
    #expect(validation.process.terminationStatus == 0)
  }

  private func verifyLockRelease(signal: Int32) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-lock-tests-\(UUID().uuidString)")
    let legacy = root.appendingPathComponent("watch.lock", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = legacy.appendingPathComponent("retain.txt")
    let original = Data("legacy directory must be retained".utf8)
    try original.write(to: sentinel)
    let lockURL = root.appendingPathComponent("watch-process.lock")
    let generated = CodexWatcherManager.watcherScript(appPath: "/Applications/Synthetic.app")
    let sections = generated.components(separatedBy: "resolve_dashboard_app() {")
    try #require(sections.count == 2, "Only the lock preamble may run in the synthetic test")
    let prefix = sections[0].replacingOccurrences(
        of: "WATCH_LOCK_FILE=\"$HOME/Library/Application Support/CodexSuanliMeter/watch-process.lock\"",
        with: "WATCH_LOCK_FILE=\(shellQuote(lockURL.path))")
    try #require(prefix.contains("WATCH_LOCK_FILE=\(shellQuote(lockURL.path))"),
      "The real watcher lock path must be replaced before any process starts")
    let acquired = root.appendingPathComponent("first-acquired")
    let first = try run(script: prefix + "\nprint -r -- acquired > \(shellQuote(acquired.path))\nread -r REPLY\n")
    defer {
      if first.process.isRunning {
        kill(first.process.processIdentifier, SIGKILL)
        first.process.waitUntilExit()
      }
    }
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: acquired.path), first.process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(FileManager.default.fileExists(atPath: acquired.path), "Synthetic watcher must acquire its initial lock")

    let contenderMarker = root.appendingPathComponent("contender-acquired")
    let contender = try run(script: prefix + "\nprint -r -- acquired > \(shellQuote(contenderMarker.path))\n")
    contender.process.waitUntilExit()
    #expect(contender.process.terminationStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: contenderMarker.path))

    #expect(kill(first.process.processIdentifier, signal) == 0)
    first.process.waitUntilExit()
    let restartedMarker = root.appendingPathComponent("restart-acquired")
    let restarted = try run(script: prefix + "\nprint -r -- acquired > \(shellQuote(restartedMarker.path))\n")
    restarted.process.waitUntilExit()
    #expect(restarted.process.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: restartedMarker.path))
    #expect(FileManager.default.fileExists(atPath: lockURL.path))
    #expect(try Data(contentsOf: sentinel) == original)
  }

  private func run(script: String, syntaxOnly: Bool = false) throws -> (process: Process, input: Pipe) {
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = syntaxOnly ? ["-f", "-n", "-c", script] : ["-f", "-c", script]
    process.standardInput = input
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return (process, input)
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
