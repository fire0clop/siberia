import XCTest
@testable import Siberia

final class MarkdownParserTests: XCTestCase {

	func testBold() {
		let (text, ents) = MarkdownParser.parse("привет **мир**!")
		XCTAssertEqual(text, "привет мир!")
		XCTAssertEqual(ents, [MessageEntity(type: "bold", offset: 7, length: 3)])
	}

	func testItalicBothMarkers() {
		let (t1, e1) = MarkdownParser.parse("*курсив*")
		XCTAssertEqual(t1, "курсив")
		XCTAssertEqual(e1.first?.type, "italic")

		let (t2, e2) = MarkdownParser.parse("_курсив_")
		XCTAssertEqual(t2, "курсив")
		XCTAssertEqual(e2.first?.type, "italic")
	}

	func testSpoilerAndStrike() {
		let (text, ents) = MarkdownParser.parse("~~зачёркнуто~~ и ||секрет||")
		XCTAssertEqual(text, "зачёркнуто и секрет")
		XCTAssertEqual(ents.count, 2)
		XCTAssertEqual(ents[0], MessageEntity(type: "strikethrough", offset: 0, length: 10))
		XCTAssertEqual(ents[1], MessageEntity(type: "spoiler", offset: 13, length: 6))
	}

	func testCodeAndPre() {
		let (text, ents) = MarkdownParser.parse("код `let x = 1` и ```блок```")
		XCTAssertEqual(text, "код let x = 1 и блок")
		XCTAssertEqual(ents[0].type, "code")
		XCTAssertEqual(ents[1].type, "pre")
	}

	func testUnpairedMarkersStayLiteral() {
		let (text, ents) = MarkdownParser.parse("2 * 2 = 4, а _вот")
		XCTAssertEqual(text, "2 * 2 = 4, а _вот")
		XCTAssertTrue(ents.isEmpty)
	}

	func testEmptyMarkupIsLiteral() {
		let (text, ents) = MarkdownParser.parse("****")
		XCTAssertEqual(text, "****")
		XCTAssertTrue(ents.isEmpty)
	}

	func testUTF16OffsetsWithEmoji() {
		// 🔥 = 2 UTF-16 юнита: bold начинается с offset 3
		let (text, ents) = MarkdownParser.parse("🔥 **да**")
		XCTAssertEqual(text, "🔥 да")
		XCTAssertEqual(ents, [MessageEntity(type: "bold", offset: 3, length: 2)])
	}

	func testPlainTextUntouched() {
		let (text, ents) = MarkdownParser.parse("просто текст без разметки")
		XCTAssertEqual(text, "просто текст без разметки")
		XCTAssertTrue(ents.isEmpty)
	}

	func testMultipleEntitiesOffsets() {
		let (text, ents) = MarkdownParser.parse("**a** b *c*")
		XCTAssertEqual(text, "a b c")
		XCTAssertEqual(ents, [
			MessageEntity(type: "bold", offset: 0, length: 1),
			MessageEntity(type: "italic", offset: 4, length: 1),
		])
	}
}
