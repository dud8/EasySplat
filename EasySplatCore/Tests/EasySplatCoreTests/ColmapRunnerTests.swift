#if canImport(XCTest)
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapRunnerTests: XCTestCase {
    private enum WorkerObserverTestError: Error, Equatable {
        case couldNotPersist
    }

    func testMapperReceivesBoundedGlobalBundleAdjustmentPolicy() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_max_num_iterations", in: args),
                        "75"
                    )
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: args), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: args), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: args), "2")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_max_refinements", in: args), "5")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_num_iterations", in: args), "10")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_function_tolerance", in: args), "0.001")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_function_tolerance", in: args), "1e-06")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_num_images", in: args), "6")
                    XCTAssertEqual(self.value(for: "--Mapper.random_seed", in: args), "42")
                    XCTAssertEqual(self.value(for: "--Mapper.min_num_matches", in: args), "15")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_refine_focal_length", in: args), "1")
                    XCTAssertNil(self.value(for: "--log_level", in: args))
                }
            )
        ])

        try await ColmapRunner(runner: runner).runMapper(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            outputPath: URL(fileURLWithPath: "/tmp/sparse"),
            environment: [:],
            mapperOptions: try ColmapMapperOptions(
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                localMaxRefinements: 2,
                globalMaxRefinements: 5,
                globalMaxNumIterations: 75,
                localMaxNumIterations: 10,
                localFunctionTolerance: 0.001,
                globalFunctionTolerance: 0.000_001,
                localImageCount: 6,
                randomSeed: 42,
                refineFocalLength: true
            ),
            mapperContext: mapperContext(),
            onLog: { _, _ in }
        )

        let removed = try XCTUnwrap(runner.removedEnvironmentKeys.first)
        XCTAssertTrue(
            Set([
                "OMP_NUM_THREADS",
                "OMP_THREAD_LIMIT",
                "OMP_DYNAMIC",
                "OMP_MAX_ACTIVE_LEVELS",
                "OMP_NESTED",
                "OPENBLAS_NUM_THREADS",
                "MKL_NUM_THREADS",
                "VECLIB_MAXIMUM_THREADS",
                "GOMP_CPU_AFFINITY",
                "KMP_AFFINITY",
                "KMP_HW_SUBSET",
            ]).isSubset(of: removed)
        )
    }

    func testMapperEnablesSolverReportsOnlyWhenExplicitlyRequested() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--log_level", in: args), "1")
                }
            ),
        ])

        try await ColmapRunner(runner: runner).runMapper(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            outputPath: URL(fileURLWithPath: "/tmp/sparse"),
            environment: [:],
            mapperOptions: try ColmapMapperOptions(
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                localMaxRefinements: 2,
                globalMaxRefinements: 5,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true
            ),
            mapperContext: mapperContext(),
            emitSolverReports: true,
            onLog: { _, _ in }
        )
    }

    func testMapperOptionsRejectInvalidBundleAdjustmentPolicy() {
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .invalidRatio("Global frame ratio")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: .infinity,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        ))
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: .nan,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .invalidRatio("Global point ratio")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 0,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Local refinement limit")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 0,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Global refinement limit")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 0,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Global iteration limit")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: UInt64(Int32.max) + 1,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .randomSeedOutOfRange
            )
        }

        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            localMaxNumIterations: 0,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Local iteration limit")
            )
        }

        for tolerance in [Double.nan, -.infinity, -0.001] {
            XCTAssertThrowsError(try ColmapMapperOptions(
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                localMaxRefinements: 2,
                globalMaxRefinements: 5,
                globalMaxNumIterations: 75,
                localFunctionTolerance: tolerance,
                randomSeed: 42,
                refineFocalLength: true
            )) { error in
                XCTAssertEqual(
                    error as? ColmapMapperOptionsValidationError,
                    .invalidTolerance("Local function tolerance")
                )
            }
        }

        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            globalFunctionTolerance: -.infinity,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .invalidTolerance("Global function tolerance")
            )
        }

        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            localMaxRefinements: 2,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            localImageCount: 0,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Local image count")
            )
        }
    }

    func testFeatureExtractorPassesMaxNumFeatures() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.max_image_size", in: args), "1024")
                    XCTAssertNil(self.value(for: "--SiftExtraction.max_image_size", in: args))
                    XCTAssertEqual(self.value(for: "--SiftExtraction.max_num_features", in: args), "5000")
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.num_threads", in: args), "12")
                    XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "1")
                    XCTAssertNil(self.value(for: "--ImageReader.camera_params", in: args))
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runFeatureExtractor(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            maxImageSize: 1024,
            cameraInitialization: .automaticSharedSimpleRadial,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 12,
                matchThreads: 1,
                maxNumFeatures: 5000
            ),
            onLog: { _, _ in }
        )

        XCTAssertEqual(runner.environments.first?["OMP_NUM_THREADS"], "12")
        XCTAssertTrue(try XCTUnwrap(runner.removedEnvironmentKeys.first).contains("OMP_THREAD_LIMIT"))
    }

    func testFeatureExtractorAllowsPerImageCameras() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "0")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runFeatureExtractor(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            maxImageSize: 1024,
            cameraInitialization: ColmapCameraInitializationReceipt(
                recipe: .colmapAutomatic,
                cameraModel: "SIMPLE_PINHOLE",
                singleCamera: false,
                pixelWidth: nil,
                pixelHeight: nil,
                diagonalFieldOfViewDegrees: nil,
                cameraParameters: nil,
                priorFocalLength: false
            ),
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 2,
                matchThreads: 1
            ),
            onLog: { _, _ in }
        )
    }

    func testMatchesImporterUsesFaissByDefault() async throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                    XCTAssertEqual(self.value(for: "--FeatureMatching.use_gpu", in: args), "0")
                    XCTAssertEqual(
                        args.filter { $0 == "--FeatureMatching.use_gpu" }.count,
                        1
                    )
                    XCTAssertEqual(self.value(for: "--FeatureMatching.num_threads", in: args), "8")
                    XCTAssertEqual(self.value(for: "--match_type", in: args), "pairs")
                    XCTAssertEqual(
                        self.value(for: "--TwoViewGeometry.random_seed", in: args),
                        "2147483647"
                    )
                    XCTAssertEqual(
                        self.value(
                            for: "--EasySplat.require_empty_matching_results",
                            in: args
                        ),
                        "1"
                    )
                    XCTAssertEqual(
                        args.filter {
                            $0 == "--EasySplat.require_empty_matching_results"
                        }.count,
                        1
                    )
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatchesImporter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: fixture.database,
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
            randomSeed: UInt64(Int32.max),
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 8
            ),
            onLog: { _, _ in }
        )

        XCTAssertEqual(runner.environments.first?["OMP_NUM_THREADS"], "8")
        XCTAssertTrue(try XCTUnwrap(runner.removedEnvironmentKeys.first).contains("OMP_THREAD_LIMIT"))
    }

    func testMatchesImporterRejectsPreexistingRowsForEveryDescriptorMatcher() async throws {
        for (matcher, rawRows, verifiedRows) in [
            (DescriptorMatcher.faiss, 1, 0),
            (DescriptorMatcher.exact, 0, 1),
        ] {
            let fixture = try makeMatchingDatabase(
                rawRows: rawRows,
                verifiedRows: verifiedRows
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let runner = MockSubprocessRunner(scripts: [
                .init(
                    path: "/mock/colmap",
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    )
                )
            ])

            do {
                try await ColmapRunner(runner: runner).runMatchesImporter(
                    colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                    database: fixture.database,
                    matchListPath: fixture.root.appendingPathComponent("pairs.txt"),
                    matchType: "pairs",
                    randomSeed: 42,
                    options: ColmapOptions(
                        useGPU: false,
                        extractThreads: 1,
                        matchThreads: 1,
                        descriptorMatcher: matcher
                    ),
                    onLog: { _, _ in }
                )
                XCTFail("Expected \(matcher.rawValue) matching to reject stale rows")
            } catch {
                XCTAssertEqual(
                    error as? ColmapDatabaseMatchStoreError,
                    .matchingResultsNotEmpty(
                        rawMatchCount: Int64(rawRows),
                        verifiedMatchCount: Int64(verifiedRows)
                    )
                )
            }
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    func testMatchesImporterChecksForRowsAfterLoggingAndBeforeLaunch() async throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                )
            )
        ])

        do {
            try await ColmapRunner(runner: runner).runMatchesImporter(
                colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                database: fixture.database,
                matchListPath: fixture.root.appendingPathComponent("pairs.txt"),
                matchType: "pairs",
                randomSeed: 42,
                options: ColmapOptions(
                    useGPU: false,
                    extractThreads: 1,
                    matchThreads: 1
                ),
                onLog: { _, _ in
                    try? Self.insertRawMatch(at: fixture.database)
                }
            )
            XCTFail("Expected the launch-boundary check to reject the injected row")
        } catch {
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .matchingResultsNotEmpty(rawMatchCount: 1, verifiedMatchCount: 0)
            )
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMatchesImporterRejectsOutOfRangeTwoViewGeometrySeedBeforeLaunch() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
            )
        ])

        do {
            try await ColmapRunner(runner: runner).runMatchesImporter(
                colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                database: URL(fileURLWithPath: "/tmp/db"),
                matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
                matchType: "pairs",
                randomSeed: UInt64(Int32.max) + 1,
                options: ColmapOptions(
                    useGPU: false,
                    extractThreads: 1,
                    matchThreads: 8
                ),
                onLog: { _, _ in }
            )
            XCTFail("Expected an out-of-range seed to fail before launch")
        } catch {
            XCTAssertEqual(
                error as? ColmapMatchesImporterOptionsValidationError,
                .randomSeedOutOfRange
            )
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMatchesImporterReportsBoundedWorkerEvidenceFromProcessReceipt() async throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        try await colmap.runMatchesImporter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: fixture.database,
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
            randomSeed: 42,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 8,
                environment: ["NON_THREAD_SENTINEL": "preserved-at-launch"]
            ),
            onLog: { _, _ in }
        )

        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .matchesImporter)
        XCTAssertEqual(invocation.threadPolicy, .bounded)
        XCTAssertEqual(invocation.argvWorkerCount, 8)
        XCTAssertEqual(invocation.explicitThreadEnvironment, [
            "MKL_NUM_THREADS": "8",
            "OMP_NUM_THREADS": "8",
            "OPENBLAS_NUM_THREADS": "8",
        ])
        XCTAssertEqual(
            invocation.removedThreadEnvironmentKeysSHA256,
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256
        )
        XCTAssertEqual(
            invocation.effectiveSanitizedThreadEnvironment,
            invocation.explicitThreadEnvironment
        )
        XCTAssertEqual(invocation.exitStatus, 0)
        XCTAssertTrue(invocation.succeeded)
        XCTAssertNil(invocation.explicitThreadEnvironment["NON_THREAD_SENTINEL"])
    }

    func testMapperReportsNativeAutoWorkerEvidenceFromProcessReceipt() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        try await colmap.runMapper(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            outputPath: URL(fileURLWithPath: "/tmp/sparse"),
            environment: [:],
            mapperOptions: try ColmapMapperOptions(
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                localMaxRefinements: 2,
                globalMaxRefinements: 5,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true
            ),
            mapperContext: mapperContext(),
            onLog: { _, _ in }
        )

        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .mapper)
        XCTAssertEqual(invocation.threadPolicy, .nativeAuto)
        XCTAssertNil(invocation.argvWorkerCount)
        XCTAssertEqual(invocation.explicitThreadEnvironment, [:])
        XCTAssertEqual(
            invocation.removedThreadEnvironmentKeysSHA256,
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256
        )
        XCTAssertEqual(invocation.effectiveSanitizedThreadEnvironment, [:])
        let mapper = try XCTUnwrap(invocation.mapperExecution)
        XCTAssertEqual(mapper.incrementalCadence, .balancedGlobal)
        XCTAssertEqual(mapper.globalMaxNumIterations, 75)
        XCTAssertEqual(mapper.randomSeed, 42)
        XCTAssertTrue(mapper.refineFocalLength)
        XCTAssertEqual(mapper.minimumPairInlierCount, 15)
        XCTAssertEqual(mapper.pairGraphAttemptOrdinal, 2)
        XCTAssertEqual(mapper.pairListDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(mapper.descriptorMatcher, .faiss)
        XCTAssertEqual(
            mapper.matchingDatabaseDigest,
            String(repeating: "c", count: 64)
        )
        XCTAssertNil(mapper.evaluation)
        XCTAssertEqual(invocation.exitStatus, 0)
        XCTAssertTrue(invocation.succeeded)
    }

    func testWorkerObserverRejectsMissingOrMismatchedProcessReceipt() async throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mismatchedReceipt = SubprocessEnvironmentReceipt(
            explicitOverrides: [
                "OMP_NUM_THREADS": "8",
                "OPENBLAS_NUM_THREADS": "8",
                "MKL_NUM_THREADS": "8",
            ],
            removedKeys: ["OMP_NUM_THREADS"],
            effectiveValuesForControlledKeys: [
                "OMP_NUM_THREADS": "8",
                "OPENBLAS_NUM_THREADS": "8",
                "MKL_NUM_THREADS": "8",
            ]
        )

        for receipt in [nil, mismatchedReceipt] as [SubprocessEnvironmentReceipt?] {
            let runner = FixedSubprocessResultRunner(result: .init(
                exitCode: 0,
                terminationReason: .exit,
                stdout: "",
                stderr: "",
                environmentReceipt: receipt
            ))
            let evidence = WorkerEvidenceSink()
            let colmap = ColmapRunner(runner: runner)
            colmap.setWorkerExecutionObserver { invocation in
                evidence.append(invocation)
            }

            do {
                try await colmap.runMatchesImporter(
                    colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                    database: fixture.database,
                    matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
                    matchType: "pairs",
                    randomSeed: 42,
                    options: ColmapOptions(
                        useGPU: false,
                        extractThreads: 1,
                        matchThreads: 8
                    ),
                    onLog: { _, _ in }
                )
                XCTFail("Expected worker evidence to fail closed")
            } catch ColmapRunnerError.executionEvidenceUnavailable(let command) {
                XCTAssertEqual(command, ColmapWorkerCommandIdentity.matchesImporter.rawValue)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(evidence.values.isEmpty)
        }
    }

    func testRealBoundedChildSanitizesCanonicalThreadEnvironmentAndRecordsOnce() async throws {
        let previousEnvironment = poisonCanonicalThreadEnvironment()
        defer { restoreEnvironment(previousEnvironment) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingDatabase = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: matchingDatabase.root) }
        let executable = root.appendingPathComponent("bounded-colmap.sh")
        try TestFileBuilder.createExecutable(
            at: executable,
            script: "#!/bin/sh\n/usr/bin/env\n"
        )
        let log = LockedLogLines()
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner()
        colmap.setWorkerExecutionObserver { evidence.append($0) }

        try await colmap.runMatchesImporter(
            colmapPath: executable,
            database: matchingDatabase.database,
            matchListPath: root.appendingPathComponent("pairs.txt"),
            matchType: "pairs",
            randomSeed: 42,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 6,
                environment: canonicalThreadEnvironmentOverrides()
            ),
            onLog: { line, _ in log.append(line) }
        )

        let childEnvironment = environmentValues(in: log.values)
        let expected = [
            "MKL_NUM_THREADS": "6",
            "OMP_NUM_THREADS": "6",
            "OPENBLAS_NUM_THREADS": "6",
        ]
        for key in GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys {
            XCTAssertEqual(childEnvironment[key], expected[key], "Unexpected child value for \(key)")
        }
        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .matchesImporter)
        XCTAssertEqual(invocation.explicitThreadEnvironment, expected)
        XCTAssertEqual(invocation.effectiveSanitizedThreadEnvironment, expected)
        XCTAssertTrue(invocation.succeeded)
    }

    func testRealNativeAutoChildFailureSanitizesThreadEnvironmentAndRecordsOnce() async throws {
        let previousEnvironment = poisonCanonicalThreadEnvironment()
        defer { restoreEnvironment(previousEnvironment) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("failed-native-auto-colmap.sh")
        try TestFileBuilder.createExecutable(
            at: executable,
            script: "#!/bin/sh\n/usr/bin/env\nexit 17\n"
        )
        let log = LockedLogLines()
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner()
        colmap.setWorkerExecutionObserver { evidence.append($0) }

        do {
            try await colmap.runMapper(
                colmapPath: executable,
                database: root.appendingPathComponent("database.db"),
                imagePath: root.appendingPathComponent("images"),
                outputPath: root.appendingPathComponent("sparse"),
                environment: canonicalThreadEnvironmentOverrides(),
                mapperOptions: try ColmapMapperOptions(
                    globalFramesRatio: 1.4,
                    globalPointsRatio: 1.4,
                    localMaxRefinements: 2,
                    globalMaxRefinements: 5,
                    globalMaxNumIterations: 75,
                    randomSeed: 42,
                    refineFocalLength: true
                ),
                mapperContext: mapperContext(),
                onLog: { line, _ in log.append(line) }
            )
            XCTFail("Expected mapper failure")
        } catch ColmapRunnerError.failed(let command, let exitCode, _, _, _) {
            XCTAssertEqual(command, "mapper")
            XCTAssertEqual(exitCode, 17)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let childEnvironment = environmentValues(in: log.values)
        for key in GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys {
            XCTAssertNil(childEnvironment[key], "Native-auto child inherited \(key)")
        }
        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .mapper)
        XCTAssertEqual(invocation.exitStatus, 17)
        XCTAssertFalse(invocation.succeeded)
        let mapper = try XCTUnwrap(invocation.mapperExecution)
        XCTAssertEqual(mapper.incrementalCadence, .balancedGlobal)
        XCTAssertEqual(mapper.pairGraphAttemptOrdinal, 2)
        XCTAssertNil(mapper.evaluation)
        XCTAssertTrue(invocation.explicitThreadEnvironment.isEmpty)
        XCTAssertTrue(invocation.effectiveSanitizedThreadEnvironment.isEmpty)
    }

    func testRealCancelledChildRecordsTerminationEvidenceExactlyOnce() async throws {
        let previousEnvironment = poisonCanonicalThreadEnvironment()
        defer { restoreEnvironment(previousEnvironment) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingDatabase = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: matchingDatabase.root) }
        let executable = root.appendingPathComponent("cancelled-colmap.sh")
        try TestFileBuilder.createExecutable(
            at: executable,
            script: """
            #!/bin/sh
            trap 'exit 25' INT TERM
            /usr/bin/env
            printf '__EASYSPLAT_READY__\\n'
            while :; do /bin/sleep 1; done
            """
        )
        let ready = DispatchSemaphore(value: 0)
        let log = LockedLogLines()
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner()
        colmap.setWorkerExecutionObserver { evidence.append($0) }

        let task = Task {
            try await colmap.runMatchesImporter(
                colmapPath: executable,
                database: matchingDatabase.database,
                matchListPath: root.appendingPathComponent("pairs.txt"),
                matchType: "pairs",
                randomSeed: 42,
                options: ColmapOptions(
                    useGPU: false,
                    extractThreads: 1,
                    matchThreads: 5
                ),
                onLog: { line, _ in
                    log.append(line)
                    if line == "__EASYSPLAT_READY__" { ready.signal() }
                }
            )
        }

        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: ready.wait(timeout: .now() + 2) == .success)
            }
        }
        guard didStart else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Child process did not start")
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The termination callback must run before cancellation is rethrown.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .matchesImporter)
        XCTAssertNotEqual(invocation.exitStatus, 0)
        XCTAssertFalse(invocation.succeeded)
        let expected = [
            "MKL_NUM_THREADS": "5",
            "OMP_NUM_THREADS": "5",
            "OPENBLAS_NUM_THREADS": "5",
        ]
        XCTAssertEqual(invocation.explicitThreadEnvironment, expected)
        XCTAssertEqual(invocation.effectiveSanitizedThreadEnvironment, expected)
        let childEnvironment = environmentValues(in: log.values)
        for key in GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys {
            XCTAssertEqual(childEnvironment[key], expected[key], "Unexpected child value for \(key)")
        }
    }

    func testRealCancelledChildPreservesWorkerObserverFailureExactlyOnce() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingDatabase = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: matchingDatabase.root) }
        let executable = root.appendingPathComponent("cancelled-colmap-observer-failure.sh")
        try TestFileBuilder.createExecutable(
            at: executable,
            script: """
            #!/bin/sh
            trap 'exit 26' INT TERM
            printf '__EASYSPLAT_READY__\\n'
            while :; do /bin/sleep 1; done
            """
        )
        let ready = DispatchSemaphore(value: 0)
        let attempts = WorkerEvidenceSink()
        let colmap = ColmapRunner()
        colmap.setWorkerExecutionObserver { invocation in
            attempts.append(invocation)
            throw WorkerObserverTestError.couldNotPersist
        }

        let task = Task {
            try await colmap.runMatchesImporter(
                colmapPath: executable,
                database: matchingDatabase.database,
                matchListPath: root.appendingPathComponent("pairs.txt"),
                matchType: "pairs",
                randomSeed: 42,
                options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 4),
                onLog: { line, _ in
                    if line == "__EASYSPLAT_READY__" { ready.signal() }
                }
            )
        }

        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: ready.wait(timeout: .now() + 2) == .success)
            }
        }
        guard didStart else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Child process did not start")
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected durable worker-evidence failure")
        } catch let error as WorkerObserverTestError {
            XCTAssertEqual(error, .couldNotPersist)
        } catch {
            XCTFail("Expected worker-observer failure, got \(error)")
        }

        XCTAssertEqual(attempts.values.count, 1)
        let invocation = try XCTUnwrap(attempts.values.first)
        XCTAssertEqual(invocation.command, .matchesImporter)
        XCTAssertFalse(invocation.succeeded)
    }

    func testCancellationWithoutTerminationResultDoesNotFabricateWorkerEvidence() async throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in throw CancellationError() }
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { evidence.append($0) }

        do {
            try await colmap.runMatchesImporter(
                colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                database: fixture.database,
                matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
                matchType: "pairs",
                randomSeed: 42,
                options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 4),
                onLog: { _, _ in }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // No process result exists, so no evidence can truthfully be recorded.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertTrue(evidence.values.isEmpty)
    }

    func testLocalVocabularyRetrieverUsesPinnedOfflineConfiguration() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--database_path", in: args), "/tmp/database.db")
                    XCTAssertEqual(self.value(for: "--output_pair_list_path", in: args), "/tmp/retrieval.txt")
                    XCTAssertEqual(self.value(for: "--query_image_list_path", in: args), "/tmp/queries.txt")
                    XCTAssertEqual(self.value(for: "--excluded_pair_list_path", in: args), "/tmp/excluded.txt")
                    XCTAssertNil(self.value(for: "--image_group_list_path", in: args))
                    XCTAssertNil(self.value(for: "--image_group_list_digest", in: args))
                    XCTAssertEqual(self.value(for: "--num_images", in: args), "40")
                    XCTAssertEqual(self.value(for: "--returned_neighbor_count", in: args), "16")
                    XCTAssertEqual(self.value(for: "--minimum_frame_separation", in: args), "25")
                    XCTAssertEqual(self.value(for: "--query_stride", in: args), "10")
                    XCTAssertEqual(
                        self.value(for: "--request_digest", in: args),
                        String(repeating: "a", count: 64)
                    )
                    XCTAssertEqual(self.value(for: "--num_visual_words", in: args), "512")
                    XCTAssertEqual(self.value(for: "--max_features_per_image", in: args), "512")
                    XCTAssertEqual(self.value(for: "--max_training_descriptors", in: args), "65536")
                    XCTAssertEqual(self.value(for: "--num_iterations", in: args), "10")
                    XCTAssertEqual(self.value(for: "--num_rounds", in: args), "1")
                    XCTAssertEqual(self.value(for: "--num_checks", in: args), "64")
                    XCTAssertEqual(self.value(for: "--num_threads", in: args), "6")
                    XCTAssertEqual(self.value(for: "--memory_budget_bytes", in: args), "8589934592")
                }
            )
        ])

        try await ColmapRunner(runner: runner).runLocalVocabularyRetriever(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            outputPairListPath: URL(fileURLWithPath: "/tmp/retrieval.txt"),
            queryImageListPath: URL(fileURLWithPath: "/tmp/queries.txt"),
            excludedPairListPath: URL(fileURLWithPath: "/tmp/excluded.txt"),
            options: try ColmapVocabularyRetrievalOptions(
                candidateCount: 40,
                returnedNeighborCount: 16,
                minimumFrameSeparation: 25,
                queryStride: 10,
                threadCount: 6,
                memoryBudgetBytes: 8_589_934_592
            ),
            pairContext: ColmapPairWorkerInvocationContext(
                attemptOrdinal: 1,
                descriptorMatcher: .faiss,
                retrievalRequestDigest: String(repeating: "a", count: 64),
                retrievalOutputURL: URL(fileURLWithPath: "/tmp/retrieval.txt")
            ),
            onLog: { _, _ in }
        )

        XCTAssertEqual(runner.environments.first?["OMP_NUM_THREADS"], "6")
        XCTAssertTrue(try XCTUnwrap(runner.removedEnvironmentKeys.first).contains("OMP_THREAD_LIMIT"))
    }

    func testLocalVocabularyRetrieverBindsCrossGroupInputsTogether() async throws {
        let digest = String(repeating: "b", count: 64)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(
                        self.value(for: "--image_group_list_path", in: args),
                        "/tmp/image-groups.txt"
                    )
                    XCTAssertEqual(
                        self.value(for: "--image_group_list_digest", in: args),
                        digest
                    )
                }
            )
        ])

        try await ColmapRunner(runner: runner).runLocalVocabularyRetriever(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            outputPairListPath: URL(fileURLWithPath: "/tmp/retrieval.txt"),
            queryImageListPath: URL(fileURLWithPath: "/tmp/queries.txt"),
            excludedPairListPath: nil,
            imageGroupListPath: URL(fileURLWithPath: "/tmp/image-groups.txt"),
            imageGroupListDigest: digest,
            options: try ColmapVocabularyRetrievalOptions(
                candidateCount: 20,
                returnedNeighborCount: 8,
                minimumFrameSeparation: 0,
                queryStride: 1,
                threadCount: 4
            ),
            pairContext: ColmapPairWorkerInvocationContext(
                attemptOrdinal: 1,
                descriptorMatcher: .faiss,
                retrievalRequestDigest: String(repeating: "a", count: 64),
                retrievalOutputURL: URL(fileURLWithPath: "/tmp/retrieval.txt")
            ),
            onLog: { _, _ in }
        )
    }

    func testLocalVocabularyRetrieverRejectsHalfBoundCrossGroupInput() async throws {
        do {
            try await ColmapRunner(runner: MockSubprocessRunner(scripts: []))
                .runLocalVocabularyRetriever(
                    colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                    database: URL(fileURLWithPath: "/tmp/database.db"),
                    outputPairListPath: URL(fileURLWithPath: "/tmp/retrieval.txt"),
                    queryImageListPath: URL(fileURLWithPath: "/tmp/queries.txt"),
                    excludedPairListPath: nil,
                    imageGroupListPath: URL(fileURLWithPath: "/tmp/image-groups.txt"),
                    imageGroupListDigest: nil,
                    options: try ColmapVocabularyRetrievalOptions(
                        candidateCount: 20,
                        returnedNeighborCount: 8,
                        minimumFrameSeparation: 0,
                        queryStride: 1,
                        threadCount: 4
                    ),
                    pairContext: ColmapPairWorkerInvocationContext(
                        attemptOrdinal: 1,
                        descriptorMatcher: .faiss,
                        retrievalRequestDigest: String(repeating: "a", count: 64),
                        retrievalOutputURL: URL(fileURLWithPath: "/tmp/retrieval.txt")
                    ),
                    onLog: { _, _ in }
                )
            XCTFail("Expected an incomplete V3 binding to be rejected")
        } catch let error as ColmapRunnerError {
            guard case .executionEvidenceUnavailable("local_vocab_retriever") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLocalVocabularyRetrieverRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 8,
            returnedNeighborCount: 9,
            minimumFrameSeparation: 0,
            queryStride: 1,
            threadCount: 1
        )) { error in
            XCTAssertEqual(
                error as? ColmapVocabularyRetrievalOptionsValidationError,
                .neighborCountExceedsCandidateCount
            )
        }
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: -1,
            queryStride: 1,
            threadCount: 1
        ))
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            queryStride: 0,
            threadCount: 1
        )) { error in
            XCTAssertEqual(
                error as? ColmapVocabularyRetrievalOptionsValidationError,
                .queryStrideOutOfRange
            )
        }
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            queryStride: 1,
            threadCount: 0
        ))
        for outOfRange in [
            ColmapVocabularyRetrievalOptions.minimumMemoryBudgetBytes - 1,
            ColmapVocabularyRetrievalOptions.maximumMemoryBudgetBytes + 1,
        ] {
            XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
                candidateCount: 20,
                returnedNeighborCount: 8,
                minimumFrameSeparation: 0,
                queryStride: 1,
                threadCount: 1,
                memoryBudgetBytes: outOfRange
            )) { error in
                XCTAssertEqual(
                    error as? ColmapVocabularyRetrievalOptionsValidationError,
                    .memoryBudgetOutOfRange
                )
            }
        }
    }

    func testExactRecoveryUsesBruteForceMatching() async throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatchesImporter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: fixture.database,
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
            randomSeed: 42,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 1,
                descriptorMatcher: .exact
            ),
            onLog: { _, _ in }
        )
    }

    func testPointTriangulatorUsesSeedAndOutputPaths() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["point_triangulator"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--database_path", in: args), "/tmp/db")
                    XCTAssertEqual(self.value(for: "--image_path", in: args), "/tmp/images")
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/seed")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/sparse")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runPointTriangulator(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            inputPath: URL(fileURLWithPath: "/tmp/seed"),
            outputPath: URL(fileURLWithPath: "/tmp/sparse"),
            environment: [:],
            onLog: { _, _ in }
        )
    }

    func testBundleAdjusterPassesRefinementKnobs() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/in")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/out")
                    XCTAssertEqual(self.value(for: "--BundleAdjustmentCeres.max_num_iterations", in: args), "35")
                    XCTAssertNil(self.value(for: "--BundleAdjustment.max_num_iterations", in: args))
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.refine_focal_length", in: args), "0")
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.refine_principal_point", in: args), "1")
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.refine_extra_params", in: args), "1")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runBundleAdjuster(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            environment: [:],
            bundleOptions: ColmapBundleAdjustmentOptions(
                maxNumIterations: 35,
                refineFocalLength: false,
                refinePrincipalPoint: true,
                refineExtraParams: true
            ),
            onLog: { _, _ in }
        )
    }

    func testBundleAdjusterCreatesOutputDirectoryWhenMissing() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputPath = temp.appendingPathComponent("in", isDirectory: true)
        let outputPath = temp.appendingPathComponent("missing_out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputPath, withIntermediateDirectories: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: outputPath.path, isDirectory: &isDirectory)
                    XCTAssertTrue(exists)
                    XCTAssertTrue(isDirectory.boolValue)
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runBundleAdjuster(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: inputPath,
            outputPath: outputPath,
            environment: [:],
            bundleOptions: ColmapBundleAdjustmentOptions(
                maxNumIterations: 10,
                refineFocalLength: true,
                refinePrincipalPoint: false,
                refineExtraParams: false
            ),
            onLog: { _, _ in }
        )
    }

    func testBundleAdjusterDoesNotRetryWithUnsupportedLegacyIterationFlag() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "Failed to parse options - unrecognised option '--BundleAdjustmentCeres.max_num_iterations'."
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--BundleAdjustmentCeres.max_num_iterations", in: args), "20")
                    XCTAssertNil(self.value(for: "--BundleAdjustment.max_num_iterations", in: args))
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        do {
            try await colmap.runBundleAdjuster(
                colmapPath: URL(fileURLWithPath: "/mock/colmap"),
                inputPath: URL(fileURLWithPath: "/tmp/in"),
                outputPath: URL(fileURLWithPath: "/tmp/out"),
                environment: [:],
                bundleOptions: ColmapBundleAdjustmentOptions(
                    maxNumIterations: 20,
                    refineFocalLength: true,
                    refinePrincipalPoint: false,
                    refineExtraParams: false
                ),
                onLog: { _, _ in }
            )
            XCTFail("Expected unsupported native option failure")
        } catch {
            XCTAssertTrue(error is ColmapRunnerError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterUsesTxtOutput() throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/in")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/out")
                    XCTAssertEqual(self.value(for: "--output_type", in: args), "TXT")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try colmap.runModelConverter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            onLog: { _, _ in }
        )
    }

    func testModelConverterReportsNativeAutoWorkerEvidenceFromProcessReceipt() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in try self.writeConvertedModel(at: fixture.output) }
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            environment: [:],
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )

        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .modelConverter)
        XCTAssertEqual(invocation.threadPolicy, .nativeAuto)
        XCTAssertNil(invocation.argvWorkerCount)
        XCTAssertEqual(invocation.explicitThreadEnvironment, [:])
        XCTAssertEqual(
            invocation.removedThreadEnvironmentKeysSHA256,
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeysSHA256
        )
        XCTAssertEqual(invocation.effectiveSanitizedThreadEnvironment, [:])
        XCTAssertEqual(invocation.exitStatus, 0)
        XCTAssertTrue(invocation.succeeded)
        XCTAssertNotNil(invocation.modelConversion?.convertedModelDigest)
        XCTAssertEqual(
            invocation.modelConversion?.candidateProjectRelativePath,
            "SfM/colmap/sparse/0"
        )
        XCTAssertEqual(invocation.modelConversion?.executableComponentPath, "bin/colmap")
        XCTAssertEqual(
            invocation.modelConversion?.executableSHA256,
            try GeometryArtifactStore.sha256(of: fixture.executable)
        )
        XCTAssertEqual(runner.environments, [[:]])
        XCTAssertTrue(
            Set(GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys)
                .isSubset(of: try XCTUnwrap(runner.removedEnvironmentKeys.first))
        )
    }

    func testModelConverterAcceptsColmap41AuxiliaryTextFiles() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try Data("converted rigs.txt".utf8).write(
                        to: fixture.output.appendingPathComponent("rigs.txt")
                    )
                    try Data("converted frames.txt".utf8).write(
                        to: fixture.output.appendingPathComponent("frames.txt")
                    )
                }
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )

        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertNotNil(evidence.values.first?.modelConversion?.convertedModelDigest)
    }

    func testModelConverterRejectsUnknownAuxiliaryTextFile() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try Data("unexpected".utf8).write(
                        to: fixture.output.appendingPathComponent("unsupported.txt")
                    )
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected exact-output-membership failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
        }
    }

    func testModelConverterRejectsSymlinkedColmap41AuxiliaryTextFile() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-frames.txt")
        try Data("outside frames".utf8).write(to: outside)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try Data("converted rigs.txt".utf8).write(
                        to: fixture.output.appendingPathComponent("rigs.txt")
                    )
                    try FileManager.default.createSymbolicLink(
                        at: fixture.output.appendingPathComponent("frames.txt"),
                        withDestinationURL: outside
                    )
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected no-follow auxiliary failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
        }
    }

    func testModelConverterRejectsHardLinkedColmap41AuxiliaryTextFile() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-frames.txt")
        try Data("outside frames".utf8).write(to: outside)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try Data("converted rigs.txt".utf8).write(
                        to: fixture.output.appendingPathComponent("rigs.txt")
                    )
                    try FileManager.default.linkItem(
                        at: outside,
                        to: fixture.output.appendingPathComponent("frames.txt")
                    )
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
    }

    func testModelConverterRejectsFifoColmap41AuxiliaryTextFileWithoutBlocking() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try Data("converted rigs.txt".utf8).write(
                        to: fixture.output.appendingPathComponent("rigs.txt")
                    )
                    let path = fixture.output.appendingPathComponent("frames.txt").path
                    guard Darwin.mkfifo(path, mode_t(0o600)) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
    }

    func testModelConverterAuxiliaryBytesDoNotChangeCanonicalModelDigest() throws {
        func convertedDigest(auxiliaryMarker: String) throws -> String {
            let fixture = try makeModelConversionFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let runner = MockSubprocessRunner(scripts: [
                .init(
                    path: fixture.executable.path,
                    argsPrefix: ["model_converter"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { _ in
                        try self.writeConvertedModel(at: fixture.output)
                        try Data("rigs \(auxiliaryMarker)".utf8).write(
                            to: fixture.output.appendingPathComponent("rigs.txt")
                        )
                        try Data("frames \(auxiliaryMarker)".utf8).write(
                            to: fixture.output.appendingPathComponent("frames.txt")
                        )
                    }
                )
            ])
            let evidence = WorkerEvidenceSink()
            let colmap = ColmapRunner(runner: runner)
            colmap.setWorkerExecutionObserver { invocation in
                evidence.append(invocation)
            }
            try colmap.runModelConverter(
                colmapPath: fixture.executable,
                inputPath: fixture.input,
                outputPath: fixture.output,
                recordGeometryWorkerExecution: true,
                modelConversionContext: fixture.context,
                onLog: { _, _ in }
            )
            return try XCTUnwrap(evidence.values.first?.modelConversion?.convertedModelDigest)
        }

        XCTAssertEqual(
            try convertedDigest(auxiliaryMarker: "first"),
            try convertedDigest(auxiliaryMarker: "second")
        )
    }

    func testModelConverterAllowsUnrelatedSiblingChurnInSharedAncestor() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sharedAncestor = fixture.root.deletingLastPathComponent()
        let unrelatedSibling = sharedAncestor.appendingPathComponent(
            "unrelated-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: unrelatedSibling) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try Data("unrelated sibling".utf8).write(to: unrelatedSibling)
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )

        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterRejectsExecutableSwapAndRestoreDuringInvocation() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bin = fixture.executable.deletingLastPathComponent()
        let executable = fixture.executable
        let replacement = bin.appendingPathComponent("replacement")
        let held = bin.appendingPathComponent("held")
        try Data("replacement executable".utf8).write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: replacement.path
        )
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try FileManager.default.moveItem(at: executable, to: held)
                    try FileManager.default.moveItem(at: replacement, to: executable)
                    try FileManager.default.moveItem(at: executable, to: replacement)
                    try FileManager.default.moveItem(at: held, to: executable)
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            environment: [:],
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterRejectsOpenMPRuntimeSwapAndRestoreDuringInvocation() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let libraryDirectory = fixture.root.appendingPathComponent("lib", isDirectory: true)
        let library = libraryDirectory.appendingPathComponent("libomp.dylib")
        let replacement = libraryDirectory.appendingPathComponent("replacement-libomp.dylib")
        let held = libraryDirectory.appendingPathComponent("held-libomp.dylib")
        try Data("replacement OpenMP runtime".utf8).write(to: replacement)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try FileManager.default.moveItem(at: library, to: held)
                    try FileManager.default.moveItem(at: replacement, to: library)
                    try FileManager.default.moveItem(at: library, to: replacement)
                    try FileManager.default.moveItem(at: held, to: library)
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected runtime-closure failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterRejectsInputPathOutsideRecordedContext() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let differentInput = fixture.root.appendingPathComponent("different-input")
        try FileManager.default.createDirectory(at: differentInput, withIntermediateDirectories: false)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in try self.writeConvertedModel(at: fixture.output) }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: differentInput,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testModelConverterRejectsOutputPathOutsideRecordedContext() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let differentOutput = fixture.root.appendingPathComponent("different-output")
        try FileManager.default.createDirectory(at: differentOutput, withIntermediateDirectories: false)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in try self.writeConvertedModel(at: fixture.output) }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: differentOutput,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRecordedModelConverterRejectsNonTextOutput() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in try self.writeConvertedModel(at: fixture.output) }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            outputType: "BIN",
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testModelConverterRejectsCandidateSwapAndRestoreDuringInvocation() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.input.appendingPathComponent("images.bin")
        let replacement = fixture.root.appendingPathComponent("replacement-images.bin")
        let held = fixture.root.appendingPathComponent("held-images.bin")
        try Data("replacement images".utf8).write(to: replacement)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try FileManager.default.moveItem(at: source, to: held)
                    try FileManager.default.moveItem(at: replacement, to: source)
                    try FileManager.default.moveItem(at: source, to: replacement)
                    try FileManager.default.moveItem(at: held, to: source)
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterRejectsUnexpectedBinaryModelMemberBeforeLaunch() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("unsupported rigs".utf8).write(
            to: fixture.input.appendingPathComponent("rigs.bin")
        )
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected exact-input-membership failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testModelConverterRejectsPreexistingTextOutputBeforeLaunch() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("stale output".utf8).write(
            to: fixture.output.appendingPathComponent("cameras.txt")
        )
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected empty-staging failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testModelConverterRejectsSymlinkedStagingDescendantBeforeLaunch() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-binary", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.input, to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.input, withDestinationURL: outside)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in try self.writeConvertedModel(at: fixture.output) }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected no-follow project binding failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testModelConverterRejectsExecutableAncestorPathSwap() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trustedRoot = fixture.root.appendingPathComponent("trusted-toolchain", isDirectory: true)
        let trustedBin = trustedRoot.appendingPathComponent("bin", isDirectory: true)
        let trustedLib = trustedRoot.appendingPathComponent("lib", isDirectory: true)
        let executable = trustedBin.appendingPathComponent("colmap")
        let replacementRoot = fixture.root.appendingPathComponent(
            "replacement-toolchain",
            isDirectory: true
        )
        let replacementBin = replacementRoot.appendingPathComponent("bin", isDirectory: true)
        let replacementExecutable = replacementBin.appendingPathComponent("colmap")
        let heldRoot = fixture.root.appendingPathComponent("held-toolchain", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trustedLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementBin, withIntermediateDirectories: true)
        try writeExecutableFixture("trusted nested executable", to: executable)
        try Data("trusted nested OpenMP runtime".utf8).write(
            to: trustedLib.appendingPathComponent("libomp.dylib")
        )
        try writeExecutableFixture("replacement nested executable", to: replacementExecutable)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try self.writeConvertedModel(at: fixture.output)
                    try FileManager.default.moveItem(at: trustedRoot, to: heldRoot)
                    try FileManager.default.moveItem(at: replacementRoot, to: trustedRoot)
                }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        ))
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterStripsDynamicLoaderInjection() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in try self.writeConvertedModel(at: fixture.output) }
            )
        ])
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { _ in }

        try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            environment: ["DYLD_INSERT_LIBRARIES": "/tmp/untrusted.dylib"],
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )

        XCTAssertNil(runner.environments.first?["DYLD_INSERT_LIBRARIES"])
        XCTAssertTrue(
            try XCTUnwrap(runner.removedEnvironmentKeys.first)
                .contains("DYLD_INSERT_LIBRARIES")
        )
    }

    func testModelConverterReportsFailedInvocationBeforeThrowing() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["model_converter"],
                result: .init(
                    exitCode: 9,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "conversion failed"
                )
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            environment: [:],
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.failed(let command, let exitCode, _, _, _) = error else {
                return XCTFail("Expected converter failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
            XCTAssertEqual(exitCode, 9)
        }

        let invocation = try XCTUnwrap(evidence.values.first)
        XCTAssertEqual(evidence.values.count, 1)
        XCTAssertEqual(invocation.command, .modelConverter)
        XCTAssertEqual(invocation.threadPolicy, .nativeAuto)
        XCTAssertEqual(invocation.exitStatus, 9)
        XCTAssertFalse(invocation.succeeded)
        XCTAssertNil(invocation.modelConversion?.convertedModelDigest)
        XCTAssertEqual(invocation.modelConversion?.executableComponentPath, "bin/colmap")
        XCTAssertEqual(
            invocation.modelConversion?.executableSHA256,
            try GeometryArtifactStore.sha256(of: fixture.executable)
        )
    }

    func testModelConverterRejectsZeroStatusTerminatedBySignal() throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["model_converter"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "terminated"
                )
            )
        ])

        XCTAssertThrowsError(try ColmapRunner(runner: runner).runModelConverter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.failed(
                let command,
                let exitCode,
                let terminationReason,
                _,
                _
            ) = error else {
                return XCTFail("Expected signal termination failure, got \(error)")
            }
            XCTAssertEqual(command, "model_converter")
            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(terminationReason, .uncaughtSignal)
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testModelConverterFailsClosedWhenProcessReceiptIsUnavailable() throws {
        let fixture = try makeModelConversionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runner = FixedSubprocessResultRunner(result: .init(
            exitCode: 0,
            terminationReason: .exit,
            stdout: "",
            stderr: "",
            environmentReceipt: nil
        ), onRun: { _ in
            try self.writeConvertedModel(at: fixture.output)
        })
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: fixture.executable,
            inputPath: fixture.input,
            outputPath: fixture.output,
            environment: [:],
            recordGeometryWorkerExecution: true,
            modelConversionContext: fixture.context,
            onLog: { _, _ in }
        )) { error in
            guard case ColmapRunnerError.executionEvidenceUnavailable(let command) = error else {
                return XCTFail("Expected missing receipt failure, got \(error)")
            }
            XCTAssertEqual(command, ColmapWorkerCommandIdentity.modelConverter.rawValue)
        }
        XCTAssertTrue(evidence.values.isEmpty)
    }

    func testModelConverterDoesNotAttachTrainingConversionToGeometryEvidence() throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
            )
        ])
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        try colmap.runModelConverter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            outputType: "BIN",
            environment: [:],
            onLog: { _, _ in }
        )

        XCTAssertTrue(evidence.values.isEmpty)
    }

    func testImageUndistorterProducesBoundedColmapWorkspace() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["image_undistorter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--image_path", in: args), "/tmp/images")
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/sparse")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/undistorted")
                    XCTAssertEqual(self.value(for: "--output_type", in: args), "COLMAP")
                    XCTAssertEqual(self.value(for: "--copy_policy", in: args), "COPY")
                    XCTAssertEqual(self.value(for: "--max_image_size", in: args), "2048")
                }
            )
        ])

        try await ColmapRunner(runner: runner).runImageUndistorter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            inputPath: URL(fileURLWithPath: "/tmp/sparse"),
            outputPath: URL(fileURLWithPath: "/tmp/undistorted"),
            maxImageSize: 2_048,
            environment: [:],
            onLog: { _, _ in }
        )
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func makeMatchingDatabase(
        rawRows: Int,
        verifiedRows: Int
    ) throws -> (root: URL, database: URL) {
        let root = try TestFileBuilder.makeTempDir()
        let databaseURL = root.appendingPathComponent("database.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY);"
                + " CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        for pairIndex in 0..<rawRows {
            guard sqlite3_exec(
                database,
                "INSERT INTO matches VALUES (\(pairIndex + 1));",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        for pairIndex in 0..<verifiedRows {
            guard sqlite3_exec(
                database,
                "INSERT INTO two_view_geometries VALUES (\(pairIndex + 1));",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return (root, databaseURL)
    }

    private static func insertRawMatch(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "INSERT INTO matches VALUES (1);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func mapperContext() -> ColmapMapperWorkerInvocationContext {
        ColmapMapperWorkerInvocationContext(
            pairGraphAttemptOrdinal: 2,
            pairListDigest: String(repeating: "a", count: 64),
            descriptorMatcher: .faiss,
            matchingDatabaseDigest: String(repeating: "c", count: 64)
        )
    }

    private typealias ModelConversionFixture = (
        root: URL,
        executable: URL,
        input: URL,
        output: URL,
        context: ColmapModelConversionWorkerInvocationContext
    )

    private func makeModelConversionFixture() throws -> ModelConversionFixture {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        let rootPath = try temporaryRoot.path.withCString { path in
            guard let resolved = Darwin.realpath(path, nil) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let executable = bin.appendingPathComponent("colmap")
        let stagingRelativePath =
            "SfM/colmap/sparse/.text-model-00000000-0000-0000-0000-000000000000"
        let staging = root.appendingPathComponent(stagingRelativePath, isDirectory: true)
        let input = staging.appendingPathComponent("binary", isDirectory: true)
        let output = staging.appendingPathComponent("text", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("trusted executable".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )
        try Data("trusted OpenMP runtime".utf8).write(
            to: lib.appendingPathComponent("libomp.dylib")
        )
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data("binary \(name)".utf8).write(
                to: input.appendingPathComponent(name)
            )
        }
        return (
            root,
            executable,
            input,
            output,
            ColmapModelConversionWorkerInvocationContext(
                mappingAttemptOrdinal: 1,
                projectRootURL: root,
                candidateProjectRelativePath: "SfM/colmap/sparse/0",
                inputProjectRelativePath: stagingRelativePath + "/binary",
                outputProjectRelativePath: stagingRelativePath + "/text",
                inputURL: input,
                outputURL: output
            )
        )
    }

    private func writeConvertedModel(at output: URL) throws {
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            try Data("converted \(name)".utf8).write(
                to: output.appendingPathComponent(name)
            )
        }
    }

    private func writeExecutableFixture(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
    }

    private func poisonCanonicalThreadEnvironment() -> [(key: String, value: String?)] {
        GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys.map { key in
            let previous = RuntimeEnvironment.value(forKey: key)
            RuntimeEnvironment.setValue("inherited-poison", forKey: key)
            return (key, previous)
        }
    }

    private func canonicalThreadEnvironmentOverrides() -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys.map {
                ($0, "explicit-poison")
            }
        )
    }

    private func restoreEnvironment(_ values: [(key: String, value: String?)]) {
        for item in values {
            RuntimeEnvironment.setValue(item.value, forKey: item.key)
        }
    }

    private func environmentValues(in lines: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: lines.compactMap { line in
            let fields = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2 else { return nil }
            return (String(fields[0]), String(fields[1]))
        })
    }
}

private final class WorkerEvidenceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ColmapWorkerInvocationEvidence] = []

    var values: [ColmapWorkerInvocationEvidence] {
        lock.withLock { storedValues }
    }

    func append(_ value: ColmapWorkerInvocationEvidence) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}

private final class LockedLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}

private final class FixedSubprocessResultRunner: @unchecked Sendable, SubprocessRunning {
    private let result: SubprocessResult
    private let onRun: (([String]) throws -> Void)?

    init(
        result: SubprocessResult,
        onRun: (([String]) throws -> Void)? = nil
    ) {
        self.result = result
        self.onRun = onRun
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        try onRun?(arguments)
        return result
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try onRun?(arguments)
        return result
    }
}
#endif
