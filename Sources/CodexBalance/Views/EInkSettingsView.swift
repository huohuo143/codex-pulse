import CodexBalanceCore
import SwiftUI

struct EInkSettingsView: View {
  @ObservedObject var model: EInkDashboardStore
  @State private var width = "400"
  @State private var height = "300"
  @State private var customDimensions = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Mac 提供数据，小悟云保存画面，墨水屏通过 Wi-Fi 显示。新增独立的“Codex 脉动”模式，可在小悟配置页单独选中或加入轮播。")
        .font(.callout)
      HStack {
        Button("登录小悟", systemImage: "person.crop.circle") { model.showLogin() }.disabled(model.isBusy)
        Button("读取绑定设备", systemImage: "arrow.clockwise") { model.readDevices() }.disabled(model.isBusy)
        Button("小悟设备配置", systemImage: "rectangle.3.group") { model.showConfiguration() }.disabled(model.isBusy)
      }
      if model.devices.isEmpty {
        Text("尚未读取绑定设备；登录后点击“读取绑定设备”。").font(.caption).foregroundStyle(.secondary)
      } else {
        Picker("显示设备", selection: Binding(get: { model.selectedDevice?.mac ?? "" }, set: model.selectDevice)) {
          ForEach(model.devices) { device in Text(device.title).tag(device.mac) }
        }.disabled(model.isBusy)
      }
      HStack {
        Picker("屏幕", selection: Binding(get: {
          !customDimensions && EInkScreenProfile.presets.contains { $0.width == model.profile.width && $0.height == model.profile.height } ? model.profile.title : "custom"
        }, set: { title in
          customDimensions = title == "custom"
          if let value = EInkScreenProfile.presets.first(where: { $0.title == title }) {
            model.setProfile(.init(width: value.width, height: value.height, colors: model.profile.colors)); updateDimensions()
          }
        })) {
          ForEach(EInkScreenProfile.presets) { Text($0.title).tag($0.title) }
          Text("自定义尺寸").tag("custom")
        }
        Picker("屏幕色彩", selection: Binding(get: { model.profile.colors }, set: { colors in
          model.setProfile(.init(width: model.profile.width, height: model.profile.height, colors: colors))
        })) {
          Text("黑白").tag(2); Text("三色").tag(3); Text("四色").tag(4); Text("六色（待验证）").tag(6)
        }
      }.disabled(model.isBusy)
      HStack {
        TextField("宽（像素）", text: $width).frame(width: 100)
        Text("×")
        TextField("高（像素）", text: $height).frame(width: 100)
        Button("应用尺寸") {
          model.setProfile(.init(width: Int(width) ?? 0, height: Int(height) ?? 0, colors: model.profile.colors))
        }
        Spacer()
      }.disabled(model.isBusy)
      Text(model.profile.compatibilityNote).font(.caption).foregroundStyle(.secondary)
      HStack {
        Picker("本地预览", selection: $model.usesSampleData) {
          Text("示例数据").tag(true); Text("当前账号数据").tag(false)
        }.pickerStyle(.segmented).frame(maxWidth: 300)
        Button("刷新预览") { model.refreshPreview() }
        Button("导出 PNG") { model.exportPreview() }
      }
      if let image = model.localPreview {
        Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
          .frame(maxWidth: 640).border(Color.secondary.opacity(0.4))
          .accessibilityLabel("墨水屏本地预览：总览、重置预告、7天额度历史")
      }
      Text("本地预览中的小悟页眉、页脚为占位区域；实际天气、电量和时间由小悟云绘制。画面为白底黑字。")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      HStack {
        Button("1. 上传示例看板") { model.uploadSample() }
          .disabled(model.isBusy || model.selectedDevice == nil || !model.profile.canPublish)
        Button("2. 读取云端预览") { model.fetchCloudPreview() }
          .disabled(model.isBusy || !(model.sampleUploaded || model.deviceVerified))
      }
      if let image = model.cloudPreview {
        Text("小悟云返回的预览").font(.caption).bold()
        Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(maxWidth: 640)
          .border(Color.secondary.opacity(0.4))
      }
      Button(model.deviceVerified ? "已记录实机示例显示" : "3. 我已在墨水屏看到示例") { model.confirmDeviceDisplayedSample() }
        .disabled(model.isBusy || !model.sampleUploaded || !model.cloudPreviewVerified || model.deviceVerified)
      HStack {
        Toggle("每10分钟同步真实看板", isOn: Binding(get: { model.automaticSync }, set: model.setAutomaticSync))
          .disabled(!model.canPublishRealData || model.isBusy)
        Spacer()
        Button("立即同步真实看板") { model.publishRealData() }.disabled(!model.canPublishRealData || model.isBusy)
        if model.isBusy { ProgressView().controlSize(.small) }
      }
      if model.automaticSync { Button("暂停同步") { model.setAutomaticSync(false) } }
      Text(model.statusMessage).font(.callout).textSelection(.enabled)
      if let date = model.lastUploadAt {
        Text("最近上传：\(EInkFormat.date(date, full: true))（北京时间）").font(.caption).foregroundStyle(.secondary)
      }
      Text("上传范围：额度百分比、24h Token 汇总、重置状态与期限、Full reset 次数、7天额度曲线和更新时间。云端图片使用随机链接访问，不能视为私密存储；模式不会发布到模式广场。")
        .font(.caption).foregroundStyle(.secondary)
      Text("Mac 休眠后保留末次快照，倒计时以画面生成时刻为准；上屏时间取决于设备唤醒和轮播。7/10英寸全彩、双屏及NFC/蓝牙机型仍需逐型号验证。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { updateDimensions() }
  }
  private func updateDimensions() { width = String(model.profile.width); height = String(model.profile.height) }
}
