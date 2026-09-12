#if DEBUG
import XCTest
import SwiftData
@testable import Maccy

@available(macOS 15, *)
@MainActor
class StorageTests: XCTestCase {
  func testPruneHistoryLogDeletesPersistedTransactionsWithoutTouchingLiveItems() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        let path = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
        try? FileManager.default.removeItem(at: path)
      }
    }

    let storage = Storage(onDiskURL: url)
    let context = storage.context

    // One item survives the prune, one is deleted before it — the surviving
    // item is what proves `pruneHistoryLog` only touches the history log and
    // never live `HistoryItem` rows.
    let keptItem = HistoryItem(contents: [HistoryItemContent(type: "public.utf8-plain-text", value: Data("keep".utf8))])
    let removedItem = HistoryItem(contents: [HistoryItemContent(type: "public.utf8-plain-text", value: Data("remove".utf8))])
    context.insert(keptItem)
    context.insert(removedItem)
    try context.save()

    context.delete(removedItem)
    try context.save()

    let historyBeforePrune = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
    XCTAssertFalse(historyBeforePrune.isEmpty)

    try storage.pruneHistoryLog()

    let historyAfterPrune = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
    XCTAssertTrue(historyAfterPrune.isEmpty)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItem>()), 1)

    // Reopening against the same file with a fresh container proves the pruned
    // history and the surviving item were actually committed to disk, not just
    // held in this context's in-memory state.
    let reopened = Storage(onDiskURL: url)
    let historyAfterReopen = try reopened.context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
    XCTAssertTrue(historyAfterReopen.isEmpty)
    XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<HistoryItem>()), 1)
  }
}
#endif
