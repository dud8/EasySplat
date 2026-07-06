import XCTest
import EasySplatCore
@testable import EasySplatApp

final class ProjectListFilterSortTests: XCTestCase {
    private func makeSummary(
        id: UUID = UUID(),
        title: String = "Project",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        status: ProjectStatus = .ready,
        reconstruction: ReconstructionSummary? = nil,
        stageTimings: [StageTimingRecord] = [],
        lastOpenedAt: Date? = nil
    ) -> ProjectSummary {
        return ProjectSummary(
            id: id,
            title: title,
            url: URL(fileURLWithPath: "/tmp/\(id.uuidString).easysplatproj"),
            createdAt: createdAt,
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
            lastOpenedAt: lastOpenedAt,
            lastFailureAt: nil,
            recentErrorCount: nil
        )
    }

    func testFilterReadyExcludesOtherStatuses() {
        let ready = makeSummary(status: .ready)
        let inProgress = makeSummary(status: .inProgress)
        let failed = makeSummary(status: .failed)
        XCTAssertTrue(ProjectListFilter.ready.matches(ready))
        XCTAssertFalse(ProjectListFilter.ready.matches(inProgress))
        XCTAssertFalse(ProjectListFilter.ready.matches(failed))
    }

    func testFilterAllPassesEverything() {
        let projects = [
            makeSummary(status: .ready),
            makeSummary(status: .inProgress),
            makeSummary(status: .failed),
            makeSummary(status: .needsAppUpdate)
        ]
        for project in projects {
            XCTAssertTrue(ProjectListFilter.all.matches(project))
        }
    }

    func testSortByCreatedNewestPutsRecentFirst() {
        let older = makeSummary(title: "Old", createdAt: Date(timeIntervalSince1970: 100))
        let newer = makeSummary(title: "New", createdAt: Date(timeIntervalSince1970: 1_000))
        let sorted = ProjectListSort.createdNewest.apply(to: [older, newer])
        XCTAssertEqual(sorted.map(\.title), ["New", "Old"])
    }

    func testSortByDurationLongestUsesStageTimings() {
        let short = makeSummary(
            title: "Short",
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 30)
            ]
        )
        let long = makeSummary(
            title: "Long",
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60),
                .init(stage: .trainBrush, startedAt: Date(timeIntervalSince1970: 100), durationSeconds: 300)
            ]
        )
        let untimed = makeSummary(title: "Untimed")
        let sorted = ProjectListSort.durationLongest.apply(to: [untimed, short, long])
        XCTAssertEqual(sorted.map(\.title), ["Long", "Short", "Untimed"])
    }

    func testSortByCoverageHighestRanksRegisteredFractionDesc() {
        let highCoverage = makeSummary(
            title: "High",
            reconstruction: ReconstructionSummary(
                mapper: "vggt",
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 30,
                totalImages: 30
            )
        )
        let lowCoverage = makeSummary(
            title: "Low",
            reconstruction: ReconstructionSummary(
                mapper: "vggt",
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 5,
                totalImages: 30
            )
        )
        let noReconstruction = makeSummary(title: "None")
        let sorted = ProjectListSort.coverageHighest.apply(to: [noReconstruction, lowCoverage, highCoverage])
        XCTAssertEqual(sorted.map(\.title), ["High", "Low", "None"])
    }

    func testTrashCandidateURLsKeepsOnlyFailedAndExcludesActive() {
        let failedActive = makeSummary(title: "Active", status: .failed)
        let failedIdle = makeSummary(title: "Idle", status: .failed)
        let ready = makeSummary(title: "Ready", status: .ready)
        let inProgress = makeSummary(title: "Working", status: .inProgress)
        let candidates = ProjectListView.trashCandidateURLs(
            in: [failedActive, failedIdle, ready, inProgress],
            excludingActive: failedActive.url
        )
        XCTAssertEqual(candidates, [failedIdle.url])
    }

    func testRenameDraftValidityRejectsEmptyAndUnchangedTitles() {
        XCTAssertTrue(ProjectListView.renameDraftIsInvalid(draft: "", currentTitle: "ProjectA"))
        XCTAssertTrue(ProjectListView.renameDraftIsInvalid(draft: "   ", currentTitle: "ProjectA"))
        XCTAssertTrue(ProjectListView.renameDraftIsInvalid(draft: " ProjectA ", currentTitle: "ProjectA"))
        XCTAssertFalse(ProjectListView.renameDraftIsInvalid(draft: "ProjectB", currentTitle: "ProjectA"))
        XCTAssertFalse(ProjectListView.renameDraftIsInvalid(draft: " ProjectB ", currentTitle: "ProjectA"))
    }

    func testSortByLastActivityPrefersLastOpenedAtOverStageTimings() {
        let openedYesterday = makeSummary(
            title: "OpenedYesterday",
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 100), durationSeconds: 60)
            ],
            lastOpenedAt: Date(timeIntervalSince1970: 200_000)
        )
        let openedToday = makeSummary(
            title: "OpenedToday",
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 60)
            ],
            lastOpenedAt: Date(timeIntervalSince1970: 300_000)
        )
        let stageOnly = makeSummary(
            title: "StageOnly",
            stageTimings: [
                .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 500_000), durationSeconds: 60)
            ],
            lastOpenedAt: nil
        )
        let sorted = ProjectListSort.lastActivityNewest.apply(to: [openedYesterday, openedToday, stageOnly])
        XCTAssertEqual(sorted.map(\.title), ["StageOnly", "OpenedToday", "OpenedYesterday"])
    }

    func testSortByTitleAlphabeticalIsCaseInsensitive() {
        let zebra = makeSummary(title: "zebra")
        let apple = makeSummary(title: "Apple")
        let middle = makeSummary(title: "monkey")
        let sorted = ProjectListSort.titleAlphabetical.apply(to: [zebra, apple, middle])
        XCTAssertEqual(sorted.map(\.title), ["Apple", "monkey", "zebra"])
    }

    func testTotalRunDurationTextOmitsZero() {
        let withoutTimings = makeSummary()
        XCTAssertNil(withoutTimings.totalRunDurationText)
        let withTimings = makeSummary(stageTimings: [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 90)
        ])
        XCTAssertEqual(withTimings.totalRunDurationText, "1m 30s")
    }
}
