#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers
import SQLite3

final class PipelineIntegrationTests: XCTestCase {
    private func makePipelineConfig(
        toolchain: ToolchainPaths,
        candidateRoute: SfmBackend? = nil,
        skipTraining: Bool = false,
        stopAfterStage: PipelineStage? = nil,
        hardwareProfile: HardwareProfile? = nil
    ) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: DevelopmentOverrides(
                candidateRoute: candidateRoute,
                stopAfterStage: stopAfterStage,
                skipTraining: skipTraining
            ),
            hardwareProfile: hardwareProfile
        )
    }

    func testDevelopmentStopAfterFeatureExtractionEndsWithoutStartingMatching() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("StopAfterFeatures.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "Stop after features",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            )
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .sfmFeatures
            ),
            tooling: .init(runner: subprocess)
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(subprocess.calls.map { $0.1.first }, ["feature_extractor"])
        let stoppedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(stoppedMetadata.state.stage, .sfmFeatures)
        XCTAssertNil(stoppedMetadata.state.lastError)
        XCTAssertNil(stoppedMetadata.lastRunStartedAt)
        XCTAssertNil(stoppedMetadata.checkpoint)
    }

    func testPipelineSuccessWithGlobalMapper() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<100 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runStartProbe = RunStartMarkerProbe()
        let powerAssertion = RecordingPowerAssertion()

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                let loaded = try? ProjectMetadataStore.load(from: paths.metadataURL)
                runStartProbe.record(observed: loaded?.lastRunStartedAt != nil)
                XCTAssertEqual(powerAssertion.active, 1, "The assertion must still be active while subprocess work is running.")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 100 / 100\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap, skipTraining: true),
            tooling: .init(runner: runner),
            powerAssertion: powerAssertion
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(powerAssertion.begun, 1, "A successful run holds exactly one idle-sleep assertion.")
        XCTAssertEqual(powerAssertion.released, 1, "A successful run must release the idle-sleep assertion.")
        XCTAssertEqual(powerAssertion.active, 0)

        XCTAssertTrue(runStartProbe.wasObserved, "Expected lastRunStartedAt to be set before subprocess work starts.")
        let finalMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(finalMetadata.lastRunStartedAt, "Successful runs should clear lastRunStartedAt.")
        let reconstruction = try XCTUnwrap(finalMetadata.reconstruction, "Successful runs must persist a reconstruction summary.")
        let selectedCount = selectedImageNames(in: paths).count
        XCTAssertEqual(reconstruction.registeredImages, selectedCount)
        XCTAssertEqual(reconstruction.totalImages, selectedCount)
        XCTAssertEqual(
            reconstruction.mapper,
            "global_mapper",
            "The synthetic test toolchain does not advertise GPU support."
        )
        XCTAssertEqual(
            reconstruction.meanReprojectionError,
            0,
            "Persisted reconstruction facts must use residuals recomputed from COLMAP tracks."
        )
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(geometry.residualProvenance, "colmap-text-tracks-v1")
        XCTAssertEqual(geometry.medianPixelResidual, 0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.p90PixelResidual, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(try XCTUnwrap(geometry.timings[PipelineStage.sfmMapping.rawValue]), 0)
        XCTAssertEqual(geometry.schemaVersion, 2)
        XCTAssertEqual(geometry.modelVersion, "none")
        XCTAssertEqual(geometry.provenance.toolchainVersion, "Toolchain")
        XCTAssertEqual(geometry.provenance.solver.identifier, "colmap")
        XCTAssertNil(geometry.provenance.runtime)
        XCTAssertNil(geometry.provenance.model)
        XCTAssertEqual(finalMetadata.geometryArtifact, geometry)
        let selectedManifest = try String(contentsOf: paths.framesSelectedManifestURL, encoding: .utf8)
        XCTAssertFalse(selectedManifest.contains("sourcePath"))
    }

    func testOrderedColmapMatchingAddsVerifiedLoopPairs() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("OrderedLoops.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<30 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }

        let metadata = ProjectMetadata(
            title: "Ordered loops",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["sequential_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let path = self.value(for: "--match_list_path", in: args),
                      let pairs = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return XCTFail("Loop pair list was not readable")
                }
                XCTAssertTrue(pairs.contains("frame_000000.jpg frame_000029.jpg"))
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 30 / 30\nPoints: 1\nObservations: 30\nMean track length: 30.0\n", stderr: ""), onRun: nil),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        try await pipeline.run { _ in }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertTrue(commands.contains("sequential_matcher"))
        XCTAssertTrue(commands.contains("matches_importer"))
        XCTAssertFalse(commands.contains("exhaustive_matcher"))
    }

    func testLargeUnorderedColmapMatchingUsesBoundedRetrievalPairs() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("UnorderedRetrieval.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<120 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }
        let metadata = ProjectMetadata(
            title: "Unordered retrieval",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let path = self.value(for: "--match_list_path", in: args),
                      let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return XCTFail("Retrieval pair list was not readable")
                }
                let pairs = text.split(separator: "\n")
                XCTAssertLessThanOrEqual(pairs.count, 960)
                XCTAssertGreaterThanOrEqual(pairs.count, 119)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 120 / 120\nPoints: 1\nObservations: 120\nMean track length: 120.0\n", stderr: ""), onRun: nil),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        try await pipeline.run { _ in }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertTrue(commands.contains("matches_importer"))
        XCTAssertFalse(commands.contains("exhaustive_matcher"))
    }

    func testDisconnectedThumbnailRetrievalFallsBackToExhaustiveMatching() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("RetrievalFallback.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        var sourceURLs: [URL] = []
        for index in 0..<120 {
            let url = sourcePhotos.appendingPathComponent(String(format: "img_%03d.png", index))
            try writeDisconnectedRetrievalTestImage(url: url, index: index)
            sourceURLs.append(url)
        }
        let descriptors = try ColmapPairEstimator.imageDescriptors(for: sourceURLs)
        XCTAssertThrowsError(try ColmapPairEstimator.boundedRetrievalPairs(
            imageNames: sourceURLs.map(\.lastPathComponent),
            descriptors: descriptors,
            maxNeighbors: 8
        )) { error in
            XCTAssertEqual(error as? ColmapPairPlanningError, .disconnectedGraph)
        }

        let metadata = ProjectMetadata(
            title: "Retrieval fallback",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 120 / 120\nPoints: 1\nObservations: 120\nMean track length: 120.0\n", stderr: ""), onRun: nil),
        ])
        let events = PipelineEventSink()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { events.append($0) }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "feature_extractor" }.count, 2)
        XCTAssertTrue(commands.contains("exhaustive_matcher"))
        XCTAssertFalse(commands.contains("matches_importer"))
        XCTAssertNotNil(events.stageLog(containing: "retrying with fewer frames and exhaustive matching"))
    }

    func testPipelineFailureClearsRunStartMarker() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("TestFail.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "TestFail",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let powerAssertion = RecordingPowerAssertion()
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "feature extraction failed"), onRun: { _ in
                XCTAssertEqual(powerAssertion.active, 1, "The assertion must remain active through a failing subprocess.")
            })
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner),
            powerAssertion: powerAssertion
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { _ in })

        XCTAssertEqual(powerAssertion.begun, 1, "A failed run still holds exactly one idle-sleep assertion.")
        XCTAssertEqual(powerAssertion.released, 1, "A failed run must release the idle-sleep assertion on the throw path.")
        XCTAssertEqual(powerAssertion.active, 0)

        let failedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(failedMetadata.lastRunStartedAt, "Failed runs should clear lastRunStartedAt.")
        XCTAssertNotNil(failedMetadata.state.lastError)
        XCTAssertNotNil(
            failedMetadata.lastFailureAt,
            "PipelineRunner.emitFailure must preserve the real failure time for diagnostics."
        )
    }

    func testPipelineExplicitDa3FailureDoesNotFallbackToOtherBackends() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("StrictDa3.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "StrictDa3",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "da3 native export failed"),
                onRun: nil
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        })

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.0, toolchain.da3.sfmTool.path)
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path }))
    }

    func testPipelineCanTrainWithNativeMsplat() async throws {
        let temp = makeTempRoot()

        let projectURL = temp.appendingPathComponent("Msplat.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Msplat",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        let plySizeProbe = temp.appendingPathComponent("msplat-size-probe.ply")
        try TestFileBuilder.writeMinimalPly(at: plySizeProbe, vertexCount: 1_800)
        let msplatOutputBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: plySizeProbe.path)[.size] as? NSNumber)?.int64Value
        )
        try FileManager.default.removeItem(at: plySizeProbe)
        let inputDigest = String(repeating: "1", count: 64)
        let geometryDigest = String(repeating: "2", count: 64)
        let trainerDigest = String(repeating: "3", count: 64)
        let payloadDigest = String(repeating: "4", count: 64)
        let generation = "00000000-" + String(repeating: "5", count: 64)
        let msplatEvents = """
        {"camera_count":12,"checkpoint_schema":1,"event":"started","geometry_digest":"\(geometryDigest)","initial_gaussian_count":1500,"input_digest":"\(inputDigest)","iteration":0,"iteration_limit":3000,"payload_schema":2,"plateau_window":400,"profile":"fast","resumed":false,"schema_version":1,"seed":42,"sequence":1,"trainer_build_digest":"\(trainerDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(generation)","checkpoint_payload_bytes":128,"checkpoint_payload_sha256":"\(payloadDigest)","event":"checkpoint_completed","gaussian_count":1500,"geometry_digest":"\(geometryDigest)","input_digest":"\(inputDigest)","iteration":0,"peak_memory_bytes":268435456,"profile":"fast","schema_version":1,"seed":42,"sequence":2,"trainer_build_digest":"\(trainerDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":2,"event":"completed","gaussian_count":1800,"geometry_digest":"\(geometryDigest)","input_digest":"\(inputDigest)","iteration":3000,"iteration_limit":3000,"output_bytes":\(msplatOutputBytes),"peak_memory_bytes":536870912,"plateau_window":400,"profile":"fast","schema_version":1,"seed":42,"sequence":3,"stop_reason":"iteration_limit","trainer_build_digest":"\(trainerDigest)","version":"1.1.3 (git 106499b)"}
        """ + "\n"
        var msplatDatasetPath: String?
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["exhaustive_matcher"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["global_mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    try? self.writeSparseModel(at: projectURL)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 12 / 12\nMean reprojection error: 1.0\n",
                    stderr: ""
                ),
                onRun: nil
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                    let out = URL(fileURLWithPath: outputPath, isDirectory: true)
                    FileManager.default.createFile(atPath: out.appendingPathComponent("cameras.bin").path, contents: Data([0x01]))
                    FileManager.default.createFile(atPath: out.appendingPathComponent("images.bin").path, contents: Data([0x01]))
                    FileManager.default.createFile(atPath: out.appendingPathComponent("points3D.bin").path, contents: Data([0x01]))
                }
            ),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: msplatEvents, stderr: ""),
                onRun: { args in
                    guard let datasetArg = args.dropFirst().first,
                          let outputArg = self.value(for: "--output", in: args),
                          let checkpointArg = self.value(for: "--checkpoint", in: args) else { return }
                    msplatDatasetPath = datasetArg
                    let dataset = URL(fileURLWithPath: datasetArg, isDirectory: true)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.appendingPathComponent("sparse/0/cameras.bin").path))
                    XCTAssertTrue(args.contains("fast"))
                    XCTAssertFalse(args.contains("--num-iters"))
                    try? TestFileBuilder.writeMinimalPly(
                        at: URL(fileURLWithPath: outputArg),
                        vertexCount: 1_800
                    )
                    try? FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: checkpointArg, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                }
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap
            ),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.msplat.path }))
        XCTAssertNotNil(msplatDatasetPath)
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let completedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let plan = try XCTUnwrap(completedMetadata.resolvedRunPlan)
        let trainingArtifact = try XCTUnwrap(completedMetadata.trainingArtifact)
        XCTAssertEqual(trainingArtifact.completionStatus, .completed)
        XCTAssertEqual(trainingArtifact.trainerBuildDigest, trainerDigest)
        XCTAssertEqual(trainingArtifact.outputPath, "Output/splat.ply")
        XCTAssertEqual(trainingArtifact.iterationLimit, plan.trainerIterationLimit)
        XCTAssertEqual(trainingArtifact.plateauWindow, plan.plateauWindow)
        XCTAssertEqual(trainingArtifact.deterministicSeed, plan.deterministicSeed)
        XCTAssertEqual(trainingArtifact.peakMemoryBytes, 536_870_912)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.msplatCheckpointURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.msplatOutputURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.trainingURL.appendingPathComponent("msplat_dataset").path
            )
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ),
            completedMetadata.trainingArtifact
        )
    }

    func testCompletedTrainingCleanupRejectsSymlinkedTrainingParent() throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("CleanupSymlink.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        let externalTraining = temp.appendingPathComponent("ExternalTraining", isDirectory: true)
        let externalDataset = externalTraining.appendingPathComponent("msplat_dataset", isDirectory: true)
        let externalOutput = externalTraining.appendingPathComponent("msplat/splat.ply")
        try FileManager.default.createDirectory(at: externalDataset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: externalOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = externalDataset.appendingPathComponent("keep.txt")
        try Data("outside project".utf8).write(to: marker)
        try TestFileBuilder.writeMinimalPly(at: externalOutput)

        try FileManager.default.removeItem(at: paths.trainingURL)
        try FileManager.default.createSymbolicLink(
            at: paths.trainingURL,
            withDestinationURL: externalTraining
        )

        let toolchain = try makeToolchain(root: temp)
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain)
        )

        XCTAssertThrowsError(
            try pipeline.removeDisposableCompletedTrainingPayload(paths: paths)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalOutput.path))
    }

    func testPipelineCancellationRestartsFreshWhenNativeRejectsCheckpoint() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("ResumeMsplat.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }
        var metadata = ProjectMetadata(
            title: "Resume msplat",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1),
                registeredImages: 2,
                totalImages: 2
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try FileManager.default.copyItem(
            at: sourcePhotos,
            to: paths.importedPhotosURL
        )
        var selectedMappings: [TestSelectedFrameMapping] = []
        for index in 0..<2 {
            let name = String(format: "frame_%06d.jpg", index)
            try writeTestImage(
                url: paths.framesSelectedURL.appendingPathComponent(name),
                value: UInt8(index)
            )
            selectedMappings.append(TestSelectedFrameMapping(
                outputFileName: name,
                groupId: "photos",
                isVideo: false
            ))
        }
        try JSONEncoder().encode(selectedMappings).write(
            to: paths.framesSelectedManifestURL,
            options: [.atomic]
        )
        try writeCompletedColmapDatabase(at: paths.colmapDatabaseURL)
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n".write(
            to: sparse.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        320 240 1
        2 1 0 0 0 0 0 0 1 frame_000001.jpg
        320 240 1
        """.write(
            to: sparse.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 1 128 128 128 0.5 1 0 2 0\n".write(
            to: sparse.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data([1]).write(to: sparse.appendingPathComponent(name))
        }
        try persistGeometryArtifactFixture(metadata: &metadata, paths: paths)
        let datasetIdentity = try MsplatDatasetIdentity.compute(
            imageFiles: try FileManager.default.contentsOfDirectory(
                at: paths.framesSelectedURL,
                includingPropertiesForKeys: nil
            ),
            sparseDirectory: sparse
        )
        let receipt = try makeMsplatCheckpointFixture(
            at: paths.msplatCheckpointURL,
            iteration: 500,
            profile: "fast",
            iterationLimit: 3_000,
            plateauWindow: 400,
            inputDigest: datasetIdentity.inputDigest,
            geometryDigest: datasetIdentity.geometryDigest
        )
        let initialGeneration = "00000000-" + String(repeating: "5", count: 64)
        let interruptedEvents = """
        {"camera_count":8,"checkpoint_schema":1,"event":"started","geometry_digest":"\(receipt.geometryDigest)","initial_gaussian_count":750,"input_digest":"\(receipt.inputDigest)","iteration":0,"iteration_limit":3000,"payload_schema":2,"plateau_window":400,"profile":"fast","resumed":false,"schema_version":1,"seed":42,"sequence":1,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(initialGeneration)","checkpoint_payload_bytes":128,"checkpoint_payload_sha256":"\(String(repeating: "4", count: 64))","event":"checkpoint_completed","gaussian_count":750,"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":0,"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"fast","schema_version":1,"seed":42,"sequence":2,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":2,"eta_seconds":20,"event":"progress","gaussian_count":750,"iteration":500,"iteration_limit":3000,"iterations_per_second":250,"schema_version":1,"sequence":3}
        {"checkpoint_generation":"\(receipt.generation)","checkpoint_payload_bytes":\(receipt.payloadBytes),"checkpoint_payload_sha256":"\(receipt.payloadSHA256)","event":"checkpoint_completed","gaussian_count":\(receipt.gaussianCount),"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":\(receipt.iteration),"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"fast","schema_version":1,"seed":42,"sequence":4,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"event":"cancellation_requested","iteration":575,"schema_version":1,"sequence":5,"signal":2}
        {"checkpoint_generation":"\(receipt.generation)","checkpoint_iteration":\(receipt.iteration),"checkpoint_payload_sha256":"\(receipt.payloadSHA256)","event":"cancelled","geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":575,"schema_version":1,"sequence":6}
        """ + "\n"

        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        let firstBacking = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["model_converter"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                FileManager.default.createFile(atPath: output.appendingPathComponent("cameras.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("images.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("points3D.bin").path, contents: Data([1]))
            }),
        ])
        let cancellingRunner = CheckpointCancellingSubprocessRunner(
            backing: firstBacking,
            launchPath: toolchain.msplat.path,
            events: interruptedEvents
        )
        let firstPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: cancellingRunner)
        )

        do {
            try await firstPipeline.run(resumeFrom: .sfmMapping) { _ in }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.completionStatus, .checkpointed)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.completedIteration, 500)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.checkpointDigest, receipt.payloadSHA256)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.peakMemoryBytes, receipt.peakMemoryBytes)

        let outputProbe = temp.appendingPathComponent("resume-output-probe.ply")
        try TestFileBuilder.writeMinimalPly(at: outputProbe, vertexCount: 1_400)
        let outputBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: outputProbe.path)[.size] as? NSNumber)?.int64Value
        )
        try FileManager.default.removeItem(at: outputProbe)
        let freshEvents = """
        {"camera_count":8,"checkpoint_schema":1,"event":"started","geometry_digest":"\(receipt.geometryDigest)","initial_gaussian_count":\(receipt.gaussianCount),"input_digest":"\(receipt.inputDigest)","iteration":0,"iteration_limit":3000,"payload_schema":2,"plateau_window":400,"profile":"fast","resumed":false,"schema_version":1,"seed":42,"sequence":1,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(initialGeneration)","checkpoint_payload_bytes":128,"checkpoint_payload_sha256":"\(String(repeating: "4", count: 64))","event":"checkpoint_completed","gaussian_count":\(receipt.gaussianCount),"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":0,"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"fast","schema_version":1,"seed":42,"sequence":2,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":4,"eta_seconds":0,"event":"progress","gaussian_count":1400,"iteration":3000,"iteration_limit":3000,"iterations_per_second":1600,"schema_version":1,"sequence":3}
        {"elapsed_seconds":4,"event":"completed","gaussian_count":1400,"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":3000,"iteration_limit":3000,"output_bytes":\(outputBytes),"peak_memory_bytes":536870912,"plateau_window":400,"profile":"fast","schema_version":1,"seed":42,"sequence":4,"stop_reason":"iteration_limit","trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        """ + "\n"
        let secondRunner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["model_converter"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                FileManager.default.createFile(atPath: output.appendingPathComponent("cameras.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("images.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("points3D.bin").path, contents: Data([1]))
            }),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(
                    exitCode: 78,
                    terminationReason: .exit,
                    stdout: "{\"event\":\"resume_rejected\",\"reason\":\"geometry_changed\",\"schema_version\":1,\"sequence\":1}\n",
                    stderr: "checkpoint geometry no longer matches"
                ),
                onRun: nil
            ),
            .init(path: toolchain.msplat.path, argsPrefix: ["--dataset"], result: .init(exitCode: 0, terminationReason: .exit, stdout: freshEvents, stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output", in: args) else { return }
                try? TestFileBuilder.writeMinimalPly(
                    at: URL(fileURLWithPath: outputPath),
                    vertexCount: 1_400
                )
            }),
        ])
        let secondPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: secondRunner)
        )

        try await secondPipeline.run(resumeFrom: .sfmMapping) { _ in }

        let trainingCalls = secondRunner.calls.filter { $0.0 == toolchain.msplat.path }
        XCTAssertEqual(trainingCalls.count, 2)
        XCTAssertEqual(value(for: "--resume", in: trainingCalls[0].1), paths.msplatCheckpointURL.path)
        XCTAssertNil(value(for: "--resume", in: trainingCalls[1].1))
        let completedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(completedMetadata.trainingArtifact?.completionStatus, .completed)
        XCTAssertEqual(completedMetadata.trainingArtifact?.completedIteration, 3_000)
        XCTAssertEqual(completedMetadata.trainingArtifact?.peakMemoryBytes, 536_870_912)
        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(
                at: paths.outputURL.appendingPathComponent("splat.ply")
            ),
            .valid
        )
    }

    func testBalancedRetryPinsNativeTrainerFromCheckpointArtifactAfterFailure() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("BalancedRetry.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index * 40)
            )
        }
        try FileManager.default.copyItem(
            at: sourcePhotos,
            to: paths.importedPhotosURL
        )

        let selectedMappings = try (0..<2).map { index in
            let name = String(format: "frame_%06d.jpg", index)
            try writeTestImage(
                url: paths.framesSelectedURL.appendingPathComponent(name),
                value: UInt8(index * 40)
            )
            return TestSelectedFrameMapping(
                outputFileName: name,
                groupId: "photos",
                isVideo: false
            )
        }
        try JSONEncoder().encode(selectedMappings).write(
            to: paths.framesSelectedManifestURL,
            options: [.atomic]
        )
        try writeCompletedColmapDatabase(at: paths.colmapDatabaseURL)
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n".write(
            to: sparse.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        320 240 1
        2 1 0 0 0 0 0 0 1 frame_000001.jpg
        320 240 1
        """.write(
            to: sparse.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 1 128 128 128 0.5 1 0 2 0\n".write(
            to: sparse.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )

        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data([1]).write(to: sparse.appendingPathComponent(name))
        }
        let datasetIdentity = try MsplatDatasetIdentity.compute(
            imageFiles: try FileManager.default.contentsOfDirectory(
                at: paths.framesSelectedURL,
                includingPropertiesForKeys: nil
            ),
            sparseDirectory: sparse
        )

        let receipt = try makeMsplatCheckpointFixture(
            at: paths.msplatCheckpointURL,
            iteration: 500,
            inputDigest: datasetIdentity.inputDigest,
            geometryDigest: datasetIdentity.geometryDigest
        )
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v1",
            trainerBuildDigest: receipt.trainerBuildDigest,
            inputDigest: receipt.inputDigest,
            geometryDigest: receipt.geometryDigest,
            detailProfile: .balanced,
            iterationLimit: 7_000,
            plateauWindow: 800,
            deterministicSeed: 42,
            completedIteration: receipt.iteration,
            checkpointPath: "Training/checkpoints/msplat",
            checkpointDigest: receipt.payloadSHA256,
            outputPath: nil,
            gaussianCount: receipt.gaussianCount,
            elapsedSeconds: nil,
            peakMemoryBytes: receipt.peakMemoryBytes,
            completionStatus: .checkpointed
        )
        var metadata = ProjectMetadata(
            title: "Balanced retry",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            trainingArtifact: artifact,
            state: PipelineState(stage: .sfmMapping, lastError: nil),
            checkpoint: PipelineCheckpoint(
                stage: .trainSplat,
                details: .trainSplat(TrainSplatCheckpoint(
                    progressStep: receipt.iteration,
                    progressTotal: 7_000
                ))
            ),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1),
                registeredImages: 2,
                totalImages: 2
            )
        )
        try persistGeometryArtifactFixture(metadata: &metadata, paths: paths)
        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        let converterScript: () -> MockSubprocessRunner.Script = {
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                    FileManager.default.createFile(atPath: output.appendingPathComponent("cameras.bin").path, contents: Data([1]))
                    FileManager.default.createFile(atPath: output.appendingPathComponent("images.bin").path, contents: Data([1]))
                    FileManager.default.createFile(atPath: output.appendingPathComponent("points3D.bin").path, contents: Data([1]))
                }
            )
        }
        let failedRunner = MockSubprocessRunner(scripts: [
            converterScript(),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "simulated Metal failure"
                ),
                onRun: nil
            ),
        ])
        let failedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain),
            tooling: .init(runner: failedRunner)
        )
        await XCTAssertThrowsErrorAsync {
            try await failedPipeline.run(resumeFrom: .sfmMapping) { _ in }
        }

        let failedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(failedMetadata.state.lastError)
        XCTAssertNil(failedMetadata.checkpoint)
        XCTAssertEqual(failedMetadata.trainingArtifact?.completionStatus, .checkpointed)

        let outputProbe = temp.appendingPathComponent("balanced-retry-output-probe.ply")
        try TestFileBuilder.writeMinimalPly(at: outputProbe, vertexCount: 1_400)
        let outputBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: outputProbe.path)[.size] as? NSNumber)?.int64Value
        )
        try FileManager.default.removeItem(at: outputProbe)
        let resumedEvents = """
        {"camera_count":8,"checkpoint_schema":1,"event":"started","geometry_digest":"\(receipt.geometryDigest)","initial_gaussian_count":\(receipt.gaussianCount),"input_digest":"\(receipt.inputDigest)","iteration":500,"iteration_limit":7000,"payload_schema":2,"plateau_window":800,"profile":"balanced","resumed":true,"schema_version":1,"seed":42,"sequence":1,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(receipt.generation)","checkpoint_payload_bytes":\(receipt.payloadBytes),"checkpoint_payload_sha256":"\(receipt.payloadSHA256)","event":"checkpoint_loaded","gaussian_count":\(receipt.gaussianCount),"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":500,"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"balanced","schema_version":1,"seed":42,"sequence":2,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":4,"eta_seconds":0,"event":"progress","gaussian_count":1400,"iteration":7000,"iteration_limit":7000,"iterations_per_second":1600,"schema_version":1,"sequence":3}
        {"elapsed_seconds":4,"event":"completed","gaussian_count":1400,"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":7000,"iteration_limit":7000,"output_bytes":\(outputBytes),"peak_memory_bytes":805306368,"plateau_window":800,"profile":"balanced","schema_version":1,"seed":42,"sequence":4,"stop_reason":"iteration_limit","trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        """ + "\n"
        let retryRunner = MockSubprocessRunner(scripts: [
            converterScript(),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: resumedEvents, stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output", in: args) else { return }
                    try? TestFileBuilder.writeMinimalPly(
                        at: URL(fileURLWithPath: outputPath),
                        vertexCount: 1_400
                    )
                }
            )
        ])
        let retryPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain),
            tooling: .init(runner: retryRunner)
        )

        try await retryPipeline.run(resumeFrom: .sfmMapping) { _ in }

        let retryCall = try XCTUnwrap(retryRunner.calls.first(where: { $0.0 == toolchain.msplat.path }))
        XCTAssertEqual(value(for: "--resume", in: retryCall.1), paths.msplatCheckpointURL.path)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL)
                .trainingArtifact?.peakMemoryBytes,
            805_306_368
        )
    }

    func testPipelineDa3CancellationDoesNotFallbackBetweenBackends() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3Cancel.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3Cancel",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = CancellationOnSfmRunner(cancelPath: toolchain.da3.sfmTool.path)

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        })

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertEqual(callPaths.filter { $0 == toolchain.da3.sfmTool.path }.count, 1)
        let da3Args = runner.calls.first(where: { $0.0 == toolchain.da3.sfmTool.path })?.1 ?? []
        XCTAssertFalse(da3Args.contains("--mode"))
        XCTAssertFalse(callPaths.contains(toolchain.colmap.path))
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(interruptedMetadata.lastRunStartedAt, "Cancellation should preserve lastRunStartedAt for crash/interruption detection.")
    }

    func testPipelineDefaultsToDa3AndRecordsAcceptedSmallFallback() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                do {
                    try self.writeDa3RunArtifacts(
                        for: args,
                        selectedModelSubdirectory: "DA3-SMALL"
                    )
                } catch {
                    XCTFail("Failed to write DA3 test artifacts: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "0")
                XCTAssertEqual(self.value(for: "--ImageReader.camera_model", in: args), "SIMPLE_RADIAL")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths)
                )
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths)
                )
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                skipTraining: true,
                hardwareProfile: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                )
            ),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertTrue(callPaths.contains(toolchain.da3.sfmTool.path))
        XCTAssertTrue(callPaths.contains(toolchain.colmap.path))
        let da3Args = try XCTUnwrap(runner.calls.first(where: { $0.0 == toolchain.da3.sfmTool.path })?.1)
        XCTAssertFalse(da3Args.contains("--mode"))
        XCTAssertEqual(value(for: "--model-subdir", in: da3Args), "DA3-BASE")
        XCTAssertEqual(value(for: "--fallback-model-subdir", in: da3Args), "DA3-SMALL")
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "model_analyzer" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        let geometry = try XCTUnwrap(finished.geometryArtifact)
        XCTAssertEqual(
            geometry.modelVersion,
            "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(geometry.provenance.runtime?.identifier, "da3_mps")
        XCTAssertEqual(geometry.provenance.model?.identifier, "DA3-SMALL")
        XCTAssertEqual(
            geometry.provenance.model?.payloadSHA256,
            try GeometryArtifactStore.sha256(
                of: toolchain.da3.fallbackModelBundle.appendingPathComponent("model.safetensors")
            )
        )
    }

    func testMeasuredDa3ResidualFailureFallsBackToClassicalSolve() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("ResidualFallback.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "Residual fallback",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let acceptedReport = "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n"
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    do {
                        try self.writeDa3RunArtifacts(for: args)
                    } catch {
                        XCTFail("Failed to prepare DA3 seed artifacts: \(error)")
                    }
                }
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                do {
                    let modelURL = URL(fileURLWithPath: output)
                    try self.writeDa3SparseModel(
                        at: modelURL,
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 4
                    )
                    try self.makeSparseModelHighResidual(at: modelURL)
                } catch {
                    XCTFail("Failed to prepare high-residual triangulated model: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                do {
                    let modelURL = URL(fileURLWithPath: output)
                    try self.writeDa3SparseModel(
                        at: modelURL,
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 4
                    )
                    try self.makeSparseModelHighResidual(at: modelURL)
                } catch {
                    XCTFail("Failed to prepare high-residual adjusted model: \(error)")
                }
            }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: acceptedReport, stderr: ""),
                onRun: nil
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["global_mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let output = self.value(for: "--output_path", in: args) else { return }
                    try? self.writeDa3SparseModel(
                        at: URL(fileURLWithPath: output).appendingPathComponent("0", isDirectory: true),
                        imageNames: ["frame_000000.jpg", "frame_000001.jpg"],
                        pointCount: 4
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: acceptedReport, stderr: ""),
                onRun: nil
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        let events = PipelineEventSink()

        try await pipeline.run { event in
            events.append(event)
        }

        XCTAssertTrue(runner.calls.contains { $0.1.first == "global_mapper" })
        XCTAssertNotNil(events.stageLog(containing: "Falling back to COLMAP"))
        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(finished.reconstruction?.mapper, "global_mapper")
        XCTAssertEqual(finished.geometryArtifact?.fallbackReason, "learned geometry did not pass; used classical compatibility solve")
        XCTAssertEqual(finished.geometryArtifact?.medianPixelResidual, 0)
        XCTAssertEqual(finished.geometryArtifact?.modelVersion, "none")
        XCTAssertNil(finished.geometryArtifact?.provenance.runtime)
        XCTAssertNil(finished.geometryArtifact?.provenance.model)
    }

    func testRejectedDa3SummaryIsNotPersistedWhenClassicalFallbackFails() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("RejectedResidualFallback.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "Rejected residual fallback",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let acceptedReport = "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n"
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    try? self.writeDa3RunArtifacts(for: args)
                }
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                let modelURL = URL(fileURLWithPath: output)
                try? self.writeDa3SparseModel(
                    at: modelURL,
                    imageNames: self.selectedImageNames(in: paths),
                    pointCount: 4
                )
                try? self.makeSparseModelHighResidual(at: modelURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                let modelURL = URL(fileURLWithPath: output)
                try? self.writeDa3SparseModel(
                    at: modelURL,
                    imageNames: self.selectedImageNames(in: paths),
                    pointCount: 4
                )
                try? self.makeSparseModelHighResidual(at: modelURL)
            }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: acceptedReport, stderr: ""),
                onRun: nil
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "global mapper failed"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "mapper failed"), onRun: nil),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        XCTAssertTrue(runner.calls.contains { $0.1.first == "global_mapper" })
        XCTAssertTrue(runner.calls.contains { $0.1.first == "mapper" })
        let failed = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(failed.reconstruction)
        XCTAssertNil(failed.geometryArtifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
    }

    func testPipelineOversizedDa3SeedRunsBoundedRefinementBeforeAcceptance() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3AlignedSeed.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<30 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }

        let metadata = ProjectMetadata(
            title: "Da3AlignedSeed",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeDa3RunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let path = self.value(for: "--match_list_path", in: args),
                      let pairs = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return XCTFail("DA3 refinement pair list was not readable")
                }
                XCTAssertTrue(pairs.contains("frame_000000.jpg frame_000029.jpg"))
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths)
                )
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths)
                )
            }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 30 / 30\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n",
                    stderr: ""
                ),
                onRun: nil
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )
        let events = PipelineEventSink()
        try await pipeline.run { events.append($0) }

        let da3Args = try XCTUnwrap(runner.calls.first(where: { $0.0 == toolchain.da3.sfmTool.path })?.1)
        XCTAssertFalse(da3Args.contains("--mode"))
        XCTAssertEqual(value(for: "--input-ordering", in: da3Args), "continuous")
        let commands = runner.calls.filter { $0.0 == toolchain.colmap.path }.compactMap { $0.1.first }
        XCTAssertEqual(commands, ["feature_extractor", "matches_importer", "point_triangulator", "bundle_adjuster", "model_analyzer"])
        XCTAssertFalse(commands.contains("global_mapper"))
        XCTAssertFalse(commands.contains("mapper"))
        XCTAssertNotNil(events.stageLog(containing: "DA3 refinement pair plan"))

        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(finished.reconstruction?.mapper, "da3-refined")
        XCTAssertEqual(
            finished.reconstruction?.meanReprojectionError,
            0,
            "Persisted reconstruction facts must use residuals recomputed from COLMAP tracks."
        )
    }

    func testPipelineFailsOnLowQuality() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let featureRuns = runner.calls.filter { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }
        XCTAssertEqual(featureRuns.count, 2)
    }

    func testPipelineFailsOnMissingImages() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "no images"), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
    }

    func testPipelineFailsWhenOnlyOneUsableImageRemains() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("OneImage.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img0.jpg"), value: 42)

        let metadata = ProjectMetadata(
            title: "OneImage",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, skipTraining: true),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(saved.state.lastError, "At least two usable photos or video frames are required.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPipelineFailsOnMatcherError() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "match failed"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "exhaustive failed"), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
    }

    private func writeTestImage(url: URL, value: UInt8) throws {
        let size = 32
        var pixels = [UInt8](repeating: value, count: size * size)
        let data = Data(bytes: &pixels, count: pixels.count)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    private func writeRetrievalTestImage(url: URL, index: Int) throws {
        let size = 32
        var pixels = [UInt8](repeating: 96, count: size * size)
        let markerX = (index * 7) % (size - 3)
        let markerY = (index * 11) % (size - 3)
        for y in markerY..<(markerY + 3) {
            for x in markerX..<(markerX + 3) {
                pixels[y * size + x] = UInt8(128 + index % 96)
            }
        }
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeDisconnectedRetrievalTestImage(url: URL, index: Int) throws {
        let size = 32
        let verticalCluster = index < 60
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let high = verticalCluster ? x >= size / 2 : y >= size / 2
                pixels[y * size + x] = high ? 232 : 24
            }
        }
        let marker = (index * 13) % pixels.count
        pixels[marker] = UInt8(80 + index % 120)
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeSparseModel(at projectURL: URL) throws {
        let modelURL = projectURL.appendingPathComponent("SfM/colmap/sparse/0", isDirectory: true)
        try writeSparseModel(
            at: modelURL,
            imageNames: selectedImageNames(in: ProjectPaths(root: projectURL))
        )
    }

    private func writeSparseModelBinaryOnlyForProject(at projectURL: URL) throws {
        let modelURL = projectURL.appendingPathComponent("SfM/colmap/sparse/0", isDirectory: true)
        try writeSparseModelBinaryOnly(at: modelURL)
    }

    private func writeSparseModelBinaryOnly(at modelURL: URL) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let url = modelURL.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        }
    }

    private func writeSparseModel(at modelURL: URL, imageName: String) throws {
        try writeSparseModel(at: modelURL, imageNames: [imageName])
    }

    private func writeSparseModel(at modelURL: URL, imageNames: [String]) throws {
        let safeImageNames = imageNames.isEmpty ? ["frame_000000.jpg"] : imageNames
        try writeDa3SparseModel(
            at: modelURL,
            imageNames: safeImageNames,
            pointCount: 1
        )
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let url = modelURL.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        }
    }

    private func selectedImageNames(in paths: ProjectPaths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: paths.framesSelectedURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func writeProcessedPairCount(into databaseURL: URL, pairCount: Int) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Unable to open sqlite database at \(databaseURL.path)")
            return
        }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS two_view_geometries(pair_id INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to create two_view_geometries table")
            return
        }
        guard sqlite3_exec(db, "DELETE FROM two_view_geometries;", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to clear two_view_geometries table")
            return
        }
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to begin sqlite transaction")
            return
        }
        for index in 0..<max(0, pairCount) {
            let sql = "INSERT INTO two_view_geometries(pair_id) VALUES(\(index + 1));"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                XCTFail("Unable to insert sqlite row \(index + 1)")
                return
            }
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to commit sqlite transaction")
            return
        }
    }

    private func persistGeometryArtifactFixture(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        let modelURL = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let residuals = try ColmapResidualAnalyzer.analyze(modelDirectory: modelURL)
        let imageNames = residuals.registeredImageNames.sorted()
        let modelHashes = try Dictionary(uniqueKeysWithValues: [
            "cameras.txt",
            "images.txt",
            "points3D.txt",
        ].map { name in
            (name, try GeometryArtifactStore.sha256(of: modelURL.appendingPathComponent(name)))
        })
        let artifact = GeometryArtifact(
            schemaVersion: GeometryArtifact.currentSchemaVersion,
            solverVersion: "colmap-test-fixture",
            runtimeVersion: "toolchain-test-fixture",
            modelVersion: "none",
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            orderedImageNames: imageNames,
            orderedImageTimestamps: Array(repeating: nil, count: imageNames.count),
            canonicalModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: "SIMPLE_PINHOLE",
            cameraGrouping: .automatic,
            registeredViewCount: residuals.registeredViewCount,
            totalViewCount: imageNames.count,
            trackCount: residuals.observationCount,
            pointCount: residuals.pointCount,
            residualProvenance: residuals.provenance,
            medianPixelResidual: residuals.medianPixelResidual,
            p90PixelResidual: residuals.p90PixelResidual,
            timings: [PipelineStage.sfmMapping.rawValue: 1],
            peakMemoryBytes: 1,
            modelHashes: modelHashes,
            fallbackReason: nil,
            provenance: GeometryProvenance(
                toolchainVersion: "test-toolchain",
                solver: GeometryComponentProvenance(
                    identifier: "colmap",
                    version: "test",
                    revision: "test",
                    payloadSHA256: String(repeating: "a", count: 64)
                ),
                runtime: nil,
                model: nil
            )
        )
        try GeometryArtifactStore.persist(
            artifact,
            metadata: &metadata,
            paths: paths,
            measuredResiduals: residuals
        )
    }

    private func writeCompletedColmapDatabase(at databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(
                domain: "PipelineIntegrationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open sqlite database at \(databaseURL.path)"]
            )
        }

        let sql = """
        CREATE TABLE images(image_id INTEGER PRIMARY KEY);
        CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER);
        CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY);
        INSERT INTO images(image_id) VALUES (1), (2);
        INSERT INTO keypoints(image_id, rows) VALUES (1, 1), (2, 1);
        INSERT INTO two_view_geometries(pair_id) VALUES (1);
        """
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "sqlite error \(sqlite3_errcode(db))"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "PipelineIntegrationTests",
                code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func writeDa3RunArtifacts(
        for args: [String],
        imageName: String = "frame_000000.jpg",
        selectedModelSubdirectory: String? = nil
    ) throws {
        guard let manifestPath = value(for: "--manifest-out", in: args),
              let imagesPath = value(for: "--images", in: args),
              let out = value(for: "--out-sparse", in: args) else {
            return
        }

        let imagesURL = URL(fileURLWithPath: imagesPath, isDirectory: true)
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: nil
        )
        .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        .map(\.lastPathComponent)
        .sorted()

        let totalImages = imageNames.count
        let requestedWindowSize = Int(value(for: "--window-size", in: args) ?? "") ?? max(2, totalImages)
        let requestedWindowOverlap = Int(value(for: "--window-overlap", in: args) ?? "") ?? 0
        let effectiveWindowSize = max(2, min(totalImages, requestedWindowSize))
        let effectiveWindowOverlap = max(0, min(requestedWindowOverlap, effectiveWindowSize - 1))
        let inputOrdering = value(for: "--input-ordering", in: args) ?? "automatic"
        let windowIndices: [[Int]]
        if inputOrdering == "unordered", totalImages > effectiveWindowSize {
            let anchors = [0, 1, 2]
            windowIndices = [Array(0..<effectiveWindowSize)] + stride(
                from: effectiveWindowSize,
                to: totalImages,
                by: max(1, effectiveWindowSize - anchors.count)
            ).map { start in anchors + Array(start..<min(totalImages, start + effectiveWindowSize - anchors.count)) }
        } else {
            windowIndices = planWindows(
                imageCount: totalImages,
                windowSize: effectiveWindowSize,
                windowOverlap: effectiveWindowOverlap
            ).map { Array($0.0..<$0.1) }
        }

        try writeDa3PoseSeed(
            at: URL(fileURLWithPath: out),
            imageNames: imageNames.isEmpty ? [imageName] : imageNames
        )

        let manifest = Da3CoverageManifest(
            mode: "seed_refine",
            requestedDevice: value(for: "--device", in: args) ?? "mps",
            selectedDevice: "mps",
            modelSubdirectory: selectedModelSubdirectory
                ?? value(for: "--model-subdir", in: args)
                ?? "DA3-BASE",
            fallbackModelSubdirectory: value(for: "--fallback-model-subdir", in: args),
            processResolution: Int(value(for: "--process-res", in: args) ?? "") ?? 504,
            cameraType: value(for: "--camera-type", in: args) ?? "PINHOLE",
            sharedCamera: args.contains("--shared-camera"),
            maxPoints: Int(value(for: "--max-points", in: args) ?? "") ?? 120_000,
            totalImages: totalImages,
            windowSize: effectiveWindowSize,
            windowOverlap: effectiveWindowOverlap,
            windows: windowIndices.map { indices in
                Da3CoverageManifest.Window(
                    start: indices.min() ?? 0,
                    end: (indices.max() ?? -1) + 1,
                    images: indices.map { imageNames[$0] },
                    indices: indices
                )
            },
            rawPointSampleCount: 8,
            fusedSparsePointCount: 4,
            finalObservationCount: nil,
            meanTrackLength: nil,
            registeredImageCount: totalImages,
            nativeColmapExport: false,
            exportStrategy: "aligned_pose_depth_seed",
            inputOrdering: inputOrdering == "automatic" ? "unordered" : inputOrdering,
            anchorImageNames: Array(imageNames.prefix(3)),
            alignmentEdgeCount: max(0, windowIndices.count - 1),
            maxAlignmentRMSE: 0.01,
            alignmentComplete: true
        )

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
    }

    private func writeDa3PoseSeed(at modelURL: URL, imageNames: [String]) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
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
    }

    private func makeSparseModelHighResidual(at modelURL: URL) throws {
        let imagesURL = modelURL.appendingPathComponent("images.txt")
        let text = try String(contentsOf: imagesURL, encoding: .utf8)
            .replacingOccurrences(of: "320 240 ", with: "400 240 ")
        try text.write(to: imagesURL, atomically: true, encoding: .utf8)
    }

    private func writeDa3SparseModel(at modelURL: URL, imageNames: [String], pointCount: Int) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        var imagesText = "# Image list with two lines per image:\n"
        for (offset, imageName) in imageNames.enumerated() {
            let imageID = offset + 1
            imagesText += "\(imageID) 1 0 0 0 0 0 0 1 \(imageName)\n"
            let observations = (1...pointCount)
                .map { pointID in "320 240 \(pointID)" }
                .joined(separator: " ")
            imagesText += observations + "\n"
        }
        try imagesText.write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        let points = (1...pointCount)
            .map { pointID in
                let point2DIndex = pointID - 1
                let track = imageNames.enumerated()
                    .map { offset, _ in "\(offset + 1) \(point2DIndex)" }
                    .joined(separator: " ")
                return "\(pointID) 0 0 1 128 128 128 1.0 \(track)"
            }
            .joined(separator: "\n")
        try (points + "\n").write(to: modelURL.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
    }

    private func planWindows(imageCount: Int, windowSize: Int, windowOverlap: Int) -> [(Int, Int)] {
        guard imageCount > 0 else { return [] }
        let size = max(2, min(windowSize, imageCount))
        let overlap = max(0, min(windowOverlap, size - 1))
        let stride = max(1, size - overlap)
        if imageCount <= size {
            return [(0, imageCount)]
        }

        var windows: [(Int, Int)] = []
        var start = 0
        while start < imageCount {
            let end = min(start + size, imageCount)
            if windows.last?.1 == end {
                break
            }
            windows.append((start, end))
            if end == imageCount {
                break
            }
            start += stride
        }
        return windows
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func makeToolchain(
        root: URL,
        createDa3Files: Bool = false,
        createMsplatFile: Bool = false
    ) throws -> ToolchainPaths {
        let fm = FileManager.default
        let toolchainRoot = root.appendingPathComponent("Toolchain", isDirectory: true)
        let bin = toolchainRoot.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        func writeStub(_ name: String) throws -> URL {
            let url = bin.appendingPathComponent(name)
            let stub = [
                "#!/usr/bin/env bash",
                "exit 0",
                ""
            ].joined(separator: "\n")
            try stub.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        let colmap = try writeStub("colmap")
        let colmapProvenance = toolchainRoot.appendingPathComponent("provenance/colmap.json")
        try fm.createDirectory(
            at: colmapProvenance.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let colmapExecutableSHA256 = try GeometryArtifactStore.sha256(of: colmap)
        try """
        {
          "toolchain_name": "colmap",
          "source_version": "3.13.0",
          "source_commit": "fa7280fee27f97aff31ae7f98bab7f583fac7d08",
          "executable_sha256": "\(colmapExecutableSHA256)"
        }
        """.write(to: colmapProvenance, atomically: true, encoding: .utf8)
        let msplat = createMsplatFile ? try writeStub("easysplat-train") : bin.appendingPathComponent("easysplat-train")

        let da3 = try TestToolchains.da3Toolchain(root: toolchainRoot, createFiles: createDa3Files)
        return ToolchainPaths(
            root: toolchainRoot,
            colmap: colmap,
            msplat: msplat,
            da3: da3
        )
    }

    private func makeTempRoot() -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        return temp
    }
}

private final class RunStartMarkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    var wasObserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func record(observed value: Bool) {
        guard value else { return }
        lock.lock()
        observed = true
        lock.unlock()
    }
}

private final class CancellationOnSfmRunner: @unchecked Sendable, SubprocessRunning {
    private let cancelPath: String
    private let lock = NSLock()
    private var recordedCalls: [(String, [String])] = []

    init(cancelPath: String) {
        self.cancelPath = cancelPath
    }

    var calls: [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        try execute(launchPath, arguments)
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try execute(launchPath, arguments)
    }

    private func execute(_ launchPath: String, _ arguments: [String]) throws -> SubprocessResult {
        lock.lock()
        recordedCalls.append((launchPath, arguments))
        lock.unlock()

        if launchPath == cancelPath && arguments.starts(with: ["--images"]) {
            throw CancellationError()
        }

        return SubprocessResult(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
    }
}

private final class PipelineEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []

    func append(_ event: PipelineEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func stageLog(containing fragment: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event -> String? in
            guard case let .stageLog(_, line, _) = event, line.contains(fragment) else { return nil }
            return line
        }.first
    }
}

#endif
