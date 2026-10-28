import AppKit
import CodexBalanceCore
import SwiftUI
import Testing
import WidgetKit
@testable import CodexSuanliWidgets

@Suite("Quota history widget rendering", .serialized)
struct QuotaHistoryWidgetViewTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"] != nil))
  @MainActor func renderPeriodsFamiliesAndMissingData() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_PULSE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let now = Date()
    for scheme in [ColorScheme.light, .dark] {
      for family in [WidgetFamily.systemMedium, .systemLarge] {
        for days in [1, 7, 30] {
          var snapshot = CodexWidgetSnapshot.preview
          // Include an upward adjustment and an extended gap, as in the app.
          let rows: [QuotaSnapshot] = (0...(days * 24)).compactMap { index in
            if index % 72 > 26 && index % 72 < 44 { return nil }
            return .init(recordedAt: now.addingTimeInterval(Double(index - days * 24) * 3600),
              remainingPercent: 96 - Double(index % 72) * 1.1,
              resetsAt: now.addingTimeInterval(Double(index / 72 + 1) * 7 * 86400), windowMinutes: 10080)
          }
          snapshot.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: rows, now: now)
          try render(snapshot, now: now, days: days, family: family, scheme: scheme, state: "data", folder: folder)
        }
        for state in ["empty", "legacy", "expired", "single"] {
          var snapshot = CodexWidgetSnapshot.preview
          if state == "empty" { snapshot.quotaHistory = [] }
          if state == "legacy" { snapshot.quotaHistory = nil }
          if state == "expired" { snapshot = snapshot.effective(at: now.addingTimeInterval(7200)) }
          if state == "single" {
            snapshot.quotaHistory = QuotaHistoryTrend.widgetHistory(snapshots: [
              .init(recordedAt: now, remainingPercent: 65, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080)
            ], now: now)
          }
          try render(snapshot, now: state == "expired" ? now.addingTimeInterval(7200) : now,
            days: 7, family: family, scheme: scheme, state: state, folder: folder)
        }
      }
    }
    print("QUOTA_HISTORY_WIDGET rendered=28 output=\(folder.path)")
  }

  @MainActor private func render(_ snapshot: CodexWidgetSnapshot, now: Date, days: Int,
    family: WidgetFamily, scheme: ColorScheme, state: String, folder: URL) throws {
    let entry = CodexWidgetEntry(date: now, snapshot: snapshot, hasLiveData: true, quotaHistoryDays: days)
    let size = CGSize(width: 360, height: family == .systemLarge ? 376 : 170)
    let view = QuotaHistoryWidgetView(entry: entry)
      .environment(\.codexWidgetFamilyOverride, family).environment(\.colorScheme, scheme)
      .frame(width: size.width, height: size.height)
      .background(CodexWidgetBackground().environment(\.colorScheme, scheme))
    let renderer = ImageRenderer(content: view); renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    #expect(rep.pixelsWide == 720)
    let name = "quota-history-\(days)d-\(family)-\(scheme)-\(state).png"
    try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
  }
}
