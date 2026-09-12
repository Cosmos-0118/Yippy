import AppKit
import Defaults
import Foundation
import SwiftUI

@Observable
class AppState {
  static let shared = AppState(history: History.shared, footer: Footer())

  let multiSelectionEnabled = false

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: NSWindowController?

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      })
    preview.contentWidth = Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
  }

  @MainActor
  func select(flags modifierFlags: NSEvent.ModifierFlags) {
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        navigator.isManualMultiSelect = false
        history.startPasteStack(selection: &navigator.selection, flags: modifierFlags)
      } else {
        history.select(navigator.selection.first, flags: modifierFlags)
      }
    } else if let item = footer.selectedItem {
      // TODO: Use item.suppressConfirmation, but it's not updated!
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Clipboard.shared.copyInMaccy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }

    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences() {
    if settingsWindowController == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      window.title = NSLocalizedString("Preferences", comment: "")
      window.titlebarAppearsTransparent = true
      window.isReleasedWhenClosed = false
      // Preferences should follow the current Space instead of reopening in the
      // Space where the window was first created. This is especially important
      // when Yippy is opened from a full-screen app or another display.
      window.collectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenAuxiliary]
      center(window, on: preferredSettingsScreen())
      window.contentView = NSHostingView(
        rootView: PreferencesView()
          .environment(self)
          .modelContainer(Storage.shared.container)
      )
      settingsWindowController = NSWindowController(window: window)
    }

    guard let window = settingsWindowController?.window else { return }

    centerIfNeeded(window, on: preferredSettingsScreen())
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }

  @MainActor
  private func preferredSettingsScreen() -> NSScreen? {
    if let panel = appDelegate?.panel, panel.isVisible, let screen = panel.screen {
      return screen
    }
    return NSScreen.main
  }

  @MainActor
  private func center(_ window: NSWindow, on screen: NSScreen?) {
    guard let screen else {
      window.center()
      return
    }

    let visibleFrame = screen.visibleFrame
    let origin = NSPoint(
      x: visibleFrame.midX - window.frame.width / 2,
      y: visibleFrame.midY - window.frame.height / 2
    )
    window.setFrameOrigin(origin)
  }

  @MainActor
  private func centerIfNeeded(_ window: NSWindow, on screen: NSScreen?) {
    guard !window.isVisible, let screen else { return }

    let isAlreadyOnTargetScreen = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
      as? NSNumber == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    if !isAlreadyOnTargetScreen || !window.frame.intersects(screen.visibleFrame) {
      center(window, on: screen)
    }
  }

  func quit() {
    NSApp.terminate(self)
  }
}

private struct PreferencesView: View {
  enum Section: String, CaseIterable, Identifiable {
    case general, storage, appearance, pins, ignore, advanced

    var id: Self { self }

    var title: LocalizedStringKey {
      switch self {
      case .general: "General"
      case .storage: "Storage"
      case .appearance: "Appearance"
      case .pins: "Pins"
      case .ignore: "Ignore"
      case .advanced: "Advanced"
      }
    }

    var subtitle: LocalizedStringKey {
      switch self {
      case .general: "Startup, shortcuts, and paste behavior"
      case .storage: "What Yippy keeps and how it is organized"
      case .appearance: "How the clipboard window looks and behaves"
      case .pins: "Manage your saved clipboard items"
      case .ignore: "Exclude apps, content types, and patterns"
      case .advanced: "Safety controls and data management"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .storage: "externaldrive"
      case .appearance: "paintpalette"
      case .pins: "pin"
      case .ignore: "eye.slash"
      case .advanced: "slider.horizontal.3"
      }
    }
  }

  @State private var selection: Section? = .general

  var body: some View {
    NavigationSplitView {
      List(Section.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.symbol)
          .tag(section)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 230)
    } detail: {
      if let selection {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 5) {
            Text(selection.title)
              .font(.system(size: 24, weight: .bold))
            Text(selection.subtitle)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 32)
          .padding(.top, 28)
          .padding(.bottom, 20)

          Divider()

          ScrollView {
            page(for: selection)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(32)
          }
        }
        .background(.background)
      }
    }
    .frame(width: 980, height: 680)
  }

  @ViewBuilder
  private func page(for section: Section) -> some View {
    switch section {
    case .general:
      GeneralSettingsPane()
    case .storage:
      StorageSettingsPane()
    case .appearance:
      AppearanceSettingsPane()
    case .pins:
      PinsSettingsPane()
    case .ignore:
      IgnoreSettingsPane()
    case .advanced:
      AdvancedSettingsPane()
    }
  }
}
