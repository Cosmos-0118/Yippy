import SwiftUI
import Defaults

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.sortBy) private var sortBy

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PreferencesCard(title: "What to save", description: "Choose the clipboard content Yippy should keep in history.") {
        Toggle(isOn: $viewModel.saveFiles) {
          Text("Files", tableName: "StorageSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()

        Toggle(isOn: $viewModel.saveImages) {
          Text("Images", tableName: "StorageSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()

        Toggle(isOn: $viewModel.saveText) {
          Text("Text", tableName: "StorageSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()

        Text("SaveDescription", tableName: "StorageSettings")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      PreferencesCard(title: "History size", description: "Limit how many clipboard items are retained.") {
        HStack {
          Text("Size", tableName: "StorageSettings")
          Spacer()
          TextField("", value: $size, formatter: sizeFormatter)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
          Stepper("", value: $size, in: 1...999)
            .labelsHidden()
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
        }

        LabeledContent("Currently stored") {
          Text(storageSize)
            .foregroundStyle(.secondary)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
        }
        .onAppear { storageSize = Storage.shared.size }
      }

      PreferencesCard(title: "Organization", description: "Choose how clipboard history is ordered.") {
        HStack {
          Text("SortBy", tableName: "StorageSettings")
          Spacer()
          Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .preferencesControl(width: 180)
        .help(Text("SortByTooltip", tableName: "StorageSettings"))
        .accessibilityLabel(Text("SortBy", tableName: "StorageSettings"))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
