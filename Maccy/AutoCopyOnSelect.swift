import AppKit
import Defaults
import Logging
import Sauce

/// System-wide "hold Option, highlight text, release to copy".
///
/// When enabled, releasing the mouse while Option is held arms a pending
/// copy; once Option itself is then released, Cmd+C is synthesized in the
/// active application, so the highlighted text lands on the system clipboard
/// (and therefore in history) without the user having to press Cmd+C
/// themselves. Firing only has to wait for Option to physically lift because
/// the synthetic event otherwise inherits the still-held Option flag.
///
/// Strictly opt-in (off by default): it injects keystrokes into other
/// applications and needs Accessibility access, just like paste-by-default.
enum AutoCopyOnSelect {
  private static let logger = Logger(label: "dev.cosmos0118.Yippy")
  private static var mouseUpMonitor: Any?
  private static var flagsChangedMonitor: Any?
  private static var observeTask: Task<Void, Never>?

  // Set at mouse-up while Option is still held, and consumed once Option is
  // actually released (see handleFlagsChanged). 0 means "nothing pending".
  private static var pendingArmToken = 0
  private static var nextArmToken = 1

  static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

  static func start() {
    stop()
    observeTask = Task {
      for await enabled in Defaults.updates(.autoCopyOnOptionSelect, initial: true) {
        await MainActor.run { setEnabled(enabled) }
      }
    }
  }

  static func stop() {
    observeTask?.cancel()
    observeTask = nil
    setEnabled(false)
  }

  /// Prompts the system Accessibility dialog. Only call this from an explicit
  /// user action (toggling the setting on, or a "Grant Access" button) —
  /// never automatically on launch, or it pops a system dialog unprompted
  /// every time the app starts.
  static func requestAccessibilityAccess() {
    guard !AXIsProcessTrusted() else {
      return
    }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  /// Pure decision helper, extracted for testability.
  static func shouldAutoCopy(
    flags: NSEvent.ModifierFlags,
    isEnabled: Bool,
    isPaused: Bool,
    isYippyActive: Bool
  ) -> Bool {
    guard isEnabled, !isPaused, !isYippyActive else {
      return false
    }
    return flags.intersection(.deviceIndependentFlagsMask).contains(.option)
  }

  private static func setEnabled(_ enabled: Bool) {
    if let mouseUpMonitor {
      NSEvent.removeMonitor(mouseUpMonitor)
      self.mouseUpMonitor = nil
    }
    if let flagsChangedMonitor {
      NSEvent.removeMonitor(flagsChangedMonitor)
      self.flagsChangedMonitor = nil
    }
    pendingArmToken = 0
    guard enabled else {
      return
    }
    mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
      handleMouseUp(event)
    }
    flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
      handleFlagsChanged(event)
    }
    // Global mouse monitors and synthesized keystrokes silently do nothing
    // without Accessibility trust — and every rebuild re-signs the binary,
    // which can silently invalidate a previous grant. Trust is re-checked
    // live at copy time below, so no toggle-off-and-on is needed once it's
    // granted; this just explains a currently-missing grant in the logs.
    if !AXIsProcessTrusted() {
      logger.warning(
        """
        Auto-copy on Option-select is enabled but Yippy is not trusted under \
        System Settings → Privacy & Security → Accessibility, so selections \
        cannot be observed or copied. Grant access from the Auto-copy setting \
        (after every rebuild, remove and re-add Yippy there).
        """
      )
    }
  }

  /// Arms a pending copy when Option is held through mouse-up; the actual
  /// copy fires later, once Option is released (see handleFlagsChanged).
  ///
  /// This can't fire immediately: the synthetic ⌘C below is built from
  /// `.combinedSessionState`, which merges the real, currently-held hardware
  /// modifiers into the posted event. Firing while Option is still physically
  /// down would deliver ⌘⌥C to the target app instead of ⌘C, which most apps
  /// don't recognize as copy.
  private static func handleMouseUp(_ event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard shouldAutoCopy(
      flags: flags,
      isEnabled: Defaults[.autoCopyOnOptionSelect],
      isPaused: Defaults[.ignoreEvents],
      isYippyActive: NSApp.isActive
    ) else {
      pendingArmToken = 0
      return
    }
    let token = nextArmToken
    nextArmToken += 1
    pendingArmToken = token
  }

  private static func handleFlagsChanged(_ event: NSEvent) {
    guard pendingArmToken != 0 else {
      return
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // Still held — wait for the event where it actually drops out.
    guard !flags.contains(.option) else {
      return
    }
    let token = pendingArmToken
    // Let the key-up fully propagate before injecting our own keystroke.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      fireIfArmed(token)
    }
  }

  private static func fireIfArmed(_ token: Int) {
    guard token != 0, token == pendingArmToken else {
      return
    }
    pendingArmToken = 0
    guard Defaults[.autoCopyOnOptionSelect], !Defaults[.ignoreEvents] else {
      return
    }
    // Trust can be revoked (or invalidated by a rebuild) at any time;
    // posting keystrokes while untrusted silently does nothing.
    guard AXIsProcessTrusted() else {
      return
    }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
      return
    }
    simulateCopy()
  }

  private static func simulateCopy() {
    Accessibility.check()
    // Mirror Clipboard.paste(): flag that a modifier was pressed and force
    // the QWERTY keycode when the layout switches to QWERTY while ⌘ is held.
    let commandFlag = CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.command.rawValue) | 0x000008)
    var keyCode = Sauce.shared.keyCode(for: Key.c)
    if KeyboardLayout.current.commandSwitchesToQWERTY {
      keyCode = Key.c.QWERTYKeyCode
    }
    let source = CGEventSource(stateID: .combinedSessionState)
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyDown?.flags = commandFlag
    keyUp?.flags = commandFlag
    keyDown?.post(tap: .cgSessionEventTap)
    keyUp?.post(tap: .cgSessionEventTap)
  }
}
