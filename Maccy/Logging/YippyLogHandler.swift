import Foundation
import Logging
import os

struct YippyLogHandler: LogHandler {
  var logLevel: Logging.Logger.Level = .warning
  var metadata: Logging.Logger.Metadata = [:]

  let label: String
  private let osLogger: os.Logger

  init(label: String) {
    self.label = label
    self.osLogger = os.Logger(subsystem: "dev.cosmos0118.Yippy", category: "app")
  }

  subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  static func shouldRecord(_ level: Logging.Logger.Level) -> Bool {
    level >= .warning
  }

  func log(level: Logging.Logger.Level,
           message: Logging.Logger.Message,
           metadata: Logging.Logger.Metadata?,
           source: String,
           file: String,
           function: String,
           line: UInt) {
    guard Self.shouldRecord(level) else {
      return
    }
    let text = message.description

    switch level {
    case .warning:
      osLogger.warning("\(text, privacy: .public)")
    case .error, .critical:
      osLogger.error("\(text, privacy: .public)")
    default:
      break
    }

    let capturedLabel = label
    Task { @MainActor in
      YippyLogStore.shared.append(level: level, label: capturedLabel, message: text)
    }
  }
}

enum YippyLogging {
  private static let bootstrapLock = NSLock()
  private static var didBootstrap = false

  static func bootstrapOnce() {
    bootstrapLock.lock()
    defer { bootstrapLock.unlock() }
    guard !didBootstrap else {
      return
    }
    didBootstrap = true
    LoggingSystem.bootstrap({ (label: String, _: Logging.Logger.MetadataProvider?) in
      YippyLogHandler(label: label)
    }, metadataProvider: nil)
  }
}
