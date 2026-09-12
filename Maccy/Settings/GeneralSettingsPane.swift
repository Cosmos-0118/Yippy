import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater()

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PreferencesCard(
        title: "Startup",
        description: "Choose how Yippy runs in the background."
      ) {
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)

        Toggle(isOn: $updater.automaticallyChecksForUpdates) {
          Text("CheckForUpdates", tableName: "GeneralSettings")
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)

        Divider()

        Button(
          action: { updater.checkForUpdates() },
          label: { Text("CheckNow", tableName: "GeneralSettings") }
        )
      }

      PreferencesCard(
        title: "Keyboard shortcuts",
        description: "Use these anywhere to control your clipboard history."
      ) {
        shortcutRow("Open", shortcut: .popup, tooltip: "OpenTooltip") { newShortcut in
          if newShortcut == nil {
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            AppState.shared.popup.initEventsMonitor()
          }
        }
        Divider()
        shortcutRow("Pin", shortcut: .pin, tooltip: "PinTooltip")
        Divider()
        shortcutRow("Delete", shortcut: .delete, tooltip: "DeleteTooltip")
        Divider()
        shortcutRow("ShowPreview", shortcut: .togglePreview, tooltip: "ShowPreviewTooltip")
      }

      PreferencesCard(title: "Search", description: "Set how Yippy matches clipboard history.") {
        HStack {
          Text("Search", tableName: "GeneralSettings")
          Spacer()
          Picker("", selection: $searchMode) {
            ForEach(Search.Mode.allCases) { mode in
              Text(mode.description)
            }
          }
          .labelsHidden()
          .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
          .frame(width: 200, alignment: .leading)
        }
      }

      PreferencesCard(title: "Paste behavior", description: "Choose what happens when you select an item.") {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)

        Divider()

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .controlSize(.small)
      }

      if let notificationsURL {
        Link(destination: notificationsURL) {
          HStack {
            Label("NotificationsAndSounds", systemImage: "bell.badge")
              .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "arrow.up.forward")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(.separator, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func shortcutRow(
    _ title: LocalizedStringKey,
    shortcut: KeyboardShortcuts.Name,
    tooltip: String,
    onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
  ) -> some View {
    HStack {
      Text(title, tableName: "GeneralSettings")
      Spacer()
      KeyboardShortcuts.Recorder(for: shortcut, onChange: onChange)
        .help(Text(LocalizedStringKey(tooltip), tableName: "GeneralSettings"))
        .accessibilityLabel(Text(title, tableName: "GeneralSettings"))
    }
  }

  private func refreshModifiers(_ sender: Sendable) {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

struct PreferencesCard<Content: View>: View {
  let title: LocalizedStringKey
  let description: LocalizedStringKey
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.separator, lineWidth: 1)
    )
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
