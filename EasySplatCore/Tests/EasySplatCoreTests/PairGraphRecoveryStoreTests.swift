#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class PairGraphRecoveryStoreTests: XCTestCase {
    func testStoreAcceptsCanonicalPathThroughPrivateTemporaryAlias() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/EasySplat-PairGraphRecovery-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let imageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        for (index, imageName) in imageNames.enumerated() {
            try Data("frame-\(index)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName)
            )
        }
        let fixture = (
            root: root,
            paths: paths,
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            )
        )
        let state = try makeSameScheduleState(fixture: fixture)

        try PairGraphRecoveryStore.save(
            state,
            to: paths.pairGraphRecoveryURL,
            projectPaths: paths
        )

        XCTAssertEqual(
            try PairGraphRecoveryStore.loadBound(
                from: paths.pairGraphRecoveryURL,
                expectedImageNames: imageNames,
                projectPaths: paths
            ),
            state
        )
    }

    func testRetiredRecoverySchemaInvalidatesPendingExactIntent() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        var state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [makeAttempt(
                number: 1,
                matcher: .faiss,
                outcome: .failed,
                plan: plans.source,
                duration: 0.5
            )],
            matchingDurationSeconds: 0.5,
            fallbackReasons: ["exact descriptor matching"]
        )
        state.schemaVersion = 2

        XCTAssertThrowsError(try PairGraphRecoveryStore.save(
            state,
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? PairGraphRecoveryStoreError, .invalidSchema(2))
        }
    }

    func testPolicyRecoveryRoundTripPreservesHistoryAcrossDensityEscalation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        var normalAttempt = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.sparse,
            duration: 1.25
        )
        normalAttempt.retrieval = makeRetrievalEvidence(directedPairLines: [])
        normalAttempt.retrievalWasExecuted = true
        let activeRetrieval = makeRetrievalEvidence(
            directedPairLines: ["a.jpg d.jpg"]
        )
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            pairingPolicy: .orderedOrbit,
            mode: .policy,
            activeRecoveryLevel: .expanded,
            activePlan: plans.source,
            activeRetrieval: activeRetrieval,
            attempts: [normalAttempt],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: true,
            matchingDurationSeconds: 1.25,
            fallbackReasons: ["Reconstruction coverage was below the acceptance gate"]
        )

        try PairGraphRecoveryStore.save(
            state,
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )
        let restored = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames,
            projectPaths: fixture.paths
        ).restoredRecovery()

        XCTAssertEqual(restored.mode, .policy)
        XCTAssertEqual(restored.recoveryLevel, .expanded)
        XCTAssertEqual(restored.activePlan, plans.source)
        XCTAssertEqual(restored.activeRetrieval, activeRetrieval)
        XCTAssertEqual(restored.attempts, [normalAttempt])
        XCTAssertTrue(restored.retrievalWasScheduled)
        XCTAssertTrue(restored.usedLocalVocabularyRetrieval)
    }

    func testRecoveryRejectsACompletedRetrievalRequestWithAnExplicitZeroOutcome() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        var attempt = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        attempt.retrieval = makeRetrievalEvidence(directedPairLines: [])
        attempt.retrievalWasExecuted = true
        let activeRetrieval = makeRetrievalEvidence(
            directedPairLines: [],
            explicitZero: true
        )
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            pairingPolicy: .orderedOrbit,
            mode: .policy,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            activeRetrieval: activeRetrieval,
            attempts: [attempt],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: true,
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )

        XCTAssertThrowsError(try PairGraphRecoveryStore.save(
            state,
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        ))
    }

    func testInitialVocabularyScheduleIsDurableBeforeTheFirstInvocation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            pairingPolicy: .orderedOrbit,
            mode: .policy,
            phase: .preparing,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 0,
            fallbackReasons: []
        )

        try PairGraphRecoveryStore.save(
            state,
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )
        let restored = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames,
            projectPaths: fixture.paths
        ).restoredRecovery()

        XCTAssertEqual(restored.phase, .preparing)
        XCTAssertEqual(restored.attempts, [])
        XCTAssertTrue(restored.retrievalWasScheduled)
        XCTAssertFalse(restored.usedLocalVocabularyRetrieval)
    }

    func testAutomaticMultiVideoCrossClipRequirementIsDurableAndAuthenticated() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let crossClipPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .automatic),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        XCTAssertEqual(crossClipPlan.pairingPolicy, .segmentedMixed)
        XCTAssertTrue(crossClipPlan.requiresCrossClipRetrieval)
        let groups = [
            ColmapPairGroup(imageNames: ["a.jpg", "b.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["c.jpg", "d.jpg"], isVideo: true),
        ]
        var state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            groups: groups,
            pairingPolicy: crossClipPlan.pairingPolicy,
            planBinding: PairGraphPlanBinding(crossClipPlan),
            mode: .policy,
            phase: .preparing,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 0,
            fallbackReasons: []
        )

        try save(state, fixture: fixture)
        let restored = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames,
            expectedGroups: groups,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(restored.groups, groups)
        XCTAssertTrue(restored.planBinding.requiresCrossClipRetrieval)
        XCTAssertTrue(restored.retrievalWasScheduled)

        let singleClipPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov"]),
            hardware: hardware,
            developmentOverrides: .none
        )
        state.planBinding = PairGraphPlanBinding(singleClipPlan)
        XCTAssertThrowsError(try save(state, fixture: fixture))
    }

    func testShortCrossClipMatchingRecoveryPreservesRetrievalAcrossEscalation() throws {
        let firstClip = (0..<17).map { "a_\($0).jpg" }
        let secondClip = (0..<3).map { "b_\($0).jpg" }
        let imageNames = firstClip + secondClip
        let fixture = try makeProject(imageNames: imageNames)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let crossClipPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let groups = [
            ColmapPairGroup(imageNames: firstClip, isVideo: true),
            ColmapPairGroup(imageNames: secondClip, isVideo: true),
        ]
        let retrievalLines = [
            "a_0.jpg b_0.jpg",
            "a_10.jpg b_1.jpg",
            "b_0.jpg a_1.jpg",
        ]
        let groupContract = try XCTUnwrap(
            PipelineRunner.vocabularyRetrievalImageGroupContract(
                imageNames: imageNames,
                groups: groups,
                requiresCrossClipRetrieval: true
            )
        )
        let retrieval = PairGraphRetrievalAttemptEvidence(
            engine: crossClipPlan.retrievalEngine,
            queryImageNames: ["a_0.jpg", "a_10.jpg", "b_0.jpg"],
            queryStride: crossClipPlan.retrievalQueryStride,
            candidateCount: crossClipPlan.retrievalCandidateCount,
            returnedNeighborCount: crossClipPlan.retrievalNeighborCount,
            minimumFrameSeparation: 0,
            candidatePolicy: groupContract.policy,
            imageGroupListDigest: groupContract.digest,
            imageGroupLines: groupContract.canonicalLines,
            queryOutcomes: [
                PairGraphRetrievalQueryOutcome(
                    queryImageName: "a_0.jpg",
                    status: .ranked,
                    rankedNeighborImageNames: ["b_0.jpg"]
                ),
                PairGraphRetrievalQueryOutcome(
                    queryImageName: "a_10.jpg",
                    status: .ranked,
                    rankedNeighborImageNames: ["b_1.jpg"]
                ),
                PairGraphRetrievalQueryOutcome(
                    queryImageName: "b_0.jpg",
                    status: .ranked,
                    rankedNeighborImageNames: ["a_1.jpg"]
                ),
            ],
            directedPairLines: retrievalLines
        )
        let basePlan = try PipelineRunner.baseColmapPairPlan(
            imageNames: imageNames,
            groups: groups,
            resolvedPlan: crossClipPlan,
            recoveryLevel: .normal
        )
        let recoveredPlan = try basePlan.addingRetrievalPairLines(
            retrievalLines,
            pairingPolicy: crossClipPlan.pairingPolicy,
            groups: groups,
            requiresCrossClipRetrieval: true
        )
        var priorAttempt = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: recoveredPlan,
            duration: 1
        )
        priorAttempt.retrieval = retrieval
        priorAttempt.retrievalWasExecuted = true
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: imageNames,
            groups: groups,
            pairingPolicy: .orderedContinuous,
            planBinding: PairGraphPlanBinding(crossClipPlan),
            mode: .policy,
            phase: .matching,
            activeRecoveryLevel: .expanded,
            activePlan: recoveredPlan,
            activeRetrieval: retrieval,
            attempts: [priorAttempt],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: true,
            matchingDurationSeconds: 1,
            fallbackReasons: ["Reconstruction coverage was below the acceptance gate"]
        )

        try save(state, fixture: fixture)
        let restored = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: imageNames,
            expectedGroups: groups,
            projectPaths: fixture.paths
        ).restoredRecovery()

        XCTAssertEqual(restored.phase, .matching)
        XCTAssertEqual(restored.recoveryLevel, .expanded)
        XCTAssertEqual(restored.activeRetrieval, retrieval)
        XCTAssertEqual(restored.attempts, [priorAttempt])
        XCTAssertTrue(restored.retrievalWasScheduled)
        XCTAssertTrue(restored.usedLocalVocabularyRetrieval)
        XCTAssertEqual(restored.groups, groups)
    }

    func testShortCrossClipRecoveryRejectsChangedClipBoundaries() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let crossClipPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let storedGroups = [
            ColmapPairGroup(imageNames: ["a.jpg", "b.jpg"], isVideo: true),
            ColmapPairGroup(imageNames: ["c.jpg", "d.jpg"], isVideo: true),
        ]
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            groups: storedGroups,
            pairingPolicy: .orderedContinuous,
            planBinding: PairGraphPlanBinding(crossClipPlan),
            mode: .policy,
            phase: .preparing,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 0,
            fallbackReasons: []
        )
        try save(state, fixture: fixture)

        let changedGroups = [
            ColmapPairGroup(imageNames: ["a.jpg"], isVideo: true),
            ColmapPairGroup(
                imageNames: ["b.jpg", "c.jpg", "d.jpg"],
                isVideo: true
            ),
        ]
        XCTAssertThrowsError(try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames,
            expectedGroups: changedGroups,
            projectPaths: fixture.paths
        ))
    }

    func testRecoveryRejectsStructurallyInvalidCrossClipPlanBinding() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let crossClipPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
            input: .video(files: ["/tmp/one.mov", "/tmp/two.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        var state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            groups: [
                ColmapPairGroup(imageNames: ["a.jpg", "b.jpg"], isVideo: true),
                ColmapPairGroup(imageNames: ["c.jpg", "d.jpg"], isVideo: true),
            ],
            pairingPolicy: .orderedContinuous,
            planBinding: PairGraphPlanBinding(crossClipPlan),
            mode: .policy,
            phase: .preparing,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [],
            retrievalWasScheduled: true,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 0,
            fallbackReasons: []
        )
        state.planBinding.temporalPairing = .none
        state.planBinding.temporalOffsets = []

        XCTAssertThrowsError(try save(state, fixture: fixture))
    }

    func testPreparingPolicyRecoveryPreservesDisconnectedPlanningFailure() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let imageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        let disconnected = try ColmapPairPlan.persisted(
            imageNames: imageNames,
            scheduledPairs: [ColmapScheduledPair("a.jpg", "b.jpg", role: .local)]
        )
        let attempt = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .failed,
            plan: disconnected,
            duration: 1
        )
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: imageNames,
            mode: .policy,
            phase: .preparing,
            activeRecoveryLevel: .expanded,
            activePlan: disconnected,
            attempts: [attempt],
            matchingDurationSeconds: 1,
            fallbackReasons: ["Image matching did not produce a connected graph"]
        )

        let restored = try state.restoredRecovery()

        XCTAssertEqual(restored.phase, .preparing)
        XCTAssertEqual(restored.mode, .policy)
        XCTAssertEqual(restored.activePlan, disconnected)
        XCTAssertEqual(restored.recoveryLevel, .expanded)
    }

    func testPreparingExactRecoveryRejectsDensityTransition() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .failed,
                plan: plans.sparse,
                duration: 1
            ),
            makeAttempt(
                number: 2,
                matcher: .exact,
                recoveryLevel: .normal,
                outcome: .completed,
                plan: plans.sparse,
                duration: 2
            ),
        ]
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            phase: .preparing,
            activeRecoveryLevel: .expanded,
            activePlan: plans.sparse,
            attempts: attempts,
            matchingDurationSeconds: 3,
            fallbackReasons: ["exact descriptor matching"]
        )

        XCTAssertThrowsError(try state.restoredRecovery())
    }

    func testPolicyRecoveryRejectsExactOrSkippedDensityHistory() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let exactAttempt = makeAttempt(
            number: 1,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .failed,
            plan: plans.sparse,
            duration: 1
        )
        let skippedDensity = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.sparse,
            duration: 1
        )

        XCTAssertThrowsError(try PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .policy,
            activeRecoveryLevel: .expanded,
            activePlan: plans.source,
            attempts: [exactAttempt],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        ).restoredRecovery())
        XCTAssertThrowsError(try PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .policy,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [skippedDensity],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        ).restoredRecovery())
    }

    func testSameScheduleExactRecoveryRestoresCanonicalPlan() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()

        let failedPolicy = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .failed,
            plan: plans.source,
            duration: 0.5
        )
        let sameSchedule = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [failedPolicy],
            matchingDurationSeconds: 0.5,
            fallbackReasons: ["exact descriptor matching"]
        )
        let restoredSame = try sameSchedule.restoredRecovery()
        XCTAssertEqual(restoredSame.activePlan, plans.source)

        let failedExact = makeAttempt(
            number: 2,
            matcher: .exact,
            outcome: .failed,
            plan: plans.source,
            duration: 0.75
        )
        let terminalExact = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .terminalExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [failedPolicy, failedExact],
            matchingDurationSeconds: 1.25,
            fallbackReasons: ["exact descriptor matching"]
        )
        let restoredRetry = try terminalExact.restoredRecovery()
        XCTAssertEqual(restoredRetry.mode, .terminalExact)
        XCTAssertEqual(restoredRetry.attempts, [failedPolicy, failedExact])
        XCTAssertEqual(restoredRetry.matchingDurationSeconds, 1.25)

    }

    func testSameScheduleExactRecoveryRejectsMoreThan256Pairs() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let imageNames = (0..<24).map { String(format: "frame-%03d.jpg", $0) }
        let exhaustive = try ColmapPairPlan.exhaustive(imageNames: imageNames)

        func state(pairCount: Int) throws -> PairGraphRecoveryState {
            let plan = try ColmapPairPlan.persisted(
                imageNames: imageNames,
                scheduledPairs: Array(exhaustive.pairs.prefix(pairCount))
            )
            let failedFaiss = makeAttempt(
                number: 1,
                matcher: .faiss,
                outcome: .failed,
                plan: plan,
                duration: 1
            )
            return PairGraphRecoveryState(
                selectedFramesDigest: fixture.selectedFramesDigest,
                imageNames: imageNames,
                mode: .sameScheduleExact,
                exactRecoveryReason: .faissCrash,
                activeRecoveryLevel: .normal,
                activePlan: plan,
                attempts: [failedFaiss],
                matchingDurationSeconds: 1,
                fallbackReasons: ["exact descriptor matching"]
            )
        }

        XCTAssertNoThrow(try state(pairCount: 256).restoredRecovery())
        XCTAssertThrowsError(try state(pairCount: 257).restoredRecovery())
    }

    func testSameScheduleExactRejectsPendingLevelAcrossDensityLadder() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let imageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        let disconnected = try ColmapPairPlan.persisted(
            imageNames: imageNames,
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ]
        )
        let expanded = try ColmapPairPlan.persisted(
            imageNames: imageNames,
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
                ColmapScheduledPair("a.jpg", "d.jpg", role: .loopRevisit),
                ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
                ColmapScheduledPair("c.jpg", "d.jpg", role: .local),
            ]
        )
        let maximum = try ColmapPairPlan.persisted(
            imageNames: imageNames,
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
                ColmapScheduledPair("a.jpg", "c.jpg", role: .retrieval),
                ColmapScheduledPair("a.jpg", "d.jpg", role: .loopRevisit),
                ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
                ColmapScheduledPair("c.jpg", "d.jpg", role: .local),
            ]
        )
        let attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .failed,
                plan: disconnected,
                duration: 1
            ),
            makeAttempt(
                number: 2,
                matcher: .faiss,
                recoveryLevel: .expanded,
                outcome: .failed,
                plan: expanded,
                duration: 2
            ),
            makeAttempt(
                number: 3,
                matcher: .exact,
                recoveryLevel: .expanded,
                outcome: .completed,
                plan: expanded,
                duration: 3
            ),
        ]
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .maximum,
            activePlan: maximum,
            attempts: attempts,
            matchingDurationSeconds: 6,
            fallbackReasons: ["exact descriptor matching"]
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))
    }

    func testSameScheduleRejectsEscalationAfterFailedConnectedExactAttempt() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .failed,
                plan: plans.sparse,
                duration: 1
            ),
            makeAttempt(
                number: 2,
                matcher: .exact,
                recoveryLevel: .normal,
                outcome: .failed,
                plan: plans.sparse,
                duration: 1
            ),
        ]
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .expanded,
            activePlan: plans.source,
            attempts: attempts,
            matchingDurationSeconds: 2,
            fallbackReasons: []
        )

        XCTAssertThrowsError(try state.restoredRecovery())
    }

    func testSameScheduleExactRejectsInvalidLadderTransitions() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()

        func state(
            attempts: [PairGraphAttemptEvidence],
            activeLevel: PairGraphRecoveryLevel,
            activePlan: ColmapPairPlan
        ) -> PairGraphRecoveryState {
            PairGraphRecoveryState(
                selectedFramesDigest: fixture.selectedFramesDigest,
                imageNames: activePlan.imageNames,
                mode: .sameScheduleExact,
                exactRecoveryReason: .faissCrash,
                activeRecoveryLevel: activeLevel,
                activePlan: activePlan,
                attempts: attempts,
                matchingDurationSeconds: attempts.reduce(0) {
                    $0 + $1.artifact.durationSeconds
                },
                fallbackReasons: []
            )
        }

        let exactWithoutFaiss = makeAttempt(
            number: 1,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.sparse,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [exactWithoutFaiss],
            activeLevel: .normal,
            activePlan: plans.sparse
        ).restoredRecovery())

        let faissNormal = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.sparse,
            duration: 1
        )
        let exactMaximum = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .maximum,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissNormal, exactMaximum],
            activeLevel: .maximum,
            activePlan: plans.source
        ).restoredRecovery())
        XCTAssertThrowsError(try state(
            attempts: [faissNormal],
            activeLevel: .maximum,
            activePlan: plans.source
        ).restoredRecovery())
        XCTAssertThrowsError(try state(
            attempts: [faissNormal],
            activeLevel: .normal,
            activePlan: plans.sparse
        ).restoredRecovery())
        XCTAssertThrowsError(try state(
            attempts: [faissNormal],
            activeLevel: .expanded,
            activePlan: plans.source
        ).restoredRecovery())

        let completedExactNormal = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.sparse,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissNormal],
            activeLevel: .normal,
            activePlan: plans.source
        ).restoredRecovery())
        XCTAssertThrowsError(try state(
            attempts: [faissNormal, completedExactNormal],
            activeLevel: .normal,
            activePlan: plans.sparse
        ).restoredRecovery())

        let changedPlanExact = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .failed,
            plan: plans.source,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissNormal, changedPlanExact],
            activeLevel: .normal,
            activePlan: plans.source
        ).restoredRecovery())

        let changedLevelExact = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .expanded,
            outcome: .failed,
            plan: plans.sparse,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissNormal, changedLevelExact],
            activeLevel: .expanded,
            activePlan: plans.sparse
        ).restoredRecovery())

        let faissExpanded = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .expanded,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        let exactNormal = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.sparse,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissExpanded, exactNormal],
            activeLevel: .normal,
            activePlan: plans.sparse
        ).restoredRecovery())

        let faissAfterExact = makeAttempt(
            number: 3,
            matcher: .faiss,
            recoveryLevel: .expanded,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissNormal, exactNormal, faissAfterExact],
            activeLevel: .expanded,
            activePlan: plans.source
        ).restoredRecovery())
    }

    func testSaveRejectsTamperedDigestAndInvalidModeRelationships() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let policy = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )

        var state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .policy,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        state.activePairListDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try save(state, fixture: fixture))

        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: plans.sparse,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))

        let unsafePlan = try ColmapPairPlan.persisted(
            imageNames: ["../a.jpg", "b.jpg"],
            scheduledPairs: [
                ColmapScheduledPair("../a.jpg", "b.jpg", role: .local),
            ]
        )
        let unsafeAttempt = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .failed,
            plan: unsafePlan,
            duration: 1
        )
        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: unsafePlan.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: unsafePlan,
            attempts: [unsafeAttempt],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))

        var noncontiguous = policy
        noncontiguous.artifact.attemptNumber = 2
        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .policy,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [noncontiguous],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))
    }

    func testLoadBoundRejectsChangedFramesAndOrder() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let policy = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .failed,
            plan: plans.source,
            duration: 1
        )
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        try save(state, fixture: fixture)

        XCTAssertThrowsError(try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames.reversed(),
            projectPaths: fixture.paths
        ))

        try Data("changed".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("a.jpg"),
            options: [.atomic]
        )
        XCTAssertThrowsError(try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames,
            projectPaths: fixture.paths
        ))
    }

    func testStoreRejectsOutsideSymlinkHardLinkOversizeAndMalformedFiles() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = try makeSameScheduleState(fixture: fixture)
        let outside = fixture.root.appendingPathComponent("outside.json")

        XCTAssertThrowsError(try PairGraphRecoveryStore.save(
            state,
            to: outside,
            projectPaths: fixture.paths
        ))

        try save(state, fixture: fixture)
        let data = try Data(contentsOf: fixture.paths.pairGraphRecoveryURL)
        let externalAlias = fixture.root.appendingPathComponent("pair-recovery-alias.json")
        try FileManager.default.createSymbolicLink(
            at: externalAlias,
            withDestinationURL: fixture.paths.pairGraphRecoveryURL
        )
        XCTAssertThrowsError(try PairGraphRecoveryStore.save(
            state,
            to: externalAlias,
            projectPaths: fixture.paths
        ))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: externalAlias.path)
        )

        try FileManager.default.removeItem(at: fixture.paths.pairGraphRecoveryURL)
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.pairGraphRecoveryURL,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try PairGraphRecoveryStore.load(
            from: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        ))

        try FileManager.default.removeItem(at: fixture.paths.pairGraphRecoveryURL)
        XCTAssertEqual(link(outside.path, fixture.paths.pairGraphRecoveryURL.path), 0)
        XCTAssertThrowsError(try PairGraphRecoveryStore.load(
            from: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        ))

        try FileManager.default.removeItem(at: fixture.paths.pairGraphRecoveryURL)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fixture.paths.pairGraphRecoveryURL.path,
            contents: nil
        ))
        let handle = try FileHandle(forWritingTo: fixture.paths.pairGraphRecoveryURL)
        try handle.truncate(atOffset: UInt64(PairGraphRecoveryStore.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try PairGraphRecoveryStore.load(
            from: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        ))

        try FileManager.default.removeItem(at: fixture.paths.pairGraphRecoveryURL)
        try Data("{not-json".utf8).write(to: fixture.paths.pairGraphRecoveryURL)
        XCTAssertThrowsError(try PairGraphRecoveryStore.load(
            from: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        ))
    }

    func testCancelledTaskDoesNotSaveRecoveryState() async throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = try makeSameScheduleState(fixture: fixture)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try PairGraphRecoveryStore.save(
                state,
                to: fixture.paths.pairGraphRecoveryURL,
                projectPaths: fixture.paths
            )
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.pairGraphRecoveryURL.path
        ))
    }

    func testProjectPathsUsesCanonicalRecoveryLocation() {
        let root = URL(fileURLWithPath: "/tmp/easysplat-project", isDirectory: true)
        XCTAssertEqual(
            ProjectPaths(root: root).pairGraphRecoveryURL,
            root.appendingPathComponent("SfM/pair_graph_recovery.json")
        )
    }

    private func makeProject(
        imageNames: [String] = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
    ) throws -> (
        root: URL,
        paths: ProjectPaths,
        selectedFramesDigest: String
    ) {
        let root = try TestFileBuilder.makeTempDir()
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        for (index, imageName) in imageNames.enumerated() {
            try Data("frame-\(index)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName)
            )
        }
        return (
            root,
            paths,
            try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            )
        )
    }

    private func makePlans() throws -> (source: ColmapPairPlan, sparse: ColmapPairPlan) {
        let imageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        let sourcePairs = [
            ColmapScheduledPair("a.jpg", "b.jpg", role: .local),
            ColmapScheduledPair("a.jpg", "d.jpg", role: .retrieval),
            ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
            ColmapScheduledPair("c.jpg", "d.jpg", role: .local),
        ]
        return (
            try ColmapPairPlan.persisted(
                imageNames: imageNames,
                scheduledPairs: sourcePairs
            ),
            try ColmapPairPlan.persisted(
                imageNames: imageNames,
                scheduledPairs: [sourcePairs[0], sourcePairs[2], sourcePairs[3]]
            )
        )
    }

    private func makeAttempt(
        number: Int,
        matcher: DescriptorMatcher,
        recoveryLevel: PairGraphRecoveryLevel = .normal,
        outcome: PairMatchingAttemptOutcome,
        plan: ColmapPairPlan,
        duration: Double
    ) -> PairGraphAttemptEvidence {
        let completedCount = outcome == .completed ? plan.pairs.count : 0
        return PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: number,
                matcher: matcher,
                recoveryLevel: recoveryLevel,
                outcome: outcome,
                exactRecoveryReason: matcher == .exact ? .faissCrash : nil,
                scheduledPairCount: plan.pairs.count,
                attemptedPairCount: completedCount,
                rawMatchedPairCount: completedCount,
                spatiallyVerifiedPairCount: completedCount,
                durationSeconds: duration
            ),
            scheduledPairs: plan.pairs
        )
    }

    private func makeRetrievalEvidence(
        directedPairLines: [String],
        explicitZero: Bool = false
    ) -> PairGraphRetrievalAttemptEvidence {
        let returnedNeighbors = directedPairLines.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 ? String(fields[1]) : nil
        }.sorted()
        let firstQueryNeighbors = returnedNeighbors.isEmpty && !explicitZero
            ? ["b.jpg"]
            : returnedNeighbors
        let queryImageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        let neighbors = [firstQueryNeighbors, ["a.jpg"], ["b.jpg"], ["c.jpg"]]
        return PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: queryImageNames,
            queryStride: 1,
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 12,
            queryOutcomes: zip(queryImageNames, neighbors).map { query, values in
                PairGraphRetrievalQueryOutcome(
                    queryImageName: query,
                    status: values.isEmpty ? .noRankedNeighbors : .ranked,
                    rankedNeighborImageNames: values
                )
            },
            directedPairLines: directedPairLines
        )
    }

    private func makeSameScheduleState(
        fixture: (root: URL, paths: ProjectPaths, selectedFramesDigest: String)
    ) throws -> PairGraphRecoveryState {
        let plans = try makePlans()
        let policy = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .failed,
            plan: plans.source,
            duration: 1
        )
        return PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            exactRecoveryReason: .faissCrash,
            activeRecoveryLevel: .normal,
            activePlan: plans.source,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
    }

    private func save(
        _ state: PairGraphRecoveryState,
        fixture: (root: URL, paths: ProjectPaths, selectedFramesDigest: String)
    ) throws {
        try PairGraphRecoveryStore.save(
            state,
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )
    }
}
#endif
