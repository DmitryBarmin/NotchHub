import XCTest
import AppKit
@testable import NotchHub

final class StoreDurabilityTests: XCTestCase {
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testCorruptManifestRemainsUntouchedAcrossPreferencesAndEveryWritePath() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets = root.appendingPathComponent("Assets")
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let corrupt = Data("{corrupt archive".utf8), original = try png()
        try corrupt.write(to: root.appendingPathComponent("history.json")); try original.write(to: assets.appendingPathComponent("protected.png"))
        let preferences = HubPreferences(defaults: defaults)
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: preferences)
        let fake = Clip(kind: .text, title: "new", text: "new", fingerprint: "new")
        preferences.setFeature(.favorites, enabled: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertFalse(store.addText("new")); store.addImage(original)
        let file = root.appendingPathComponent("source.txt"); try Data("source".utf8).write(to: file)
        store.addFile(file); store.enqueueFile(file); store.enqueueImage(original); store.finishImports()
        store.setNote("new"); store.insert(fake); store.toggleFavorite(fake); store.remove(fake)
        store.createWorkspace(name: "new"); store.selectWorkspace(nil); store.renameWorkspace(id: UUID(), name: "new"); store.removeWorkspace(UUID()); store.moveToWorkspace(fake, id: nil)
        XCTAssertFalse(store.addTemplate(title: "new", text: "new")); store.removeTemplate(TextTemplate(title: "new", text: "new"))
        XCTAssertFalse(store.updateTemplate(TextTemplate(title: "new", text: "new")))
        XCTAssertFalse(store.receiveTransfer([TransferItem(kind: .text, title: "new", text: "new")]))
        XCTAssertFalse(store.clear(shelf: false)); store.clearClipboard(); store.enforcePolicy(); XCTAssertFalse(store.save())
        XCTAssertTrue(store.archive.clips.isEmpty); XCTAssertTrue(store.archive.shelf.isEmpty); XCTAssertTrue(store.archive.workspaces.isEmpty); XCTAssertTrue(store.archive.templates.isEmpty)
        XCTAssertEqual(store.archive.note, "")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), corrupt)
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("protected.png")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assets.path), ["protected.png"])
        XCTAssertNotNil(store.message)
    }
    func testFailedEvictionRemovalAndClearPreserveDurableAssetAndMemory() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let board = NSPasteboard.withUniqueName()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: HubPreferences(defaults: defaults))
        store.addImage(try png()); let image = try XCTUnwrap(store.archive.clips.first), url = try XCTUnwrap(store.assetURL(image))
        for index in 0..<19 { store.addText("item \(index)") }
        let before = store.archive.clips, history = try Data(contentsOf: root.appendingPathComponent("history.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertFalse(store.addText("would evict image")); XCTAssertEqual(store.archive.clips, before)
        store.remove(image); XCTAssertEqual(store.archive.clips, before)
        XCTAssertFalse(store.clear(shelf: false)); XCTAssertEqual(store.archive.clips, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), history)
    }
    func testFailedPreferencesPruningRollsBackAndKeepsAssets() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let board = NSPasteboard.withUniqueName()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let preferences = HubPreferences(defaults: defaults); preferences.update { $0.historyLimit = 50 }
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: preferences)
        store.addImage(try png()); let image = try XCTUnwrap(store.archive.clips.first), url = try XCTUnwrap(store.assetURL(image))
        for index in 0..<25 { store.addText("item \(index)") }
        let before = store.archive.clips, history = try Data(contentsOf: root.appendingPathComponent("history.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        preferences.update { $0.historyLimit = 20 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(store.archive.clips, before); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), history)
    }
}
