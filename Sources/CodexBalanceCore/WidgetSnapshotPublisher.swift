import Foundation

/// Serializes file work away from UI, merges identical updates and preserves a minute heartbeat.
public actor WidgetSnapshotPublisher {
  private var previous: CodexWidgetSnapshot?
  private var lastWrite: Date?
  private var lastLiveWrite: Date?
  private var lastLiveContent: Data?
  private let urls: [URL]
  private let liveURL: URL
  public init(urls: [URL] = [CodexWidgetSnapshotStore.defaultURL(), CodexWidgetSnapshotStore.widgetContainerURL()],
              liveURL: URL = PulsePaths.support.appendingPathComponent("live-balance.json")) {
    self.urls = urls; self.liveURL = liveURL
  }

  public func publish(_ snapshot: CodexWidgetSnapshot) throws -> Set<CodexWidgetKind> {
    let changed = !snapshot.affectedKinds(comparedTo: previous).isEmpty
    guard changed || lastWrite.map({ snapshot.updatedAt.timeIntervalSince($0) >= 60 }) ?? true else { return [] }
    for url in urls { try CodexWidgetSnapshotStore.save(snapshot, to: url) }
    let affected = snapshot.affectedKinds(comparedTo: previous)
    previous = snapshot; lastWrite = snapshot.updatedAt
    return affected
  }

  public func publishLive(_ data: Data) {
    let now = Date()
    var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    object.removeValue(forKey: "updatedAt"); object.removeValue(forKey: "statsUpdatedAt")
    let content = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard content != lastLiveContent || lastLiveWrite.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
    lastLiveContent = content; lastLiveWrite = now
    try? FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: liveURL, options: .atomic)
  }
}
