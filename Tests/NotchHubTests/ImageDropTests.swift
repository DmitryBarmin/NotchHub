import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import NotchHub

final class ImageDropTests: XCTestCase {
    private func jpeg() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 6000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 6000, height: 2000))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    }
    @MainActor func testDropKeepsNativeJPEGInsteadOfExpandingThroughNSImage() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: board)
        let data = try jpeg()
        XCTAssertLessThan(data.count, HubStore.maxBytes)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        XCTAssertTrue(provider.canLoadObject(ofClass: NSImage.self))
        let view = HubView(store: store, clock: FocusClock(), state: HubState())
        XCTAssertTrue(view.receive([provider]))
        let imported = expectation(description: "drop completed")
        let observer = store.$archive.filter { !$0.shelf.isEmpty }.prefix(1).sink { _ in imported.fulfill() }
        await fulfillment(of: [imported], timeout: 3)
        observer.cancel()
        store.finishImports()
        XCTAssertNil(store.message)
        let clip = try XCTUnwrap(store.archive.shelf.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.assetURL(clip))), data)
        XCTAssertEqual(store.assetURL(clip)?.pathExtension, "jpeg")
    }
    @MainActor func testClipboardCapturesNativeJPEGWithoutSynthesizingTIFF() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: board)
        let data = try jpeg()
        board.clearContents()
        board.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        XCTAssertEqual(board.pasteboardItems?.first?.types, [NSPasteboard.PasteboardType(UTType.jpeg.identifier)])
        store.capture(); store.finishImports()
        XCTAssertNil(store.message)
        let clip = try XCTUnwrap(store.archive.clips.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.assetURL(clip))), data)
    }
    @MainActor func testDropReportsNativeImageLoadError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: board)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(nil, NSError(domain: "ImageDropTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "image unavailable"])); return nil
        }
        let failed = expectation(description: "drop failure reported")
        let observer = store.$message.compactMap { $0 }.sink { _ in failed.fulfill() }
        XCTAssertTrue(HubView(store: store, clock: FocusClock(), state: HubState()).receive([provider]))
        await fulfillment(of: [failed], timeout: 3)
        observer.cancel()
        XCTAssertNotNil(store.message)
        XCTAssertTrue(store.archive.shelf.isEmpty)
    }
    func testOversizedNSImageFallbackDoesNotAllocateTIFF() {
        final class Image: NSImage {
            override var tiffRepresentation: Data? { XCTFail("Oversized fallback must not allocate a TIFF"); return nil }
        }
        let image = Image(size: CGSize(width: 6000, height: 2000))
        XCTAssertNil(HubView.boundedImageData(image))
    }
    @MainActor func testRejectedNoteCopyPreservesClipboardAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: board)
        store.addText("old history")
        board.setString("current clipboard", forType: .string)
        let before = store.archive.clips
        store.setNote(String(repeating: "x", count: HubStore.maxBytes + 1))
        HubView(store: store, clock: FocusClock(), state: HubState()).copyNote()
        XCTAssertEqual(board.string(forType: .string), "current clipboard")
        XCTAssertEqual(store.archive.clips, before)
        XCTAssertEqual(store.message, "Текст слишком большой (лимит 30 МБ)")
        store.setNote("accepted note")
        HubView(store: store, clock: FocusClock(), state: HubState()).copyNote()
        XCTAssertEqual(board.string(forType: .string), "accepted note")
        XCTAssertEqual(store.archive.clips.first?.text, "accepted note")
    }
}
