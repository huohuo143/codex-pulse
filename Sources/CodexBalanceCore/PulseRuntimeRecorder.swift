import Foundation

public struct PulseRuntimeEvent: Codable, Sendable {
  public var at: Date
  public var name: String
  public var metrics: [String: Double]
  public var labels: [String: String]
  public init(name: String, metrics: [String: Double] = [:], labels: [String: String] = [:], at: Date = Date()) {
    self.at = at; self.name = name; self.metrics = metrics; self.labels = labels
  }
}

/// Opt-in local acceptance trace: counters and source states only, no credentials or session content.
public actor PulseRuntimeRecorder {
  public static let shared = PulseRuntimeRecorder()
  public func record(_ event: PulseRuntimeEvent) {
    guard PulsePreferences.isIsolated else { return }
    let url = PulsePaths.support.appendingPathComponent("runtime-acceptance.jsonl")
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
      try handle.seekToEnd(); try handle.write(contentsOf: encoder.encode(event) + Data([10]))
    } catch { /* Optional acceptance instrumentation must not affect production behavior. */ }
  }
}
