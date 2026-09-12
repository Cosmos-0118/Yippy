import AppKit
import XCTest

@testable import Maccy

final class SlideoutPlacementTests: XCTestCase {
  private let screen = NSRect(x: 0, y: 0, width: 1_238, height: 900)

  func testUsesLeftWhenPreviewDoesNotFitAtRight() {
    let placement = SlideoutController.placement(
      windowFrame: NSRect(x: 244, y: 100, width: 900, height: 500),
      expandedSize: NSSize(width: 1_300, height: 500),
      within: screen
    )

    XCTAssertEqual(placement, .left)
  }

  func testUsesRightWhenPreviewFitsAtRight() {
    let placement = SlideoutController.placement(
      windowFrame: NSRect(x: 100, y: 100, width: 500, height: 500),
      expandedSize: NSSize(width: 900, height: 500),
      within: screen
    )

    XCTAssertEqual(placement, .right)
  }

  func testUsesSideWithMoreSpaceWhenPreviewFitsNeitherSide() {
    let placement = SlideoutController.placement(
      windowFrame: NSRect(x: 300, y: 100, width: 700, height: 500),
      expandedSize: NSSize(width: 1_500, height: 500),
      within: screen
    )

    XCTAssertEqual(placement, .left)
  }
}
