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
}
