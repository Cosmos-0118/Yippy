import Defaults
import KeyboardShortcuts
import Logging
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  static let isTesting = CommandLine.arguments.contains("enable-testing")
  static weak var shared: AppDelegate?
  var panel: FloatingPanel<ContentView>!

  private let logger = Logger(label: "dev.cosmos0118.Yippy")

  private lazy var menuBarPopover: NSPopover = {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = NSSize(width: 280, height: 252)
    popover.contentViewController = NSHostingController(rootView: MenuBarDropdownView())
    return popover
  }()

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Base accessibility label for the status item; kept separate from the optional
  // dynamic `title` (recent copy text) so VoiceOver always announces something
  // meaningful even when that preference is off or the app is disabled.
  private func updateStatusItemAccessibilityLabel() {
    let base = NSLocalizedString("status_item_accessibility_label", comment: "")
    statusItem.button?.setAccessibilityLabel(
      isStatusItemDisabled ? "\(base) — \(NSLocalizedString("status_item_disabled_accessibility_suffix", comment: ""))" : base
    )
  }

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    Self.shared = self
    #if DEBUG
    if Self.isTesting {
      SPUUpdater(hostBundle: Bundle.main,
                 applicationBundle: Bundle.main,
                 userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil),
                 delegate: nil)
      .automaticallyChecksForUpdates = false
      // Start from a clean slate for the isolated testing preferences.
      UserDefaults.standard.removePersistentDomain(forName: Defaults.Keys.testingSuiteName)
    }
    #endif

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    Clipboard.shared.start()
    AutoCopyOnSelect.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    updateStatusItemAccessibilityLabel()

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    if #available(macOS 15, *) {
      Storage.shared.pruneHistoryLogIfNeeded()
    }

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "dev.cosmos0118.Yippy",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }

    // Unlike title sanitization, nothing renders orphaned contents, so this
    // has no reason to block the panel's appearance — it runs after launch.
    Task {
      await migrateOrphanedContentsIfNeeded()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  // The key is only recorded once `action` returns without throwing, so a
  // failed migration (e.g. SQLITE_FULL during cleanup) retries on next
  // launch instead of being silently treated as done forever.
  private func ensureMigration(key: String, _ action: () throws -> Void) rethrows {
    guard Defaults[.migrations][key] != true else {
      return
    }

    try action()
    Defaults[.migrations][key] = true
  }

  private func ensureMigrationAsync(key: String, _ action: () async throws -> Void) async rethrows {
    guard Defaults[.migrations][key] != true else {
      return
    }

    try await action()
    Defaults[.migrations][key] = true
  }

  @MainActor
  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")
    }

    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      var types = Defaults[.enabledPasteboardTypes]
      if !types.isDisjoint(with: StorageType.images.types) {
        types.formUnion(StorageType.images.types)
      }
      Defaults[.enabledPasteboardTypes] = types
    }

    // Re-dated (was "2026-08-31-..."): that key could already be marked done
    // for installs where the old unconditional-write bug silently swallowed a
    // failure. The new date gives every install one retry under the now-
    // correct throw-and-log handling.
    do {
      try ensureMigration(key: "2026-09-12-sanitize-history-item-titles") {
        _ = try Storage.shared.sanitizeTitles()
      }
    } catch {
      logger.error("Failed to sanitize history item titles: \(String(reflecting: error))")
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  private func migrateOrphanedContentsIfNeeded() async {
    // Re-dated for the same reason as the title-sanitization key above: gives
    // installs where the old unconditional-write bug already marked this
    // "done" one retry under the now-correct throw-and-log handling.
    do {
      try await ensureMigrationAsync(key: "2026-09-12-cleanup-orphaned-history-item-contents") {
        let deletedCount = try await Storage.shared.cleanupOrphanedContents()
        guard deletedCount > 0 else {
          return
        }

        // Cleanup itself writes persistent-history rows for every delete; force
        // an unthrottled prune so they don't sit in the log until the next
        // throttle window instead of riding along with today's regular prune.
        Defaults[.lastHistoryLogPruneAt] = .distantPast
        if #available(macOS 15, *) {
          await Storage.shared.pruneHistoryLogIfNeeded()
        }
      }
    } catch {
      logger.error("Failed to clean up orphaned history item contents: \(String(reflecting: error))")
    }
  }

  @objc
  private func performStatusItemClick() {
    if let event = NSApp.currentEvent {
      let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      if modifierFlags.contains(.option) {
        Defaults[.ignoreEvents].toggle()

        if modifierFlags.contains(.shift) {
          Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
        }

        return
      }
    }

    // The status item has one presentation at a time. In particular, after
    // “Open Clipboard” the next click must close the clipboard panel rather
    // than reveal the menu underneath it.
    if menuBarPopover.isShown {
      dismissMenuBarDropdown()
    } else if panel.isPresented {
      panel.close()
    } else {
      showMenuBarDropdown()
    }
  }

  private func showMenuBarDropdown() {
    guard let button = statusItem.button else { return }

    if menuBarPopover.isShown {
      dismissMenuBarDropdown()
      return
    }

    // Clicking a status item never activates an agent (LSUIElement) app, so the
    // popover would come up in an inactive application: its window cannot become
    // key, controls render in their inactive gray state, and anything opened from
    // it inherits the same non-active application. Activate synchronously, while
    // still inside the click handler, because macOS 14+ cooperative activation
    // only honours the request while the user interaction that triggered it is
    // current — a deferred activate can be silently denied.
    NSApp.activate(ignoringOtherApps: true)
    menuBarPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

    // Activation completes asynchronously, so the popover's window cannot become
    // key during this turn of the runloop. Claim key status once the application
    // is actually active, otherwise the popover stays in its inactive appearance
    // and keyboard input keeps going to the previously frontmost application.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.menuBarPopover.isShown else { return }
      self.menuBarPopover.contentViewController?.view.window?.makeKey()
    }
  }

  func dismissMenuBarDropdown() {
    // `performClose` mimics a user-driven close (animated, delegate-consulted)
    // and can still hold key/activation status across the runloop tick that
    // follows, racing whatever window we open right after. `close()` tears
    // the popover down immediately, so the next window's `makeKey`/`activate`
    // isn't fighting a popover still relinquishing focus.
    menuBarPopover.close()
  }

  func openClipboardFromMenuBar() {
    // Finish the transient popover interaction before making the panel key.
    dismissMenuBarDropdown()
    DispatchQueue.main.async {
      self.panel.open(
        height: AppState.shared.popup.height,
        at: .statusItem
      )

      // The menu popover may already have made the application active, so the
      // panel does not reliably receive the activation transition that normally
      // initializes selection. Do it explicitly for this mouse-driven route.
      DispatchQueue.main.async {
        let appState = AppState.shared
        appState.navigator.hoverSelectionWhileKeyboardNavigating = nil
        appState.navigator.isKeyboardNavigating = false
        appState.navigator.selectWithoutScrolling(
          item: appState.history.unpinnedItems.first ?? appState.history.pinnedItems.first
        )
      }
    }
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      Task { @MainActor in
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .togglePreview]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, names.contains(name) {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}

private struct MenuBarDropdownView: View {
  @Default(.ignoreEvents) private var ignoreEvents

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(nsImage: Defaults[.menuIcon].image)
          .resizable()
          .scaledToFit()
          .frame(width: 24, height: 24)
          .padding(7)
          .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text("Yippy")
            .font(.headline)
          Text("Clipboard history, ready when you are")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Button {
        AppDelegate.shared?.openClipboardFromMenuBar()
      } label: {
        Label("Open Clipboard", systemImage: "clipboard")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .background(Color.accentColor, in: Capsule())
          .contentShape(Capsule())
      }
      // A custom surface for the primary action: it keeps the accent fill
      // independent of the popover's key state, which still lags by a runloop
      // turn while the application activates.
      .buttonStyle(.plain)

      Divider()

      Toggle(isOn: $ignoreEvents) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Pause clipboard history")
          Text("Yippy will not save new copies while paused.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)

      Divider()

      HStack {
        Button("Preferences…") {
          AppDelegate.shared?.dismissMenuBarDropdown()
          // Same reasoning as `openClipboardFromMenuBar`: activating/keying
          // another window in the same runloop tick as the dismissal races
          // the popover's own teardown and can leave Preferences frontmost
          // but not actually key.
          DispatchQueue.main.async {
            AppState.shared.openPreferences()
          }
        }

        Spacer()

        Button("Quit Yippy") {
          NSApp.terminate(nil)
        }
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: 280)
  }

}
