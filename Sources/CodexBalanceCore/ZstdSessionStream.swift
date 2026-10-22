import CZstd
import Foundation

/// Bundled, streaming decoder: no command-line tool or full transcript buffer.
enum ZstdSessionStream {
  enum ReadError: Error { case allocationFailed, invalidFrame, incompleteFrame }

  static func read(file: URL, endOffset: Int, consume: (Data) -> Void) throws -> Int {
    guard let decoder = ZSTD_createDCtx() else { throw ReadError.allocationFailed }
    defer { ZSTD_freeDCtx(decoder) }
    // Cap the decoder history window at 128 MiB even for an untrusted header.
    guard ZSTD_isError(ZSTD_DCtx_setParameter(decoder, ZSTD_d_windowLogMax, 27)) == 0 else {
      throw ReadError.invalidFrame
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var position = 0
    var remaining = 1
    var output = Data(count: Int(ZSTD_DStreamOutSize()))
    while position < endOffset {
      guard let chunk = try handle.read(upToCount: min(Int(ZSTD_DStreamInSize()), endOffset - position)),
            !chunk.isEmpty else { throw ReadError.incompleteFrame }
      position += chunk.count
      try chunk.withUnsafeBytes { source in
        var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
        repeat {
          let previous = input.pos
          var written = 0
          try output.withUnsafeMutableBytes { destination in
            var buffer = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
            remaining = ZSTD_decompressStream(decoder, &buffer, &input)
            guard ZSTD_isError(remaining) == 0 else { throw ReadError.invalidFrame }
            written = buffer.pos
          }
          if written > 0 { consume(output.prefix(written)) }
          // A full output buffer can leave decoded bytes buffered after the
          // last input byte. Flush them before accepting EOF or reading more.
          if input.pos == input.size && (remaining == 0 || written < output.count) { break }
          guard input.pos > previous || written > 0 else { throw ReadError.invalidFrame }
        } while true
      }
    }
    guard position > 0, remaining == 0 else { throw ReadError.incompleteFrame }
    return position
  }
}
