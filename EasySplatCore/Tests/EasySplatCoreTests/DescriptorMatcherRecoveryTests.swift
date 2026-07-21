#if canImport(XCTest)
import Foundation
import XCTest
import SQLite3
@testable import EasySplatCore

final class DescriptorMatcherRecoveryTests: XCTestCase {
    func testFaissMatcherSignalSelectsExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: SIGSEGV,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss,
                scheduledPairCount: 1
            ),
            .faissCrash
        )
    }

    func testCancellationSignalsDoNotSelectExactRecovery() {
        for signal in [Int32(SIGTERM), Int32(SIGKILL)] {
            let error = ColmapRunnerError.failed(
                command: "matches_importer",
                exitCode: signal,
                terminationReason: .uncaughtSignal,
                stdoutTail: "",
                stderrTail: "terminated"
            )

            XCTAssertNil(
                DescriptorMatcherRecoveryPolicy.reason(
                    for: error,
                    currentMatcher: .faiss,
                    scheduledPairCount: 1
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
                currentMatcher: .faiss,
                scheduledPairCount: 1
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
                currentMatcher: .faiss,
                scheduledPairCount: 1
            )
        )
    }

    func testGenericFailureDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "database is locked"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss,
                scheduledPairCount: 1
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
                currentMatcher: .faiss,
                scheduledPairCount: 1
            )
        )
    }

    func testExactMatcherFailureCannotRetryExact() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .exact,
                scheduledPairCount: 1
            )
        )
    }

    func testGeometryRejectionSelectsExactOnlyAfterFaissRetries() {
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: false,
                scheduledPairCount: 1
            )
        )
        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: true,
                scheduledPairCount: 1
            ),
            .faissGeometryRejectedAfterRetries
        )
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .exact,
                exhaustedFaissRetries: true,
                scheduledPairCount: 1
            )
        )
    }

    func testExactRecoveryAcceptsAtMost256ScheduledPairs() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: SIGSEGV,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss,
                scheduledPairCount: 256
            ),
            .faissCrash
        )
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss,
                scheduledPairCount: 257
            )
        )
        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: true,
                scheduledPairCount: 256
            ),
            .faissGeometryRejectedAfterRetries
        )
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: true,
                scheduledPairCount: 257
            )
        )
    }

    func testUnorderedExhaustiveSchedulesAt60And250ViewsCannotUseExactRecovery() throws {
        for imageCount in [60, 250] {
            let imageNames = (0..<imageCount).map { String(format: "frame-%03d.jpg", $0) }
            let plan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
            XCTAssertFalse(
                DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                    scheduledPairCount: plan.pairs.count
                ),
                "an exhaustive (imageCount)-view schedule must remain FAISS-only"
            )
        }
    }

}
#endif
