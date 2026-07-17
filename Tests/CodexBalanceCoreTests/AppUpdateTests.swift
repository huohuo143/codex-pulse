import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("App update detection")
struct AppUpdateTests {
  @Test func semanticVersionsCompareNumerically() throws {
    let current = try #require(SemanticVersion("v2.9.0"))
    let newerMinor = try #require(SemanticVersion("2.10.0"))
    let newerPatch = try #require(SemanticVersion("2.9.1"))

    #expect(newerMinor > current)
    #expect(newerPatch > current)
    #expect(SemanticVersion("2.9") == current)
  }

  @Test func stableVersionRanksAbovePrerelease() throws {
    let prerelease = try #require(SemanticVersion("v3.0.0-beta.2"))
    let laterPrerelease = try #require(SemanticVersion("3.0.0-beta.10"))
    let stable = try #require(SemanticVersion("3.0.0"))

    #expect(prerelease < laterPrerelease)
    #expect(laterPrerelease < stable)
  }

  @Test func malformedVersionsAreRejected() {
    #expect(SemanticVersion("") == nil)
    #expect(SemanticVersion("version 2.9.0") == nil)
    #expect(SemanticVersion("2.9.0.1") == nil)
    #expect(SemanticVersion("2.x.0") == nil)
  }

  @Test func githubReleaseDecodesAndSelectsDMG() throws {
    let data = Data(
      """
      {
        "tag_name": "v2.9.0",
        "name": "Codex Pulse 2.9.0",
        "body": "Update notes",
        "html_url": "https://github.com/huohuo143/codex-pulse/releases/tag/v2.9.0",
        "published_at": "2026-07-17T08:00:00Z",
        "draft": false,
        "prerelease": false,
        "assets": [
          {
            "name": "Codex-Pulse-v2.9.0-arm64.dmg.sha256",
            "browser_download_url": "https://github.com/example/checksum",
            "state": "uploaded"
          },
          {
            "name": "Codex-Pulse-v2.9.0-arm64.dmg",
            "browser_download_url": "https://github.com/example/app.dmg",
            "content_type": "application/x-apple-diskimage",
            "size": 1234,
            "state": "uploaded"
          }
        ]
      }
      """.utf8
    )

    let release = try GitHubReleaseUpdateService.decodeRelease(from: data)
    #expect(release.version == SemanticVersion("2.9.0"))
    #expect(release.preferredDMGURL?.absoluteString == "https://github.com/example/app.dmg")
    #expect(release.publishedAt != nil)
  }

  @Test func evaluatorDistinguishesAvailableCurrentAndLocalNewer() throws {
    let release = AppRelease(
      tagName: "v2.9.0",
      htmlURL: try #require(URL(string: "https://github.com/example/release"))
    )

    let available = try GitHubReleaseUpdateService.evaluate(
      release: release,
      currentVersion: try #require(SemanticVersion("2.8.0"))
    )
    let current = try GitHubReleaseUpdateService.evaluate(
      release: release,
      currentVersion: try #require(SemanticVersion("2.9.0"))
    )
    let localNewer = try GitHubReleaseUpdateService.evaluate(
      release: release,
      currentVersion: try #require(SemanticVersion("2.10.0"))
    )

    #expect(available.availability == .updateAvailable)
    #expect(current.availability == .upToDate)
    #expect(localNewer.availability == .localVersionNewer)
  }

  @Test func draftReleaseIsRejected() throws {
    let release = AppRelease(
      tagName: "v9.0.0",
      htmlURL: try #require(URL(string: "https://github.com/example/release")),
      draft: true
    )

    #expect(throws: AppUpdateError.self) {
      try GitHubReleaseUpdateService.evaluate(
        release: release,
        currentVersion: try #require(SemanticVersion("2.9.0"))
      )
    }
  }
}
