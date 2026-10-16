import XCTest
@testable import NotchHub

final class TimerLibraryTests: XCTestCase {
    private func withDefaults(_ action: (UserDefaults) throws -> Void) rethrows {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try action(defaults)
    }
    func testNamedTimersShareTickerPauseAndRestoreDeadlines() {
        withDefaults { defaults in
            let now = Date(timeIntervalSince1970: 10_000)
            let library = TimerLibrary(defaults: defaults, now: now)
            let first = library.add(title: "Work", minutes: 2), second = library.add(title: "Tea", minutes: 1)
            XCTAssertFalse(library.hasScheduledTick)
            library.start(id: first, now: now); library.start(id: second, now: now)
            XCTAssertTrue(library.hasScheduledTick)
            let saved = defaults.data(forKey: TimerLibrary.preferenceKey)
            library.tick(now: now.addingTimeInterval(30))
            XCTAssertEqual(defaults.data(forKey: TimerLibrary.preferenceKey), saved, "ticks must not rewrite preferences")
            XCTAssertEqual(library.timers.first?.remaining, 90)
            let restored = TimerLibrary(defaults: defaults, now: now.addingTimeInterval(70))
            XCTAssertEqual(restored.timers.first?.remaining, 50)
            XCTAssertEqual(restored.timers.last?.completed, true)
            restored.pause(id: first, now: now.addingTimeInterval(80))
            XCTAssertEqual(restored.timers.first?.remaining, 40); XCTAssertFalse(restored.hasScheduledTick)
            restored.reset(id: second); XCTAssertEqual(restored.timers.last?.remaining, 60); XCTAssertEqual(restored.timers.last?.completed, false)
            restored.remove(id: second); XCTAssertEqual(restored.timers.count, 1)
            library.pauseAll(now: now.addingTimeInterval(30)); XCTAssertFalse(library.hasScheduledTick)
        }
    }
    func testExpiredRestartCompletesAndNeverSchedulesIdleTick() {
        withDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1000)
            let library = TimerLibrary(defaults: defaults, now: now)
            let id = library.add(title: "Deadline", minutes: 1); library.start(id: id, now: now)
            let restored = TimerLibrary(defaults: defaults, now: now.addingTimeInterval(61))
            XCTAssertEqual(restored.timers.first?.completed, true); XCTAssertEqual(restored.timers.first?.remaining, 0); XCTAssertFalse(restored.hasScheduledTick)
            library.pauseAll(now: now.addingTimeInterval(61))
        }
    }
    func testSimpleFocusClockOptInRestore() {
        withDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1000)
            let clock = FocusClock(defaults: defaults, now: now); clock.reset(minutes: 2); clock.start(now: now)
            let restored = FocusClock(defaults: defaults, now: now.addingTimeInterval(30))
            XCTAssertEqual(restored.remaining, 90); XCTAssertTrue(restored.running)
            restored.pause(now: now.addingTimeInterval(40)); XCTAssertFalse(restored.hasScheduledTick)
            clock.pause(now: now.addingTimeInterval(40))
        }
    }
}
