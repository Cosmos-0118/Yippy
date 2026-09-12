import AppKit
import SwiftUI
import Defaults

struct AppearanceSettingsPane: View {
  @Default(.popupPosition) private var popupAt
  @Default(.popupScreen) private var popupScreen
  @Default(.pinTo) private var pinTo
  @Default(.imageMaxHeight) private var imageHeight
  @Default(.openPreviewAutomatically) private var openPreviewAutomatically
  @Default(.previewDelay) private var previewDelay
  @Default(.highlightMatch) private var highlightMatch
  @Default(.menuIcon) private var menuIcon
  @Default(.showInStatusBar) private var showInStatusBar
  @Default(.showSearch) private var showSearch
  @Default(.searchVisibility) private var searchVisibility
  @Default(.showFooter) private var showFooter
  @Default(.windowPosition) private var windowPosition
  @Default(.showApplicationIcons) private var showApplicationIcons

  @State private var screens = NSScreen.screens

  private let imageHeightFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 200
    return formatter
  }()

  private let numberOfItemsFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 0
    formatter.maximum = 100
    return formatter
  }()

  private let titleLengthFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 30
    formatter.maximum = 200
    return formatter
  }()

  private let previewDelayFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 200
    formatter.maximum = 100_000
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PreferencesCard(title: "Window placement", description: "Choose where Yippy appears when you open clipboard history.") {
        HStack {
          Text("PopupAt", tableName: "AppearanceSettings")
          Spacer()
          Picker("", selection: $popupAt) {
            ForEach(PopupPosition.allCases) { position in
              if position == .center || position == .lastPosition, screens.count > 1 {
                screenPicker(for: position)
              } else {
                Text(position.description)
              }
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .preferencesControl()
          .help(Text("PopupAtTooltip", tableName: "AppearanceSettings"))
          .accessibilityLabel(Text("PopupAt", tableName: "AppearanceSettings"))

          if popupAt == .lastPosition {
            Button {
              _windowPosition.reset()
            } label: {
              Image(systemName: "arrow.uturn.backward.circle.fill")
                .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help(Text("PopupAtLastLocationReset", tableName: "AppearanceSettings"))
            .disabled(windowPosition == _windowPosition.defaultValue)
          }
        }

        HStack {
          Text("PinTo", tableName: "AppearanceSettings")
          Spacer()
          Picker("", selection: $pinTo) {
            ForEach(PinsPosition.allCases) { position in
              Text(position.description)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .preferencesControl()
          .help(Text("PinToTooltip", tableName: "AppearanceSettings"))
          .accessibilityLabel(Text("PinTo", tableName: "AppearanceSettings"))
        }
      }

      PreferencesCard(title: "Previews", description: "Tune the size and timing of clipboard previews.") {
        HStack {
          Text("ImageHeight", tableName: "AppearanceSettings")
          Spacer()
          TextField("", value: $imageHeight, formatter: imageHeightFormatter)
            .multilineTextAlignment(.trailing)
            .frame(width: 120)
            .help(Text("ImageHeightTooltip", tableName: "AppearanceSettings"))
            .accessibilityLabel(Text("ImageHeight", tableName: "AppearanceSettings"))
          Stepper("", value: $imageHeight, in: 1...200)
            .labelsHidden()
            .accessibilityLabel(Text("ImageHeight", tableName: "AppearanceSettings"))
        }

        Defaults.Toggle(key: .openPreviewAutomatically) {
          Text("OpenPreviewAutomatically", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()

        HStack {
          Text("PreviewDelay", tableName: "AppearanceSettings")
          Spacer()
          TextField("", value: $previewDelay, formatter: previewDelayFormatter)
            .multilineTextAlignment(.trailing)
            .frame(width: 120)
            .help(Text("PreviewDelayTooltip", tableName: "AppearanceSettings"))
            .accessibilityLabel(Text("PreviewDelay", tableName: "AppearanceSettings"))
          Stepper("", value: $previewDelay, in: 200...100_000)
            .labelsHidden()
            .accessibilityLabel(Text("PreviewDelay", tableName: "AppearanceSettings"))
        }
        .disabled(!openPreviewAutomatically)

        HStack {
          Text("HighlightMatches", tableName: "AppearanceSettings")
          Spacer()
          Picker("", selection: $highlightMatch) {
            ForEach(HighlightMatch.allCases) { match in
              Text(match.description)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .preferencesControl()
          .help(Text("HighlightMatchesTooltip", tableName: "AppearanceSettings"))
          .accessibilityLabel(Text("HighlightMatches", tableName: "AppearanceSettings"))
        }
      }

      PreferencesCard(title: "Content display", description: "Decide which information is visible in the clipboard window.") {
        Defaults.Toggle(key: .showSpecialSymbols) {
          Text("ShowSpecialSymbols", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        .help(Text("ShowSpecialSymbolsTooltip", tableName: "AppearanceSettings"))

        HStack {
          Defaults.Toggle(key: .showInStatusBar) {
            Text("ShowMenuIcon", tableName: "AppearanceSettings")
          }
          .toggleStyle(.switch)

          Spacer()
          Picker("", selection: $menuIcon) {
            ForEach(MenuIcon.allCases) { icon in
              Image(nsImage: icon.image)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .preferencesControl(width: 72)
          .disabled(!showInStatusBar)
          .accessibilityLabel(Text("ShowMenuIcon", tableName: "AppearanceSettings"))
        }

        Defaults.Toggle(key: .showRecentCopyInMenuBar) {
          Text("ShowRecentCopyInMenuBar", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        HStack {
          Defaults.Toggle(key: .showSearch) {
            Text("ShowSearchField", tableName: "AppearanceSettings")
          }
          .toggleStyle(.switch)

          Spacer()
          Picker("", selection: $searchVisibility) {
            ForEach(SearchVisibility.allCases) { type in
              Text(type.description)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .preferencesControl()
          .disabled(!showSearch)
          .accessibilityLabel(Text("ShowSearchField", tableName: "AppearanceSettings"))
        }
        Defaults.Toggle(key: .showTitle) {
          Text("ShowTitleBeforeSearchField", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        Defaults.Toggle(key: .showApplicationIcons) {
          Text("ShowApplicationIcons", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        Defaults.Toggle(key: .showHexColorSwatch) {
          Text("ShowHexColorSwatch", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        .help(Text("ShowHexColorSwatchTooltip", tableName: "AppearanceSettings"))

        Defaults.Toggle(key: .showFooter) {
          Text("ShowFooter", tableName: "AppearanceSettings")
        }
        .toggleStyle(.switch)
        .preferencesSwitchRow()
        Text("OpenPreferencesWarning", tableName: "AppearanceSettings")
          .fixedSize(horizontal: false, vertical: true)
          .opacity(showFooter ? 0 : 1)
          .controlSize(.small)
          .foregroundStyle(.gray)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      screens = NSScreen.screens
    }
  }

  @ViewBuilder
  private func screenPicker(for position: PopupPosition) -> some View {
    let screenBinding: Binding<Int> = Binding {
      return popupScreen
    } set: {
      popupScreen = $0
      popupAt = position
    }

    Picker(selection: screenBinding) {
      Text(labelForScreen(index: 0))
        .tag(0)

      ForEach(screens.indices, id: \.self) { index in
        Text(labelForScreen(index: index + 1))
          .tag(index + 1)
      }
    } label: {
      if popupAt == position {
        Text("\(position.description) (\(labelForScreen(index: popupScreen)))")
      } else {
        Text(position.description)
      }
    }
  }

  private func labelForScreen(index screenIndex: Int) -> String {
    switch screenIndex {
    case 0:
      return String(localized: "ActiveScreen", table: "AppearanceSettings")
    case _:
      return screens[screenIndex - 1].localizedName
    }
  }
}

#Preview {
  AppearanceSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
