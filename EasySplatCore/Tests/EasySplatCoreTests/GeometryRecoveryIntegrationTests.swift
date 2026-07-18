import Foundation
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class GeometryRecoveryIntegrationTests: XCTestCase {
    func testCancelledDa3MappingResumesSeededRefinementWithoutRepeatingPreparation() async throws {
        let fixture = try makeFixture(named: "Da3MappingResume")
        let plan = try da3FallbackPlan(for: fixture)
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
        XCTAssertEqual(interrupted.geometryRecovery?.activeBackend, .da3)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 1)
        XCTAssertNil(interrupted.geometryRecovery?.colmapComputeMode)

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
        XCTAssertEqual(finished.geometryArtifact?.mapping.attemptCount, 2)
        XCTAssertEqual(
            finished.geometryArtifact?.mapping.fallbackReason,
            "interrupted mapping resumed"
        )
        XCTAssertNil(finished.geometryRecovery)
    }

    func testCpuFallbackRemainsCpuAfterCancellationAndRelaunch() async throws {
        let fixture = try makeFixture(named: "CpuFallbackResume")
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
        let fixture = try makeFixture(named: "NormalCpuResume")
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

    func testTornDa3ToColmapTransitionRestartsFromCleanClassicalFeatures() async throws {
        let fixture = try makeFixture(named: "TornBackendTransition")
        let plan = try da3FallbackPlan(for: fixture)
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

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: successfulResult,
                onRun: { arguments in
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: fixture.paths.colmapSeedModelURL.path),
                        "A committed classical transition must not reuse a learned seed database."
                    )
                    try self.writeFeatureDatabase(for: arguments)
                }
            ),
            matchingScript(for: fixture),
        ] + successfulGeometryScripts(for: fixture, includePreparation: false))
        try await makePipeline(
            fixture: fixture,
            runner: resumeRunner,
            candidateRoute: .da3,
            resolvedPlan: plan
        ).run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["feature_extractor", "matches_importer", "mapper", "model_analyzer"]
        )
        XCTAssertFalse(resumeRunner.calls.contains { $0.0 == fixture.toolchain.da3.sfmTool.path })
    }

    func testDa3FallbackCancelledInClassicalMappingResumesClassicalRoute() async throws {
        let fixture = try makeFixture(named: "Da3FallbackMappingResume")
        let fallbackPlan = try da3FallbackPlan(for: fixture)
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
                result: SubprocessResult(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "seeded triangulation failed"
                )
            ),
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
            try await makePipeline(
                fixture: fixture,
                runner: firstRunner,
                candidateRoute: .da3,
                resolvedPlan: fallbackPlan
            ).run { _ in }
            XCTFail("Expected classical mapper cancellation")
        } catch is CancellationError {
            // The selected fallback route and both launched mapping attempts must survive.
        }

        let interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(interrupted.checkpoint?.stage, .sfmMapping)
        XCTAssertEqual(interrupted.geometryRecovery?.activeBackend, .colmap)
        XCTAssertEqual(interrupted.geometryRecovery?.mappingAttemptCount, 2)
        XCTAssertEqual(
            interrupted.geometryRecovery?.mappingFallbackReasons,
            ["da3 fallback to colmap"]
        )

        let resumeRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: false)
        )
        try await makePipeline(
            fixture: fixture,
            runner: resumeRunner,
            candidateRoute: .da3,
            resolvedPlan: fallbackPlan
        ).run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["mapper", "model_analyzer"],
            "Resume must skip DA3 and reuse the accepted classical features and matches."
        )
        XCTAssertFalse(resumeRunner.calls.contains { $0.0 == fixture.toolchain.da3.sfmTool.path })
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let mapping = try XCTUnwrap(finished.geometryArtifact?.mapping)
        XCTAssertEqual(mapping.attemptCount, 3)
        XCTAssertEqual(
            mapping.fallbackReason,
            "da3 fallback to colmap; interrupted mapping resumed"
        )
        let workerExecution = try XCTUnwrap(finished.geometryArtifact?.workerExecution)
        XCTAssertEqual(
            workerExecution.mappingAndRefinementInvocations.map(\.command),
            [.pointTriangulator, .mapper, .modelAnalyzer]
        )
        XCTAssertEqual(
            workerExecution.mappingAndRefinementInvocations.map(\.succeeded),
            [false, true, true],
            "Resume must append to the failed mapping attempt instead of erasing it."
        )
        XCTAssertNil(finished.geometryRecovery)
    }

    func testExpandedPairRecoveryResumesExpandedScheduleWithPriorHistory() async throws {
        let fixture = try makeFixture(
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
        let lowCoverageReport = "Registered images: 2 / 8\nPoints: 20\nObservations: 40\nMean track length: 2.0\nMean reprojection error: 0.5\n"
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
                        registeredImageCount: 2
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
                        registeredImageCount: 2
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
                "conservative mapping cadence after quality rejection",
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
        let geometry = try XCTUnwrap(finished.geometryArtifact)
        let matcherAttempts = try XCTUnwrap(geometry.pairGraph.measurement?.matcherAttempts)
        XCTAssertEqual(matcherAttempts.map(\.attemptNumber), [1, 2])
        XCTAssertEqual(matcherAttempts.map(\.recoveryLevel), [.normal, .expanded])
        XCTAssertEqual(matcherAttempts.map(\.outcome), [.completed, .completed])
        XCTAssertEqual(matcherAttempts.map(\.scheduledPairCount), [17, 28])
        XCTAssertEqual(geometry.mapping.attemptCount, 3)
        XCTAssertEqual(geometry.mapping.incrementalCadence, .conservative)
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "conservative mapping cadence after quality rejection; Reconstruction coverage was below the acceptance gate"
        )
        XCTAssertNil(finished.geometryRecovery)
    }

    func testAnalyzerOnlyFragmentDoesNotRejectAnOtherwiseAcceptableModel() async throws {
        let fixture = try makeFixture(
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
            ["feature_extractor", "matches_importer", "mapper", "model_analyzer", "model_analyzer"]
        )
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(finished.geometryArtifact?.mapping.attemptCount, 1)
        XCTAssertNil(finished.geometryArtifact?.mapping.fallbackReason)
        XCTAssertNil(finished.geometryRecovery)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.paths.colmapSparseURL.path),
            ["0"]
        )
    }

    func testFragmentedMappingRecoveryResumesExpandedScheduleWithoutPublishingTheSplit() async throws {
        let fixture = try makeFixture(
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
                "conservative mapping cadence after fragmented solve",
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
        let mapping = try XCTUnwrap(finished.geometryArtifact?.mapping)
        XCTAssertEqual(mapping.attemptCount, 3)
        XCTAssertEqual(mapping.incrementalCadence, .conservative)
        XCTAssertEqual(
            mapping.fallbackReason,
            "conservative mapping cadence after fragmented solve; Camera mapping split recoverable views across separate models"
        )
        XCTAssertNil(finished.geometryRecovery)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.paths.colmapSparseURL.path),
            ["0"]
        )
    }

    func testPersistedGeometrySurvivesResumeBeforeMappingStageCommit() async throws {
        let fixture = try makeFixture(named: "PersistedGeometryResume")
        let initialRunner = MockSubprocessRunner(
            scripts: successfulGeometryScripts(for: fixture, includePreparation: true)
        )
        try await makePipeline(fixture: fixture, runner: initialRunner).run { _ in }

        var interrupted = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let acceptedArtifact = try XCTUnwrap(interrupted.geometryArtifact)
        let manifestBeforeResume = try Data(contentsOf: fixture.paths.geometryManifestURL)
        interrupted.state = PipelineState(stage: .sfmMatching, lastError: nil)
        interrupted.checkpoint = PipelineCheckpoint(
            stage: .sfmMapping,
            updatedAt: Date(timeIntervalSince1970: 2),
            progressFraction: 1,
            message: "Geometry persisted before stage completion",
            details: .sfmMapping(SfmMappingCheckpoint(
                mapper: "colmap",
                sparsePath: "SfM/colmap/sparse",
                registeredImages: fixture.imageCount
            ))
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
        XCTAssertEqual(resumed.geometryArtifact, acceptedArtifact)
        XCTAssertEqual(resumed.state.stage, .sfmMapping)
        XCTAssertNil(resumed.checkpoint)
        XCTAssertNil(resumed.lastRunStartedAt)
    }

    func testCorruptWorkerLedgerIsQuarantinedAndGeometryRegeneratesOnRetry() async throws {
        let fixture = try makeFixture(named: "CorruptWorkerLedgerRecovery")
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
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let geometry = try XCTUnwrap(finished.geometryArtifact)
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
        let fixture = try makeFixture(named: "CancelledMappingResume")
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
        XCTAssertNil(interrupted.geometryArtifact)
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
        let mapping = try XCTUnwrap(finished.geometryArtifact?.mapping)
        XCTAssertEqual(mapping.attemptCount, 2)
        XCTAssertEqual(mapping.fallbackReason, "interrupted mapping resumed")
        XCTAssertEqual(finished.state.stage, .sfmMapping)
        XCTAssertNil(finished.checkpoint)
        XCTAssertNil(finished.lastRunStartedAt)
        XCTAssertNil(finished.geometryRecovery)
    }

    func testTerminalRetryAllocatesOrdinalAfterPreservedFailedAttempt() async throws {
        let fixture = try makeFixture(named: "TerminalMappingRetry")
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

        let mapping = try XCTUnwrap(
            ProjectMetadataStore.load(from: fixture.paths.metadataURL).geometryArtifact?.mapping
        )
        XCTAssertEqual(mapping.attemptCount, 1)
        XCTAssertEqual(mapping.acceptedMappingAttemptOrdinal, 2)
        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                from: fixture.paths.workerExecutionURL,
                projectPaths: fixture.paths
            ).mappingAndRefinementInvocations.map(\.mappingAttemptOrdinal),
            [1, 2, 2]
        )
    }

    func testOrderedQualityRejectionRetriesSameGraphWithConservativeCadence() async throws {
        let fixture = try makeFixture(
            named: "OrderedConservativeCadence",
            imageCount: 8,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let matchingProbe = MappingCadenceProbe()
        let lowCoverageReport = "Registered images: 2 / 8\nPoints: 20\nObservations: 40\nMean track length: 2.0\nMean reprojection error: 0.5\n"
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
                        registeredImageCount: 2
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
        let geometry = try XCTUnwrap(
            ProjectMetadataStore.load(from: fixture.paths.metadataURL).geometryArtifact
        )
        XCTAssertEqual(geometry.mapping.attemptCount, 2)
        XCTAssertEqual(geometry.mapping.acceptedRefinementInvocationCount, 1)
        XCTAssertEqual(geometry.mapping.incrementalCadence, .conservative)
        XCTAssertEqual(
            geometry.mapping.fallbackReason,
            "conservative mapping cadence after quality rejection"
        )
        XCTAssertEqual(geometry.pairGraph.measurement?.matcherAttempts.count, 1)
    }

    func testConservativeCadenceSurvivesCancellationWithoutRematching() async throws {
        let fixture = try makeFixture(
            named: "ConservativeCadenceResume",
            imageCount: 8,
            requestedRunOptions: RequestedRunOptions(
                capturePath: .walkthrough,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let lowCoverageReport = "Registered images: 2 / 8\nPoints: 20\nObservations: 40\nMean track length: 2.0\nMean reprojection error: 0.5\n"
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
                        registeredImageCount: 2
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
            .conservative
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
        let mapping = try XCTUnwrap(
            ProjectMetadataStore.load(from: fixture.paths.metadataURL).geometryArtifact?.mapping
        )
        XCTAssertEqual(mapping.attemptCount, 3)
        XCTAssertEqual(mapping.acceptedRefinementInvocationCount, 2)
        XCTAssertEqual(mapping.incrementalCadence, .conservative)
        XCTAssertEqual(
            mapping.fallbackReason,
            "conservative mapping cadence after quality rejection; interrupted mapping resumed"
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
    ) throws -> Fixture {
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
                value: UInt8(24 + (index * 23) % 220),
                utType: .png
            ))
        }

        let projectURL = root.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: name,
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: requestedRunOptions
            ),
            to: paths.metadataURL
        )

        return Fixture(
            root: root,
            projectURL: projectURL,
            paths: paths,
            toolchain: try makeToolchain(root: root),
            imageCount: imageCount
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

    private func da3FallbackPlan(for fixture: Fixture) throws -> ResolvedRunPlan {
        let metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var plan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        plan.fallbackRouteIdentifiers = [SfmBackend.colmap.rawValue]
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

    private func emptyVocabularyScript(for fixture: Fixture) -> MockSubprocessRunner.Script {
        .init(
            path: fixture.toolchain.colmap.path,
            argsPrefix: ["local_vocab_retriever"],
            result: successfulResult,
            onRun: { arguments in
                guard let outputPath = self.value(
                    for: "--output_pair_list_path",
                    in: arguments
                ) else {
                    throw FixtureError.missingArgument
                }
                try "".write(
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
          "source_version": "4.1.0",
          "source_commit": "fa8e3b3ff591552855f8ad2806723c80f963f69c",
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
        try "1 SIMPLE_PINHOLE 24 24 20 12 12\n".write(
            to: modelURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let imagesText = imageNames.enumerated()
            .map { offset, name in "\(offset + 1) 1 0 0 0 0 0 0 1 \(name)\n" }
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
            fallbackModelSubdirectory: value(for: "--fallback-model-subdir", in: arguments),
            processResolution: Int(value(for: "--process-res", in: arguments) ?? "") ?? 504,
            cameraType: value(for: "--camera-type", in: arguments) ?? "PINHOLE",
            sharedCamera: arguments.contains("--shared-camera"),
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
            try executeSQL("""
            CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                camera_id INTEGER NOT NULL
            );
            CREATE TABLE keypoints(
                image_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE descriptors(
                image_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                type INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE matches(
                pair_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE two_view_geometries(
                pair_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            INSERT INTO cameras(camera_id) VALUES (1);
            """, in: database)
            for (offset, imageName) in imageNames.enumerated() {
                let imageID = offset + 1
                try executeSQL(
                    "INSERT INTO images(image_id, name, camera_id) VALUES (\(imageID), '\(sqlQuoted(imageName))', 1);" +
                    "INSERT INTO keypoints(image_id, rows, cols) VALUES (\(imageID), 64, 4);" +
                    "INSERT INTO descriptors(image_id, rows, cols, type) VALUES (\(imageID), 64, 128, 0);",
                    in: database
                )
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
        try withDatabase(at: URL(fileURLWithPath: databasePath)) { database in
            let imageIDs = try imageIdentifiers(in: database)
            try executeSQL("BEGIN IMMEDIATE TRANSACTION;", in: database)
            do {
                for pair in pairs {
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
                        in: database
                    )
                }
                try executeSQL("COMMIT;", in: database)
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
        registeredImageCount: Int? = nil
    ) throws {
        let allImageNames = try selectedImageNames(for: fixture)
        let imageNames = Array(allImageNames.prefix(registeredImageCount ?? allImageNames.count))

        try writeSparseModel(at: modelURL, for: fixture, imageNames: imageNames)
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
        imageNames: [String]
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

        try "1 SIMPLE_PINHOLE 24 24 20 12 12\n".write(
            to: modelURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        var images = "# Image list\n"
        for imageName in imageNames {
            let imageID = imageIDByName[imageName]!
            images += "\(imageID) 1 0 0 0 0 0 0 1 \(imageName)\n"
            images += (1...20).map { "12 12 \($0)" }.joined(separator: " ") + "\n"
        }
        try images.write(
            to: modelURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let points = (1...20).map { pointID -> String in
            let track = imageNames
                .map { "\(imageIDByName[$0]!) \(pointID - 1)" }
                .joined(separator: " ")
            return "\(pointID) 0 0 1 128 128 128 0 \(track)"
        }
        try (points.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func withDatabase(
        at url: URL,
        operation: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.databaseOpenFailed
        }
        defer { sqlite3_close(database) }
        try operation(database)
    }

    private func imageIdentifiers(in database: OpaquePointer) throws -> [String: Int64] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT image_id, name FROM images;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw FixtureError.databaseQueryFailed
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else {
                throw FixtureError.databaseQueryFailed
            }
            result[String(cString: name)] = sqlite3_column_int64(statement, 0)
        }
        return result
    }

    private func executeSQL(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw FixtureError.sqlFailed(description)
        }
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

    private enum FixtureError: Error {
        case missingArgument
        case invalidPairList
        case invalidDa3ImageCount(Int)
        case databaseOpenFailed
        case databaseQueryFailed
        case invalidSparseModelImageNames
        case sqlFailed(String)
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
}
