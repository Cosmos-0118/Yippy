import AppKit.NSRunningApplication
import Defaults
import Foundation
import KeyboardShortcuts
import Observation

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

/// Tracks a hold-and-repeat cycling session started by the popup shortcut.
///
/// The snapshot is captured once, when cycling begins, so each subsequent
/// press only needs to advance an index -- O(1) -- instead of re-scanning
/// history to find "the current item" and then "the next item" (O(n) per
/// press, approaching O(n^2) over a full cycle through history).
private struct CycleSession {
  let id = UUID()
  let snapshot: [HistoryItemDecorator]
  var index: Int
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
  private var cycleSession: CycleSession?
  private var pendingCycleRender = false

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
    endCycleSession()
    KeyboardShortcuts.enable(.popup)
  }

  func close(afterFocusRestored completion: (() -> Void)? = nil) {
    AppState.shared.appDelegate?.panel.dismiss(afterFocusRestored: completion)  // close() calls reset
  }

  func isClosed() -> Bool {
    AppState.shared.appDelegate?.panel.isPresented != true
  }

  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    let height = newHeight

    var minHeight = self.minimumHeight
    // If the preview is non-empty make sure the window accomodates for it to be visible.
    if AppState.shared.preview.state.isOpen && AppState.shared.navigator.leadSelection != nil {
      minHeight = max(minHeight, Self.minimumPreviewHeight)
    }
    minHeight = max(headerHeight + Self.verticalPadding, minHeight)

    return WindowSizing.openingHeight(
      requested: height,
      saved: Defaults[.windowSize].height,
      minimum: minHeight
    )
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
    if isHotKeyCode(Int(event.keyCode)) {
      // Skip once cycling has begun: this is an O(n) scan over history, and
      // continuing to run it on every repeat press could let a shortcut that
      // collides with a numbered/pinned item's own shortcut hijack the
      // press and paste immediately instead of cycling.
      if state != .cycle, let item = History.shared.pressedShortcutItem {
        AppState.shared.navigator.select(item: item)
        let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
        Task { @MainActor in
          AppState.shared.history.select(item, flags: modifierFlags)
        }
        return nil
      }

      if state == .opening {
        state = .cycle
        beginCycleSession()
        // Next 'if' will advance to the next item and then return nil
      }

      if state == .cycle {
        // History-only: this cycle is confirmed by releasing modifiers (see
        // handleFlagsChanged below), which immediately acts on whatever is
        // highlighted. Landing on a footer item (Clear, Preferences, About,
        // Quit) there would run that action instead of pasting a history
        // item, so the cycle session's snapshot never includes them.
        advanceCycleSession()
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
    // If we are in cycle mode, releasing a modifier the shortcut requires
    // triggers a selection -- e.g. for a ⌘⇧C shortcut, releasing Shift while
    // still holding Command is enough to commit, matching how holding one
    // key while tapping another to cycle (e.g. ⌘-Tab) normally works.
    if state == .cycle && requiredModifierReleased(event) {
      let sessionID = cycleSession?.id
      // Only residual modifiers beyond the shortcut's own decide the paste
      // action (HistoryItemAction). The shortcut's own modifiers are how
      // cycling was invoked, not a requested action, and since cycling can
      // now commit before every one of them is released, a lone leftover
      // shortcut modifier (e.g. bare .shift from a ⌘⇧C shortcut) must not
      // reach HistoryItemAction, where it would resolve to .unknown and
      // silently commit nothing.
      let shortcutModifiers = KeyboardShortcuts.Name.popup.shortcut?.modifiers ?? []
      let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
        .subtracting(shortcutModifiers)
      DispatchQueue.main.async { [weak self] in
        // A session ID guard: without it, a commit delayed behind the main
        // queue could land on a cycle session started after this one.
        guard let self, self.cycleSession?.id == sessionID else { return }
        self.endCycleSession()
        AppState.shared.select(flags: modifierFlags)
      }
      return nil
    }

    // Otherwise if in opening mode, enter toggle mode
    if state == .opening && requiredModifierReleased(event) {
      state = .toggle
      return event
    }

    return event
  }

  private func beginCycleSession() {
    let snapshot = AppState.shared.history.visibleItems
    guard !snapshot.isEmpty else { return }

    // -1 when nothing is currently selected (e.g. a paste stack is active,
    // or this press raced the view's initial-selection setup) so the first
    // advance below lands on index 0 -- matching highlightFirst()'s old
    // fallback -- instead of skipping straight to index 1.
    let startIndex = AppState.shared.navigator.leadSelection
      .flatMap { id in snapshot.firstIndex { $0.id == id } } ?? -1

    cycleSession = CycleSession(snapshot: snapshot, index: startIndex)
    AppState.shared.preview.disableAutoOpen()
  }

  private func advanceCycleSession() {
    guard var session = cycleSession, !session.snapshot.isEmpty else {
      // No usable snapshot (e.g. history was empty when cycling began);
      // fall back to ordinary navigation rather than doing nothing.
      AppState.shared.navigator.highlightNextHistoryItem()
      return
    }

    session.index = (session.index + 1) % session.snapshot.count
    cycleSession = session
    scheduleCycleRender()
  }

  /// Coalesces visual updates to once per main-run-loop turn: rapid presses
  /// (e.g. OS key-repeat while the shortcut key is held down) can advance
  /// the index many times before SwiftUI gets a chance to render, but only
  /// the latest pending index needs to actually be applied.
  private func scheduleCycleRender() {
    guard !pendingCycleRender else { return }
    pendingCycleRender = true

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingCycleRender = false
      guard let session = self.cycleSession else { return }
      AppState.shared.navigator.selectForCycling(session.snapshot[session.index])
    }
  }

  private func endCycleSession() {
    guard cycleSession != nil else { return }
    cycleSession = nil
    pendingCycleRender = false
    AppState.shared.preview.enableAutoOpen()
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

  /// True once the event no longer holds down every modifier the popup
  /// shortcut itself requires -- not necessarily every modifier key on the
  /// keyboard. For a multi-modifier shortcut (e.g. ⌘⇧C) this fires as soon
  /// as the first of its modifiers is released, rather than waiting for all
  /// of them (which could also be delayed by an unrelated modifier like Fn
  /// or Caps Lock still being reported as held).
  private func requiredModifierReleased(_ event: NSEvent) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else { return true }

    let required = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
    let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return !current.isSuperset(of: required)
  }
}
