import XCTest
@testable import EasySplatCore

final class VideoSourceAnalysisConcurrencyMeterTests: XCTestCase {
    func testPrecancelledMeasurementDoesNotStartOrClaimWork() async throws {
        let meter = VideoSourceAnalysisConcurrencyMeter()
        let invocation = InvocationFlag()
        let task = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await meter.measure {
                await invocation.markInvoked()
                return 1
            }
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected before the operation starts.
        }
        let wasInvoked = await invocation.wasInvoked
        XCTAssertFalse(wasInvoked)
        XCTAssertEqual(
            meter.snapshot(),
            VideoSourceAnalysisConcurrencySnapshot(
                startedAnalysisTaskCount: 0,
                peakInFlightAnalysisTaskCount: 0
            )
        )
    }

    func testMeasuresExecutedTaskCountAndPeakConcurrency() async throws {
        let meter = VideoSourceAnalysisConcurrencyMeter()
        let gate = ArrivalGate(target: 3)

        async let first: Int = meter.measure {
            await gate.arriveAndWait()
            return 1
        }
        async let second: Int = meter.measure {
            await gate.arriveAndWait()
            return 2
        }
        async let third: Int = meter.measure {
            await gate.arriveAndWait()
            return 3
        }

        let values = try await [first, second, third]
        XCTAssertEqual(values.sorted(), [1, 2, 3])
        XCTAssertEqual(
            meter.snapshot(),
            VideoSourceAnalysisConcurrencySnapshot(
                startedAnalysisTaskCount: 3,
                peakInFlightAnalysisTaskCount: 3
            )
        )
    }

    func testSequentialTasksKeepPeakAtOne() async throws {
        let meter = VideoSourceAnalysisConcurrencyMeter()

        _ = try await meter.measure { 1 }
        _ = try await meter.measure { 2 }

        XCTAssertEqual(
            meter.snapshot(),
            VideoSourceAnalysisConcurrencySnapshot(
                startedAnalysisTaskCount: 2,
                peakInFlightAnalysisTaskCount: 1
            )
        )
    }
}

private actor InvocationFlag {
    private(set) var wasInvoked = false

    func markInvoked() {
        wasInvoked = true
    }
}

private actor ArrivalGate {
    private let target: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func arriveAndWait() async {
        arrivalCount += 1
        if arrivalCount == target {
            let currentWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in currentWaiters {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
