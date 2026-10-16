import XCTest
import AppKit
@testable import NotchHub

final class FeatureStoreTests: XCTestCase {
    private func withStore(frontmostApp: @escaping () -> String? = { "excluded.app" }, _ body: (HubStore, HubPreferences, NSPasteboard) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        try body(HubStore(root: root, monitor: false, pasteboard: board, preferences: preferences, frontmostApp: frontmostApp), preferences, board)
    }
    func testOldArchiveDecodesWithoutNewKeys() throws {
        let old = Data("{\"clips\":[],\"shelf\":[],\"note\":\"old\"}".utf8)
        let archive = try JSONDecoder().decode(Archive.self, from: old)
        XCTAssertEqual(archive.note, "old"); XCTAssertTrue(archive.favorites.isEmpty); XCTAssertTrue(archive.workspaces.isEmpty); XCTAssertTrue(archive.templates.isEmpty)
        XCTAssertNil(archive.activeWorkspaceID)
    }
    func testFavoriteImageSurvivesHistoryClearAndReload() throws {
        try withStore { store, preferences, board in
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            store.addImage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            let clip = try XCTUnwrap(store.archive.clips.first), url = try XCTUnwrap(store.assetURL(clip))
            store.toggleFavorite(clip); store.clear(shelf: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let restored = HubStore(root: store.root, monitor: false, pasteboard: board, preferences: preferences)
            XCTAssertEqual(restored.archive.favorites.count, 1)
            XCTAssertTrue(restored.isFavorite(clip))
            restored.toggleFavorite(clip)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testHistoryLimitExpiryNeverRemoveShelfOrFavorites() throws {
        try withStore { store, preferences, _ in
            preferences.update { $0.historyLimit = 50; $0.expiryHours = 1 }
            store.addText("protected", shelf: true)
            store.addText("favorite"); store.toggleFavorite(store.archive.clips[0])
            for index in 0..<60 { store.addText("item \(index)") }
            XCTAssertEqual(store.archive.clips.count, 50)
            store.enforcePolicy(now: Date().addingTimeInterval(7200))
            XCTAssertTrue(store.archive.clips.isEmpty)
            XCTAssertEqual(store.archive.shelf.count, 1); XCTAssertEqual(store.archive.favorites.count, 1)
        }
    }
    func testWorkspaceNotesShelfAndQueuedImportStayInSubmittedWorkspace() throws {
        try withStore { store, preferences, _ in
            store.setNote("global")
            store.createWorkspace(name: "A")
            let first = try XCTUnwrap(store.archive.activeWorkspaceID)
            store.setNote("A note"); store.addText("A shelf", shelf: true)
            let file = store.root.appendingPathComponent("queued.txt"); try Data("file".utf8).write(to: file)
            store.enqueueFile(file)
            store.createWorkspace(name: "B"); store.setNote("B note")
            store.finishImports()
            XCTAssertTrue(store.activeShelf.isEmpty); XCTAssertEqual(store.currentNote, "B note")
            store.selectWorkspace(first)
            XCTAssertEqual(store.activeShelf.count, 2); XCTAssertEqual(store.currentNote, "A note")
            store.clear(shelf: true); XCTAssertTrue(store.activeShelf.isEmpty)
            store.addText("saved", shelf: true); store.removeWorkspace(first)
            XCTAssertEqual(store.currentNote, "global"); XCTAssertEqual(store.activeShelf.first?.text, "saved")
            XCTAssertEqual(store.archive.templates.first?.text, "A note")
            preferences.setFeature(.workspaces, enabled: false)
            XCTAssertEqual(store.currentNote, "global")
        }
    }
    func testClearingAnotherWorkspaceDoesNotCancelQueuedImport() throws {
        try withStore { store, _, _ in
            store.createWorkspace(name: "A"); let first = try XCTUnwrap(store.activeWorkspaceID)
            store.createWorkspace(name: "B"); let second = try XCTUnwrap(store.activeWorkspaceID)
            let file = store.root.appendingPathComponent("queued.txt"); try Data("file".utf8).write(to: file)
            store.enqueueFile(file)
            store.selectWorkspace(first); store.clear(shelf: true); store.finishImports()
            store.selectWorkspace(second); XCTAssertEqual(store.activeShelf.count, 1)
        }
    }
    func testRejectedProtectedQuotaDoesNotEraseShelf() throws {
        try withStore { store, preferences, _ in
            preferences.update { $0.diskLimitMB = 50 }
            XCTAssertTrue(store.addText(String(repeating: "a", count: 26 * 1024 * 1024), shelf: true))
            let kept = store.archive.shelf
            XCTAssertFalse(store.addText(String(repeating: "b", count: 26 * 1024 * 1024), shelf: true))
            XCTAssertEqual(store.archive.shelf, kept)
            XCTAssertNotNil(store.message)
        }
    }
    func testPrivacyExclusionAndConcealedClipboard() throws {
        try withStore { store, preferences, board in
            preferences.update { $0.excludedAppIDs = ["excluded.app"] }
            board.clearContents(); board.setString("secret", forType: .string); store.capture()
            XCTAssertTrue(store.archive.clips.isEmpty)
            preferences.setFeature(.privacy, enabled: false)
            board.clearContents(); board.setString("allowed", forType: .string); store.capture()
            XCTAssertEqual(store.archive.clips.first?.text, "allowed")
            board.clearContents(); board.setString("hidden", forType: .string); board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); store.capture()
            XCTAssertEqual(store.archive.clips.count, 1)
        }
    }
    func testSwitchingAwayFromExcludedAppDiscardsPendingSecretBeforePolling() throws {
        var foreground: String? = "excluded.app"
        try withStore(frontmostApp: { foreground }) { store, preferences, board in
            preferences.update { $0.excludedAppIDs = ["excluded.app"] }
            board.clearContents(); board.setString("secret copied before app switch", forType: .string)
            foreground = "safe.app"
            store.capture()
            XCTAssertTrue(store.archive.clips.isEmpty)
            board.clearContents(); board.setString("next safe copy", forType: .string)
            store.capture()
            XCTAssertEqual(store.archive.clips.map(\.text), ["next safe copy"])
            board.clearContents(); board.setString("pending before exclusion", forType: .string)
            foreground = "excluded.app"
            store.capture()
            XCTAssertEqual(store.archive.clips.map(\.text), ["next safe copy"])
            foreground = "safe.app"; store.capture()
            XCTAssertEqual(store.archive.clips.count, 1)
        }
    }
    func testBatchPreservesOrderAndMixedRejectionPreservesClipboard() throws {
        try withStore { store, _, board in
            store.addText("first"); store.addText("second")
            XCTAssertTrue(store.copyBatch(Array(store.archive.clips.reversed()), separator: " | "))
            XCTAssertEqual(board.string(forType: .string), "first | second")
            let file = store.root.appendingPathComponent("source.txt"); try Data("file".utf8).write(to: file)
            store.addFile(file)
            let clip = try XCTUnwrap(store.archive.shelf.first)
            XCTAssertFalse(store.copyBatch([store.archive.clips[0], clip]))
            XCTAssertEqual(board.string(forType: .string), "first | second")
            XCTAssertTrue(store.copyBatch([clip]))
            XCTAssertEqual((board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, store.assetURL(clip))
        }
    }
    func testTemplateSaveFailureReturnsFalseAndRestoresOldContent() throws {
        try withStore { store, _, _ in
            XCTAssertTrue(store.addTemplate(title: "Original", text: "saved"))
            let old = store.archive.templates
            let history = store.root.appendingPathComponent("history.json")
            try FileManager.default.removeItem(at: history)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
            var changed = old[0]; changed.text = "draft must stay in editor"
            XCTAssertFalse(store.updateTemplate(changed))
            XCTAssertEqual(store.archive.templates, old)
            XCTAssertFalse(store.addTemplate(title: "New draft", text: "not persisted"))
            XCTAssertEqual(store.archive.templates, old)
            XCTAssertNotNil(store.message)
        }
    }
    func testTemplateQuotaFailureKeepsExistingProtectedContent() throws {
        try withStore { store, preferences, _ in
            preferences.update { $0.diskLimitMB = 50 }
            XCTAssertTrue(store.addText(String(repeating: "a", count: 26 * 1024 * 1024), shelf: true))
            XCTAssertFalse(store.addTemplate(title: "Draft", text: String(repeating: "b", count: 26 * 1024 * 1024)))
            XCTAssertTrue(store.archive.templates.isEmpty)
            XCTAssertEqual(store.archive.shelf.count, 1)
            XCTAssertEqual(store.message, "Недостаточно места для шаблона")
        }
    }
    func testTemplatesAndMovingHistoryToWorkspacePersist() throws {
        try withStore { store, preferences, board in
            store.addText("history"); let clip = store.archive.clips[0]
            store.createWorkspace(name: "Work")
            store.moveToWorkspace(clip, id: store.archive.activeWorkspaceID)
            XCTAssertEqual(store.archive.clips.first?.id, clip.id); XCTAssertEqual(store.activeShelf.first?.text, "history")
            store.addTemplate(title: "T", text: "body")
            var template = try XCTUnwrap(store.archive.templates.first); template.text = "edited"; store.updateTemplate(template)
            let restored = HubStore(root: store.root, monitor: false, pasteboard: board, preferences: preferences)
            XCTAssertEqual(restored.archive.templates.first?.text, "edited"); XCTAssertEqual(restored.activeShelf.count, 1)
            restored.removeTemplate(template); XCTAssertTrue(restored.archive.templates.isEmpty)
        }
    }
}
