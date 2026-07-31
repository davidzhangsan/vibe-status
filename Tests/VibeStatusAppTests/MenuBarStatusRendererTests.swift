import AppKit
import XCTest
import VibeStatusCore
@testable import VibeStatus

final class MenuBarStatusRendererTests: XCTestCase {
    func testPaletteUsesMutedYellowBlueAndGreen() {
        XCTAssertTrue(
            StatusPalette.needsAttention.isEqual(
                NSColor(srgbRed: 0.91, green: 0.70, blue: 0.24, alpha: 1)
            )
        )
        XCTAssertTrue(
            StatusPalette.working.isEqual(
                NSColor(srgbRed: 0.30, green: 0.56, blue: 0.82, alpha: 1)
            )
        )
        XCTAssertTrue(
            StatusPalette.ready.isEqual(
                NSColor(srgbRed: 0.32, green: 0.65, blue: 0.43, alpha: 1)
            )
        )
    }

    func testAccessibilityLabelIncludesAllStatusesAndZeroes() {
        let counts = StatusCounts(needsAttention: 0, working: 4, ready: 2)

        XCTAssertEqual(
            MenuBarStatusRenderer.accessibilityLabel(for: counts),
            "0 needs attention, 4 working, 2 ready"
        )
    }

    func testRenderedImageIsNeverTemplate() {
        let image = MenuBarStatusRenderer.image(
            for: StatusCounts(needsAttention: 1, working: 0, ready: 9)
        )

        XCTAssertFalse(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertLessThanOrEqual(image.size.width, 38)
        XCTAssertEqual(image.size.height, 18)
    }

    func testRenderedImageExpandsForMultiDigitCounts() {
        let singleDigitImage = MenuBarStatusRenderer.image(
            for: StatusCounts(needsAttention: 1, working: 2, ready: 3)
        )
        let multiDigitImage = MenuBarStatusRenderer.image(
            for: StatusCounts(needsAttention: 12, working: 3, ready: 456)
        )

        XCTAssertGreaterThan(multiDigitImage.size.width, singleDigitImage.size.width)
        XCTAssertEqual(multiDigitImage.size.height, singleDigitImage.size.height)
    }
}
