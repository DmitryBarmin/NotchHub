import XCTest
@testable import NotchHub

final class SidebarRoutingTests: XCTestCase {
    @MainActor func testPinningActionDoesNotPauseNamedTimerWhenFocusWasAlreadyHidden() throws {
        let name = "SidebarRoutingTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppDelegate()
        app.clock = FocusClock()
        app.timerLibrary = TimerLibrary(defaults: defaults)
        defer { app.timerLibrary.pauseAll() }
        let settings = SectionSettings(defaults: defaults) { app.applySectionVisibility($0) }
        settings.set(.timer, enabled: false)
        app.timerLibrary.add(title: "Task", minutes: 5)
        let id = try XCTUnwrap(app.timerLibrary.timers.first?.id)
        app.timerLibrary.start(id: id)
        settings.setCommand(.openTimers, enabled: true)
        XCTAssertTrue(try XCTUnwrap(app.timerLibrary.timers.first).running)
        settings.setCommand(.share, enabled: true)
        XCTAssertTrue(try XCTUnwrap(app.timerLibrary.timers.first).running)
        settings.set(.timer, enabled: true)
        settings.set(.timer, enabled: false)
        XCTAssertFalse(try XCTUnwrap(app.timerLibrary.timers.first).running)
    }
    func testBatchActionFromNoteOpensClipboardAndDismissesPreview() {
        let state = HubState()
        state.tab = 2
        state.previewClip = Clip(kind: .text, title: "Preview", text: "text", fingerprint: "test")
        var closedPreview = false
        state.showPreview = { if $0 == nil { closedPreview = true } }
        XCTAssertTrue(state.beginBatchSelection())
        XCTAssertEqual(state.tab, 0)
        XCTAssertTrue(state.batchMode)
        XCTAssertNil(state.previewClip)
        XCTAssertTrue(closedPreview)
    }
    func testBatchActionFallsBackToVisibleShelfOrRejectsWithoutVisibleLists() {
        let state = HubState()
        state.sections.mask = 14
        state.tab = 3
        XCTAssertTrue(state.beginBatchSelection())
        XCTAssertEqual(state.tab, 1)
        XCTAssertTrue(state.batchMode)
        state.sections.mask = 12; state.tab = 2; state.batchMode = false
        XCTAssertFalse(state.beginBatchSelection())
        XCTAssertEqual(state.tab, 2)
        XCTAssertFalse(state.batchMode)
    }
}
