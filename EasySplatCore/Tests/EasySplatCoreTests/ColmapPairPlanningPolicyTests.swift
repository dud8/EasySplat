#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapPairPlanningPolicyTests: XCTestCase {
    func testSelectedFrameGroupsPreserveClipBoundariesAndPhotoGroup() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "p0.jpg"]
        let manifest = [
            mapping("a0.jpg", group: "video_000", video: true),
            mapping("a1.jpg", group: "video_000", video: true),
            mapping("b0.jpg", group: "video_001", video: true),
            mapping("p0.jpg", group: "photos", video: false),
        ]

        let groups = try PipelineRunner.colmapPairGroups(
            imageNames: names,
            manifest: manifest
        )

        XCTAssertEqual(groups, [
            ColmapPairGroup(imageNames: ["a0.jpg", "a1.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["b0.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["p0.jpg"], isVideo: false),
        ])
    }

    func testSelectedFrameGroupsRejectInconsistentManifest() {
        XCTAssertThrowsError(try PipelineRunner.colmapPairGroups(
            imageNames: ["a.jpg", "b.jpg"],
            manifest: [
                mapping("a.jpg", group: "same", video: true),
                mapping("b.jpg", group: "same", video: false),
            ]
        ))
    }

    func testNormalContinuousPlanUsesExactMultiscaleScheduleAndSparseQueries() throws {
        let names = (0..<250).map { String(format: "frame_%06d.jpg", $0) }
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16, 32, 64, 128],
            neighbors: 2,
            stride: 10
        )
        let pairs = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let retrieval = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        XCTAssertEqual(pairs.pairs.count, 1_745)
        XCTAssertEqual(retrieval.queryImageNames.count, 25)
        XCTAssertEqual(retrieval.queryImageNames.first, names.first)
        XCTAssertEqual(retrieval.queryImageNames.last, names[240])
        XCTAssertEqual(retrieval.candidateCount, 20)
        XCTAssertEqual(retrieval.returnedNeighborCount, 2)
        XCTAssertEqual(retrieval.minimumFrameSeparation, 25)
    }

    func testShortGenericSequenceDoesNotPayForRetrieval() {
        let names = (0..<119).map { "frame_\($0).jpg" }
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16, 32, 64],
            neighbors: 2,
            stride: 10
        )

        XCTAssertNil(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
    }

    func testExplicitContinuousPhotoSequenceReceivesTemporalPairs() throws {
        let names = (0..<12).map { "photo_\($0).jpg" }
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8],
            neighbors: 2,
            stride: 10
        )

        let pairs = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: [ColmapPairGroup(imageNames: names, isVideo: false)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        )

        XCTAssertEqual(pairs.pairs.count, 33)
        XCTAssertTrue(pairs.pairs.allSatisfy { $0.role == .local })
    }

    func testSegmentedPlanKeepsTemporalEdgesInsideClipsAndRetrievesAcrossInput() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "b1.jpg", "photo.jpg"]
        let groups = [
            ColmapPairGroup(imageNames: ["a0.jpg", "a1.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["b0.jpg", "b1.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["photo.jpg"], isVideo: false),
        ]
        let plan = resolvedPlan(
            policy: .segmentedMixed,
            temporal: .linear,
            offsets: Array(1...6),
            neighbors: 8,
            stride: 1
        )

        let pairs = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let retrieval = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        XCTAssertEqual(pairs.pairLines, ["a0.jpg a1.jpg", "b0.jpg b1.jpg"])
        XCTAssertEqual(retrieval.queryImageNames, names)
        XCTAssertEqual(retrieval.minimumFrameSeparation, 0)
    }

    func testUnorderedThresholdAndRecoveryLadder() throws {
        let sixty = (0..<60).map { "photo_\($0).jpg" }
        let sixtyOne = (0..<61).map { "photo_\($0).jpg" }
        let plan = resolvedPlan(
            policy: .unorderedRetrieval,
            temporal: .none,
            offsets: [],
            neighbors: 8,
            stride: 1
        )

        let exhaustive = try PipelineRunner.baseColmapPairPlan(
            imageNames: sixty,
            groups: [ColmapPairGroup(imageNames: sixty, isVideo: false)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        XCTAssertEqual(exhaustive.pairs.count, 1_770)
        XCTAssertNil(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: sixty,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        let expanded = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: sixtyOne,
            resolvedPlan: plan,
            recoveryLevel: .expanded
        ))
        XCTAssertEqual(expanded.candidateCount, 40)
        XCTAssertEqual(expanded.returnedNeighborCount, 16)

        let maximumAt250 = try PipelineRunner.baseColmapPairPlan(
            imageNames: (0..<250).map { "p_\($0).jpg" },
            groups: [],
            resolvedPlan: plan,
            recoveryLevel: .maximum
        )
        XCTAssertEqual(maximumAt250.pairs.count, 31_125)

        let over250 = (0..<251).map { "p_\($0).jpg" }
        let maximumRequest = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: over250,
            resolvedPlan: plan,
            recoveryLevel: .maximum
        ))
        XCTAssertEqual(maximumRequest.candidateCount, 80)
        XCTAssertEqual(maximumRequest.returnedNeighborCount, 32)
    }

    func testAlreadyExhaustiveFaissPlanSkipsRedundantDensityRetries() {
        XCTAssertNil(PipelineRunner.nextPairRecoveryLevel(
            after: .normal,
            imageCount: 60,
            pairingPolicy: .unorderedRetrieval
        ))
        XCTAssertEqual(
            PipelineRunner.nextPairRecoveryLevel(
                after: .normal,
                imageCount: 61,
                pairingPolicy: .unorderedRetrieval
            ),
            .expanded
        )
        XCTAssertEqual(
            PipelineRunner.nextPairRecoveryLevel(
                after: .expanded,
                imageCount: 250,
                pairingPolicy: .unorderedRetrieval
            ),
            .maximum
        )
    }

    func testMinorVerifiedComponentsRequireOrderedInputAndOneDensityRetry() {
        for policy in [
            ResolvedPairingPolicy.orderedContinuous,
            .orderedOrbit,
            .orderedWalkthrough,
            .orderedLargeArea,
        ] {
            XCTAssertFalse(PipelineRunner.allowsMinorVerifiedComponents(
                pairingPolicy: policy,
                recoveryLevel: .normal
            ))
            XCTAssertTrue(PipelineRunner.allowsMinorVerifiedComponents(
                pairingPolicy: policy,
                recoveryLevel: .expanded
            ))
            XCTAssertTrue(PipelineRunner.allowsMinorVerifiedComponents(
                pairingPolicy: policy,
                recoveryLevel: .maximum
            ))
        }

        for policy in [
            ResolvedPairingPolicy.unorderedRetrieval,
            .segmentedMixed,
        ] {
            XCTAssertFalse(PipelineRunner.allowsMinorVerifiedComponents(
                pairingPolicy: policy,
                recoveryLevel: .expanded
            ))
            XCTAssertFalse(PipelineRunner.allowsMinorVerifiedComponents(
                pairingPolicy: policy,
                recoveryLevel: .maximum
            ))
        }

        let minorVerifiedComponents = [57, 2, 1]
        XCTAssertFalse(PipelineRunner.permitsAcceptedComponentShape(
            minorVerifiedComponents,
            pairingPolicy: .orderedContinuous,
            recoveryLevel: .normal
        ))
        XCTAssertTrue(PipelineRunner.permitsAcceptedComponentShape(
            minorVerifiedComponents,
            pairingPolicy: .orderedContinuous,
            recoveryLevel: .expanded
        ))
        XCTAssertFalse(PipelineRunner.permitsAcceptedComponentShape(
            minorVerifiedComponents,
            pairingPolicy: .unorderedRetrieval,
            recoveryLevel: .maximum
        ))
        XCTAssertTrue(PipelineRunner.permitsAcceptedComponentShape(
            [54, 1, 1, 1, 1, 1, 1],
            pairingPolicy: .unorderedRetrieval,
            recoveryLevel: .normal
        ))
    }

    func testRetrievalOutputRequiresDirectedQueriesAndNovelBoundedPairs() throws {
        let names = (0..<20).map { "frame_\($0).jpg" }
        let base = try ColmapPairPlan.temporal(
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
            offsets: [1]
        )
        let request = PipelineRunner.VocabularyRetrievalRequest(
            queryImageNames: [names[0], names[10]],
            candidateCount: 20,
            returnedNeighborCount: 2,
            minimumFrameSeparation: 2
        )

        let validated = try PipelineRunner.validatedVocabularyRetrievalPairLines(
            [
                "\(names[0]) \(names[5])",
                "\(names[0]) \(names[6])",
                "\(names[10]) \(names[2])",
            ],
            request: request,
            imageNames: names,
            excluding: base
        )
        XCTAssertEqual(validated.count, 3)

        for invalid in [
            ["\(names[5]) \(names[0])"],
            ["\(names[0]) \(names[1])"],
            ["\(names[0]) \(names[5])", "\(names[0]) \(names[6])", "\(names[0]) \(names[7])"],
            ["\(names[0]) \(names[5])", "\(names[10]) \(names[5])", "\(names[10]) \(names[0])", "\(names[0]) \(names[6])", "\(names[10]) \(names[6])"],
        ] {
            XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalPairLines(
                invalid,
                request: request,
                imageNames: names,
                excluding: base
            ))
        }
    }

    private func mapping(
        _ name: String,
        group: String,
        video: Bool
    ) -> PipelineRunner.SelectedFrameMapping {
        PipelineRunner.SelectedFrameMapping(
            outputFileName: name,
            groupId: group,
            isVideo: video,
            timestampSeconds: video
                ? Double(name.filter(\.isNumber)) ?? 0
                : nil
        )
    }

    private func resolvedPlan(
        policy: ResolvedPairingPolicy,
        temporal: TemporalPairing,
        offsets: [Int],
        neighbors: Int,
        stride: Int
    ) -> ResolvedRunPlan {
        ResolvedRunPlan(
            routeIdentifier: "colmap",
            modelIdentifier: "none",
            memoryTier: "standard",
            chunkSize: 0,
            keyframeBudget: 250,
            maximumImageDimension: 1_024,
            cameraGrouping: .automatic,
            lensProjection: .automatic,
            refinementIterationLimit: 75,
            trainerIterationLimit: 3_000,
            plateauWindow: 400,
            trainerMemoryBudgetBytes: 1_024 * 1_024 * 1_024,
            geometryWorkerBudget: GeometryWorkerBudget(
                featureExtractionWorkers: 12,
                coupledMatchingWorkers: 8,
                vocabularyRetrievalWorkers: 8,
                maximumConcurrentVideoSourceAnalysisTasks: 4
            ),
            requiredToolchainCapabilities: ["geometry.colmap", "runtime.core", "training.msplat"],
            fallbackRouteIdentifiers: [],
            pairingPolicy: policy,
            temporalPairing: temporal,
            temporalOffsets: offsets,
            retrievalCandidateCount: 20,
            retrievalNeighborCount: neighbors,
            retrievalQueryStride: stride
        )
    }
}
#endif
