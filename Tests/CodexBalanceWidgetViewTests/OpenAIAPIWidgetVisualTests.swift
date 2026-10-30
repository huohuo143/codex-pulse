import AppKit
import CodexBalanceCore
import SwiftUI
import Testing
import WidgetKit
@testable import CodexSuanliWidgets

@Suite("OpenAI API widget rendering", .serialized)
struct OpenAIAPIWidgetVisualTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  @MainActor func renderConnectedAndPendingInBothSizes() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let now = Date()
    let connected = OpenAIAPIWidgetSnapshot(publishedAt: now, isConnected: true, monthlyCostUSD: 12.34,
      periodStart: OpenAIAPIUsageReader.monthStart(at: now), costSampledAt: now, status: "ok",
      grantTotalUSD: 200, grantRemainingUSD: 150, grantCheckedAt: now, grantExpiresAt: nil)
    var dueSoon = connected
    dueSoon.grantExpiresAt = now.addingTimeInterval(2 * 86400 + 5 * 3600)
    dueSoon.grantExpiryConfirmedAt = now
    var expired = dueSoon
    expired.grantExpiresAt = now.addingTimeInterval(-60)
    for scheme in [ColorScheme.light, .dark] {
      for family in [WidgetFamily.systemSmall, .systemMedium] {
        for (state, value) in [("pending", OpenAIAPIWidgetSnapshot.empty), ("connected", connected), ("due-soon", dueSoon), ("expired", expired)] {
          let size = family == .systemSmall ? CGSize(width: 170, height: 170) : CGSize(width: 360, height: 170)
          let view = OpenAIAPIWidgetView(entry: OpenAIAPIWidgetEntry(date: now, snapshot: value))
            .environment(\.codexWidgetFamilyOverride, family).environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
            .background(CodexWidgetBackground().environment(\.colorScheme, scheme))
          let renderer = ImageRenderer(content: view); renderer.scale = 2
          let image = try #require(renderer.nsImage)
          let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
          let data = try #require(rep.representation(using: .png, properties: [:]))
          try data.write(to: folder.appendingPathComponent("api-widget-\(state)-\(family)-\(scheme).png"))
        }
      }
    }
  }
}
