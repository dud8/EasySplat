import XCTest
import EasySplatCore
@testable import EasySplatApp

final class RunDurationPredictorTests: XCTestCase {
    private func makeSummary(
        status: ProjectStatus = .ready,
        totalSeconds: TimeInterval?,
        mode: CaptureMode = .object,
        quality: QualityPreset = .standard
    ) -> ProjectSummary {
        let timings: [StageTimingRecord]
        if let total = totalSeconds {
            timings = [.init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: total)]
        } else {
            timings = []
        }
        let id = UUID()
        return ProjectSummary(
            id: id,
            title: "T",
            url: URL(fileURLWithPath: "/tmp/t-\(id.uuidString).easysplatproj"),
            createdAt: Date(timeIntervalSince1970: 0),
            status: status,
            isActive: false,
            isRetrying: false,
            isInterrupted: false,
            checkpointUpdatedAt: nil,
            lastError: nil,
            outputPlyURL: nil,
            outputPlySizeBytes: nil,
            reconstruction: nil,
            stageTimings: timings,
            preset: PresetSpec(mode: mode, quality: quality),
            lastOpenedAt: nil,
            lastFailureAt: nil,
            recentErrorCount: nil
        )
    }

    func testReturnsNilWhenBelowSampleFloor() {
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [makeSummary(totalSeconds: 60)]
        )
        XCTAssertNil(prediction)
    }

    func testReturnsMedianAcrossSuccessfulRuns() {
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [
                makeSummary(totalSeconds: 60),
                makeSummary(totalSeconds: 90),
                makeSummary(totalSeconds: 120)
            ]
        )
        XCTAssertEqual(prediction?.seconds, 90)
        XCTAssertEqual(prediction?.sampleCount, 3)
    }

    func testIgnoresFailedAndInProgressProjects() {
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [
                makeSummary(status: .failed, totalSeconds: 600),
                makeSummary(status: .inProgress, totalSeconds: 600),
                makeSummary(totalSeconds: 60),
                makeSummary(totalSeconds: 90)
            ]
        )
        XCTAssertEqual(prediction?.seconds, 75) // median of [60, 90]
        XCTAssertEqual(prediction?.sampleCount, 2)
    }

    func testIgnoresProjectsWithoutTimings() {
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [
                makeSummary(totalSeconds: nil),
                makeSummary(totalSeconds: 60),
                makeSummary(totalSeconds: 90)
            ]
        )
        XCTAssertEqual(prediction?.seconds, 75)
        XCTAssertEqual(prediction?.sampleCount, 2)
    }

    func testMedianHelperOnEmptyReturnsZero() {
        XCTAssertEqual(RunDurationPredictor.medianForTesting([]), 0)
    }

    func testDisplayTextFormatsCleanly() {
        let prediction = RunDurationPredictor.Prediction(seconds: 90, sampleCount: 3)
        XCTAssertEqual(prediction.displayText, "Estimated ~1m 30s based on 3 past runs")
    }

    func testPredictStageReturnsMedianForCompletedStage() {
        let projects: [ProjectSummary] = [
            makeSummaryWithStageTimings([
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 30),
                .init(stage: .trainBrush, startedAt: Date(timeIntervalSince1970: 30), durationSeconds: 200)
            ]),
            makeSummaryWithStageTimings([
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60),
                .init(stage: .trainBrush, startedAt: Date(timeIntervalSince1970: 60), durationSeconds: 220)
            ]),
            makeSummaryWithStageTimings([
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 90)
            ])
        ]
        let features = RunDurationPredictor.predictStage(.sfmFeatures, mode: nil, quality: nil, from: projects)
        XCTAssertEqual(features?.seconds, 60)
        XCTAssertEqual(features?.sampleCount, 3)
        let train = RunDurationPredictor.predictStage(.trainBrush, mode: nil, quality: nil, from: projects)
        XCTAssertEqual(train?.seconds, 210)
        XCTAssertEqual(train?.sampleCount, 2)
    }

    func testPredictStageReturnsNilBelowSampleFloor() {
        let projects: [ProjectSummary] = [
            makeSummaryWithStageTimings([
                .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 30)
            ])
        ]
        XCTAssertNil(RunDurationPredictor.predictStage(.sfmMapping, mode: nil, quality: nil, from: projects))
    }

    func testPredictStageFiltersByPresetWhenSpecified() {
        let projects: [ProjectSummary] = [
            makeSummaryWithStageTimings([
                .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 500)
            ], preset: PresetSpec(mode: .room, quality: .ultra)),
            makeSummaryWithStageTimings([
                .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60)
            ], preset: PresetSpec(mode: .object, quality: .standard)),
            makeSummaryWithStageTimings([
                .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 80)
            ], preset: PresetSpec(mode: .object, quality: .standard))
        ]
        let prediction = RunDurationPredictor.predictStage(
            .sfmMapping,
            mode: .object,
            quality: .standard,
            from: projects
        )
        XCTAssertEqual(prediction?.seconds, 70)
        XCTAssertEqual(prediction?.sampleCount, 2)
    }

    private func makeSummaryWithStageTimings(
        _ timings: [StageTimingRecord],
        preset: PresetSpec = PresetSpec(mode: .object, quality: .standard)
    ) -> ProjectSummary {
        return ProjectSummary(
            id: UUID(),
            title: "S",
            url: URL(fileURLWithPath: "/tmp/s.easysplatproj"),
            createdAt: Date(timeIntervalSince1970: 0),
            status: .ready,
            isActive: false,
            isRetrying: false,
            isInterrupted: false,
            checkpointUpdatedAt: nil,
            lastError: nil,
            outputPlyURL: nil,
            outputPlySizeBytes: nil,
            reconstruction: nil,
            stageTimings: timings,
            preset: preset,
            lastOpenedAt: nil,
            lastFailureAt: nil,
            recentErrorCount: nil
        )
    }

    func testPredictExcludesProjectsWithDifferentPreset() {
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [
                makeSummary(totalSeconds: 100, mode: .object, quality: .ultra), // different quality
                makeSummary(totalSeconds: 100, mode: .room, quality: .standard), // different mode
                makeSummary(totalSeconds: 60, mode: .object, quality: .standard),
                makeSummary(totalSeconds: 90, mode: .object, quality: .standard)
            ]
        )
        XCTAssertEqual(prediction?.seconds, 75)
        XCTAssertEqual(prediction?.sampleCount, 2)
    }

    func testPredictExcludesViewedProjectViaExcludingURL() {
        let viewed = makeSummary(totalSeconds: 120)
        let pastA = makeSummary(totalSeconds: 100)
        let pastB = makeSummary(totalSeconds: 80)
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [viewed, pastA, pastB],
            excluding: viewed.url
        )
        // Without exclusion the median would be 100 (median of [80, 100, 120]).
        // Excluding viewed leaves [80, 100] -> median 90.
        XCTAssertEqual(prediction?.seconds, 90)
        XCTAssertEqual(prediction?.sampleCount, 2)
    }

    func testPredictExcludingURLBlocksSelfBenchmarkBelowSampleFloor() {
        let viewed = makeSummary(totalSeconds: 120)
        let onePast = makeSummary(totalSeconds: 100)
        // Without exclusion the predictor would think there are 2 samples
        // (viewed + onePast) and return a median; excluding viewed drops
        // us back below the sample floor where we correctly return nil.
        XCTAssertNotNil(
            RunDurationPredictor.predict(mode: .object, quality: .standard, from: [viewed, onePast])
        )
        XCTAssertNil(
            RunDurationPredictor.predict(
                mode: .object,
                quality: .standard,
                from: [viewed, onePast],
                excluding: viewed.url
            )
        )
    }

    func testPredictExcludesProjectsWithNilPreset() {
        // Legacy projects without persisted preset must not pollute the median.
        var legacy = makeSummary(totalSeconds: 600, mode: .object, quality: .standard)
        legacy = ProjectSummary(
            id: legacy.id,
            title: legacy.title,
            url: legacy.url,
            createdAt: legacy.createdAt,
            status: legacy.status,
            isActive: legacy.isActive,
            isRetrying: legacy.isRetrying,
            isInterrupted: legacy.isInterrupted,
            checkpointUpdatedAt: legacy.checkpointUpdatedAt,
            lastError: legacy.lastError,
            outputPlyURL: legacy.outputPlyURL,
            outputPlySizeBytes: legacy.outputPlySizeBytes,
            reconstruction: legacy.reconstruction,
            stageTimings: legacy.stageTimings,
            preset: nil,
            lastOpenedAt: nil,
            lastFailureAt: nil,
            recentErrorCount: nil
        )
        let prediction = RunDurationPredictor.predict(
            mode: .object,
            quality: .standard,
            from: [
                legacy,
                makeSummary(totalSeconds: 60),
                makeSummary(totalSeconds: 90)
            ]
        )
        XCTAssertEqual(prediction?.seconds, 75)
        XCTAssertEqual(prediction?.sampleCount, 2)
    }
}
