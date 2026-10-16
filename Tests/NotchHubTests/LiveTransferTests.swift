import XCTest
import AppKit
import Combine
@testable import NotchHub

final class LiveTransferTests: XCTestCase {
    /// Opt-in deployment smoke test. Never uploads a user's actual clipboard.
    @MainActor func testThreeImagesRoundTripThroughConfiguredServer() async throws {
        guard let keyPath = ProcessInfo.processInfo.environment["NOTCHHUB_TRANSFER_KEY_FILE"] else { throw XCTSkip("Set NOTCHHUB_TRANSFER_KEY_FILE for the optional HTTPS smoke test") }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = "NotchHubLiveTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let senderBoard = NSPasteboard.withUniqueName(), receiverBoard = NSPasteboard.withUniqueName()
        defer { senderBoard.releaseGlobally(); receiverBoard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let senderStore = HubStore(root: root.appendingPathComponent("sender"), monitor: false, pasteboard: senderBoard, preferences: HubPreferences(defaults: defaults))
        let receiverStore = HubStore(root: root.appendingPathComponent("receiver"), monitor: false, pasteboard: receiverBoard, preferences: HubPreferences(defaults: defaults))
        for color in [NSColor.systemBlue, NSColor.systemGreen, NSColor.systemOrange] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            color.setFill(); CGRect(x: 0, y: 0, width: 64, height: 48).fill(); NSGraphicsContext.restoreGraphicsState()
            senderStore.addImage(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        }
        let selected = senderStore.archive.clips
        XCTAssertEqual(selected.count, 3)
        let senderSettings = TransferSettings(defaults: defaults, readKey: { _ in key }, writeKey: { _, _ in })
        let receiverSettings = TransferSettings(defaults: defaults, readKey: { _ in nil }, writeKey: { _, _ in })
        let sender = ClipboardTransfer(settings: senderSettings), receiver = ClipboardTransfer(settings: receiverSettings)
        defer { sender.cancel(); receiver.cancel() }
        let uploaded = expectation(description: "Encrypted transfer uploaded")
        let sent = sender.$shareURL.compactMap { $0 }.prefix(1).sink { _ in uploaded.fulfill() }
        sender.send(clips: selected, store: senderStore)
        await fulfillment(of: [uploaded], timeout: 35)
        sent.cancel()
        let link = try XCTUnwrap(sender.shareURL, sender.message ?? "No invitation created")
        let downloaded = expectation(description: "Three separate images decrypted")
        let incoming = receiver.$incoming.filter { $0.count == 3 }.prefix(1).sink { _ in downloaded.fulfill() }
        receiver.receive(url: link)
        await fulfillment(of: [downloaded], timeout: 35)
        incoming.cancel()
        XCTAssertEqual(receiver.incoming.count, 3)
        receiverBoard.clearContents(); receiverBoard.setString("unchanged before selection", forType: .string)
        XCTAssertTrue(receiverStore.receiveTransfer(receiver.incoming), receiverStore.message ?? "Import failed")
        XCTAssertEqual(receiverStore.archive.clips.count, 3)
        XCTAssertEqual(receiverBoard.string(forType: .string), "unchanged before selection")
        for (original, received) in zip(selected, receiverStore.archive.clips) {
            XCTAssertEqual(received.kind, .image)
            let expected = try Data(contentsOf: XCTUnwrap(senderStore.assetURL(original)))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receiverStore.assetURL(received))), expected)
            receiverStore.copy(received)
            XCTAssertEqual(receiverBoard.data(forType: .png), expected)
        }
        receiver.dismissIncoming()
        XCTAssertTrue(receiver.incoming.isEmpty)
    }
}
