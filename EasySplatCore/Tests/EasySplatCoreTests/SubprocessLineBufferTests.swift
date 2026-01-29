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

    func testBufferFlushesRemainderWithoutTrailingNewline() {
        let buffer = SubprocessLineBuffer()
        XCTAssertEqual(buffer.append("partial"), [])
        XCTAssertEqual(buffer.flush(), "partial")
        XCTAssertNil(buffer.flush())
    }
}
#endif

