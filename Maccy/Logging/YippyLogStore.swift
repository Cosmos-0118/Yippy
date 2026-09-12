import Foundation
import Logging
import Observation

struct YippyLogEntry: Identifiable, Equatable {
  enum Level: String, Equatable, Codable {
    case warning
    case error
    case critical

    init?(_ loggerLevel: Logger.Level) {
      switch loggerLevel {
      case .warning:
        self = .warning
      case .error:
        self = .error
      case .critical:
        self = .critical
      default:
        return nil
      }
    }

    var displayName: String {
      switch self {
      case .warning: "Warning"
      case .error: "Error"
      case .critical: "Critical"
      }
    }
  }

  let id = UUID()
  let timestamp: Date
  let level: Level
  let label: String
  let message: String

  var formattedLine: String {
    "\(Self.lineFormatter.string(from: timestamp)) [\(level.rawValue.uppercased())] \(label): \(message)"
  }

  static let lineFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func parse(line: String) -> YippyLogEntry? {
    // Format: "<iso8601> [LEVEL] label: message"
    guard let levelStart = line.firstIndex(of: "["),
          let levelEnd = line.firstIndex(of: "]") else {
      return nil
    }
    let timestampPart = String(line[..<levelStart]).trimmingCharacters(in: .whitespaces)
    let levelPart = String(line[line.index(after: levelStart)..<levelEnd]).lowercased()
    let remainder = String(line[line.index(after: levelEnd)...]).trimmingCharacters(in: .whitespaces)

    guard let timestamp = lineFormatter.date(from: timestampPart) ?? ISO8601DateFormatter().date(from: timestampPart),
          let level = Level(rawValue: levelPart) else {
      return nil
    }

    let label: String
    let message: String
    if let separator = remainder.firstIndex(of: ":") {
      label = String(remainder[..<separator]).trimmingCharacters(in: .whitespaces)
      message = String(remainder[remainder.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    } else {
      label = ""
      message = remainder
    }

    return YippyLogEntry(timestamp: timestamp, level: level, label: label, message: message)
  }
}

@Observable
@MainActor
final class YippyLogStore {
  static let shared = YippyLogStore()

  static let maxEntries = 500
  static let maxFileBytes = 1_048_576
  static let maxRotatedFiles = 3

  private(set) var entries: [YippyLogEntry] = []

  let logFileURL: URL
  private let maxEntriesLimit: Int

  init(logFileURL: URL? = nil, maxEntries: Int = 500) {
    self.logFileURL = logFileURL ?? Self.defaultLogFileURL()
    self.maxEntriesLimit = maxEntries
    loadFromDisk()
  }

  static func defaultLogDirectory() -> URL {
    let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appending(path: "Logs/Yippy", directoryHint: .isDirectory)
  }

  static func defaultLogFileURL() -> URL {
    defaultLogDirectory().appending(path: "app.log", directoryHint: .notDirectory)
  }

  func append(level: Logger.Level, label: String, message: String) {
    guard let entryLevel = YippyLogEntry.Level(level) else {
      return
    }
    let entry = YippyLogEntry(timestamp: Date(), level: entryLevel, label: label, message: message)
    entries.append(entry)
    if entries.count > maxEntriesLimit {
      entries.removeFirst(entries.count - maxEntriesLimit)
    }
    writeLine(entry.formattedLine)
  }

  func clear() {
    entries.removeAll()
    try? FileManager.default.removeItem(at: logFileURL)
    for index in 1...Self.maxRotatedFiles {
      try? FileManager.default.removeItem(at: rotatedURL(index: index))
    }
  }

  var filePathDescription: String {
    logFileURL.path(percentEncoded: false)
  }

  private func rotatedURL(index: Int) -> URL {
    logFileURL.appendingPathExtension("\(index).log")
  }

  private func writeLine(_ line: String) {
    do {
      try FileManager.default.createDirectory(
        at: logFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      rotateIfNeeded()
      if FileManager.default.fileExists(atPath: logFileURL.path(percentEncoded: false)) {
        let handle = try FileHandle(forWritingTo: logFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = (line + "\n").data(using: .utf8) {
          try handle.write(contentsOf: data)
        }
      } else {
        try (line + "\n").write(to: logFileURL, atomically: true, encoding: .utf8)
      }
    } catch {
      // Logging must never crash or recurse — drop the write on failure.
    }
  }

  private func rotateIfNeeded() {
    guard let size = try? logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size >= Self.maxFileBytes else {
      return
    }
    // Shift app.log.N -> app.log.N+1, drop the oldest.
    for index in stride(from: Self.maxRotatedFiles - 1, through: 1, by: -1) {
      let source = rotatedURL(index: index)
      let destination = rotatedURL(index: index + 1)
      if FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
        if index + 1 > Self.maxRotatedFiles {
          try? FileManager.default.removeItem(at: source)
        } else {
          try? FileManager.default.moveItem(at: source, to: destination)
        }
      }
    }
    try? FileManager.default.moveItem(at: logFileURL, to: rotatedURL(index: 1))
  }

  private func loadFromDisk() {
    guard let data = try? Data(contentsOf: logFileURL),
          let text = String(data: data, encoding: .utf8) else {
      return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let parsed = lines.suffix(maxEntriesLimit).compactMap { YippyLogEntry.parse(line: String($0)) }
    entries = Array(parsed)
  }
}
