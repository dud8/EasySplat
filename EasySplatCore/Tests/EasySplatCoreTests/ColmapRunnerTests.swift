#if canImport(XCTest)
import Foundation
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
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runFeatureExtractor(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            maxImageSize: 1024,
            cameraModel: "SIMPLE_RADIAL",
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
            cameraModel: "SIMPLE_PINHOLE",
            singleCamera: false,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 2,
                matchThreads: 1
            ),
            onLog: { _, _ in }
        )
    }

    func testMatchesImporterUsesFaissByDefault() async throws {
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
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatchesImporter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
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

    func testMatchesImporterReportsBoundedWorkerEvidenceFromProcessReceipt() async throws {
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
            database: URL(fileURLWithPath: "/tmp/db"),
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
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
        XCTAssertEqual(invocation.exitStatus, 0)
        XCTAssertTrue(invocation.succeeded)
    }

    func testWorkerObserverRejectsMissingOrMismatchedProcessReceipt() async throws {
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
                    database: URL(fileURLWithPath: "/tmp/db"),
                    matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
                    matchType: "pairs",
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
            database: root.appendingPathComponent("database.db"),
            matchListPath: root.appendingPathComponent("pairs.txt"),
            matchType: "pairs",
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
        XCTAssertTrue(invocation.explicitThreadEnvironment.isEmpty)
        XCTAssertTrue(invocation.effectiveSanitizedThreadEnvironment.isEmpty)
    }

    func testRealCancelledChildRecordsTerminationEvidenceExactlyOnce() async throws {
        let previousEnvironment = poisonCanonicalThreadEnvironment()
        defer { restoreEnvironment(previousEnvironment) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
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
                database: root.appendingPathComponent("database.db"),
                matchListPath: root.appendingPathComponent("pairs.txt"),
                matchType: "pairs",
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
                database: root.appendingPathComponent("database.db"),
                matchListPath: root.appendingPathComponent("pairs.txt"),
                matchType: "pairs",
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
                database: URL(fileURLWithPath: "/tmp/database.db"),
                matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
                matchType: "pairs",
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
                    XCTAssertEqual(self.value(for: "--num_images", in: args), "40")
                    XCTAssertEqual(self.value(for: "--returned_neighbor_count", in: args), "16")
                    XCTAssertEqual(self.value(for: "--minimum_frame_separation", in: args), "25")
                    XCTAssertEqual(self.value(for: "--num_visual_words", in: args), "512")
                    XCTAssertEqual(self.value(for: "--max_features_per_image", in: args), "512")
                    XCTAssertEqual(self.value(for: "--max_training_descriptors", in: args), "65536")
                    XCTAssertEqual(self.value(for: "--num_iterations", in: args), "10")
                    XCTAssertEqual(self.value(for: "--num_rounds", in: args), "1")
                    XCTAssertEqual(self.value(for: "--num_checks", in: args), "64")
                    XCTAssertEqual(self.value(for: "--num_threads", in: args), "6")
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
                threadCount: 6
            ),
            onLog: { _, _ in }
        )

        XCTAssertEqual(runner.environments.first?["OMP_NUM_THREADS"], "6")
        XCTAssertTrue(try XCTUnwrap(runner.removedEnvironmentKeys.first).contains("OMP_THREAD_LIMIT"))
    }

    func testLocalVocabularyRetrieverRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 8,
            returnedNeighborCount: 9,
            minimumFrameSeparation: 0,
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
            threadCount: 1
        ))
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            threadCount: 0
        ))
    }

    func testExactRecoveryUsesBruteForceMatching() async throws {
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
            database: URL(fileURLWithPath: "/tmp/db"),
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
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
            environment: [:],
            recordGeometryWorkerExecution: true,
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
        XCTAssertEqual(runner.environments, [[:]])
        XCTAssertEqual(
            runner.removedEnvironmentKeys,
            [Set(GeometryWorkerExecutionArtifact.canonicalRemovedThreadEnvironmentKeys)]
        )
    }

    func testModelConverterReportsFailedInvocationBeforeThrowing() throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
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
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            environment: [:],
            recordGeometryWorkerExecution: true,
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
    }

    func testModelConverterFailsClosedWhenProcessReceiptIsUnavailable() throws {
        let runner = FixedSubprocessResultRunner(result: .init(
            exitCode: 0,
            terminationReason: .exit,
            stdout: "",
            stderr: "",
            environmentReceipt: nil
        ))
        let evidence = WorkerEvidenceSink()
        let colmap = ColmapRunner(runner: runner)
        colmap.setWorkerExecutionObserver { invocation in
            evidence.append(invocation)
        }

        XCTAssertThrowsError(try colmap.runModelConverter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            environment: [:],
            recordGeometryWorkerExecution: true,
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

    init(result: SubprocessResult) {
        self.result = result
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
        result
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
        result
    }
}
#endif
