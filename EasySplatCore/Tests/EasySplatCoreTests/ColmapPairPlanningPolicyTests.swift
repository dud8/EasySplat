#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapPairPlanningPolicyTests: XCTestCase {
    func testSelectedFrameGroupsPreserveClipBoundariesAndPhotoGroup() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "p0.jpg", "p1.jpg"]
        let manifest = [
            mapping("a0.jpg", group: "video_000", video: true),
            mapping("a1.jpg", group: "video_000", video: true),
            mapping("b0.jpg", group: "video_001", video: true),
            mapping("p0.jpg", group: "photos", video: false),
            mapping("p1.jpg", group: "photos", video: false),
        ]

        let groups = try PipelineRunner.colmapPairGroups(
            imageNames: names,
            manifest: manifest
        )

        XCTAssertEqual(groups, [
            ColmapPairGroup(imageNames: ["a0.jpg", "a1.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["b0.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["p0.jpg", "p1.jpg"], isVideo: false),
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

    func testCameraGroupingEvidenceUsesManifestSourceIdentityAndResolvedPolicy() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "photo.jpg"]
        let manifest = [
            mapping("a0.jpg", group: "video_000", video: true),
            mapping("a1.jpg", group: "video_000", video: true),
            mapping("b0.jpg", group: "video_001", video: true),
            mapping("photo.jpg", group: "photos", video: false),
        ]

        let evidence = try PipelineRunner.colmapCameraGroupingEvidence(
            imageNames: names,
            manifest: manifest
        )

        XCTAssertEqual(evidence.map(\.imageName), names)
        XCTAssertEqual(evidence.map(\.sourceGroupID), [
            "video_000", "video_000", "video_001", "photos",
        ])
        XCTAssertEqual(evidence.map(\.isVideo), [true, true, true, false])
        XCTAssertEqual(
            PipelineRunner.colmapCameraGroupingMode(
                cameraGrouping: .mixedCamerasOrLenses,
                evidence: evidence
            ),
            .videoSourceGroups
        )
        XCTAssertEqual(
            PipelineRunner.colmapCameraGroupingMode(
                cameraGrouping: .sameCameraAndLens,
                evidence: evidence
            ),
            .allSelectedImagesShared
        )
    }

    func testPhotoOnlyAutomaticCameraGroupingPreservesColmapAssignments() throws {
        let names = ["a.jpg", "b.jpg"]
        let evidence = try PipelineRunner.colmapCameraGroupingEvidence(
            imageNames: names,
            manifest: names.map { mapping($0, group: "photos", video: false) }
        )

        XCTAssertEqual(
            PipelineRunner.colmapCameraGroupingMode(
                cameraGrouping: .mixedCamerasOrLenses,
                evidence: evidence
            ),
            .preserveExisting
        )
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
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
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
        XCTAssertNil(retrieval.imageGroupContract)
    }

    func testCrossClipRetrievalAppliesStrideInsideEveryUnevenClip() throws {
        let firstClip = (0..<17).map { "a\($0).jpg" }
        let secondClip = (0..<3).map { "b\($0).jpg" }
        let names = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16],
            neighbors: 2,
            stride: 10,
            requiresCrossClipRetrieval: true
        )

        let retrieval = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        XCTAssertEqual(retrieval.queryImageNames, ["a0.jpg", "a10.jpg", "b0.jpg"])
        XCTAssertEqual(retrieval.minimumFrameSeparation, 0)
        let groupContract = try XCTUnwrap(retrieval.imageGroupContract)
        XCTAssertEqual(groupContract.policy, .crossGroupV1)
        XCTAssertEqual(
            groupContract.canonicalLines,
            (firstClip.map { "\($0)\t0" } + secondClip.map { "\($0)\t1" })
                .sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
        )
        XCTAssertEqual(
            groupContract.digest,
            PairGraphEvidenceStore.imageGroupListDigest(
                policy: .crossGroupV1,
                canonicalLines: groupContract.canonicalLines
            )
        )
        XCTAssertEqual(
            groupContract.serializedData,
            Data((groupContract.canonicalLines.joined(separator: "\n") + "\n").utf8)
        )
    }

    func testCrossClipRetrievalQueriesEveryClipBelowGlobalSeparationThreshold() throws {
        let firstClip = (0..<7).map { "a\($0).jpg" }
        let secondClip = (0..<3).map { "b\($0).jpg" }
        let names = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4],
            neighbors: 2,
            stride: 10,
            requiresCrossClipRetrieval: true
        )

        let retrieval = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        XCTAssertEqual(retrieval.queryImageNames, ["a0.jpg", "b0.jpg"])
        XCTAssertEqual(retrieval.minimumFrameSeparation, 0)
    }

    func testCrossClipRetrievalKeepsRankedNeighborsAcrossAdjacentClipBoundary() throws {
        let firstClip = (0..<17).map { "a\($0).jpg" }
        let secondClip = (0..<3).map { "b\($0).jpg" }
        let names = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16],
            neighbors: 2,
            stride: 10,
            requiresCrossClipRetrieval: true
        )
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        let outcomes = [
            PairGraphRetrievalQueryOutcome(
                queryImageName: "a0.jpg",
                status: .ranked,
                rankedNeighborImageNames: ["b0.jpg"]
            ),
            PairGraphRetrievalQueryOutcome(
                queryImageName: "a10.jpg",
                status: .ranked,
                rankedNeighborImageNames: ["b0.jpg"]
            ),
            PairGraphRetrievalQueryOutcome(
                queryImageName: "b0.jpg",
                status: .ranked,
                rankedNeighborImageNames: ["a16.jpg"]
            ),
        ]
        let pairLines = outcomes.map {
            "\($0.queryImageName) \($0.rankedNeighborImageNames[0])"
        }.sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
        let evidence = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            candidatePolicy: request.imageGroupContract?.policy,
            imageGroupListDigest: request.imageGroupContract?.digest,
            imageGroupLines: request.imageGroupContract?.canonicalLines,
            queryOutcomes: outcomes,
            directedPairLines: pairLines
        )

        let parsed = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(evidence),
            engine: .localSiftVocabularyV2,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        )
        let joined = try base.addingRetrievalPairLines(
            parsed.directedPairLines,
            pairingPolicy: .orderedContinuous,
            groups: groups,
            requiresCrossClipRetrieval: true
        )

        XCTAssertTrue(joined.pairLines.contains("a16.jpg b0.jpg"))
        XCTAssertFalse(base.pairLines.contains("a16.jpg b0.jpg"))
        XCTAssertEqual(parsed.candidatePolicy, .crossGroupV1)
        XCTAssertEqual(
            parsed.imageGroupListDigest,
            request.imageGroupContract?.digest
        )
        XCTAssertTrue(
            PairGraphEvidenceStore.retrievalContractLines(parsed)[0]
                .hasPrefix("EASYSPLAT_RETRIEVAL_OUTCOMES_V3 ")
        )
    }

    func testCrossClipV3ReceiptRejectsSameGroupNeighborAndGroupDigestTampering() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "b1.jpg"]
        let groups = [
            ColmapPairGroup(imageNames: Array(names[0...1]), isVideo: true),
            ColmapPairGroup(imageNames: Array(names[2...3]), isVideo: true),
        ]
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .linear,
            offsets: [1],
            neighbors: 2,
            stride: 1,
            requiresCrossClipRetrieval: true
        )
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        let groupContract = try XCTUnwrap(request.imageGroupContract)
        let valid = PairGraphRetrievalAttemptEvidence(
            engine: plan.retrievalEngine,
            queryImageNames: request.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            candidatePolicy: groupContract.policy,
            imageGroupListDigest: groupContract.digest,
            imageGroupLines: groupContract.canonicalLines,
            queryOutcomes: request.queryImageNames.map { queryName in
                let neighbor = queryName.hasPrefix("a") ? "b0.jpg" : "a0.jpg"
                return PairGraphRetrievalQueryOutcome(
                    queryImageName: queryName,
                    status: .ranked,
                    rankedNeighborImageNames: [neighbor]
                )
            },
            directedPairLines: [
                "a0.jpg b0.jpg", "a1.jpg b0.jpg", "b1.jpg a0.jpg",
            ]
        )
        XCTAssertNoThrow(try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(valid),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        ))

        let baseWithCrossGroupEdge = try base.addingRetrievalPairLines(
            ["a0.jpg b0.jpg"],
            pairingPolicy: plan.pairingPolicy,
            groups: groups,
            requiresCrossClipRetrieval: true
        )
        var rankedBaseEdge = valid
        rankedBaseEdge.directedPairLines.removeAll { $0 == "a0.jpg b0.jpg" }
        rankedBaseEdge.outputDigest = PairGraphEvidenceStore.retrievalOutputDigest(
            rankedBaseEdge
        )
        XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(rankedBaseEdge),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: baseWithCrossGroupEdge
        ))

        var sameGroup = valid
        sameGroup.queryOutcomes[0].rankedNeighborImageNames = ["a1.jpg"]
        sameGroup.directedPairLines = [
            "a0.jpg b0.jpg", "a1.jpg b0.jpg", "b1.jpg a0.jpg",
        ]
        sameGroup.outputDigest = PairGraphEvidenceStore.retrievalOutputDigest(sameGroup)
        XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(sameGroup),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        ))

        var wrongGroupDigest = valid
        wrongGroupDigest.imageGroupListDigest = String(repeating: "f", count: 64)
        wrongGroupDigest.outputDigest = PairGraphEvidenceStore.retrievalOutputDigest(
            wrongGroupDigest
        )
        XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(wrongGroupDigest),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        ))
    }

    func testCrossClipMaximumRecoveryOver250ViewsStillQueriesEveryClip() throws {
        let firstClip = (0..<257).map { "a\($0).jpg" }
        let secondClip = (0..<3).map { "b\($0).jpg" }
        let names = firstClip + secondClip
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16, 32, 64, 128],
            neighbors: 2,
            stride: 10,
            requiresCrossClipRetrieval: true
        )

        let retrieval = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .maximum
        ))

        XCTAssertEqual(retrieval.queryImageNames, stride(from: 0, to: 257, by: 10).map {
            firstClip[$0]
        } + ["b0.jpg"])
        XCTAssertEqual(retrieval.candidateCount, 80)
        XCTAssertEqual(retrieval.returnedNeighborCount, 32)
        XCTAssertEqual(retrieval.minimumFrameSeparation, 0)
    }

    func testShortGenericSequenceDoesNotPayForRetrieval() throws {
        let names = (0..<119).map { "frame_\($0).jpg" }
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16, 32, 64],
            neighbors: 2,
            stride: 10
        )

        XCTAssertNil(try PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
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
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        XCTAssertEqual(pairs.pairLines, ["a0.jpg a1.jpg", "b0.jpg b1.jpg"])
        XCTAssertEqual(retrieval.queryImageNames, names)
        XCTAssertEqual(retrieval.minimumFrameSeparation, 0)
    }

    func testAutomaticMultipleVideosRequireCrossClipV3WithoutTemporalCrossEdges() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "b1.jpg"]
        let groups = [
            ColmapPairGroup(imageNames: Array(names[0...1]), isVideo: true),
            ColmapPairGroup(imageNames: Array(names[2...3]), isVideo: true),
        ]
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .automatic),
            input: .video(files: ["/tmp/a.mov", "/tmp/b.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.pairingPolicy, .segmentedMixed)
        XCTAssertTrue(plan.requiresCrossClipRetrieval)
        XCTAssertNoThrow(try plan.validate())
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        XCTAssertEqual(base.pairLines, ["a0.jpg a1.jpg", "b0.jpg b1.jpg"])
        XCTAssertFalse(base.isConnected)

        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        let groupContract = try XCTUnwrap(request.imageGroupContract)
        XCTAssertEqual(groupContract.policy, .crossGroupV1)
        XCTAssertEqual(request.queryImageNames, names)
        let receipt = PairGraphRetrievalAttemptEvidence(
            engine: plan.retrievalEngine,
            queryImageNames: request.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            candidatePolicy: groupContract.policy,
            imageGroupListDigest: groupContract.digest,
            imageGroupLines: groupContract.canonicalLines,
            queryOutcomes: request.queryImageNames.map { queryName in
                PairGraphRetrievalQueryOutcome(
                    queryImageName: queryName,
                    status: queryName == "a0.jpg" ? .ranked : .noRankedNeighbors,
                    rankedNeighborImageNames: queryName == "a0.jpg" ? ["b0.jpg"] : []
                )
            },
            directedPairLines: ["a0.jpg b0.jpg"]
        )
        let parsed = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(receipt),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        )
        let connected = try base.addingRetrievalPairLines(
            parsed.directedPairLines,
            pairingPolicy: plan.pairingPolicy,
            groups: groups,
            requiresCrossClipRetrieval: plan.requiresCrossClipRetrieval
        )

        XCTAssertTrue(connected.isConnected)
        XCTAssertEqual(connected.pairs.count { $0.role == .retrieval }, 1)
    }

    func testAutomaticMixedInputKeepsPhotoPhotoRetrievalEligible() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "b1.jpg", "p0.jpg", "p1.jpg"]
        let groups = [
            ColmapPairGroup(imageNames: Array(names[0...1]), isVideo: true),
            ColmapPairGroup(imageNames: Array(names[2...3]), isVideo: true),
            ColmapPairGroup(imageNames: Array(names[4...5]), isVideo: false),
        ]
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .automatic),
            input: .mixed(
                videos: ["/tmp/a.mov", "/tmp/b.mov"],
                photosFolder: "/tmp/photos"
            ),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        XCTAssertEqual(plan.pairingPolicy, .segmentedMixed)
        XCTAssertFalse(plan.requiresCrossClipRetrieval)
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        XCTAssertEqual(base.pairLines, ["a0.jpg a1.jpg", "b0.jpg b1.jpg"])
        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        XCTAssertNil(request.imageGroupContract)
        XCTAssertThrowsError(try PipelineRunner.vocabularyRetrievalImageGroupContract(
            imageNames: names,
            groups: groups,
            requiresCrossClipRetrieval: true
        ))
        let neighbors = [
            "a0.jpg": ["b0.jpg"],
            "b0.jpg": ["p0.jpg"],
            "p0.jpg": ["p1.jpg"],
        ]
        let receipt = PairGraphRetrievalAttemptEvidence(
            engine: plan.retrievalEngine,
            queryImageNames: request.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            queryOutcomes: request.queryImageNames.map { queryName in
                let ranked = neighbors[queryName] ?? []
                return PairGraphRetrievalQueryOutcome(
                    queryImageName: queryName,
                    status: ranked.isEmpty ? .noRankedNeighbors : .ranked,
                    rankedNeighborImageNames: ranked
                )
            },
            directedPairLines: [
                "a0.jpg b0.jpg", "b0.jpg p0.jpg", "p0.jpg p1.jpg",
            ]
        )
        XCTAssertTrue(
            PairGraphEvidenceStore.retrievalContractLines(receipt)[0]
                .hasPrefix("EASYSPLAT_RETRIEVAL_OUTCOMES_V2 ")
        )
        let parsed = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(receipt),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        )
        let connected = try base.addingRetrievalPairLines(
            parsed.directedPairLines,
            pairingPolicy: plan.pairingPolicy,
            groups: groups,
            requiresCrossClipRetrieval: plan.requiresCrossClipRetrieval
        )

        XCTAssertTrue(connected.isConnected)
        XCTAssertTrue(connected.pairLines.contains("p0.jpg p1.jpg"))
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
        XCTAssertNil(try PipelineRunner.vocabularyRetrievalRequest(
            imageNames: sixty,
            groups: [ColmapPairGroup(imageNames: sixty, isVideo: false)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))

        let expanded = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: sixtyOne,
            groups: [ColmapPairGroup(imageNames: sixtyOne, isVideo: false)],
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
            groups: [ColmapPairGroup(imageNames: over250, isVideo: false)],
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

    func testRetrievalOutcomeContractAuthenticatesEveryQuery() throws {
        let names = (0..<6).map { "frame_\($0).jpg" }
        let base = try ColmapPairPlan.persisted(
            imageNames: names,
            scheduledPairs: [
                ColmapScheduledPair(names[0], names[1], role: .local),
            ]
        )
        let request = PipelineRunner.VocabularyRetrievalRequest(
            queryImageNames: [names[0], names[2]],
            candidateCount: 20,
            returnedNeighborCount: 2,
            minimumFrameSeparation: 0
        )
        let requestDigest = PairGraphEvidenceStore.retrievalRequestDigest(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: 2,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation
        )
        let lines = [
            "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 2 0 2 \(requestDigest)",
            "Q ranked \(names[0]) 2 \(names[2]) \(names[3])",
            // The reciprocal 2->0 result remains visible even though 0->2 already won.
            "Q ranked \(names[2]) 2 \(names[0]) \(names[4])",
            "P \(names[0]) \(names[2])",
            "P \(names[0]) \(names[3])",
            "P \(names[2]) \(names[4])",
        ]

        let evidence = try PipelineRunner.validatedVocabularyRetrievalContract(
            lines,
            engine: .localSiftVocabularyV2,
            queryStride: 2,
            request: request,
            imageNames: names,
            excluding: base
        )

        XCTAssertEqual(evidence.queryOutcomes.map(\.queryImageName), request.queryImageNames)
        XCTAssertEqual(evidence.queryOutcomes.map(\.status), [.ranked, .ranked])
        XCTAssertEqual(evidence.queryOutcomes[0].rankedNeighborImageNames, [
            names[2], names[3],
        ])
        XCTAssertEqual(evidence.queryOutcomes[1].rankedNeighborImageNames, [
            names[0], names[4],
        ])
        XCTAssertEqual(evidence.directedPairLines, [
            "\(names[0]) \(names[2])",
            "\(names[0]) \(names[3])",
            "\(names[2]) \(names[4])",
        ])
        XCTAssertEqual(
            evidence.outputDigest,
            PairGraphEvidenceStore.retrievalOutputDigest(lines: lines)
        )
    }

    func testRetrievalOutcomeContractRejectsRankedBaseEdgeEvenWithoutPairRecord() throws {
        let names = (0..<4).map { "frame_\($0).jpg" }
        let base = try ColmapPairPlan.persisted(
            imageNames: names,
            scheduledPairs: [ColmapScheduledPair(names[0], names[1], role: .local)]
        )
        let request = PipelineRunner.VocabularyRetrievalRequest(
            queryImageNames: [names[0]],
            candidateCount: 20,
            returnedNeighborCount: 2,
            minimumFrameSeparation: 0
        )
        let digest = PairGraphEvidenceStore.retrievalRequestDigest(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: 1,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation
        )
        let lines = [
            "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 1 20 2 0 1 \(digest)",
            "Q ranked \(names[0]) 1 \(names[1])",
        ]

        XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalContract(
            lines,
            engine: .localSiftVocabularyV2,
            queryStride: 1,
            request: request,
            imageNames: names,
            excluding: base
        ))
    }

    func testRetrievalOutcomeContractRejectsMissingExtraReorderedAndSubstitutedQueries() throws {
        let names = (0..<5).map { "photo_\($0).jpg" }
        let request = PipelineRunner.VocabularyRetrievalRequest(
            queryImageNames: [names[0], names[2]],
            candidateCount: 20,
            returnedNeighborCount: 2,
            minimumFrameSeparation: 0
        )
        let digest = PairGraphEvidenceStore.retrievalRequestDigest(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: 2,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation
        )
        let header = "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 2 0 2 \(digest)"
        let validQueries = [
            "Q ranked \(names[0]) 1 \(names[3])",
            "Q ranked \(names[2]) 1 \(names[4])",
        ]
        let pairs = ["P \(names[0]) \(names[3])", "P \(names[2]) \(names[4])"]
        let emptyPlan = try ColmapPairPlan.persisted(
            imageNames: names,
            scheduledPairs: []
        )
        let invalidContracts = [
            [header, validQueries[0]] + [pairs[0]],
            [header] + validQueries + [validQueries[1]] + pairs,
            [header, validQueries[1], validQueries[0]] + pairs,
            [header, validQueries[0], "Q ranked \(names[1]) 1 \(names[4])"] + pairs,
        ]

        for lines in invalidContracts {
            XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalContract(
                lines,
                engine: .localSiftVocabularyV2,
                queryStride: 2,
                request: request,
                imageNames: names,
                excluding: emptyPlan
            ))
        }
    }

    func testRetrievalOutcomeContractAcceptsAuthenticatedZeroOutcome() throws {
        let names = (0..<4).map { "photo_\($0).jpg" }
        let request = PipelineRunner.VocabularyRetrievalRequest(
            queryImageNames: [names[0]],
            candidateCount: 20,
            returnedNeighborCount: 2,
            minimumFrameSeparation: 0
        )
        let digest = PairGraphEvidenceStore.retrievalRequestDigest(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: 1,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation
        )
        let header = "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 1 20 2 0 1 \(digest)"
        let emptyPlan = try ColmapPairPlan.persisted(
            imageNames: names,
            scheduledPairs: []
        )

        let evidence = try PipelineRunner.validatedVocabularyRetrievalContract(
            [header, "Q noRankedNeighbors \(names[0]) 0"],
            engine: .localSiftVocabularyV2,
            queryStride: 1,
            request: request,
            imageNames: names,
            excluding: emptyPlan
        )

        XCTAssertEqual(evidence.queryOutcomes.map(\.status), [.noRankedNeighbors])
        XCTAssertTrue(evidence.directedPairLines.isEmpty)
    }

    func testRetrievalOutcomeContractRejectsStatusCountTamperingAndPairMismatch() throws {
        let names = (0..<4).map { "photo_\($0).jpg" }
        let request = PipelineRunner.VocabularyRetrievalRequest(
            queryImageNames: [names[0]],
            candidateCount: 20,
            returnedNeighborCount: 2,
            minimumFrameSeparation: 0
        )
        let digest = PairGraphEvidenceStore.retrievalRequestDigest(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: 1,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation
        )
        let header = "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 1 20 2 0 1 \(digest)"
        let emptyPlan = try ColmapPairPlan.persisted(
            imageNames: names,
            scheduledPairs: []
        )
        let invalidContracts = [
            [header, "Q ranked \(names[0]) 0"],
            [header, "Q noRankedNeighbors \(names[0]) 1 \(names[1])"],
            [header, "Q ranked \(names[0]) 1 \(names[1])"],
            [header.replacingOccurrences(of: digest, with: String(repeating: "f", count: 64)),
             "Q ranked \(names[0]) 1 \(names[1])", "P \(names[0]) \(names[1])"],
            [header, "Q ranked \(names[0]) 1 ./\(names[1])", "P \(names[0]) \(names[1])"],
        ]

        for lines in invalidContracts {
            XCTAssertThrowsError(try PipelineRunner.validatedVocabularyRetrievalContract(
                lines,
                engine: .localSiftVocabularyV2,
                queryStride: 1,
                request: request,
                imageNames: names,
                excluding: emptyPlan
            ))
        }
    }

    func testConnectedOrderedBaseAcceptsZeroNeighborReceiptWithoutChangingSchedule() throws {
        let names = (0..<250).map { String(format: "frame_%03d.jpg", $0) }
        let groups = [ColmapPairGroup(imageNames: names, isVideo: true)]
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16, 32, 64, 128],
            neighbors: 2,
            stride: 10
        )
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        let receipt = PairGraphRetrievalAttemptEvidence(
            engine: plan.retrievalEngine,
            queryImageNames: request.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            queryOutcomes: request.queryImageNames.map {
                PairGraphRetrievalQueryOutcome(
                    queryImageName: $0,
                    status: .noRankedNeighbors,
                    rankedNeighborImageNames: []
                )
            },
            directedPairLines: []
        )

        let validated = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(receipt),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        )
        let merged = try base.addingRetrievalPairLines(
            validated.directedPairLines,
            pairingPolicy: plan.pairingPolicy,
            groups: groups,
            requiresCrossClipRetrieval: plan.requiresCrossClipRetrieval
        )

        XCTAssertEqual(base.pairs.count, 1_745)
        XCTAssertEqual(merged, base)
        XCTAssertTrue(merged.isConnected)
    }

    func testSegmentedReceiptMayLeaveSomeQueriesEmptyWhenItsPairsConnectAllGroups() throws {
        let names = ["a0.jpg", "a1.jpg", "b0.jpg", "b1.jpg"]
        let groups = [
            ColmapPairGroup(imageNames: Array(names[0...1]), isVideo: true),
            ColmapPairGroup(imageNames: Array(names[2...3]), isVideo: true),
        ]
        let plan = resolvedPlan(
            policy: .segmentedMixed,
            temporal: .linear,
            offsets: [1],
            neighbors: 2,
            stride: 1
        )
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: groups,
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        let receipt = PairGraphRetrievalAttemptEvidence(
            engine: plan.retrievalEngine,
            queryImageNames: request.queryImageNames,
            queryStride: plan.retrievalQueryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            queryOutcomes: request.queryImageNames.map { queryName in
                PairGraphRetrievalQueryOutcome(
                    queryImageName: queryName,
                    status: queryName == names[0] ? .ranked : .noRankedNeighbors,
                    rankedNeighborImageNames: queryName == names[0] ? [names[2]] : []
                )
            },
            directedPairLines: ["\(names[0]) \(names[2])"]
        )

        let validated = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(receipt),
            engine: plan.retrievalEngine,
            queryStride: plan.retrievalQueryStride,
            request: request,
            imageNames: names,
            excluding: base
        )
        let merged = try base.addingRetrievalPairLines(
            validated.directedPairLines,
            pairingPolicy: plan.pairingPolicy,
            groups: groups,
            requiresCrossClipRetrieval: plan.requiresCrossClipRetrieval
        )

        XCTAssertFalse(base.isConnected)
        XCTAssertTrue(merged.isConnected)
    }

    func testRetrievalNotScheduledPathDoesNotRequireAnOutcomeContract() throws {
        let names = (0..<119).map { "frame_\($0).jpg" }
        let plan = resolvedPlan(
            policy: .orderedContinuous,
            temporal: .multiscale,
            offsets: [1, 2, 4, 8, 16, 32, 64],
            neighbors: 2,
            stride: 10
        )

        XCTAssertNil(try PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: [ColmapPairGroup(imageNames: names, isVideo: true)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
    }

    func testUnorderedSixtyOnePhotoReceiptCoversEveryQueryAndBuildsAConnectedPlan() throws {
        let names = (0..<61).map { String(format: "photo_%03d.jpg", $0) }
        let plan = resolvedPlan(
            policy: .unorderedRetrieval,
            temporal: .none,
            offsets: [],
            neighbors: 8,
            stride: 1
        )
        let base = try PipelineRunner.baseColmapPairPlan(
            imageNames: names,
            groups: [ColmapPairGroup(imageNames: names, isVideo: false)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        )
        let request = try XCTUnwrap(PipelineRunner.vocabularyRetrievalRequest(
            imageNames: names,
            groups: [ColmapPairGroup(imageNames: names, isVideo: false)],
            resolvedPlan: plan,
            recoveryLevel: .normal
        ))
        let outcomes = names.enumerated().map { index, query in
            PairGraphRetrievalQueryOutcome(
                queryImageName: query,
                status: .ranked,
                rankedNeighborImageNames: [names[(index + 1) % names.count]]
            )
        }
        let pairLines = outcomes.map {
            "\($0.queryImageName) \($0.rankedNeighborImageNames[0])"
        }.sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
        let produced = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: request.queryImageNames,
            queryStride: 1,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            queryOutcomes: outcomes,
            directedPairLines: pairLines
        )

        let parsed = try PipelineRunner.validatedVocabularyRetrievalContract(
            PairGraphEvidenceStore.retrievalContractLines(produced),
            engine: .localSiftVocabularyV2,
            queryStride: 1,
            request: request,
            imageNames: names,
            excluding: base
        )
        let connected = try base.addingRetrievalPairLines(
            parsed.directedPairLines,
            pairingPolicy: .unorderedRetrieval,
            groups: [ColmapPairGroup(imageNames: names, isVideo: false)],
            requiresCrossClipRetrieval: false
        )

        XCTAssertEqual(parsed.queryOutcomes.count, 61)
        XCTAssertEqual(connected.pairs.count, 61)
        XCTAssertTrue(connected.isConnected)
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
        stride: Int,
        requiresCrossClipRetrieval: Bool = false
    ) -> ResolvedRunPlan {
        ResolvedRunPlan(
            geometryBackend: .colmap,
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
            pairingPolicy: policy,
            temporalPairing: temporal,
            temporalOffsets: offsets,
            retrievalCandidateCount: 20,
            retrievalNeighborCount: neighbors,
            retrievalQueryStride: stride,
            requiresCrossClipRetrieval: requiresCrossClipRetrieval
        )
    }
}
#endif
