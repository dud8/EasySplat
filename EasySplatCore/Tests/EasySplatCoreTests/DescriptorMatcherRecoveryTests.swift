#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class DescriptorMatcherRecoveryTests: XCTestCase {
    func testFaissMatcherSignalSelectsExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "sequential_matcher",
            exitCode: SIGSEGV,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            ),
            .faissCrash
        )
    }

    func testCancellationSignalsDoNotSelectExactRecovery() {
        for signal in [Int32(SIGTERM), Int32(SIGKILL)] {
            let error = ColmapRunnerError.failed(
                command: "sequential_matcher",
                exitCode: signal,
                terminationReason: .uncaughtSignal,
                stdoutTail: "",
                stderrTail: "terminated"
            )

            XCTAssertNil(
                DescriptorMatcherRecoveryPolicy.reason(
                    for: error,
                    currentMatcher: .faiss
                ),
                "signal \(signal) must remain a cancellation instead of starting recovery"
            )
        }
    }

    func testFaissUnsupportedOperationSelectsExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "Feature descriptor index not implemented"
        )

        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            ),
            .faissUnsupportedOperation
        )
    }

    func testGenericUnsupportedOperationDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "filesystem returned unsupported operation"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            )
        )
    }

    func testGenericFailureDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "exhaustive_matcher",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "database is locked"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            )
        )
    }

    func testNonMatcherCrashDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "feature_extractor",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            )
        )
    }

    func testExactMatcherFailureCannotRetryExact() {
        let error = ColmapRunnerError.failed(
            command: "sequential_matcher",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .exact
            )
        )
    }

    func testGeometryRejectionSelectsExactOnlyAfterFaissRetries() {
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: false
            )
        )
        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: true
            ),
            .faissGeometryRejectedAfterRetries
        )
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .exact,
                exhaustedFaissRetries: true
            )
        )
    }
}
#endif
