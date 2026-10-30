import Foundation
import XCTest
@testable import SidebarCore

final class CodexRPCReaderTests: XCTestCase {
  func testPicksSevenDayWindowAndCreditBalance() throws {
    let source = """
    {"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":10},
      "secondary":{"windowDurationMins":10080,"usedPercent":43},
      "credits":{"balance":"12345.75","unlimited":false}},
      "rateLimitResetCredits":{"availableCount":4}}
    """
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    let sample = try XCTUnwrap(CodexRateLimitParser.sample(from: object, at: Date(timeIntervalSince1970: 100)))
    XCTAssertEqual(sample.remaining, 57)
    XCTAssertEqual(sample.balance, 12345.75)
    XCTAssertEqual(sample.resetCount, 4)
    XCTAssertEqual(sample.sampledAt, 100)
  }

  func testMissingOrInvalidValuesAreNotInvented() {
    XCTAssertNil(CodexRateLimitParser.sample(from: [:]))
    XCTAssertNil(CodexRateLimitParser.sample(from: ["rateLimits": [
      "primary": ["windowDurationMins": 10080, "usedPercent": true],
      "credits": ["balance": "-2"]
    ]]))
    XCTAssertNil(CodexRateLimitParser.sample(from: ["rateLimitResetCredits": ["availableCount": -1]]))
    XCTAssertEqual(CodexRateLimitParser.sample(from: ["rateLimitResetCredits": ["availableCount": 0]])?.resetCount, 0)
  }

  func testReadsMockServerWithoutPython() throws {
    let script = """
    #!/bin/sh
    while IFS= read -r request; do
      case "$request" in
        *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *rateLimits*) printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":10080,"usedPercent":40},"credits":{"balance":"998.5"}}}}' ;;
      esac
    done
    """
    let executable = try makeExecutable(script)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let value = try XCTUnwrap(CodexRPCReader.read(executable: executable, timeout: 3))
    XCTAssertEqual(value.remaining, 60)
    XCTAssertEqual(value.balance, 998.5)
  }

  func testUnresponsiveServerTimesOut() throws {
    let executable = try makeExecutable("#!/bin/sh\nwhile IFS= read -r request; do :; done\n")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let started = Date()
    XCTAssertNil(CodexRPCReader.read(executable: executable, timeout: 0.3))
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  private func makeExecutable(_ content: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("mock-codex")
    try Data(content.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file
  }
}
