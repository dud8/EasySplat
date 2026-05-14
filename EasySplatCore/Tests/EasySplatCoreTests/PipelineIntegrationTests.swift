#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers
import SQLite3

final class PipelineIntegrationTests: XCTestCase {
    private static let clearedTrainingEnvironment: [String: String?] = [
            "EASYSPLAT_TRAINER": nil,
            "EASYSPLAT_MSPLAT_BIN": nil,
            "EASYSPLAT_MSPLAT_ITERS": nil,
            "EASYSPLAT_MSPLAT_NUM_DOWNSCALES": nil,
            "EASYSPLAT_MSPLAT_DOWNSCALE_FACTOR": nil
    ]

    private func scopedPipelineEnvironment(_ changes: [String: String?]) async -> @Sendable () -> Void {
        var merged = Self.clearedTrainingEnvironment
        for (key, value) in changes {
            merged[key] = value
        }
        return await scopedEnvironment(merged)
    }

    func testPipelineSuccessWithGlobalMapper() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<100 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runStartProbe = RunStartMarkerProbe()

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                let loaded = try? ProjectMetadataStore.load(from: paths.metadataURL)
                runStartProbe.record(observed: loaded?.lastRunStartedAt != nil)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 100 / 100\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(runStartProbe.wasObserved, "Expected lastRunStartedAt to be set before subprocess work starts.")
        let finalMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(finalMetadata.lastRunStartedAt, "Successful runs should clear lastRunStartedAt.")
    }

    func testPipelineFailureClearsRunStartMarker() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

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
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "feature extraction failed"), onRun: nil)
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { _ in })

        let failedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(failedMetadata.lastRunStartedAt, "Failed runs should clear lastRunStartedAt.")
        XCTAssertNotNil(failedMetadata.state.lastError)
    }

    func testTrainingGateInvokedBeforeTraining() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let gateFlag = TrainingGateFlag()

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(
                toolchain: toolchain,
                preset: metadata.preset,
                trainingGate: {
                    await gateFlag.setCalled()
                    throw CancellationError()
                }
            ),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { _ in }
            XCTFail("Expected training gate cancellation")
        } catch is CancellationError {
            // expected
        }

        let wasCalled = await gateFlag.wasCalled()
        XCTAssertTrue(wasCalled)
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.brush.path }))
    }

    func testPipelineSuccessWithVggt() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "vggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<20 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.vggt.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineMapAnythingDirectSuccessSkipsExternalRefinement() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "mapanything",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapAnythingDirect.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<4 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "MapAnythingDirect",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 4 / 4\nMean reprojection error: 0.7\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.mapanything.sfmTool.path }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineMapAnythingSeedRefineRunsTriangulatorAndBA() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "mapanything",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapAnythingSeed.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "MapAnythingSeed",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 12 / 12\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.mapanything.sfmTool.path }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "bundle_adjuster" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineMapAnythingDirectLowQualityFallsBackToSeedRefine() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "mapanything",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapAnythingDirectFallback.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<4 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "MapAnythingDirectFallback",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 4\nMean reprojection error: 3.2\n", stderr: ""), onRun: nil),
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 4 / 4\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let mapAnythingCalls = runner.calls.filter { $0.0 == toolchain.mapanything.sfmTool.path }
        XCTAssertEqual(mapAnythingCalls.count, 2)
        XCTAssertTrue(mapAnythingCalls[0].1.contains("direct"))
        XCTAssertTrue(mapAnythingCalls[1].1.contains("seed_refine"))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineMapAnythingDirectThinTracksFallsBackToSeedRefine() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "mapanything",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapAnythingThinTracks.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<4 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "MapAnythingThinTracks",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 4 / 4\nPoints: 10000\nObservations: 10100\nMean track length: 1.01\nMean reprojection error: 0.9\n", stderr: ""), onRun: nil),
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 4 / 4\nPoints: 16000\nObservations: 42000\nMean track length: 2.63\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let mapAnythingCalls = runner.calls.filter { $0.0 == toolchain.mapanything.sfmTool.path }
        XCTAssertEqual(mapAnythingCalls.count, 2)
        XCTAssertTrue(mapAnythingCalls[0].1.contains("direct"))
        XCTAssertTrue(mapAnythingCalls[1].1.contains("seed_refine"))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
    }

    func testPipelineMapAnythingInvalidCoverageManifestFallsBackToSeedRefine() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "mapanything",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapAnythingInvalidManifest.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<4 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "MapAnythingInvalidManifest",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args, manifestModeOverride: "seed_refine")
            }),
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 4 / 4\nPoints: 15000\nObservations: 32000\nMean track length: 2.13\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let mapAnythingCalls = runner.calls.filter { $0.0 == toolchain.mapanything.sfmTool.path }
        XCTAssertEqual(mapAnythingCalls.count, 2)
        XCTAssertTrue(mapAnythingCalls[0].1.contains("direct"))
        XCTAssertTrue(mapAnythingCalls[1].1.contains("seed_refine"))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
    }

    func testPipelineDa3AndMapAnythingFailureFallsBackToColmapDefaultPath() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapAnythingToColmap.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3MapAnythingToColmap",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "da3 failed"),
                onRun: nil
            ),
            .init(
                path: toolchain.mapanything.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "mapanything failed"),
                onRun: nil
            ),
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
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""),
                onRun: nil
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.da3.sfmTool.path }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.mapanything.sfmTool.path }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineExplicitDa3FailureDoesNotFallbackToOtherBackends() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "da3",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

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
            preset: PresetSpec(mode: .object, quality: .draft)
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
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        })

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.0, toolchain.da3.sfmTool.path)
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.mapanything.sfmTool.path }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path }))
    }

    func testPipelineConvertsBinaryOnlySparseModelBeforeTraining() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_TRAINER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("BinarySparse.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "BinarySparse",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
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
                    try? self.writeSparseModelBinaryOnlyForProject(at: projectURL)
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
                    let images = """
                    # Image list with two lines per image:
                    1 1 0 0 0 0 0 0 1 frame_000000.jpg

                    """
                    try? images.write(to: out.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
                    try? "1 SIMPLE_RADIAL 32 32 10 16 16\n".write(
                        to: out.appendingPathComponent("cameras.txt"),
                        atomically: true,
                        encoding: .utf8
                    )
                    try? "# empty\n".write(
                        to: out.appendingPathComponent("points3D.txt"),
                        atomically: true,
                        encoding: .utf8
                    )
                }
            ),
            .init(
                path: toolchain.brush.path,
                argsPrefix: [],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let datasetArg = args.last else { return }
                    let dataset = URL(fileURLWithPath: datasetArg)
                    let training = dataset.deletingLastPathComponent()
                    let ply = training.appendingPathComponent("export_00001.ply")
                    try? TestFileBuilder.writeMinimalPly(at: ply)
                }
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { _, args in args.first == "model_converter" }))
        let convertedImages = projectURL.appendingPathComponent("Training/dataset/sparse/0/images.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: convertedImages.path))
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineCanTrainWithMsplatOverride() async throws {
        let temp = makeTempRoot()
        let externalMsplat = temp.appendingPathComponent("External/msplat-train")
        try TestFileBuilder.createExecutable(at: externalMsplat)

        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_TRAINER": "msplat",
            "EASYSPLAT_MSPLAT_BIN": externalMsplat.path,
            "EASYSPLAT_SKIP_TRAINING": nil,
            "EASYSPLAT_MSPLAT_ITERS": "1200"
        ])
        defer { restore() }

        let projectURL = temp.appendingPathComponent("Msplat.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Msplat",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
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
                path: externalMsplat.path,
                argsPrefix: ["--input"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let datasetArg = args.dropFirst().first,
                          let outputArg = self.value(for: "--output", in: args) else { return }
                    msplatDatasetPath = datasetArg
                    let dataset = URL(fileURLWithPath: datasetArg, isDirectory: true)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.appendingPathComponent("sparse/0/cameras.bin").path))
                    XCTAssertTrue(args.contains("1200"))
                    try? TestFileBuilder.writeMinimalPly(at: URL(fileURLWithPath: outputArg))
                }
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(
                toolchain: toolchain,
                preset: metadata.preset
            ),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.brush.path }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == externalMsplat.path }))
        XCTAssertNotNil(msplatDatasetPath)
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineCancellationDoesNotFallbackBetweenBackends() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "fastvggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)
        let runner = CancellationOnSfmRunner(cancelPath: toolchain.fastvggt.sfmTool.path)

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        })

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertEqual(callPaths.filter { $0 == toolchain.fastvggt.sfmTool.path }.count, 1)
        XCTAssertFalse(callPaths.contains(toolchain.vggt.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.colmap.path))
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(interruptedMetadata.lastRunStartedAt, "Cancellation should preserve lastRunStartedAt for crash/interruption detection.")
    }

    func testPipelineDa3CancellationDoesNotFallbackBetweenBackends() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3Cancel.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3Cancel",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true, createVggtFiles: true)
        let runner = CancellationOnSfmRunner(cancelPath: toolchain.da3.sfmTool.path)

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        })

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertEqual(callPaths.filter { $0 == toolchain.da3.sfmTool.path }.count, 1)
        XCTAssertFalse(callPaths.contains(toolchain.mapanything.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.colmap.path))
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(interruptedMetadata.lastRunStartedAt, "Cancellation should preserve lastRunStartedAt for crash/interruption detection.")
    }

    func testPipelineMapAnythingDirectCancellationDoesNotStartSeedRefine() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "mapanything",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MapCancel.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "MapCancel",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createMapAnythingFiles: true, createVggtFiles: true)
        let runner = CancellationOnSfmRunner(cancelPath: toolchain.mapanything.sfmTool.path)

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        })

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertEqual(callPaths.filter { $0 == toolchain.mapanything.sfmTool.path }.count, 1)
        XCTAssertFalse(callPaths.contains(toolchain.colmap.path))
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(interruptedMetadata.lastRunStartedAt, "Cancellation should preserve lastRunStartedAt for crash/interruption detection.")
    }

    func testPipelineDefaultsToDa3WhenBackendUnset() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                do {
                    try self.writeDa3RunArtifacts(for: args)
                } catch {
                    XCTFail("Failed to write DA3 test artifacts: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertTrue(callPaths.contains(toolchain.da3.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.mapanything.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.fastvggt.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.vggt.sfmTool.path))
        XCTAssertTrue(callPaths.contains(toolchain.colmap.path))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "model_analyzer" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineDefaultDa3ProducesFinalPly() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3Ply.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3Ply",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                do {
                    try self.writeDa3RunArtifacts(for: args)
                } catch {
                    XCTFail("Failed to write DA3 test artifacts: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let finalMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(finalMetadata.outputs?.splatPlyPath, "Output/splat.ply")
        XCTAssertEqual(finalMetadata.outputs?.colmapModelPath, "SfM/colmap/sparse/0")
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.mapanything.sfmTool.path }))
    }

    func testPipelineRejectsSymlinkedOutputDirectoryOnExport() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3SymlinkOutput.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3SymlinkOutput",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let externalOutput = temp.appendingPathComponent("ExternalOutput", isDirectory: true)
        try FileManager.default.createDirectory(at: externalOutput, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: paths.outputURL)
        try FileManager.default.createSymbolicLink(at: paths.outputURL, withDestinationURL: externalOutput)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeDa3RunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                try? TestFileBuilder.writeMinimalPly(at: training.appendingPathComponent("export_00001.ply"))
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            guard case ProjectPathError.escapesProjectRoot = error else {
                return XCTFail("Expected project root escape, got \(error)")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalOutput.appendingPathComponent("splat.ply").path))
    }

    func testPipelineLowQualityDa3FallsBackToMapAnything() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_DA3_WINDOW_SIZE": "500",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3ThinTracks.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3ThinTracks",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeDa3RunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nPoints: 10000\nObservations: 10100\nMean track length: 1.01\nMean reprojection error: 0.9\n", stderr: ""), onRun: nil),
            .init(path: toolchain.mapanything.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeMapAnythingRunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nPoints: 16000\nObservations: 42000\nMean track length: 2.63\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(runner.calls.filter { $0.0 == toolchain.da3.sfmTool.path }.count, 1)
        XCTAssertEqual(runner.calls.filter { $0.0 == toolchain.mapanything.sfmTool.path }.count, 1)
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineFastVggtRefinementFallsBackToMapperPath() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "fastvggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": "0",
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": "0",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.fastvggt.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--out-sparse", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "triangulator failed"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertTrue(callPaths.contains(toolchain.fastvggt.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.vggt.sfmTool.path))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertTrue(callPaths.contains(toolchain.colmap.path))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineIgnoresDeprecatedGraceFallbackEnv() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_ENABLE_VGGT_GRACE_FALLBACK": "1",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeDa3RunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertTrue(callPaths.contains(toolchain.da3.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.mapanything.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.fastvggt.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.vggt.sfmTool.path))
        XCTAssertTrue(callPaths.contains(toolchain.colmap.path))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "model_analyzer" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
    }

    func testPipelineFastVggtRefinementSuccessRunsTriangulatorAndBA() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "fastvggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": "0",
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": "0",
            "EASYSPLAT_VGGT_CAMERA_TYPE": "PINHOLE",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.fastvggt.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--out-sparse", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "bundle_adjuster" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "mapper" }))
        let featureExtractorArgs = runner.calls.first(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" })?.1
        XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: featureExtractorArgs ?? []), "0")
        XCTAssertEqual(self.value(for: "--ImageReader.camera_model", in: featureExtractorArgs ?? []), "PINHOLE")
    }

    func testPipelineFastVggtMatchingEmitsPairProgressHeartbeat() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "fastvggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": "0",
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": "0",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.fastvggt.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--out-sparse", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let dbPath = self.value(for: "--database_path", in: args) else { return }
                try? self.writeProcessedPairCount(into: URL(fileURLWithPath: dbPath), pairCount: 24)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                Thread.sleep(forTimeInterval: 0.3)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--output_path", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
        ])

        final class LockedEvents: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [PipelineEvent] = []

            func append(_ event: PipelineEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            func snapshot() -> [PipelineEvent] {
                lock.lock()
                let copy = events
                lock.unlock()
                return copy
            }
        }

        let sink = LockedEvents()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { event in
            sink.append(event)
        }

        let matchingProgress = sink.snapshot().compactMap { event -> (Double, String)? in
            guard case let .stageProgress(stage, fraction, message) = event,
                  stage == .sfmMatching else {
                return nil
            }
            return (fraction, message)
        }

        XCTAssertTrue(matchingProgress.contains(where: { $0.1.contains("Matching views: extracting local features") }))
        XCTAssertTrue(matchingProgress.contains(where: { $0.1.contains("pairs ") }))
        XCTAssertGreaterThan(matchingProgress.map(\.0).max() ?? 0, 0.30)
    }

    func testPipelineFastVggtStrictCoverageSkipsExternalMatcherAndMapper() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "fastvggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": "1",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.fastvggt.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--out-sparse", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
                if let manifest = self.value(for: "--coverage-manifest", in: args) {
                    try? Data("{\"ok\":true}".utf8).write(to: URL(fileURLWithPath: manifest))
                }
            })
        ])

        final class LockedEvents: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [PipelineEvent] = []

            func append(_ event: PipelineEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            func snapshot() -> [PipelineEvent] {
                lock.lock()
                let copy = events
                lock.unlock()
                return copy
            }
        }

        let sink = LockedEvents()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { event in
            sink.append(event)
        }

        let allCalls = runner.calls
        XCTAssertEqual(allCalls.filter { $0.0 == toolchain.fastvggt.sfmTool.path }.count, 1)
        let fastArgs = allCalls.first(where: { $0.0 == toolchain.fastvggt.sfmTool.path })?.1 ?? []
        XCTAssertTrue(fastArgs.contains("--gpu-only"))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "exhaustive_matcher" }))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "sequential_matcher" }))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "bundle_adjuster" }))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }))
        XCTAssertFalse(allCalls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "mapper" }))

        let logs = sink.snapshot().compactMap { event -> String? in
            guard case let .stageLog(_, line, _) = event else { return nil }
            return line
        }
        XCTAssertTrue(logs.contains(where: { $0.contains("skipping COLMAP matching stage") }))
        XCTAssertTrue(logs.contains(where: { $0.contains("skipping external mapping/refinement fallback") }))
    }

    func testPipelineFastVggtAllowsSeedFallbackWhenRefinementNotRequired() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "fastvggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_FASTVGGT_REQUIRE_REFINED_MODEL": "0",
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.fastvggt.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let out = self.value(for: "--out-sparse", in: args) else { return }
                try? self.writeSparseModel(at: URL(fileURLWithPath: out), imageName: "frame_000000.jpg")
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "triangulator failed"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "global_mapper failed"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "colmap failed"), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let finalModel = projectURL.appendingPathComponent("SfM/colmap/sparse/0/images.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalModel.path))
        let callPaths = runner.calls.map { $0.0 }
        XCTAssertTrue(callPaths.contains(toolchain.fastvggt.sfmTool.path))
        XCTAssertFalse(callPaths.contains(toolchain.vggt.sfmTool.path))
    }


    func testPipelineVggtEmitsProgressWhileRunning() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "vggt",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<20 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createVggtFiles: true)

        final class SlowVggt: @unchecked Sendable, VggtSfmRunning {
            private let delayNanoseconds: UInt64

            init(delayNanoseconds: UInt64) {
                self.delayNanoseconds = delayNanoseconds
            }

            func run(
                toolchain: VggtToolchain,
                images: URL,
                outSparse: URL,
                config: VggtSfmConfig,
                onLog: @escaping @Sendable (String, Bool) -> Void
            ) async throws {
                onLog("VGGT: loading model weights...", false)
                try await Task.sleep(nanoseconds: delayNanoseconds)
                onLog("VGGT: chunking enabled (chunk=6, overlap=2, stride=4).", false)

                for chunk in [
                    "VGGT: chunk 1/4 images[0:6]",
                    "VGGT: chunk 2/4 images[4:10]",
                    "VGGT: chunk 3/4 images[8:14]",
                    "VGGT: chunk 4/4 images[12:20]"
                ] {
                    onLog(chunk, false)
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }

                onLog("VGGT: writing COLMAP model to \(outSparse.path) (points=1234)", false)
                try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)
                for name in ["cameras.bin", "images.bin", "points3D.bin", "cameras.txt", "points3D.txt"] {
                    let url = outSparse.appendingPathComponent(name)
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
                }
                let imagesTxt = outSparse.appendingPathComponent("images.txt")
                let text = """
                # Image list with two lines per image:
                #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
                1 1 0 0 0 0 0 0 1 frame_000000.jpg
                """
                try text.write(to: imagesTxt, atomically: true, encoding: .utf8)
                onLog("VGGT: done", false)
            }
        }

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        var tooling = PipelineRunner.Tooling(runner: runner)
        tooling.vggtSfm = SlowVggt(delayNanoseconds: 300_000_000)

        final class LockedEvents: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [PipelineEvent] = []

            func append(_ event: PipelineEvent) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            func snapshot() -> [PipelineEvent] {
                lock.lock()
                let copy = events
                lock.unlock()
                return copy
            }
        }

        let sink = LockedEvents()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: tooling
        )

        try await pipeline.run { event in
            sink.append(event)
        }

        let progressEvents = sink.snapshot().compactMap { event -> (fraction: Double, message: String)? in
            guard case let .stageProgress(stage, fraction, message) = event,
                  stage == .sfmFeatures else {
                return nil
            }
            return (fraction, message)
        }

        XCTAssertTrue(progressEvents.contains(where: { $0.message.contains("Starting VGGT") }))
        XCTAssertTrue(progressEvents.contains(where: { $0.message.contains("VGGT chunk") }))
        XCTAssertGreaterThan(progressEvents.map(\.fraction).max() ?? 0, 0.0)
    }

    func testPipelineAcceptsModelAnalyzerOutputInStderr() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<20 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "Registered images: 20 / 20\nMean reprojection error: 1.0\n"), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineGlobalMapperFallbackToColmap() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "fail"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 2\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineDisablesGlobalMapperAfterMissingCommand() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<100 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let missingCommandError = "ERROR: command `global_mapper` not recognized. To list all commands, run `colmap help`."

        let runner = MockSubprocessRunner(scripts: [
            // Attempt 1
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: missingCommandError), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),

            // Attempt 2 (global_mapper should be skipped)
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 60 / 60\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),

            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let globalMapperRuns = runner.calls.filter { $0.0 == toolchain.colmap.path && $0.1.first == "global_mapper" }
        XCTAssertEqual(globalMapperRuns.count, 1)

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineRespectsColmapMapperPreference() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": "colmap",
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineFailsOnLowQuality() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
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
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let featureRuns = runner.calls.filter { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }
        XCTAssertEqual(featureRuns.count, 2)
    }

    func testPipelineFailsOnMissingImages() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "no images"), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
    }

    func testPipelineFailsWhenOnlyOneUsableImageRemains() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": nil,
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("OneImage.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img0.jpg"), value: 42)

        let metadata = ProjectMetadata(
            title: "OneImage",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(saved.state.lastError, "At least two usable photos or video frames are required.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPipelineRetriesWithReducedFramesOnColmapFailure() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<100 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "fail"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 80 / 80\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineRetriesWithCpuWhenGpuUnsupported() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil,
            "EASYSPLAT_COLMAP_FORCE_CPU": nil,
            "EASYSPLAT_COLMAP_USE_GPU": nil,
            "EASYSPLAT_COLMAP_FORCE_GPU": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        var featureRuns: [[String]] = []
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "No CUDA support."), onRun: { args in
                featureRuns.append(args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                featureRuns.append(args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("export_00001.ply")
                try? TestFileBuilder.writeMinimalPly(at: ply)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(featureRuns.count, 2)
        XCTAssertEqual(value(for: "--FeatureExtraction.use_gpu", in: featureRuns[0]), "1")
        XCTAssertEqual(value(for: "--FeatureExtraction.use_gpu", in: featureRuns[1]), "0")

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineFailsOnMatcherError() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
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
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
    }

    func testPipelineFailsOnBrushError() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "brush failed"), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
    }

    func testPipelineFailsWhenOutputMissing() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["global_mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
    }

    func testPipelineResumeSkipsCompletedStages() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SFM_BACKEND": "colmap",
            "EASYSPLAT_SFM_MAPPER": nil,
            "EASYSPLAT_SKIP_TRAINING": nil,
            "EASYSPLAT_COLMAP_FORCE_CPU": "1"
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let originalsFolder = paths.originalsURL.appendingPathComponent(sourcePhotos.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: originalsFolder, withIntermediateDirectories: true)
        try writeTestImage(url: originalsFolder.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: originalsFolder.appendingPathComponent("img2.jpg"), value: 40)

        for index in 0..<2 {
            let url = paths.framesSelectedURL.appendingPathComponent(String(format: "frame_%06d.jpg", index))
            try writeTestImage(url: url, value: UInt8(index * 40))
        }
        let selectedManifest: [TestSelectedFrameMapping] = [
            .init(outputFileName: "frame_000000.jpg", groupId: "photos", isVideo: false, sourcePath: sourcePhotos.appendingPathComponent("img1.jpg").path),
            .init(outputFileName: "frame_000001.jpg", groupId: "photos", isVideo: false, sourcePath: sourcePhotos.appendingPathComponent("img2.jpg").path)
        ]
        let selectedManifestData = try JSONEncoder().encode(selectedManifest)
        try selectedManifestData.write(to: paths.framesSelectedManifestURL, options: [.atomic])
        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())

        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try """
        # cameras
        1 SIMPLE_PINHOLE 640 480 500 320 240
        """.write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        # images
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        0 0 -1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try """
        # points
        1 0 0 1 128 128 128 1.0 1 0
        """.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let trainingExport = paths.trainingURL.appendingPathComponent("export_00001.ply")
        try FileManager.default.createDirectory(at: paths.trainingURL, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: trainingExport)

        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: output)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run(resumeFrom: .done) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineResumeRepairsCorruptExportAfterInterruptedRun() async throws {
        let restore = await scopedPipelineEnvironment([
            "EASYSPLAT_SKIP_TRAINING": nil
        ])
        defer { restore() }

        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0"),
            checkpoint: PipelineCheckpoint(
                stage: .exportSplat,
                updatedAt: Date(),
                progressFraction: 0.9,
                message: "Interrupted during export",
                details: nil
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let originalsFolder = paths.originalsURL.appendingPathComponent(sourcePhotos.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: originalsFolder, withIntermediateDirectories: true)
        try writeTestImage(url: originalsFolder.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: originalsFolder.appendingPathComponent("img2.jpg"), value: 40)

        for index in 0..<2 {
            let url = paths.framesSelectedURL.appendingPathComponent(String(format: "frame_%06d.jpg", index))
            try writeTestImage(url: url, value: UInt8(index * 40))
        }
        let selectedManifest: [TestSelectedFrameMapping] = [
            .init(outputFileName: "frame_000000.jpg", groupId: "photos", isVideo: false, sourcePath: sourcePhotos.appendingPathComponent("img1.jpg").path),
            .init(outputFileName: "frame_000001.jpg", groupId: "photos", isVideo: false, sourcePath: sourcePhotos.appendingPathComponent("img2.jpg").path)
        ]
        let selectedManifestData = try JSONEncoder().encode(selectedManifest)
        try selectedManifestData.write(to: paths.framesSelectedManifestURL, options: [.atomic])
        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())

        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try """
        # cameras
        1 SIMPLE_PINHOLE 640 480 500 320 240
        """.write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        # images
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        0 0 -1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try """
        # points
        1 0 0 1 128 128 128 1.0 1 0
        """.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let trainingExport = paths.trainingURL.appendingPathComponent("export_00001.ply")
        try FileManager.default.createDirectory(at: paths.trainingURL, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: trainingExport)

        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try "ply".write(to: output, atomically: true, encoding: .utf8)

        let toolchain = try makeToolchain(root: temp)
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run(resumeFrom: .done) { _ in }

        let outputText = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(outputText.contains("end_header"), "Unexpected output content: \(outputText)")
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

    private func writeSparseModel(at projectURL: URL) throws {
        let modelURL = projectURL.appendingPathComponent("SfM/colmap/sparse/0", isDirectory: true)
        try writeSparseModel(at: modelURL, imageName: "frame_000000.jpg")
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
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin", "cameras.txt", "points3D.txt"] {
            let url = modelURL.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        }
        let imagesTxt = modelURL.appendingPathComponent("images.txt")
        let text = """
        # Image list with two lines per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 \(imageName)
        """
        try text.write(to: imagesTxt, atomically: true, encoding: .utf8)
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

    private func writeMapAnythingRunArtifacts(
        for args: [String],
        imageName: String = "frame_000000.jpg",
        manifestModeOverride: String? = nil,
        registeredImageCountOverride: Int? = nil
    ) throws {
        guard let out = value(for: "--out-sparse", in: args) else { return }
        try writeSparseModel(at: URL(fileURLWithPath: out), imageName: imageName)

        guard let manifestPath = value(for: "--manifest-out", in: args),
              let imagesPath = value(for: "--images", in: args),
              let mode = value(for: "--mode", in: args) else {
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
        let requestedAnchorMaxViews = Int(value(for: "--anchor-max-views", in: args) ?? "") ?? totalImages
        let anchorNames = downsampleMapAnythingNamesUniform(
            imageNames,
            targetCount: max(2, min(totalImages, requestedAnchorMaxViews))
        )
        let requestedWindowSize = Int(value(for: "--window-size", in: args) ?? "") ?? max(2, anchorNames.count)
        let requestedWindowOverlap = Int(value(for: "--window-overlap", in: args) ?? "") ?? 0
        let effectiveMode = manifestModeOverride ?? mode
        let effectiveWindowSize = effectiveMode == "direct" ? max(2, anchorNames.count) : max(2, min(anchorNames.count, requestedWindowSize))
        let effectiveWindowOverlap = effectiveMode == "direct" ? 0 : max(0, min(requestedWindowOverlap, effectiveWindowSize - 1))
        let windows = planMapAnythingWindows(
            imageCount: anchorNames.count,
            windowSize: effectiveWindowSize,
            windowOverlap: effectiveWindowOverlap
        )
        let fusedSparsePointCount = max(1, min(9_000, totalImages * 2_000))
        let finalObservationCount = max(fusedSparsePointCount + 1_000, fusedSparsePointCount + totalImages * 400)
        let registeredImageCount = registeredImageCountOverride ?? (effectiveMode == "direct" ? totalImages : anchorNames.count)
        let meanTrackLength = Double(finalObservationCount) / Double(fusedSparsePointCount)

        let manifest = MapAnythingCoverageManifest(
            mode: effectiveMode,
            requestedDevice: "mps",
            selectedDevice: "mps",
            resolution: 518,
            cameraType: "SIMPLE_RADIAL",
            sharedCamera: false,
            seed: 42,
            maxPoints: 120_000,
            totalImages: totalImages,
            anchorImageCount: anchorNames.count,
            requestedWindowSize: effectiveMode == "direct" ? anchorNames.count : requestedWindowSize,
            requestedWindowOverlap: effectiveMode == "direct" ? 0 : requestedWindowOverlap,
            windowSize: effectiveWindowSize,
            windowOverlap: effectiveWindowOverlap,
            windowReductionCount: 0,
            anchors: anchorNames,
            windows: windows.map { (start, end) in
                MapAnythingCoverageManifest.Window(
                    start: start,
                    end: end,
                    images: Array(anchorNames[start..<end])
                )
            },
            rawPointSampleCount: fusedSparsePointCount + totalImages * 500,
            fusedSparsePointCount: fusedSparsePointCount,
            finalObservationCount: finalObservationCount,
            meanTrackLength: meanTrackLength,
            registeredImageCount: registeredImageCount
        )

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
    }

    private func writeDa3RunArtifacts(
        for args: [String],
        imageName: String = "frame_000000.jpg"
    ) throws {
        guard let manifestPath = value(for: "--manifest-out", in: args),
              let imagesPath = value(for: "--images", in: args),
              let mode = value(for: "--mode", in: args),
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
        let pointCount = max(16_000, totalImages * 500)
        let observationsPerPoint = max(1, min(2, totalImages))
        try writeDa3SparseModel(
            at: URL(fileURLWithPath: out),
            imageNames: imageNames.isEmpty ? [imageName] : imageNames,
            pointCount: pointCount
        )
        let requestedWindowSize = Int(value(for: "--window-size", in: args) ?? "") ?? max(2, totalImages)
        let requestedWindowOverlap = Int(value(for: "--window-overlap", in: args) ?? "") ?? 0
        let effectiveWindowSize = max(2, min(totalImages, requestedWindowSize))
        let effectiveWindowOverlap = max(0, min(requestedWindowOverlap, effectiveWindowSize - 1))
        let windows = planMapAnythingWindows(
            imageCount: totalImages,
            windowSize: effectiveWindowSize,
            windowOverlap: effectiveWindowOverlap
        )
        let nativeColmapExport = totalImages <= effectiveWindowSize

        let manifest = Da3CoverageManifest(
            mode: mode,
            requestedDevice: value(for: "--device", in: args) ?? "mps",
            selectedDevice: "mps",
            modelSubdirectory: value(for: "--model-subdir", in: args) ?? "DA3-BASE",
            fallbackModelSubdirectory: value(for: "--fallback-model-subdir", in: args),
            processResolution: Int(value(for: "--process-res", in: args) ?? "") ?? 504,
            cameraType: value(for: "--camera-type", in: args) ?? "PINHOLE",
            sharedCamera: args.contains("--shared-camera"),
            maxPoints: Int(value(for: "--max-points", in: args) ?? "") ?? 120_000,
            totalImages: totalImages,
            windowSize: effectiveWindowSize,
            windowOverlap: effectiveWindowOverlap,
            windows: windows.map { (start, end) in
                Da3CoverageManifest.Window(
                    start: start,
                    end: end,
                    images: Array(imageNames[start..<end])
                )
            },
            rawPointSampleCount: pointCount,
            fusedSparsePointCount: pointCount,
            finalObservationCount: pointCount * observationsPerPoint,
            meanTrackLength: Double(observationsPerPoint),
            registeredImageCount: totalImages,
            nativeColmapExport: nativeColmapExport,
            exportStrategy: nativeColmapExport ? "native_colmap" : "unsupported_non_native_colmap"
        )

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
    }

    private func writeDa3SparseModel(at modelURL: URL, imageNames: [String], pointCount: Int) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        var imagesText = "# Image list with two lines per image:\n"
        for (offset, imageName) in imageNames.enumerated() {
            let imageID = offset + 1
            imagesText += "\(imageID) 1 0 0 0 0 0 0 1 \(imageName)\n"
            if imageID == 1 || imageID == 2 {
                let observations = (1...pointCount)
                    .map { pointID in "\(imageID - 1) \(imageID - 1) \(pointID)" }
                    .joined(separator: " ")
                imagesText += observations + "\n"
            } else {
                imagesText += "\n"
            }
        }
        try imagesText.write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        let points = (1...pointCount)
            .map { pointID in
                let point2DIndex = pointID - 1
                let track = imageNames.count >= 2 ? "1 \(point2DIndex) 2 \(point2DIndex)" : "1 \(point2DIndex)"
                return "\(pointID) 0 0 1 128 128 128 1.0 \(track)"
            }
            .joined(separator: "\n")
        try (points + "\n").write(to: modelURL.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
    }

    private func downsampleMapAnythingNamesUniform(_ names: [String], targetCount: Int) -> [String] {
        guard !names.isEmpty else { return [] }
        let cappedTarget = max(1, min(names.count, targetCount))
        if names.count <= cappedTarget {
            return names
        }
        if cappedTarget == 1 {
            return [names[names.count / 2]]
        }

        let step = Double(names.count - 1) / Double(cappedTarget - 1)
        var indices: [Int] = []
        for index in 0..<cappedTarget {
            let candidate = max(0, min(names.count - 1, Int(round(Double(index) * step))))
            if indices.last != candidate {
                indices.append(candidate)
            }
        }
        if indices.last != names.count - 1 {
            indices[indices.count - 1] = names.count - 1
        }
        return indices.map { names[$0] }
    }

    private func planMapAnythingWindows(imageCount: Int, windowSize: Int, windowOverlap: Int) -> [(Int, Int)] {
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
        createMapAnythingFiles: Bool = true,
        createVggtFiles: Bool = false,
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
        let brush = try writeStub("brush")
        let msplat = createMsplatFile ? try writeStub("msplat-train") : bin.appendingPathComponent("msplat-train")

        let da3 = try TestToolchains.da3Toolchain(root: toolchainRoot, createFiles: createDa3Files)
        let mapanything = try TestToolchains.mapAnythingToolchain(root: toolchainRoot, createFiles: createMapAnythingFiles)
        let vggt = try TestToolchains.vggtToolchain(root: toolchainRoot, createFiles: createVggtFiles)
        let fastvggt = try TestToolchains.fastVggtToolchain(root: toolchainRoot, createFiles: createVggtFiles)
        return ToolchainPaths(
            root: toolchainRoot,
            colmap: colmap,
            glomap: colmap,
            brush: brush,
            msplat: msplat,
            da3: da3,
            mapanything: mapanything,
            vggt: vggt,
            fastvggt: fastvggt
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

private actor TrainingGateFlag {
    private var called = false

    func setCalled() {
        called = true
    }

    func wasCalled() -> Bool {
        called
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

#endif
