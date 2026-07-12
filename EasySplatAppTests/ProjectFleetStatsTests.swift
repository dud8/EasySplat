import XCTest
import EasySplatCore
@testable import EasySplatApp

final class ProjectFleetStatsTests: XCTestCase {
    private func makeSummary(
        title: String = "P",
        status: ProjectStatus = .ready,
        reconstruction: ReconstructionSummary? = nil,
        stageTimings: [StageTimingRecord] = [],
        lastOpenedAt: Date? = nil,
        lastFailureAt: Date? = nil
    ) -> ProjectSummary {
        return ProjectSummary(
            id: UUID(),
            title: title,
            url: URL(fileURLWithPath: "/tmp/\(title).easysplatproj"),
            createdAt: Date(timeIntervalSince1970: 0),
            status: status,
            isActive: false,
            isRetrying: false,
            isInterrupted: false,
            checkpointUpdatedAt: nil,
            lastError: nil,
            outputPlyURL: nil,
            outputPlySizeBytes: nil,
            reconstruction: reconstruction,
            stageTimings: stageTimings,
            preset: PresetSpec(mode: .object, quality: .standard),
            input: nil,
            requestedRunOptions: nil,
            lastOpenedAt: lastOpenedAt,
            lastFailureAt: lastFailureAt,
            recentErrorCount: nil
        )
    }

    func testAggregateOfEmptyListReturnsEmpty() {
        XCTAssertEqual(ProjectFleetStats.aggregate([]), .empty)
    }

    func testAggregateCountsAndSumsTime() {
        let stats = ProjectFleetStats.aggregate([
            makeSummary(status: .ready, stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60)
            ]),
            makeSummary(status: .ready, stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 30),
                .init(stage: .trainSplat, startedAt: Date(timeIntervalSince1970: 60), durationSeconds: 90)
            ]),
            makeSummary(status: .failed),
            makeSummary(status: .inProgress),
            makeSummary(status: .needsAppUpdate) // Ignored
        ])
        XCTAssertEqual(stats.totalProjects, 4)
        XCTAssertEqual(stats.readyProjects, 2)
        XCTAssertEqual(stats.failedProjects, 1)
        XCTAssertEqual(stats.inProgressProjects, 1)
        XCTAssertEqual(stats.totalRunSeconds, 180)
        XCTAssertEqual(stats.totalRunDurationText, "3m")
        XCTAssertEqual(stats.totalSfmSeconds, 90)
        XCTAssertEqual(stats.totalTrainingSeconds, 90)
        XCTAssertEqual(stats.totalSfmDurationText, "1m 30s")
        XCTAssertEqual(stats.totalTrainingDurationText, "1m 30s")
    }

    func testAggregateAveragesRegisteredFraction() {
        let stats = ProjectFleetStats.aggregate([
            makeSummary(reconstruction: ReconstructionSummary(
                mapper: "vggt",
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 30,
                totalImages: 30
            )),
            makeSummary(reconstruction: ReconstructionSummary(
                mapper: "vggt",
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 15,
                totalImages: 30
            ))
        ])
        XCTAssertEqual(stats.averageRegisteredFraction ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(stats.averageCoverageText, "75%")
    }

    func testAggregateCoverageUsesReadyProjectsOnly() {
        let stats = ProjectFleetStats.aggregate([
            makeSummary(status: .ready, reconstruction: ReconstructionSummary(
                mapper: "global_mapper",
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 20,
                totalImages: 20
            )),
            makeSummary(status: .failed, reconstruction: ReconstructionSummary(
                mapper: "global_mapper",
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 1,
                totalImages: 20
            ))
        ])
        XCTAssertEqual(stats.averageRegisteredFraction ?? -1, 1.0, accuracy: 1e-9)
    }

    func testAggregateLastSuccessIgnoresLastOpenedAt() {
        let completion = Date(timeIntervalSince1970: 1_060)
        let laterOpen = Date(timeIntervalSince1970: 5_000)
        let stats = ProjectFleetStats.aggregate([
            makeSummary(
                title: "ReopenedReady",
                status: .ready,
                stageTimings: [
                    .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 60)
                ],
                lastOpenedAt: laterOpen
            )
        ])
        XCTAssertEqual(stats.lastSuccessfulCompletionAt, completion)
    }

    func testAggregateUsesPersistedFailureTimestampOverLastOpenedAt() {
        // Regression for the Codex finding: a failed project that was opened
        // after its failure (lastOpenedAt = T+100) should still report the
        // actual failure time (lastFailureAt = T+0) on the home card.
        let failureMoment = Date(timeIntervalSince1970: 5_000)
        let laterOpen = Date(timeIntervalSince1970: 5_500)
        let summary = makeSummary(
            title: "ReopenedAfterFailure",
            status: .failed,
            stageTimings: [],
            lastOpenedAt: laterOpen,
            lastFailureAt: failureMoment
        )
        let stats = ProjectFleetStats.aggregate([summary])
        XCTAssertEqual(stats.lastFailureAt, failureMoment,
                       "Persisted lastFailureAt must win over lastOpenedAt for the Last failure card.")
    }

    func testAggregateFallsBackToLastActivityWhenFailureTimestampMissing() {
        // Legacy projects without the persisted failure field should still
        // show *something* on the card (the prior behavior is the fallback).
        let summary = makeSummary(
            title: "LegacyFailure",
            status: .failed,
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 30)
            ],
            lastFailureAt: nil
        )
        let stats = ProjectFleetStats.aggregate([summary])
        XCTAssertNotNil(stats.lastFailureAt)
    }

    func testAggregateTracksLastFailureSeparatelyFromLastSuccess() {
        let readyOlder = makeSummary(title: "ReadySooner", status: .ready, stageTimings: [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 60)
        ])
        let failedRecent = makeSummary(title: "FailedRecent", status: .failed, stageTimings: [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 5_000), durationSeconds: 30)
        ])
        let stats = ProjectFleetStats.aggregate([readyOlder, failedRecent])
        // The .ready run completed at 1_060s, the failure at 5_030s.
        XCTAssertEqual(stats.lastSuccessfulCompletionAt, Date(timeIntervalSince1970: 1_060))
        XCTAssertEqual(stats.lastFailureAt, Date(timeIntervalSince1970: 5_030))
    }

    func testAggregateIgnoresProjectsWithoutReconstruction() {
        let stats = ProjectFleetStats.aggregate([
            makeSummary(status: .failed),
            makeSummary(status: .inProgress)
        ])
        XCTAssertNil(stats.averageRegisteredFraction)
        XCTAssertNil(stats.averageCoverageText)
    }

    func testMedianCoverageRequiresAtLeastTwoOtherProjects() {
        let only = makeSummary(reconstruction: ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 18,
            totalImages: 20
        ))
        XCTAssertNil(ProjectFleetStats.medianCoverage(excluding: nil, from: [only]))
    }

    func testMedianCoverageExcludesNamedProject() {
        let target = makeSummary(title: "target", reconstruction: ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 5,
            totalImages: 20
        ))
        let high = makeSummary(title: "high", reconstruction: ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 30,
            totalImages: 30
        ))
        let mid = makeSummary(title: "mid", reconstruction: ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 24,
            totalImages: 30
        ))
        let median = ProjectFleetStats.medianCoverage(excluding: target.url, from: [target, high, mid])
        // Excluded target's 25% does not skew the median, which becomes (0.8 + 1.0)/2 = 0.9
        XCTAssertEqual(median ?? 0, 0.9, accuracy: 1e-9)
    }
}
