import Foundation
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class GeometryRecoveryIntegrationTests: XCTestCase {
    func testCancelledDa3MappingResumesSeededRefinementWithoutRepeatingPreparation() async throws {
        let fixture = try await makeFixture(
            named: "Da3MappingResume",
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let plan = try da3Plan(for: fixture)
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: successfulResult,
                onRun: { arguments in try self.writeDa3SeedArtifacts(for: arguments) }
            ),
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: successfulResult,
                onRun: { _ in throw CancellationError() }
            ),
        ])

        do {
            try await makePipeline(
                fixture: fixture,
                runner: firstRunner,
                candidateRoute: .da3,
                resolvedPlan: plan
            ).run { _ in }
            XCTFail("Expected DA3 refinement cancellation")
        } catch is CancellationError {
            // The mapping boundary must be durable before the first triangulator launch.
        }

        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.checkpoint?.stage, .sfmMapping)
        XCTAssertNil(interrupted.checkpoint?.details)
        XCTAssertEqual(interrupted.geometryRecovery?.activeBackend, .da3)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 1)
        XCTAssertNil(interrupted.geometryRecovery?.colmapComputeMode)
        XCTAssertEqual(
            try makePipeline(
                fixture: fixture,
                runner: MockSubprocessRunner(scripts: []),
                candidateRoute: .da3,
                resolvedPlan: plan
            ).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: interrupted
            ),
            .valid,
            "Accepted DA3 matching evidence must remain durable across cancellation."
        )

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: successfulResult,
                onRun: { arguments in
                    guard let output = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    try self.writeSparseModel(
                        at: URL(fileURLWithPath: output, isDirectory: true),
                        for: fixture
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["bundle_adjuster"],
                result: successfulResult,
                onRun: { arguments in
                    guard let output = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    try self.writeSparseModel(
                        at: URL(fileURLWithPath: output, isDirectory: true),
                        for: fixture
                    )
                }
            ),
            analyzerScript(for: fixture),
        ])
        try await makePipeline(
            fixture: fixture,
            runner: resumeRunner,
            candidateRoute: .da3,
            resolvedPlan: plan
        ).run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["point_triangulator", "bundle_adjuster", "model_analyzer"]
        )
        XCTAssertFalse(resumeRunner.calls.contains { $0.0 == fixture.toolchain.da3.sfmTool.path })
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let geometry = try loadGeometry(for: fixture)
        XCTAssertEqual(geometry.mapping.attemptCount, 2)
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "interrupted mapping resumed"
        )
        XCTAssertNil(finished.geometryRecovery)
    }

    func testDa3MatchingRecoveryRejectsNondeterministicFeatureIdentity() async throws {
        let fixture = try await makeFixture(
            named: "Da3MatchingIdentityCorruption",
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let plan = try da3Plan(for: fixture)
        let preparationRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: successfulResult,
                onRun: { arguments in try self.writeDa3SeedArtifacts(for: arguments) }
            ),
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
        ])
        try await makePipeline(
            fixture: fixture,
            runner: preparationRunner,
            candidateRoute: .da3,
            resolvedPlan: plan,
            stopAfterStage: .sfmMatching
        ).run { _ in }

        var evidence = try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        let expectedNames = evidence.imageNames.sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
        XCTAssertGreaterThanOrEqual(expectedNames.count, 2)
        try withDatabase(at: fixture.paths.colmapDatabaseURL) { database in
            try executeSQL(
                "BEGIN IMMEDIATE TRANSACTION;",
                operation: "begin identity corruption transaction",
                databaseURL: fixture.paths.colmapDatabaseURL,
                in: database
            )
            do {
                try executeSQL(
                    "UPDATE images SET name = '__easysplat_identity_swap__' WHERE image_id = 1;" +
                    "UPDATE images SET name = '\(sqlQuoted(expectedNames[0]))' WHERE image_id = 2;" +
                    "UPDATE images SET name = '\(sqlQuoted(expectedNames[1]))' WHERE image_id = 1;",
                    operation: "swap deterministic image identities",
                    databaseURL: fixture.paths.colmapDatabaseURL,
                    in: database
                )
                try executeSQL(
                    "COMMIT;",
                    operation: "commit identity corruption transaction",
                    databaseURL: fixture.paths.colmapDatabaseURL,
                    in: database
                )
            } catch {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
        evidence.featureDatabaseDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        let metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(
            try makePipeline(
                fixture: fixture,
                runner: MockSubprocessRunner(scripts: []),
                candidateRoute: .da3,
                resolvedPlan: plan
            ).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: metadata
            ),
            .corrupt,
            "DA3 recovery must reject completion-order image IDs even when row counts and the refreshed feature digest still look valid."
        )
    }

    func testCpuFallbackRemainsCpuAfterCancellationAndRelaunch() async throws {
        let fixture = try await makeFixture(named: "CpuFallbackResume")
        let gpuFailure = SubprocessResult(
            exitCode: 1,
            terminationReason: .exit,
            stdout: "",
            stderr: "GPU initialization failed"
        )
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: gpuFailure,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.use_gpu", in: arguments), "1")
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.use_gpu", in: arguments), "0")
                    throw CancellationError()
                }
            ),
        ])

        do {
            try await makePipeline(
                fixture: fixture,
                runner: firstRunner,
                colmapGPUSupport: true
            ).run { _ in }
            XCTFail("Expected cancellation during the CPU retry")
        } catch is CancellationError {
            // The compute mode must survive the process boundary.
        }

        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.geometryRecovery?.activeBackend, .colmap)
        XCTAssertEqual(interrupted.geometryRecovery?.colmapComputeMode, .cpu)
        XCTAssertEqual(
            interrupted.geometryRecovery?.mappingFallbackReasons,
            ["CPU recovery after GPU failure"]
        )

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.use_gpu", in: arguments), "0")
                    try self.writeFeatureDatabase(for: arguments)
                }
            ),
            matchingScript(for: fixture),
        ] + successfulGeometryScripts(for: fixture, includePreparation: false))
        try await makePipeline(
            fixture: fixture,
            runner: resumeRunner,
            colmapGPUSupport: true
        ).run(resumeFrom: .selectFrames) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.filter { $0.1.first == "feature_extractor" }.count,
            1,
            "Relaunch must not probe the already-failed GPU path again."
        )
        XCTAssertNil(try ProjectMetadataStore.load(from: fixture.paths.metadataURL).geometryRecovery)
    }

    func testNormalCpuResumeDoesNotClaimThatGpuRecoverySucceeded() async throws {
        let fixture = try await makeFixture(named: "NormalCpuResume")
        let cancellationRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.use_gpu", in: arguments), "0")
                    throw CancellationError()
                }
            ),
        ])

        do {
            try await makePipeline(
                fixture: fixture,
                runner: cancellationRunner,
                colmapGPUSupport: false
            ).run { _ in }
            XCTFail("Expected normal CPU feature extraction cancellation")
        } catch is CancellationError {
            // A normal CPU route is resumable, but it is not a GPU fallback.
        }

        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.geometryRecovery?.colmapComputeMode, .cpu)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingFallbackReasons, [])

        let resumeRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: true)
        )
        let events = GeometryRecoveryEventSink()
        try await makePipeline(
            fixture: fixture,
            runner: resumeRunner,
            colmapGPUSupport: false
        ).run(resumeFrom: .selectFrames) { events.append($0) }

        XCTAssertNil(events.stageLog(containing: "Retry on CPU succeeded."))
    }

    func testDifferentRouteRecoveryIsDiscardedBeforeRestartingResolvedDa3Route() async throws {
        let fixture = try await makeFixture(
            named: "DifferentRouteRecovery",
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let plan = try da3Plan(for: fixture)
        let preparationRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: successfulResult,
                onRun: { arguments in try self.writeDa3SeedArtifacts(for: arguments) }
            ),
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
        ])
        try await makePipeline(
            fixture: fixture,
            runner: preparationRunner,
            candidateRoute: .da3,
            resolvedPlan: plan,
            stopAfterStage: .sfmMatching
        ).run { _ in }

        var interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let previousRecovery = try XCTUnwrap(interrupted.geometryRecovery)
        interrupted.geometryRecovery = GeometryRecoveryState(
            selectedFramesDigest: previousRecovery.selectedFramesDigest,
            orderedImageNames: previousRecovery.orderedImageNames,
            activeBackend: .colmap,
            mappingAttemptCount: previousRecovery.mappingAttemptCount,
            mappingFallbackReasons: ["da3 fallback to colmap"],
            colmapComputeMode: .gpu,
            plannedIncrementalCadence: plan.incrementalMappingCadence,
            activeIncrementalCadence: plan.incrementalMappingCadence
        )
        try ProjectMetadataStore.save(interrupted, to: fixture.paths.metadataURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.colmapSeedModelURL.path))

        let staleWorkerExecution = try Data(contentsOf: fixture.paths.workerExecutionURL)
        XCTAssertFalse(
            try Data(contentsOf: fixture.paths.colmapDatabaseURL).isEmpty
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.colmapFeatureEvidenceURL.path
        ))
        try Data("stale pair graph".utf8).write(
            to: fixture.paths.pairGraphEvidenceURL,
            options: .atomic
        )
        let staleTraining = fixture.paths.trainingURL.appendingPathComponent(
            "stale-route.bin"
        )
        let staleSparse = fixture.paths.colmapSparseURL.appendingPathComponent(
            "stale-route.txt"
        )
        try Data("stale geometry".utf8).write(
            to: fixture.paths.geometryManifestURL,
            options: .atomic
        )
        try Data("stale training".utf8).write(to: staleTraining, options: .atomic)
        try Data("stale sparse".utf8).write(to: staleSparse, options: .atomic)

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: fixture.paths.colmapFeatureEvidenceURL.path
                        )
                    )
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: fixture.paths.pairGraphEvidenceURL.path
                        )
                    )
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: fixture.paths.colmapDatabaseURL.path
                        )
                    )
                    XCTAssertFalse(FileManager.default.fileExists(
                        atPath: fixture.paths.colmapSeedModelURL.path
                    ))
                    XCTAssertFalse(FileManager.default.fileExists(
                        atPath: fixture.paths.geometryManifestURL.path
                    ))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: staleTraining.path))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: staleSparse.path))
                    XCTAssertNotEqual(
                        try Data(contentsOf: fixture.paths.workerExecutionURL),
                        staleWorkerExecution,
                        "Fail-closed recovery must discard the different route's worker ledger."
                    )
                    try self.writeDa3SeedArtifacts(for: arguments)
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: fixture.paths.colmapDatabaseURL.path
                        ),
                        "DA3 must discard the stale route database before feature extraction."
                    )
                    try self.writeFeatureDatabase(for: arguments)
                }
            ),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: successfulResult,
                onRun: { arguments in
                    guard let output = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    try self.writeSparseModel(
                        at: URL(fileURLWithPath: output, isDirectory: true),
                        for: fixture
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["bundle_adjuster"],
                result: successfulResult,
                onRun: { arguments in
                    guard let output = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    try self.writeSparseModel(
                        at: URL(fileURLWithPath: output, isDirectory: true),
                        for: fixture
                    )
                }
            ),
            analyzerScript(for: fixture),
        ])
        try await makePipeline(
            fixture: fixture,
            runner: resumeRunner,
            candidateRoute: .da3,
            resolvedPlan: plan
        ).run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            [
                "--images",
                "feature_extractor",
                "matches_importer",
                "point_triangulator",
                "bundle_adjuster",
                "model_analyzer",
            ]
        )
        let geometry = try loadGeometry(for: fixture)
        XCTAssertEqual(geometry.provenance.model?.identifier, "DA3-BASE")
        XCTAssertNil(geometry.mapping.fallbackReason)
    }

    func testConditioningRejectedDa3FailsWithoutClassicalFallback() async throws {
        let fixture = try await makeFixture(
            named: "ConditioningRejectedDa3",
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let plan = try da3Plan(for: fixture)
        XCTAssertEqual(plan.geometryBackend, .da3)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: successfulResult,
                onRun: { arguments in try self.writeDa3SeedArtifacts(for: arguments) }
            ),
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: successfulResult,
                onRun: { arguments in
                    guard let output = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    try self.writeSparseModel(
                        at: URL(fileURLWithPath: output, isDirectory: true),
                        for: fixture,
                        cameraCenterStep: 0
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["bundle_adjuster"],
                result: successfulResult,
                onRun: { arguments in
                    guard let output = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    try self.writeSparseModel(
                        at: URL(fileURLWithPath: output, isDirectory: true),
                        for: fixture,
                        cameraCenterStep: 0
                    )
                }
            ),
        ])
        let events = GeometryRecoveryEventSink()

        await XCTAssertThrowsErrorAsync {
            try await self.makePipeline(
                fixture: fixture,
                runner: runner,
                candidateRoute: .da3,
                resolvedPlan: plan
            ).run { events.append($0) }
        }

        XCTAssertEqual(
            runner.calls.compactMap { $0.1.first },
            [
                "--images",
                "feature_extractor",
                "matches_importer",
                "point_triangulator",
                "bundle_adjuster",
            ],
            "A rejected DA3 candidate must not be relabeled as a successful classical run."
        )
        XCTAssertNil(events.stageLog(containing: "Falling back to COLMAP"))
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.geometryManifestURL.path))
        XCTAssertEqual(finished.geometryRecovery?.activeBackend, .da3)
    }

    func testFailedDa3MappingDoesNotStartClassicalRoute() async throws {
        let fixture = try await makeFixture(
            named: "FailedDa3Mapping",
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let plan = try da3Plan(for: fixture)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: successfulResult,
                onRun: { arguments in try self.writeDa3SeedArtifacts(for: arguments) }
            ),
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: SubprocessResult(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "seeded triangulation failed"
                )
            ),
        ])

        await XCTAssertThrowsErrorAsync {
            try await self.makePipeline(
                fixture: fixture,
                runner: runner,
                candidateRoute: .da3,
                resolvedPlan: plan
            ).run { _ in }
        }

        XCTAssertEqual(
            runner.calls.compactMap { $0.1.first },
            [
                "--images",
                "feature_extractor",
                "matches_importer",
                "point_triangulator",
            ],
            "A failed DA3 mapping attempt must be terminal for the candidate route."
        )
        let failed = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.geometryManifestURL.path))
        XCTAssertEqual(failed.geometryRecovery?.activeBackend, .da3)
        XCTAssertEqual(failed.geometryRecovery?.mappingAttemptCount, 1)
        XCTAssertEqual(failed.geometryRecovery?.mappingFallbackReasons, [])
    }

    func testExpandedPairRecoveryResumesExpandedScheduleWithPriorHistory() async throws {
        let fixture = try await makeFixture(
            named: "ExpandedPairRecoveryResume",
            imageCount: 8,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .automatic,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let pairSchedules = PairScheduleProbe()
        let lowCoverageReport = "Registered images: 3 / 8\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n"
        let firstRunner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: successfulResult,
                onRun: { arguments in
                    let pairs = try self.pairListLines(for: arguments)
                    XCTAssertEqual(pairs.count, 17)
                    pairSchedules.recordNormal(pairs)
                    try self.writeVerifiedMatches(for: arguments)
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { arguments in
                    try self.writeSparseModel(
                        for: fixture,
                        mapperArguments: arguments,
                        registeredImageCount: 3
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowCoverageReport,
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    try self.writeSparseModel(
                        for: fixture,
                        mapperArguments: arguments,
                        registeredImageCount: 3
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowCoverageReport,
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: successfulResult,
                onRun: { arguments in
                    let pairs = try self.pairListLines(for: arguments)
                    XCTAssertEqual(pairs.count, 28)
                    XCTAssertGreaterThan(pairs.count, pairSchedules.normal.count)
                    pairSchedules.recordExpanded(pairs)
                    throw CancellationError()
                }
            ),
        ])

        do {
            try await makePipeline(fixture: fixture, runner: firstRunner).run { _ in }
            XCTFail("Expected expanded matching cancellation")
        } catch is CancellationError {
            // Recovery must remain bound to the expanded graph and earlier evidence.
        }

        let expandedSchedule = pairSchedules.expanded
        XCTAssertEqual(expandedSchedule.count, 28)
        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.checkpoint?.stage, .sfmMatching)
        XCTAssertEqual(interrupted.geometryRecovery?.activeBackend, .colmap)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 2)
        XCTAssertEqual(interrupted.geometryRecovery?.pendingPairRecoveryLevel, .expanded)
        XCTAssertEqual(
            interrupted.geometryRecovery?.mappingFallbackReasons,
            [
                "mapping cadence retry after quality rejection",
                "Reconstruction coverage was below the acceptance gate",
            ]
        )

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: successfulResult,
                onRun: { arguments in
                    let resumedPairs = try self.pairListLines(for: arguments)
                    XCTAssertEqual(
                        resumedPairs,
                        expandedSchedule,
                        "Resume must continue the pending expanded schedule, not restart normal pairing."
                    )
                    try self.writeVerifiedMatches(for: arguments)
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    try self.writeSparseModel(for: fixture, mapperArguments: arguments)
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        try await makePipeline(fixture: fixture, runner: resumeRunner).run(
            resumeFrom: .sfmMatching
        ) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["matches_importer", "mapper", "model_analyzer"]
        )
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let geometry = try loadGeometry(for: fixture)
        let matcherAttempts = try XCTUnwrap(geometry.pairGraph.measurement?.matcherAttempts)
        XCTAssertEqual(matcherAttempts.map(\.attemptNumber), [1, 2])
        XCTAssertEqual(matcherAttempts.map(\.recoveryLevel), [.normal, .expanded])
        XCTAssertEqual(matcherAttempts.map(\.outcome), [.completed, .completed])
        XCTAssertEqual(matcherAttempts.map(\.scheduledPairCount), [17, 28])
        XCTAssertEqual(geometry.mapping.attemptCount, 3)
        XCTAssertEqual(geometry.mapping.incrementalCadence, .balancedGlobal)
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "mapping cadence retry after quality rejection; Reconstruction coverage was below the acceptance gate"
        )
        XCTAssertNil(finished.geometryRecovery)
    }

    func testAnalyzerOnlyFragmentDoesNotRejectAnOtherwiseAcceptableModel() async throws {
        let fixture = try await makeFixture(
            named: "AnalyzerOnlyFragment",
            imageCount: 30,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .automatic,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let runner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    guard let outputPath = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    let names = try self.selectedImageNames(for: fixture)
                    let sparseRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
                    try self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("0", isDirectory: true),
                        for: fixture,
                        imageNames: Array(names.prefix(27))
                    )
                    let invalidSibling = sparseRoot.appendingPathComponent("1", isDirectory: true)
                    try self.writeSparseModel(
                        at: invalidSibling,
                        for: fixture,
                        imageNames: Array(names.suffix(3))
                    )
                    try "# No real points\n".write(
                        to: invalidSibling.appendingPathComponent("points3D.txt"),
                        atomically: true,
                        encoding: .utf8
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 27 / 30\nPoints: 20\nObservations: 540\nMean track length: 27.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 3 / 30\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])

        try await makePipeline(fixture: fixture, runner: runner).run { _ in }

        XCTAssertEqual(
            runner.calls.compactMap { $0.1.first },
            ["feature_extractor", "matches_importer", "mapper", "model_analyzer"]
        )
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let geometry = try loadGeometry(for: fixture)
        XCTAssertEqual(geometry.mapping.attemptCount, 1)
        XCTAssertNil(geometry.mapping.fallbackReason)
        XCTAssertNil(finished.geometryRecovery)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.paths.colmapSparseURL.path),
            ["0"]
        )
    }

    func testFragmentedMappingRecoveryResumesExpandedScheduleWithoutPublishingTheSplit() async throws {
        let fixture = try await makeFixture(
            named: "FragmentedMappingRecoveryResume",
            imageCount: 30,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .automatic,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let pairSchedules = PairScheduleProbe()
        let events = GeometryRecoveryEventSink()
        let firstRunner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: successfulResult,
                onRun: { arguments in
                    let pairs = try self.pairListLines(for: arguments)
                    pairSchedules.recordNormal(pairs)
                    try self.writeVerifiedMatches(for: arguments)
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    guard let outputPath = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    let names = try self.selectedImageNames(for: fixture)
                    let sparseRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
                    try self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("0", isDirectory: true),
                        for: fixture,
                        imageNames: Array(names.prefix(27))
                    )
                    try self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("1", isDirectory: true),
                        for: fixture,
                        imageNames: Array(names.suffix(3))
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 27 / 30\nPoints: 20\nObservations: 540\nMean track length: 27.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 3 / 30\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    guard let outputPath = self.value(for: "--output_path", in: arguments) else {
                        throw FixtureError.missingArgument
                    }
                    let names = try self.selectedImageNames(for: fixture)
                    let sparseRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
                    try self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("0", isDirectory: true),
                        for: fixture,
                        imageNames: Array(names.prefix(27))
                    )
                    try self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("1", isDirectory: true),
                        for: fixture,
                        imageNames: Array(names.suffix(3))
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 27 / 30\nPoints: 20\nObservations: 540\nMean track length: 27.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 3 / 30\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: successfulResult,
                onRun: { arguments in
                    let pairs = try self.pairListLines(for: arguments)
                    XCTAssertGreaterThan(pairs.count, pairSchedules.normal.count)
                    pairSchedules.recordExpanded(pairs)
                    throw CancellationError()
                }
            ),
        ])

        do {
            try await makePipeline(fixture: fixture, runner: firstRunner).run {
                events.append($0)
            }
            XCTFail("Expected expanded matching cancellation")
        } catch is CancellationError {
            // The recovery intent must survive without accepting either coordinate frame.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.geometryManifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.colmapSparseURL.appendingPathComponent("1").path
        ), "The split mapper output must not be mistaken for canonical publication.")
        XCTAssertNotNil(events.stageLog(containing: "omitted 3 views"))
        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 2)
        XCTAssertEqual(interrupted.geometryRecovery?.pendingPairRecoveryLevel, .expanded)
        XCTAssertEqual(
            interrupted.geometryRecovery?.mappingFallbackReasons,
            [
                "mapping cadence retry after fragmented reconstruction",
                "Camera mapping split recoverable views across separate models",
            ]
        )

        let expandedSchedule = pairSchedules.expanded
        XCTAssertFalse(expandedSchedule.isEmpty)
        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(try self.pairListLines(for: arguments), expandedSchedule)
                    try self.writeVerifiedMatches(for: arguments)
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    try self.writeSparseModel(for: fixture, mapperArguments: arguments)
                }
            ),
            analyzerScript(for: fixture),
        ])
        try await makePipeline(fixture: fixture, runner: resumeRunner).run(
            resumeFrom: .sfmMatching
        ) { _ in }

        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let mapping = try loadGeometry(for: fixture).mapping
        XCTAssertEqual(mapping.attemptCount, 3)
        XCTAssertEqual(mapping.incrementalCadence, .balancedGlobal)
        XCTAssertEqual(
            mapping.fallbackReason,
            "mapping cadence retry after fragmented reconstruction; Camera mapping split recoverable views across separate models"
        )
        XCTAssertNil(finished.geometryRecovery)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.paths.colmapSparseURL.path),
            ["0"]
        )
    }

    func testPersistedGeometrySurvivesResumeBeforeMappingStageCommit() async throws {
        let fixture = try await makeFixture(named: "PersistedGeometryResume")
        let initialRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: true)
        )
        try await makePipeline(fixture: fixture, runner: initialRunner).run { _ in }

        var interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let acceptedArtifact = try loadGeometry(for: fixture)
        let manifestBeforeResume = try Data(contentsOf: fixture.paths.geometryManifestURL)
        interrupted.state = PipelineState(stage: .sfmMatching, lastError: nil)
        interrupted.checkpoint = PipelineCheckpoint(
            stage: .sfmMapping,
            updatedAt: Date(timeIntervalSince1970: 2),
            progressFraction: 1,
            message: "Geometry persisted before stage completion",
            inputReceiptDigest: try RuntimeInputSnapshotLease.receiptDigest(
                metadata: interrupted
            ),
            details: nil
        )
        interrupted.lastRunStartedAt = Date(timeIntervalSince1970: 1)
        try ProjectMetadataStore.save(interrupted, to: fixture.paths.metadataURL)

        let resumeRunner = MockSubprocessRunner(scripts: [])
        try await makePipeline(fixture: fixture, runner: resumeRunner).run(
            resumeFrom: .sfmMatching
        ) { _ in }

        XCTAssertTrue(resumeRunner.calls.isEmpty, "A valid committed geometry artifact must not rerun COLMAP.")
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.geometryManifestURL),
            manifestBeforeResume,
            "Resume must not rewrite the accepted geometry transaction."
        )
        let resumed = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(try loadGeometry(for: fixture), acceptedArtifact)
        XCTAssertEqual(resumed.state.stage, .sfmMapping)
        XCTAssertNil(resumed.checkpoint)
        XCTAssertNil(resumed.lastRunStartedAt)
    }

    func testGeometryPersistenceFailureCannotPublishMappingCompletion() async throws {
        let fixture = try await makeFixture(named: "GeometryPersistenceFailure")
        let blockingManifestScript = MockSubprocessRunner.Script(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["model_analyzer"],
            result: SubprocessResult(
                exitCode: 0,
                terminationReason: .exit,
                stdout: "Registered images: \(fixture.imageCount) / \(fixture.imageCount)\nPoints: 20\nObservations: \(fixture.imageCount * 20)\nMean track length: \(fixture.imageCount).0\nMean reprojection error: 0.5\n",
                stderr: ""
            ),
            onRun: { _ in
                try FileManager.default.createDirectory(
                    at: fixture.paths.geometryManifestURL,
                    withIntermediateDirectories: false
                )
            }
        )
        var scripts = successfulGeometryScripts(for: fixture, includePreparation: true)
        scripts[scripts.count - 1] = blockingManifestScript
        let events = GeometryRecoveryEventSink()

        do {
            try await makePipeline(
                fixture: fixture,
                runner: MockSubprocessRunner(scripts: scripts)
            ).run { events.append($0) }
            XCTFail("Expected geometry persistence to fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        let failed = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.geometryManifestURL.path))
        XCTAssertEqual(failed.state.stage, .sfmMapping)
        XCTAssertNil(failed.checkpoint)
        XCTAssertFalse(events.didFinish(.sfmMapping))
        XCTAssertFalse(
            events.progressFractions(for: .sfmMapping).contains(1),
            "The mapping stage must not report completion before its artifact transaction commits."
        )
    }

    func testCorruptWorkerLedgerIsQuarantinedAndGeometryRegeneratesOnRetry() async throws {
        let fixture = try await makeFixture(named: "CorruptWorkerLedgerRecovery")
        let initialRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: true)
        )
        try await makePipeline(fixture: fixture, runner: initialRunner).run { _ in }

        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fixture.paths.workerExecutionURL, options: [.atomic])
        let retryRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: true)
        )

        try await makePipeline(fixture: fixture, runner: retryRunner).run(
            resumeFrom: .sfmMapping
        ) { _ in }

        XCTAssertEqual(
            retryRunner.calls.compactMap { $0.1.first },
            ["feature_extractor", "matches_importer", "mapper", "model_analyzer"]
        )
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.logsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("worker_execution.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantined.first)), corrupt)
        let geometry = try loadGeometry(for: fixture)
        XCTAssertFalse(geometry.pairGraph.usedLocalVocabularyRetrieval)
        let workerExecution = geometry.workerExecution
        XCTAssertEqual(
            workerExecution.featureExtractionInvocations.map(\.succeeded),
            [true]
        )
        XCTAssertEqual(workerExecution.matchingInvocations.map(\.succeeded), [true])
        XCTAssertEqual(
            workerExecution.mappingAndRefinementInvocations.map(\.succeeded),
            [true, true]
        )
    }

    func testCancelledClassicalMappingPreservesAttemptEvidenceOnResume() async throws {
        let fixture = try await makeFixture(named: "CancelledMappingResume")
        let cancellationRunner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { _ in throw CancellationError() }
            ),
        ])

        do {
            try await makePipeline(fixture: fixture, runner: cancellationRunner).run { _ in }
            XCTFail("Expected mapping cancellation")
        } catch is CancellationError {
            // The in-flight mapping checkpoint and recovery evidence must remain durable.
        }

        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.state.stage, .sfmMatching)
        XCTAssertEqual(interrupted.checkpoint?.stage, .sfmMapping)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.geometryManifestURL.path))
        XCTAssertEqual(interrupted.geometryRecovery?.activeBackend, .colmap)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 1)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingFallbackReasons, [])

        let resumeRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: false)
        )
        try await makePipeline(fixture: fixture, runner: resumeRunner).run(
            resumeFrom: .sfmMatching
        ) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["mapper", "model_analyzer"],
            "Resume must reuse accepted features and matches."
        )
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let mapping = try loadGeometry(for: fixture).mapping
        XCTAssertEqual(mapping.attemptCount, 2)
        XCTAssertEqual(mapping.fallbackReason, "interrupted mapping resumed")
        XCTAssertEqual(finished.state.stage, .sfmMapping)
        XCTAssertNil(finished.checkpoint)
        XCTAssertNil(finished.lastRunStartedAt)
        XCTAssertNil(finished.geometryRecovery)
    }

    func testTerminalRetryAllocatesOrdinalAfterPreservedFailedAttempt() async throws {
        let fixture = try await makeFixture(named: "TerminalMappingRetry")
        let failedRunner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: SubprocessResult(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "mapping failed"
                )
            ),
        ])

        await XCTAssertThrowsErrorAsync {
            try await self.makePipeline(fixture: fixture, runner: failedRunner).run { _ in }
        }
        let failed = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertNotNil(failed.state.lastError)
        XCTAssertEqual(failed.geometryRecovery?.mappingAttemptCount, 1)
        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                from: fixture.paths.workerExecutionURL,
                projectPaths: fixture.paths
            ).mappingAndRefinementInvocations.map(\.mappingAttemptOrdinal),
            [1]
        )

        let retryRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: false)
        )
        try await makePipeline(fixture: fixture, runner: retryRunner).run(
            resumeFrom: .sfmMatching
        ) { _ in }

        let mapping = try loadGeometry(for: fixture).mapping
        XCTAssertEqual(
            mapping.attemptCount,
            2,
            "The published count must include the preserved failed attempt whose worker evidence allocated ordinal 1."
        )
        XCTAssertEqual(mapping.acceptedMappingAttemptOrdinal, 2)
        XCTAssertEqual(mapping.fallbackReason, "mapping retry after failed run")
        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                from: fixture.paths.workerExecutionURL,
                projectPaths: fixture.paths
            ).mappingAndRefinementInvocations.map(\.mappingAttemptOrdinal),
            [1, 2, 2]
        )
    }

    func testOrderedQualityRejectionRetriesSameGraphWithBalancedCadence() async throws {
        let fixture = try await makeFixture(
            named: "OrderedBalancedCadence",
            imageCount: 8,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let matchingProbe = MappingCadenceProbe()
        let lowCoverageReport = "Registered images: 3 / 8\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n"
        let runner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            emptyVocabularyScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                stdoutLines: Array(
                    repeating: "Retriangulation and Global bundle adjustment",
                    count: 4
                ),
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "4.0")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: arguments), "4.0")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "1")
                    matchingProbe.record(
                        try ColmapDatabaseDigester.digests(
                            at: fixture.paths.colmapDatabaseURL
                        ).matching
                    )
                    try self.writeSparseModel(
                        for: fixture,
                        mapperArguments: arguments,
                        registeredImageCount: 3
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowCoverageReport,
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    matchingProbe.record(
                        try ColmapDatabaseDigester.digests(
                            at: fixture.paths.colmapDatabaseURL
                        ).matching
                    )
                    try self.writeSparseModel(for: fixture, mapperArguments: arguments)
                }
            ),
            analyzerScript(for: fixture),
        ])

        try await makePipeline(fixture: fixture, runner: runner).run { _ in }

        XCTAssertEqual(
            runner.calls.compactMap { $0.1.first },
            [
                "feature_extractor",
                "local_vocab_retriever",
                "matches_importer",
                "mapper",
                "model_analyzer",
                "mapper",
                "model_analyzer",
            ]
        )
        XCTAssertEqual(Set(matchingProbe.digests).count, 1)
        let geometry = try loadGeometry(for: fixture)
        XCTAssertEqual(geometry.mapping.attemptCount, 2)
        XCTAssertEqual(geometry.mapping.acceptedRefinementInvocationCount, 1)
        XCTAssertEqual(geometry.mapping.incrementalCadence, .balancedGlobal)
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "mapping cadence retry after quality rejection"
        )
        XCTAssertEqual(geometry.pairGraph.measurement?.matcherAttempts.count, 1)
    }

    func testUnorderedQualityRejectionRetriesSameGraphWithFrequentCadence() async throws {
        let fixture = try await makeFixture(
            named: "UnorderedFrequentCadence",
            imageCount: 8,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .automatic,
                detailProfile: .fast,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let matchingProbe = MappingCadenceProbe()
        let lowCoverageReport = "Registered images: 3 / 8\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n"
        let runner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments),
                        "1.4"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_points_ratio", in: arguments),
                        "1.4"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_local_max_refinements", in: arguments),
                        "2"
                    )
                    matchingProbe.record(
                        try ColmapDatabaseDigester.digests(
                            at: fixture.paths.colmapDatabaseURL
                        ).matching
                    )
                    try self.writeSparseModel(
                        for: fixture,
                        mapperArguments: arguments,
                        registeredImageCount: 3
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowCoverageReport,
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments),
                        "1.1"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_points_ratio", in: arguments),
                        "1.1"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_local_max_refinements", in: arguments),
                        "2"
                    )
                    matchingProbe.record(
                        try ColmapDatabaseDigester.digests(
                            at: fixture.paths.colmapDatabaseURL
                        ).matching
                    )
                    try self.writeSparseModel(for: fixture, mapperArguments: arguments)
                }
            ),
            analyzerScript(for: fixture),
        ])

        try await makePipeline(fixture: fixture, runner: runner).run { _ in }

        XCTAssertEqual(
            runner.calls.compactMap { $0.1.first },
            [
                "feature_extractor",
                "matches_importer",
                "mapper",
                "model_analyzer",
                "mapper",
                "model_analyzer",
            ]
        )
        XCTAssertEqual(Set(matchingProbe.digests).count, 1)
        let geometry = try loadGeometry(for: fixture)
        XCTAssertEqual(geometry.mapping.attemptCount, 2)
        XCTAssertEqual(geometry.mapping.acceptedMappingAttemptOrdinal, 2)
        XCTAssertEqual(geometry.mapping.plannedIncrementalCadence, .balancedGlobal)
        XCTAssertEqual(geometry.mapping.incrementalCadence, .frequentGlobal)
        XCTAssertEqual(
            geometry.mapping.cadenceFallbackTrigger,
            .lowReconstructionQuality
        )
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "mapping cadence retry after quality rejection"
        )
        XCTAssertEqual(geometry.pairGraph.measurement?.matcherAttempts.count, 1)

        let worker = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            expectedBudget: geometry.workerExecution.resolvedBudget,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(worker.matchingInvocations.count, 1)
        let mapperEvidence = worker.mappingAndRefinementInvocations
            .filter { $0.command == .mapper }
            .compactMap(\.mapperExecution)
        XCTAssertEqual(mapperEvidence.map(\.incrementalCadence), [
            .balancedGlobal,
            .frequentGlobal,
        ])
        XCTAssertEqual(Set(mapperEvidence.map(\.pairGraphAttemptOrdinal)).count, 1)
        XCTAssertEqual(Set(mapperEvidence.map(\.pairListDigest)).count, 1)
        XCTAssertEqual(Set(mapperEvidence.map(\.matchingDatabaseDigest)).count, 1)
    }

    func testSegmentedMixedQualityRejectionRetriesSameGraphWithFrequentCadence() async throws {
        let fixture = try await makeSegmentedMixedFixture(
            named: "SegmentedMixedFrequentCadence"
        )
        let matchingProbe = MappingCadenceProbe()
        let lowCoverageReport = "Registered images: 3 / 8\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n"
        let runner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            emptyVocabularyScript(for: fixture, connectQueries: true),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments),
                        "1.4"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_points_ratio", in: arguments),
                        "1.4"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_local_max_refinements", in: arguments),
                        "2"
                    )
                    matchingProbe.record(
                        try ColmapDatabaseDigester.digests(
                            at: fixture.paths.colmapDatabaseURL
                        ).matching
                    )
                    try self.writeSparseModel(
                        for: fixture,
                        mapperArguments: arguments,
                        registeredImageCount: 3
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowCoverageReport,
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments),
                        "1.1"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_points_ratio", in: arguments),
                        "1.1"
                    )
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_local_max_refinements", in: arguments),
                        "2"
                    )
                    matchingProbe.record(
                        try ColmapDatabaseDigester.digests(
                            at: fixture.paths.colmapDatabaseURL
                        ).matching
                    )
                    try self.writeSparseModel(for: fixture, mapperArguments: arguments)
                }
            ),
            analyzerScript(for: fixture),
        ])

        try await makePipeline(fixture: fixture, runner: runner).run { _ in }

        XCTAssertEqual(
            runner.calls.compactMap { $0.1.first },
            [
                "feature_extractor",
                "local_vocab_retriever",
                "matches_importer",
                "mapper",
                "model_analyzer",
                "mapper",
                "model_analyzer",
            ]
        )
        XCTAssertEqual(Set(matchingProbe.digests).count, 1)
        let metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(metadata.resolvedRunPlan?.pairingPolicy, .segmentedMixed)
        let geometry = try loadGeometry(for: fixture)
        XCTAssertEqual(geometry.mapping.attemptCount, 2)
        XCTAssertEqual(geometry.mapping.acceptedMappingAttemptOrdinal, 2)
        XCTAssertEqual(geometry.mapping.plannedIncrementalCadence, .balancedGlobal)
        XCTAssertEqual(geometry.mapping.incrementalCadence, .frequentGlobal)
        XCTAssertEqual(
            geometry.mapping.cadenceFallbackTrigger,
            .lowReconstructionQuality
        )
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "mapping cadence retry after quality rejection"
        )
        XCTAssertEqual(geometry.pairGraph.measurement?.matcherAttempts.count, 1)

        let worker = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            expectedBudget: geometry.workerExecution.resolvedBudget,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(worker.matchingInvocations.count, 1)
        let mapperEvidence = worker.mappingAndRefinementInvocations
            .filter { $0.command == .mapper }
            .compactMap(\.mapperExecution)
        XCTAssertEqual(mapperEvidence.map(\.incrementalCadence), [
            .balancedGlobal,
            .frequentGlobal,
        ])
        XCTAssertEqual(Set(mapperEvidence.map(\.pairGraphAttemptOrdinal)).count, 1)
        XCTAssertEqual(Set(mapperEvidence.map(\.pairListDigest)).count, 1)
        XCTAssertEqual(Set(mapperEvidence.map(\.descriptorMatcher)).count, 1)
        XCTAssertEqual(Set(mapperEvidence.map(\.matchingDatabaseDigest)).count, 1)
        XCTAssertEqual(
            mapperEvidence.map { $0.evaluation?.fallbackTrigger },
            [.lowReconstructionQuality, nil]
        )
    }

    func testBalancedCadenceSurvivesCancellationWithoutRematching() async throws {
        let fixture = try await makeFixture(
            named: "BalancedCadenceResume",
            imageCount: 8,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .walkthrough,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let lowCoverageReport = "Registered images: 3 / 8\nPoints: 20\nObservations: 60\nMean track length: 3.0\nMean reprojection error: 0.5\n"
        let firstRunner = MockSubprocessRunner(scripts: [
            featureExtractionScript(for: fixture),
            emptyVocabularyScript(for: fixture),
            matchingScript(for: fixture),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    try self.writeSparseModel(
                        for: fixture,
                        mapperArguments: arguments,
                        registeredImageCount: 3
                    )
                }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: SubprocessResult(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowCoverageReport,
                    stderr: ""
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    throw CancellationError()
                }
            ),
        ])

        do {
            try await makePipeline(fixture: fixture, runner: firstRunner).run { _ in }
            XCTFail("Expected conservative mapper cancellation")
        } catch is CancellationError {
            // Active cadence and accepted pair evidence must already be durable.
        }

        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(
            interrupted.geometryRecovery?.plannedIncrementalCadence,
            IncrementalMappingCadenceArtifact(
                localMaxRefinements: 1,
                globalFramesRatio: 4,
                globalPointsRatio: 4,
                globalMaxRefinements: 5
            )
        )
        XCTAssertEqual(
            interrupted.geometryRecovery?.activeIncrementalCadence,
            .balancedGlobal
        )
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 2)
        let matchingDigest = try ColmapDatabaseDigester.digests(
            at: fixture.paths.colmapDatabaseURL
        ).matching
        let pairEvidence = try Data(contentsOf: fixture.paths.pairGraphEvidenceURL)

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: successfulResult,
                stdoutLines: [
                    "Retriangulation and Global bundle adjustment",
                    "Retriangulation and Global bundle adjustment",
                ],
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: arguments), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: arguments), "2")
                    try self.writeSparseModel(for: fixture, mapperArguments: arguments)
                }
            ),
            analyzerScript(for: fixture),
        ])
        try await makePipeline(fixture: fixture, runner: resumeRunner).run(
            resumeFrom: .sfmMatching
        ) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["mapper", "model_analyzer"]
        )
        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(
                at: fixture.paths.colmapDatabaseURL
            ).matching,
            matchingDigest
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.pairGraphEvidenceURL), pairEvidence)
        let mapping = try loadGeometry(for: fixture).mapping
        XCTAssertEqual(mapping.attemptCount, 3)
        XCTAssertEqual(mapping.acceptedRefinementInvocationCount, 2)
        XCTAssertEqual(mapping.incrementalCadence, .balancedGlobal)
        XCTAssertEqual(
            mapping.fallbackReason,
            "mapping cadence retry after quality rejection; interrupted mapping resumed"
        )
    }

    private struct Fixture {
        let root: URL
        let projectURL: URL
        let paths: ProjectPaths
        let toolchain: ToolchainPaths
        let imageCount: Int
    }

    private var successfulResult: SubprocessResult {
        SubprocessResult(
            exitCode: 0,
            terminationReason: .exit,
            stdout: "",
            stderr: ""
        )
    }

    private func makeFixture(
        named name: String,
        imageCount: Int = 3,
        requestedRunOptions: RequestedRunOptions = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos
        )
    ) async throws -> Fixture {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sourcePhotos = root.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: true
        )
        for index in 0..<imageCount {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: sourcePhotos.appendingPathComponent("image_\(index).png"),
                size: 24,
                value: UInt8(64 + (index * 5) % 160),
                utType: .png
            ))
        }

        let requestedInput = InputSpec.photos(folder: sourcePhotos.path)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedRunOptions,
            input: requestedInput,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let prepared = try await PhotoInputPreflight.prepare(
            folder: sourcePhotos,
            stagingParent: root,
            photoSelection: plan.photoSelection,
            inputOrdering: plan.inputOrdering,
            keyframeBudget: plan.keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 64,
                maximumTotalBytes: 128 * 1_024 * 1_024,
                maximumSinglePhotoBytes: 8 * 1_024 * 1_024,
                maximumPixelCount: 4_096 * 4_096,
                maximumDecodedDimension: 256,
                maximumTraversalEntryCount: 128,
                maximumRecursionDepth: 8,
                minimumFreeSpaceReserveBytes: 0
            ),
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        guard prepared.photos.count == imageCount else {
            throw FixtureError.invalidPhotoAdmissionCount(
                expected: imageCount,
                actual: prepared.photos.count
            )
        }

        let projectURL = root.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try adoption.adoptPhotos(prepared, into: paths)
        let photoReceipts = try XCTUnwrap(adoption.photoInputReceipts)
        let photoSelectionReceipt = try XCTUnwrap(adoption.photoSelectionReceipt)
        guard photoReceipts.count == imageCount else {
            throw FixtureError.invalidPhotoAdmissionCount(
                expected: imageCount,
                actual: photoReceipts.count
            )
        }
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: name,
                input: adoption.input,
                photoInputReceipts: photoReceipts,
                photoSelectionReceipt: photoSelectionReceipt,
                requestedRunOptions: requestedRunOptions,
                resolvedRunPlan: plan
            ),
            to: paths.metadataURL
        )
        try PhotoInputReceiptValidator.validateFiles(
            metadata: ProjectMetadataStore.load(from: paths.metadataURL),
            paths: paths
        )

        return Fixture(
            root: root,
            projectURL: projectURL,
            paths: paths,
            toolchain: try makeToolchain(root: root),
            imageCount: imageCount
        )
    }

    private func makeSegmentedMixedFixture(named name: String) async throws -> Fixture {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let firstVideo = root.appendingPathComponent("first.mov")
        let secondVideo = root.appendingPathComponent("second.mov")
        let times = [0.0, 0.2, 0.4, 0.6]
        do {
            try await TestVideoBuilder.writeH264(
                to: firstVideo,
                times: times,
                levels: [20, 60, 100, 140]
            )
            try await TestVideoBuilder.writeH264(
                to: secondVideo,
                times: times,
                levels: [80, 120, 160, 200]
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }

        let projectURL = root.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let requestedInput = InputSpec.video(files: [firstVideo.path, secondVideo.path])
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: requestedInput,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        XCTAssertEqual(plan.pairingPolicy, .segmentedMixed)
        XCTAssertEqual(plan.incrementalMappingCadence, .balancedGlobal)

        let preflight = VideoInputPreflight(limits: .init(
            maximumVideoCount: 64,
            maximumTotalBytes: 1_024 * 1_024 * 1_024,
            minimumFreeSpaceReserveBytes: 0,
            maximumConcurrentDecoders: 2
        ))
        let prepared = try await preflight.prepare(
            videoURLs: [firstVideo, secondVideo],
            stagingParent: root,
            requiredAtomicWorkspaceReserveBytes: 0,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
            pairingPolicy: plan.pairingPolicy,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false
        )
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try adoption.adoptVideos(prepared, into: paths)
        let receipts = try XCTUnwrap(adoption.videoInputReceipts)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: name,
                input: adoption.input,
                videoInputReceipts: receipts,
                requestedRunOptions: requestedOptions
            ),
            to: paths.metadataURL
        )

        return Fixture(
            root: root,
            projectURL: projectURL,
            paths: paths,
            toolchain: try makeToolchain(root: root),
            imageCount: times.count * 2
        )
    }

    private func makePipeline(
        fixture: Fixture,
        runner: MockSubprocessRunner,
        candidateRoute: SfmBackend = .colmap,
        resolvedPlan: ResolvedRunPlan? = nil,
        stopAfterStage: PipelineStage? = nil,
        colmapGPUSupport: Bool? = nil
    ) -> PipelineRunner {
        let gpuSupportDetector: (@Sendable (URL) -> Bool)?
        if let colmapGPUSupport {
            gpuSupportDetector = { _ in colmapGPUSupport }
        } else {
            gpuSupportDetector = nil
        }
        return PipelineRunner(
            projectURL: fixture.projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: fixture.toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: candidateRoute,
                    stopAfterStage: stopAfterStage,
                    skipTraining: true
                ),
                hardwareProfile: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                ),
                resolvedRunPlan: resolvedPlan
            ),
            tooling: .init(
                runner: runner,
                colmapGPUSupport: gpuSupportDetector
            )
        )
    }

    private func da3Plan(for fixture: Fixture) throws -> ResolvedRunPlan {
        let metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let plan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        return plan
    }

    private func successfulGeometryScripts(
        for fixture: Fixture,
        includePreparation: Bool
    ) -> [MockSubprocessRunner.Script] {
        var scripts: [MockSubprocessRunner.Script] = []
        if includePreparation {
            scripts.append(featureExtractionScript(for: fixture))
            scripts.append(matchingScript(for: fixture))
        }
        scripts.append(.init(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["mapper"],
            result: successfulResult,
            stdoutLines: ["Retriangulation and Global bundle adjustment"],
            onRun: { arguments in
                try self.writeSparseModel(for: fixture, mapperArguments: arguments)
            }
        ))
        scripts.append(analyzerScript(for: fixture))
        return scripts
    }

    private func analyzerScript(for fixture: Fixture) -> MockSubprocessRunner.Script {
        .init(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["model_analyzer"],
            result: SubprocessResult(
                exitCode: 0,
                terminationReason: .exit,
                stdout: "Registered images: \(fixture.imageCount) / \(fixture.imageCount)\nPoints: 20\nObservations: \(fixture.imageCount * 20)\nMean track length: \(fixture.imageCount).0\nMean reprojection error: 0.5\n",
                stderr: ""
            )
        )
    }

    private func featureExtractionScript(for fixture: Fixture) -> MockSubprocessRunner.Script {
        .init(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["feature_extractor"],
            result: successfulResult,
            onRun: { arguments in try self.writeFeatureDatabase(for: arguments) }
        )
    }

    private func matchingScript(for fixture: Fixture) -> MockSubprocessRunner.Script {
        .init(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["matches_importer"],
            result: successfulResult,
            onRun: { arguments in try self.writeVerifiedMatches(for: arguments) }
        )
    }

    private func emptyVocabularyScript(
        for fixture: Fixture,
        connectQueries: Bool = false
    ) -> MockSubprocessRunner.Script {
        .init(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["local_vocab_retriever"],
            result: successfulResult,
            onRun: { arguments in
                guard let outputPath = self.value(for: "--output_pair_list_path", in: arguments),
                      let queryPath = self.value(for: "--query_image_list_path", in: arguments),
                      let exclusionsPath = self.value(
                        for: "--excluded_pair_list_path",
                        in: arguments
                      ),
                      let candidateCount = self.value(for: "--num_images", in: arguments)
                        .flatMap(Int.init),
                      let returnedNeighborCount = self.value(
                        for: "--returned_neighbor_count",
                        in: arguments
                      ).flatMap(Int.init),
                      let minimumFrameSeparation = self.value(
                        for: "--minimum_frame_separation",
                        in: arguments
                      ).flatMap(Int.init),
                      let queryStride = self.value(for: "--query_stride", in: arguments)
                        .flatMap(Int.init),
                      let requestDigest = self.value(for: "--request_digest", in: arguments) else {
                    throw FixtureError.missingArgument
                }
                let imageGroupListPath = self.value(
                    for: "--image_group_list_path",
                    in: arguments
                )
                let imageGroupListDigest = self.value(
                    for: "--image_group_list_digest",
                    in: arguments
                )
                guard (imageGroupListPath == nil) == (imageGroupListDigest == nil) else {
                    throw FixtureError.missingArgument
                }
                let queryImageNames = try String(
                    contentsOf: URL(fileURLWithPath: queryPath),
                    encoding: .utf8
                ).split(whereSeparator: \.isNewline).map(String.init)
                let excludedPairs = try String(
                    contentsOf: URL(fileURLWithPath: exclusionsPath),
                    encoding: .utf8
                ).split(whereSeparator: \.isNewline).map { line -> (String, String) in
                    let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard fields.count == 2 else { throw FixtureError.invalidPairList }
                    return (fields[0], fields[1])
                }
                func edgeKey(_ first: String, _ second: String) -> String {
                    [first, second]
                        .sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
                        .joined(separator: "\u{0}")
                }
                let excludedEdges = Set(excludedPairs.map(edgeKey))
                var candidatePolicy: PairGraphRetrievalCandidatePolicy?
                var imageGroupLines: [String]?
                var imageGroupIndexByName: [String: Int] = [:]
                if let imageGroupListPath, let imageGroupListDigest {
                    let lines = try String(
                        contentsOf: URL(fileURLWithPath: imageGroupListPath),
                        encoding: .utf8
                    ).split(whereSeparator: \.isNewline).map(String.init)
                    for line in lines {
                        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                        guard fields.count == 2,
                              let groupIndex = Int(fields[1]),
                              groupIndex >= 0,
                              imageGroupIndexByName.updateValue(
                                  groupIndex,
                                  forKey: String(fields[0])
                              ) == nil else {
                            throw FixtureError.invalidPairList
                        }
                    }
                    let policy = PairGraphRetrievalCandidatePolicy.crossGroupV1
                    guard imageGroupListDigest == PairGraphEvidenceStore.imageGroupListDigest(
                        policy: policy,
                        canonicalLines: lines
                    ) else {
                        throw FixtureError.invalidPairList
                    }
                    candidatePolicy = policy
                    imageGroupLines = lines
                }
                var requestedPairs: [(String, String)] = []
                if connectQueries {
                    let allImageNames = Set(
                        queryImageNames + excludedPairs.flatMap { [$0.0, $0.1] }
                    ).sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
                    for query in queryImageNames {
                        if let neighbor = allImageNames.first(where: { candidate in
                            guard candidate != query,
                                  !excludedEdges.contains(edgeKey(query, candidate)) else {
                                return false
                            }
                            guard !imageGroupIndexByName.isEmpty else { return true }
                            return imageGroupIndexByName[query]
                                != imageGroupIndexByName[candidate]
                        }) {
                            requestedPairs.append((query, neighbor))
                        }
                    }
                }
                let outcomes = queryImageNames.map { query -> PairGraphRetrievalQueryOutcome in
                    let neighbors = requestedPairs.compactMap { first, second -> String? in
                        if first == query { return second }
                        return nil
                    }.sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
                    return PairGraphRetrievalQueryOutcome(
                        queryImageName: query,
                        status: neighbors.isEmpty ? .noRankedNeighbors : .ranked,
                        rankedNeighborImageNames: neighbors
                    )
                }
                var emittedEdges: Set<String> = []
                var directedPairLines: [String] = []
                for outcome in outcomes {
                    for neighbor in outcome.rankedNeighborImageNames {
                        let key = edgeKey(outcome.queryImageName, neighbor)
                        guard !excludedEdges.contains(key),
                              emittedEdges.insert(key).inserted else {
                            continue
                        }
                        directedPairLines.append("\(outcome.queryImageName) \(neighbor)")
                    }
                }
                directedPairLines.sort(by: PairGraphEvidenceStore.canonicalUTF8Less)
                let evidence = PairGraphRetrievalAttemptEvidence(
                    engine: .localSiftVocabularyV2,
                    queryImageNames: queryImageNames,
                    queryStride: queryStride,
                    candidateCount: candidateCount,
                    returnedNeighborCount: returnedNeighborCount,
                    minimumFrameSeparation: minimumFrameSeparation,
                    candidatePolicy: candidatePolicy,
                    imageGroupListDigest: imageGroupListDigest,
                    imageGroupLines: imageGroupLines,
                    queryOutcomes: outcomes,
                    directedPairLines: directedPairLines
                )
                guard PairGraphEvidenceStore.retrievalRequestDigest(evidence) == requestDigest else {
                    throw FixtureError.invalidPairList
                }
                try (PairGraphEvidenceStore.retrievalContractLines(evidence)
                    .joined(separator: "\n") + "\n").write(
                    to: URL(fileURLWithPath: outputPath),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
    }

    private func makeToolchain(root: URL) throws -> ToolchainPaths {
        let toolchainRoot = root.appendingPathComponent("Toolchain", isDirectory: true)
        let colmap = toolchainRoot.appendingPathComponent("bin/colmap")
        try TestFileBuilder.createExecutable(at: colmap)
        let openMPRuntime = toolchainRoot.appendingPathComponent("lib/libomp.dylib")
        try FileManager.default.createDirectory(
            at: openMPRuntime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture OpenMP runtime".utf8).write(to: openMPRuntime)
        let da3 = try TestToolchains.da3Toolchain(
            root: toolchainRoot,
            createFiles: true
        )
        let provenance = toolchainRoot.appendingPathComponent("provenance/colmap.json")
        try FileManager.default.createDirectory(
            at: provenance.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let executableDigest = try GeometryArtifactStore.sha256(of: colmap)
        try """
        {
          "toolchain_name": "colmap",
          "source_version": "4.1.1",
          "source_commit": "a0d785fba74b2664f31edc4a29026a8b27c00f67",
          "executable_sha256": "\(executableDigest)"
        }
        """.write(to: provenance, atomically: true, encoding: .utf8)
        return ToolchainPaths(
            root: toolchainRoot,
            colmap: colmap,
            msplat: toolchainRoot.appendingPathComponent("bin/easysplat-train"),
            da3: da3
        )
    }

    private func writeDa3SeedArtifacts(for arguments: [String]) throws {
        guard let manifestPath = value(for: "--manifest-out", in: arguments),
              let imagesPath = value(for: "--images", in: arguments),
              let sparsePath = value(for: "--out-sparse", in: arguments) else {
            throw FixtureError.missingArgument
        }
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: imagesPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        .map(\.lastPathComponent)
        .sorted()
        guard imageNames.count >= 3 else {
            throw FixtureError.invalidDa3ImageCount(imageNames.count)
        }

        let requestedWindowSize = Int(value(for: "--window-size", in: arguments) ?? "")
            ?? imageNames.count
        let requestedWindowOverlap = Int(value(for: "--window-overlap", in: arguments) ?? "")
            ?? 0
        let windowSize = max(2, min(imageNames.count, requestedWindowSize))
        let windowOverlap = max(0, min(requestedWindowOverlap, windowSize - 1))
        let indices = Array(0..<imageNames.count)
        let modelURL = URL(fileURLWithPath: sparsePath, isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        let sharedCamera = arguments.contains("--shared-camera")
        guard let cameraType = value(for: "--camera-type", in: arguments),
              let cameraParameters = cameraParameters(for: cameraType) else {
            throw FixtureError.missingArgument
        }
        let camerasText = sharedCamera
            ? "1 \(cameraType) 24 24 \(cameraParameters)\n"
            : imageNames.indices.map {
                "\($0 + 1) \(cameraType) 24 24 \(cameraParameters)"
            }.joined(separator: "\n") + "\n"
        try camerasText.write(
            to: modelURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let imagesText = imageNames.enumerated()
            .map { offset, name in
                let cameraID = sharedCamera ? 1 : offset + 1
                return "\(offset + 1) 1 0 0 0 0 0 0 \(cameraID) \(name)\n"
            }
            .joined(separator: "\n")
        try (imagesText + "\n").write(
            to: modelURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "# Number of points: 0\n".write(
            to: modelURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # learned points
        1 0 0 1 255 0 0 -1.0
        2 1 0 1 0 255 0 -1.0
        3 0 1 1 0 0 255 -1.0
        4 1 1 1 255 255 255 -1.0

        """.write(
            to: modelURL.appendingPathComponent("learned_points3D.txt"),
            atomically: true,
            encoding: .utf8
        )

        let inputOrdering = value(for: "--input-ordering", in: arguments) ?? "automatic"
        let manifest = Da3CoverageManifest(
            mode: "seed_refine",
            requestedDevice: value(for: "--device", in: arguments) ?? "mps",
            selectedDevice: "mps",
            modelSubdirectory: value(for: "--model-subdir", in: arguments) ?? "DA3-BASE",
            processResolution: Int(value(for: "--process-res", in: arguments) ?? "") ?? 504,
            cameraType: value(for: "--camera-type", in: arguments) ?? "PINHOLE",
            sharedCamera: sharedCamera,
            maxPoints: Int(value(for: "--max-points", in: arguments) ?? "") ?? 120_000,
            totalImages: imageNames.count,
            windowSize: windowSize,
            windowOverlap: windowOverlap,
            windows: [Da3CoverageManifest.Window(
                start: 0,
                end: imageNames.count,
                images: imageNames,
                indices: indices
            )],
            rawPointSampleCount: 8,
            fusedSparsePointCount: 4,
            finalObservationCount: nil,
            meanTrackLength: nil,
            registeredImageCount: imageNames.count,
            nativeColmapExport: false,
            exportStrategy: "aligned_pose_depth_seed",
            inputOrdering: inputOrdering == "automatic" ? "unordered" : inputOrdering,
            anchorImageNames: Array(imageNames.prefix(3)),
            alignmentEdgeCount: 0,
            maxAlignmentRMSE: 0.01,
            alignmentComplete: true
        )
        try JSONEncoder().encode(manifest).write(
            to: URL(fileURLWithPath: manifestPath),
            options: [.atomic]
        )
    }

    private func writeFeatureDatabase(for arguments: [String]) throws {
        guard let databasePath = value(for: "--database_path", in: arguments),
              let imagePath = value(for: "--image_path", in: arguments) else {
            throw FixtureError.missingArgument
        }
        let databaseURL = URL(fileURLWithPath: databasePath)
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: imagePath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .map(\.lastPathComponent)
        .sorted()
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: databaseURL)

        try withDatabase(at: databaseURL) { database in
            var cameraParameters = Data()
            for value in [16.0, 16.0, 8.0, 8.0] {
                var littleEndian = value.bitPattern.littleEndian
                withUnsafeBytes(of: &littleEndian) {
                    cameraParameters.append(contentsOf: $0)
                }
            }
            let cameraParameterHex = cameraParameters.map {
                String(format: "%02x", $0)
            }.joined()
            try executeSQL(
                "BEGIN IMMEDIATE TRANSACTION;",
                operation: "begin feature fixture transaction",
                databaseURL: databaseURL,
                in: database
            )
            do {
                try executeSQL(
                    """
                    CREATE TABLE cameras(
                        camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        model INTEGER NOT NULL,
                        width INTEGER NOT NULL,
                        height INTEGER NOT NULL,
                        params BLOB,
                        prior_focal_length INTEGER NOT NULL
                    );
                    CREATE TABLE rigs(
                        rig_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        ref_sensor_id INTEGER NOT NULL,
                        ref_sensor_type INTEGER NOT NULL
                    );
                    CREATE UNIQUE INDEX rig_ref_sensor_assignment
                        ON rigs(ref_sensor_id, ref_sensor_type);
                    CREATE TABLE rig_sensors(
                        rig_id INTEGER NOT NULL,
                        sensor_id INTEGER NOT NULL,
                        sensor_type INTEGER NOT NULL,
                        sensor_from_rig BLOB,
                        FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
                    );
                    CREATE UNIQUE INDEX rig_sensor_assignment
                        ON rig_sensors(sensor_id, sensor_type);
                    CREATE TABLE frames(
                        frame_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        rig_id INTEGER NOT NULL,
                        FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
                    );
                    CREATE TABLE frame_data(
                        frame_id INTEGER NOT NULL,
                        data_id INTEGER NOT NULL,
                        sensor_id INTEGER NOT NULL,
                        sensor_type INTEGER NOT NULL,
                        FOREIGN KEY(frame_id) REFERENCES frames(frame_id) ON DELETE CASCADE
                    );
                    CREATE UNIQUE INDEX frame_sensor_assignment
                        ON frame_data(data_id, sensor_type);
                    CREATE TABLE images(
                        image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        name TEXT NOT NULL UNIQUE,
                        camera_id INTEGER NOT NULL,
                        FOREIGN KEY(camera_id) REFERENCES cameras(camera_id)
                    );
                    CREATE UNIQUE INDEX index_name ON images(name);
                    CREATE TABLE pose_priors(
                        pose_prior_id INTEGER PRIMARY KEY NOT NULL,
                        corr_data_id INTEGER NOT NULL,
                        corr_sensor_id INTEGER NOT NULL,
                        corr_sensor_type INTEGER NOT NULL,
                        position BLOB,
                        position_covariance BLOB,
                        gravity BLOB,
                        coordinate_system INTEGER NOT NULL
                    );
                    CREATE UNIQUE INDEX pose_prior_data_assignment
                        ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
                    CREATE TABLE keypoints(
                        image_id INTEGER PRIMARY KEY NOT NULL,
                        rows INTEGER NOT NULL,
                        cols INTEGER NOT NULL,
                        data BLOB,
                        FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
                    );
                    CREATE TABLE descriptors(
                        image_id INTEGER PRIMARY KEY NOT NULL,
                        type INTEGER NOT NULL,
                        rows INTEGER NOT NULL,
                        cols INTEGER NOT NULL,
                        data BLOB,
                        FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
                    );
                    CREATE TABLE matches(
                        pair_id INTEGER PRIMARY KEY NOT NULL,
                        rows INTEGER NOT NULL,
                        cols INTEGER NOT NULL,
                        data BLOB
                    );
                    CREATE TABLE two_view_geometries(
                        pair_id INTEGER PRIMARY KEY NOT NULL,
                        rows INTEGER NOT NULL,
                        cols INTEGER NOT NULL,
                        data BLOB,
                        config INTEGER NOT NULL DEFAULT 0,
                        F BLOB,
                        E BLOB,
                        H BLOB,
                        qvec BLOB,
                        tvec BLOB
                    );
                    """,
                    operation: "create feature fixture schema",
                    databaseURL: databaseURL,
                    in: database
                )
                for (offset, imageName) in imageNames.enumerated() {
                    let imageID = offset + 1
                    try executeSQL(
                        "INSERT INTO cameras(camera_id, model, width, height, params, prior_focal_length) VALUES (\(imageID), 1, 16, 16, X'\(cameraParameterHex)', 0);" +
                        "INSERT INTO rigs(rig_id, ref_sensor_id, ref_sensor_type) VALUES (\(imageID), \(imageID), 0);" +
                        "INSERT INTO frames(frame_id, rig_id) VALUES (\(imageID), \(imageID));" +
                        "INSERT INTO frame_data(frame_id, data_id, sensor_id, sensor_type) VALUES (\(imageID), \(imageID), \(imageID), 0);" +
                        "INSERT INTO images(image_id, name, camera_id) VALUES (\(imageID), '\(sqlQuoted(imageName))', \(imageID));" +
                        "INSERT INTO pose_priors(pose_prior_id, corr_data_id, corr_sensor_id, corr_sensor_type, coordinate_system) VALUES (\(imageID), \(imageID), \(imageID), 0, 1);" +
                        "INSERT INTO keypoints(image_id, rows, cols) VALUES (\(imageID), 64, 4);" +
                        "INSERT INTO descriptors(image_id, rows, cols, type) VALUES (\(imageID), 64, 128, 0);",
                        operation: "insert feature fixture image \(imageID)",
                        databaseURL: databaseURL,
                        in: database
                    )
                }
                try executeSQL(
                    "COMMIT;",
                    operation: "commit feature fixture transaction",
                    databaseURL: databaseURL,
                    in: database
                )
            } catch {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    private func writeVerifiedMatches(for arguments: [String]) throws {
        guard let databasePath = value(for: "--database_path", in: arguments),
              let pairListPath = value(for: "--match_list_path", in: arguments) else {
            throw FixtureError.missingArgument
        }
        let pairs = try String(contentsOfFile: pairListPath, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let databaseURL = URL(fileURLWithPath: databasePath)
        try withDatabase(at: databaseURL) { database in
            let imageIDs = try imageIdentifiers(in: database, databaseURL: databaseURL)
            try executeSQL(
                "BEGIN IMMEDIATE TRANSACTION;",
                operation: "begin verified-match transaction",
                databaseURL: databaseURL,
                in: database
            )
            do {
                for (pairOffset, pair) in pairs.enumerated() {
                    guard pair.count == 2,
                          let firstID = imageIDs[pair[0]],
                          let secondID = imageIDs[pair[1]] else {
                        throw FixtureError.invalidPairList
                    }
                    let low = min(firstID, secondID)
                    let high = max(firstID, secondID)
                    let pairID = low * ColmapPairGraphInspector.pairIDDivisor + high
                    let rows = ColmapMappingPolicy.minimumPairInlierCount
                    try executeSQL(
                        "INSERT INTO matches(pair_id, rows, cols) VALUES (\(pairID), \(rows), 2);" +
                        "INSERT INTO two_view_geometries(pair_id, rows, cols) VALUES (\(pairID), \(rows), 2);",
                        operation: "insert verified pair \(pairOffset + 1)",
                        databaseURL: databaseURL,
                        in: database
                    )
                }
                try executeSQL(
                    "COMMIT;",
                    operation: "commit verified-match transaction",
                    databaseURL: databaseURL,
                    in: database
                )
            } catch {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    private func pairListLines(for arguments: [String]) throws -> [String] {
        guard let pairListPath = value(for: "--match_list_path", in: arguments) else {
            throw FixtureError.missingArgument
        }
        return try String(contentsOfFile: pairListPath, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
    }

    private func writeSparseModel(
        for fixture: Fixture,
        mapperArguments: [String],
        registeredImageCount: Int? = nil
    ) throws {
        guard let outputPath = value(for: "--output_path", in: mapperArguments) else {
            throw FixtureError.missingArgument
        }
        let modelURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            .appendingPathComponent("0", isDirectory: true)
        try writeSparseModel(
            at: modelURL,
            for: fixture,
            registeredImageCount: registeredImageCount
        )
    }

    private func writeSparseModel(
        at modelURL: URL,
        for fixture: Fixture,
        registeredImageCount: Int? = nil,
        cameraCenterStep: Double = 0.25
    ) throws {
        let allImageNames = try selectedImageNames(for: fixture)
        let imageNames = Array(allImageNames.prefix(registeredImageCount ?? allImageNames.count))

        try writeSparseModel(
            at: modelURL,
            for: fixture,
            imageNames: imageNames,
            cameraCenterStep: cameraCenterStep
        )
    }

    private func selectedImageNames(for fixture: Fixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: fixture.paths.framesSelectedURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .map(\.lastPathComponent)
        .sorted()
    }

    private func writeSparseModel(
        at modelURL: URL,
        for fixture: Fixture,
        imageNames: [String],
        cameraCenterStep: Double = 0.25
    ) throws {
        let allImageNames = try selectedImageNames(for: fixture)
        let imageIDByName = Dictionary(
            uniqueKeysWithValues: allImageNames.enumerated().map { ($0.element, $0.offset + 1) }
        )
        guard !imageNames.isEmpty,
              Set(imageNames).count == imageNames.count,
              imageNames.allSatisfy({ imageIDByName[$0] != nil }) else {
            throw FixtureError.invalidSparseModelImageNames
        }
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)

        try "1 SIMPLE_RADIAL 24 24 20 12 12 0\n".write(
            to: modelURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let points = (0..<20).map { pointIndex in
            (
                x: Double(pointIndex % 5) - 2,
                y: Double(pointIndex / 5) - 1.5,
                z: 12.0
            )
        }
        var tracks = Array(repeating: [String](), count: points.count)
        var images = "# Image list\n"
        for imageName in imageNames {
            let imageID = imageIDByName[imageName]!
            let centerX = (Double(imageID) - 1) * cameraCenterStep
            images += "\(imageID) 1 0 0 0 \(-centerX) 0 0 1 \(imageName)\n"
            images += points.enumerated().map { pointOffset, point in
                tracks[pointOffset].append("\(imageID) \(pointOffset)")
                let x = 20 * (point.x - centerX) / point.z + 12
                let y = 20 * point.y / point.z + 12
                return "\(x) \(y) \(pointOffset + 1)"
            }.joined(separator: " ") + "\n"
        }
        try images.write(
            to: modelURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let pointLines = points.enumerated().map { pointOffset, point -> String in
            "\(pointOffset + 1) \(point.x) \(point.y) \(point.z) 128 128 128 0 "
                + tracks[pointOffset].joined(separator: " ")
        }
        try (pointLines.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func cameraParameters(for cameraType: String) -> String? {
        switch cameraType {
        case "SIMPLE_PINHOLE":
            return "20 12 12"
        case "PINHOLE":
            return "20 20 12 12"
        case "SIMPLE_RADIAL":
            return "20 12 12 0"
        case "RADIAL":
            return "20 12 12 0 0"
        case "OPENCV", "OPENCV_FISHEYE":
            return "20 20 12 12 0 0 0 0"
        default:
            return nil
        }
    }

    private func withDatabase(
        at url: URL,
        operation: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open(url.path, &database)
        guard openResult == SQLITE_OK, let database else {
            let failure = sqliteFailure(
                operation: "open database",
                resultCode: openResult,
                database: database,
                databaseURL: url,
                context: "sqlite3_open"
            )
            if let database {
                sqlite3_close(database)
            }
            throw failure
        }

        let operationResult = Result<Void, Error> {
            let extendedResult = sqlite3_extended_result_codes(database, 1)
            guard extendedResult == SQLITE_OK else {
                throw sqliteFailure(
                    operation: "enable extended result codes",
                    resultCode: extendedResult,
                    database: database,
                    databaseURL: url,
                    context: "sqlite3_extended_result_codes"
                )
            }
            let timeoutResult = sqlite3_busy_timeout(database, 5_000)
            guard timeoutResult == SQLITE_OK else {
                throw sqliteFailure(
                    operation: "set busy timeout",
                    resultCode: timeoutResult,
                    database: database,
                    databaseURL: url,
                    context: "sqlite3_busy_timeout(5000)"
                )
            }
            try operation(database)
        }

        let closeResult = sqlite3_close(database)
        if closeResult != SQLITE_OK {
            let priorContext: String
            switch operationResult {
            case .success:
                priorContext = "no prior operation error"
            case .failure(let error):
                priorContext = "prior error: \(boundedSQLiteContext(String(describing: error)))"
            }
            throw sqliteFailure(
                operation: "close database",
                resultCode: closeResult,
                database: database,
                databaseURL: url,
                context: priorContext
            )
        }
        try operationResult.get()
    }

    private func imageIdentifiers(
        in database: OpaquePointer,
        databaseURL: URL
    ) throws -> [String: Int64] {
        let sql = "SELECT image_id, name FROM images;"
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw sqliteFailure(
                operation: "prepare image identifier query",
                resultCode: prepareResult,
                database: database,
                databaseURL: databaseURL,
                context: sql
            )
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: Int64] = [:]
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw sqliteFailure(
                    operation: "read image identifier row",
                    resultCode: stepResult,
                    database: database,
                    databaseURL: databaseURL,
                    context: sql
                )
            }
            guard let name = sqlite3_column_text(statement, 1) else {
                throw FixtureError.sqliteFailure(
                    operation: "decode image identifier row",
                    primaryCode: SQLITE_MISMATCH,
                    extendedCode: SQLITE_MISMATCH,
                    databasePath: urlPathForError(databaseURL),
                    context: boundedSQLiteContext(sql),
                    message: "Image name was not SQLite text."
                )
            }
            result[String(cString: name)] = sqlite3_column_int64(statement, 0)
        }
        return result
    }

    private func executeSQL(
        _ sql: String,
        operation: String,
        databaseURL: URL,
        in database: OpaquePointer
    ) throws {
        var message: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw sqliteFailure(
                operation: operation,
                resultCode: result,
                database: database,
                databaseURL: databaseURL,
                context: sql,
                message: message.map { String(cString: $0) }
            )
        }
    }

    private func sqliteFailure(
        operation: String,
        resultCode: Int32,
        database: OpaquePointer?,
        databaseURL: URL,
        context: String,
        message: String? = nil
    ) -> FixtureError {
        let extendedCode: Int32
        if let database {
            let reportedCode = sqlite3_extended_errcode(database)
            extendedCode = reportedCode == SQLITE_OK ? resultCode : reportedCode
        } else {
            extendedCode = resultCode
        }
        return .sqliteFailure(
            operation: boundedSQLiteContext(operation, limit: 80),
            primaryCode: extendedCode & 0xFF,
            extendedCode: extendedCode,
            databasePath: urlPathForError(databaseURL),
            context: boundedSQLiteContext(context),
            message: boundedSQLiteContext(
                message
                    ?? database.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "SQLite operation failed.",
                limit: 240
            )
        )
    }

    private func boundedSQLiteContext(_ value: String, limit: Int = 160) -> String {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(normalized.prefix(limit))
    }

    private func urlPathForError(_ url: URL) -> String {
        boundedSQLiteContext(url.path, limit: 512)
    }

    private func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func sqlQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func loadGeometry(for fixture: Fixture) throws -> GeometryArtifact {
        let metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        return try GeometryArtifactStore.load(
            from: fixture.paths.geometryManifestURL,
            projectPaths: fixture.paths,
            expectedInput: metadata.input
        )
    }

    private enum FixtureError: Error {
        case missingArgument
        case invalidPairList
        case invalidDa3ImageCount(Int)
        case invalidPhotoAdmissionCount(expected: Int, actual: Int)
        case invalidSparseModelImageNames
        case sqliteFailure(
            operation: String,
            primaryCode: Int32,
            extendedCode: Int32,
            databasePath: String,
            context: String,
            message: String
        )
    }
}

private final class PairScheduleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var normalStorage: [String] = []
    private var expandedStorage: [String] = []

    var normal: [String] {
        lock.withLock { normalStorage }
    }

    var expanded: [String] {
        lock.withLock { expandedStorage }
    }

    func recordNormal(_ pairs: [String]) {
        lock.withLock { normalStorage = pairs }
    }

    func recordExpanded(_ pairs: [String]) {
        lock.withLock { expandedStorage = pairs }
    }
}

private final class MappingCadenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var digests: [String] {
        lock.withLock { storage }
    }

    func record(_ digest: String) {
        lock.withLock { storage.append(digest) }
    }
}

private final class GeometryRecoveryEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []

    func append(_ event: PipelineEvent) {
        lock.withLock { events.append(event) }
    }

    func stageLog(containing text: String) -> PipelineEvent? {
        lock.withLock {
            events.first { event in
                guard case .stageLog(_, let line, _) = event else { return false }
                return line.contains(text)
            }
        }
    }

    func progressFractions(for stage: PipelineStage) -> [Double] {
        lock.withLock {
            events.compactMap { event in
                guard case .stageProgress(let eventStage, let fraction, _) = event,
                      eventStage == stage else {
                    return nil
                }
                return fraction
            }
        }
    }

    func didFinish(_ stage: PipelineStage) -> Bool {
        lock.withLock {
            events.contains { event in
                guard case .stageFinished(let eventStage) = event else { return false }
                return eventStage == stage
            }
        }
    }
}
