import Foundation
import XCTest
@testable import EasySplatApp

final class ViewerArtifactLoaderTests: XCTestCase {
    @MainActor
    func testLoadRunsVerificationOffTheMainThread() async {
        let loader = ViewerArtifactLoader<Int>()
        let request = request(named: "A")
        let completed = expectation(description: "load completed")
        let execution = LockedThreadObservation()
        var publishedValue: Int?

        loader.load(
            request,
            operation: { _ in
                execution.recordCurrentThread()
                return 17
            }
        ) { _, outcome in
            if case .success(let value) = outcome {
                publishedValue = value
            }
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(publishedValue, 17)
        XCTAssertEqual(execution.wasMainThread, false)
    }

    @MainActor
    func testNewerRequestSuppressesBlockedStaleSuccess() async {
        let loader = ViewerArtifactLoader<Int>()
        let first = request(named: "A")
        let second = request(named: "B")
        let firstStarted = expectation(description: "first load started")
        let firstFinished = expectation(description: "first load finished")
        let secondPublished = expectation(description: "second load published")
        let releaseFirst = DispatchSemaphore(value: 0)
        var publications: [(ViewerArtifactLoadRequest, Int)] = []

        loader.load(
            first,
            operation: { _ in
                firstStarted.fulfill()
                releaseFirst.wait()
                firstFinished.fulfill()
                return 1
            }
        ) { request, outcome in
            if case .success(let value) = outcome {
                publications.append((request, value))
            }
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        loader.load(second, operation: { _ in 2 }) { request, outcome in
            if case .success(let value) = outcome {
                publications.append((request, value))
                secondPublished.fulfill()
            }
        }
        await fulfillment(of: [secondPublished], timeout: 2)
        releaseFirst.signal()
        await fulfillment(of: [firstFinished], timeout: 2)
        await settleCancelledCompletion()

        XCTAssertEqual(publications.map(\.0), [second])
        XCTAssertEqual(publications.map(\.1), [2])
    }

    @MainActor
    func testNewerRequestSuppressesBlockedStaleFailure() async {
        let loader = ViewerArtifactLoader<Int>()
        let first = request(named: "A")
        let second = request(named: "B")
        let firstStarted = expectation(description: "first load started")
        let firstFinished = expectation(description: "first load finished")
        let secondPublished = expectation(description: "second load published")
        let releaseFirst = DispatchSemaphore(value: 0)
        var outcomes: [ViewerArtifactLoadOutcome<Int>] = []

        loader.load(
            first,
            operation: { _ in
                firstStarted.fulfill()
                releaseFirst.wait()
                firstFinished.fulfill()
                throw TestFailure.blockedRequestFailed
            }
        ) { _, outcome in
            outcomes.append(outcome)
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        loader.load(second, operation: { _ in 2 }) { _, outcome in
            outcomes.append(outcome)
            secondPublished.fulfill()
        }
        await fulfillment(of: [secondPublished], timeout: 2)
        releaseFirst.signal()
        await fulfillment(of: [firstFinished], timeout: 2)
        await settleCancelledCompletion()

        XCTAssertEqual(outcomes.count, 1)
        guard case .success(2) = outcomes[0] else {
            return XCTFail("Only the newer success may be published")
        }
    }

    private func request(named name: String) -> ViewerArtifactLoadRequest {
        let project = URL(fileURLWithPath: "/tmp/\(name).easysplatproj", isDirectory: true)
        return ViewerArtifactLoadRequest(
            projectURL: project,
            outputURL: project.appendingPathComponent("Output/splat.ply")
        )
    }

    @MainActor
    private func settleCancelledCompletion() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private enum TestFailure: Error {
    case blockedRequestFailed
}

private final class LockedThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasMainThread: Bool? {
        lock.withLock { value }
    }

    func recordCurrentThread() {
        lock.withLock {
            value = Thread.isMainThread
        }
    }
}
