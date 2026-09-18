import Foundation

/// Reads bounded chunks. Non-token records only need their first 8 KiB for the
/// existing classification rules; token records remain complete for accounting.
enum SessionLogStream {
  struct Result {
    var pending: Data
    var offset: Int
    var bytesRead: Int
  }

  static func read(file: URL, offset: Int, endOffset: Int, pending: Data,
                   consume: (String) -> Void) throws -> Result {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(max(0, offset)))
    var line = pending
    var batch = Data()
    var position = offset
    // A Unicode scalar uses at most four bytes. Keep enough bytes for the
    // classifier's original 8,192-character prefix, including Chinese text.
    let contextPrefixBytes = 4 * 8192
    // Whitespace around JSON keys is insignificant. A value-only prefix check
    // retains complete accounting records with both compact and spaced JSON.
    let tokenNeedle = Data(#""token_count""#.utf8)
    func append(_ bytes: Data.SubSequence) {
      if line.count >= contextPrefixBytes && line.prefix(contextPrefixBytes).range(of: tokenNeedle) == nil { return }
      line.append(contentsOf: bytes)
      if line.count > contextPrefixBytes && line.prefix(contextPrefixBytes).range(of: tokenNeedle) == nil {
        line = Data(line.prefix(contextPrefixBytes))
      }
    }
    while position < endOffset, let chunk = try handle.read(upToCount: min(256 * 1024, endOffset - position)), !chunk.isEmpty {
      position += chunk.count
      var start = chunk.startIndex
      while let newline = chunk[start...].firstIndex(of: 10) {
        append(chunk[start..<newline])
        batch.append(line); batch.append(10); line.removeAll(keepingCapacity: true)
        start = chunk.index(after: newline)
        if batch.count >= 256 * 1024 {
          consume(String(decoding: batch, as: UTF8.self)); batch.removeAll(keepingCapacity: true)
        }
      }
      append(chunk[start...])
    }
    // A complete final JSON object does not require a newline; partial UTF-8 is
    // retained as bytes, so appends cannot replace or lose a split character.
    if !line.isEmpty, (try? JSONSerialization.jsonObject(with: line)) != nil {
      batch.append(line); batch.append(10); line.removeAll()
    }
    if !batch.isEmpty { consume(String(decoding: batch, as: UTF8.self)) }
    return Result(pending: line, offset: position, bytesRead: max(0, position - offset))
  }
}
