import AppKit
import SidebarCore
import SwiftUI

struct SidebarStatusView: View {
  @ObservedObject var model: SidebarModel
  @ObservedObject private var api = OpenAIAPIUsageStore.shared
  private var remaining: Double? { model.isAccountCurrent ? model.account?.remaining : nil }
  private var band: QuotaBand { QuotaBand.classify(remaining) }
  private var radar: RadarDisplay { RadarDisplay.resolve(model.radar, now: model.now) }
  private var tint: Color { QuotaRingStyle.color(for: remaining) }
  private var radarTint: Color {
    switch radar.kind {
    case .announced: return Color(red: 0.77, green: 0.45, blue: 0.16)
    case .completed: return Color(red: 0.16, green: 0.58, blue: 0.47)
    case .waiting: return .secondary
    case .stale: return .secondary.opacity(0.75)
    }
  }
  private var creditText: String {
    guard model.isAccountCurrent else { return "—" }
    if model.account?.unlimited == true { return "∞" }
    return SidebarFormat.credits(model.account?.balance)
  }
  private var resetText: String {
    guard model.isAccountCurrent, let count = model.account?.resetCount else { return "—" }
    return "\(count) 次"
  }
  private var accessibleSummary: String {
    var parts: [String] = []
    if model.visibility.quota { parts.append("七天剩余 \(SidebarFormat.percentage(remaining))") }
    if model.visibility.radar { parts.append("Tibo \(radar.title)") }
    if model.visibility.credits { parts.append("Credits 余额 \(creditText)") }
    if model.visibility.reset { parts.append("Full reset 可用 \(resetText)") }
    if model.visibility.apiUsage {
      let expiry = api.grantExpiry.map { "账单到期 \($0.longDate)，\($0.countdown(at: model.now))" } ?? "到期时间待确认"
      parts.append("API 本月消费 \(api.costText)，赠额余额 \(api.grantText)，\(expiry)，赠额信息为手动确认")
    }
    return parts.isEmpty ? "侧栏内容已隐藏" : "Codex " + parts.joined(separator: "，")
  }

  var body: some View {
    VStack(spacing: 0) {
      if model.visibility.quota { quotaSection }
      if model.visibility.radar {
        if model.visibility.quota { separator.padding(.top, 9).padding(.bottom, 8) }
        radarSection
      }
      if model.visibility.credits {
        if model.visibility.quota || model.visibility.radar { separator.padding(.top, 9).padding(.bottom, 8) }
        creditsSection
      }
      if model.visibility.reset {
        if model.visibility.quota || model.visibility.radar || model.visibility.credits {
          separator.padding(.top, 9).padding(.bottom, 8)
        }
        resetSection
      }
      if model.visibility.apiUsage {
        if model.visibility.quota || model.visibility.radar || model.visibility.credits || model.visibility.reset {
          separator.padding(.top, 9).padding(.bottom, 8)
        }
        apiSection
      }
    }
    .frame(width: 52)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibleSummary)
  }

  private var quotaSection: some View {
    VStack(spacing: 0) {
      ZStack {
        // The faint track shows the used share; the colored arc is remaining.
        Circle().stroke(Color.primary.opacity(0.11), lineWidth: 4.2)
        if let remaining, band != .unavailable, remaining > 0 {
          Circle().trim(from: 0, to: min(1, remaining / 100))
            .stroke(tint, style: StrokeStyle(lineWidth: 4.2, lineCap: .butt))
            .rotationEffect(.degrees(-90))
        }
        Text(SidebarFormat.percentage(remaining))
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .monospacedDigit()
          .minimumScaleFactor(0.66).lineLimit(1)
          .foregroundStyle(remaining == 0 ? tint : Color.primary.opacity(0.88))
          .frame(width: 30)
      }
      .frame(width: 37, height: 37)
      Text(model.isAccountCurrent ? "7天剩余" : "等待更新")
        .font(.system(size: 7.2, weight: .medium)).foregroundStyle(.secondary)
        .lineLimit(1).padding(.top, 3)
    }
  }

  private var radarSection: some View {
    VStack(spacing: 0) {
      HStack(spacing: 2) {
        Circle().fill(radarTint).frame(width: 3.5, height: 3.5)
        Text("TIBO").tracking(0.5)
      }
      .font(.system(size: 7.3, weight: .semibold)).foregroundStyle(.secondary)
      Text(radar.title)
        .font(.system(size: 8.7, weight: .semibold)).foregroundStyle(radarTint)
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(radarTint.opacity(0.11), in: Capsule())
        .padding(.top, 3)
      if let detail = radar.detail {
        Text(detail.replacingOccurrences(of: " ", with: "\n"))
          .font(.system(size: 7, weight: .medium, design: .rounded))
          .multilineTextAlignment(.center).foregroundStyle(.secondary)
          .lineSpacing(0).padding(.top, 2)
      }
    }
  }

  private var creditsSection: some View {
    VStack(spacing: 0) {
      Text("CREDITS").tracking(0.3)
        .font(.system(size: 6.8, weight: .semibold)).foregroundStyle(.secondary)
      Text(creditText)
        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.65)
        .foregroundStyle(Color.primary.opacity(0.84)).padding(.top, 3)
    }
  }

  private var resetSection: some View {
    VStack(spacing: 0) {
      Text("FULL RESET").tracking(0.12)
        .font(.system(size: 6.5, weight: .semibold)).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.8)
      Text(resetText)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .monospacedDigit().foregroundStyle(Color.primary.opacity(0.84)).padding(.top, 3)
    }
  }

  private var apiSection: some View {
    VStack(spacing: 0) {
      Text(api.isCostStale ? "API 上次" : "API 本月").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
      Text(api.costText).font(.system(size: 8.5, weight: .semibold, design: .rounded))
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        .foregroundStyle(Color.primary.opacity(0.84)).padding(.top, 3)
      Text(api.grant == nil ? "赠额待确认" : "赠额* \(api.grantText)")
        .font(.system(size: 6.8, weight: .medium)).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 3)
      if let expiry = api.grantExpiry {
        Text("到期 \(expiry.shortDate)").font(.system(size: 6.6, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
        Text(expiry.compactCountdown(at: model.now))
          .font(.system(size: 7.2, weight: .semibold))
          .foregroundStyle(expiry.expiresAt.timeIntervalSince(model.now) <= 3 * 86400 ? Color.orange : Color.secondary)
          .lineLimit(1).minimumScaleFactor(0.75).padding(.top, 3)
      } else {
        Text("到期待确认").font(.system(size: 6.6, weight: .medium))
          .foregroundStyle(.secondary).lineLimit(1).padding(.top, 4)
      }
    }
  }

  private var separator: some View {
    Capsule().fill(Color.primary.opacity(0.11)).frame(width: 18, height: 0.6)
  }
}

/// The preview is our own mock window; it does not inspect Codex's UI.
struct CodexSidebarPreviewView: View {
  @ObservedObject var model: SidebarModel
  var usesTrackedPanel = false
  var movePreview: (() -> Void)? = nil
  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        Spacer()
        if usesTrackedPanel {
          Color.clear.frame(width: 52, height: 300)
        } else {
          SidebarStatusView(model: model)
        }
        Spacer().frame(height: 20)
        Text("ZS").font(.system(size: 10)).foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(Circle().fill(Color(red: 0.48, green: 0.54, blue: 0.54)))
          .padding(.bottom, 16)
      }
      .frame(width: 54)
      .frame(maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
      VStack(alignment: .leading, spacing: 10) {
        Text("布局预览").font(.system(size: 19, weight: .semibold))
        Text("以当前额度和重置状态展示，侧栏位置为示意。")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Text("额度环随剩余比例变色。Credits 是账户余额；Full reset 是可用次数。")
          .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
        Text("API 消费按月读取；赠额与到期时间以账单手动确认为准。")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Text("侧栏显示内容").font(.system(size: 12, weight: .semibold)).padding(.top, 6)
        Toggle("七天额度", isOn: binding(\.quota))
        Toggle("Tibo 重置状态", isOn: binding(\.radar))
        Toggle("Credits 余额", isOn: binding(\.credits))
        Toggle("Full reset 次数", isOn: binding(\.reset))
        Toggle("API 用量与赠额", isOn: binding(\.apiUsage))
        if usesTrackedPanel {
          Text("模拟窗口跟随测试：\(model.previewTrackingStatus)")
            .font(.system(size: 12)).foregroundStyle(.secondary)
          Text("移动验证：\(model.previewMoveResult)")
            .font(.system(size: 12)).foregroundStyle(.secondary)
          Button("移动模拟窗口") { movePreview?() }
        }
        Spacer()
      }
      .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .controlBackgroundColor))
    }
    .frame(width: 650, height: 430)
  }

  private func binding(_ key: WritableKeyPath<SidebarVisibility, Bool>) -> Binding<Bool> {
    Binding(get: { model.visibility[keyPath: key] }, set: { value in
      var next = model.visibility; next[keyPath: key] = value; model.setVisibility(next)
    })
  }
}
