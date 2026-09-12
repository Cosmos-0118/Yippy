import SwiftUI
import Defaults

struct IgnoreRegexpsSettingsView: View {
  @Default(.ignoreRegexp) private var ignoredRegexps

  @FocusState private var focus: String.ID?
  @State private var edit = ""
  @State private var selection = ""

  var body: some View {
    PreferencesCard(title: "Regular expressions", description: "Define patterns for copied text that Yippy should ignore.") {
      List(selection: $selection) {
        ForEach(ignoredRegexps) { regexp in
          TextField("", text: Binding(
            get: { regexp },
            set: {
              guard !$0.isEmpty, regexp != $0 else { return }
              edit = $0
            })
          ).onSubmit {
            remove(regexp)
            ignoredRegexps.append(edit)
          }.focused($focus, equals: regexp)
        }
      }
      .frame(height: 260)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .onDeleteCommand {
        remove(selection)
      }

      ControlGroup {
        Button("", systemImage: "plus") {
          ignoredRegexps.append("^[a-zA-Z0-9]{50}$")
          focus = "^[a-zA-Z0-9]{50}$"
        }
        Button("", systemImage: "minus") {
          remove(selection)
        }
      }.frame(width: 50)

      Text("IgnoredRegexpsDescription", tableName: "IgnoreSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .font(.subheadline)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func remove(_ regexp: String?) {
    guard let regexp else { return }

    ignoredRegexps.removeAll(where: { $0 == regexp })
  }
}

#Preview {
  IgnoreRegexpsSettingsView()
    .environment(\.locale, .init(identifier: "en"))
}
