import Foundation

enum CodexAnalysisCommand {
  static func arguments(help: String, featureList: String, directory: String, model: String, effort: String) throws -> [String] {
    let available = Set(featureList.split(separator: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) })
    guard ["--ignore-user-config", "--ephemeral", "--output-schema", "--output-last-message"].allSatisfy(help.contains),
          available.contains("shell_tool"), available.contains("unified_exec"),
          model.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$"#, options: .regularExpression) != nil,
          ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort)
    else { throw LocalCodexAnalysisError.incompatibleCLI }
    var args = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
      "-C", directory, "-m", model, "-c", "model_reasoning_effort=\"\(effort)\"",
      "-c", "web_search=\"disabled\"", "-c", "approval_policy=\"never\""]
    if available.contains("skip_host_skill_discovery") { args += ["--enable", "skip_host_skill_discovery"] }
    for name in ["shell_tool", "unified_exec", "apps", "browser_use", "browser_use_external", "computer_use",
      "in_app_browser", "multi_agent", "memories", "chronicle", "hooks", "image_generation", "view_image",
      "workspace_dependencies", "goals", "artifact", "agent_message_board", "plugins"] where available.contains(name) {
      args += ["--disable", name]
    }
    return args
  }

  static func output(executable: URL, arguments: [String], directory: URL) throws -> String {
    let output = directory.appendingPathComponent(UUID().uuidString + ".probe")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = executable; process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = handle; process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(8)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
      process.terminate()
      let grace = Date().addingTimeInterval(1)
      while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      throw LocalCodexAnalysisError.incompatibleCLI
    }
    guard process.terminationStatus == 0, let data = try? Data(contentsOf: output),
          data.count <= 128_000, let result = String(data: data, encoding: .utf8)
    else { throw LocalCodexAnalysisError.incompatibleCLI }
    return result
  }
}
