import Defaults
import Foundation
import Logging
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  private let logger = Logger(label: "dev.cosmos0118.Yippy")

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Yippy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  #if DEBUG
  // Persistent history requires a real on-disk, journaled store, so tests that
  // exercise `pruneHistoryLog()` need an instance pointed at a temporary file
  // instead of the in-memory store the default `init()` uses under `isTesting`.
  init(onDiskURL: URL) {
    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(url: onDiskURL))
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }
  #endif

  private static let cleanupBatchSize = 500

  // A single predicate delete over the whole orphan set stages one huge
  // transaction and blocks the main actor for as long as it takes to commit,
  // which is what makes a large store hang at launch. Deleting in bounded
  // batches, each with its own save, keeps every commit small (bounding WAL
  // growth) and makes the operation resumable: a batch that never gets its
  // save is simply retried, since deleted rows leave the predicate and
  // undeleted ones stay in it — no offset bookkeeping is needed or safe here.
  //
  // Runs on its own `ModelContext` rather than `mainContext`: a fetch merges
  // its own context's *pending*, unsaved changes, so on `mainContext` a
  // content object momentarily inserted with no `item` yet attached (e.g. a
  // clipboard add still in progress) would match `item == nil` and be
  // deleted — and a failed save's rollback would discard that unrelated
  // pending insert along with it. A private context sees only what is
  // already committed to the store, so live clipboard activity on
  // `mainContext` can never be touched by this loop.
  func cleanupOrphanedContents() async throws -> Int {
    logLowCapacityWarningIfNeeded()

    let cleanupContext = ModelContext(container)
    var totalDeleted = 0

    while true {
      var descriptor = FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.item == nil }
      )
      descriptor.fetchLimit = Self.cleanupBatchSize

      let batch = try cleanupContext.fetch(descriptor)
      guard !batch.isEmpty else {
        break
      }

      for content in batch {
        cleanupContext.delete(content)
      }
      cleanupContext.processPendingChanges()

      do {
        try cleanupContext.save()
      } catch {
        cleanupContext.rollback()
        throw error
      }

      totalDeleted += batch.count

      // Yields the main actor between batches so a large cleanup doesn't
      // starve UI/event handling even though it now runs after launch.
      await Task.yield()
    }

    return totalDeleted
  }

  // Best-effort warning only: available capacity and how much space a
  // SQLite checkpoint/WAL cycle actually needs are not in a strict 1:1
  // relationship, so this must never gate the cleanup itself — batching is
  // what keeps a low-space cleanup safe and resumable, not this check.
  private func logLowCapacityWarningIfNeeded() {
    guard
      let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage,
      let storeSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    else {
      return
    }

    if capacity < Int64(storeSize) {
      logger.warning(
        "Low disk space (\(capacity) bytes available) before orphaned-content cleanup of a \(storeSize)-byte store."
      )
    }
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  //
  // `historySize` caps unpinned items at 999 and pins are capped at ~20 keys
  // (see `HistoryItem.supportedPins`), so the live item count this scans is
  // always small — a single fetch is appropriate. (A `fetchLimit`/`fetchOffset`
  // page loop was tried here and reverted: SQLite still produces and discards
  // every earlier page's rows for each `OFFSET`, making the scan O(n²) instead
  // of O(n) for no bound this call actually needs.)
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    do {
      try context.save()
    } catch {
      context.rollback()
      throw error
    }

    return count
  }

  // SwiftData's persistent history log (transactions/changes) grows on every
  // insert and delete and is never pruned by the framework itself, so the
  // store's on-disk footprint keeps climbing even when `historySize` bounds
  // the number of live `HistoryItem` rows. `deleteHistory` requires macOS 15.
  @available(macOS 15, *)
  func pruneHistoryLog() throws {
    let cutoff = Date()
    try context.deleteHistory(
      HistoryDescriptor<DefaultHistoryTransaction>(
        predicate: #Predicate { $0.timestamp <= cutoff }
      )
    )
  }

  // Yippy is a menu-bar app that can run for weeks without quitting, so pruning
  // only at launch would leave the log growing unbounded for the whole session.
  // Called from both launch and the per-copy trim path, throttled to once a day
  // since `deleteHistory` walks the whole log and runs on the main actor.
  @available(macOS 15, *)
  func pruneHistoryLogIfNeeded() {
    guard Date().timeIntervalSince(Defaults[.lastHistoryLogPruneAt]) > 60 * 60 * 24 else {
      return
    }

    do {
      try pruneHistoryLog()
      Defaults[.lastHistoryLogPruneAt] = Date()
    } catch {
      logger.error("Failed to prune history log: \(String(reflecting: error))")
    }
  }
}
