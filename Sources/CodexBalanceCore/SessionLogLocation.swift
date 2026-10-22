import Foundation

enum SessionLogLocation {
  static func isCompressed(_ url: URL) -> Bool {
    url.lastPathComponent.hasSuffix(".jsonl.zst")
  }

  static func isSupported(_ url: URL) -> Bool {
    url.pathExtension == "jsonl" || isCompressed(url)
  }

  /// Codex rollout names carry a globally unique session UUID. Preserve this
  /// identity across compression and archive moves; arbitrary names remain
  /// scoped to their full path so unrelated logs never merge by basename.
  static func accountingIdentity(_ path: String) -> String {
    var url = URL(fileURLWithPath: path).standardizedFileURL
    if isCompressed(url) { url.deletePathExtension() }
    let stem = url.deletingPathExtension().lastPathComponent
    if stem.hasPrefix("rollout-"), stem.count > 44,
       let id = UUID(uuidString: String(stem.suffix(36))),
       stem.dropLast(36).hasSuffix("-") {
      return "session:" + id.uuidString.lowercased()
    }
    return "path:" + url.path
  }

  static func roots(in home: URL) -> [URL] {
    ["sessions", "archived_sessions"].map { home.appendingPathComponent($0) }
  }
}
