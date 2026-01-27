import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

final class PipelineIntegrationTests: XCTestCase {
    func testPipelineSuccessWithGlomap() async throws {
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

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["sequential_matcher"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: { args in
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

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["sequential_matcher"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 1, stdout: "", stderr: "fail"), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: { args in
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

    func testPipelineFailsOnLowQuality() async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try? paths.ensureDirectories()
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["sequential_matcher"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["mapper"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, stdout: "Registered images: 2 / 10\nMean reprojection error: 3.5\n", stderr: ""), onRun: nil)
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

    func testPipelineFailsOnMissingImages() async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try? paths.ensureDirectories()
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, stdout: "", stderr: "no images"), onRun: nil)
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

    func testPipelineFailsOnMatcherError() async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try? paths.ensureDirectories()
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["sequential_matcher"], result: .init(exitCode: 1, stdout: "", stderr: "match failed"), onRun: nil)
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

    func testPipelineFailsOnBrushError() async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try? paths.ensureDirectories()
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["sequential_matcher"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 1, stdout: "", stderr: "brush failed"), onRun: nil)
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

    func testPipelineFailsWhenOutputMissing() async {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try? writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       preset: PresetSpec(mode: .object, quality: .draft))
        let paths = ProjectPaths(root: projectURL)
        try? paths.ensureDirectories()
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = ToolchainPaths(
            root: temp,
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
        )

        let runner = MockSubprocessRunner(scripts: [
            .init(path: "/mock/colmap", argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["sequential_matcher"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/glomap", argsPrefix: ["mapper"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/mock/colmap", argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, stdout: "Registered images: 10 / 10\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil),
            .init(path: "/mock/brush", argsPrefix: ["train"], result: .init(exitCode: 0, stdout: "", stderr: ""), onRun: nil)
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
}

private func XCTAssertThrowsErrorAsync(_ expression: @escaping () async throws -> Void) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        XCTAssertTrue(true)
    }
}
