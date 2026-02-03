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
        let toolchain = ToolchainPaths(root: projectURL, colmap: projectURL, glomap: projectURL, brush: projectURL, vggt: vggt)
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
        let toolchain = ToolchainPaths(root: projectURL, colmap: projectURL, glomap: projectURL, brush: projectURL, vggt: vggt)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        let photos = try runner.loadPhotosForTesting(in: dir)
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.lastPathComponent, "photo.jpg")
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
