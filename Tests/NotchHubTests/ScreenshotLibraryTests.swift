import XCTest
import AppKit
@testable import NotchHub

final class ScreenshotLibraryTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func editor() throws -> ScreenshotEditor {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let editor = ScreenshotEditor(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 100, height: 50))
        editor.selection = CGRect(x: 10, y: 5, width: 40, height: 25)
        return editor
    }
    func testCroppedBaseBurnsRedactionsAndRetainsEditableShiftedAnnotations() throws {
        let path = root(); defer { try? FileManager.default.removeItem(at: path) }
        let library = ScreenshotLibrary(root: path), original = try editor()
        original.annotations = [
            ScreenshotAnnotation(tool: .redact, points: [CGPoint(x: 15, y: 10), CGPoint(x: 20, y: 15)], color: .red, width: 3),
            ScreenshotAnnotation(tool: .line, points: [CGPoint(x: 25, y: 20), CGPoint(x: 30, y: 20)], color: .blue, width: 2)
        ]
        let entry = try library.save(original)
        XCTAssertEqual(original.archiveID, entry.id)
        XCTAssertEqual(entry.size, CGSize(width: 40, height: 25))
        let stored = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: library.url(for: entry))))
        XCTAssertEqual(stored.pixelsWide, 80); XCTAssertEqual(stored.pixelsHigh, 50)
        XCTAssertLessThan(try XCTUnwrap(stored.colorAt(x: 15, y: 15)?.usingColorSpace(.deviceRGB)).redComponent, 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(stored.colorAt(x: 35, y: 30)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        let reopened = try library.editor(for: entry)
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertEqual(reopened.annotations.first?.tool, .line)
        XCTAssertEqual(reopened.annotations.first?.points.first, CGPoint(x: 15, y: 15))
        XCTAssertEqual(reopened.archiveID, entry.id)
        XCTAssertEqual(reopened.selection, CGRect(origin: .zero, size: entry.size))
        XCTAssertEqual(ScreenshotLibrary(root: path).entries, library.entries)
        let mode = try FileManager.default.attributesOfItem(atPath: library.url(for: entry).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
    }
    func testEditingUpdatesSameEntryAndEvictionRemovesAssets() throws {
        let path = root(); defer { try? FileManager.default.removeItem(at: path) }
        let library = ScreenshotLibrary(root: path)
        let first = try library.save(editor())
        let reopened = try library.editor(for: first)
        let updated = try library.save(reopened)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: first).path))
        for _ in 0..<22 { try library.save(editor()) }
        XCTAssertEqual(library.entries.count, 20)
        XCTAssertFalse(library.entries.contains { $0.id == first.id })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.count, 20)
        XCTAssertLessThanOrEqual(library.entries.reduce(0) { $0 + $1.byteCount }, ScreenshotLibrary.byteLimit)
        let removed = try XCTUnwrap(library.entries.first)
        library.remove(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: removed).path))
        XCTAssertEqual(ScreenshotLibrary(root: path).entries.count, 19)
    }
    func testInvalidCropAndCorruptManifestDoNotOverwriteExistingData() throws {
        let path = root(); defer { try? FileManager.default.removeItem(at: path) }
        let library = ScreenshotLibrary(root: path), invalid = try editor()
        invalid.selection = .zero
        XCTAssertThrowsError(try library.save(invalid))
        let manifest = path.appendingPathComponent("history.json"), bad = Data("broken".utf8)
        try bad.write(to: manifest)
        let protected = ScreenshotLibrary(root: path)
        XCTAssertNotNil(protected.message)
        XCTAssertThrowsError(try protected.save(editor()))
        XCTAssertEqual(try Data(contentsOf: manifest), bad)
    }
    @MainActor func testReopenSkipsCaptureAndArchivesOnlyWhenCallbackEnabled() throws {
        let original = try editor()
        var captures = 0, archived = 0, finished = 0
        let controller = ScreenshotController(capture: { _ in captures += 1; return [] }, finished: { finished += 1 })
        controller.reopen(original)
        XCTAssertTrue(controller.active)
        controller.finish()
        XCTAssertEqual(archived, 0); XCTAssertEqual(captures, 0)
        controller.archiveEditor = { editor in XCTAssertTrue(editor.valid); archived += 1 }
        controller.reopen(original)
        controller.finish(); controller.finish()
        XCTAssertEqual(archived, 1); XCTAssertEqual(finished, 2)
        XCTAssertFalse(controller.active)
    }
}
