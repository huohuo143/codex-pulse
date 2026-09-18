import CoreServices
import Foundation

public struct SessionFileEntry: Equatable, Sendable {
  public var url: URL
  public var modified: Date
  public var size: Int
  public var identity: String
}

/// FSEvents only marks paths. Enumeration and parsing run on the reader's worker.
/// A periodic reconciliation covers dropped events, unavailable roots and rotation.
public final class SessionFileIndex: @unchecked Sendable {
  private let roots: [URL]
  private let reconciliationInterval: TimeInterval
  private let lock = NSLock()
  private var dirtyPaths = Set<String>()
  private var needsReconciliation = true
  private var entries: [String: SessionFileEntry] = [:]
  private var lastReconciliation: Date?
  private var stream: FSEventStreamRef?
  public private(set) var revision = 0
  public private(set) var enumerationCount = 0
  public private(set) var metadataReadCount = 0
  public private(set) var lastActivityAt: Date?

  public init(roots: [URL], reconciliationInterval: TimeInterval = 300, watch: Bool = true) {
    self.roots = roots.map(\.standardizedFileURL)
    self.reconciliationInterval = reconciliationInterval
    if watch { startWatching() }
  }

  deinit {
    if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
  }

  public func markChanged(_ paths: [String] = []) {
    lock.lock(); defer { lock.unlock() }
    if paths.isEmpty { needsReconciliation = true }
    dirtyPaths.formUnion(paths)
  }

  public func read(at now: Date) -> [SessionFileEntry] {
    lock.lock()
    let reconcile = needsReconciliation || lastReconciliation.map { now.timeIntervalSince($0) >= reconciliationInterval } ?? true
    let dirty = dirtyPaths
    needsReconciliation = false
    dirtyPaths.removeAll()
    lock.unlock()
    guard reconcile || !dirty.isEmpty else { return Array(entries.values) }
    let previous = entries
    if reconcile {
      entries = [:]
      roots.forEach(scan)
      lastReconciliation = now
    } else {
      for path in dirty {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard roots.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else { continue }
        entries = entries.filter { $0.key != url.path && !$0.key.hasPrefix(url.path + "/") }
        if url.pathExtension == "jsonl" { register(url) } else { scan(url) }
      }
    }
    if entries != previous {
      revision += 1
      lastActivityAt = entries.values.map(\.modified).max()
    }
    return Array(entries.values)
  }

  private func scan(_ root: URL) {
    enumerationCount += 1
    guard let enumerator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
    for case let url as URL in enumerator where url.pathExtension == "jsonl" { register(url) }
  }

  private func register(_ candidate: URL) {
    let url = candidate.standardizedFileURL
    metadataReadCount += 1
    guard let info = try? FileManager.default.attributesOfItem(atPath: url.path),
          info[.type] as? FileAttributeType == .typeRegular else { return }
    let identity = "\(info[.systemNumber] ?? 0):\(info[.systemFileNumber] ?? 0):\((info[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    entries[url.path] = SessionFileEntry(url: url,
      modified: info[.modificationDate] as? Date ?? .distantPast,
      size: info[.size] as? Int ?? -1, identity: identity)
  }

  private func startWatching() {
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    stream = FSEventStreamCreate(nil, { _, context, count, paths, flags, _ in
      guard let context else { return }
      let owner = Unmanaged<SessionFileIndex>.fromOpaque(context).takeUnretainedValue()
      let values = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      let dropped = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 }
      owner.markChanged(dropped ? [] : values)
    }, &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "dev.codex.pulse.session-events", qos: .utility))
      if !FSEventStreamStart(stream) { markChanged() }
    }
  }
}

public struct SessionReadDiagnostics: Codable, Equatable, Sendable {
  public var parsedFiles = 0
  public var bytesRead = 0
  public var aggregations = 0
  public init() {}
}

public enum QuotaPollingPolicy {
  public static func interval(selected: TimeInterval, windowVisible: Bool, lastActivity: Date?, startedAt: Date, now: Date) -> TimeInterval {
    !windowVisible && now.timeIntervalSince(max(lastActivity ?? startedAt, startedAt)) >= 300 ? 120 : selected
  }
}
