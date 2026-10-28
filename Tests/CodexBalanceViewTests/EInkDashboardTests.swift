import AppKit
import CodexBalanceCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBalance

@Suite("E-ink dashboard integration", .serialized)
struct EInkDashboardTests {
  @MainActor @Test func renderExactOpaqueBinaryPNGs() throws {
    _ = NSApplication.shared
    let folder = ProcessInfo.processInfo.environment["CODEX_PULSE_EINK_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let now = Date(timeIntervalSince1970: 1_792_800_000)
    for profile in EInkScreenProfile.presets {
      for (name, presentation) in [("sample", EInkPresentation.sample(at: now)), ("empty", EInkPresentation(snapshot: .empty, at: now))] {
        let data = try EInkRenderer.render(presentation, profile: profile)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == profile.width); #expect(image.pixelsHigh == profile.imageHeight)
        #expect(!image.hasAlpha)
        let pixels = try #require(image.bitmapData)
        var black = 0
        var binary = true
        for y in 0..<image.pixelsHigh {
          for x in 0..<image.pixelsWide {
            let byte = pixels[y*image.bytesPerRow+x]
            binary = binary && (byte == 0 || byte == 255)
            if byte == 0 { black += 1 }
          }
        }
        #expect(black > 500)
        #expect(binary)
        if let folder {
          try data.write(to: folder.appendingPathComponent("eink-\(profile.title.replacingOccurrences(of: " ", with: ""))-\(name)-body.png"))
          try EInkRenderer.devicePreview(data, profile: profile).write(to: folder.appendingPathComponent("eink-\(profile.width)x\(profile.height)-\(name)-device.png"))
        }
      }
    }
  }

  @MainActor @Test func cloudPublicationStagesImageValidationBeforeModeCommit() async throws {
    let profile = EInkScreenProfile()
    let preview = try EInkRenderer.devicePreview(EInkRenderer.render(.sample(), profile: profile), profile: profile)
    let transport = StubEInkTransport(preview: preview)
    let service = XiaowuCloudPublisher(transport: transport)
    _ = try await service.publish(png: Data([1, 2, 3]), device: .init(mac: "AA:BB:CC:DD:EE:FF"), profile: profile, modeID: "CODEX_PULSE_TEST")
    #expect(transport.paths == ["/api/user/devices", "/api/uploads", "/api/modes/custom/preview", "/api/modes/custom"])
    #expect(!transport.paths.contains { $0.contains("/config") || $0.contains("/switch") || $0.contains("discover") })
    transport.paths = []; transport.probeStatus = 500
    await #expect(throws: XiaowuCloudError.http(500)) {
      _ = try await service.publish(png: Data([1]), device: .init(mac: "AA:BB:CC:DD:EE:FF"), profile: profile, modeID: "CODEX_PULSE_TEST")
    }
    #expect(transport.paths == ["/api/user/devices", "/api/uploads", "/api/modes/custom/preview"])
    let corrupt = StubEInkTransport(preview: Data(preview.prefix(24)))
    let corruptService = XiaowuCloudPublisher(transport: corrupt)
    await #expect(throws: XiaowuCloudError.invalidImage) {
      _ = try await corruptService.publish(png: Data([1]), device: .init(mac: "AA:BB:CC:DD:EE:FF"), profile: profile, modeID: "CODEX_PULSE_TEST")
    }
    #expect(!corrupt.paths.contains("/api/modes/custom"))
  }

  @MainActor @Test func sampleAndPhysicalAcknowledgementAreRequiredBeforeRealSync() async throws {
    let suite = "eink-test-\(UUID().uuidString)"
    // Each test uses an isolated suite and never touches the user's sign-in or preferences.
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = StubEInkService()
    let model = EInkDashboardStore(defaults: preferences, service: service)
    model.ingest(.preview, accountScope: "test-account")
    #expect(!model.canPublishRealData)
    model.readDevices(); try await wait(model)
    #expect(model.selectedDevice != nil); #expect(!model.canPublishRealData)
    model.uploadSample(); try await wait(model)
    #expect(model.sampleUploaded); #expect(!model.canPublishRealData)
    model.confirmDeviceDisplayedSample(); #expect(!model.deviceVerified)
    model.fetchCloudPreview(); try await wait(model)
    model.confirmDeviceDisplayedSample(); #expect(model.canPublishRealData)
    model.setAutomaticSync(true); try await wait(model)
    #expect(model.automaticSync)
    #expect(service.uploads == 2)
    service.failure = .loginRequired
    model.publishRealData(); try await wait(model)
    #expect(!model.automaticSync); #expect(model.statusMessage.contains("登录"))
    service.failure = nil
    model.setAutomaticSync(true); try await wait(model)
    #expect(model.automaticSync)
    model.ingest(.preview, accountScope: "different-account")
    #expect(!model.automaticSync)
    model.setProfile(.init(width: 648, height: 480))
    #expect(!model.deviceVerified); #expect(!model.canPublishRealData)
  }

  @MainActor @Test func authenticationIsReportedWithoutReadingLoginCredentials() async throws {
    let transport = StubEInkTransport(preview: Data()); transport.loginFailure = true
    let service = XiaowuCloudPublisher(transport: transport)
    await #expect(throws: XiaowuCloudError.loginRequired) { _ = try await service.devices() }
    transport.paths = []
    await #expect(throws: XiaowuCloudError.loginRequired) {
      _ = try await service.publish(png: Data([1]), device: .init(mac: "AA:BB:CC:DD:EE:FF"), profile: .init(), modeID: "CODEX_PULSE_TEST")
    }
    #expect(transport.paths == ["/api/user/devices"])
  }

  @MainActor @Test func cancellationAfterProbeDoesNotCommitTheMode() async throws {
    let profile = EInkScreenProfile()
    let image = try EInkRenderer.devicePreview(EInkRenderer.render(.sample(), profile: profile), profile: profile)
    let transport = StubEInkTransport(preview: image); transport.cancelOnProbe = true
    let publisher = XiaowuCloudPublisher(transport: transport)
    let operation = Task { @MainActor in
      _ = try await publisher.publish(png: Data([1]), device: .init(mac: "AA:BB:CC:DD:EE:FF"), profile: profile, modeID: "CODEX_PULSE_TEST")
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(transport.paths == ["/api/user/devices", "/api/uploads", "/api/modes/custom/preview"])
  }

  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_EINK_RENDER_DIR"] != nil))
  func renderTheSettingsEntry() throws {
    _ = NSApplication.shared
    let suite = "eink-settings-\(UUID().uuidString)", preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = EInkDashboardStore(defaults: preferences, service: StubEInkService())
    let view = EInkSettingsView(model: model).padding(20).frame(width: 720).background(Color.white).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    let size = NSSize(width: 720, height: max(1100, host.fittingSize.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.close()
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_EINK_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try data.write(to: root.appendingPathComponent("eink-settings.png"))
  }

  @MainActor private func wait(_ model: EInkDashboardStore) async throws {
    for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isBusy)
  }
}

@MainActor private final class StubEInkTransport: XiaowuCloudTransport {
  let preview: Data
  var paths: [String] = []
  var probeStatus = 200
  var loginFailure = false
  var cancelOnProbe = false
  init(preview: Data) { self.preview = preview }
  func request(path: String, method: String, body: Data?, contentType: String) async throws -> XiaowuHTTPResponse {
    paths.append(path)
    if loginFailure { return .init(status: 401, contentType: "application/json", data: Data()) }
    if path == "/api/user/devices" {
      return .init(status: 200, contentType: "application/json", data: Data(#"{"devices":[{"mac":"AA:BB:CC:DD:EE:FF"}]}"#.utf8))
    }
    if path == "/api/uploads" {
      return .init(status: 200, contentType: "application/json", data: Data(#"{"ok":true,"url":"https://xiaowuai.vip/api/uploads/00000000-0000-0000-0000-000000000001"}"#.utf8))
    }
    if path == "/api/modes/custom/preview" {
      if cancelOnProbe { withUnsafeCurrentTask { $0?.cancel() } }
      return .init(status: probeStatus, contentType: "image/png", data: preview)
    }
    return .init(status: 200, contentType: "application/json", data: Data(#"{"ok":true,"mode_id":"CODEX_PULSE_TEST"}"#.utf8))
  }
}
@MainActor private final class StubEInkService: XiaowuCloudService {
  var uploads = 0
  var failure: XiaowuCloudError?
  func devices() async throws -> [XiaowuDevice] { [.init(mac: "AA:BB:CC:DD:EE:FF", nickname: "测试屏幕")] }
  func publish(png: Data, device: XiaowuDevice, profile: EInkScreenProfile, modeID: String) async throws -> Data {
    if let failure { throw failure }
    uploads += 1
    return try EInkRenderer.devicePreview(png, profile: profile)
  }
  func preview(device: XiaowuDevice, profile: EInkScreenProfile, modeID: String) async throws -> Data {
    try EInkRenderer.devicePreview(EInkRenderer.render(.sample(), profile: profile), profile: profile)
  }
}
