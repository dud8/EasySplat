import XCTest
@testable import EasySplatCore

final class SubprocessFailureTests: XCTestCase {
    func testDescriptionsIncludeDetails() {
        let failure = SubprocessFailure(
            tool: "colmap",
            command: "mapper",
            exitCode: 42,
            terminationReason: .exit,
            stdoutTail: "out",
            stderrTail: "err"
        )
        XCTAssertTrue(failure.errorDescription?.contains("colmap failed") ?? false)
        XCTAssertTrue(failure.debugDescription.contains("Exit code: 42"))
        XCTAssertTrue(failure.debugDescription.contains("Stdout tail:"))
        XCTAssertTrue(failure.debugDescription.contains("Stderr tail:"))
    }
}
