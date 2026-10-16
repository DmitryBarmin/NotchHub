import XCTest
import AppKit
@testable import NotchHub

final class TransferStoreTests: XCTestCase {
    private func withStore(_ action: (HubStore, HubPreferences, NSPasteboard) throws -> Void) rethrows {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString, board = NSPasteboard.withUniqueName()
        let defaults = UserDefaults(suiteName: name)!
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let preferences = HubPreferences(defaults: defaults)
        try action(HubStore(root: root, monitor: false, pasteboard: board, preferences: preferences), preferences, board)
    }
    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
    private func item(_ kind: Clip.Kind, text: String? = nil, data: Data? = nil, title: String = "") -> TransferItem {
        TransferItem(id: UUID(), kind: kind, title: title, text: text, data: data, filename: nil)
    }
    func testImagesIncludingIdenticalBytesRemainSeparateAndNeverOverwritePasteboard() throws {
        try withStore { store, _, board in
            board.clearContents(); board.setString("keep clipboard", forType: .string)
            for index in 0..<20 { store.addText("old \(index)") }
            let data = try png()
            XCTAssertTrue(store.receiveTransfer([item(.image, data: data, title: "first"), item(.image, data: data, title: "second"), item(.image, data: data, title: "third")]))
            XCTAssertEqual(store.archive.clips.count, 20)
            let received = Array(store.archive.clips.prefix(3))
            XCTAssertEqual(received.map(\.title), ["first", "second", "third"])
            XCTAssertEqual(Set(received.map(\.fingerprint)).count, 3)
            XCTAssertEqual(Set(received.map(\.id)).count, 3)
            XCTAssertEqual(Set(received.compactMap(\.asset)).count, 1)
            for clip in received { XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.assetURL(clip))), data) }
            XCTAssertEqual(board.string(forType: .string), "keep clipboard")
        }
    }
    func testInvalidLaterImageRejectsWholeBatchWithoutAssetsOrHistoryChanges() throws {
        try withStore { store, _, _ in
            store.addText("old"); let before = store.archive.clips
            XCTAssertFalse(store.receiveTransfer([item(.image, data: try png()), item(.image, data: Data("invalid".utf8))]))
            XCTAssertEqual(store.archive.clips, before)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: store.root.appendingPathComponent("Assets"), includingPropertiesForKeys: nil).isEmpty)
        }
    }
    func testStorageFailureRollsBackMetadataAndRemovesStaging() throws {
        try withStore { store, _, _ in
            store.addText("old"); let before = store.archive.clips
            let history = try Data(contentsOf: store.root.appendingPathComponent("history.json"))
            let assets = store.root.appendingPathComponent("Assets")
            try FileManager.default.removeItem(at: assets); try Data().write(to: assets)
            XCTAssertFalse(store.receiveTransfer([item(.image, data: try png())]))
            XCTAssertEqual(store.archive.clips, before)
            XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("history.json")), history)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".transfer-") })
        }
    }
    func testWholeBatchQuotaRejectionPreservesProtectedAndOrdinaryHistory() {
        withStore { store, preferences, _ in
            preferences.update { $0.diskLimitMB = 50 }
            store.addText("old"); store.addText("protected", shelf: true)
            let clips = store.archive.clips, shelf = store.archive.shelf
            XCTAssertFalse(store.receiveTransfer([item(.text, text: String(repeating: "a", count: 26 * 1024 * 1024)), item(.text, text: String(repeating: "b", count: 26 * 1024 * 1024))]))
            XCTAssertEqual(store.archive.clips, clips); XCTAssertEqual(store.archive.shelf, shelf)
        }
    }
    func testDisabledSharingRejectsIncomingAndCountIsBounded() {
        withStore { store, preferences, _ in
            preferences.setFeature(.sharing, enabled: false)
            XCTAssertFalse(store.receiveTransfer([item(.text, text: "incoming")]))
            preferences.setFeature(.sharing, enabled: true)
            XCTAssertFalse(store.receiveTransfer((0..<21).map { item(.text, text: String($0)) }))
            XCTAssertTrue(store.archive.clips.isEmpty)
        }
    }
    func testInitializationPersistsPruningBeforeAssetCleanup() throws {
        try withStore { store, preferences, board in
            preferences.update { $0.historyLimit = 50 }
            for index in 0..<25 { store.addText("item \(index)") }
            preferences.update { $0.historyLimit = 20 }
            let restored = HubStore(root: store.root, monitor: false, pasteboard: board, preferences: preferences)
            XCTAssertEqual(restored.archive.clips.count, 20)
            let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: store.root.appendingPathComponent("history.json")))
            XCTAssertEqual(saved.clips.count, 20)
        }
    }
}
