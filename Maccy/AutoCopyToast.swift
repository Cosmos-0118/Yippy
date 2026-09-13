import AppKit
import SwiftUI

/// A small, transient "Copied" indicator shown near the cursor after
/// Auto-copy on Option-select actually copies something to the clipboard.
///
/// Deliberately never activates Yippy or becomes key: `AutoCopyOnSelect`'s own
/// gating (`shouldAutoCopy`'s `isYippyActive` check, and the frontmost-app
/// check in `fireIfArmed`) depends on Yippy staying non-frontmost, and this
/// toast is shown from inside that same flow -- stealing activation here
/// would break the *next* auto-copy.
enum AutoCopyToast {
  private static let size = NSSize(width: 92, height: 36)
  private static let visibleDuration: TimeInterval = 0.9
  private static let fadeDuration: TimeInterval = 0.25
  // Offsets the toast up and to the right of the cursor so it doesn't sit
  // on top of the text that was just selected and copied.
  private static let cursorOffset = NSPoint(x: 16, y: 16)

  private static let panel = makePanel()
  private static var dismissWorkItem: DispatchWorkItem?

  static func show() {
    dismissWorkItem?.cancel()

    positionNearCursor()
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    let workItem = DispatchWorkItem {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = fadeDuration
        panel.animator().alphaValue = 0
      } completionHandler: {
        panel.orderOut(nil)
      }
    }
    dismissWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: workItem)
  }

  private static func positionNearCursor() {
    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    var origin = NSPoint(x: mouseLocation.x + cursorOffset.x, y: mouseLocation.y + cursorOffset.y)

    if let visibleFrame = screen?.visibleFrame {
      origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
      origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
    }

    panel.setFrame(NSRect(origin: origin, size: size), display: false)
  }

  private static func makePanel() -> NSPanel {
    let panel = ToastPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    // Mirrors FloatingPanel's level: sits above Chrome autofill (999) while
    // still covering status items / Spotlight.
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.alphaValue = 0
    panel.contentView = NSHostingView(rootView: ToastContentView())
    return panel
  }
}

/// Never becomes key or main, even though `.nonactivatingPanel` alone
/// already keeps it from activating the app -- belt and suspenders, since
/// `AutoCopyOnSelect` relies on Yippy staying non-frontmost.
private final class ToastPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct ToastContentView: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text("Copied", tableName: "GeneralSettings")
        .foregroundStyle(.primary)
    }
    .font(.system(size: 13, weight: .medium))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
