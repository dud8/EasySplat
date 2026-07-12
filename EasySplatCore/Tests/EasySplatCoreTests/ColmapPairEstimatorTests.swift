#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapPairEstimatorTests: XCTestCase {
    func testRetrievalPairPlanningHonorsTaskCancellation() async {
        let task = Task<[String], Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ColmapPairEstimator.boundedRetrievalPairs(
                imageNames: ["a.jpg", "b.jpg"],
                descriptors: [[1, 0], [1, 0]],
                maxNeighbors: 1,
                minimumSimilarity: 0.5
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled pair planning must stop before the all-pairs loop.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExpectedSequentialPairs() {
        XCTAssertEqual(ColmapPairEstimator.expectedSequentialPairs(imageCount: 96, overlap: 10), 905)
    }

    func testExpectedExhaustivePairs() {
        XCTAssertEqual(ColmapPairEstimator.expectedExhaustivePairs(imageCount: 96), 4560)
    }

    func testBoundedRetrievalPairsAreDeterministicAtFiveHundredViews() throws {
        let names = (0..<500).map { String(format: "frame_%06d.jpg", $0) }
        let descriptors = (0..<500).map { index in
            let angle = Double(index) * .pi * 2.0 / 500.0
            return [cos(angle), sin(angle), 0.25]
        }

        let first = try ColmapPairEstimator.boundedRetrievalPairs(
            imageNames: names,
            descriptors: descriptors,
            maxNeighbors: 8,
            minimumSimilarity: 0.7
        )
        let second = try ColmapPairEstimator.boundedRetrievalPairs(
            imageNames: names,
            descriptors: descriptors,
            maxNeighbors: 8,
            minimumSimilarity: 0.7
        )

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, 4_000)
        XCTAssertGreaterThanOrEqual(first.count, 499)
    }

    func testBoundedRetrievalPairsRejectDisconnectedSceneGraph() {
        let names = (0..<6).map { "image_\($0).jpg" }
        let descriptors = [
            [1.0, 0.0, 0.0], [0.99, 0.1, 0.0], [0.98, 0.2, 0.0],
            [0.0, 0.0, 1.0], [0.0, 0.1, 0.99], [0.0, 0.2, 0.98],
        ]

        XCTAssertThrowsError(try ColmapPairEstimator.boundedRetrievalPairs(
            imageNames: names,
            descriptors: descriptors,
            maxNeighbors: 2
        )) { error in
            XCTAssertEqual(error as? ColmapPairPlanningError, .disconnectedGraph)
        }
    }

    func testOrderedLoopPairsIncludeVerifiedFirstLastAndDistantNeighbor() throws {
        let names = (0..<10).map { "frame_\($0).jpg" }
        let descriptors = [
            [1.0, 0.0, 0.0],
            [0.8, 0.2, 0.0],
            [0.0, 1.0, 0.0],
            [0.2, 0.8, 0.0],
            [0.4, 0.6, 0.0],
            [0.6, 0.4, 0.0],
            [0.2, 0.8, 0.0],
            [0.0, 1.0, 0.0],
            [0.8, 0.2, 0.0],
            [1.0, 0.0, 0.0],
        ]

        let pairs = try ColmapPairEstimator.orderedLoopPairs(
            imageNames: names,
            descriptors: descriptors,
            minimumSeparation: 4,
            maxNeighbors: 1,
            minimumSimilarity: 0.95
        )

        XCTAssertTrue(pairs.contains("frame_0.jpg frame_9.jpg"))
        XCTAssertTrue(pairs.contains("frame_2.jpg frame_7.jpg"))
        XCTAssertFalse(pairs.contains("frame_0.jpg frame_1.jpg"))
        XCTAssertEqual(pairs, pairs.sorted())
    }

    func testDa3RefinementPairPlanUnionsLoopsAndBindsSerializedDigest() throws {
        let names = (0..<8).map { "frame_\($0).jpg" }
        let localPairs = (0..<7).map { "frame_\($0).jpg frame_\($0 + 1).jpg" }
        let loopPairs = [
            "frame_0.jpg frame_7.jpg",
            "frame_1.jpg frame_6.jpg",
        ]

        let first = try ColmapPairEstimator.da3RefinementPairPlan(
            imageNames: names,
            localPairs: localPairs,
            loopPairs: loopPairs,
            maxPairCount: 20
        )
        let second = try ColmapPairEstimator.da3RefinementPairPlan(
            imageNames: names,
            localPairs: Array(localPairs.reversed()),
            loopPairs: Array(loopPairs.reversed()),
            maxPairCount: 20
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.localPairCount, 7)
        XCTAssertEqual(first.loopPairCount, 2)
        XCTAssertEqual(first.pairs.count, 9)
        XCTAssertTrue(first.pairs.contains("frame_0.jpg frame_7.jpg"))
        XCTAssertTrue(first.validates(first.serializedData))
        XCTAssertEqual(first.sha256.count, 64)

        var tampered = first.serializedData
        tampered.append(0x0A)
        XCTAssertFalse(first.validates(tampered))
    }

    func testDa3RefinementPairPlanRejectsDisconnectedAndOversizedGraphs() {
        let names = (0..<5).map { "frame_\($0).jpg" }
        let disconnected = [
            "frame_0.jpg frame_1.jpg",
            "frame_1.jpg frame_2.jpg",
            "frame_3.jpg frame_4.jpg",
        ]

        XCTAssertThrowsError(try ColmapPairEstimator.da3RefinementPairPlan(
            imageNames: names,
            localPairs: disconnected,
            loopPairs: [],
            maxPairCount: 10
        )) { error in
            XCTAssertEqual(error as? ColmapPairPlanningError, .disconnectedGraph)
        }

        XCTAssertThrowsError(try ColmapPairEstimator.da3RefinementPairPlan(
            imageNames: names,
            localPairs: [
                "frame_0.jpg frame_1.jpg",
                "frame_1.jpg frame_2.jpg",
                "frame_2.jpg frame_3.jpg",
                "frame_3.jpg frame_4.jpg",
            ],
            loopPairs: [],
            maxPairCount: 3
        )) { error in
            XCTAssertEqual(error as? ColmapPairPlanningError, .pairLimitExceeded)
        }
    }
}
#endif
