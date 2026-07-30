#if !XCODE_WIDGET_BUILD
import CodexBalanceCore
#endif
import Foundation
import WidgetKit

struct CodexWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: CodexWidgetSnapshot
  let hasLiveData: Bool
}

struct CodexTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> CodexWidgetEntry {
    CodexWidgetEntry(date: Date(), snapshot: .preview, hasLiveData: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (CodexWidgetEntry) -> Void) {
    completion(loadEntry(usePreviewWhenMissing: context.isPreview))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CodexWidgetEntry>) -> Void) {
    let entry = loadEntry(usePreviewWhenMissing: false)
    let regularRefresh = Date().addingTimeInterval(15 * 60)
    let quotaResetDates = [
      entry.snapshot.resetsAt,
      entry.snapshot.displaysFiveHourQuota ? entry.snapshot.fiveHourResetsAt : nil
    ].compactMap { $0 }
    let resetRefresh = quotaResetDates.min().map { max(Date().addingTimeInterval(60), $0) }
    let nextRefresh = resetRefresh.map { min(regularRefresh, $0) } ?? regularRefresh
    completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
  }

  private func loadEntry(usePreviewWhenMissing: Bool) -> CodexWidgetEntry {
    if let snapshot = try? CodexWidgetSnapshotStore.load(
      from: CodexWidgetSnapshotStore.sandboxedWidgetURL()
    ) {
      return CodexWidgetEntry(date: Date(), snapshot: snapshot, hasLiveData: true)
    }
    return CodexWidgetEntry(
      date: Date(),
      snapshot: usePreviewWhenMissing ? .preview : .empty,
      hasLiveData: usePreviewWhenMissing
    )
  }
}
