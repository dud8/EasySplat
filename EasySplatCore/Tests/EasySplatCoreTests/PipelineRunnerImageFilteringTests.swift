#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

final class PipelineRunnerImageFilteringTests: XCTestCase {
    func testLoadImagesFiltersNonImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("frame_000001.jpg")
        try writeImage(url: imageURL, size: 16, value: 90)
        let junkURL = dir.appendingPathComponent(".DS_Store")
        try "junk".write(to: junkURL, atomically: true, encoding: .utf8)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let vggt = try TestToolchains.vggtToolchain(root: projectURL)
        let fastvggt = try TestToolchains.fastVggtToolchain(root: projectURL)
        let toolchain = ToolchainPaths(
            root: projectURL,
            colmap: projectURL,
            glomap: projectURL,
            brush: projectURL,
            vggt: vggt,
            fastvggt: fastvggt
        )
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let images = try runner.loadImagesForTesting(in: dir)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.lastPathComponent, "frame_000001.jpg")
    }

    func testLoadPhotosFiltersDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("photo.jpg")
        try writeImage(url: imageURL, size: 16, value: 42)
        let bundleDir = dir.appendingPathComponent("album.jpg", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let vggt = try TestToolchains.vggtToolchain(root: projectURL)
        let fastvggt = try TestToolchains.fastVggtToolchain(root: projectURL)
        let toolchain = ToolchainPaths(
            root: projectURL,
            colmap: projectURL,
            glomap: projectURL,
            brush: projectURL,
            vggt: vggt,
            fastvggt: fastvggt
        )
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.lastPathComponent, "photo.jpg")
    }

    func testLoadPhotosIncludesNestedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rootPhoto = dir.appendingPathComponent("root.jpg")
        try writeImage(url: rootPhoto, size: 16, value: 40)

        let nestedDir = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedPhoto = nestedDir.appendingPathComponent("inner.jpg")
        try writeImage(url: nestedPhoto, size: 16, value: 200)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let vggt = try TestToolchains.vggtToolchain(root: projectURL)
        let fastvggt = try TestToolchains.fastVggtToolchain(root: projectURL)
        let toolchain = ToolchainPaths(
            root: projectURL,
            colmap: projectURL,
            glomap: projectURL,
            brush: projectURL,
            vggt: vggt,
            fastvggt: fastvggt
        )
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(Set(photos.map(\.lastPathComponent)), Set(["root.jpg", "inner.jpg"]))
    }

    func testLoadPhotosSkipsGeneratedProjectDirectoriesAtProjectRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let rootPhoto = dir.appendingPathComponent("root.jpg")
        try writeImage(url: rootPhoto, size: 16, value: 25)

        let nestedDir = dir.appendingPathComponent("nested/input", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nestedPhoto = nestedDir.appendingPathComponent("inner.jpg")
        try writeImage(url: nestedPhoto, size: 16, value: 35)

        let generatedFramesDir = dir.appendingPathComponent("Frames/selected", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedFramesDir, withIntermediateDirectories: true)
        try writeImage(url: generatedFramesDir.appendingPathComponent("frame_000001.jpg"), size: 16, value: 45)

        let generatedSfMDir = dir.appendingPathComponent("SfM/colmap/sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedSfMDir, withIntermediateDirectories: true)
        try writeImage(url: generatedSfMDir.appendingPathComponent("model.jpg"), size: 16, value: 55)

        let generatedTrainingDir = dir.appendingPathComponent("Training", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedTrainingDir, withIntermediateDirectories: true)
        try writeImage(url: generatedTrainingDir.appendingPathComponent("checkpoint.jpg"), size: 16, value: 65)

        let generatedOutputDir = dir.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedOutputDir, withIntermediateDirectories: true)
        try writeImage(url: generatedOutputDir.appendingPathComponent("preview.jpg"), size: 16, value: 75)

        let generatedLogsDir = dir.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedLogsDir, withIntermediateDirectories: true)
        try writeImage(url: generatedLogsDir.appendingPathComponent("snapshot.jpg"), size: 16, value: 85)

        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let vggt = try TestToolchains.vggtToolchain(root: projectURL)
        let fastvggt = try TestToolchains.fastVggtToolchain(root: projectURL)
        let toolchain = ToolchainPaths(
            root: projectURL,
            colmap: projectURL,
            glomap: projectURL,
            brush: projectURL,
            vggt: vggt,
            fastvggt: fastvggt
        )
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(Set(photos.map(\.lastPathComponent)), Set(["root.jpg", "inner.jpg"]))
    }

    private func writeImage(url: URL, size: Int, value: UInt8) throws {
        let width = size
        let height = size
        let bytesPerRow = width
        var pixels = [UInt8](repeating: value, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let data = Data(bytes: &pixels, count: pixels.count)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            XCTFail("Failed to create image")
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create destination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
