import XCTest
@testable import NotchHub

final class FullscreenVisibilityTests: XCTestCase {
    private let display = CGRect(x: -1920, y: 200, width: 1920, height: 1080)

    private func window(_ frame: CGRect, pid: Int = 42, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    func testFullscreenOnOffsetSecondaryDisplay() {
        XCTAssertTrue(FullscreenWindowGeometry.hasFullscreenWindow([window(display)], display: display, ownPID: 100))
        XCTAssertFalse(FullscreenWindowGeometry.fillsDisplay(CGRect(x: 0, y: 0, width: 1920, height: 1080), display: display))
    }

    func testMaximizedWindowBelowMenuBarDoesNotHideHub() {
        let maximized = CGRect(x: display.minX, y: display.minY + 25, width: display.width, height: display.height - 25)
        XCTAssertFalse(FullscreenWindowGeometry.hasFullscreenWindow([window(maximized)], display: display, ownPID: 100))
    }

    func testOccludingWindowPreventsFullscreenSuppression() {
        let smaller = CGRect(x: display.minX + 100, y: display.minY + 100, width: 500, height: 400)
        XCTAssertFalse(FullscreenWindowGeometry.hasFullscreenWindow([window(smaller), window(display)], display: display, ownPID: 100))
    }

    func testOwnPanelsOtherScreensAndInvisibleWindowsAreIgnored() {
        let elsewhere = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let windows = [window(display, pid: 100), window(display, layer: 25), window(display, alpha: 0), window(elsewhere), window(display)]
        XCTAssertTrue(FullscreenWindowGeometry.hasFullscreenWindow(windows, display: display, ownPID: 100))
    }

    func testOversizedAndEmptyBoundsAreNotFullscreen() {
        XCTAssertFalse(FullscreenWindowGeometry.fillsDisplay(display.insetBy(dx: -20, dy: -20), display: display))
        XCTAssertFalse(FullscreenWindowGeometry.fillsDisplay(.zero, display: .zero))
        XCTAssertTrue(FullscreenWindowGeometry.fillsDisplay(display.insetBy(dx: 1, dy: 1), display: display))
    }
}
