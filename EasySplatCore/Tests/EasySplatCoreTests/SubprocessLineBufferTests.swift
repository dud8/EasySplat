#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class SubprocessLineBufferTests: XCTestCase {
    func testBufferEmitsCompleteLinesAcrossChunks() {
        let buffer = SubprocessLineBuffer()
        XCTAssertEqual(buffer.append("hello\nwor"), ["hello"])
        XCTAssertEqual(buffer.append("ld\n"), ["world"])
        XCTAssertNil(buffer.flush())
    }

    func testBufferSplitsOnCarriageReturn() {
        let buffer = SubprocessLineBuffer()
        XCTAssertEqual(buffer.append("a\rb\r"), ["a", "b"])
        XCTAssertNil(buffer.flush())
    }

    func testBufferTreatsCRLFAsSingleDelimiter() {
        let buffer = SubprocessLineBuffer()
        XCTAssertEqual(buffer.append("a\r\nb\r\n"), ["a", "b"])
        XCTAssertNil(buffer.flush())
    }

    func testBufferFlushesRemainderWithoutTrailingNewline() {
        let buffer = SubprocessLineBuffer()
        XCTAssertEqual(buffer.append("partial"), [])
        XCTAssertEqual(buffer.flush(), "partial")
        XCTAssertNil(buffer.flush())
    }
}
#endif
