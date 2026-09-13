import AppKit.NSRunningApplication
import Carbon

extension NSRunningApplication {
  var windowFrame: NSRect? {
    let options = CGWindowListOption(arrayLiteral: [.excludeDesktopElements, .optionOnScreenOnly])
    let windowListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0))
    if let windowInfoList = windowListInfo as NSArray? as? [[String: AnyObject]] {
      for info in windowInfoList {
        if let windowPID = info["kCGWindowOwnerPID"] as? UInt32, windowPID == processIdentifier,
           let topLeftX = info["kCGWindowBounds"]?["X"] as? Double,
           let topLeftY = info["kCGWindowBounds"]?["Y"] as? Double,
           let width = info["kCGWindowBounds"]?["Width"] as? Double,
           let height = info["kCGWindowBounds"]?["Height"] as? Double {
          // Quartz's global display space has its origin at the top-left of
          // whichever screen is "primary" (the one Cocoa anchors at (0,0) --
          // its frame.origin is exactly .zero), Y increasing downward, and
          // that single global frame spans every display. `NSScreen.screens`
          // is not documented to return the primary screen first, so using
          // `.first` picks the wrong anchor whenever that ordering doesn't
          // happen to match, producing a wrong Y on those setups (most
          // visibly when displays are stacked vertically or differently
          // sized). Find the actual primary screen instead.
          guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first else { return nil }
          let rect = NSRect(
            x: topLeftX,
            y: primaryScreen.frame.height - topLeftY - height,
            width: width,
            height: height
          )
          return rect
        }
      }
    }

    return nil
  }
}
