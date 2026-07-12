import XCTest
@testable import EasySplatApp
import EasySplatCore

@MainActor
final class ProcessingTimingTextTests: XCTestCase {
    func testEveryPipelineStageMapsToOneOfFourUserPhases() {
        let expected: [(PipelineStage, ProcessingPhase)] = [
            (.importInput, .prepare),
            (.extractFrames, .prepare),
            (.selectFrames, .prepare),
            (.sfmFeatures, .reconstruct),
            (.sfmMatching, .reconstruct),
            (.sfmMapping, .reconstruct),
            (.trainSplat, .train),
            (.exportSplat, .finish),
            (.done, .finish)
        ]

        XCTAssertEqual(expected.count, PipelineStage.allCases.count)
        for (stage, phase) in expected {
            XCTAssertEqual(ProcessingPhase.forStage(stage), phase, "Unexpected phase for \(stage)")
        }
    }

    func testPhaseHeadingsAreShortAndUserFacing() {
        XCTAssertEqual(ProcessingPhase.prepare.heading, "Step 1 of 4 · Preparing input")
        XCTAssertEqual(ProcessingPhase.reconstruct.heading, "Step 2 of 4 · Reconstructing scene")
        XCTAssertEqual(ProcessingPhase.train.heading, "Step 3 of 4 · Training splat")
        XCTAssertEqual(ProcessingPhase.finish.heading, "Step 4 of 4 · Finishing")
    }

    func testVisibleProgressNeverPresentsInternalStageFractionsAsPhaseProgress() {
        XCTAssertNil(ProcessingView.phaseProgress(stage: .importInput, progress: 0.8))
        XCTAssertNil(ProcessingView.phaseProgress(stage: .extractFrames, progress: 0.2))
        XCTAssertNil(ProcessingView.phaseProgress(stage: .sfmFeatures, progress: 0.9))
        XCTAssertNil(ProcessingView.phaseProgress(stage: .sfmMapping, progress: 0.1))
        XCTAssertEqual(ProcessingView.phaseProgress(stage: .trainSplat, progress: 0.4), 0.4)
        XCTAssertEqual(ProcessingView.phaseProgress(stage: .exportSplat, progress: 0.7), 0.7)
        XCTAssertEqual(ProcessingView.phaseProgress(stage: .done, progress: 1), 1)
    }

    func testTryAgainSupportsDurableProjectsAndPreProjectSetupFailures() {
        XCTAssertTrue(ProcessingView.canTryAgain(projectExists: true, pendingInputExists: false))
        XCTAssertTrue(ProcessingView.canTryAgain(projectExists: false, pendingInputExists: true))
        XCTAssertFalse(ProcessingView.canTryAgain(projectExists: false, pendingInputExists: false))
    }

    func testValidationFailuresPresentSpecificRecoveryActions() {
        XCTAssertEqual(ProcessingView.failureActionTitle(recovery: .useUnordered), "Use Unordered")
        XCTAssertEqual(ProcessingView.failureActionTitle(recovery: .useFast), "Use Fast")
        XCTAssertEqual(ProcessingView.failureActionTitle(recovery: .useBalanced), "Use Balanced")
        XCTAssertEqual(ProcessingView.failureActionTitle(recovery: nil), "Try Again")
    }

    func testFailureMessageShowsOnlyTheTrimmedUserFacingError() {
        XCTAssertEqual(
            ProcessingView.failureMessage("  The capture could not be connected. Try again with more overlap.\n"),
            "The capture could not be connected. Try again with more overlap."
        )
        XCTAssertEqual(
            ProcessingView.failureMessage("   "),
            "No error details were reported."
        )
        XCTAssertEqual(
            ProcessingView.failureMessage(nil),
            "No error details were reported."
        )
    }

    func testFormatElapsedClampsRoundsAndFormats() {
        XCTAssertEqual(ProcessingView.formatElapsed(0), "0m 00s")
        XCTAssertEqual(ProcessingView.formatElapsed(-5), "0m 00s", "Negative elapsed clamps to zero.")
        XCTAssertEqual(ProcessingView.formatElapsed(65), "1m 05s")
        XCTAssertEqual(ProcessingView.formatElapsed(90.6), "1m 31s", "Rounds to the nearest second.")
        XCTAssertEqual(ProcessingView.formatElapsed(3661), "1h 01m 01s", "Hours appear only when non-zero.")
    }

    func testTimingTextIsNilWithoutElapsed() {
        XCTAssertNil(ProcessingView.timingText(elapsed: nil, silenceSeconds: 5))
    }

    func testTimingTextElapsedOnly() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: nil),
            "Elapsed 1m 05s"
        )
    }

    func testTimingTextSubSecondSilenceReadsNow() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: 0.4),
            "Elapsed 1m 05s · Last update now"
        )
    }

    func testTimingTextSilenceAtLeastOneSecondReadsAgo() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: 5),
            "Elapsed 1m 05s · Last update 0m 05s ago"
        )
    }
}
