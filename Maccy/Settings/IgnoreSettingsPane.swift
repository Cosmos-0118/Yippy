import SwiftUI

struct IgnoreSettingsPane: View {
  private enum Rule: Hashable {
    case applications, pasteboardTypes, regularExpressions
  }

  @State private var rule: Rule = .applications

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PreferencesCard(title: "Ignore rules", description: "Choose the kind of clipboard content you want Yippy to skip.") {
        Picker("Rule type", selection: $rule) {
          Text("ApplicationsTab", tableName: "IgnoreSettings").tag(Rule.applications)
          Text("PasteboardTypesTab", tableName: "IgnoreSettings").tag(Rule.pasteboardTypes)
          Text("RegexpTab", tableName: "IgnoreSettings").tag(Rule.regularExpressions)
        }
        .pickerStyle(.segmented)
      }

      Group {
        switch rule {
        case .applications:
          IgnoreApplicationsSettingsView()
        case .pasteboardTypes:
          IgnorePasteboardTypesSettingsView()
        case .regularExpressions:
          IgnoreRegexpsSettingsView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  IgnoreSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
