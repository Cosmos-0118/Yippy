import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PreferencesCard(title: "Privacy controls", description: "Control when Yippy is allowed to observe your clipboard.") {
        Defaults.Toggle(key: .ignoreEvents) {
          Text("TurnOff", tableName: "AdvancedSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()

        Text("TurnOffDescription", tableName: "AdvancedSettings")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      PreferencesCard(title: "Automation", description: "Use these commands when a workflow needs to pause clipboard history.") {
        Text("TurnOffShellScript", tableName: "AdvancedSettings")
          .textSelection(.enabled)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Text("TurnOffNextShellScript", tableName: "AdvancedSettings")
          .textSelection(.enabled)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }

      PreferencesCard(title: "On quit", description: "Clear private clipboard data automatically when Yippy closes.") {
        Defaults.Toggle(key: .clearOnQuit) {
          Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        .help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))

        Defaults.Toggle(key: .clearSystemClipboard) {
          Text("ClearSystemClipboard", tableName: "AdvancedSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        .help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
