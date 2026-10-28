import AppKit
import CodexBalanceCore
import SwiftUI

@MainActor
final class S3SandboxStore: ObservableObject {
  @Published private(set) var target: S3SandboxTarget
  @Published private(set) var profileA: S3ScreenProfile
  @Published private(set) var profileB: S3ScreenProfile
  @Published private(set) var previewA: NSImage?
  @Published private(set) var previewB: NSImage?
  @Published private(set) var receipts: [S3Screen: S3PushReceipt] = [:]
  @Published private(set) var statusMessage = "示例布局已准备；请填写平台分配的沙箱设备与模板。"
  @Published private(set) var isBusy = false
  @Published private(set) var connected = false
  @Published private(set) var sampleAt = Date()
  private let defaults: UserDefaults
  private let service: any S3SandboxServing
  private var credential: S3SandboxCredential?
  private var operation: Task<Void, Never>?
  private var generation = 0
  private var policy = S3ScreenPushPolicy()
  private var pngs: [S3Screen: Data] = [:]
  var canPush: Bool { connected && credential != nil && !isBusy }

  init(defaults: UserDefaults = PulsePreferences.shared, service: any S3SandboxServing = S3SandboxService()) {
    self.defaults = defaults; self.service = service
    var restored = defaults.data(forKey: "s3Sandbox.target").flatMap { try? JSONDecoder().decode(S3SandboxTarget.self, from: $0) } ?? .init()
    // Confirmation is scoped to a connection; never restore a prior user's assertion silently.
    restored.confirmedSandbox = false; target = restored
    profileA = defaults.data(forKey: "s3Sandbox.profileA").flatMap { try? JSONDecoder().decode(S3ScreenProfile.self, from: $0) }.flatMap { $0.isValid ? $0 : nil } ?? .init(monochrome: true)
    profileB = defaults.data(forKey: "s3Sandbox.profileB").flatMap { try? JSONDecoder().decode(S3ScreenProfile.self, from: $0) }.flatMap { $0.isValid ? $0 : nil } ?? .init()
    policy = defaults.data(forKey: "s3Sandbox.pushPolicy").flatMap { try? JSONDecoder().decode(S3ScreenPushPolicy.self, from: $0) } ?? .init()
    refreshPreviews()
  }
  func configure(target: S3SandboxTarget, a: S3ScreenProfile, b: S3ScreenProfile) {
    guard a.isValid, b.isValid else { statusMessage = "布局支持宽 400–1600、高 300–1200 像素；请按实际硬件规格填写。"; return }
    disconnect(); self.target = target; profileA = .init(width: a.width, height: a.height, monochrome: true); profileB = b
    defaults.set(try? JSONEncoder().encode(target), forKey: "s3Sandbox.target")
    defaults.set(try? JSONEncoder().encode(profileA), forKey: "s3Sandbox.profileA")
    defaults.set(try? JSONEncoder().encode(profileB), forKey: "s3Sandbox.profileB")
    refreshPreviews(); statusMessage = "配置已应用。填写本次沙箱凭据后连接。"
  }
  func connect(_ value: String) {
    guard !isBusy else { return }
    do {
      try target.validate(); let key = try S3SandboxCredential(value)
      run { model in
        _ = try await model.service.device(target: model.target, credential: key)
        try Task.checkCancellation()
        model.credential = key; model.connected = true
        model.statusMessage = "测试设备已读取；可分别推送 A、B 屏示例。平台受理不代表实机已显示。"
      }
    } catch { statusMessage = message(error) }
  }
  func disconnect() {
    generation += 1; operation?.cancel(); operation = nil; isBusy = false
    credential = nil; connected = false; receipts = [:]
    statusMessage = "连接已断开，沙箱凭据已从本次会话清除。"
    // Preserve screen cooldowns even when reconnecting or changing configuration.
  }
  func refreshPreviews(at now: Date = Date()) {
    guard !isBusy else { return }
    do {
      let sample = EInkPresentation.sample(at: now)
      for screen in S3Screen.allCases {
        let layout = try S3DualScreenLayout(sample: sample, screen: screen, profile: profile(for: screen))
        pngs[screen] = try S3DualScreenRenderer.png(layout)
      }
      previewA = pngs[.a].flatMap(NSImage.init(data:)); previewB = pngs[.b].flatMap(NSImage.init(data:)); sampleAt = now
    } catch { statusMessage = message(error) }
  }
  func push(_ screen: S3Screen, at now: Date = Date()) {
    guard canPush, let credential, let png = pngs[screen] else { return }
    do { try policy.validate(screen, at: now) } catch { statusMessage = message(error); return }
    // A timeout/cancellation may occur after the server queued B. Reserve its interval before starting.
    policy.started(screen, at: now)
    persistPolicy()
    let target = target, profile = profile(for: screen), sample = EInkPresentation.sample(at: sampleAt)
    run { model in
      do {
        let receipt = try await model.service.publish(png: png, sample: sample, screen: screen, profile: profile, target: target, credential: credential)
        try Task.checkCancellation()
        model.receipts[screen] = receipt; model.policy.succeeded(screen, at: receipt.acceptedAt)
        model.persistPolicy()
        model.statusMessage = "\(screen.rawValue) 屏示例已获平台受理；等待设备显示验证。"
      } catch {
        if !(error is CancellationError) { model.policy.failed(screen, at: Date()); model.persistPolicy() }
        throw error
      }
    }
  }
  func profile(for screen: S3Screen) -> S3ScreenProfile { screen == .a ? profileA : profileB }
  private func persistPolicy() { defaults.set(try? JSONEncoder().encode(policy), forKey: "s3Sandbox.pushPolicy") }
  func export(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let sample = EInkPresentation.sample(at: sampleAt)
    for screen in S3Screen.allCases {
      let layout = try S3DualScreenLayout(sample: sample, screen: screen, profile: profile(for: screen))
      try layout.svg().write(to: folder.appendingPathComponent("screen-\(screen.rawValue)-sample.svg"), options: .atomic)
      try S3DualScreenContract.encode(layout).write(to: folder.appendingPathComponent("screen-\(screen.rawValue)-layout.json"), options: .atomic)
      try S3DualScreenRenderer.png(layout).write(to: folder.appendingPathComponent("screen-\(screen.rawValue)-sample.png"), options: .atomic)
      let data = try S3TemplateData(sample: sample, screen: screen, profile: profile(for: screen))
      // Exports carry proposed IDs, no actual target, credential, or uploaded image URL.
      let content = try S3ContentRequest(template: "codex-pulse-\(screen.rawValue.lowercased())", screen: screen, data: data)
      try S3DualScreenContract.encode(content).write(to: folder.appendingPathComponent("screen-\(screen.rawValue)-request-proposal.json"), options: .atomic)
    }
  }
  func exportWithPanel() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    panel.prompt = "导出示例资料"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try export(to: url.appendingPathComponent("Codex-Pulse-S3-Sample-"+UUID().uuidString.prefix(8))); statusMessage = "双屏 PNG、SVG 和模板请求提案已导出。" }
    catch { statusMessage = "导出失败，请检查目标文件夹。" }
  }
  private func run(_ action: @escaping @MainActor (S3SandboxStore) async throws -> Void) {
    guard !isBusy else { return }; isBusy = true; let current = generation
    operation = Task { [weak self] in
      guard let self else { return }
      defer { if current == self.generation { self.isBusy = false; self.operation = nil } }
      do { try await action(self) }
      catch is CancellationError { }
      catch {
        guard current == self.generation else { return }
        self.statusMessage = self.message(error)
        if case S3SandboxError.http(let code) = error, code == 401 || code == 403 { self.credential = nil; self.connected = false }
      }
    }
  }
  private func message(_ error: Error) -> String { (error as? S3SandboxError)?.localizedDescription ?? "无法连接平台；本地示例和已受理的各屏结果仍保留。" }
}
