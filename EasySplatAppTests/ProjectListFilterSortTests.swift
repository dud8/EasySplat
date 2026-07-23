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
        lastOpenedAt: Date? = nil,
        lastRunStartedAt: Date? = nil,
        lastFailureAt: Date? = nil,
        url: URL? = nil
    ) -> ProjectSummary {
        return ProjectSummary(
            id: id,
            title: title,
            url: url ?? URL(fileURLWithPath: "/tmp/\(id.uuidString).easysplatproj"),
            createdAt: createdAt,
            status: status,
            isActive: false,
            isInterrupted: false,
            checkpointUpdatedAt: nil,
            stageTimings: stageTimings,
            createToViewerReadySeconds: nil,
            input: nil,
            requestedRunOptions: nil,
            lastOpenedAt: lastOpenedAt,
            lastRunStartedAt: lastRunStartedAt,
            lastFailureAt: lastFailureAt
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
            makeSummary(status: .failed)
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

    func testSidebarSelectionIdentityUsesBundleLocationInsteadOfDuplicatedMetadataUUID() {
        let duplicatedProjectID = UUID()
        let first = makeSummary(
            id: duplicatedProjectID,
            title: "Original",
            url: URL(fileURLWithPath: "/tmp/Original.easysplatproj")
        )
        let copy = makeSummary(
            id: duplicatedProjectID,
            title: "Copy",
            url: URL(fileURLWithPath: "/tmp/Copy.easysplatproj")
        )

        XCTAssertNotEqual(
            ProjectSidebar.selectionID(for: first),
            ProjectSidebar.selectionID(for: copy)
        )
        XCTAssertEqual(
            ProjectSidebar.project(forSelectionID: ProjectSidebar.selectionID(for: copy), in: [first, copy])?.url,
            copy.url
        )
    }

    func testSidebarSelectionIdentityIgnoresDirectoryURLSpelling() {
        let directoryURL = URL(fileURLWithPath: "/tmp/Project.easysplatproj", isDirectory: true)
        let fileURL = URL(fileURLWithPath: directoryURL.path)

        XCTAssertEqual(
            ProjectSidebar.selectionID(for: directoryURL),
            ProjectSidebar.selectionID(for: fileURL)
        )
    }

    func testProjectRowAccessibilityIdentifierIsStableAndDoesNotExposeThePath() {
        let directoryURL = URL(fileURLWithPath: "/Users/example/Client Work/House.easysplatproj", isDirectory: true)
        let fileURL = URL(fileURLWithPath: directoryURL.path)

        let identifier = ProjectSidebar.rowAccessibilityIdentifier(for: directoryURL)

        XCTAssertEqual(identifier, ProjectSidebar.rowAccessibilityIdentifier(for: fileURL))
        XCTAssertTrue(identifier.hasPrefix("project.row."))
        XCTAssertEqual(identifier.count, "project.row.".count + 16)
        XCTAssertFalse(identifier.contains("example"))
        XCTAssertFalse(identifier.contains("House"))
        XCTAssertFalse(identifier.contains("Client"))
    }

    func testProjectActionAccessibilityIdentifierIsStableAndDistinctFromRow() {
        let directoryURL = URL(fileURLWithPath: "/Users/example/Client Work/House.easysplatproj", isDirectory: true)
        let fileURL = URL(fileURLWithPath: directoryURL.path)

        let identifier = ProjectSidebar.actionAccessibilityIdentifier(for: directoryURL)

        XCTAssertEqual(identifier, ProjectSidebar.actionAccessibilityIdentifier(for: fileURL))
        XCTAssertTrue(identifier.hasPrefix("project.action."))
        XCTAssertEqual(identifier.count, "project.action.".count + 16)
        XCTAssertNotEqual(identifier, ProjectSidebar.rowAccessibilityIdentifier(for: directoryURL))
        XCTAssertFalse(identifier.contains("example"))
        XCTAssertFalse(identifier.contains("House"))
    }

    func testSidebarUserSelectionRejectsProjectsThatRequireExplicitAction() {
        let ready = makeSummary(title: "Ready", status: .ready)
        let failed = makeSummary(title: "Failed", status: .failed)
        let unfinished = makeSummary(title: "Unfinished", status: .inProgress)
        let readySelection = ProjectSidebar.selectionID(for: ready)

        XCTAssertEqual(
            ProjectSidebar.acceptedUserSelection(
                ProjectSidebar.selectionID(for: failed),
                current: readySelection,
                projects: [ready, failed, unfinished]
            ),
            readySelection
        )
        XCTAssertNil(ProjectSidebar.acceptedUserSelection(
            ProjectSidebar.selectionID(for: unfinished),
            current: nil,
            projects: [ready, failed, unfinished]
        ))
        XCTAssertEqual(
            ProjectSidebar.acceptedUserSelection(
                nil,
                current: readySelection,
                projects: [ready, failed, unfinished]
            ),
            readySelection
        )
        XCTAssertEqual(
            ProjectSidebar.acceptedUserSelection(
                readySelection,
                current: nil,
                projects: [ready, failed, unfinished]
            ),
            readySelection
        )
    }

    @MainActor
    func testSidebarKeepsCurrentSelectionWhenPendingNotesPreventOpeningAnotherProject() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let currentURL = base.appendingPathComponent("Current.easysplatproj", isDirectory: true)
        let nextURL = base.appendingPathComponent("Next.easysplatproj", isDirectory: true)
        let current = makeSummary(title: "Current", url: currentURL)
        let next = makeSummary(title: "Next", url: nextURL)
        let currentSelection = ProjectSidebar.selectionID(for: current)
        let model = AppModel(
            toolchainManager: SidebarTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = currentURL
        model.viewState = .viewer
        model.scheduleNotesSave(at: currentURL, to: "final keystroke")

        let selection = ProjectSidebar.selectionAfterOpening(
            ProjectSidebar.selectionID(for: next),
            current: currentSelection,
            projects: [current, next],
            open: { model.resumeProject(at: $0.url) }
        )

        XCTAssertEqual(selection, currentSelection)
        XCTAssertEqual(model.currentProjectURL, currentURL)
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t save notes")
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

    func testLastActivityUsesWorkCompletedAfterProjectWasOpened() {
        let project = makeSummary(
            createdAt: Date(timeIntervalSince1970: 100),
            stageTimings: [
                .init(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 400),
                    durationSeconds: 50
                )
            ],
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(project.lastActivityAt, Date(timeIntervalSince1970: 450))
    }

    func testLastActivityIncludesRunStartAndFailure() {
        let started = makeSummary(
            createdAt: Date(timeIntervalSince1970: 100),
            lastOpenedAt: Date(timeIntervalSince1970: 200),
            lastRunStartedAt: Date(timeIntervalSince1970: 300)
        )
        let failed = makeSummary(
            createdAt: Date(timeIntervalSince1970: 100),
            lastOpenedAt: Date(timeIntervalSince1970: 200),
            lastRunStartedAt: Date(timeIntervalSince1970: 300),
            lastFailureAt: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(started.lastActivityAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(failed.lastActivityAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(
            ProjectListSort.lastActivityNewest.apply(to: [started, failed]).map(\.id),
            [failed.id, started.id]
        )
    }

    func testSortByTitleAlphabeticalIsCaseInsensitive() {
        let zebra = makeSummary(title: "zebra")
        let apple = makeSummary(title: "Apple")
        let middle = makeSummary(title: "monkey")
        let sorted = ProjectListSort.titleAlphabetical.apply(to: [zebra, apple, middle])
        XCTAssertEqual(sorted.map(\.title), ["Apple", "monkey", "zebra"])
    }

    func testOnlyExceptionalStatesEarnARowCaption() {
        XCTAssertNil(ProjectSidebar.rowCaption(status: .ready, isInterrupted: false))
        XCTAssertEqual(ProjectSidebar.rowCaption(status: .inProgress, isInterrupted: false), "In Progress")
        XCTAssertEqual(ProjectSidebar.rowCaption(status: .failed, isInterrupted: false), "Failed")
        XCTAssertEqual(ProjectSidebar.rowCaption(status: .ready, isInterrupted: true), "Unfinished")
        XCTAssertEqual(ProjectSidebar.rowCaption(status: .inProgress, isInterrupted: true), "Unfinished")
    }

}

private struct SidebarTestToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        fatalError("Sidebar tests do not install a toolchain")
    }
}
