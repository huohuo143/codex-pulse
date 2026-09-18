import Foundation

public enum PulsePaths {
  public static var support: URL {
    if let path = ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter", isDirectory: true)
  }
}

public enum PulsePreferences {
  public static var isIsolated: Bool { ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"] != nil }
  public static var shared: UserDefaults {
    if let suite = ProcessInfo.processInfo.environment["CODEX_PULSE_PREFERENCES_SUITE"] { return UserDefaults(suiteName: suite) ?? .standard }
    return .standard
  }
}
