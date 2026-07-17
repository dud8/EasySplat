#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapPairEstimatorTests: XCTestCase {
    func testTemporalPairPlanningHonorsTaskCancellation() async {
        let task = Task<ColmapPairPlan, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ColmapPairPlan.temporal(
                groups: [ColmapPairGroup(imageNames: ["a.jpg", "b.jpg"], isVideo: true)],
                offsets: [1]
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

    func testMultiscalePlanSchedulesExactly1745PairsAt250Views() throws {
        let names = (0..<250).map { String(format: "frame_%06d.jpg", $0) }
        let plan = try ColmapPairPlan.temporal(
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
            offsets: [1, 2, 4, 8, 16, 32, 64, 128]
        )

        XCTAssertEqual(plan.pairs.count, 1_745)
        XCTAssertEqual(plan.localPairCount, 1_745)
        XCTAssertEqual(plan.retrievalPairCount, 0)
        XCTAssertEqual(plan.loopRevisitPairCount, 0)
        XCTAssertEqual(plan.sha256.count, 64)
        XCTAssertTrue(plan.validates(plan.serializedData))
    }

    func testSegmentedPlanNeverCreatesTemporalEdgesAcrossClipsOrPhotos() throws {
        let plan = try ColmapPairPlan.temporal(
            groups: [
                ColmapPairGroup(imageNames: ["a0.jpg", "a1.jpg", "a2.jpg"], isVideo: true),
                ColmapPairGroup(imageNames: ["b0.jpg", "b1.jpg"], isVideo: true),
                ColmapPairGroup(imageNames: ["p0.jpg", "p1.jpg"], isVideo: false),
            ],
            offsets: [1, 2, 3, 4, 5, 6]
        )

        XCTAssertEqual(plan.pairLines, [
            "a0.jpg a1.jpg",
            "a0.jpg a2.jpg",
            "a1.jpg a2.jpg",
            "b0.jpg b1.jpg",
        ])
        XCTAssertFalse(plan.pairLines.contains("a2.jpg b0.jpg"))
        XCTAssertFalse(plan.pairLines.contains("p0.jpg p1.jpg"))
    }

    func testRetrievalUnionDeduplicatesTemporalPairsAndFiltersNearOrderedCandidates() throws {
        let names = (0..<100).map { String(format: "frame_%03d.jpg", $0) }
        let temporal = try ColmapPairPlan.temporal(
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
            offsets: [1]
        )
        let result = try temporal.addingRetrievalPairLines(
            [
                "frame_000.jpg frame_001.jpg",
                "frame_000.jpg frame_011.jpg",
                "frame_000.jpg frame_012.jpg",
                "frame_099.jpg frame_000.jpg",
            ],
            pairingPolicy: .orderedContinuous
        )

        XCTAssertEqual(result.pairs.count, temporal.pairs.count + 2)
        XCTAssertEqual(result.loopRevisitPairCount, 2)
        XCTAssertTrue(result.pairLines.contains("frame_000.jpg frame_012.jpg"))
        XCTAssertTrue(result.pairLines.contains("frame_000.jpg frame_099.jpg"))
        XCTAssertFalse(result.pairLines.contains("frame_000.jpg frame_011.jpg"))
    }

    func testExhaustivePlanIsDeterministicAndClassifiedAsRetrieval() throws {
        let names = (0..<61).map { String(format: "photo_%03d.jpg", $0) }
        let first = try ColmapPairPlan.exhaustive(imageNames: names)
        let second = try ColmapPairPlan.exhaustive(imageNames: names)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pairs.count, 1_830)
        XCTAssertEqual(first.retrievalPairCount, 1_830)
        XCTAssertEqual(first.localPairCount, 0)
        XCTAssertEqual(first.loopRevisitPairCount, 0)
    }

    func testEmptyPlanCanReceiveRetrievalPairsWithoutTemporalAssumptions() throws {
        let names = ["photo_a.jpg", "photo_b.jpg", "photo_c.jpg"]
        let empty = try ColmapPairPlan.empty(imageNames: names)

        XCTAssertTrue(empty.pairs.isEmpty)
        XCTAssertTrue(empty.validates(Data()))

        let retrieved = try empty.addingRetrievalPairLines(
            ["photo_c.jpg photo_a.jpg", "photo_a.jpg photo_c.jpg"],
            pairingPolicy: .unorderedRetrieval
        )
        XCTAssertEqual(retrieved.pairLines, ["photo_a.jpg photo_c.jpg"])
        XCTAssertEqual(retrieved.retrievalPairCount, 1)
    }

    func testPersistedPairPlanRestoresCanonicalSchedule() throws {
        let source = try ColmapPairPlan.exhaustive(
            imageNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        )

        let restored = try ColmapPairPlan.persisted(
            imageNames: source.imageNames,
            scheduledPairs: source.pairs
        )

        XCTAssertEqual(restored, source)
        XCTAssertTrue(restored.validates(restored.serializedData))
    }

    func testPersistedPairPlanRejectsNoncanonicalOrInvalidSchedule() throws {
        let source = try ColmapPairPlan.exhaustive(
            imageNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        )
        var reversedPair = source.pairs
        reversedPair[0] = ColmapScheduledPair(
            reversedPair[0].secondImageName,
            reversedPair[0].firstImageName,
            role: reversedPair[0].role
        )
        var unknownPair = source.pairs
        unknownPair[0] = ColmapScheduledPair("a.jpg", "unknown.jpg", role: .retrieval)
        let invalidSchedules = [
            Array(source.pairs.reversed()),
            reversedPair,
            unknownPair,
            source.pairs + [source.pairs[0]],
        ]

        for scheduledPairs in invalidSchedules {
            XCTAssertThrowsError(try ColmapPairPlan.persisted(
                imageNames: source.imageNames,
                scheduledPairs: scheduledPairs
            )) {
                XCTAssertEqual($0 as? ColmapPairPlanningError, .invalidPairPlan)
            }
        }
    }

    func testConnectivityRejectsSchedulesThatCannotPossiblyJoinAllViews() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "b1.jpg"]
        let segmented = try ColmapPairPlan.temporal(
            groups: [
                ColmapPairGroup(imageNames: Array(names[0...1]), isVideo: true),
                ColmapPairGroup(imageNames: Array(names[2...3]), isVideo: true),
            ],
            offsets: [1]
        )

        XCTAssertFalse(segmented.isConnected)

        let joined = try segmented.addingRetrievalPairLines(
            ["a1.jpg b0.jpg"],
            pairingPolicy: .segmentedMixed
        )
        XCTAssertTrue(joined.isConnected)
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
            XCTAssertEqual(
                error as? ColmapPairPlanningError,
                .disconnectedPairSchedule
            )
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
