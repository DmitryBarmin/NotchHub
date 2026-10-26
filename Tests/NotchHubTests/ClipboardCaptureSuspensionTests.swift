import AppKit
import XCTest
@testable import NotchHub

@MainActor final class ClipboardCaptureSuspensionTests: XCTestCase {
    private func withStore(_ body: (HubStore, NSPasteboard) throws -> Void) throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: HubPreferences(defaults: defaults), frontmostApp: { "allowed.app" })
        try body(store, board)
    }
    func testSuspendedCaptureDoesNotPersistTemporarySelectionOrAdvanceCount() throws {
        try withStore { store, board in
            var suspended = true; store.captureSuspended = { suspended }
            board.clearContents(); board.setString("temporary selection", forType: .string)
            store.capture(); XCTAssertTrue(store.archive.clips.isEmpty)
            suspended = false; store.capture()
            XCTAssertEqual(store.archive.clips.map(\.text), ["temporary selection"])
            XCTAssertFalse(store.paused)
        }
    }
    func testOwnedRestorationIsIgnoredWithoutCapturingTemporaryOrRestoredClipboard() throws {
        try withStore { store, board in
            var suspended = true; store.captureSuspended = { suspended }
            board.clearContents(); board.setString("copied selection", forType: .string)
            store.capture()
            board.clearContents(); board.setString("original", forType: .string)
            store.ignoreClipboardChange(board.changeCount)
            suspended = false; store.capture()
            XCTAssertTrue(store.archive.clips.isEmpty)
        }
    }
    func testUserCopyDuringCancellationIsStillCapturedAndStaleRestoreCallbackCannotDropIt() throws {
        try withStore { store, board in
            var suspended = true; store.captureSuspended = { suspended }
            board.clearContents(); board.setString("temporary", forType: .string)
            let staleCount = board.changeCount
            board.clearContents(); board.setString("new user copy", forType: .string)
            store.capture(); store.ignoreClipboardChange(staleCount)
            suspended = false; store.capture()
            XCTAssertEqual(store.archive.clips.map(\.text), ["new user copy"])
        }
    }
}
