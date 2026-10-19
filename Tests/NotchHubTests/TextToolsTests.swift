import XCTest
@testable import NotchHub

final class TextToolsTests: XCTestCase {
    func testKeyboardLayoutRoundTripPreservesWhitespaceAndEmoji() throws {
        XCTAssertEqual(try TextTransform.fixLayout.apply(to: "Ghbdtn, vbh! 😀\n"), "Приветб мир! 😀\n")
        XCTAssertEqual(try TextTransform.fixLayout.apply(to: "руддщ цщкдв 😀"), "hello world 😀")
        XCTAssertEqual(try TextTransform.fixLayout.apply(to: ""), "")
    }
    func testCaseAndPlainTextPreserveUnicode() throws {
        XCTAssertEqual(try TextTransform.upper.apply(to: "Привет world 😀"), "ПРИВЕТ WORLD 😀")
        XCTAssertEqual(try TextTransform.lower.apply(to: "HELLO МИР"), "hello мир")
        XCTAssertEqual(try TextTransform.titleCase.apply(to: "hello world"), "Hello World")
        XCTAssertEqual(try TextTransform.plainText.apply(to: "a\t b\n😀"), "a\t b\n😀")
    }
    func testSentenceCasePreservesUnicodeAndSentenceBoundaries() throws {
        XCTAssertEqual(try TextTransform.sentenceCase.apply(to: "ПРИВЕТ, МИР! HELLO 😀. ЕЩЁ? ДА\nНОВАЯ СТРОКА"), "Привет, мир! Hello 😀. Ещё? Да\nНовая строка")
    }
    func testSelectionUsesUTF16AndRejectsBrokenGraphemes() throws {
        let text = "😀 Straße конец"
        let range = (text as NSString).range(of: "Straße")
        let result = try TextSelectionTransform.apply(.upper, to: text, range: range)
        XCTAssertEqual(result.text, "STRASSE")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 7))
        XCTAssertEqual((text as NSString).replacingCharacters(in: range, with: result.text), "😀 STRASSE конец")
        XCTAssertThrowsError(try TextSelectionTransform.apply(.upper, to: text, range: NSRange(location: 1, length: 1)))
        XCTAssertThrowsError(try TextSelectionTransform.apply(.upper, to: text, range: NSRange(location: 900, length: 1)))
        let jsonSelection = try TextSelectionTransform.apply(.formatJSON, to: text, range: range)
        let selectedObject = try JSONSerialization.jsonObject(with: Data(jsonSelection.text.utf8)) as? [String: String]
        XCTAssertEqual(selectedObject, ["text": "Straße"])
        XCTAssertEqual(jsonSelection.selection.location, range.location)
        XCTAssertEqual(jsonSelection.selection.length, jsonSelection.text.utf16.count)
    }
    func testJSONPreservesDataAndValidFragments() throws {
        let result = try TextTransform.formatJSON.apply(to: "{\"z\":[1,true,null],\"a\":\"текст\"}")
        XCTAssertTrue(result.contains("\n"))
        let decoded = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data("{\"z\":[1,true,null],\"a\":\"текст\"}".utf8)) as? NSDictionary
        XCTAssertEqual(decoded, original)
        for fragment in ["true", "null", "123.5", "\"hello\""] {
            XCTAssertEqual(try TextTransform.formatJSON.apply(to: fragment), fragment)
        }
    }
    func testJSON5NormalizesNestedObjectsCommentsAndTrailingCommas() throws {
        let input = """
        // configuration
        { name: 'NotchHub', settings: { enabled: true, }, items: [1, 'текст 😀', { value: null, },], }
        """
        let output = try TextTransform.formatJSON.apply(to: input)
        let decoded = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data("{\"name\":\"NotchHub\",\"settings\":{\"enabled\":true},\"items\":[1,\"текст 😀\",{\"value\":null}]}".utf8)) as? NSDictionary
        XCTAssertEqual(decoded, expected)
        XCTAssertTrue(output.contains("\n"))
        XCTAssertFalse(output.contains("// configuration"))
    }
    func testNativeJSON5AcceptsUnbracedDictionary() throws {
        let output = try TextTransform.formatJSON.apply(to: "name: 'Аня', count: 2")
        let decoded = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, ["name": "Аня", "count": 2] as NSDictionary)
    }
    func testArbitraryTextBecomesJSONObjectWithoutLosingAnyCharacters() throws {
        for input in ["", "  \n\t", "hello world", "{not json}", "{\"a\":1 \"b\":2}", "  \"цитата\"\n\t😀 Straße\r\n", "NaN", "Infinity", "-Infinity", "{value: NaN}", "[Infinity]"] {
            let output = try TextTransform.formatJSON.apply(to: input)
            let decoded = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String]
            XCTAssertEqual(decoded, ["text": input], "Input must be preserved: \(input)")
        }
    }
    func testURLRemovesOnlyTrackingAndKeepsEncodingFragmentAndRepeatedKeys() throws {
        let original = "https://example.com/a%2Fb?token=a%2Bb&x=1&utm_source=mail&x=2&gclid=123#part"
        XCTAssertEqual(try TextTransform.cleanURL.apply(to: original), "https://example.com/a%2Fb?token=a%2Bb&x=1&x=2#part")
        XCTAssertEqual(try TextTransform.cleanURL.apply(to: "https://example.com/?UTM_source=x#ok"), "https://example.com/#ok")
        for unchanged in ["not a URL", "mailto:a@example.com?utm_source=x", "https://example.com/?signature=a%2fb%2B&x=1", "https://example.com/?product=utm_source", "http://", "https://example.com/%ZZ?utm_source=x", "https://example.com/a b?utm_source=x"] {
            XCTAssertEqual(try TextTransform.cleanURL.apply(to: unchanged), unchanged)
        }
    }
}
