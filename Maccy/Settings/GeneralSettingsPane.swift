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
        Toggle(isOn: $updater.automaticallyChecksForUpdates) {
          Text("CheckForUpdates", tableName: "GeneralSettings")
        }
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
        Picker("Search", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
        .frame(maxWidth: 260, alignment: .leading)
      }

      PreferencesCard(title: "Paste behavior", description: "Choose what happens when you select an item.") {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      }

      if let notificationsURL {
        Link(destination: notificationsURL) {
          Label("NotificationsAndSounds", systemImage: "bell.badge")
        }
        .padding(.leading, 4)
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
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

private struct PreferencesCard<Content: View>: View {
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
      content
    }
    .padding(20)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
