import AppKit

/// Synthesizing ⌘V / ⌘C only works while macOS trusts this exact binary for
/// Accessibility. Without trust, `CGEvent.post` is silently dropped, so the
/// callers must check first and tell the user -- never fail quietly.
enum Accessibility {
  private static var hasPromptedThisLaunch = false

  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Returns whether keystrokes can be posted. When not trusted, shows the
  /// system prompt once per launch (it is modal-ish and re-appears on every
  /// call otherwise) and returns false so the caller can fall back.
  @discardableResult
  static func check() -> Bool {
    guard !isTrusted else {
      return true
    }
    if !hasPromptedThisLaunch {
      hasPromptedThisLaunch = true
      AutoCopyOnSelect.requestAccessibilityAccess()
    }
    return false
  }
}
