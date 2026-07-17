import XCTest
@testable import EasySplatCore

final class VideoFrameAllocationTests: XCTestCase {
    func testAnalysisConcurrencyFollowsResolvedResourcePolicy() {
        XCTAssertEqual(
            PipelineRunner.test_videoAnalysisConcurrency(
                threadLimit: 2,
                videoCount: 6
            ),
            1
        )
        XCTAssertEqual(
            PipelineRunner.test_videoAnalysisConcurrency(
                threadLimit: 4,
                videoCount: 6
            ),
            2
        )
        XCTAssertEqual(
            PipelineRunner.test_videoAnalysisConcurrency(
                threadLimit: 6,
                videoCount: 6
            ),
            3
        )
        XCTAssertEqual(
            PipelineRunner.test_videoAnalysisConcurrency(
                threadLimit: 8,
                videoCount: 6
            ),
            4
        )
        XCTAssertEqual(
            PipelineRunner.test_videoAnalysisConcurrency(
                threadLimit: 10,
                videoCount: 2
            ),
            2
        )
    }

    func testWeightedParallelAnalysisProgressNeverRegresses() {
        let reported = TestFractionSink()
        let progress = WeightedVideoAnalysisProgress(
            weights: [1, 3],
            base: 0.1,
            span: 0.4
        ) { fraction in
            reported.append(fraction)
        }

        DispatchQueue.concurrentPerform(iterations: 100) { iteration in
            let index = iteration % 2
            let fraction = Double((iteration * 37) % 101) / 100
            progress.update(index: index, fraction: fraction)
        }
        progress.update(index: 0, fraction: 1)
        progress.update(index: 1, fraction: 1)

        let snapshot = reported.values
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(zip(snapshot, snapshot.dropFirst()).allSatisfy { $1 >= $0 })
        XCTAssertEqual(snapshot.last ?? -1, 0.5, accuracy: 0.000_001)
    }

    private let runner = PipelineRunner(
        projectURL: URL(fileURLWithPath: "/tmp"),
        config: .init(toolchain: TestToolchains.toolchainPaths(
            root: URL(fileURLWithPath: "/tmp")
        ))
    )

    func testBalancedAndHighDetailAlwaysUseFullProfileBudget() {
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [9.5428666667],
                frameCeiling: 250,
                analysisFrameRate: 3,
                detail: .balanced
            ),
            250
        )
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [9.5428666667],
                frameCeiling: 500,
                analysisFrameRate: 3,
                detail: .highDetail
            ),
            500
        )
    }

    func testFastTreatsProfileBudgetAsADurationAwareCeiling() {
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [9.5428666667],
                frameCeiling: 250,
                analysisFrameRate: 3,
                detail: .fast
            ),
            30
        )
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [100],
                frameCeiling: 250,
                analysisFrameRate: 3,
                detail: .fast
            ),
            250
        )
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [66.0326333333],
                frameCeiling: 250,
                analysisFrameRate: 3,
                detail: .fast
            ),
            199
        )
    }

    func testDurationAwareTargetUsesTotalClipDurationWithoutMultiplyingTheFloor() {
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [1, 2, 3],
                frameCeiling: 250,
                analysisFrameRate: 3,
                detail: .fast
            ),
            30
        )
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [20, 20],
                frameCeiling: 250,
                analysisFrameRate: 3,
                detail: .fast
            ),
            120
        )
        XCTAssertEqual(
            PipelineRunner.test_durationAwareVideoFrameTarget(
                durations: [1, 1, 1, 1],
                frameCeiling: 6,
                analysisFrameRate: 3,
                detail: .fast
            ),
            6
        )
    }

    func testDurationAwareTargetRejectsInvalidInputs() {
        XCTAssertNil(PipelineRunner.test_durationAwareVideoFrameTarget(
            durations: [],
            frameCeiling: 250,
            analysisFrameRate: 3,
            detail: .balanced
        ))
        XCTAssertNil(PipelineRunner.test_durationAwareVideoFrameTarget(
            durations: [.nan],
            frameCeiling: 250,
            analysisFrameRate: 3,
            detail: .balanced
        ))
        XCTAssertNil(PipelineRunner.test_durationAwareVideoFrameTarget(
            durations: [10],
            frameCeiling: 0,
            analysisFrameRate: 3,
            detail: .balanced
        ))
        XCTAssertNil(PipelineRunner.test_durationAwareVideoFrameTarget(
            durations: [10],
            frameCeiling: 250,
            analysisFrameRate: 0,
            detail: .balanced
        ))
    }

    func testTargetsFollowClipDurationInsteadOfClipCount() throws {
        XCTAssertEqual(
            try runner.allocateVideoFrameTargets(
                [
                    .init(durationSeconds: 1, availableCandidateCount: 30),
                    .init(durationSeconds: 60, availableCandidateCount: 1_800),
                ],
                totalTargetCount: 250
            ),
            [6, 244]
        )
    }

    func testTargetsRedistributeWhenShortClipSaturates() throws {
        XCTAssertEqual(
            try runner.allocateVideoFrameTargets(
                [
                    .init(durationSeconds: 1, availableCandidateCount: 3),
                    .init(durationSeconds: 9, availableCandidateCount: 300),
                ],
                totalTargetCount: 100
            ),
            [3, 97]
        )
    }

    func testTargetsUseStableLargestRemainderTieBreak() throws {
        let inputs = (0..<3).map { _ in
            VideoFrameAllocationInput(durationSeconds: 1, availableCandidateCount: 20)
        }
        for _ in 0..<100 {
            XCTAssertEqual(
                try runner.allocateVideoFrameTargets(inputs, totalTargetCount: 10),
                [4, 3, 3]
            )
        }
    }

    func testTargetsPreserveClipEndpointsAndSingleFrameIdentity() throws {
        XCTAssertEqual(
            try runner.allocateVideoFrameTargets(
                [
                    .init(durationSeconds: 1, availableCandidateCount: 1),
                    .init(durationSeconds: 10, availableCandidateCount: 100),
                ],
                totalTargetCount: 20
            ),
            [1, 19]
        )
        let targets = try runner.allocateVideoFrameTargets(
            [
                .init(durationSeconds: 1, availableCandidateCount: 8),
                .init(durationSeconds: 2, availableCandidateCount: 12),
                .init(durationSeconds: 4, availableCandidateCount: 30),
            ],
            totalTargetCount: 20
        )
        XCTAssertTrue(targets.allSatisfy { $0 >= 2 })
    }

    func testTargetsRejectBudgetThatCannotRepresentEveryClip() {
        XCTAssertThrowsError(
            try runner.allocateVideoFrameTargets(
                [
                    .init(durationSeconds: 1, availableCandidateCount: 10),
                    .init(durationSeconds: 1, availableCandidateCount: 10),
                ],
                totalTargetCount: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoFrameAllocationError,
                .insufficientBudgetForClipCoverage(required: 4, available: 3)
            )
        }
    }

    func testTargetsUseAllPhysicalCapacityWithoutExceedingIt() throws {
        XCTAssertEqual(
            try runner.allocateVideoFrameTargets(
                [
                    .init(durationSeconds: 1, availableCandidateCount: 10),
                    .init(durationSeconds: 1, availableCandidateCount: 12),
                ],
                totalTargetCount: 30
            ),
            [10, 12]
        )

        for firstCapacity in 1...8 {
            for secondCapacity in 1...8 {
                for budget in 4...20 {
                    let capacities = [firstCapacity, secondCapacity]
                    let targets = try runner.allocateVideoFrameTargets(
                        [
                            .init(durationSeconds: 1, availableCandidateCount: firstCapacity),
                            .init(durationSeconds: 3, availableCandidateCount: secondCapacity),
                        ],
                        totalTargetCount: budget
                    )
                    XCTAssertEqual(targets.reduce(0, +), min(budget, capacities.reduce(0, +)))
                    XCTAssertTrue(zip(targets, capacities).allSatisfy { $0 <= $1 })
                    XCTAssertGreaterThanOrEqual(targets[0], min(2, firstCapacity))
                    XCTAssertGreaterThanOrEqual(targets[1], min(2, secondCapacity))
                }
            }
        }
    }

    func testTargetsRejectInvalidInputAndLeaveEmptyClipAtZero() throws {
        XCTAssertThrowsError(
            try runner.allocateVideoFrameTargets(
                [.init(durationSeconds: .nan, availableCandidateCount: 10)],
                totalTargetCount: 10
            )
        ) { error in
            XCTAssertEqual(error as? VideoFrameAllocationError, .invalidInput(index: 0))
        }
        XCTAssertEqual(
            try runner.allocateVideoFrameTargets(
                [
                    .init(durationSeconds: 1, availableCandidateCount: 0),
                    .init(durationSeconds: 2, availableCandidateCount: 10),
                ],
                totalTargetCount: 8
            ),
            [0, 8]
        )
    }

    func testGlobalAutomaticTargetsMatchExistingMixedBudgetSemantics() throws {
        let plan = try runner.resolveGlobalFrameTargets(
            videos: [
                .init(durationSeconds: 60, availableCandidateCount: 120),
            ],
            validPhotoCount: 80,
            targetCount: 120,
            photoSelection: .automatic
        )

        XCTAssertEqual(plan.videoTargets, [72])
        XCTAssertEqual(plan.photoTarget, 48)
        XCTAssertEqual(plan.totalTargetCount, 120)
    }

    func testGlobalUseAllTargetsPreserveEveryPhotoAndVideoReserve() throws {
        let plan = try runner.resolveGlobalFrameTargets(
            videos: [
                .init(durationSeconds: 60, availableCandidateCount: 120),
            ],
            validPhotoCount: 80,
            targetCount: 120,
            photoSelection: .useAllValidPhotos
        )

        XCTAssertEqual(plan.videoTargets, [40])
        XCTAssertEqual(plan.photoTarget, 80)
        XCTAssertThrowsError(try runner.resolveGlobalFrameTargets(
            videos: [
                .init(durationSeconds: 60, availableCandidateCount: 120),
            ],
            validPhotoCount: 91,
            targetCount: 120,
            photoSelection: .useAllValidPhotos
        ))
    }

    func testGlobalTargetsRedistributeDurationWithoutMultiplyingBudget() throws {
        let plan = try runner.resolveGlobalFrameTargets(
            videos: [
                .init(durationSeconds: 1, availableCandidateCount: 30),
                .init(durationSeconds: 9, availableCandidateCount: 300),
            ],
            validPhotoCount: 0,
            targetCount: 250,
            photoSelection: .automatic
        )

        XCTAssertEqual(plan.videoTargets.reduce(0, +), 250)
        XCTAssertEqual(plan.photoTarget, 0)
        XCTAssertEqual(plan.videoTargets, [27, 223])
    }

    func testGlobalTargetsUseVideosWhenMixedPhotosAreAllInvalid() throws {
        let plan = try runner.resolveGlobalFrameTargets(
            videos: [
                .init(durationSeconds: 60, availableCandidateCount: 250),
            ],
            validPhotoCount: 0,
            targetCount: 250,
            photoSelection: .automatic
        )

        XCTAssertEqual(plan.videoTargets, [250])
        XCTAssertEqual(plan.photoTarget, 0)
    }
}

private final class TestFractionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
