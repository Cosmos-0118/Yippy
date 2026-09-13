import AppKit.NSRunningApplication
import Defaults
import KeyboardShortcuts
import Logging
import Observation

private let popupLogger = Logger(label: "dev.cosmos0118.Yippy.popup")

enum PopupState {
  // Default; shortcut will toggle the popup
  case toggle
  // In this mode, every additional press of the main key
  // will cycle to the next item in the paste history list.
  // Releasing the modifier keys will accept selection and close the popup
  case cycle
  // Transition state when the shortcut is first pressed and
  // we don't know whether we are in "toggle" or "cycle" mode.
  case opening
}

@Observable
class Popup {
  static let verticalSeparatorPadding = 6.0
  static let horizontalSeparatorPadding = 6.0
  static let verticalPadding: CGFloat = 5
  static let horizontalPadding: CGFloat = 5
  static let minimumPreviewHeight: CGFloat = 150

  // Radius used for items inset by the padding. Ensures they visually have the same curvature
  // as the menu.
  static let cornerRadius: CGFloat = if #available(macOS 26.0, *) {
    7
  } else {
    4
  }

  static let itemHeight: CGFloat = if #available(macOS 26.0, *) {
    24
  } else {
    22
  }

  var needsResize = false
  var height: CGFloat = 0
  var headerHeight: CGFloat = 0
  var extraTopHeight: CGFloat = 0
  var extraBottomHeight: CGFloat = 0
  var footerHeight: CGFloat = 0

  var minimumHeight: CGFloat {
    // Reserve space for 3 items
    return suitableHeight(for: 3 * Popup.itemHeight)
  }

  private var eventsMonitor: Any?

  private var state: PopupState = .toggle

  init() {
    KeyboardShortcuts.onKeyDown(for: .popup, action: handleFirstKeyDown)
    initEventsMonitor()
  }

  deinit {
    deinitEventsMonitor()
  }

  func initEventsMonitor() {
    guard eventsMonitor == nil else { return }

    self.eventsMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown],
      handler: handleEvent
    )
  }

  func deinitEventsMonitor() {
    guard let eventsMonitor else { return }

    NSEvent.removeMonitor(eventsMonitor)
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    AppState.shared.appDelegate?.panel.open(height: height, at: popupPosition)
  }

  func reset() {
    state = .toggle
    KeyboardShortcuts.enable(.popup)
  }

  func close() {
    AppState.shared.appDelegate?.panel.close()  // close() calls reset
  }

  func isClosed() -> Bool {
    AppState.shared.appDelegate?.panel.isPresented != true
  }

  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    var height = newHeight

    var minHeight = self.minimumHeight
    // If the preview is non-empty make sure the window accomodates for it to be visible.
    if AppState.shared.preview.state.isOpen && AppState.shared.navigator.leadSelection != nil {
      minHeight = max(minHeight, Self.minimumPreviewHeight)
    }
    minHeight = max(headerHeight + Self.verticalPadding, minHeight)

    height = max(height, minHeight)
    height = min(height, Defaults[.windowSize].height)
    return height
  }

  private func suitableHeight(for historyListHeight: CGFloat) -> CGFloat {
    return historyListHeight + headerHeight + extraTopHeight + extraBottomHeight + footerHeight
  }

  func resize(height: CGFloat) {
    self.height = suitableHeight(for: height)
    AppState.shared.appDelegate?.panel.verticallyResize(to: preferredHeight(for: self.height))
    needsResize = false
  }

  private func handleFirstKeyDown() {
    popupLogger.warning("[diag] handleFirstKeyDown isClosed=\(isClosed()) isActive=\(NSApp.isActive)")
    if isClosed() {
      open(height: height)
      state = .opening
      KeyboardShortcuts.disable(.popup)  // Handle events via eventsMonitor. Re-enable on popup close
      return
    }

    // Maccy was not opened via shortcut. We assume toggle mode and close it
    close()
  }

  private func handleEvent(_ event: NSEvent) -> NSEvent? {
    // While a `KeyboardShortcuts.Recorder` is recording, let its keys through untouched. Without
    // this, a press that matches the *currently saved* "Open" shortcut's key code (e.g. Space,
    // regardless of modifiers) gets swallowed here before the recorder's own monitor -- which is
    // installed later, on focus -- ever sees it. This is why recording only failed for a
    // specific key combo rather than every key.
    guard !KeyboardShortcuts.isPaused else { return event }

    popupLogger.warning(
      "[diag] handleEvent type=\(event.type.rawValue) state=\(state) isActive=\(NSApp.isActive) isKeyWindow=\(AppState.shared.appDelegate?.panel.isKeyWindow ?? false)"
    )

    switch event.type {
    case .keyDown:
      return handleKeyDown(event)
    case .flagsChanged:
      return handleFlagsChanged(event)
    default:
      return event
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    popupLogger.warning(
      "[diag] handleKeyDown keyCode=\(event.keyCode) isHotKeyCode=\(isHotKeyCode(Int(event.keyCode))) state=\(state)"
    )
    if isHotKeyCode(Int(event.keyCode)) {
      if let item = History.shared.pressedShortcutItem {
        AppState.shared.navigator.select(item: item)
        let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
        Task { @MainActor in
          AppState.shared.history.select(item, flags: modifierFlags)
        }
        return nil
      }

      if state == .opening {
        state = .cycle
        // Next 'if' will highlight next item and then return nil
      }

      if state == .cycle {
        AppState.shared.navigator.highlightNext(allowCycle: true)
        return nil
      }

      if state == .toggle && isHotKeyModifiers(event.modifierFlags) {
        close()
        return nil
      }
    }

    return event
  }

  private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
    popupLogger.warning(
      "[diag] handleFlagsChanged flags=\(event.modifierFlags.rawValue) allReleased=\(allModifiersReleased(event)) state=\(state)"
    )
    // If we are in cycle mode, releasing modifiers triggers a selection
    if state == .cycle && allModifiersReleased(event) {
      let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
      // Selecting here can end in Clipboard.paste(), which synthesizes ⌘V via
      // a `.combinedSessionState` event source. That source merges the real,
      // currently-held hardware modifiers into posted events, and this fires
      // on the very flagsChanged event that reports the open shortcut's own
      // modifiers (e.g. ⇧⌘) as released — before that release has actually
      // propagated. Without a settle delay the target app can still receive
      // the old modifiers merged into the synthetic V, e.g. ⇧⌘V instead of
      // ⌘V, so it doesn't paste. Mirrors the same fix in AutoCopyOnSelect.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        AppState.shared.select(flags: modifierFlags)
      }
      return nil
    }

    // Otherwise if in opening mode, enter toggle mode
    if state == .opening && allModifiersReleased(event) {
      state = .toggle
      return event
    }

    return event
  }

  private func isHotKeyCode(_ keyCode: Int) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else {
      return false
    }

    return shortcut.key?.rawValue == keyCode
  }

  private func isHotKeyModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else {
      return false
    }

    return modifiers.intersection(.deviceIndependentFlagsMask) ==
      shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
  }

  private func allModifiersReleased(_ event: NSEvent) -> Bool {
    return event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
  }
}
