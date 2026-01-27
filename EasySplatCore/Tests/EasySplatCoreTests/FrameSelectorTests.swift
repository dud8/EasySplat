import Foundation
import Testing
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers

struct FrameSelectorTests {
    @Test func selectFramesReturnsTargetCount() throws {
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
        #expect(selected.count == 3)
    }

    private func writeImage(url: URL, size: Int, value: UInt8) throws {
        let width = size
        let height = size
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let base = Int(value)
                let pixel = (x * 7 + y * 13 + base) % 255
                pixels[row + x] = UInt8(pixel)
            }
        }
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
            throw FrameSelectorTestError.imageCreationFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FrameSelectorTestError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FrameSelectorTestError.destinationFinalizeFailed
        }
    }
}

private enum FrameSelectorTestError: Error {
    case imageCreationFailed
    case destinationCreationFailed
    case destinationFinalizeFailed
}
