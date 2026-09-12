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

// Unlike `pruneHistoryLog`, neither method under test here requires macOS 15,
// so this class is intentionally not `@available`-gated.
@MainActor
class StorageCleanupTests: XCTestCase {
  // The batch size is 500, so 1,200 orphans force multiple fetch/delete/save
  // rounds — this is what proves the loop actually drains fully instead of
  // stopping after one batch, and that a second run is a no-op.
  func testCleanupOrphanedContentsDrainsAllBatchesAndIsIdempotent() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        let path = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
        try? FileManager.default.removeItem(at: path)
      }
    }

    let storage = Storage(onDiskURL: url)
    let context = storage.context

    let live = HistoryItem(contents: [HistoryItemContent(type: "public.utf8-plain-text", value: Data("keep".utf8))])
    context.insert(live)
    for index in 0..<1_200 {
      context.insert(HistoryItemContent(type: "public.utf8-plain-text", value: Data("orphan-\(index)".utf8)))
    }
    try context.save()

    let deletedCount = try await storage.cleanupOrphanedContents()
    XCTAssertEqual(deletedCount, 1_200)
    let secondRunDeletedCount = try await storage.cleanupOrphanedContents()
    XCTAssertEqual(secondRunDeletedCount, 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItemContent>()), 1)

    // Reopening proves the batched saves actually committed to disk rather
    // than only clearing this context's in-memory state.
    let reopened = Storage(onDiskURL: url)
    XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<HistoryItemContent>()), 1)
    XCTAssertEqual(try reopened.context.fetchCount(FetchDescriptor<HistoryItem>()), 1)
  }

  // Cleanup runs on its own private `ModelContext`, not `mainContext` — this
  // proves a content object that is only *pending* on `mainContext` (attached
  // to an item, but not yet saved) is invisible to the cleanup fetch and
  // survives, the way an in-flight clipboard add must.
  func testCleanupOrphanedContentsIgnoresUnsavedPendingContentOnMainContext() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        let path = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
        try? FileManager.default.removeItem(at: path)
      }
    }

    let storage = Storage(onDiskURL: url)
    let context = storage.context

    let pendingItem = HistoryItem()
    let pendingContent = HistoryItemContent(type: "public.utf8-plain-text", value: Data("pending".utf8))
    context.insert(pendingContent)
    // Not yet attached to an item and not yet saved — mirrors the moment
    // between constructing a copy's content and attaching it to its item.
    XCTAssertNil(pendingContent.item)

    let deletedCount = try await storage.cleanupOrphanedContents()
    XCTAssertEqual(deletedCount, 0)

    pendingContent.item = pendingItem
    pendingItem.contents = [pendingContent]
    context.insert(pendingItem)
    try context.save()

    XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItemContent>()), 1)
  }

  func testSanitizeTitlesFixesAllUnsafeTitles() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        let path = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
        try? FileManager.default.removeItem(at: path)
      }
    }

    let storage = Storage(onDiskURL: url)
    let context = storage.context
    let unsafeScalar = "\u{FFFC}"

    var expectedBadCount = 0
    for index in 0..<50 {
      let item = HistoryItem()
      if index % 3 == 0 {
        item.title = "\(unsafeScalar)bad-\(index)"
        expectedBadCount += 1
      } else {
        item.title = "clean-\(index)"
      }
      context.insert(item)
    }
    try context.save()

    let sanitizedCount = try storage.sanitizeTitles()
    XCTAssertEqual(sanitizedCount, expectedBadCount)

    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(items.count, 50)
    XCTAssertTrue(items.allSatisfy { !$0.title.containsScalarsUnsafeForTitleLayout })

    let reopened = Storage(onDiskURL: url)
    let reopenedItems = try reopened.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(reopenedItems.count, 50)
    XCTAssertTrue(reopenedItems.allSatisfy { !$0.title.containsScalarsUnsafeForTitleLayout })
  }
}
#endif
