import XCTest
@testable import EasySplatCore

final class FinishedProjectStageTimingValidationTests: XCTestCase {
    func testFinishedPhotoRunRequiresEveryApplicableStageExactlyOnce() throws {
        let timings = makeTimings(includeVideoExtraction: false)

        XCTAssertNoThrow(try ProjectArtifactValidator.validateCompletedStageTimings(
            timings,
            input: .photos(folder: "/tmp/Photos")
        ))

        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            nil,
            input: .photos(folder: "/tmp/Photos")
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            Array(timings.dropLast()),
            input: .photos(folder: "/tmp/Photos")
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            timings + [timings[0]],
            input: .photos(folder: "/tmp/Photos")
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            timings + [record(.done)],
            input: .photos(folder: "/tmp/Photos")
        ))
    }

    func testFinishedVideoRunRequiresExtractionTiming() throws {
        let videoInput = InputSpec.video(files: ["/tmp/capture.mov"])
        XCTAssertNoThrow(try ProjectArtifactValidator.validateCompletedStageTimings(
            makeTimings(includeVideoExtraction: true),
            input: videoInput
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            makeTimings(includeVideoExtraction: false),
            input: videoInput
        ))
    }

    func testFinishedRunRejectsNonFiniteTimingFacts() throws {
        var invalidDuration = makeTimings(includeVideoExtraction: false)
        invalidDuration[0].durationSeconds = .nan
        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            invalidDuration,
            input: .photos(folder: "/tmp/Photos")
        ))

        var invalidStart = makeTimings(includeVideoExtraction: false)
        invalidStart[0].startedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try ProjectArtifactValidator.validateCompletedStageTimings(
            invalidStart,
            input: .photos(folder: "/tmp/Photos")
        ))
    }

    private func makeTimings(includeVideoExtraction: Bool) -> [StageTimingRecord] {
        var stages: [PipelineStage] = [.importInput]
        if includeVideoExtraction {
            stages.append(.extractFrames)
        }
        stages.append(contentsOf: [
            .selectFrames,
            .sfmFeatures,
            .sfmMatching,
            .sfmMapping,
            .trainSplat,
            .exportSplat,
        ])
        return stages.enumerated().map { offset, stage in
            record(stage, offset: offset)
        }
    }

    private func record(
        _ stage: PipelineStage,
        offset: Int = 0
    ) -> StageTimingRecord {
        StageTimingRecord(
            stage: stage,
            startedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + offset)),
            durationSeconds: TimeInterval(offset + 1)
        )
    }
}
