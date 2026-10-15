import XCTest
import AppKit
import Carbon
@testable import NotchHub

final class PreviewShortcutTests: XCTestCase {
    func testHeldPreviewSurvivesRunLoopUpdatesSelectionAndClosesOnRelease() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let delegate = AppDelegate()
        delegate.store = HubStore(root: root, monitor: false, pasteboard: board)
        delegate.clock = FocusClock()
        let first = Clip(kind: .text, title: "First preview", text: "first", fingerprint: "first")
        let second = Clip(kind: .text, title: "Second preview", text: "second", fingerprint: "second")
        delegate.store.insert(first); delegate.store.insert(second)
        let state = HubState()
        let controller = PanelController(store: delegate.store, clock: delegate.clock, state: state, screen: screen)
        defer { controller.dispose() }
        delegate.controllers = [controller]
        delegate.hotKeys = ClipboardHotKeys(advance: {}, finish: {}, register: { _, _, _ in noErr })
        delegate.previewSettings = ScreenshotSettings(defaults: defaults, preferenceKey: "testHeldPreview", signature: 0x54505256,
            register: { _, _ in noErr }, released: { [weak delegate] in delegate?.hideKeyboardPreview() }, action: { [weak delegate] in delegate?.showKeyboardPreview() })
        delegate.advanceClipboard()
        XCTAssertTrue(state.keyboardSelecting)
        XCTAssertEqual(state.selectedClipboardID, second.id)

        func send(_ kind: UInt32) throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event), noErr)
            let value = try XCTUnwrap(event)
            defer { ReleaseEvent(value) }
            var id = EventHotKeyID(signature: 0x54505256, id: 1)
            XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
            XCTAssertEqual(SendEventToEventTarget(value, GetApplicationEventTarget()), noErr)
        }
        try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(state.previewClip?.id, second.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(state.previewClip?.id, second.id, "Preview must stay open until the hotkey is released")
        XCTAssertTrue(state.expanded)
        delegate.advanceClipboard()
        XCTAssertEqual(state.previewClip?.id, first.id)
        try send(UInt32(kEventHotKeyReleased))
        XCTAssertNil(state.previewClip)
        XCTAssertTrue(state.keyboardSelecting)
        try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(state.previewClip?.id, first.id)
        delegate.finishClipboard()
        XCTAssertNil(state.previewClip)
        XCTAssertFalse(state.keyboardSelecting)
        XCTAssertNil(delegate.keyboardController)
        XCTAssertEqual(board.string(forType: .string), "first")
        try send(UInt32(kEventHotKeyReleased))
        XCTAssertNil(state.previewClip)
    }
}
