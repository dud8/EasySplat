import XCTest
@testable import EasySplatCore

final class TextTailsTests: XCTestCase {
    func testTailLinesLimitZero() {
        let text = "a\nb\nc"
        XCTAssertEqual(TextTails.tailLines(text, limit: 0), "")
    }

    func testTailLinesShorterThanLimit() {
        let text = "a\nb\nc"
        XCTAssertEqual(TextTails.tailLines(text, limit: 5), text)
    }

    func testTailLinesPreservesEmptyLines() {
        let text = "a\n\nb\n"
        let tail = TextTails.tailLines(text, limit: 2)
        XCTAssertEqual(tail, "b\n")
    }

    func testTailLinesSplitsCarriageReturnProgress() {
        let text = "start\rmiddle\rend"
        let tail = TextTails.tailLines(text, limit: 2)
        XCTAssertEqual(tail, "middle\nend")
    }

    func testTailLinesAppliesByteLimit() {
        let text = String(repeating: "a", count: 200)
        let tail = TextTails.tailLines(text, limit: 10, byteLimit: 40)
        XCTAssertLessThanOrEqual(tail.utf8.count, 40)
        XCTAssertTrue(tail.allSatisfy { $0 == "a" })
    }

    func testTailLinesByteLimitKeepsLargestValidMultibyteSuffix() {
        let glyph = "\u{1F600}"
        let text = glyph + glyph
        let tail = TextTails.tailLines(text, limit: 1, byteLimit: 5)
        XCTAssertEqual(tail, glyph)
        XCTAssertLessThanOrEqual(tail.utf8.count, 5)
    }
}
