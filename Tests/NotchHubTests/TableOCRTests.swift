import XCTest
import AppKit
@testable import NotchHub

final class TableOCRTests: XCTestCase {
    private func region(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.12) -> TableTextRegion {
        TableTextRegion(text: text, bounds: CGRect(x: x, y: y, width: width, height: 0.035))
    }
    func testReconstructionKeepsMissingCellsAndReadingOrder() throws {
        let table = try TableGeometry.reconstruct([
            region("B", x: 0.4, y: 0.9), region("A", x: 0.1, y: 0.9), region("C", x: 0.7, y: 0.9),
            region("1", x: 0.1, y: 0.8), region("3", x: 0.7, y: 0.8),
            region("5", x: 0.4, y: 0.7), region("6", x: 0.7, y: 0.7)
        ])
        XCTAssertEqual(table.cells, [["A", "B", "C"], ["1", "", "3"], ["", "5", "6"]])
    }
    func testRightAlignedValuesShareColumn() throws {
        let table = try TableGeometry.reconstruct([
            region("Name", x: 0.1, y: 0.9), region("100", x: 0.6, y: 0.9, width: 0.1),
            region("Other", x: 0.1, y: 0.8), region("1", x: 0.67, y: 0.8, width: 0.03)
        ])
        XCTAssertEqual(table.cells, [["Name", "100"], ["Other", "1"]])
    }
    func testSingleColumnProseIsNotInventedIntoTable() {
        XCTAssertThrowsError(try TableGeometry.reconstruct([region("One line", x: 0.1, y: 0.9), region("Another line", x: 0.1, y: 0.8)]))
        XCTAssertThrowsError(try TableGeometry.reconstruct([]))
    }
    func testAmbiguousColumnMatchesFailInsteadOfCombining() {
        XCTAssertThrowsError(try TableGeometry.reconstruct([
            region("a", x: 0.1, y: 0.9, width: 0.1), region("b", x: 0.4, y: 0.9, width: 0.1),
            region("overlap", x: 0.1, y: 0.8, width: 0.4), region("c", x: 0.7, y: 0.8)
        ]))
    }
    func testDelimitedFormatsPreserveTabsNewlinesQuotesUnicodeAndEmptyCells() throws {
        let table = try RecognizedTable(cells: [["Имя", "", "a,b"], ["a\tb", "a\"b", "a\nb"]])
        XCTAssertEqual(table.delimited(by: ","), "Имя,,\"a,b\"\r\na\tb,\"a\"\"b\",\"a\nb\"")
        XCTAssertEqual(table.delimited(by: "\t"), "Имя\t\ta,b\r\n\"a\tb\"\t\"a\"\"b\"\t\"a\nb\"")
    }
    func testBoundsAndCellLimits() {
        XCTAssertThrowsError(try RecognizedTable(cells: [["a"], ["a", "b"]]))
        XCTAssertThrowsError(try RecognizedTable(cells: Array(repeating: ["a"], count: 201)))
        XCTAssertThrowsError(try RecognizedTable(cells: [Array(repeating: "a", count: 31)]))
        XCTAssertThrowsError(try RecognizedTable(cells: Array(repeating: Array(repeating: "", count: 30), count: 200)))
        XCTAssertThrowsError(try TableGeometry.reconstruct([region("a", x: .nan, y: 0.1)]))
    }
    @MainActor private func image() throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.cgImage)
    }
    @MainActor func testCancellationDiscardsInFlightTableAndCompletion() async throws {
        let began = expectation(description: "recognizer began")
        let finished = expectation(description: "recognizer finished")
        let gate = DispatchSemaphore(value: 0)
        let controller = TableOCRController(recognizer: { _ in
            began.fulfill(); _ = gate.wait(timeout: .now() + 5); finished.fulfill()
            return [self.region("A", x: 0.1, y: 0.9), self.region("B", x: 0.5, y: 0.9), self.region("1", x: 0.1, y: 0.7), self.region("2", x: 0.5, y: 0.7)]
        })
        var delivered = false
        controller.recognize(image: try image()) { _ in delivered = true }
        await fulfillment(of: [began], timeout: 2)
        controller.cancel(); gate.signal()
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()
        XCTAssertFalse(controller.busy); XCTAssertNil(controller.table); XCTAssertFalse(delivered)
    }
    @MainActor func testRecognitionPublishesTableWithoutTouchingClipboard() async throws {
        let controller = TableOCRController(recognizer: { _ in
            [self.region("A", x: 0.1, y: 0.9), self.region("B", x: 0.5, y: 0.9), self.region("1", x: 0.1, y: 0.7), self.region("2", x: 0.5, y: 0.7)]
        })
        let completed = expectation(description: "complete")
        let count = NSPasteboard.general.changeCount
        controller.recognize(image: try image()) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(controller.busy); XCTAssertEqual(controller.table?.cells, [["A", "B"], ["1", "2"]])
        XCTAssertEqual(NSPasteboard.general.changeCount, count)
    }
    @MainActor func testRealVisionRecognizesSyntheticMultiwordAndRightAlignedTable() throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 420, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1200, height: 420).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]
        let rows = [["Item name", "Units", "Total"], ["Green tea", "12", "1200"], ["Black coffee", "2", "90"]]
        for (row, cells) in rows.enumerated() {
            let y = CGFloat(310 - row * 110)
            (cells[0] as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: attributes)
            for column in 1...2 {
                let text = cells[column] as NSString
                let right = CGFloat(column == 1 ? 760 : 1130)
                text.draw(at: CGPoint(x: right - text.size(withAttributes: attributes).width, y: y), withAttributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let regions = try TableOCRController.regions(in: XCTUnwrap(bitmap.cgImage))
        let table = try TableGeometry.reconstruct(regions)
        XCTAssertEqual(table.cells, rows, "Vision regions: \(regions.map { ($0.text, $0.bounds) })")
    }

    func testCenteredHeadersUseStableBodyColumnsInsteadOfPhantomColumns() throws {
        let table = try TableGeometry.reconstruct([
            region("A", x: 0.2, y: 0.9, width: 0.1), region("B", x: 0.7, y: 0.9, width: 0.1),
            region("1", x: 0.1, y: 0.8, width: 0.1), region("2", x: 0.6, y: 0.8, width: 0.1),
            region("3", x: 0.1, y: 0.7, width: 0.1), region("4", x: 0.6, y: 0.7, width: 0.1)
        ])
        XCTAssertEqual(table.cells, [["A", "B"], ["1", "2"], ["3", "4"]])
    }
    func testAmbiguousHeaderBetweenStableColumnsFails() {
        XCTAssertThrowsError(try TableGeometry.reconstruct([
            region("Header", x: 0.35, y: 0.9, width: 0.1), region("Other", x: 0.8, y: 0.9, width: 0.1),
            region("1", x: 0.1, y: 0.8, width: 0.1), region("2", x: 0.6, y: 0.8, width: 0.1),
            region("3", x: 0.1, y: 0.7, width: 0.1), region("4", x: 0.6, y: 0.7, width: 0.1)
        ]))
    }
    @MainActor func testDisabledTableActionKeepsCaptureOpenAndDoesNotDeliver() async throws {
        _ = NSApplication.shared
        let captured = expectation(description: "capture active")
        var enabled = false
        var deliveries = 0
        var finishes = 0
        let controller = ScreenshotController(capture: { _ in [] }, present: { _ in captured.fulfill() }, finished: { finishes += 1 })
        controller.canRecognizeTable = { enabled }
        controller.recognizeTable = { _ in deliveries += 1 }
        let image = try image()
        let editor = ScreenshotEditor(image: image, size: CGSize(width: 40, height: 40))
        controller.configureTableRecognition(editor)
        XCTAssertNil(editor.recognizeTable)
        enabled = true; controller.configureTableRecognition(editor)
        XCTAssertNotNil(editor.recognizeTable)
        controller.start()
        await fulfillment(of: [captured], timeout: 2)
        enabled = false; editor.recognizeTable?(image)
        XCTAssertTrue(controller.active); XCTAssertEqual(deliveries, 0); XCTAssertEqual(finishes, 0)
        enabled = true; editor.recognizeTable?(image)
        XCTAssertFalse(controller.active); XCTAssertEqual(deliveries, 1); XCTAssertEqual(finishes, 1)
    }

}
