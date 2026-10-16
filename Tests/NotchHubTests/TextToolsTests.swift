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
    func testJSONPreservesDataAndRejectsInvalidInput() throws {
        let result = try TextTransform.formatJSON.apply(to: "{\"z\":[1,true,null],\"a\":\"текст\"}")
        XCTAssertTrue(result.contains("\n"))
        let decoded = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data("{\"z\":[1,true,null],\"a\":\"текст\"}".utf8)) as? NSDictionary
        XCTAssertEqual(decoded, original)
        XCTAssertThrowsError(try TextTransform.formatJSON.apply(to: "{not json}"))
        XCTAssertEqual(try TextTransform.formatJSON.apply(to: "true"), "true")
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
