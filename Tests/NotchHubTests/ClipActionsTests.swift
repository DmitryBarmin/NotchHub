import XCTest
import AppKit
import SwiftUI
@testable import NotchHub

final class ClipActionsTests: XCTestCase {
    func testQRRejectsEmptyAndOversizedUTF8WithoutTruncation() throws {
        XCTAssertThrowsError(try QuickShareController.qrImage(text: ""))
        XCTAssertThrowsError(try QuickShareController.qrImage(text: String(repeating: "я", count: 1025)))
        XCTAssertNotNil(try QuickShareController.qrImage(text: "https://example.com/?text=Привет"))
    }
    @MainActor func testDetachedPreviewOwnsCopyAndBoundsWindowLifetime() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: source)
        let controller = DetachedPreviewController()
        defer { controller.closeAll() }
        controller.open(clip: Clip(kind: .file, title: "Fixture", fingerprint: "file"), url: source)
        XCTAssertEqual(controller.windowCount, 1); XCTAssertNil(controller.message)
        let preview = try XCTUnwrap(NSApp.windows.first { $0.title == "Fixture" }?.contentView as? NSHostingView<ClipPreviewView>)
        let privateCopy = try XCTUnwrap(preview.rootView.url)
        XCTAssertNotEqual(privateCopy, source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try String(contentsOf: privateCopy), "fixture")
        for index in 0..<7 { controller.open(clip: Clip(kind: .text, title: "Text \(index)", text: "Text", fingerprint: "\(index)"), url: nil) }
        XCTAssertEqual(controller.windowCount, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateCopy.path))
        controller.closeAll(); XCTAssertEqual(controller.windowCount, 0)
    }
    @MainActor func testOCRCancellationSuppressesOldCompletionAndAllowsRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root)
        let entered = expectation(description: "recognizer started"), gate = DispatchSemaphore(value: 0)
        let oldCompletion = expectation(description: "cancelled result stays suppressed"); oldCompletion.isInverted = true
        var calls = 0
        let controller = ImageOCRController(recognizer: { _ in
            calls += 1
            if calls == 1 { entered.fulfill(); _ = gate.wait(timeout: .now() + 3) }
            return "recognized"
        })
        controller.recognize(url: root) { _ in oldCompletion.fulfill() }
        await fulfillment(of: [entered], timeout: 2)
        controller.cancel(); XCTAssertFalse(controller.busy)
        let completed = expectation(description: "new request completed")
        controller.recognize(url: root) { result in
            XCTAssertEqual(try? result.get(), "recognized"); completed.fulfill()
        }
        gate.signal()
        await fulfillment(of: [completed], timeout: 3)
        await fulfillment(of: [oldCompletion], timeout: 0.05)
        XCTAssertFalse(controller.busy)
    }
}
