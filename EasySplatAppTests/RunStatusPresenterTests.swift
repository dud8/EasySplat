import XCTest
@testable import EasySplatApp
import EasySplatCore

@MainActor
final class RunStatusPresenterTests: XCTestCase {
    func testRunOutcomeComesOnlyFromEventsObservedDuringTheRun() {
        XCTAssertEqual(
            RunStatusPresenter.outcome(sawFailure: false, sawCompletion: true),
            .finished
        )
        XCTAssertEqual(
            RunStatusPresenter.outcome(sawFailure: true, sawCompletion: false),
            .failed
        )
        // A failure observed during the run wins even if a completion also
        // slipped through.
        XCTAssertEqual(
            RunStatusPresenter.outcome(sawFailure: true, sawCompletion: true),
            .failed
        )
        // No events during the active period — e.g. opening an
        // already-finished project, which toggles isRunActive without running
        // a pipeline — must read as a stop, never a completion.
        XCTAssertEqual(
            RunStatusPresenter.outcome(sawFailure: false, sawCompletion: false),
            .stopped
        )
    }

    func testNotificationsFireOnlyWhenUnattendedAndNeverForUserStops() {
        XCTAssertTrue(RunStatusPresenter.shouldNotify(isUserAttending: false, outcome: .finished))
        XCTAssertTrue(RunStatusPresenter.shouldNotify(isUserAttending: false, outcome: .failed))
        XCTAssertFalse(RunStatusPresenter.shouldNotify(isUserAttending: false, outcome: .stopped))
        XCTAssertFalse(RunStatusPresenter.shouldNotify(isUserAttending: true, outcome: .finished))
        XCTAssertFalse(RunStatusPresenter.shouldNotify(isUserAttending: true, outcome: .failed))
        XCTAssertFalse(RunStatusPresenter.shouldNotify(isUserAttending: true, outcome: .stopped))
    }

    func testNotificationTitlesExistExactlyForNotifiableOutcomes() {
        XCTAssertEqual(RunStatusPresenter.notificationTitle(for: .finished), "Splat ready")
        XCTAssertEqual(
            RunStatusPresenter.notificationTitle(for: .failed),
            "Couldn’t finish this splat"
        )
        XCTAssertNil(RunStatusPresenter.notificationTitle(for: .stopped))
    }
}
