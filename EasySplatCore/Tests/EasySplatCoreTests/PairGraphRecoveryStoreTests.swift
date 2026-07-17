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
            activeRecoveryLevel: .maximum,
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

    func testTargetedRecoveryRoundTripRestoresActiveSourceAndHistory() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let policy = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .completed,
            plan: plans.source,
            duration: 1.25
        )
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .targetedExact,
            computeMode: .cpu,
            activeRecoveryLevel: .maximum,
            activePlan: plans.targeted,
            attempts: [policy],
            matchingDurationSeconds: 1.25,
            fallbackReasons: ["exact descriptor matching"]
        )

        try PairGraphRecoveryStore.save(
            state,
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )
        let loaded = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: plans.source.imageNames,
            projectPaths: fixture.paths
        )
        let restored = try loaded.restoredRecovery()

        XCTAssertEqual(loaded, state)
        XCTAssertEqual(restored.mode, .targetedExact)
        XCTAssertEqual(restored.computeMode, .cpu)
        XCTAssertEqual(restored.activePlan, plans.targeted)
        XCTAssertEqual(restored.sourcePlan, plans.source)
        XCTAssertEqual(restored.attempts, [policy])
        XCTAssertEqual(restored.matchingDurationSeconds, 1.25)
        XCTAssertEqual(restored.fallbackReasons, ["exact descriptor matching"])
    }

    func testPolicyRecoveryRoundTripPreservesHistoryAcrossDensityEscalation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let normalAttempt = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.targeted,
            duration: 1.25
        )
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .policy,
            activeRecoveryLevel: .expanded,
            activePlan: plans.source,
            attempts: [normalAttempt],
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
        XCTAssertEqual(restored.sourcePlan, plans.targeted)
        XCTAssertEqual(restored.attempts, [normalAttempt])
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

    func testPreparingExactRecoveryPreservesDensityTransitionBeforePlanExists() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .failed,
                plan: plans.targeted,
                duration: 1
            ),
            makeAttempt(
                number: 2,
                matcher: .exact,
                recoveryLevel: .normal,
                outcome: .completed,
                plan: plans.targeted,
                duration: 2
            ),
        ]
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            phase: .preparing,
            activeRecoveryLevel: .expanded,
            activePlan: plans.targeted,
            attempts: attempts,
            matchingDurationSeconds: 3,
            fallbackReasons: ["exact descriptor matching"]
        )

        let restored = try state.restoredRecovery()

        XCTAssertEqual(restored.phase, .preparing)
        XCTAssertEqual(restored.mode, .sameScheduleExact)
        XCTAssertEqual(restored.activePlan, plans.targeted)
        XCTAssertEqual(restored.recoveryLevel, .expanded)
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
            plan: plans.targeted,
            duration: 1
        )
        let skippedDensity = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.targeted,
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
            activeRecoveryLevel: .maximum,
            activePlan: plans.source,
            attempts: [skippedDensity],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        ).restoredRecovery())
    }

    func testSameScheduleAndFullRecoveryRestoreCanonicalPlans() throws {
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
            activeRecoveryLevel: .maximum,
            activePlan: plans.source,
            attempts: [failedPolicy],
            matchingDurationSeconds: 0.5,
            fallbackReasons: ["exact descriptor matching"]
        )
        let restoredSame = try sameSchedule.restoredRecovery()
        XCTAssertEqual(restoredSame.activePlan, plans.source)
        XCTAssertEqual(restoredSame.sourcePlan, plans.source)

        let failedExact = makeAttempt(
            number: 2,
            matcher: .exact,
            outcome: .failed,
            plan: plans.source,
            duration: 0.75
        )
        let retryingSameSchedule = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.source,
            attempts: [failedPolicy, failedExact],
            matchingDurationSeconds: 1.25,
            fallbackReasons: ["exact descriptor matching"]
        )
        let restoredRetry = try retryingSameSchedule.restoredRecovery()
        XCTAssertEqual(restoredRetry.sourcePlan, plans.source)
        XCTAssertEqual(restoredRetry.attempts, [failedPolicy, failedExact])
        XCTAssertEqual(restoredRetry.matchingDurationSeconds, 1.25)

        let completedPolicy = makeAttempt(
            number: 1,
            matcher: .faiss,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        let completedTarget = makeAttempt(
            number: 2,
            purpose: .targetedExactGraphRecovery,
            matcher: .exact,
            outcome: .completed,
            plan: plans.targeted,
            duration: 2
        )
        let full = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .fullExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.source,
            attempts: [completedPolicy, completedTarget],
            matchingDurationSeconds: 3,
            fallbackReasons: ["exact descriptor matching"]
        )
        let restoredFull = try full.restoredRecovery()
        XCTAssertEqual(restoredFull.activePlan, plans.source)
        XCTAssertEqual(restoredFull.sourcePlan, plans.source)
        XCTAssertEqual(restoredFull.attempts, [completedPolicy, completedTarget])
    }

    func testSameScheduleExactRestoresPendingLevelAcrossDensityLadder() throws {
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
                outcome: .completed,
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
            activeRecoveryLevel: .maximum,
            activePlan: maximum,
            attempts: attempts,
            matchingDurationSeconds: 6,
            fallbackReasons: ["exact descriptor matching"]
        )
        try save(state, fixture: fixture)
        let loaded = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: imageNames,
            projectPaths: fixture.paths
        )

        let restored = try loaded.restoredRecovery()

        XCTAssertEqual(loaded.activeRecoveryLevel, .maximum)
        XCTAssertEqual(restored.recoveryLevel, .maximum)
        XCTAssertEqual(restored.activePlan, maximum)
        XCTAssertEqual(restored.sourcePlan, maximum)
        XCTAssertEqual(restored.attempts, attempts)
    }

    func testSameScheduleAllowsEscalationAfterFailedConnectedExactAttempt() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()
        let attempts = [
            makeAttempt(
                number: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                plan: plans.targeted,
                duration: 1
            ),
            makeAttempt(
                number: 2,
                matcher: .exact,
                recoveryLevel: .normal,
                outcome: .failed,
                plan: plans.targeted,
                duration: 1
            ),
        ]
        let state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            activeRecoveryLevel: .expanded,
            activePlan: plans.source,
            attempts: attempts,
            matchingDurationSeconds: 2,
            fallbackReasons: []
        )

        let restored = try state.restoredRecovery()

        XCTAssertEqual(restored.recoveryLevel, .expanded)
        XCTAssertEqual(restored.activePlan, plans.source)
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
            plan: plans.targeted,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [exactWithoutFaiss],
            activeLevel: .normal,
            activePlan: plans.targeted
        ).restoredRecovery())

        let faissNormal = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.targeted,
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
            activeLevel: .expanded,
            activePlan: plans.source
        ).restoredRecovery())

        let completedExactNormal = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.targeted,
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
            activePlan: plans.targeted
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
            plan: plans.targeted,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissNormal, changedLevelExact],
            activeLevel: .expanded,
            activePlan: plans.targeted
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
            plan: plans.targeted,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            attempts: [faissExpanded, exactNormal],
            activeLevel: .normal,
            activePlan: plans.targeted
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

    func testTargetedAndFullRejectInvalidPolicyHistorySequences() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plans = try makePlans()

        func state(
            mode: PairGraphRecoveryMode,
            attempts: [PairGraphAttemptEvidence],
            activeLevel: PairGraphRecoveryLevel,
            activePlan: ColmapPairPlan
        ) -> PairGraphRecoveryState {
            PairGraphRecoveryState(
                selectedFramesDigest: fixture.selectedFramesDigest,
                imageNames: plans.source.imageNames,
                mode: mode,
                activeRecoveryLevel: activeLevel,
                activePlan: activePlan,
                attempts: attempts,
                matchingDurationSeconds: attempts.reduce(0) {
                    $0 + $1.artifact.durationSeconds
                },
                fallbackReasons: []
            )
        }

        let normal = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.targeted,
            duration: 1
        )
        let skippedMaximum = makeAttempt(
            number: 2,
            matcher: .faiss,
            recoveryLevel: .maximum,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            mode: .targetedExact,
            attempts: [normal, skippedMaximum],
            activeLevel: .maximum,
            activePlan: plans.targeted
        ).restoredRecovery())

        let expanded = makeAttempt(
            number: 1,
            matcher: .faiss,
            recoveryLevel: .expanded,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        let decreasedNormal = makeAttempt(
            number: 2,
            matcher: .faiss,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            mode: .targetedExact,
            attempts: [expanded, decreasedNormal],
            activeLevel: .normal,
            activePlan: plans.targeted
        ).restoredRecovery())

        let exactNormal = makeAttempt(
            number: 2,
            matcher: .exact,
            recoveryLevel: .normal,
            outcome: .completed,
            plan: plans.targeted,
            duration: 1
        )
        let faissAfterExact = makeAttempt(
            number: 3,
            matcher: .faiss,
            recoveryLevel: .expanded,
            outcome: .completed,
            plan: plans.source,
            duration: 1
        )
        XCTAssertThrowsError(try state(
            mode: .fullExact,
            attempts: [normal, exactNormal, faissAfterExact],
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
            mode: .targetedExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.targeted,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        state.activePairListDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try save(state, fixture: fixture))

        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .targetedExact,
            activeRecoveryLevel: .expanded,
            activePlan: plans.targeted,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))

        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .sameScheduleExact,
            activeRecoveryLevel: .normal,
            activePlan: plans.targeted,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))

        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .fullExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.targeted,
            attempts: [policy],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))

        let roleChangedTarget = try ColmapPairPlan.persisted(
            imageNames: plans.source.imageNames,
            scheduledPairs: [
                ColmapScheduledPair("a.jpg", "b.jpg", role: .retrieval),
                ColmapScheduledPair("b.jpg", "c.jpg", role: .local),
                ColmapScheduledPair("c.jpg", "d.jpg", role: .local),
            ]
        )
        state = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .targetedExact,
            activeRecoveryLevel: .maximum,
            activePlan: roleChangedTarget,
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
            activeRecoveryLevel: .maximum,
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
            mode: .targetedExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.targeted,
            attempts: [noncontiguous],
            matchingDurationSeconds: 1,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(state, fixture: fixture))
    }

    func testRecoveryHistoryMustDescribePendingExactWork() throws {
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
        let completedTarget = makeAttempt(
            number: 2,
            purpose: .targetedExactGraphRecovery,
            matcher: .exact,
            outcome: .completed,
            plan: plans.targeted,
            duration: 2
        )
        let completedFull = makeAttempt(
            number: 3,
            purpose: .fullExactGraphRecovery,
            matcher: .exact,
            outcome: .completed,
            plan: plans.source,
            duration: 3
        )

        let staleTarget = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .targetedExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.targeted,
            attempts: [policy, completedTarget],
            matchingDurationSeconds: 3,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(staleTarget, fixture: fixture))

        let staleFull = PairGraphRecoveryState(
            selectedFramesDigest: fixture.selectedFramesDigest,
            imageNames: plans.source.imageNames,
            mode: .fullExact,
            activeRecoveryLevel: .maximum,
            activePlan: plans.source,
            attempts: [policy, completedTarget, completedFull],
            matchingDurationSeconds: 6,
            fallbackReasons: []
        )
        XCTAssertThrowsError(try save(staleFull, fixture: fixture))
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
            activeRecoveryLevel: .maximum,
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

    private func makeProject() throws -> (
        root: URL,
        paths: ProjectPaths,
        selectedFramesDigest: String
    ) {
        let root = try TestFileBuilder.makeTempDir()
        let projectURL = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let imageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
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

    private func makePlans() throws -> (source: ColmapPairPlan, targeted: ColmapPairPlan) {
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
        purpose: PairGraphAttemptPurpose = .policy,
        matcher: DescriptorMatcher,
        recoveryLevel: PairGraphRecoveryLevel = .maximum,
        outcome: PairMatchingAttemptOutcome,
        plan: ColmapPairPlan,
        duration: Double
    ) -> PairGraphAttemptEvidence {
        let completedCount = outcome == .completed ? plan.pairs.count : 0
        return PairGraphAttemptEvidence(
            purpose: purpose,
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: number,
                matcher: matcher,
                recoveryLevel: recoveryLevel,
                outcome: outcome,
                scheduledPairCount: plan.pairs.count,
                attemptedPairCount: completedCount,
                rawMatchedPairCount: completedCount,
                spatiallyVerifiedPairCount: completedCount,
                durationSeconds: duration
            ),
            scheduledPairs: plan.pairs
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
            activeRecoveryLevel: .maximum,
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
