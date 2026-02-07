#if canImport(XCTest)
import XCTest
@testable import EasySplatApp

final class PreviewReloadPlannerTests: XCTestCase {
    func testCoalescesQueuedRequestsToLatestWhileLoadInFlight() {
        var planner = PreviewReloadPlanner()
        let now = Date()
        let url = URL(fileURLWithPath: "/tmp/latest_snapshot.ply")
        let request1 = PreviewLoadRequest(url: url, reloadToken: 1)
        let request2 = PreviewLoadRequest(url: url, reloadToken: 2)
        let request3 = PreviewLoadRequest(url: url, reloadToken: 3)

        planner.request(request1)
        XCTAssertEqual(planner.nextDecision(now: now), .start(request: request1, forceReload: false))

        planner.request(request2)
        planner.request(request3)
        XCTAssertEqual(planner.nextDecision(now: now), .none)

        planner.completeInFlight()
        XCTAssertEqual(planner.nextDecision(now: now), .start(request: request3, forceReload: true))
    }

    func testDefersReloadWhileUserIsInteracting() {
        var planner = PreviewReloadPlanner()
        let now = Date()
        let request = PreviewLoadRequest(url: URL(fileURLWithPath: "/tmp/latest_snapshot.ply"), reloadToken: 4)
        planner.request(request)
        planner.recordInteraction(now: now)

        let decision = planner.nextDecision(now: now)
        switch decision {
        case .deferLoad(let delay):
            XCTAssertGreaterThanOrEqual(delay, 1.19)
            XCTAssertLessThanOrEqual(delay, 1.2)
        default:
            XCTFail("Expected reload deferral while interacting.")
        }

        XCTAssertEqual(planner.nextDecision(now: now.addingTimeInterval(1.3)), .start(request: request, forceReload: false))
    }

    func testStartsImmediatelyWhenIdleAndNoInflightLoad() {
        var planner = PreviewReloadPlanner()
        let request = PreviewLoadRequest(url: URL(fileURLWithPath: "/tmp/latest_snapshot.ply"), reloadToken: 9)
        planner.request(request)

        XCTAssertEqual(planner.nextDecision(now: Date()), .start(request: request, forceReload: false))
    }
}
#endif
