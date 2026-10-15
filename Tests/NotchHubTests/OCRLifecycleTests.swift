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

    @MainActor func testAsyncRecognitionReturnsToIdleAndReplacesPreviousResultWindow() async throws {
        let editor = try editor(text: "NOTCH HUB 123")
        defer { editor.textWindow?.close() }
        await recognize(editor)
        XCTAssertNil(editor.message)
        let first = try XCTUnwrap(editor.textWindow)
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(first.title, "Распознанный текст")
        await recognize(editor)
        XCTAssertNil(editor.message)
        let second = try XCTUnwrap(editor.textWindow)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
        second.close()
        XCTAssertFalse(second.isVisible)
    }

    @MainActor func testBlankImageReturnsToIdleWithMessageAndNoResultWindow() async throws {
        let editor = try editor()
        await recognize(editor)
        XCTAssertEqual(editor.message, "Текст не найден — выдели область крупнее")
        XCTAssertNil(editor.textWindow)
    }
}
