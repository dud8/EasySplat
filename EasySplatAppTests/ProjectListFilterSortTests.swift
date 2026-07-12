import XCTest
import EasySplatCore
@testable import EasySplatApp

final class ProjectListFilterSortTests: XCTestCase {
    private func makeSummary(
        id: UUID = UUID(),
        title: String = "Project",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        status: ProjectStatus = .ready,
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
            reconstruction: nil,
            stageTimings: stageTimings,
            preset: PresetSpec(mode: .object, quality: .standard),
            input: nil,
            requestedRunOptions: nil,
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

    func testSortMenuContainsOnlyRecentCreatedAndName() {
        XCTAssertEqual(
            ProjectListSort.allCases.map(\.displayName),
            ["Created", "Recent", "Name"]
        )
    }

    func testSidebarAppliesStatusSearchAndSortTogether() {
        let readyKitchen = makeSummary(
            title: "Kitchen",
            createdAt: Date(timeIntervalSince1970: 100),
            status: .ready
        )
        let failedKitchen = makeSummary(
            title: "Kitchen Retry",
            createdAt: Date(timeIntervalSince1970: 300),
            status: .failed
        )
        let readyOffice = makeSummary(
            title: "Office",
            createdAt: Date(timeIntervalSince1970: 200),
            status: .ready
        )

        let visible = ProjectSidebar.visibleProjects(
            [readyOffice, failedKitchen, readyKitchen],
            filter: .ready,
            sort: .createdNewest,
            searchText: "kitchen"
        )

        XCTAssertEqual(visible.map(\.title), ["Kitchen"])
    }

    func testRenameDraftValidityRejectsEmptyAndUnchangedTitles() {
        XCTAssertTrue(ProjectSidebar.renameDraftIsInvalid(draft: "", currentTitle: "ProjectA"))
        XCTAssertTrue(ProjectSidebar.renameDraftIsInvalid(draft: "   ", currentTitle: "ProjectA"))
        XCTAssertTrue(ProjectSidebar.renameDraftIsInvalid(draft: " ProjectA ", currentTitle: "ProjectA"))
        XCTAssertFalse(ProjectSidebar.renameDraftIsInvalid(draft: "ProjectB", currentTitle: "ProjectA"))
        XCTAssertFalse(ProjectSidebar.renameDraftIsInvalid(draft: " ProjectB ", currentTitle: "ProjectA"))
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
