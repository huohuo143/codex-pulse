import Foundation
import Darwin

enum CodexWatcherManager {
  private static let label = "dev.codex.balance-dashboard.codex.watch-codex"

  private static var applicationSupportURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexSuanliMeter", isDirectory: true)
  }

  private static var scriptURL: URL {
    applicationSupportURL.appendingPathComponent("watch-codex.sh")
  }

  private static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  static func isEnabled() -> Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
  }

  static func setEnabled(_ enabled: Bool, appURL: URL) throws {
    if enabled {
      try install(appURL: appURL)
    } else {
      try uninstall()
    }
  }

  static func refreshIfEnabled(appURL: URL) throws {
    guard isEnabled(), isInstalledAppLocation(appURL) else { return }
    if isCurrentInstallation(appURL: appURL) {
      return
    }
    try install(appURL: appURL)
  }

  /// Automatic launch-agent repair must only trust a real installation.
  /// Development, dist and UI-validation bundles can share the same watcher
  /// code but must never redirect automatic startup into a project directory.
  private static func isInstalledAppLocation(_ appURL: URL) -> Bool {
    let path = appURL.standardizedFileURL.path
    let homeApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications/Codex 脉动.app", isDirectory: true)
      .standardizedFileURL.path
    let legacyHomeApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications/Codex算力码表.app", isDirectory: true)
      .standardizedFileURL.path
    return path == "/Applications/Codex 脉动.app"
      || path == homeApplicationsPath
      || path == "/Applications/Codex算力码表.app"
      || path == legacyHomeApplicationsPath
  }

  private static func install(appURL: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let script = watcherScript(appPath: appURL.standardizedFileURL.path)
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let plist = launchAgentPlist(scriptPath: scriptURL.path)
    try plist.write(to: plistURL, atomically: true, encoding: .utf8)

    _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
    _ = runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
  }

  private static func uninstall() throws {
    _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: plistURL.path) {
      try fileManager.removeItem(at: plistURL)
    }
    if fileManager.fileExists(atPath: scriptURL.path) {
      try fileManager.removeItem(at: scriptURL)
    }
  }

  private static func watcherScript(appPath: String) -> String {
    """
    #!/bin/zsh
    set -u

    APP_PATH=\(shellQuote(appPath))
    BUILD_LOCK="$HOME/Library/Application Support/CodexSuanliMeter/build.lock"
    WATCH_LOCK_DIR="$HOME/Library/Application Support/CodexSuanliMeter/watch.lock"
    BUNDLE_ID="dev.codex.balance-dashboard.codex"

    if ! /bin/mkdir "$WATCH_LOCK_DIR" 2>/dev/null; then
      exit 0
    fi
    trap '/bin/rmdir "$WATCH_LOCK_DIR" 2>/dev/null || true' EXIT

    resolve_dashboard_app() {
      local candidates=(
        "$APP_PATH"
        "$HOME/Desktop/Codex 脉动.app"
        "$HOME/Applications/Codex 脉动.app"
        "/Applications/Codex 脉动.app"
        "$HOME/Desktop/Codex算力码表.app"
        "$HOME/Applications/Codex算力码表.app"
        "/Applications/Codex算力码表.app"
      )

      local candidate
      for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
          print -r -- "$candidate"
          return 0
        fi
      done

      /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" | /usr/bin/head -n 1
    }

    is_codex_running() {
      /usr/bin/pgrep -f "Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 ||
        /usr/bin/pgrep -x "Codex" >/dev/null 2>&1 ||
        /usr/bin/pgrep -f "Contents/Resources/codex app-server" >/dev/null 2>&1
    }

    while true; do
      if is_codex_running; then
        if [[ -e "$BUILD_LOCK" ]]; then
          NOW=$(/bin/date +%s)
          MODIFIED=$(/usr/bin/stat -f %m "$BUILD_LOCK" 2>/dev/null || echo 0)
          if (( NOW - MODIFIED < 300 )); then
            /bin/sleep 5
            continue
          fi
          /bin/rm -f "$BUILD_LOCK"
        elif ! /usr/bin/pgrep -x "CodexSuanliMeter" >/dev/null 2>&1; then
          DASHBOARD_APP="$(resolve_dashboard_app)"
          if [[ -n "$DASHBOARD_APP" ]]; then
            /usr/bin/open -g "$DASHBOARD_APP" --args --background
          fi
        fi
      fi
      /bin/sleep 5
    done
    """
  }

  private static func launchAgentPlist(scriptPath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(label)</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/zsh</string>
        <string>\(escapeXML(scriptPath))</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>StandardOutPath</key>
      <string>/tmp/\(label).out.log</string>
      <key>StandardErrorPath</key>
      <string>/tmp/\(label).err.log</string>
    </dict>
    </plist>
    """
  }

  private static func runLaunchctl(arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    } catch {
      return -1
    }
  }

  private static func isCurrentInstallation(appURL: URL) -> Bool {
    guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
      return false
    }

    let appPath = appURL.standardizedFileURL.path
    return script.contains("APP_PATH=\(shellQuote(appPath))") &&
      script.contains("resolve_dashboard_app()") &&
      script.contains("is_codex_running()") &&
      script.contains("WATCH_LOCK_DIR=") &&
      script.contains("--background")
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func escapeXML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
