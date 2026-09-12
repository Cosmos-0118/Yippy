import AppKit
import SwiftUI

struct LogsSettingsPane: View {
  private enum LevelFilter: Hashable {
    case all
    case warnings
    case errors
  }

  private let store = YippyLogStore.shared

  @State private var filter: LevelFilter = .all
  @State private var isConfirmingClear = false

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()

  private var filteredEntries: [YippyLogEntry] {
    switch filter {
    case .all:
      store.entries
    case .warnings:
      store.entries.filter { $0.level == .warning }
    case .errors:
      store.entries.filter { $0.level == .error || $0.level == .critical }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PreferencesCard(
        title: "Error and warning logs",
        description: "Yippy only records errors and warnings. Use these logs when reporting an issue."
      ) {
        Picker("Show", selection: $filter) {
          Text("All").tag(LevelFilter.all)
          Text("Warnings").tag(LevelFilter.warnings)
          Text("Errors").tag(LevelFilter.errors)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320, alignment: .leading)
      }

      PreferencesCard(
        title: "Recent entries",
        description: "Newest entries appear at the bottom. The full history is kept in the log file."
      ) {
        if filteredEntries.isEmpty {
          Text("No warnings or errors recorded.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredEntries) { entry in
              logRow(entry)
              if entry.id != filteredEntries.last?.id {
                Divider()
              }
            }
          }
        }
      }

      PreferencesCard(
        title: "Log file",
        description: "Logs are also written to disk so they survive restarts."
      ) {
        Text(store.filePathDescription)
          .textSelection(.enabled)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        HStack {
          Button("Copy All") {
            copyToClipboard(filteredEntries.map(\.formattedLine).joined(separator: "\n"))
          }
          .disabled(filteredEntries.isEmpty)

          Button("Clear", role: .destructive) {
            isConfirmingClear = true
          }
          .disabled(store.entries.isEmpty)
        }
        .confirmationDialog(
          "Clear all recorded warnings and errors?",
          isPresented: $isConfirmingClear,
          titleVisibility: .visible
        ) {
          Button("Clear Logs", role: .destructive) {
            store.clear()
          }
          Button("Cancel", role: .cancel) { }
        } message: {
          Text("This also deletes the log file on disk.")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func logRow(_ entry: YippyLogEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      levelBadge(entry.level)
      VStack(alignment: .leading, spacing: 3) {
        Text(Self.timestampFormatter.string(from: entry.timestamp))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(entry.message)
          .textSelection(.enabled)
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 0)
      Button("Copy") {
        copyToClipboard(entry.formattedLine)
      }
      .buttonStyle(.link)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func levelBadge(_ level: YippyLogEntry.Level) -> some View {
    Text(level.displayName)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(level == .warning ? Color.yellow.opacity(0.25) : Color.red.opacity(0.2),
                  in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .foregroundStyle(level == .warning ? .orange : .red)
  }

  private func copyToClipboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }
}

#Preview {
  LogsSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
