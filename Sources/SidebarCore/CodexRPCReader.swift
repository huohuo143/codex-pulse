import Darwin
import CoreFoundation
import Foundation

/// Reads only the display fields needed by the sidebar. Raw responses and
/// account identifiers are never written to disk or included in diagnostics.
public enum CodexRateLimitParser {
  public static func sample(from result: [String: Any], at now: Date = Date()) -> AccountSample? {
    let legacy = result["rateLimits"] as? [String: Any] ?? [:]
    let byID = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
    let bucket = (byID["codex"] as? [String: Any]) ?? legacy
    let windows = [bucket["primary"], bucket["secondary"]].compactMap { $0 as? [String: Any] }
    let weekly = windows.first { number($0["windowDurationMins"]) == 10080 }
    let used = weekly.flatMap { number($0["usedPercent"]) }
    let remaining = used.flatMap { (0...100).contains($0) ? 100 - $0 : nil }
    let credits = (legacy["credits"] as? [String: Any]) ?? (bucket["credits"] as? [String: Any]) ?? [:]
    let balance = number(credits["balance"]).flatMap { $0 >= 0 ? $0 : nil }
    let unlimited = credits["unlimited"] as? Bool == true
    let reset = result["rateLimitResetCredits"] as? [String: Any] ?? [:]
    let resetNumber = number(reset["availableCount"])
    let resetCount = resetNumber.flatMap { $0 >= 0 && $0 <= 1_000_000 && $0.rounded(.down) == $0 ? Int($0) : nil }
    guard remaining != nil || balance != nil || unlimited || resetCount != nil else { return nil }
    return AccountSample(ok: true, remaining: remaining, balance: balance,
                         sampledAt: now.timeIntervalSince1970, unlimited: unlimited, resetCount: resetCount)
  }

  private static func number(_ object: Any?) -> Double? {
    let value: Double?
    if let string = object as? String { value = Double(string) }
    else if let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
    else { value = nil }
    guard let value, value.isFinite else { return nil }
    return value
  }
}

public enum CodexRPCReader {
  /// All blocking IO stays on the caller's background queue. The child is
  /// terminated on timeout or when the two read-only RPCs have completed.
  public static func read(executable: URL, timeout: TimeInterval = 18) -> AccountSample? {
    guard timeout > 0, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
    let task = Process()
    task.executableURL = executable
    task.arguments = ["app-server", "--listen", "stdio://"]
    let input = Pipe(), output = Pipe()
    task.standardInput = input
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    defer {
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      if task.isRunning {
        task.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
          if task.isRunning { _ = kill(task.processIdentifier, SIGKILL) }
        }
      }
      task.waitUntilExit()
    }

    let stream = ResponseStream(handle: output.fileHandleForReading, deadline: Date().addingTimeInterval(timeout))
    do {
      try send(["id": 1, "method": "initialize", "params": [
        "clientInfo": ["name": "codex-sidebar-status", "version": "1.2.0"],
        "capabilities": ["experimentalApi": true]
      ]], to: input.fileHandleForWriting)
      guard stream.response(id: 1) != nil else { return nil }
      try send(["method": "initialized"], to: input.fileHandleForWriting)
      try send(["id": 2, "method": "account/rateLimits/read"], to: input.fileHandleForWriting)
      guard let response = stream.response(id: 2) else { return nil }
      return CodexRateLimitParser.sample(from: response)
    } catch { return nil }
  }

  private static func send(_ message: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0a)
    try handle.write(contentsOf: data)
  }
}

private final class ResponseStream {
  private let handle: FileHandle
  private let deadline: Date
  private var buffer = Data()

  init(handle: FileHandle, deadline: Date) { self.handle = handle; self.deadline = deadline }

  func response(id: Int) -> [String: Any]? {
    while Date() < deadline {
      while let newline = buffer.firstIndex(of: 0x0a) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let messageID = message["id"] as? Int, messageID == id else { continue }
        guard message["error"] == nil else { return nil }
        return message["result"] as? [String: Any]
      }
      guard buffer.count < 1_000_000 else { return nil }
      let remainingMS = max(1, Int(deadline.timeIntervalSinceNow * 1000))
      var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, Int32(min(remainingMS, 500)))
      if ready < 0 { if errno == EINTR { continue }; return nil }
      if ready == 0 { continue }
      if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { return nil }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
      if count <= 0 { return nil }
      buffer.append(contentsOf: bytes.prefix(count))
    }
    return nil
  }
}
