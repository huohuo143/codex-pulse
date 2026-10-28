import Foundation

public enum PulsePaths {
  public static var support: URL {
    if let path = ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter", isDirectory: true)
    return S3DualScreenContract.isCandidateBuild ? base.appendingPathComponent("S3SandboxCandidate", isDirectory: true) : base
  }
}

public enum PulsePreferences {
  public static var isIsolated: Bool { ProcessInfo.processInfo.environment["CODEX_PULSE_SUPPORT_DIR"] != nil || S3DualScreenContract.isCandidateBuild }
  public static var shared: UserDefaults {
    if let suite = ProcessInfo.processInfo.environment["CODEX_PULSE_PREFERENCES_SUITE"] { return UserDefaults(suiteName: suite) ?? .standard }
    if S3DualScreenContract.isCandidateBuild { return UserDefaults(suiteName: "dev.codex.balance-dashboard.s3sandbox") ?? .standard }
    return .standard
  }
}
