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
        budget: GeometryWorkerBudget
    ) -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
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
        budget: GeometryWorkerBudget
    ) -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
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
        exitStatus: Int32 = 0
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
            exitStatus: exitStatus,
            succeeded: exitStatus == 0
        )
    }

    private func nativeAutoInvocation(
        _ command: ColmapWorkerCommandIdentity,
        exitStatus: Int32 = 0,
        mappingAttemptOrdinal: Int? = nil
    ) -> ColmapWorkerInvocationEvidence {
        ColmapWorkerInvocationEvidence(
            command: command,
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            threadPolicy: .nativeAuto,
            argvWorkerCount: nil,
            explicitThreadEnvironment: [:],
            removedThreadEnvironmentKeysSHA256:
                GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256,
            effectiveSanitizedThreadEnvironment: [:],
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
#endif
