#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryWorkerExecutionRecorderTests: XCTestCase {
    func testMappingInvocationsRequireBegunAttemptAndPersistItsOrdinalAcrossRecovery() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )

        XCTAssertThrowsError(try recorder.record(nativeAutoInvocation(.mapper)))

        XCTAssertEqual(try recorder.beginMappingAttempt(), 1)
        try recorder.record(nativeAutoInvocation(.mapper))
        let reopened = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMatching,
            inputHasVideos: false
        )

        XCTAssertEqual(reopened.maximumRecordedMappingAttemptOrdinal, 1)
        XCTAssertEqual(try reopened.beginMappingAttempt(), 2)
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget)
                .mappingAndRefinementInvocations.map(\.mappingAttemptOrdinal),
            [1]
        )
    }

    func testFailedInvocationPersistsBeforeSuccessfulRecovery() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let failed = boundedInvocation(
            .matchesImporter,
            workers: budget.coupledMatchingWorkers,
            exitStatus: 1
        )

        try recorder.record(failed)

        let beforeRecovery = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertEqual(beforeRecovery.matchingInvocations, [failed])

        let recovered = boundedInvocation(
            .matchesImporter,
            workers: budget.coupledMatchingWorkers
        )
        try recorder.record(recovered)

        let afterRecovery = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertEqual(afterRecovery.matchingInvocations, [failed, recovered])
    }

    func testCompletedVocabularyRetrievalTransitionsIntoRejectedEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let imageNames = (0..<61).map { "image_\($0).jpg" }
        let retrieval = rejectedRetrievalEvidence(imageNames: imageNames)
        let invocation = rejectedRetrievalInvocation(
            attemptOrdinal: 1,
            retrieval: retrieval
        )
        try recorder.record(invocation)

        try recorder.rejectCompletedVocabularyRetrieval(
            pairAttemptOrdinal: 1,
            planBinding: .testingDefault(pairingPolicy: .unorderedRetrieval),
            recoveryLevel: .normal,
            imageNames: imageNames,
            groups: [ColmapPairGroup(imageNames: imageNames, isVideo: false)],
            retrieval: retrieval,
            durationSeconds: 0.5
        )

        let artifact = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertTrue(artifact.vocabularyRetrievalInvocations.isEmpty)
        XCTAssertEqual(artifact.rejectedVocabularyRetrievalInvocations.count, 1)
        XCTAssertEqual(
            artifact.rejectedVocabularyRetrievalInvocations[0].retrievalAttemptOrdinal,
            1
        )
        XCTAssertEqual(
            artifact.rejectedVocabularyRetrievalInvocations[0].invocation,
            invocation
        )
        XCTAssertEqual(
            artifact.rejectedVocabularyRetrievalInvocations[0].retrieval,
            retrieval
        )
    }

    func testRejectedVocabularyRetrievalTransitionFailsClosedForUnmatchedEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let imageNames = (0..<61).map { "image_\($0).jpg" }
        let retrieval = rejectedRetrievalEvidence(imageNames: imageNames)
        let invocation = rejectedRetrievalInvocation(
            attemptOrdinal: 1,
            retrieval: retrieval
        )
        try recorder.record(invocation)
        var forged = retrieval
        forged.outputDigest = String(repeating: "f", count: 64)

        XCTAssertThrowsError(try recorder.rejectCompletedVocabularyRetrieval(
            pairAttemptOrdinal: 1,
            planBinding: .testingDefault(pairingPolicy: .unorderedRetrieval),
            recoveryLevel: .normal,
            imageNames: imageNames,
            groups: [ColmapPairGroup(imageNames: imageNames, isVideo: false)],
            retrieval: forged,
            durationSeconds: 0.5
        ))

        let artifact = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertEqual(artifact.vocabularyRetrievalInvocations, [invocation])
        XCTAssertTrue(artifact.rejectedVocabularyRetrievalInvocations.isEmpty)
    }

    func testNewMappingAttemptClearsASupersededAcceptedSolve() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var stale = emptyArtifact(budget: budget)
        // What a run that died in the publication tail leaves behind.
        stale.mappingAndRefinementInvocations = [
            acceptedMapperInvocation(mappingAttemptOrdinal: 1),
            nativeAutoInvocation(.modelAnalyzer, mappingAttemptOrdinal: 1),
        ]
        try save(stale, paths: fixture.paths, budget: budget)
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMatching,
            inputHasVideos: false
        )

        let ordinal = try recorder.beginMappingAttempt()

        // The ordinal still advances past the dead run's attempt, but its
        // acceptance does not survive to contradict the new one.
        XCTAssertEqual(ordinal, 2)
        XCTAssertTrue(
            try loadArtifact(fixture.paths, budget: budget)
                .mappingAndRefinementInvocations.isEmpty
        )
    }

    func testNewMappingAttemptKeepsARejectedLadderHistory() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var laddered = emptyArtifact(budget: budget)
        // A cadence-fallback rung inside one run: rejected, never published,
        // and publication needs the history to prove the ladder.
        let rejected = rejectedMapperInvocation(mappingAttemptOrdinal: 1)
        laddered.mappingAndRefinementInvocations = [rejected]
        try save(laddered, paths: fixture.paths, budget: budget)
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMatching,
            inputHasVideos: false
        )

        let ordinal = try recorder.beginMappingAttempt()

        XCTAssertEqual(ordinal, 2)
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget)
                .mappingAndRefinementInvocations,
            [rejected]
        )
    }

    func testResealedRetrievalRetryReplacesTheReceiptItFailedOn() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let first = retrievalInvocation(attemptOrdinal: 1, seed: "1")
        let second = retrievalInvocation(attemptOrdinal: 2, seed: "2")
        let failed = retrievalInvocation(attemptOrdinal: 3, seed: "3", exitStatus: 1)
        let resealed = retrievalInvocation(attemptOrdinal: 3, seed: "3")

        try recorder.record(first)
        try recorder.record(second)
        try recorder.record(failed)
        try recorder.record(resealed)

        // One receipt per attempt ordinal, in attempt order: the publication
        // contract zips these against the pair-graph attempts.
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget)
                .vocabularyRetrievalInvocations,
            [first, second, resealed]
        )
    }

    func testReplayedRetrievalDoesNotAccumulateReceipts() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let first = retrievalInvocation(attemptOrdinal: 1, seed: "1")
        let second = retrievalInvocation(attemptOrdinal: 2, seed: "2")

        try recorder.record(first)
        try recorder.record(second)
        try recorder.record(first)
        try recorder.record(second)

        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget)
                .vocabularyRetrievalInvocations,
            [first, second]
        )
    }

    func testResumeRepairsRetrievalReceiptsLeftBehindByAnInterruptedRun() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = retrievalInvocation(attemptOrdinal: 1, seed: "1")
        let second = retrievalInvocation(attemptOrdinal: 2, seed: "2")
        let failed = retrievalInvocation(attemptOrdinal: 3, seed: "3", exitStatus: 1)
        let third = retrievalInvocation(attemptOrdinal: 3, seed: "3")
        var stale = emptyArtifact(budget: budget)
        // The shape a resumed run leaves behind: every attempt replayed, plus
        // the dead process's failed receipt.
        stale.vocabularyRetrievalInvocations = [
            first, second, failed, first, second, third,
        ]
        try save(stale, paths: fixture.paths, budget: budget)

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false
        )

        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget)
                .vocabularyRetrievalInvocations,
            [first, second, third]
        )
    }

    func testResumeKeepsRetrievalReceiptsThatAreNotProvablyRedundant() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = retrievalInvocation(attemptOrdinal: 1, seed: "1")
        let divergent = retrievalInvocation(attemptOrdinal: 1, seed: "2")
        let unresolved = retrievalInvocation(attemptOrdinal: 2, seed: "3", exitStatus: 1)
        var ambiguous = emptyArtifact(budget: budget)
        ambiguous.vocabularyRetrievalInvocations = [first, divergent, unresolved]
        try save(ambiguous, paths: fixture.paths, budget: budget)

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false
        )

        // Two different retrievals for one ordinal, and a failure with no
        // successor, are real inconsistencies: leave them for validation.
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget)
                .vocabularyRetrievalInvocations,
            [first, divergent, unresolved]
        )
    }

    func testDiscardUnacceptedMatcherInvocationRollsBackOnlyTheActiveAttempt() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let first = boundedInvocation(
            .matchesImporter,
            workers: budget.coupledMatchingWorkers,
            pairExecution: pairExecution(attemptOrdinal: 1)
        )
        let interrupted = boundedInvocation(
            .matchesImporter,
            workers: budget.coupledMatchingWorkers,
            exitStatus: SIGINT,
            pairExecution: pairExecution(attemptOrdinal: 2)
        )
        let retrieval = boundedInvocation(
            .localVocabularyRetriever,
            workers: budget.vocabularyRetrievalWorkers,
            pairExecution: pairExecution(
                attemptOrdinal: 2,
                pairListDigest: nil,
                retrievalRequestDigest: String(repeating: "b", count: 64),
                retrievalOutputDigest: String(repeating: "c", count: 64)
            )
        )
        try recorder.record(first)
        try recorder.record(retrieval)
        try recorder.record(interrupted)

        try recorder.discardUnacceptedMatcherInvocation(attemptOrdinal: 2)

        let recovered = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertEqual(recovered.matchingInvocations, [first])
        XCTAssertEqual(recovered.vocabularyRetrievalInvocations, [retrieval])
    }

    func testDiscardUnacceptedMatcherInvocationRemovesDuplicateCrashResidue() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let interrupted = boundedInvocation(
            .matchesImporter,
            workers: budget.coupledMatchingWorkers,
            exitStatus: SIGINT,
            pairExecution: pairExecution(attemptOrdinal: 1)
        )
        try recorder.record(interrupted)
        try recorder.record(interrupted)

        try recorder.discardUnacceptedMatcherInvocation(attemptOrdinal: 1)

        XCTAssertTrue(
            try loadArtifact(fixture.paths, budget: budget)
                .matchingInvocations.isEmpty
        )
    }

    func testPlanChangePreservesCompletedEvidenceAndClearsInvalidatedEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seed = completeArtifact(budget: budget)
        try save(seed, paths: fixture.paths, budget: budget)

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false,
            resetForPlanChange: true
        )

        let resumed = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertEqual(resumed.videoSourceAnalysis, seed.videoSourceAnalysis)
        XCTAssertEqual(
            resumed.featureExtractionInvocations,
            seed.featureExtractionInvocations
        )
        XCTAssertTrue(resumed.matchingInvocations.isEmpty)
        XCTAssertTrue(resumed.vocabularyRetrievalInvocations.isEmpty)
        XCTAssertTrue(resumed.mappingAndRefinementInvocations.isEmpty)
    }

    func testPlanChangeBeforeFrameExtractionClearsAllEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try save(completeArtifact(budget: budget), paths: fixture.paths, budget: budget)

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .importInput,
            inputHasVideos: true,
            resetForPlanChange: true
        )

        let resumed = try loadArtifact(fixture.paths, budget: budget)
        XCTAssertEqual(resumed.videoSourceAnalysis, zeroVideoEvidence)
        XCTAssertTrue(resumed.featureExtractionInvocations.isEmpty)
        XCTAssertTrue(resumed.matchingInvocations.isEmpty)
        XCTAssertTrue(resumed.vocabularyRetrievalInvocations.isEmpty)
        XCTAssertTrue(resumed.mappingAndRefinementInvocations.isEmpty)
    }

    func testRuntimeClosureChangeWinsOverPlanRebaseAndForcesSafeRecovery() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleClosure = makeColmapRuntimeClosureEvidence()
        let currentClosure = makeColmapRuntimeClosureEvidence(
            executableSHA256: String(repeating: "c", count: 64),
            openMPSHA256: String(repeating: "d", count: 64)
        )
        try save(
            completeArtifact(budget: budget, runtimeClosure: staleClosure),
            paths: fixture.paths,
            budget: budget
        )

        let reopened = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            runtimeClosure: currentClosure,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false,
            resetForPlanChange: true
        )

        XCTAssertEqual(reopened.maximumSafeResumeBoundary, .selectFrames)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))
        XCTAssertEqual(
            try quarantinedLedgers(
                in: fixture.paths,
                prefix: "worker_execution.stale-runtime-closure-"
            ).count,
            1
        )
        try reopened.commitRecoveryBaseline()
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget),
            emptyArtifact(budget: budget, runtimeClosure: currentClosure)
        )
    }

    func testRuntimeClosureRebindRejectsAChangedClosureWithoutRewritingEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtimeClosure = makeColmapRuntimeClosureEvidence()
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            runtimeClosure: runtimeClosure,
            resumeAfter: nil,
            inputHasVideos: false
        )
        let original = try Data(contentsOf: fixture.paths.workerExecutionURL)

        XCTAssertThrowsError(try recorder.rebindColmapRuntimeClosure(
            makeColmapRuntimeClosureEvidence(
                executableSHA256: String(repeating: "c", count: 64),
                openMPSHA256: String(repeating: "d", count: 64)
            )
        )) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .invalidRuntimeClosure
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.workerExecutionURL), original)
    }

    func testBudgetRebaseSucceedsWhenResumeBoundaryClearsAffectedStage() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldArtifact = completeArtifact(budget: budget)
        try save(oldArtifact, paths: fixture.paths, budget: budget)
        var revisedBudget = budget
        revisedBudget.coupledMatchingWorkers += 2

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: revisedBudget,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false,
            resetForPlanChange: true
        )

        let rebased = try loadArtifact(fixture.paths, budget: revisedBudget)
        XCTAssertEqual(rebased.resolvedBudget, revisedBudget)
        XCTAssertEqual(
            rebased.featureExtractionInvocations,
            oldArtifact.featureExtractionInvocations
        )
        XCTAssertTrue(rebased.matchingInvocations.isEmpty)
        XCTAssertTrue(rebased.vocabularyRetrievalInvocations.isEmpty)
        XCTAssertTrue(rebased.mappingAndRefinementInvocations.isEmpty)
    }

    func testBudgetRebaseFailsClosedWhenResumeBoundaryPreservesAffectedStage() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldArtifact = completeArtifact(budget: budget)
        try save(oldArtifact, paths: fixture.paths, budget: budget)
        var revisedBudget = budget
        revisedBudget.coupledMatchingWorkers += 2

        XCTAssertThrowsError(try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: revisedBudget,
            resumeAfter: .sfmMatching,
            inputHasVideos: false,
            resetForPlanChange: true
        )) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .workerBudgetMismatch
            )
        }

        XCTAssertEqual(try loadArtifact(fixture.paths, budget: budget), oldArtifact)
    }

    func testOrdinaryPhotoResumeRecoversAfterBudgetRebaseCrashesBeforeMetadataCommit() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try save(completeArtifact(budget: budget), paths: fixture.paths, budget: budget)
        var revisedBudget = budget
        revisedBudget.coupledMatchingWorkers += 2

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: revisedBudget,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false,
            resetForPlanChange: true
        )
        let rebasedData = try Data(contentsOf: fixture.paths.workerExecutionURL)

        let reopened = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmFeatures,
            inputHasVideos: false
        )

        XCTAssertEqual(reopened.maximumSafeResumeBoundary, .selectFrames)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))
        let stale = try quarantinedLedgers(
            in: fixture.paths,
            prefix: "worker_execution.stale-budget-"
        )
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(try Data(contentsOf: stale[0]), rebasedData)
        XCTAssertEqual(try quarantinedLedgers(in: fixture.paths), [])

        try reopened.commitRecoveryBaseline()
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget),
            emptyArtifact(budget: budget)
        )
    }

    func testOrdinaryVideoResumeWithStaleBudgetRewindsBeforeSourceAnalysis() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var revisedBudget = budget
        revisedBudget.featureExtractionWorkers -= 2
        try save(
            completeArtifact(budget: revisedBudget),
            paths: fixture.paths,
            budget: revisedBudget
        )

        let reopened = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: true
        )

        XCTAssertEqual(reopened.maximumSafeResumeBoundary, .importInput)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))
        XCTAssertEqual(
            try quarantinedLedgers(
                in: fixture.paths,
                prefix: "worker_execution.stale-budget-"
            ).count,
            1
        )
    }

    func testValidHardLinkedStaleBudgetLedgerFailsClosed() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var revisedBudget = budget
        revisedBudget.featureExtractionWorkers -= 2
        try save(
            completeArtifact(budget: revisedBudget),
            paths: fixture.paths,
            budget: revisedBudget
        )
        let outside = fixture.root.appendingPathComponent("outside-worker.json")
        try FileManager.default.linkItem(
            at: fixture.paths.workerExecutionURL,
            to: outside
        )

        XCTAssertThrowsError(try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: false
        )) { error in
            XCTAssertEqual(
                error as? GeometryWorkerExecutionArtifactError,
                .invalidLocation
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(
            try quarantinedLedgers(
                in: fixture.paths,
                prefix: "worker_execution.stale-budget-"
            ),
            []
        )
    }

    func testOrdinaryResumePreservesInFlightStageEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var interrupted = completeArtifact(budget: budget)
        interrupted.mappingAndRefinementInvocations.append(
            nativeAutoInvocation(
                .bundleAdjuster,
                exitStatus: 1,
                mappingAttemptOrdinal: 1
            )
        )
        try save(interrupted, paths: fixture.paths, budget: budget)

        _ = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMatching,
            inputHasVideos: false
        )

        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget),
            interrupted
        )
    }

    func testValidatedSnapshotDefersPublicationSemanticsToArtifactStore() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: nil,
            inputHasVideos: false
        )

        XCTAssertEqual(
            try recorder.validatedArtifact(),
            emptyArtifact(budget: budget)
        )
    }

    func testCorruptSingleLinkLedgerIsQuarantinedAndBaselineIsDeferred() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fixture.paths.workerExecutionURL, options: [.atomic])

        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: false
        )

        XCTAssertEqual(recorder.maximumSafeResumeBoundary, .selectFrames)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))
        let quarantined = try quarantinedLedgers(in: fixture.paths)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantined[0]), corrupt)

        try recorder.commitRecoveryBaseline()
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget),
            emptyArtifact(budget: budget)
        )
    }

    func testMissingExpectedLedgerDefersBaselineAndForcesVideoSourceAnalysisBoundary() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMatching,
            inputHasVideos: true
        )

        XCTAssertEqual(recorder.maximumSafeResumeBoundary, .importInput)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))
        try recorder.commitRecoveryBaseline()
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget),
            emptyArtifact(budget: budget)
        )
    }

    func testMissingLedgerBeforeEvidenceBoundaryCreatesBaselineWithoutRecovery() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let recorder = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .selectFrames,
            inputHasVideos: false
        )

        XCTAssertNil(recorder.maximumSafeResumeBoundary)
        XCTAssertEqual(
            try loadArtifact(fixture.paths, budget: budget),
            emptyArtifact(budget: budget)
        )
    }

    func testCorruptLedgerRecoverySurvivesCrashBeforeBaselineCommit() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("{not-json".utf8).write(
            to: fixture.paths.workerExecutionURL,
            options: [.atomic]
        )

        let firstAttempt = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: false
        )
        XCTAssertEqual(firstAttempt.maximumSafeResumeBoundary, .selectFrames)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.workerExecutionURL.path
        ))

        let secondAttempt = try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: false
        )
        XCTAssertEqual(secondAttempt.maximumSafeResumeBoundary, .selectFrames)
        XCTAssertEqual(try quarantinedLedgers(in: fixture.paths).count, 1)
        try secondAttempt.commitRecoveryBaseline()
        XCTAssertNoThrow(try loadArtifact(fixture.paths, budget: budget))
    }

    func testCorruptSymlinkLedgerFailsClosedWithoutMovingTarget() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-worker.json")
        let contents = Data("{not-json".utf8)
        try contents.write(to: outside, options: [.atomic])
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.workerExecutionURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: false
        ))
        XCTAssertEqual(try Data(contentsOf: outside), contents)
        XCTAssertEqual(try quarantinedLedgers(in: fixture.paths), [])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.paths.workerExecutionURL.path
        ))
    }

    func testCorruptHardLinkedLedgerFailsClosedWithoutMovingEitherLink() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-worker.json")
        let contents = Data("{not-json".utf8)
        try contents.write(to: outside, options: [.atomic])
        try FileManager.default.linkItem(
            at: outside,
            to: fixture.paths.workerExecutionURL
        )

        XCTAssertThrowsError(try GeometryWorkerExecutionRecorder(
            paths: fixture.paths,
            budget: budget,
            resumeAfter: .sfmMapping,
            inputHasVideos: false
        ))
        XCTAssertEqual(try Data(contentsOf: outside), contents)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.workerExecutionURL),
            contents
        )
        XCTAssertEqual(try quarantinedLedgers(in: fixture.paths), [])
    }

    private let budget = GeometryWorkerBudget(
        featureExtractionWorkers: 12,
        coupledMatchingWorkers: 8,
        vocabularyRetrievalWorkers: 6,
        maximumConcurrentVideoSourceAnalysisTasks: 4
    )

    private let zeroVideoEvidence = VideoSourceAnalysisExecutionEvidence(
        videoSourceCount: 0,
        startedAnalysisTaskCount: 0,
        peakInFlightAnalysisTaskCount: 0
    )

    private func completeArtifact(
        budget: GeometryWorkerBudget,
        runtimeClosure: ColmapRuntimeClosureEvidence = makeColmapRuntimeClosureEvidence()
    ) -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
            colmapRuntimeClosure: runtimeClosure,
            resolvedBudget: budget,
            featureExtractionInvocations: [
                boundedInvocation(
                    .featureExtractor,
                    workers: budget.featureExtractionWorkers
                ),
            ],
            matchingInvocations: [
                boundedInvocation(
                    .matchesImporter,
                    workers: budget.coupledMatchingWorkers
                ),
            ],
            vocabularyRetrievalInvocations: [
                boundedInvocation(
                    .localVocabularyRetriever,
                    workers: budget.vocabularyRetrievalWorkers
                ),
            ],
            mappingAndRefinementInvocations: [
                nativeAutoInvocation(.mapper, mappingAttemptOrdinal: 1)
            ],
            videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 2,
                startedAnalysisTaskCount: 4,
                peakInFlightAnalysisTaskCount: 2
            )
        )
    }

    private func emptyArtifact(
        budget: GeometryWorkerBudget,
        runtimeClosure: ColmapRuntimeClosureEvidence = makeColmapRuntimeClosureEvidence()
    ) -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
            colmapRuntimeClosure: runtimeClosure,
            resolvedBudget: budget,
            featureExtractionInvocations: [],
            matchingInvocations: [],
            vocabularyRetrievalInvocations: [],
            mappingAndRefinementInvocations: [],
            videoSourceAnalysis: zeroVideoEvidence
        )
    }

    private func quarantinedLedgers(
        in paths: ProjectPaths,
        prefix: String = "worker_execution.corrupt-"
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: paths.logsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func boundedInvocation(
        _ command: ColmapWorkerCommandIdentity,
        workers: Int,
        exitStatus: Int32 = 0,
        pairExecution: ColmapPairWorkerExecutionEvidence? = nil
    ) -> ColmapWorkerInvocationEvidence {
        let environment = [
            "OMP_NUM_THREADS": "\(workers)",
            "OPENBLAS_NUM_THREADS": "\(workers)",
            "MKL_NUM_THREADS": "\(workers)",
        ]
        return ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: nil,
            threadPolicy: .bounded,
            argvWorkerCount: workers,
            explicitThreadEnvironment: environment,
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: environment,
            pairExecution: pairExecution,
            exitStatus: exitStatus,
            succeeded: exitStatus == 0
        )
    }

    private func pairExecution(
        attemptOrdinal: Int,
        pairListDigest: String? = String(repeating: "a", count: 64),
        retrievalRequestDigest: String? = nil,
        retrievalOutputDigest: String? = nil
    ) -> ColmapPairWorkerExecutionEvidence {
        ColmapPairWorkerExecutionEvidence(
            attemptOrdinal: attemptOrdinal,
            descriptorMatcher: .faiss,
            scheduledPairCount: pairListDigest == nil ? nil : 3,
            pairListDigest: pairListDigest,
            retrievalRequestDigest: retrievalRequestDigest,
            retrievalOutputDigest: retrievalOutputDigest
        )
    }

    private func retrievalInvocation(
        attemptOrdinal: Int,
        seed: String,
        exitStatus: Int32 = 0
    ) -> ColmapWorkerInvocationEvidence {
        boundedInvocation(
            .localVocabularyRetriever,
            workers: budget.vocabularyRetrievalWorkers,
            exitStatus: exitStatus,
            pairExecution: pairExecution(
                attemptOrdinal: attemptOrdinal,
                pairListDigest: nil,
                retrievalRequestDigest: String(repeating: seed, count: 64),
                // A failed retriever writes no output, so it has no digest.
                retrievalOutputDigest: exitStatus == 0
                    ? String(repeating: "a", count: 63) + seed
                    : nil
            )
        )
    }

    private func rejectedRetrievalEvidence(
        imageNames: [String]
    ) -> PairGraphRetrievalAttemptEvidence {
        PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: imageNames,
            queryStride: 1,
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            queryOutcomes: imageNames.map {
                PairGraphRetrievalQueryOutcome(
                    queryImageName: $0,
                    status: .noRankedNeighbors,
                    rankedNeighborImageNames: []
                )
            },
            directedPairLines: []
        )
    }

    private func rejectedRetrievalInvocation(
        attemptOrdinal: Int,
        retrieval: PairGraphRetrievalAttemptEvidence
    ) -> ColmapWorkerInvocationEvidence {
        boundedInvocation(
            .localVocabularyRetriever,
            workers: budget.vocabularyRetrievalWorkers,
            pairExecution: pairExecution(
                attemptOrdinal: attemptOrdinal,
                pairListDigest: nil,
                retrievalRequestDigest: PairGraphEvidenceStore.retrievalRequestDigest(retrieval),
                retrievalOutputDigest: retrieval.outputDigest
            )
        )
    }

    private func acceptedMapperInvocation(
        mappingAttemptOrdinal: Int
    ) -> ColmapWorkerInvocationEvidence {
        mapperInvocation(
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            evaluation: ColmapMapperEvaluationEvidence(
                status: .accepted,
                fallbackTrigger: nil
            )
        )
    }

    private func rejectedMapperInvocation(
        mappingAttemptOrdinal: Int
    ) -> ColmapWorkerInvocationEvidence {
        mapperInvocation(
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            evaluation: ColmapMapperEvaluationEvidence(
                status: .rejected,
                fallbackTrigger: nil
            )
        )
    }

    private func mapperInvocation(
        mappingAttemptOrdinal: Int,
        evaluation: ColmapMapperEvaluationEvidence
    ) -> ColmapWorkerInvocationEvidence {
        var invocation = nativeAutoInvocation(
            .mapper,
            mappingAttemptOrdinal: mappingAttemptOrdinal
        )
        invocation.mapperExecution?.evaluation = evaluation
        return invocation
    }

    private func nativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity,
        exitStatus: Int32 = 0,
        mappingAttemptOrdinal: Int? = nil
    ) -> ColmapWorkerInvocationEvidence {
        let mapperExecution = command == .mapper
            ? ColmapMapperWorkerExecutionEvidence(
                incrementalCadence: .balancedGlobal,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true,
                minimumPairInlierCount: ColmapMappingPolicy.minimumPairInlierCount,
                pairGraphAttemptOrdinal: 1,
                pairListDigest: String(repeating: "a", count: 64),
                descriptorMatcher: .faiss,
                matchingDatabaseDigest: String(repeating: "b", count: 64),
                evaluation: nil
            )
            : nil
        return ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            threadPolicy: .nativeAuto,
            argvWorkerCount: nil,
            explicitThreadEnvironment: [:],
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: [:],
            mapperExecution: mapperExecution,
            exitStatus: exitStatus,
            succeeded: exitStatus == 0
        )
    }

    private func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        return (root, paths)
    }

    private func save(
        _ artifact: GeometryWorkerExecutionArtifact,
        paths: ProjectPaths,
        budget: GeometryWorkerBudget
    ) throws {
        try GeometryWorkerExecutionArtifactStore.save(
            artifact,
            to: paths.workerExecutionURL,
            expectedBudget: budget,
            projectPaths: paths
        )
    }

    private func loadArtifact(
        _ paths: ProjectPaths,
        budget: GeometryWorkerBudget
    ) throws -> GeometryWorkerExecutionArtifact {
        try GeometryWorkerExecutionArtifactStore.load(
            from: paths.workerExecutionURL,
            expectedBudget: budget,
            projectPaths: paths
        )
    }
}

private extension GeometryWorkerExecutionRecorder {
    convenience init(
        paths: ProjectPaths,
        budget: GeometryWorkerBudget,
        resumeAfter lastCompletedStage: PipelineStage?,
        inputHasVideos: Bool,
        resetForPlanChange: Bool = false
    ) throws {
        try self.init(
            paths: paths,
            budget: budget,
            runtimeClosure: makeColmapRuntimeClosureEvidence(),
            resumeAfter: lastCompletedStage,
            inputHasVideos: inputHasVideos,
            resetForPlanChange: resetForPlanChange
        )
    }
}
#endif
