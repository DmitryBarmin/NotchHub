import XCTest
import AppKit
import Combine
@testable import NotchHub

final class OCRLifecycleTests: XCTestCase {
    @MainActor private func editor(text: String? = nil) throws -> ScreenshotEditor {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: 800, height: 160).fill()
        if let text {
            (text as NSString).draw(at: CGPoint(x: 40, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let editor = ScreenshotEditor(image: try XCTUnwrap(bitmap.cgImage), size: CGSize(width: 800, height: 160))
        editor.selection = CGRect(x: 0, y: 0, width: 800, height: 160)
        return editor
    }

    @MainActor private func recognize(_ editor: ScreenshotEditor) async {
        let completed = expectation(description: "OCR returns to idle")
        var becameBusy = false
        let observer = editor.$recognizing.sink { recognizing in
            if recognizing { becameBusy = true }
            else if becameBusy { completed.fulfill() }
        }
        editor.recognizeText()
        XCTAssertTrue(editor.recognizing)
        await fulfillment(of: [completed], timeout: 10)
        observer.cancel()
        XCTAssertFalse(editor.recognizing)
    }

    @MainActor func testAsyncRecognitionDeliversEditableTextWithoutAWindow() async throws {
        let editor = try editor(text: "NOTCH HUB 123")
        var results: [String] = []
        editor.recognizedText = { results.append($0) }
        await recognize(editor)
        XCTAssertNil(editor.message)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].contains("NOTCH HUB"))
        await recognize(editor)
        XCTAssertEqual(results.count, 2)
        editor.cancelRecognition()
        XCTAssertNil(editor.recognizedText)
    }

    @MainActor func testCancellationDiscardsInFlightResult() async throws {
        let editor = try editor(text: "NOTCH HUB 123")
        var results: [String] = []
        editor.recognizedText = { results.append($0) }
        editor.recognizeText()
        editor.cancelRecognition()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(editor.recognizing)
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor func testBlankImageReturnsToIdleWithMessageAndNoResultWindow() async throws {
        let editor = try editor()
        await recognize(editor)
        XCTAssertEqual(editor.message, "Текст не найден — выдели область крупнее")
        XCTAssertNil(editor.recognizedText)
    }
}
