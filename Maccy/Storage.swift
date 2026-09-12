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

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
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
    try context.save()

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
