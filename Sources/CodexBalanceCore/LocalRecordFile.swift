import Darwin
import Foundation

/// Bounded reads of ordinary local files. Missing files are distinct from unsafe or unreadable paths.
enum LocalRecordFile {
  static let maximumSize = 8 * 1024 * 1024

  static func requireDirectoryIfPresent(at url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return }
      throw CocoaError(.fileReadUnknown)
    }
    _ = close(descriptor)
  }

  static func read(at url: URL, limit: Int = maximumSize) throws -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw CocoaError(.fileReadUnknown)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0, metadata.st_size <= limit else { throw CocoaError(.fileReadUnknown) }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
    }
    return data
  }
}
