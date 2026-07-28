import XCTest
import VibeStatusCore
@testable import VibeStatus

final class MenuBarStatusRendererTests: XCTestCase {
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
        XCTAssertEqual(image.size.height, 18)
    }
}
