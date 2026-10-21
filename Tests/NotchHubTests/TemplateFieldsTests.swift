import XCTest
import AppKit
@testable import NotchHub

final class TemplateFieldsTests: XCTestCase {
    func testPlainTemplatesPreserveAllCharacters() throws {
        let text = "  Привет 😀\n\t{JSON: 'value'}\r\nC:\\Users\\path"
        let fields = try TemplateFields(text)
        XCTAssertTrue(fields.names.isEmpty)
        XCTAssertEqual(try fields.render(values: [:]), text)
    }
    func testFieldsStayOrderedAndRepeatOneValueWithoutReinterpretingIt() throws {
        let fields = try TemplateFields("{{ Имя }} / {{Номер задачи}} / {{Имя}}")
        XCTAssertEqual(fields.names, ["Имя", "Номер задачи"])
        XCTAssertEqual(try fields.render(values: ["Имя": "{{literal}} 😀", "Номер задачи": "ECOSYS-42"]), "{{literal}} 😀 / ECOSYS-42 / {{literal}} 😀")
    }
    func testLiteralBracesAndBackslashes() throws {
        let fields = try TemplateFields("\\{{буквально}} · {{Имя}} · C:\\temp")
        XCTAssertEqual(fields.names, ["Имя"])
        XCTAssertEqual(try fields.render(values: ["Имя": "Аня"]), "{{буквально}} · Аня · C:\\temp")
    }
    func testInvalidSyntaxAndTooManyFieldsFailClearly() throws {
        for text in ["{{", "{{}}", "{{   }}", "{{nested {{x}}", "{{first\nlast}}", "{{" + String(repeating: "x", count: 81) + "}}"] {
            XCTAssertThrowsError(try TemplateFields(text), text)
        }
        let fields = (1...32).map { "{{field\($0)}}" }.joined()
        XCTAssertEqual(try TemplateFields(fields).names.count, 32)
        XCTAssertThrowsError(try TemplateFields(fields + "{{field33}}"))
    }
    func testPreviewAllowsIncompleteButCopyRequiresAllValues() throws {
        let fields = try TemplateFields("Привет, {{Имя}}. Срок: {{Дата}}")
        XCTAssertEqual(try fields.render(values: ["Имя": "Аня"], requireValues: false), "Привет, Аня. Срок: ")
        XCTAssertThrowsError(try fields.render(values: ["Имя": "Аня"]))
        XCTAssertThrowsError(try fields.render(values: ["Имя": "Аня", "Дата": " \n"]))
        XCTAssertEqual(try fields.render(values: ["Имя": "Аня", "Дата": "  завтра  "]), "Привет, Аня. Срок:   завтра  ")
    }
    func testRepeatedValuesCannotBypassOutputLimit() throws {
        let fields = try TemplateFields("{{x}}{{x}}")
        XCTAssertThrowsError(try fields.render(values: ["x": String(repeating: "a", count: HubStore.maxBytes / 2 + 1)]))
    }
    func testOldTemplateArchiveDecodesWithoutMigration() throws {
        let data = Data("{\"id\":\"12345678-1234-1234-1234-123456789ABC\",\"title\":\"Ответ\",\"text\":\"Привет, {{Имя}}\"}".utf8)
        let template = try JSONDecoder().decode(TextTemplate.self, from: data)
        XCTAssertEqual(try TemplateFields(template.text).render(values: ["Имя": "мир"]), "Привет, мир")
    }
}

final class FormattingRestorationTests: XCTestCase {
    func testSnapshotRestoresExactJSON5AndArbitrarySourceIncludingWhitespace() throws {
        for original in [" // keep comment\n{b: 'two', a: 1,}\n", "  строка 😀\t\r\n", "{\"z\":1,\"a\":2}"] {
            let range = NSRange(location: 0, length: original.utf16.count)
            let snapshot = FormattingSnapshot(text: original, selection: range)
            let formatted = try TextTransform.formatJSON.apply(to: original)
            XCTAssertNotEqual(formatted, original)
            XCTAssertEqual(snapshot.text, original)
            XCTAssertEqual(snapshot.selection, range)
        }
    }
    func testSnapshotValidatesUTF16Selection() {
        let text = "😀 Привет"
        XCTAssertEqual(FormattingSnapshot(text: text, selection: NSRange(location: 3, length: 6)).selection, NSRange(location: 3, length: 6))
        XCTAssertEqual(FormattingSnapshot(text: text, selection: NSRange(location: 500, length: 1)).selection, NSRange(location: 0, length: 0))
    }
    @MainActor func testNativeUndoRedoAndExactRestoreAfterPartialJSONFormatting() throws {
        _ = NSApplication.shared
        let original = "😀 before {b: 2, a: 1} after\r\n"
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        editor.isRichText = false; editor.allowsUndo = true; editor.string = original
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        let selected = (original as NSString).range(of: "{b: 2, a: 1}")
        let transformed = try TextSelectionTransform.apply(.formatJSON, to: original, range: selected)
        let snapshot = FormattingSnapshot(text: original, selection: selected)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        XCTAssertTrue(SelectionTextEditor.replace(in: editor, range: selected, text: transformed.text, selection: transformed.selection))
        undo.endUndoGrouping()
        let formatted = editor.string
        XCTAssertNotEqual(formatted, original)
        XCTAssertTrue(undo.canUndo)
        undo.undo(); XCTAssertEqual(editor.string, original)
        undo.redo(); XCTAssertEqual(editor.string, formatted)
        undo.beginUndoGrouping()
        XCTAssertTrue(SelectionTextEditor.replace(in: editor, range: NSRange(location: 0, length: editor.string.utf16.count), text: snapshot.text, selection: snapshot.selection))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), selected)
        undo.undo(); XCTAssertEqual(editor.string, formatted)
    }
}
