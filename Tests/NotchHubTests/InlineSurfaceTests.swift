import XCTest
import AppKit
import SwiftUI
@testable import NotchHub

final class InlineSurfaceTests: XCTestCase {
    @MainActor func testFeaturesUsePreviewGeometryAndReleasePreviousLifetimeOnce() {
        let state = HubState()
        state.expandedWidth = 345; state.previewWidth = 680; state.previewContentHeight = 400
        let windows = HubWindows()
        windows.present = { state.surface = $0 }
        var firstClosed = 0
        var secondClosed = 0
        windows.show("ocr", title: "OCR", onClose: { firstClosed += 1 }) { Text("text") }
        XCTAssertEqual(state.panelWidth, 680)
        XCTAssertEqual(state.expandedHeight, state.notchHeight + 400)
        windows.show("transfer", title: "Transfer", onClose: { secondClosed += 1 }) { Text("transfer") }
        XCTAssertEqual(firstClosed, 1)
        XCTAssertEqual(state.surface?.key, "transfer")
        windows.close("ocr")
        XCTAssertEqual(secondClosed, 0)
        windows.closeAll(); windows.closeAll()
        XCTAssertEqual(secondClosed, 1)
        XCTAssertNil(state.surface)
        XCTAssertEqual(state.panelWidth, 345)
    }

    @MainActor func testNativeSelectionReplacementSupportsUndoAndLengthChangingUnicode() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSTextView(frame: window.contentView!.bounds)
        window.contentView = view
        window.makeFirstResponder(view)
        view.allowsUndo = true
        view.string = "😀 Straße конец"
        let original = view.string
        let range = (original as NSString).range(of: "Straße")
        view.setSelectedRange(range)
        let result = try TextSelectionTransform.apply(.upper, to: original, range: range)
        let undo = try XCTUnwrap(view.undoManager)
        undo.beginUndoGrouping()
        XCTAssertTrue(view.shouldChangeText(in: range, replacementString: result.text))
        view.textStorage?.replaceCharacters(in: range, with: result.text)
        view.didChangeText()
        view.setSelectedRange(result.selection)
        undo.endUndoGrouping()
        XCTAssertEqual(view.string, "😀 STRASSE конец")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 7))
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.string, original)
    }
}
