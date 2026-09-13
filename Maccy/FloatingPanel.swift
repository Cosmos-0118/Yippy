import Defaults
import SwiftUI

enum WindowSizing {
  static let defaultSize = NSSize(width: 450, height: 480)
  static let legacyDefaultSize = NSSize(width: 450, height: 800)

  static func migratedDefault(from size: NSSize) -> NSSize {
    size == legacyDefaultSize ? defaultSize : size
  }

  static func preferredHeight(requested: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    min(max(requested, minimum), max(maximum, minimum))
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
    let finalHeight = max(min(height, size.height), miniumHeight)
    setContentSize(NSSize(width: finalWidth, height: finalHeight))
    setFrameOrigin(popupPosition.origin(size: frame.size, statusBarButton: statusBarButton))
    // `orderFrontRegardless()` deliberately does not activate an agent app.
    // That leaves this panel visibly frontmost but unable to receive keyboard
    // input when it is opened over another application's full-screen Space.
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    isPresented = true

    // Moving into a full-screen Space is asynchronous. Reassert key status on
    // the next turn so the source application cannot reclaim it during that
    // transition.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isPresented else { return }
      NSApp.activate(ignoringOtherApps: true)
      self.makeKeyAndOrderFront(nil)
    }

    if popupPosition == .statusItem {
      DispatchQueue.main.async {
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
    let size = WindowSizing.resizedPreference(
      previous: Defaults[.windowSize],
      liveResizeStart: liveResizeStartSize ?? frame.size,
      final: frame.size,
      contentWidth: AppState.shared.preview.contentWidth
    )
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
    runWhenActive(appToRestore, attemptsRemaining: 10, completion: completion)
  }

  private func runWhenActive(
    _ app: NSRunningApplication,
    attemptsRemaining: Int,
    completion: (() -> Void)?
  ) {
    guard !isPresented, !app.isTerminated else { return }

    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
      completion?()
      return
    }

    // Wait up to half a second for activation/Space switching. Stop if the
    // user activates a third app, so a delayed paste can never land there.
    guard attemptsRemaining > 0,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier else {
      return
    }

    if attemptsRemaining == 5 {
      app.activate()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, app] in
      guard let self else { return }
      self.runWhenActive(app, attemptsRemaining: attemptsRemaining - 1, completion: completion)
    }
  }

  override func close() {
    let shouldNotify = isPresented
    isPresented = false
    previousApp = nil
    super.close()
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
