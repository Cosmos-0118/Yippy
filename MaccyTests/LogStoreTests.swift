#if DEBUG
import XCTest
@testable import Maccy

@MainActor
class LogStoreTests: XCTestCase {
  private func temporaryLogURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "YippyLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "app.log", directoryHint: .notDirectory)
  }

  func testInfoAndDebugLevelsAreDropped() {
    XCTAssertFalse(YippyLogHandler.shouldRecord(.trace))
    XCTAssertFalse(YippyLogHandler.shouldRecord(.debug))
    XCTAssertFalse(YippyLogHandler.shouldRecord(.info))
    XCTAssertFalse(YippyLogHandler.shouldRecord(.notice))
    XCTAssertTrue(YippyLogHandler.shouldRecord(.warning))
    XCTAssertTrue(YippyLogHandler.shouldRecord(.error))
    XCTAssertTrue(YippyLogHandler.shouldRecord(.critical))

    let store = YippyLogStore(logFileURL: temporaryLogURL())
    store.append(level: .info, label: "test", message: "ignored")
    store.append(level: .debug, label: "test", message: "ignored")
    XCTAssertTrue(store.entries.isEmpty)

    store.append(level: .warning, label: "test", message: "kept")
    store.append(level: .error, label: "test", message: "kept")
    XCTAssertEqual(store.entries.count, 2)
  }

  func testRingBufferCapsEntries() {
    let store = YippyLogStore(logFileURL: temporaryLogURL(), maxEntries: 10)
    for index in 0..<25 {
      store.append(level: .warning, label: "test", message: "message-\(index)")
    }
    XCTAssertEqual(store.entries.count, 10)
    XCTAssertEqual(store.entries.first?.message, "message-15")
    XCTAssertEqual(store.entries.last?.message, "message-24")
  }

  func testFilePersistenceAndReload() {
    let url = temporaryLogURL()
    let store = YippyLogStore(logFileURL: url)
    store.append(level: .warning, label: "test-label", message: "disk-warning")
    store.append(level: .error, label: "test-label", message: "disk-error")

    let contents = try? String(contentsOf: url, encoding: .utf8)
    XCTAssertNotNil(contents)
    XCTAssertTrue(contents?.contains("disk-warning") ?? false)
    XCTAssertTrue(contents?.contains("disk-error") ?? false)
    XCTAssertTrue(contents?.contains("[WARNING]") ?? false)
    XCTAssertTrue(contents?.contains("[ERROR]") ?? false)

    // A fresh store over the same file repopulates from disk.
    let reopened = YippyLogStore(logFileURL: url)
    XCTAssertEqual(reopened.entries.count, 2)
    XCTAssertEqual(reopened.entries.map(\.message), ["disk-warning", "disk-error"])
  }

  func testClearRemovesEntriesAndFile() {
    let url = temporaryLogURL()
    let store = YippyLogStore(logFileURL: url)
    store.append(level: .error, label: "test", message: "to-clear")
    XCTAssertFalse(store.entries.isEmpty)

    store.clear()
    XCTAssertTrue(store.entries.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }
}
#endif
