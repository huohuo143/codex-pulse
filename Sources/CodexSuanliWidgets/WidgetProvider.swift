#if !XCODE_WIDGET_BUILD
import CodexBalanceCore
#endif
import Foundation
import WidgetKit

struct CodexWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: CodexWidgetSnapshot
  let hasLiveData: Bool
  var quotaHistoryDays: Int = 7
}

struct CodexTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> CodexWidgetEntry {
    CodexWidgetEntry(date: Date(), snapshot: .preview, hasLiveData: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (CodexWidgetEntry) -> Void) {
    let entry = loadEntry(usePreviewWhenMissing: context.isPreview)
    completion(CodexWidgetEntry(date: entry.date, snapshot: entry.snapshot.effective(at: entry.date), hasLiveData: entry.hasLiveData))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CodexWidgetEntry>) -> Void) {
    let entry = loadEntry(usePreviewWhenMissing: false)
    let now = entry.date
    let entries = entry.snapshot.timelineDates(after: now).map {
      CodexWidgetEntry(date: $0, snapshot: entry.snapshot.effective(at: $0), hasLiveData: entry.hasLiveData)
    }
    completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(entry.hasLiveData ? 300 : 60))))
  }

  func loadEntry(usePreviewWhenMissing: Bool) -> CodexWidgetEntry {
    if let snapshot = try? CodexWidgetSnapshotStore.load(
      from: CodexWidgetSnapshotStore.sandboxedWidgetURL()
    ) {
      let now = Date()
      if CodexWidgetSnapshotFreshness.isFromCurrentBoot(snapshot, now: now) {
        return CodexWidgetEntry(date: now, snapshot: snapshot, hasLiveData: snapshot.schemaVersion >= 4)
      }
      return CodexWidgetEntry(date: now, snapshot: .empty, hasLiveData: false)
    }
    return CodexWidgetEntry(
      date: Date(),
      snapshot: usePreviewWhenMissing ? .preview : .empty,
      hasLiveData: usePreviewWhenMissing
    )
  }
}

struct OpenAIAPIWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: OpenAIAPIWidgetSnapshot
}

struct OpenAIAPIWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> OpenAIAPIWidgetEntry {
    OpenAIAPIWidgetEntry(date: Date(), snapshot: .empty)
  }

  func getSnapshot(in context: Context, completion: @escaping (OpenAIAPIWidgetEntry) -> Void) {
    completion(OpenAIAPIWidgetEntry(date: Date(), snapshot: (try? OpenAIAPIWidgetSnapshotStore.load()) ?? .empty))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<OpenAIAPIWidgetEntry>) -> Void) {
    let now = Date()
    let snapshot = (try? OpenAIAPIWidgetSnapshotStore.load()) ?? .empty
    let entries = snapshot.timelineDates(after: now).map { OpenAIAPIWidgetEntry(date: $0, snapshot: snapshot) }
    completion(Timeline(entries: entries,
                        policy: .after(now.addingTimeInterval(300))))
  }
}
