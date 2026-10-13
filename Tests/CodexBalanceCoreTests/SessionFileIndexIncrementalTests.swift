import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Incremental session-file indexing")
struct SessionFileIndexIncrementalTests {
  @Test func multipleFileAppendsRefreshOnlyChangedMetadata() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for number in 0..<256 {
      try Data("{}\n".utf8).write(to: root.appendingPathComponent("\(number).jsonl"))
    }
    let index = SessionFileIndex(roots: [root], reconciliationInterval: 600, watch: false)
    let now = Date()
    let original = index.read(at: now)
    let originalByPath = Dictionary(uniqueKeysWithValues: original.map { ($0.url.path, $0) })
    let metadataReads = index.metadataReadCount
    let enumerations = index.enumerationCount
    let revision = index.revision
    let changed = (0..<32).map { root.appendingPathComponent("\($0 * 3).jsonl") }
    for file in changed {
      let handle = try FileHandle(forWritingTo: file)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("{}\n".utf8))
      try handle.close()
    }

    index.markChanged(changed.map(\.path))
    let updated = index.read(at: now.addingTimeInterval(1))
    let changedPaths = Set(changed.map(\.path))
    #expect(updated.count == original.count)
    #expect(index.metadataReadCount - metadataReads == changed.count)
    #expect(index.enumerationCount == enumerations)
    #expect(index.revision == revision + 1)
    for entry in updated {
      if changedPaths.contains(entry.url.path) {
        #expect(entry.size == 6)
        #expect(entry.identity == originalByPath[entry.url.path]?.identity)
      } else {
        #expect(entry == originalByPath[entry.url.path])
      }
    }
  }

  @Test func deletedAndReplacedFilesInvalidateTheirExactEntries() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let deleted = root.appendingPathComponent("deleted.jsonl")
    let replaced = root.appendingPathComponent("replaced.jsonl")
    let unchanged = root.appendingPathComponent("unchanged.jsonl")
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    for file in [deleted, replaced, unchanged] {
      try Data("old\n".utf8).write(to: file)
      try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
    }
    let index = SessionFileIndex(roots: [root], reconciliationInterval: 600, watch: false)
    let now = Date()
    let original = Dictionary(uniqueKeysWithValues: index.read(at: now).map { ($0.url.path, $0) })
    let revision = index.revision
    try FileManager.default.removeItem(at: deleted)
    // Atomic replacement preserves the path, size and modification date, but
    // changes file identity; the incremental index must observe that change.
    try Data("new\n".utf8).write(to: replaced, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: replaced.path)

    index.markChanged([deleted.path, replaced.path])
    let updated = Dictionary(uniqueKeysWithValues: index.read(at: now.addingTimeInterval(1)).map { ($0.url.path, $0) })
    #expect(updated.count == 2)
    #expect(updated[deleted.path] == nil)
    #expect(updated[replaced.path]?.size == original[replaced.path]?.size)
    #expect(updated[replaced.path]?.modified == original[replaced.path]?.modified)
    #expect(updated[replaced.path]?.identity != original[replaced.path]?.identity)
    #expect(updated[unchanged.path] == original[unchanged.path])
    #expect(index.revision == revision + 1)
  }

  @Test func directoryEventsRefreshAndRemoveTheEntireSubtree() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let group = root.appendingPathComponent("group")
    let nested = group.appendingPathComponent("nested")
    let neighbor = root.appendingPathComponent("group-neighbor")
    for directory in [nested, neighbor] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let first = group.appendingPathComponent("first.jsonl")
    let second = nested.appendingPathComponent("second.jsonl")
    let retained = neighbor.appendingPathComponent("retained.jsonl")
    for file in [first, second, retained] { try Data("{}\n".utf8).write(to: file) }
    let index = SessionFileIndex(roots: [root], reconciliationInterval: 600, watch: false)
    let now = Date()
    #expect(index.read(at: now).count == 3)
    try FileManager.default.removeItem(at: first)
    let added = nested.appendingPathComponent("added.jsonl")
    try Data("{}\n".utf8).write(to: added)
    index.markChanged([group.path])
    #expect(Set(index.read(at: now.addingTimeInterval(1)).map(\.url)) == Set([second, added, retained]))

    try FileManager.default.removeItem(at: group)
    index.markChanged([group.path])
    #expect(index.read(at: now.addingTimeInterval(2)).map(\.url) == [retained])
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-index-regression-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
