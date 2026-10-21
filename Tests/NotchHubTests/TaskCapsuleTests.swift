import XCTest
import AppKit
@testable import NotchHub

final class TaskCapsuleTests: XCTestCase {
    @MainActor func testCapsuleResizesBelowCameraAndHonorsFeatureAndSectionVisibility() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let name = "TaskCapsule-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = HubPreferences(defaults: defaults)
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: preferences)
        let library = TimerLibrary(defaults: defaults)
        let state = HubState()
        let controller = PanelController(store: store, clock: FocusClock(defaults: defaults), state: state, screen: screen, timers: library)
        defer { controller.dispose() }
        let originalHeight = state.collapsedHeight
        let id = library.add(title: "Проверить задачу", minutes: 25)
        library.focus(id: id)
        XCTAssertEqual(state.capsuleTask?.id, id)
        XCTAssertEqual(state.collapsedHeight, originalHeight + 30)
        XCTAssertEqual(controller.panel.frame.height, state.collapsedHeight)
        preferences.setFeature(.multipleTimers, enabled: false)
        XCTAssertNil(state.capsuleTask)
        XCTAssertEqual(state.collapsedHeight, originalHeight)
        preferences.setFeature(.multipleTimers, enabled: true)
        XCTAssertEqual(state.capsuleTask?.id, id)
        var hiddenTimer = SectionVisibility.all
        hiddenTimer.mask &= ~(1 << HubSection.timer.rawValue)
        controller.applySectionVisibility(hiddenTimer)
        XCTAssertNil(state.capsuleTask)
        controller.applySectionVisibility(.all)
        XCTAssertEqual(state.capsuleTask?.id, id)
        library.remove(id: id)
        XCTAssertNil(state.capsuleTask)
        XCTAssertEqual(state.collapsedHeight, originalHeight)
    }
    func testTaskSelectionSurvivesRestartAndRemovalClearsIt() {
        let name = "TaskCapsule-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_000)
        let library = TimerLibrary(defaults: defaults, now: now)
        let first = library.add(title: "Первая задача", minutes: 2)
        let second = library.add(title: "Вторая задача", minutes: 3)
        library.focus(id: second)
        library.focus(id: UUID())
        XCTAssertEqual(library.focusedTaskID, second, "Unknown tasks cannot replace selection")
        library.start(id: second, now: now)
        let restored = TimerLibrary(defaults: defaults, now: now.addingTimeInterval(30))
        XCTAssertEqual(restored.focusedTaskID, second)
        XCTAssertEqual(restored.timers.last?.remaining, 150)
        restored.remove(id: first)
        XCTAssertEqual(restored.focusedTaskID, second)
        restored.remove(id: second)
        XCTAssertNil(restored.focusedTaskID)
        XCTAssertNil(defaults.string(forKey: TimerLibrary.focusedTaskKey))
        library.pauseAll(now: now)
    }

    func testFinishingSelectedTaskStopsTickerAndPersistsCompletion() {
        let name = "TaskCapsule-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_000)
        let library = TimerLibrary(defaults: defaults, now: now)
        let id = library.add(title: "Задача", minutes: 25)
        library.focus(id: id); library.start(id: id, now: now)
        library.finish(id: id)
        XCTAssertEqual(library.timers.first?.completed, true)
        XCTAssertEqual(library.timers.first?.remaining, 0)
        XCTAssertEqual(library.focusedTaskID, id)
        XCTAssertFalse(library.hasScheduledTick)
        let restored = TimerLibrary(defaults: defaults, now: now)
        XCTAssertEqual(restored.timers.first?.completed, true)
        XCTAssertEqual(restored.focusedTaskID, id)
        restored.reset(id: id)
        XCTAssertEqual(restored.timers.first?.remaining, 1500)
        XCTAssertEqual(restored.timers.first?.completed, false)
        restored.focus(id: nil)
        XCTAssertNil(restored.focusedTaskID)
    }
}
