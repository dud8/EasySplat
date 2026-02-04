#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

final class PipelineIntegrationTests: XCTestCase {
    private var previousBackendEnv: String?

    override func setUp() {
        super.setUp()
        if let value = getenv("EASYSPLAT_SFM_BACKEND") {
            previousBackendEnv = String(cString: value)
        } else {
            previousBackendEnv = nil
        }
        setenv("EASYSPLAT_SFM_BACKEND", "colmap", 1)
    }

    override func tearDown() {
        if let previousBackendEnv {
            setenv("EASYSPLAT_SFM_BACKEND", previousBackendEnv, 1)
        } else {
            unsetenv("EASYSPLAT_SFM_BACKEND")
        }
        super.tearDown()
    }

    func testPipelineSuccessWithGlomap() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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

    func testTrainingGateInvokedBeforeTraining() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

        let toolchain = try makeToolchain(root: temp)
        let gateFlag = TrainingGateFlag()

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
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
        setenv("EASYSPLAT_SFM_BACKEND", "vggt", 1)
        defer { setenv("EASYSPLAT_SFM_BACKEND", "colmap", 1) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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

    func testPipelineVggtEmitsProgressWhileRunning() async throws {
        setenv("EASYSPLAT_SFM_BACKEND", "vggt", 1)
        defer { setenv("EASYSPLAT_SFM_BACKEND", "colmap", 1) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "Registered images: 10 / 10\nMean reprojection error: 1.0\n"), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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

    func testPipelineGlomapFallbackToColmap() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "fail"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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

    func testPipelineDisablesGlomapAfterDyldMissingOpenSSL() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

        let dyldError = """
        dyld: Library not loaded: @rpath/libcrypto.3.dylib
          Reason: no LC_RPATH's found
        """

        let runner = MockSubprocessRunner(scripts: [
            // Attempt 1
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: dyldError), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),

            // Attempt 2 (glomap should be skipped)
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),

            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
            })
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let glomapRuns = runner.calls.filter { $0.0 == toolchain.glomap.path && $0.1.first == "mapper" }
        XCTAssertEqual(glomapRuns.count, 1)

        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testPipelineRespectsColmapMapperPreference() async throws {
        setenv("EASYSPLAT_SFM_MAPPER", "colmap", 1)
        defer { unsetenv("EASYSPLAT_SFM_MAPPER") }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    func testPipelineRetriesWithReducedFramesOnColmapFailure() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 80 / 80\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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
        setenv("EASYSPLAT_COLMAP_FORCE_GPU", "1", 1)
        defer { unsetenv("EASYSPLAT_COLMAP_FORCE_GPU") }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: toolchain.brush.path, argsPrefix: [], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let datasetArg = args.last else { return }
                let dataset = URL(fileURLWithPath: datasetArg)
                let training = dataset.deletingLastPathComponent()
                let ply = training.appendingPathComponent("mock.ply")
                try? "ply".write(to: ply, atomically: true, encoding: .utf8)
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
            .init(path: toolchain.glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
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
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

        for index in 0..<2 {
            let url = paths.framesSelectedURL.appendingPathComponent(String(format: "frame_%06d.jpg", index))
            try writeTestImage(url: url, value: UInt8(index * 40))
        }
        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data([0x00]))

        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            FileManager.default.createFile(atPath: sparse.appendingPathComponent(name).path, contents: Data([0x00]))
        }

        let trainingExport = paths.trainingURL.appendingPathComponent("export_00001.ply")
        try FileManager.default.createDirectory(at: paths.trainingURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: trainingExport.path, contents: Data([0x00]))

        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output.path, contents: Data([0x00]))

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        setenv("EASYSPLAT_COLMAP_FORCE_CPU", "1", 1)
        defer { unsetenv("EASYSPLAT_COLMAP_FORCE_CPU") }

        try await pipeline.run(resumeFrom: .done) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
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
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin", "cameras.txt", "points3D.txt"] {
            let url = modelURL.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        }
        let imagesTxt = modelURL.appendingPathComponent("images.txt")
        let text = """
        # Image list with two lines per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        """
        try text.write(to: imagesTxt, atomically: true, encoding: .utf8)
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func makeToolchain(
        root: URL,
        createVggtFiles: Bool = false
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
        let glomap = try writeStub("glomap")
        let brush = try writeStub("brush")

        let vggt = try TestToolchains.vggtToolchain(root: toolchainRoot, createFiles: createVggtFiles)
        return ToolchainPaths(
            root: toolchainRoot,
            colmap: colmap,
            glomap: glomap,
            brush: brush,
            vggt: vggt
        )
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

#endif
