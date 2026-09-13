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

  func testStoredPreviewWidthIsRaisedToReadableMinimum() {
    let controller = SlideoutController(
      onContentResize: { _ in },
      onSlideoutResize: { _ in }
    )

    controller.slideoutWidth = 200

    XCTAssertEqual(controller.slideoutWidth, 300)
  }

  func testLegacyDefaultWindowSizeMigratesToNewDefault() {
    XCTAssertEqual(
      WindowSizing.migratedDefault(from: WindowSizing.legacyDefaultSize),
      WindowSizing.defaultSize
    )
  }

  func testPreviousDefaultWindowSizeMigratesToRoomierDefault() {
    XCTAssertEqual(
      WindowSizing.migratedDefault(from: WindowSizing.previousDefaultSize),
      WindowSizing.defaultSize
    )
  }

  func testCustomizedWindowSizeIsNotMigrated() {
    let customizedSize = NSSize(width: 450, height: 799)
    XCTAssertEqual(WindowSizing.migratedDefault(from: customizedSize), customizedSize)
  }

  func testPreferredHeightHonorsMinimumWhenSavedMaximumIsStale() {
    XCTAssertEqual(
      WindowSizing.preferredHeight(requested: 100, minimum: 180, maximum: 120),
      180
    )
  }

  func testPreferredHeightClampsToMaximum() {
    XCTAssertEqual(
      WindowSizing.preferredHeight(requested: 900, minimum: 180, maximum: 480),
      480
    )
  }

  func testOpeningHeightProvidesComfortableRoomForShortContent() {
    XCTAssertEqual(
      WindowSizing.openingHeight(
        requested: 260, saved: 540, minimum: 180,
        hasCustomSize: true, screenMaximum: screen.height
      ),
      480
    )
  }

  func testOpeningHeightStillHonorsManuallyReducedSize() {
    XCTAssertEqual(
      WindowSizing.openingHeight(
        requested: 260, saved: 320, minimum: 180,
        hasCustomSize: true, screenMaximum: screen.height
      ),
      320
    )
  }

  func testOpeningHeightAllowsContentToGrowToSavedLimit() {
    XCTAssertEqual(
      WindowSizing.openingHeight(
        requested: 700, saved: 540, minimum: 180,
        hasCustomSize: true, screenMaximum: screen.height
      ),
      540
    )
  }

  func testOpeningHeightAutoFitsToScreenWhenNotCustomized() {
    // screen.height is 900, saved (540, an old/stale value) is ignored
    // entirely since the size has never been customized -- content grows up
    // to 80% of the screen instead.
    XCTAssertEqual(
      WindowSizing.openingHeight(
        requested: 900, saved: 540, minimum: 180,
        hasCustomSize: false, screenMaximum: screen.height
      ),
      720
    )
  }

  func testOpeningHeightStillFitsSmallContentWhenNotCustomized() {
    XCTAssertEqual(
      WindowSizing.openingHeight(
        requested: 260, saved: 540, minimum: 180,
        hasCustomSize: false, screenMaximum: screen.height
      ),
      480
    )
  }

  func testWidthOnlyResizePreservesHeightCeiling() {
    let resized = WindowSizing.resizedPreference(
      previous: NSSize(width: 450, height: 480),
      liveResizeStart: NSSize(width: 450, height: 180),
      final: NSSize(width: 520, height: 180),
      contentWidth: 520
    )

    XCTAssertEqual(resized, NSSize(width: 520, height: 480))
  }

  func testVerticalResizeUpdatesHeightCeiling() {
    let resized = WindowSizing.resizedPreference(
      previous: NSSize(width: 450, height: 480),
      liveResizeStart: NSSize(width: 450, height: 180),
      final: NSSize(width: 450, height: 320),
      contentWidth: 450
    )

    XCTAssertEqual(resized, NSSize(width: 450, height: 320))
  }
}
