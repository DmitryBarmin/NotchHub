import XCTest
import AppKit
@testable import NotchHub

private final class SelectionChangingView: NSView {
    let source: NSTextView
    var dispatched = false
    init(source: NSTextView) { self.source = source; super.init(frame: CGRect(x: 0, y: 0, width: 200, height: 100)) }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        dispatched = true
        source.setSelectedRange(NSRange(location: 0, length: 0))
    }
}

final class ExternalSelectionTests: XCTestCase {
    @MainActor func testPanelCapturesNativeTextSelectionBeforeDispatchCanChangeFocus() throws {
        _ = NSApplication.shared
        let source = NSTextView()
        source.string = "before selected after"
        source.setSelectedRange((source.string as NSString).range(of: "selected"))
        let panel = IslandPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let target = SelectionChangingView(source: source)
        panel.contentView = target
        panel.orderFrontRegardless()
        var captured: String?
        panel.beforeInteraction = { captured = (source.string as NSString).substring(with: source.selectedRange()) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        panel.sendEvent(event)
        XCTAssertTrue(target.dispatched)
        XCTAssertEqual(captured, "selected")
        XCTAssertEqual(source.selectedRange().length, 0)
    }
}
