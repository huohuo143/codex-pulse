import AppKit
import CodexBalanceCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBalance

@Suite("S3 sandbox workflow", .serialized)
struct S3SandboxTests {
  private let target = S3SandboxTarget(deviceID: "sandbox-test-device", templateA: "codex-pulse-a", templateB: "codex-pulse-b", confirmedSandbox: true)
  private let now = Date(timeIntervalSince1970: 1_792_980_000)

  @MainActor private func png(_ screen: S3Screen = .a) throws -> Data {
    _ = NSApplication.shared
    return try S3DualScreenRenderer.png(S3DualScreenLayout(sample: .sample(at: now), screen: screen, profile: .init()))
  }
  private var key: S3SandboxCredential { get throws { try .init("synthetic-test-credential") } }

  @MainActor @Test func structuredPushUsesOnlyOfficialOpenAPIAnd202IsAcceptance() async throws {
    let transport = S3StubTransport()
    let service = S3SandboxService(transport: transport)
    let receipt = try await service.publish(png: png(), sample: .sample(at: now), screen: .a, profile: .init(), target: target, credential: key)
    #expect(receipt.taskID == "test-task-A"); #expect(receipt.screen == .a)
    let requests = await transport.requests
    #expect(requests.map { $0.url!.path } == ["/backend/openapi/v1/devices/sandbox-test-device", "/backend/openapi/v1/devices/sandbox-test-device/content"])
    #expect(requests.allSatisfy { $0.url?.host == "dual.xiaowuai.vip" })
    let body = try #require(requests.last?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["template"] as? String == "codex-pulse-a")
    #expect((object["data"] as? [String: Any])?["image_url"] == nil)
  }

  @MainActor @Test func unauthorizedAndProductionTargetsNeverReceiveContent() async throws {
    for mode in [S3StubTransport.Mode.unauthorized, .production, .wrongDevice, .html] {
      let transport = S3StubTransport(mode: mode), service = S3SandboxService(transport: transport)
      do { _ = try await service.publish(png: png(), sample: .sample(at: now), screen: .a, profile: .init(), target: target, credential: key); Issue.record("Rejected target unexpectedly accepted") }
      catch { #expect(error is S3SandboxError) }
      #expect(await transport.requests.count == 1)
    }
  }

  @MainActor @Test func malformedImageAndRealDataNeverLeaveProcess() async throws {
    let transport = S3StubTransport(), service = S3SandboxService(transport: transport)
    let truncated = Data(try png().prefix(24))
    await #expect(throws: S3SandboxError.invalidImage) {
      try await service.publish(png: truncated, sample: .sample(at: now), screen: .a, profile: .init(), target: target, credential: key)
    }
    await #expect(throws: S3SandboxError.sandboxRequired) {
      try await service.publish(png: png(), sample: EInkPresentation(snapshot: .empty, at: now), screen: .a, profile: .init(), target: target, credential: key)
    }
    #expect(await transport.requests.isEmpty)
  }

  @MainActor @Test func missingTaskIDDoesNotBecomeSuccess() async throws {
    let service = S3SandboxService(transport: S3StubTransport(mode: .missingTask))
    await #expect(throws: S3SandboxError.incompatible) {
      try await service.publish(png: png(), sample: .sample(at: now), screen: .a, profile: .init(), target: target, credential: key)
    }
  }

  @MainActor @Test func independentScreenReceiptsAndCredentialPersistence() async throws {
    let suite = "s3-workflow-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = S3StubService(), model = S3SandboxStore(defaults: defaults, service: service)
    model.configure(target: target, a: .init(monochrome: true), b: .init())
    model.connect("synthetic-test-credential"); try await wait(model)
    #expect(model.connected)
    model.push(.a); try await wait(model)
    #expect(model.receipts[.a] != nil)
    model.push(.b); try await wait(model)
    #expect(model.receipts[.a] != nil); #expect(model.receipts[.b] == nil)
    #expect(model.statusMessage.contains("500"))
    model.disconnect(); #expect(!model.connected); #expect(!model.canPush)
    #expect(!String(describing: defaults.dictionaryRepresentation()).contains("synthetic-test-credential"))
    let restored = S3SandboxStore(defaults: defaults, service: service)
    #expect(!restored.target.confirmedSandbox); #expect(!restored.connected)
    restored.configure(target: target, a: .init(), b: .init())
    restored.connect("synthetic-test-credential"); try await wait(restored)
    restored.push(.b)
    #expect(!restored.isBusy); #expect(restored.statusMessage.contains("等待刷新间隔"))
  }

  @MainActor @Test func disconnectCancelsInFlightConnection() async throws {
    let suite = "s3-cancel-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = S3SandboxStore(defaults: defaults, service: S3StubService(delay: true))
    model.configure(target: target, a: .init(), b: .init()); model.connect("synthetic-test-credential")
    model.disconnect(); try await Task.sleep(for: .milliseconds(80))
    #expect(!model.connected); #expect(!model.isBusy)
  }

  @MainActor @Test func nativeImagesUseExactPaletteAndTextStaysInsideCanvas() throws {
    _ = NSApplication.shared
    let folder = ProcessInfo.processInfo.environment["CODEX_PULSE_S3_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for profile in [S3ScreenProfile(), .init(width: 648, height: 480), .init(width: 800, height: 480), .init(width: 600, height: 800), .init(monochrome: true)] {
      for screen in S3Screen.allCases {
        let layout = try S3DualScreenLayout(sample: .sample(at: now), screen: screen, profile: profile)
        let png = try S3DualScreenRenderer.png(layout), bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == profile.width && bitmap.pixelsHigh == profile.height); #expect(!bitmap.hasAlpha)
        let pixels = try #require(bitmap.bitmapData)
        var palette = Set<String>()
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
          // AppKit can decode a 24-bit RGB PNG into 32-bit rows with an unused byte.
          let i = y*bitmap.bytesPerRow+x*(bitmap.bitsPerPixel/8)
          palette.insert("\(pixels[i]),\(pixels[i+1]),\(pixels[i+2])")
        } }
        #expect(palette.isSubset(of: ["0,0,0", "255,255,255", "192,0,0"]))
        if screen == .a || profile.monochrome { #expect(!palette.contains("192,0,0")) }
        for c in layout.commands where c.kind == .text {
          let font = NSFont.systemFont(ofSize: c.fontSize, weight: c.bold ? .bold : .regular)
          let size = (c.text as NSString).size(withAttributes: [.font: font])
          #expect(c.fontSize >= 18)
          #expect(c.points[0]+size.width <= Double(profile.width)-4)
          #expect(c.points[1]-font.descender <= Double(profile.height))
        }
        if let folder {
          let prefix = "screen-\(screen.rawValue)-\(profile.width)x\(profile.height)-\(profile.monochrome ? "bw" : "color")"
          try png.write(to: folder.appendingPathComponent(prefix+".png")); try layout.svg().write(to: folder.appendingPathComponent(prefix+".svg"))
        }
      }
    }
  }

  @MainActor @Test func reviewExportContainsOnlySampleProposalsAndRendersSettings() throws {
    _ = NSApplication.shared
    let suite = "s3-export-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_S3_RENDER_DIR"] ?? NSTemporaryDirectory())
      .appendingPathComponent("review-sample")
    let model = S3SandboxStore(defaults: defaults, service: S3StubService())
    model.configure(target: target, a: .init(monochrome: true), b: .init()); model.refreshPreviews(at: now)
    try model.export(to: root)
    let request = try Data(contentsOf: root.appendingPathComponent("screen-A-request-proposal.json"))
    #expect(!String(decoding: request, as: UTF8.self).contains(target.deviceID))
    let view = S3SandboxSettingsView(model: model).padding(20).frame(width: 850).background(Color.white).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view); host.frame = .init(origin: .zero, size: host.fittingSize); host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("s3-settings.png"))
  }
  @MainActor private func wait(_ model: S3SandboxStore) async throws {
    for _ in 0..<200 { if !model.isBusy { return }; try await Task.sleep(for: .milliseconds(10)) }
    Issue.record("Sandbox operation did not finish")
  }
}

private actor S3StubTransport: S3HTTPTransport {
  enum Mode: Sendable { case normal, unauthorized, production, wrongDevice, html, missingTask }
  private let mode: Mode
  private(set) var requests: [URLRequest] = []
  init(mode: Mode = .normal) { self.mode = mode }
  func send(_ request: URLRequest) async throws -> S3HTTPResponse {
    requests.append(request)
    if mode == .unauthorized { return .init(status: 401, contentType: "application/json", data: Data(#"{"detail":"must not echo synthetic credentials"}"#.utf8)) }
    if mode == .html { return .init(status: 200, contentType: "text/html", data: Data("login".utf8)) }
    if request.httpMethod == "GET" {
      let id = mode == .wrongDevice ? "production-other" : "sandbox-test-device"
      let environment = mode == .production ? "production" : "sandbox"
      return .init(status: 200, contentType: "application/json", data: try JSONSerialization.data(withJSONObject: ["device_id": id, "environment": environment]))
    }
    let json = mode == .missingTask ? "{}" : #"{"task_id":"test-task-A","status":"queued"}"#
    return .init(status: 202, contentType: "application/json", data: Data(json.utf8))
  }
}

private actor S3StubService: S3SandboxServing {
  let delay: Bool
  init(delay: Bool = false) { self.delay = delay }
  func device(target: S3SandboxTarget, credential: S3SandboxCredential) async throws -> S3DeviceStatus {
    if delay { try await Task.sleep(for: .milliseconds(50)) }
    return .init(deviceID: target.deviceID, environment: "sandbox", lastSeen: nil)
  }
  func publish(png: Data, sample: EInkPresentation, screen: S3Screen, profile: S3ScreenProfile,
    target: S3SandboxTarget, credential: S3SandboxCredential) async throws -> S3PushReceipt {
    if screen == .b { throw S3SandboxError.http(500) }
    return .init(screen: screen, taskID: "test-accepted-task", acceptedAt: Date())
  }
}
