import Foundation
import Testing
@testable import CodexBalanceCore

@Suite
struct CodexExecutableDiscoveryTests {
  @Test(arguments: ["ChatGPT.app", "Codex.app"])
  func discoversNestedCLIWithoutShellPath(appName: String) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = try executable(root, "\(appName)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    #expect(CodexAppServerRateLimitSource.bundledCodexExecutableURL(applicationDirectories: [root]) == cli)
  }

  @Test
  func retainsLegacyLayoutAndPrefersNestedCLI() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try executable(root, "ChatGPT.app/Contents/Resources/codex")
    #expect(CodexAppServerRateLimitSource.bundledCodexExecutableURL(applicationDirectories: [root]) == legacy)
    let nested = try executable(root, "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    #expect(CodexAppServerRateLimitSource.bundledCodexExecutableURL(applicationDirectories: [root]) == nested)
  }

  @Test
  func searchesUserApplicationsAndRejectsNonExecutables() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = root.appendingPathComponent("system")
    let user = root.appendingPathComponent("user")
    let invalid = try executable(system, "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: invalid.path)
    let cli = try executable(user, "Codex.app/Contents/Resources/codex")
    #expect(CodexAppServerRateLimitSource.bundledCodexExecutableURL(applicationDirectories: [system, user]) == cli)
    try FileManager.default.removeItem(at: cli)
    try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
    #expect(CodexAppServerRateLimitSource.bundledCodexExecutableURL(applicationDirectories: [system, user]) == nil)
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func executable(_ root: URL, _ path: String) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}
