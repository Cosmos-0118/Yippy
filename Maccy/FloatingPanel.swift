import Defaults
import SwiftUI

enum WindowSizing {
  static let defaultSize = NSSize(width: 500, height: 540)
  static let previousDefaultSize = NSSize(width: 450, height: 480)
  static let legacyDefaultSize = NSSize(width: 450, height: 800)
  static let comfortableOpeningHeight: CGFloat = 480
  // How much of the screen an un-customized window is allowed to fill while
  // auto-fitting to content, before it scrolls instead of growing further.
  static let autoFitScreenHeightFraction: CGFloat = 0.8

  static func migratedDefault(from size: NSSize) -> NSSize {
    [previousDefaultSize, legacyDefaultSize].contains(size) ? defaultSize : size
  }

  static func preferredHeight(requested: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    min(max(requested, minimum), max(maximum, minimum))
  }

  // Caps content-driven height (used both when opening and while the window
  // auto-grows during a session) at `saved` only once the user has actually
  // dragged the window to a size themselves -- `hasCustomSize`. Until then,
  // `saved` is just a stale leftover from whatever it last happened to be
  // (the shipped default, or an earlier auto-fit), so the real ceiling is a
  // generous fraction of the screen instead: the window fits its content up
  // to that, then scrolls, rather than reopening small forever because it
  // was never manually resized.
  static func openingHeight(
    requested: CGFloat,
    saved: CGFloat,
    minimum: CGFloat,
    hasCustomSize: Bool,
    screenMaximum: CGFloat
  ) -> CGFloat {
    let ceiling = hasCustomSize ? saved : screenMaximum * autoFitScreenHeightFraction
    let contentHeight = min(requested, ceiling)
    let comfortableHeight = min(comfortableOpeningHeight, ceiling)
    return max(max(contentHeight, comfortableHeight), minimum)
  }

  static func resizedPreference(
    previous: NSSize,
    liveResizeStart: NSSize,
    final: NSSize,
    contentWidth: CGFloat
  ) -> NSSize {
    NSSize(
      width: contentWidth,
      height: abs(final.height - liveResizeStart.height) > 0.5 ? final.height : previous.height
    )
  }
}

// An NSPanel subclass that implements floating panel traits.
// https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos
class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
  var isPresented: Bool = false
  var statusBarButton: NSStatusBarButton?
  let onClose: () -> Void

  // Whatever app was frontmost right before this panel took activation, so a
  // plain dismiss (Escape, toggle-close) can hand keyboard focus straight
  // back to it -- including the exact text field that had the caret, since
  // deactivating an app doesn't clear its window's first responder.
  private var previousApp: NSRunningApplication?
  private var liveResizeStartSize: NSSize?

  // Bumped on every `open`/`close`, so `open`'s own deferred reactivation
  // closures below can tell "the panel happens to be presented again" apart
  // from "this is still the same presentation it was scheduled from" before
  // acting. (`waitForActivation` has its own equivalent via `isPresented`,
  // since a close always precedes it.)
  private var presentationGeneration = 0

  override var isMovable: Bool {
    get { Defaults[.popupPosition] != .statusItem }
    set {}
  }

  init(
    contentRect: NSRect,
    identifier: String = "",
    statusBarButton: NSStatusBarButton? = nil,
    onClose: @escaping () -> Void,
    view: () -> Content
  ) {
    self.onClose = onClose

    super.init(
        contentRect: contentRect,
        styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )

    self.statusBarButton = statusBarButton
    self.identifier = NSUserInterfaceItemIdentifier(identifier)

    Defaults[.windowSize] = contentRect.size
    delegate = self

    animationBehavior = .none
    isFloatingPanel = true
    // Chrome autofill uses window layer 999; screenSaver (1000) sits just above it
    // while still covering status items / Spotlight. See #1403.
    level = .screenSaver
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    backgroundColor = .clear
    titlebarSeparatorStyle = .none

    // Hide all traffic light buttons
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    contentView = NSHostingView(
      rootView: view()
        // The safe area is ignored because the title bar still interferes with the geometry
        .ignoresSafeArea()
        .gesture(DragGesture()
          .onEnded { _ in
            self.saveWindowPosition()
        })
    )
    contentView?.layer?.cornerRadius = Popup.cornerRadius + Popup.horizontalPadding
  }

  func toggle(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if isPresented {
      dismiss()
    } else {
      open(height: height, at: popupPosition)
    }
  }

  func open(
    height: CGFloat,
    at popupPosition: PopupPosition = Defaults[.popupPosition],
    restoringFocusTo sourceApp: NSRunningApplication? = nil
  ) {
    // Capture this before we activate ourselves below -- afterward,
    // `frontmostApplication` would just be us.
    if !isPresented {
      let candidate = sourceApp ?? NSWorkspace.shared.frontmostApplication
      if candidate?.bundleIdentifier != Bundle.main.bundleIdentifier,
         candidate?.isTerminated == false {
        previousApp = candidate
      } else {
        previousApp = nil
      }
    }

    let size = Defaults[.windowSize]
    let miniumHeight: CGFloat = AppState.shared.popup.minimumHeight
    let finalWidth = min(frame.width, size.width)
    let screenMaximum = screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? size.height
    let finalHeight = WindowSizing.openingHeight(
      requested: height,
      saved: size.height,
      minimum: miniumHeight,
      hasCustomSize: Defaults[.hasCustomWindowSize],
      screenMaximum: screenMaximum
    )
    setContentSize(NSSize(width: finalWidth, height: finalHeight))
    setFrameOrigin(popupPosition.origin(size: frame.size, statusBarButton: statusBarButton))
    // `orderFrontRegardless()` deliberately does not activate an agent app.
    // That leaves this panel visibly frontmost but unable to receive keyboard
    // input when it is opened over another application's full-screen Space.
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    isPresented = true
    presentationGeneration += 1
    let generation = presentationGeneration

    // Moving into a full-screen Space is asynchronous. Reassert key status on
    // the next turn so the source application cannot reclaim it during that
    // transition. The generation check catches what a plain `isPresented`
    // check can't: a close followed by a fresh reopen before this runs,
    // where `isPresented` is true again but for a different presentation
    // than the one that scheduled this closure.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isPresented, self.presentationGeneration == generation else { return }
      NSApp.activate(ignoringOtherApps: true)
      self.makeKeyAndOrderFront(nil)
    }

    if popupPosition == .statusItem {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.presentationGeneration == generation else { return }
        self.statusBarButton?.isHighlighted = true
      }
    }
  }

  func verticallyResize(to newHeight: CGFloat) {
    var newSize = frame.size
    let screenMaximum = screen?.visibleFrame.height ?? newHeight
    newSize.height = WindowSizing.preferredHeight(
      requested: newHeight,
      minimum: AppState.shared.popup.minimumHeight,
      maximum: screenMaximum
    )

    // Reject sub-pixel/no-op targets: content height is recalculated on every
    // keystroke while searching, and without this a settled window would
    // keep restarting this 200ms animation from itself to itself.
    guard abs(newSize.height - frame.size.height) >= 0.5 else { return }

    var newOrigin = frame.origin
    newOrigin.y += (frame.height - newSize.height)

    NSAnimationContext.runAnimationGroup { (context) in
      context.duration = 0.2
      animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }
  }

  func determinePreviewPlacement() {
    let preview = AppState.shared.preview
    guard !preview.state.isOpen else { return }
    let newSize = preview.computeSizeWithPreview(frame.size, state: .open)
    preview.placement = preview.computePlacement(window: self, for: newSize)
  }

  func saveWindowPosition() {
    if let screenFrame = screen?.visibleFrame {
      // Only store the size of the window without the preview
      let width = AppState.shared.preview.contentWidth

      let anchorX = frame.minX + width / 2 - screenFrame.minX
      let anchorY = frame.maxY - screenFrame.minY
      Defaults[.windowPosition] = NSPoint(x: anchorX / screenFrame.width, y: anchorY / screenFrame.height)
    }
  }

  func saveWindowFrame(frame: NSRect) {
    Defaults[.windowSize] = frame.size
    saveWindowPosition()
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let preview = AppState.shared.preview

    if inLiveResize && preview.resizingMode == .none {
      let screenPoint = NSEvent.mouseLocation
      let windowPoint = convertPoint(fromScreen: screenPoint)
      let location: SlideoutPlacement = windowPoint.x <= frame.width / 2 ? .left : .right
      if (location == preview.placement) && preview.state == .open {
        preview.startResize(mode: .slideout)
      } else {
        preview.startResize(mode: .content)
      }
    }

    var finalFrameSize = frameSize
    var minContent = preview.minimumContentWidth
    var minPreview = 0.0

    if inLiveResize && preview.resizingMode != .none {
      if preview.resizingMode == .content && preview.state == .open {
        minPreview = preview.slideoutWidth
      }
      if preview.resizingMode == .slideout {
        minPreview = preview.minimumSlideoutWidth
        minContent = preview.contentWidth
      }
    }
    finalFrameSize.width = max(finalFrameSize.width, minContent + minPreview)

    let minimumHeight = AppState.shared.popup.minimumHeight
    finalFrameSize.height = max(finalFrameSize.height, minimumHeight)

    return finalFrameSize
  }

  func windowWillMove(_ notification: Notification) {
    determinePreviewPlacement()
  }

  func windowDidMove(_ notification: Notification) {
    determinePreviewPlacement()
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    liveResizeStartSize = frame.size
    AppState.shared.preview.cancelAutoOpen()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    let previousSize = Defaults[.windowSize]
    let size = WindowSizing.resizedPreference(
      previous: previousSize,
      liveResizeStart: liveResizeStartSize ?? frame.size,
      final: frame.size,
      contentWidth: AppState.shared.preview.contentWidth
    )
    // `resizedPreference` only changes the height when this drag actually
    // moved it (leaving a width-only resize's height as `previous`) -- that
    // is exactly "the user deliberately chose a height," which is what
    // should stop the window from auto-fitting to content from now on.
    if size.height != previousSize.height {
      Defaults[.hasCustomWindowSize] = true
    }
    liveResizeStartSize = nil
    saveWindowFrame(frame: NSRect(origin: frame.origin, size: size))

    AppState.shared.preview.startAutoOpen()
    AppState.shared.preview.endResize()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    AppState.shared.preview.enableAutoOpen()

    if AppState.shared.navigator.leadHistoryItem != nil {
      AppState.shared.preview.startAutoOpen()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    AppState.shared.preview.disableAutoOpen()
  }

  // Close automatically when out of focus, e.g. outside click.
  override func resignKey() {
    super.resignKey()
    // Don't hide if confirmation is shown.
    if isPresented && NSApp.alertWindow == nil {
      // Something else already became key/active to cause this (e.g. the
      // user clicked into a different app), so there's nothing to restore --
      // reactivating `previousApp` here would fight whatever the user just
      // switched to. Plain `close()` skips that; `dismiss()` is for the
      // paths where *we* are the one ending the interaction.
      close()
    }
  }

  /// Ends the panel interaction and, unless told otherwise, hands keyboard
  /// focus back to whatever app (and text field) was active before this
  /// panel took it. Use this for every dismissal *we* initiate -- Escape,
  /// pressing the toggle shortcut again, or selecting a history item -- so a
  /// glance-and-cancel doesn't leave the app you were typing in deactivated.
  func dismiss(restoringFocus: Bool = true, afterFocusRestored completion: (() -> Void)? = nil) {
    let appToRestore = restoringFocus ? previousApp : nil
    previousApp = nil
    close()

    guard let appToRestore else {
      completion?()
      return
    }
    guard !appToRestore.isTerminated else {
      return
    }

    if NSWorkspace.shared.frontmostApplication?.processIdentifier == appToRestore.processIdentifier {
      completion?()
      return
    }

    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }

    appToRestore.activate()
    waitForActivation(of: appToRestore, completion: completion)
  }

  /// Resolves `completion` exactly once, as soon as `app` actually becomes
  /// frontmost -- via `NSWorkspace`'s activation notification instead of
  /// polling every 50ms, which was long enough on a slow full-screen Space
  /// transition to exhaust its fixed retry budget and silently drop a
  /// completion (e.g. a pending paste) that would have succeeded a moment
  /// later. Gives up -- without invoking `completion` -- if the user
  /// activates a third app, this panel gets presented again, or half a
  /// second passes with no activation at all.
  private func waitForActivation(of app: NSRunningApplication, completion: (() -> Void)?) {
    var observer: NSObjectProtocol?
    var resolved = false

    func finish(invokingCompletion: Bool) {
      guard !resolved else { return }
      resolved = true
      if let observer {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
      }
      if invokingCompletion {
        completion?()
      }
    }

    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      else {
        return
      }

      if activated.processIdentifier == app.processIdentifier {
        // The panel having been presented again means a fresh interaction
        // started while this one was still waiting -- give up rather than
        // paste into whatever this restored activation was racing.
        finish(invokingCompletion: !self.isPresented)
      } else if activated.bundleIdentifier != Bundle.main.bundleIdentifier {
        finish(invokingCompletion: false)
      }
    }

    // The caller already called `app.activate()` before this method runs,
    // and activation can complete -- and its notification be delivered --
    // before the observer above was even registered, especially for an app
    // that's already running. Check the already-current state right after
    // registering rather than assuming the notification is still pending;
    // otherwise a fast activation is missed entirely and the paste this
    // exists to deliver silently drops after the full timeout.
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
      finish(invokingCompletion: !isPresented)
      return
    }

    // Mirrors the previous scheme's mid-point re-kick: activation
    // occasionally doesn't "take" on the first call.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      guard !resolved, !app.isTerminated else { return }
      app.activate()
    }

    // Half a second mirrors the previous 10 * 50ms retry budget. Re-check
    // current state before giving up, for the same reason as above: a very
    // late activation's notification can land in the gap right before this
    // fires, but `frontmostApplication` is always authoritative right now.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
        finish(invokingCompletion: !self.isPresented)
      } else {
        finish(invokingCompletion: false)
      }
    }
  }

  override func close() {
    let shouldNotify = isPresented
    isPresented = false
    presentationGeneration += 1
    previousApp = nil
    super.close()
    // Without this, a delayed auto-open task started just before closing can
    // still fire afterward and reopen the preview against a panel nobody can
    // see (or, worse, the next presentation of it).
    AppState.shared.preview.cancelAutoOpen()
    AppState.shared.preview.state = .closed
    statusBarButton?.isHighlighted = false
    if shouldNotify {
      onClose()
    }
  }

  // Allow text inputs inside the panel can receive focus
  override var canBecomeKey: Bool {
    return true
  }
}
