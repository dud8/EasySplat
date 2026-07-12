import EasySplatCore
import XCTest
@testable import EasySplatApp

final class RunDurationPredictorTests: XCTestCase {
    private func makeSummary(
        status: ProjectStatus = .ready,
        totalSeconds: TimeInterval?,
        input: InputSpec = .video(files: ["/tmp/input.mov"]),
        requestedOptions: RequestedRunOptions? = RequestedRunOptions()
    ) -> ProjectSummary {
        let timings: [StageTimingRecord] = if let totalSeconds {
            [.init(
                stage: .sfmFeatures,
                startedAt: Date(timeIntervalSince1970: 0),
                durationSeconds: totalSeconds
            )]
        } else {
            []
        }
        let id = UUID()
        return ProjectSummary(
            id: id,
            title: "T",
            url: URL(fileURLWithPath: "/tmp/t-\(id.uuidString).easysplatproj"),
            createdAt: Date(timeIntervalSince1970: 0),
            status: status,
            isActive: false,
            isInterrupted: false,
            checkpointUpdatedAt: nil,
            stageTimings: timings,
            input: input,
            requestedRunOptions: requestedOptions,
            lastOpenedAt: nil,
            lastRunStartedAt: nil,
            lastFailureAt: nil
        )
    }

    func testReturnsNilBelowThreeComparableRuns() {
        let prediction = RunDurationPredictor.predict(
            options: RequestedRunOptions(),
            input: .video(files: ["/tmp/new.mov"]),
            from: [makeSummary(totalSeconds: 60), makeSummary(totalSeconds: 90)]
        )
        XCTAssertNil(prediction)
    }

    func testReturnsRangeMedianAndSampleCount() {
        let prediction = RunDurationPredictor.predict(
            options: RequestedRunOptions(),
            input: .video(files: ["/tmp/new.mov"]),
            from: [
                makeSummary(totalSeconds: 60),
                makeSummary(totalSeconds: 90),
                makeSummary(totalSeconds: 120),
            ]
        )
        XCTAssertEqual(prediction?.seconds, 90)
        XCTAssertEqual(prediction?.minimumSeconds, 60)
        XCTAssertEqual(prediction?.maximumSeconds, 120)
        XCTAssertEqual(prediction?.sampleCount, 3)
    }

    func testCompleteRequestedOptionsDefineComparableRuns() {
        let target = RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        let different = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced,
            resourcePolicy: .conserveMemory
        )
        let prediction = RunDurationPredictor.predict(
            options: target,
            input: .video(files: ["/tmp/new.mov"]),
            from: [
                makeSummary(totalSeconds: 60, requestedOptions: target),
                makeSummary(totalSeconds: 90, requestedOptions: target),
                makeSummary(totalSeconds: 120, requestedOptions: target),
                makeSummary(totalSeconds: 600, requestedOptions: different),
            ]
        )
        XCTAssertEqual(prediction?.seconds, 90)
        XCTAssertEqual(prediction?.sampleCount, 3)
    }

    func testIgnoresUnfinishedMissingAndUnmeasuredRuns() {
        let options = RequestedRunOptions()
        let prediction = RunDurationPredictor.predict(
            options: options,
            input: .video(files: ["/tmp/new.mov"]),
            from: [
                makeSummary(status: .failed, totalSeconds: 600),
                makeSummary(status: .inProgress, totalSeconds: 600),
                makeSummary(totalSeconds: nil),
                makeSummary(totalSeconds: 600, requestedOptions: nil),
                makeSummary(totalSeconds: 60),
                makeSummary(totalSeconds: 90),
                makeSummary(totalSeconds: 120),
            ]
        )
        XCTAssertEqual(prediction?.seconds, 90)
        XCTAssertEqual(prediction?.sampleCount, 3)
    }

    func testExcludingCurrentProjectCanDropBelowSampleFloor() {
        let viewed = makeSummary(totalSeconds: 120)
        let projects = [viewed, makeSummary(totalSeconds: 100), makeSummary(totalSeconds: 80)]

        XCTAssertNotNil(RunDurationPredictor.predict(
            options: RequestedRunOptions(),
            input: .video(files: ["/tmp/new.mov"]),
            from: projects
        ))
        XCTAssertNil(RunDurationPredictor.predict(
            options: RequestedRunOptions(),
            input: .video(files: ["/tmp/new.mov"]),
            from: projects,
            excluding: viewed.url
        ))
    }

    func testDoesNotComparePhotoAndVideoRuns() {
        let photoRuns = [60.0, 90.0, 120.0].map {
            makeSummary(totalSeconds: $0, input: .photos(folder: "/tmp/photos"))
        }

        XCTAssertNil(RunDurationPredictor.predict(
            options: RequestedRunOptions(),
            input: .video(files: ["/tmp/new.mov"]),
            from: photoRuns
        ))
    }

    func testDisplayTextFormatsCleanly() {
        let prediction = RunDurationPredictor.Prediction(
            seconds: 90,
            minimumSeconds: 60,
            maximumSeconds: 120,
            sampleCount: 3
        )
        XCTAssertEqual(prediction.displayText, "Usually 1m–2m · 3 similar runs")
    }

    func testMedianHelperOnEmptyReturnsZero() {
        XCTAssertEqual(RunDurationPredictor.medianForTesting([]), 0)
    }
}
