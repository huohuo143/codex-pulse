import AppKit
import CodexBalanceCore
import SwiftUI

@MainActor
final class EInkDashboardStore: ObservableObject {
  @Published private(set) var devices: [XiaowuDevice] = []
  @Published private(set) var selectedDevice: XiaowuDevice?
  @Published private(set) var profile: EInkScreenProfile
  @Published private(set) var automaticSync = false
  @Published private(set) var isBusy = false
  @Published private(set) var statusMessage = "先预览示例，再登录小悟并读取绑定设备。"
  @Published private(set) var lastUploadAt: Date?
  @Published private(set) var localPreview: NSImage?
  @Published private(set) var cloudPreview: NSImage?
  @Published private(set) var sampleUploaded = false
  @Published private(set) var cloudPreviewVerified = false
  @Published private(set) var deviceVerified = false
  @Published private(set) var hasLiveSnapshot = false
  @Published var usesSampleData = true { didSet { refreshPreview() } }

  private let defaults: UserDefaults
  private let installationID: String
  private let session: XiaowuWebSession?
  private let service: any XiaowuCloudService
  private var snapshot: CodexWidgetSnapshot?
  private var account: String?
  private var receivedAccount = false
  private var generation = 0
  private var operation: Task<Void, Never>?
  private var policy = EInkSyncPolicy()
  private var previewAt: Date?
  private var previewAttention: String?
  private var previewPNG: Data?

  var canPublishRealData: Bool { selectedDevice != nil && deviceVerified && profile.canPublish && hasLiveSnapshot }
  var modeID: String? { selectedDevice.map { XiaowuCloudContract.modeID(installationID: installationID, mac: $0.mac) } }
  private var verificationKey: String { "\(selectedDevice?.mac ?? "")|\(profile.id)" }

  init(defaults: UserDefaults = PulsePreferences.shared, service: (any XiaowuCloudService)? = nil, allowAutomaticSync: Bool = true) {
    self.defaults = defaults
    let id = defaults.string(forKey: "eink.installationID") ?? UUID().uuidString
    installationID = id; defaults.set(id, forKey: "eink.installationID")
    if let data = defaults.data(forKey: "eink.profile"), let profile = try? JSONDecoder().decode(EInkScreenProfile.self, from: data), profile.isValid {
      self.profile = profile
    } else { profile = .init() }
    if let data = defaults.data(forKey: "eink.device"), let device = try? JSONDecoder().decode(XiaowuDevice.self, from: data), XiaowuCloudContract.validMAC(device.mac) {
      selectedDevice = device; devices = [device]
    }
    if let service { self.service = service; session = nil }
    else { let session = XiaowuWebSession(); self.session = session; self.service = XiaowuCloudPublisher(transport: session) }
    deviceVerified = defaults.string(forKey: "eink.verifiedDevice") == "\(selectedDevice?.mac ?? "")|\(profile.id)" && selectedDevice != nil
    automaticSync = allowAutomaticSync && deviceVerified && profile.canPublish && defaults.bool(forKey: "eink.automaticSync")
    lastUploadAt = defaults.object(forKey: "eink.lastUploadAt") as? Date
    usesSampleData = !deviceVerified
    refreshPreview()
  }

  func showLogin() { session?.showLogin() }
  func showConfiguration() { session?.showConfiguration() }

  func selectDevice(_ mac: String) {
    guard let device = devices.first(where: { $0.mac == mac }), device != selectedDevice else { return }
    invalidateTarget()
    selectedDevice = device
    defaults.set(try? JSONEncoder().encode(device), forKey: "eink.device")
    statusMessage = "设备已选择。请上传示例并验证云端预览与实机显示。"
  }
  func setProfile(_ value: EInkScreenProfile) {
    guard value.isValid else { statusMessage = value.compatibilityNote; return }
    guard value != profile else { return }
    invalidateTarget(); profile = value
    defaults.set(try? JSONEncoder().encode(value), forKey: "eink.profile")
    refreshPreview(); statusMessage = value.compatibilityNote
  }
  private func invalidateTarget() {
    stop(); policy = EInkSyncPolicy(); deviceVerified = false
    sampleUploaded = false; cloudPreviewVerified = false; cloudPreview = nil
    defaults.removeObject(forKey: "eink.verifiedDevice")
  }

  func ingest(_ value: CodexWidgetSnapshot, accountScope: String?, at now: Date = Date()) {
    let firstSnapshot = snapshot == nil
    let changedAccount = receivedAccount && accountScope != account
    if changedAccount {
      stop(); policy = EInkSyncPolicy(); cloudPreview = nil
      statusMessage = "Codex 账号已切换，自动同步已暂停。查看当前预览后可重新开启。"
    }
    if accountScope?.isEmpty == false { receivedAccount = true }
    account = accountScope; snapshot = value
    hasLiveSnapshot = accountScope?.isEmpty == false
    let presentation = EInkPresentation(snapshot: value, at: now)
    let previewDue = previewAt.map { now.timeIntervalSince($0) >= 60 } ?? true
    if !usesSampleData && (firstSnapshot || changedAccount || previewDue || presentation.attentionKey != previewAttention) {
      refreshPreview(at: now)
    }
    if automaticSync, canPublishRealData, !isBusy, policy.shouldPublish(presentation, at: now) { publishRealData() }
  }

  func setAutomaticSync(_ enabled: Bool) {
    if !enabled { stop(); statusMessage = "自动同步已关闭，云端保留末次画面。"; return }
    guard canPublishRealData else { statusMessage = "先选择设备、完成示例实机验证，并等待本机账号数据。"; return }
    automaticSync = true; defaults.set(true, forKey: "eink.automaticSync")
    usesSampleData = false; statusMessage = "自动同步已开启；每10分钟更新，重置状态变化时提前更新。"
    if !isBusy { publishRealData() }
  }
  func stop() {
    automaticSync = false; defaults.set(false, forKey: "eink.automaticSync")
    generation += 1; operation?.cancel(); operation = nil; isBusy = false
  }
  func suspend() {
    automaticSync = false
    generation += 1; operation?.cancel(); operation = nil; isBusy = false
  }

  func readDevices() {
    run { model in
      let devices = try await model.service.devices()
      try Task.checkCancellation()
      model.devices = devices
      if let selected = model.selectedDevice, !devices.contains(where: { $0.mac == selected.mac }) {
        model.invalidateTarget(); model.selectedDevice = nil; model.defaults.removeObject(forKey: "eink.device")
      }
      if model.selectedDevice == nil, let first = devices.first { model.selectDevice(first.mac) }
      model.statusMessage = devices.isEmpty ? "已登录，尚无绑定设备；请在小悟官方配置页绑定。" : "已读取 \(devices.count) 台绑定设备。"
    }
  }
  func uploadSample() {
    guard let device = selectedDevice, let modeID, profile.canPublish else { statusMessage = "请先选择设备和支持的屏幕规格。"; return }
    guard !isBusy else { return }
    stop(); sampleUploaded = false; cloudPreviewVerified = false; deviceVerified = false
    defaults.removeObject(forKey: "eink.verifiedDevice")
    let profile = profile
    run { model in
      let sample = EInkPresentation.sample()
      let png = try EInkRenderer.render(sample, profile: profile)
      _ = try await model.service.publish(png: png, device: device, profile: profile, modeID: modeID)
      try Task.checkCancellation()
      model.sampleUploaded = true; model.recordUpload()
      model.statusMessage = "示例模式已保存。请读取云端预览，再在小悟配置页选中“Codex 脉动”。"
    }
  }
  func fetchCloudPreview() {
    guard let device = selectedDevice, let modeID, sampleUploaded || deviceVerified else { return }
    let profile = profile
    run { model in
      let data = try await model.service.preview(device: device, profile: profile, modeID: modeID)
      try Task.checkCancellation()
      guard let image = NSImage(data: data) else { throw XiaowuCloudError.invalidImage }
      model.cloudPreview = image
      if model.sampleUploaded { model.cloudPreviewVerified = true }
      model.statusMessage = "云端预览已读取。请在墨水屏显示示例后，记录实机验证结果。"
    }
  }
  func confirmDeviceDisplayedSample() {
    guard sampleUploaded, cloudPreviewVerified, !isBusy, selectedDevice != nil else { return }
    deviceVerified = true; defaults.set(verificationKey, forKey: "eink.verifiedDevice")
    usesSampleData = false
    statusMessage = "已记录你确认的实机示例显示；现在可以同步真实看板。"
  }
  func publishRealData() {
    guard canPublishRealData, let snapshot, let device = selectedDevice, let modeID else { return }
    let profile = profile, value = EInkPresentation(snapshot: snapshot)
    run { model in
      let png = try EInkRenderer.render(value, profile: profile)
      let cloud = try await model.service.publish(png: png, device: device, profile: profile, modeID: modeID)
      try Task.checkCancellation()
      model.cloudPreview = NSImage(data: cloud); model.policy.succeeded(value, at: Date()); model.recordUpload()
      model.statusMessage = "真实看板已更新；屏幕下次唤醒且轮到该模式时显示。"
    }
  }
  private func recordUpload() {
    lastUploadAt = Date(); defaults.set(lastUploadAt, forKey: "eink.lastUploadAt")
  }

  private func run(_ action: @escaping @MainActor (EInkDashboardStore) async throws -> Void) {
    guard !isBusy else { return }
    isBusy = true; let current = generation
    operation = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == current { self.isBusy = false; self.operation = nil } }
      do { try await action(self) }
      catch is CancellationError { }
      catch {
        guard self.generation == current else { return }
        self.policy.failed(at: Date())
        self.statusMessage = (error as? XiaowuCloudError)?.localizedDescription ?? XiaowuCloudError.unavailable.localizedDescription
        if let cloudError = error as? XiaowuCloudError, [.loginRequired, .unsupported, .invalidDevice].contains(cloudError) {
          self.automaticSync = false; self.defaults.set(false, forKey: "eink.automaticSync")
        }
      }
    }
  }
  func refreshPreview(at now: Date = Date()) {
    let value = usesSampleData ? EInkPresentation.sample(at: now) : snapshot.map { EInkPresentation(snapshot: $0, at: now) } ?? EInkPresentation(snapshot: .empty, at: now)
    do {
      let board = try EInkRenderer.render(value, profile: profile)
      let preview = try EInkRenderer.devicePreview(board, profile: profile)
      previewPNG = preview; localPreview = NSImage(data: preview)
      previewAt = now; previewAttention = value.attentionKey
    } catch { statusMessage = "无法生成该尺寸预览，请检查屏幕规格。" }
  }
  func exportPreview() {
    guard let previewPNG else { return }
    let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "codex-pulse-eink-\(profile.id).png"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try previewPNG.write(to: url, options: .atomic); statusMessage = "预览已保存：\(url.lastPathComponent)" }
    catch { statusMessage = "预览保存失败，请选择可写入的位置。" }
  }
}
