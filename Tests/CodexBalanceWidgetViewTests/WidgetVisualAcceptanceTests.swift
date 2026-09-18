import AppKit
import SwiftUI
import WidgetKit
import Testing
import CodexBalanceCore
@testable import CodexSuanliWidgets

@Suite("Seven widget visual acceptance", .serialized)
struct WidgetVisualAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  @MainActor func renderSevenKindsWithFreshAndExpiredData() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      for kind in CodexWidgetKind.allCases {
        let families: [WidgetFamily] = [.overview, .tokenTrend, .workload].contains(kind) ? [.systemMedium, .systemLarge] : [.systemSmall, .systemMedium]
        for family in families {
          let now = Date(); let snapshot = CodexWidgetSnapshot.preview.effective(at: now)
          let entry = CodexWidgetEntry(date: now, snapshot: snapshot, hasLiveData: true)
          try render(view(kind, entry), family: family, scheme: scheme,
            file: folder.appendingPathComponent("widget-\(kind.rawValue.split(separator: ".").last!)-\(family)-\(scheme).png"))
        }
        let later = Date().addingTimeInterval(86400)
        let expired = CodexWidgetSnapshot.preview.effective(at: later)
        #expect(expired.remainingPercent == nil)
        #expect(expired.resetCreditsAvailable == nil)
        #expect(expired.usageState(at: later).canDisplayValue == false)
        try render(view(kind, CodexWidgetEntry(date: later, snapshot: expired, hasLiveData: true)), family: .systemMedium, scheme: scheme,
          file: folder.appendingPathComponent("widget-\(kind.rawValue.split(separator: ".").last!)-expired-\(scheme).png"))
      }
      var partial = CodexWidgetSnapshot.preview
      partial.costMonthCoverage = 62
      partial.unpricedModels = ["future-model", "gpt-5.4-pro（缓存输入）"]
      let entry = CodexWidgetEntry(date: Date(), snapshot: partial, hasLiveData: true)
      try render(view(.tokenSummary, entry), family: .systemMedium, scheme: scheme,
        file: folder.appendingPathComponent("widget-token-summary-partial-\(scheme).png"))
      try render(view(.overview, entry), family: .systemLarge, scheme: scheme,
        file: folder.appendingPathComponent("widget-overview-partial-\(scheme).png"))
    }
    print("VISUAL_WIDGET rendered=46 output=\(folder.path)")
  }
  @MainActor private func view(_ kind: CodexWidgetKind, _ entry: CodexWidgetEntry) -> AnyView {
    switch kind {
    case .overview: AnyView(CodexOverviewWidgetView(entry: entry))
    case .quota: AnyView(QuotaWidgetView(entry: entry))
    case .radar: AnyView(RadarWidgetView(entry: entry))
    case .resetCredits: AnyView(ResetCreditsWidgetView(entry: entry))
    case .tokenSummary: AnyView(TokenSummaryWidgetView(entry: entry))
    case .tokenTrend: AnyView(TokenTrendWidgetView(entry: entry))
    case .workload: AnyView(WorkloadWidgetView(entry: entry))
    }
  }
  @MainActor private func render(_ view: AnyView, family: WidgetFamily, scheme: ColorScheme, file: URL) throws {
    let size = family == .systemSmall ? CGSize(width: 170, height: 170) : family == .systemMedium ? CGSize(width: 360, height: 170) : CGSize(width: 360, height: 376)
    let renderer = ImageRenderer(content: view.environment(\.codexWidgetFamilyOverride, family).environment(\.colorScheme, scheme).frame(width: size.width, height: size.height).background(CodexWidgetBackground().environment(\.colorScheme, scheme)))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    #expect(rep.pixelsWide == Int(size.width * 2))
    try #require(rep.representation(using: .png, properties: [:])).write(to: file)
  }
}
