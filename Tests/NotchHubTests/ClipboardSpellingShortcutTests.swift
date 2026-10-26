import AppKit
import XCTest
@testable import NotchHub

@MainActor final class ClipboardSpellingShortcutTests: XCTestCase {
    private func waitUntilIdle(_ shortcut: ClipboardSpellingShortcut) async {
        for _ in 0..<1000 { if !shortcut.busy { return }; await Task.yield() }
        XCTFail("Native spelling cycle did not finish")
    }
    private let corrected = LocalSpellingOutcome(text: "привет как дела", misspellingCount: 2, correctedCount: 2, unresolvedCount: 0)

    func testHotkeyRunsNativeCycleWithoutAXTextCapabilityOrPanel() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppDelegate(); app.preferences = HubPreferences(defaults: defaults)
        var panels = 0, inputs: [String] = [], feedback: [String] = [], restored: [Int] = []
        app.windows.present = { _ in panels += 1 }
        let editor = NSTextView(); editor.string = "До превет как дила после"
        let range = (editor.string as NSString).range(of: "превет как дила"); editor.setSelectedRange(range)
        let target = SpellingSelectionTarget(processIdentifier: 123, validate: {})
        app.clipboardSpelling = ClipboardSpellingShortcut(capture: { target }, correct: { text in
            inputs.append(text); return self.corrected
        }, cycle: { pid, validate, correct, restore in
            XCTAssertEqual(pid, 123); XCTAssertTrue(app.clipboardSpelling.busy)
            try validate()
            let copiedSelection = (editor.string as NSString).substring(with: editor.selectedRange())
            let result = try await correct(copiedSelection)
            try validate(); editor.insertText(result.text, replacementRange: editor.selectedRange())
            restore(42); XCTAssertTrue(app.clipboardSpelling.busy)
            return result
        }, didRestore: { restored.append($0) }, feedback: { feedback.append($0) })
        let keyWindow = NSApp?.keyWindow
        app.performShortcut(.correctText); await waitUntilIdle(app.clipboardSpelling)
        XCTAssertEqual(inputs, ["превет как дила"])
        XCTAssertEqual(editor.string, "До привет как дела после")
        XCTAssertEqual(panels, 0); XCTAssertTrue(NSApp?.keyWindow === keyWindow)
        XCTAssertEqual(restored, [42]); XCTAssertTrue(feedback.last?.contains("Правка отправлена") == true)
    }
    func testDisabledFeatureNeverCapturesOrRunsNativeCycle() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppDelegate(); app.preferences = HubPreferences(defaults: defaults)
        app.preferences.setFeature(.textTools, enabled: false)
        var captures = 0
        app.clipboardSpelling = ClipboardSpellingShortcut(capture: {
            captures += 1; throw ExternalTextSelection.SelectionError.noSelection
        }, feedback: { _ in })
        app.performShortcut(.correctText); await Task.yield(); XCTAssertEqual(captures, 0)
    }
    func testKnownProtectedFieldOrStaleFrontTargetNeverStartsCycle() async {
        for error in [ExternalTextSelection.SelectionError.protectedField, .selectionChanged, .noSelection] {
            var cycles = 0, feedback: [String] = []
            let shortcut = ClipboardSpellingShortcut(capture: { throw error }, cycle: { _, _, _, _ in
                cycles += 1; return self.corrected
            }, feedback: { feedback.append($0) })
            shortcut.trigger(); await Task.yield()
            XCTAssertEqual(cycles, 0); XCTAssertFalse(shortcut.busy)
            XCTAssertEqual(feedback.last, error.localizedDescription)
        }
    }
    func testFrontValidationFailureBeforeOrInsideCycleNeverReportsSuccess() async {
        for staleBeforeStart in [true, false] {
            var valid = !staleBeforeStart, cycles = 0, feedback: [String] = []
            let target = SpellingSelectionTarget(processIdentifier: 123, validate: {
                guard valid else { throw ExternalTextSelection.SelectionError.selectionChanged }
            })
            let shortcut = ClipboardSpellingShortcut(capture: { target }, cycle: { _, validate, _, _ in
                cycles += 1; valid = false; try validate(); return self.corrected
            }, feedback: { feedback.append($0) })
            shortcut.trigger(); await waitUntilIdle(shortcut)
            XCTAssertEqual(cycles, staleBeforeStart ? 0 : 1)
            XCTAssertTrue(feedback.last?.contains("Выделение изменилось") == true)
            XCTAssertFalse(feedback.contains(where: { $0.contains("Правка отправлена") }))
        }
    }
    func testDuplicateAndCancellationKeepBusyUntilRestorationFinishes() async {
        let started = expectation(description: "cycle started")
        var pending: CheckedContinuation<Void, Never>?, cycles = 0, restored = false, feedback: [String] = []
        let target = SpellingSelectionTarget(processIdentifier: 123, validate: {})
        let shortcut = ClipboardSpellingShortcut(capture: { target }, cycle: { _, _, _, didRestore in
            cycles += 1
            await withCheckedContinuation { pending = $0; started.fulfill() }
            didRestore(42); restored = true
            return self.corrected
        }, feedback: { feedback.append($0) })
        shortcut.trigger(); shortcut.trigger(); await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(cycles, 1)
        shortcut.cancel(); XCTAssertTrue(shortcut.busy)
        pending?.resume(); await waitUntilIdle(shortcut)
        XCTAssertTrue(restored); XCTAssertFalse(shortcut.busy)
        XCTAssertFalse(feedback.contains(where: { $0.contains("Правка отправлена") }))
    }
    func testNoChangesAndNativeErrorsHaveHonestFeedback() async {
        let target = SpellingSelectionTarget(processIdentifier: 123, validate: {})
        var feedback: [String] = []
        let unchanged = ClipboardSpellingShortcut(capture: { target }, cycle: { _, _, _, _ in
            LocalSpellingOutcome(text: "Привет", misspellingCount: 0, correctedCount: 0, unresolvedCount: 0)
        }, feedback: { feedback.append($0) })
        unchanged.trigger(); await waitUntilIdle(unchanged)
        XCTAssertTrue(feedback.last?.contains("не нашёл") == true)
        let failed = ClipboardSpellingShortcut(capture: { target }, cycle: { _, _, _, _ in
            throw TextCorrectionFailure("Приложение не скопировало выделенный текст")
        }, feedback: { feedback.append($0) })
        failed.trigger(); await waitUntilIdle(failed)
        XCTAssertTrue(feedback.last?.contains("не скопировало") == true)
        XCTAssertFalse(feedback.contains(where: { $0.contains("Правка отправлена") }))
    }
}
