#if DEBUG
import XCTest
@testable import EasySplatCore

final class Utf8StreamDecoderTests: XCTestCase {
    func testDecoderBuffersIncompleteLeadingByte() {
        var decoder = TestUtf8StreamDecoder()

        let expected = String(decoding: [0xE2, 0x82, 0xAC], as: UTF8.self)
        XCTAssertEqual(decoder.decode([0xE2]), "")
        XCTAssertEqual(decoder.decode([0x82]), "")
        XCTAssertEqual(decoder.decode([0xAC]), expected)
        XCTAssertNil(decoder.flush())
    }

    func testDecoderHandlesSplitEmoji() {
        var decoder = TestUtf8StreamDecoder()

        let expected = String(decoding: [0xF0, 0x9F, 0x98, 0x80], as: UTF8.self)
        XCTAssertEqual(decoder.decode([0xF0, 0x9F]), "")
        XCTAssertEqual(decoder.decode([0x98, 0x80]), expected)
        XCTAssertNil(decoder.flush())
    }
}
#endif
