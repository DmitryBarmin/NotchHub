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

    func testSettingsGeometryRemainsUsableWithoutChangingSavedSmallLayout() {
        var layout = HubLayoutPreferences.standard
        layout.panelWidth = 240; layout.panelHeight = 110
        layout.previewWidth = 240; layout.previewHeight = 180
        let saved = layout
        let geometry = HubGeometry.resolve(layout, screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 32, notchWidth: 179)
        XCTAssertEqual(geometry.settingsWidth, 680)
        XCTAssertEqual(geometry.settingsHeight, 480)
        XCTAssertEqual(geometry.previewWidth, 343)
        XCTAssertEqual(geometry.previewHeight, 180)
        XCTAssertEqual(layout, saved)
    }

    func testSettingsGeometryClampsToSmallMonitorAndOffset() {
        var layout = HubLayoutPreferences.standard
        layout.previewWidth = 1200; layout.previewHeight = 900; layout.verticalOffset = 120
        for screen in [CGRect(x: 1200, y: -100, width: 600, height: 400), CGRect(x: -400, y: 50, width: 200, height: 120)] {
            let geometry = HubGeometry.resolve(layout, screen: screen, safeTop: 0, notchWidth: nil)
            XCTAssertLessThanOrEqual(geometry.settingsWidth, screen.width - 40)
            XCTAssertLessThanOrEqual(geometry.settingsHeight, screen.height - 40 - geometry.topOffset)
            XCTAssertTrue(screen.contains(geometry.frame(screen: screen, width: geometry.settingsWidth, height: geometry.settingsHeight)))
        }
    }

    @MainActor func testOpeningAndEditingSettingsResizesActualPanelAndClosingRestoresSavedGeometry() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw XCTSkip("No screen available") }
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, preferences: HubPreferences(defaults: defaults))
        let state = HubState()
        var layout = HubLayoutPreferences.standard
        layout.panelWidth = 240; layout.previewWidth = 240; layout.previewHeight = 180
        let controller = PanelController(store: store, clock: FocusClock(defaults: defaults), state: state, screen: screen, layout: layout)
        defer { controller.dispose() }
        controller.expand()
        let geometry = HubGeometry.resolve(layout, screen: screen)
        state.showSurface?(HubSurface(key: "settings", title: "Settings", content: AnyView(Text("fixture"))))
        XCTAssertEqual(state.panelWidth, geometry.settingsWidth)
        XCTAssertEqual(controller.panel.frame.width, geometry.settingsWidth)
        XCTAssertEqual(controller.panel.frame.height, geometry.settingsHeight)
        layout.previewWidth = 260; layout.previewHeight = 190
        controller.applyLayout(layout)
        let updated = HubGeometry.resolve(layout, screen: screen)
        XCTAssertEqual(controller.panel.frame.width, updated.settingsWidth)
        XCTAssertEqual(controller.panel.frame.height, updated.settingsHeight)
        state.showSurface?(nil)
        XCTAssertEqual(state.panelWidth, updated.panelWidth)
        XCTAssertEqual(controller.panel.frame.width, updated.panelWidth)
        state.showPreview?(Clip(kind: .text, title: "preview", text: "text", fingerprint: ""))
        XCTAssertEqual(controller.panel.frame.width, updated.previewWidth)
        XCTAssertEqual(controller.panel.frame.height, updated.previewHeight)
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
