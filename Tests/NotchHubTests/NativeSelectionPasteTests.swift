import AppKit
import Carbon
import XCTest
@testable import NotchHub

/// All keyboard posting is injected; tests never synthesize events into other apps.
@MainActor final class NativeSelectionPasteTests: XCTestCase {
    @MainActor private final class Harness {
        let board = NSPasteboard.withUniqueName()
        let notifications = NotificationCenter()
        var time: TimeInterval = 0
        var modifiers: CGEventFlags = []
        var inputs = NativeSelectionPaste.InputCounters()
        var keys: [CGKeyCode] = []
        var pids: [pid_t] = []
        var copiedText: String? = "Превет 😀"
        var copyProtected = false
        var consumePaste = true
        var failKey: CGKeyCode?
        var pasted: [String] = []
        var pauses: [TimeInterval] = []
        var settles: [TimeInterval] = []
        var onPause: (() async throws -> Void)?
        deinit { board.releaseGlobally() }
        func transaction(maximumBytes: Int = HubStore.maxBytes) -> NativeSelectionPaste.Transaction {
            NativeSelectionPaste.Transaction(pasteboard: board, postKey: { pid, key in
                self.keys.append(key); self.pids.append(pid)
                if self.failKey == key { throw TextCorrectionFailure("Injected event failure") }
                if key == CGKeyCode(kVK_ANSI_C), let text = self.copiedText {
                    self.board.clearContents(); self.board.setString(text, forType: .string)
                    if self.copyProtected { self.board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")) }
                }
                if key == CGKeyCode(kVK_ANSI_V), self.consumePaste {
                    XCTAssertTrue(self.board.types?.contains(NativeSelectionPaste.Transaction.transient) == true)
                    XCTAssertTrue(self.board.types?.contains(NativeSelectionPaste.Transaction.generated) == true)
                    if let text = self.board.string(forType: .string) { self.pasted.append(text) }
                }
                // Targeted events use a private source, not physical HID counters.
            }, modifiers: { self.modifiers }, inputs: { self.inputs }, now: { self.time }, pause: { delay in
                self.pauses.append(delay); self.time += delay
                try await self.onPause?()
                try Task.checkCancellation()
            }, settle: { delay in
                self.settles.append(delay); self.time += delay
            }, maximumBytes: maximumBytes, notifications: notifications)
        }
    }
    private func corrected(_ text: String) -> LocalSpellingOutcome {
        LocalSpellingOutcome(text: "Привет 😀", misspellingCount: 1, correctedCount: 1, unresolvedCount: 0)
    }
    private func representations(_ board: NSPasteboard) -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
    }
    private func seedRichClipboard(_ board: NSPasteboard) {
        let text = NSPasteboardItem()
        text.setString("original rich text", forType: .string)
        text.setData(Data("{\\rtf1\\ansi original}".utf8), forType: .rtf)
        text.setData(Data([0, 1, 255]), forType: .init("com.example.private-format"))
        let image = NSPasteboardItem(); image.setData(Data([8, 9, 10]), forType: .png)
        board.clearContents(); XCTAssertTrue(board.writeObjects([text, image]))
    }

    func testCopyCorrectPasteRestoresEveryRepresentationAndDoesNotCountOwnKeysAsPhysicalInput() async throws {
        let h = Harness(); seedRichClipboard(h.board)
        let original = representations(h.board)
        var validations = 0, restored: [Int] = [], sources: [String] = []
        let outcome = try await h.transaction().perform(processIdentifier: 123, validate: { validations += 1 }, correct: { text in
            sources.append(text); return self.corrected(text)
        }, didRestore: { restored.append($0) })
        XCTAssertEqual(sources, ["Превет 😀"])
        XCTAssertEqual(outcome.text, "Привет 😀")
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)])
        XCTAssertEqual(h.pids, [123, 123]); XCTAssertEqual(h.pasted, ["Привет 😀"])
        XCTAssertGreaterThanOrEqual(validations, 4)
        XCTAssertEqual(representations(h.board), original)
        XCTAssertEqual(restored, [h.board.changeCount])
        XCTAssertEqual(h.inputs, NativeSelectionPaste.InputCounters())
    }
    func testUserNewClipboardAlwaysWinsAndNoPasteIsPosted() async {
        let h = Harness(); h.board.setString("original", forType: .string)
        var restored: [Int] = []
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in
                h.inputs.keyDown &+= 1
                h.board.clearContents(); h.board.setString("new user copy", forType: .string)
                return self.corrected(text)
            }, didRestore: { restored.append($0) })
            XCTFail("Changed physical input should abort")
        } catch {}
        XCTAssertEqual(h.board.string(forType: .string), "new user copy")
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)]); XCTAssertTrue(restored.isEmpty)
    }
    func testClipboardChangeWithoutPhysicalInputDuringCorrectionIsNotOverwritten() async {
        let h = Harness(); h.board.setString("original", forType: .string)
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in
                h.board.clearContents(); h.board.setString("external update", forType: .string)
                return self.corrected(text)
            })
            XCTFail("A new clipboard must win")
        } catch {}
        XCTAssertEqual(h.board.string(forType: .string), "external update")
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
    }
    private final class ReadSpy: NSObject, NSPasteboardItemDataProvider {
        var reads = 0
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            reads += 1; item.setString("secret", forType: type)
        }
    }
    func testProtectedOriginalClipboardIsRejectedBeforeReadingAnyRepresentationOrPosting() async {
        let h = Harness(), spy = ReadSpy(), item = NSPasteboardItem()
        item.setDataProvider(spy, forTypes: [.string])
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        h.board.writeObjects([item]); let count = h.board.changeCount
        var calls = 0
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in calls += 1; return self.corrected(text) })
            XCTFail("Protected clipboard should fail")
        } catch {}
        XCTAssertEqual(spy.reads, 0); XCTAssertEqual(calls, 0); XCTAssertTrue(h.keys.isEmpty)
        XCTAssertEqual(h.board.changeCount, count)
    }
    func testProtectedCopiedSelectionNeverEntersCorrectorAndOriginalIsRestored() async {
        let h = Harness(); seedRichClipboard(h.board); let original = representations(h.board)
        h.copyProtected = true; var calls = 0
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in calls += 1; return self.corrected(text) })
            XCTFail("Protected selection should fail")
        } catch {}
        XCTAssertEqual(calls, 0); XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
        XCTAssertEqual(representations(h.board), original)
    }
    func testEntireSnapshotMustFitBeforeClipboardMutation() async {
        let h = Harness(); h.board.setData(Data(repeating: 1, count: 8), forType: .rtf)
        let count = h.board.changeCount
        do {
            _ = try await h.transaction(maximumBytes: 4).perform(processIdentifier: 123, validate: {}, correct: self.corrected)
            XCTFail("Oversize original must fail before copy")
        } catch {}
        XCTAssertEqual(h.board.changeCount, count); XCTAssertTrue(h.keys.isEmpty)
    }
    func testHeldPhysicalModifiersTimeoutWithoutPostingOrChangingClipboard() async {
        let h = Harness(); h.modifiers = [.maskCommand, .maskShift]; h.board.setString("original", forType: .string)
        let count = h.board.changeCount
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: self.corrected)
            XCTFail("Held modifiers must time out")
        } catch {}
        XCTAssertGreaterThanOrEqual(h.time, 2); XCTAssertLessThan(h.time, 2.1)
        XCTAssertTrue(h.keys.isEmpty); XCTAssertEqual(h.board.changeCount, count)
    }
    func testCancellationWhileModifiersAreHeldDoesNotClaimClipboard() async {
        let h = Harness(); h.modifiers = .maskCommand; h.board.setString("original", forType: .string)
        let count = h.board.changeCount, started = expectation(description: "waiting for modifiers")
        var resume: CheckedContinuation<Void, Never>?
        h.onPause = { await withCheckedContinuation { resume = $0; started.fulfill() } }
        let transaction = h.transaction()
        let task = Task { try await transaction.perform(processIdentifier: 123, validate: {}, correct: self.corrected) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel(); resume?.resume()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertTrue(h.keys.isEmpty); XCTAssertEqual(h.board.changeCount, count)
    }
    func testFailedCopyEventAndFailedCorrectionRestoreOriginalWithoutRetry() async {
        for failEvent in [true, false] {
            let h = Harness(); seedRichClipboard(h.board); let original = representations(h.board)
            if failEvent { h.failKey = CGKeyCode(kVK_ANSI_C) }
            var restored: [Int] = []
            do {
                _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { _ in throw TextCorrectionFailure("Injected correction failure") }, didRestore: { restored.append($0) })
                XCTFail("Expected error")
            } catch {}
            XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
            XCTAssertEqual(representations(h.board), original)
            XCTAssertEqual(restored, [h.board.changeCount])
        }
    }
    func testReadAcknowledgementWaitsForConsumerAndMissingReadReportsFailure() async {
        for consumerReads in [true, false] {
            let h = Harness(); h.board.setString("original", forType: .string)
            h.consumePaste = false
            h.onPause = {
                if consumerReads && h.keys.last == CGKeyCode(kVK_ANSI_V) {
                    XCTAssertTrue(h.board.types?.contains(NativeSelectionPaste.Transaction.transient) == true)
                    XCTAssertEqual(h.board.string(forType: .string), "Привет 😀")
                }
            }
            do {
                _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: self.corrected)
                XCTAssertTrue(consumerReads)
            } catch { XCTAssertFalse(consumerReads) }
            // If the queued CmdV has not consumed its payload, restoring unrelated
            // original text would corrupt a later paste. Keep the intended correction.
            XCTAssertEqual(h.board.string(forType: .string), consumerReads ? "original" : "Привет 😀")
            XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)])
            if !consumerReads { XCTAssertGreaterThanOrEqual(h.time, 1) }
        }
    }
    func testNoCorrectionRestoresOriginalWithoutPastingOrErasingSelection() async throws {
        let h = Harness(); h.board.setString("original", forType: .string)
        _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in
            LocalSpellingOutcome(text: text, misspellingCount: 0, correctedCount: 0, unresolvedCount: 0)
        })
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
        XCTAssertEqual(h.board.string(forType: .string), "original")
    }
    func testCancellationDuringCorrectionRestoresOriginalAndRejectsLateResult() async {
        let h = Harness(); seedRichClipboard(h.board); let original = representations(h.board)
        var resume: CheckedContinuation<LocalSpellingOutcome, Never>?, restored: [Int] = []
        let started = expectation(description: "correcting")
        let transaction = h.transaction()
        let task = Task {
            try await transaction.perform(processIdentifier: 123, validate: {}, correct: { _ in
                await withCheckedContinuation { resume = $0; started.fulfill() }
            }, didRestore: { restored.append($0) })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel(); resume?.resume(returning: corrected("Превет 😀"))
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
        XCTAssertEqual(representations(h.board), original); XCTAssertEqual(restored.count, 1)
    }
    func testNativeCopyCanPublishTextAfterAnEmptyOwnershipChange() async throws {
        let h = Harness(); h.board.setString("original", forType: .string); h.copiedText = nil
        var step = 0, seen: [String] = []
        h.onPause = {
            step += 1
            if step == 1 { h.board.clearContents() }
            if step == 2 { h.board.setString("Превет 😀", forType: .string) }
        }
        _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in
            seen.append(text); return self.corrected(text)
        })
        XCTAssertEqual(seen, ["Превет 😀"])
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)])
        XCTAssertEqual(h.pasted, ["Привет 😀"])
        XCTAssertEqual(h.board.string(forType: .string), "original")
    }
    func testPhysicalNewCopyDuringNativeCopyWaitIsNotAdoptedOrRestored() async {
        let h = Harness(); h.board.setString("original", forType: .string); h.copiedText = nil
        var calls = 0, restored: [Int] = []
        h.onPause = {
            h.inputs.keyDown &+= 1
            h.board.clearContents(); h.board.setString("new user clipboard", forType: .string)
        }
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in
                calls += 1; return self.corrected(text)
            }, didRestore: { restored.append($0) })
            XCTFail("User activity should abort copy wait")
        } catch {}
        XCTAssertEqual(h.board.string(forType: .string), "new user clipboard")
        XCTAssertEqual(calls, 0); XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
    }
    func testCancellationWithUnreadPasteNeverMakesLatePasteReadOriginalClipboard() async {
        let h = Harness(); h.board.setString("unrelated original", forType: .string); h.consumePaste = false
        var resume: CheckedContinuation<Void, Never>?, restored: [Int] = []
        let started = expectation(description: "paste queued")
        h.onPause = { await withCheckedContinuation { resume = $0; started.fulfill() } }
        let transaction = h.transaction()
        let task = Task { try await transaction.perform(processIdentifier: 123, validate: {}, correct: self.corrected, didRestore: { restored.append($0) }) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel(); resume?.resume()
        do { _ = try await task.value; XCTFail("Unread cancelled paste must fail") } catch {}
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)])
        XCTAssertEqual(h.board.string(forType: .string), "Привет 😀", "A late target read must receive the correction")
        XCTAssertTrue(h.board.types?.contains(NativeSelectionPaste.Transaction.transient) == true)
        XCTAssertTrue(restored.isEmpty)
    }
    func testTerminationWithUnreadPasteKeepsIntendedPayloadForLateTargetRead() async {
        let h = Harness(); h.board.setString("unrelated original", forType: .string); h.consumePaste = false
        var notified = false, restored: [Int] = []
        h.onPause = {
            if !notified {
                notified = true; h.notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            }
        }
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: self.corrected, didRestore: { restored.append($0) })
            XCTFail("Unread paste must not be reported as confirmed")
        } catch {}
        XCTAssertEqual(h.board.string(forType: .string), "Привет 😀")
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)])
        XCTAssertTrue(restored.isEmpty)
    }
    func testRetryCanSnapshotOnlyKnownOwnUnreadPayload() async throws {
        let h = Harness(); h.board.setString("original", forType: .string); h.consumePaste = false
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: self.corrected)
            XCTFail("Unread paste must fail")
        } catch {}
        let retained = representations(h.board)
        h.consumePaste = true
        _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: self.corrected)
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V)])
        XCTAssertEqual(h.pasted, ["Привет 😀"])
        XCTAssertEqual(representations(h.board), retained)
    }
    func testForeignTransientMarkerIsRejectedBeforeReadingProtectedText() async {
        let h = Harness(), spy = ReadSpy(), item = NSPasteboardItem()
        item.setDataProvider(spy, forTypes: [.string])
        item.setData(Data(), forType: NativeSelectionPaste.Transaction.transient)
        item.setData(Data(UUID().uuidString.utf8), forType: NativeSelectionPaste.Transaction.marker)
        h.board.writeObjects([item]); let count = h.board.changeCount
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: self.corrected)
            XCTFail("An unknown marker must not bypass protection")
        } catch {}
        XCTAssertEqual(spy.reads, 0); XCTAssertTrue(h.keys.isEmpty)
        XCTAssertEqual(h.board.changeCount, count)
    }
    func testTerminationRestoresOwnedClipboardSynchronouslyAndPreventsPaste() async {
        let h = Harness(); seedRichClipboard(h.board); let original = representations(h.board)
        var restored: [Int] = []
        do {
            _ = try await h.transaction().perform(processIdentifier: 123, validate: {}, correct: { text in
                h.notifications.post(name: NSApplication.willTerminateNotification, object: nil)
                XCTAssertEqual(self.representations(h.board), original)
                return self.corrected(text)
            }, didRestore: { restored.append($0) })
            XCTFail("Terminated transaction must not paste")
        } catch {}
        XCTAssertEqual(h.keys, [CGKeyCode(kVK_ANSI_C)])
        XCTAssertEqual(representations(h.board), original); XCTAssertEqual(restored.count, 1)
    }
}
