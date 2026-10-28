import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("S3 dual-screen sandbox contracts")
struct S3DualScreenTests {
  private let now = Date(timeIntervalSince1970: 1_792_980_000)

  @Test func publicContentContractAndWhitelist() throws {
    let sample = EInkPresentation.sample(at: now)
    for screen in S3Screen.allCases {
      let data = try S3TemplateData(sample: sample, screen: screen, profile: .init())
      let push = try S3ContentRequest(template: "codex-pulse-\(screen.rawValue.lowercased())", screen: screen, data: data)
      let encoded = try S3DualScreenContract.encode(push)
      let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      #expect(Set(object.keys) == ["template", "screen", "data", "expires_in_seconds"])
      #expect(object["screen"] as? String == screen.rawValue)
      #expect(object["expires_in_seconds"] as? Int == 3600)
      let projected = try #require(object["data"] as? [String: Any])
      #expect(projected["is_sample"] as? Bool == true)
      #expect(projected["minimum_font_pixels"] as? Int == 18)
      #expect(projected["image_url"] == nil)
      for key in ["account", "account_scope", "project", "path", "token", "cookie", "prompt", "model_summary"] { #expect(projected[key] == nil) }
      #expect(screen == .a ? data.history.isEmpty : !data.history.isEmpty)
    }
    #expect(throws: S3SandboxError.sandboxRequired) { try S3TemplateData(sample: EInkPresentation(snapshot: .empty, at: now), screen: .a, profile: .init()) }
    #expect(throws: S3SandboxError.invalidConfiguration) { try S3ContentRequest(template: "CODEX_PULSE", screen: .a, data: S3TemplateData(sample: sample, screen: .a, profile: .init())) }
  }

  @Test func targetValidationAndCredentialRedaction() throws {
    #expect(throws: S3SandboxError.sandboxRequired) { try S3SandboxTarget().validate() }
    let valid = S3SandboxTarget(deviceID: "sandbox-test-device", templateA: "codex-pulse-a", templateB: "codex-pulse-b", confirmedSandbox: true)
    try valid.validate()
    for id in ["../production", "id?query=1", "bad/id", ""] {
      var target = valid; target.deviceID = id
      #expect(throws: S3SandboxError.invalidConfiguration) { try target.validate() }
    }
    let secret = "synthetic-test-credential"
    let credential = try S3SandboxCredential(secret)
    #expect(!String(describing: credential).contains(secret))
    #expect(!String(reflecting: credential).contains(secret))
    var request = URLRequest(url: try S3DualScreenContract.endpoint("/openapi/v1/devices/sandbox-test-device"))
    credential.authorize(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
    #expect(request.url?.path == "/backend/openapi/v1/devices/sandbox-test-device")
    #expect(throws: S3SandboxError.credentialRequired) { try S3SandboxCredential("header\r\ninjection") }
  }

  @Test func nativeLayoutNeverShrinksTextAndPreservesHistoryGaps() throws {
    for p in [S3ScreenProfile(), .init(width: 648, height: 480), .init(width: 800, height: 480), .init(width: 600, height: 800)] {
      for screen in S3Screen.allCases {
        let layout = try S3DualScreenLayout(sample: .sample(at: now), screen: screen, profile: p)
        #expect(layout.commands.filter { $0.kind == .text }.allSatisfy { $0.fontSize >= 18 })
        for c in layout.commands {
          for i in stride(from: 0, to: c.points.count, by: 2) {
            #expect(c.points[i] >= 0 && c.points[i] <= Double(p.width))
            #expect(c.points[i+1] >= 0 && c.points[i+1] <= Double(p.height))
          }
        }
        let svg = String(decoding: layout.svg(), as: UTF8.self)
        #expect(svg.contains("示例")); #expect(!svg.contains("<image")); #expect(!svg.contains("<script"))
        if screen == .b {
          let lines = layout.commands.filter { $0.kind == .polyline }
          #expect(lines.count == 4)
          // Every rendered line is one cycle: no upward reset edge or bridge across a break.
          for line in lines {
            let ys = stride(from: 1, to: line.points.count, by: 2).map { line.points[$0] }
            #expect(zip(ys, ys.dropFirst()).allSatisfy { $1 >= $0 })
          }
          for (previous, next) in zip(lines, lines.dropFirst()) {
            #expect(previous.points[previous.points.count-2] < next.points[0])
          }
        }
      }
    }
    let mono = try S3DualScreenLayout(sample: .sample(at: now), screen: .b, profile: .init(monochrome: true))
    #expect(mono.commands.allSatisfy { !$0.accent })
  }

  @Test func eachScreenHasIndependentCooldownAndBackoff() throws {
    var policy = S3ScreenPushPolicy()
    policy.succeeded(.a, at: now); policy.succeeded(.b, at: now)
    try policy.validate(.a, at: now.addingTimeInterval(600))
    #expect(throws: S3SandboxError.coolingDown(300)) { try policy.validate(.b, at: now.addingTimeInterval(600)) }
    try policy.validate(.b, at: now.addingTimeInterval(900))
    var failed = S3ScreenPushPolicy(); failed.failed(.b, at: now)
    #expect(throws: S3SandboxError.coolingDown(30)) { try failed.validate(.b, at: now) }
    try failed.validate(.a, at: now)
    try failed.validate(.b, at: now.addingTimeInterval(30))
    var uncertain = S3ScreenPushPolicy(); uncertain.started(.b, at: now); uncertain.failed(.b, at: now)
    #expect(throws: S3SandboxError.coolingDown(869)) { try uncertain.validate(.b, at: now.addingTimeInterval(31)) }
    try uncertain.validate(.a, at: now)
  }
}
