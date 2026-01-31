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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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

    func testPipelineSuccessWithLearnedMatching() async throws {
        setenv("EASYSPLAT_SFM_BACKEND", "learned", 1)
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

        let toolchain = try makeToolchain(root: temp, createLearnedFiles: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.learnedSfm.matchTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeLearnedOutputs(at: projectURL) }),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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

    func testResumeAfterLearnedMatchingFallsBackToColmap() async throws {
        let previousBackend = getenv("EASYSPLAT_SFM_BACKEND").map { String(cString: $0) }
        let previousMapper = getenv("EASYSPLAT_SFM_MAPPER").map { String(cString: $0) }
        setenv("EASYSPLAT_SFM_BACKEND", "learned", 1)
        setenv("EASYSPLAT_SFM_MAPPER", "colmap", 1)
        defer {
            if let previousBackend {
                setenv("EASYSPLAT_SFM_BACKEND", previousBackend, 1)
            } else {
                unsetenv("EASYSPLAT_SFM_BACKEND")
            }
            if let previousMapper {
                setenv("EASYSPLAT_SFM_MAPPER", previousMapper, 1)
            } else {
                unsetenv("EASYSPLAT_SFM_MAPPER")
            }
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<5 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: sourcePhotos.path),
            preset: PresetSpec(mode: .object, quality: .draft),
            state: PipelineState(stage: .sfmMapping, attempt: 1, lastError: "failed", resumeToken: nil)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let originalsPhotos = paths.originalsURL.appendingPathComponent(sourcePhotos.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: originalsPhotos, withIntermediateDirectories: true)
        for index in 0..<2 {
            try writeTestImage(url: originalsPhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        try FileManager.default.createDirectory(at: paths.framesSelectedURL, withIntermediateDirectories: true)
        try writeTestImage(url: paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg"), value: 42)

        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
        try FileManager.default.createDirectory(at: paths.sfmLearnedFeaturesURL, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: paths.sfmLearnedFeaturesURL.appendingPathComponent("features.bin").path,
            contents: Data([0x0])
        )
        try "0 1\n".write(to: paths.sfmLearnedMatchListURL, atomically: true, encoding: .utf8)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 5 / 5\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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

        try await pipeline.run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertTrue(runner.calls.contains { $0.0 == "/mock/colmap" && $0.1.first == "feature_extractor" })
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "Registered images: 10 / 10\nMean reprojection error: 1.0\n"), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "fail"), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: dyldError), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),

            // Attempt 2 (glomap should be skipped)
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),

            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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

        let glomapRuns = runner.calls.filter { $0.0 == "/mock/glomap" && $0.1.first == "mapper" }
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: .init(toolchain: toolchain, preset: metadata.preset),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let featureRuns = runner.calls.filter { $0.0 == "/mock/colmap" && $0.1.first == "feature_extractor" }
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "no images"), onRun: nil)
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "fail"), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 80 / 80\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "No CUDA support."), onRun: { args in
                featureRuns.append(args)
            }),
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                featureRuns.append(args)
            }),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard args.count > 1 else { return }
                let dataset = URL(fileURLWithPath: args[1])
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "match failed"), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "exhaustive failed"), onRun: nil)
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "brush failed"), onRun: nil)
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
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["exhaustive_matcher"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in try? self.writeSparseModel(at: projectURL) }),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil)
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
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let url = modelURL.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        }
    }

    private func writeLearnedOutputs(at projectURL: URL) throws {
        let paths = ProjectPaths(root: projectURL)
        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
        try FileManager.default.createDirectory(at: paths.sfmLearnedFeaturesURL, withIntermediateDirectories: true)
        let features = paths.sfmLearnedFeaturesURL.appendingPathComponent("features.bin")
        FileManager.default.createFile(atPath: features.path, contents: Data([0x00]))
        try "0 1\n".write(to: paths.sfmLearnedMatchListURL, atomically: true, encoding: .utf8)
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func makeToolchain(root: URL, createLearnedFiles: Bool = false) throws -> ToolchainPaths {
        let learned = try TestToolchains.learnedSfmToolchain(root: root, createFiles: createLearnedFiles)
        return ToolchainPaths(
            root: root,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush"),
            learnedSfm: learned
        )
    }
}

private func XCTAssertThrowsErrorAsync(_ expression: @escaping () async throws -> Void) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        XCTAssertTrue(true)
    }
}
#endif
