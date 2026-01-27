import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

final class FrameSelectorTests: XCTestCase {
    func testSelectFramesReturnsTargetCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try (0..<5).map { index in
            let url = dir.appendingPathComponent("img_\(index).png")
            try writeImage(url: url, size: 64, value: UInt8(index * 30))
            return url
        }

        let selector = FrameSelector()
        let selected = selector.selectFrames(from: urls, targetCount: 3) { _, _ in }
        XCTAssertEqual(selected.count, 3)
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

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create destination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
