import Foundation

extension DashboardStore {
  /// Capture report inputs before opening the save panel. Both formatting and
  /// the atomic file replacement run off the main actor, including slow volumes.
  @discardableResult
  func writeExport(
    _ makeContent: @escaping @Sendable () throws -> String,
    to url: URL,
    title: String,
    successMessage: String,
    failurePrefix: String = "导出失败",
    writer: @escaping @Sendable (String, URL) throws -> Void = { content, destination in
      try content.write(to: destination, atomically: true, encoding: .utf8)
    }
  ) async -> Bool {
    guard !isExporting else { return false }
    exportProgressTitle = title
    operationFeedback = nil
    defer { exportProgressTitle = nil }

    let result = await Task.detached(priority: .utility) {
      Result { try writer(makeContent(), url) }
    }.value
    switch result {
    case .success:
      operationFeedback = .init(.success, successMessage)
      return true
    case .failure(let error):
      operationFeedback = .init(.failure, "\(failurePrefix)：\(error.localizedDescription)")
      return false
    }
  }
}
