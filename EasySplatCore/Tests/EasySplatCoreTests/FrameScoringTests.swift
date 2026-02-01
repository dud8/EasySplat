import CoreGraphics
import XCTest
@testable import EasySplatCore

final class FrameScoringTests: XCTestCase {
    func testSolidImageScores() {
        let image = makeImage(width: 64, height: 64) { _, _ in 0 }
        let score = FrameScoring.scoreFrame(cgImage: image)
        XCTAssertLessThan(score.brightness, 0.1)
        XCTAssertGreaterThan(score.clippedFraction, 0.9)
    }

    func testHighContrastHasHigherLaplacian() {
        let solid = makeImage(width: 64, height: 64) { _, _ in 128 }
        let checker = makeImage(width: 64, height: 64) { x, y in
            ((x / 4 + y / 4) % 2 == 0) ? 0 : 255
        }

        let solidScore = FrameScoring.scoreFrame(cgImage: solid)
        let checkerScore = FrameScoring.scoreFrame(cgImage: checker)
        XCTAssertGreaterThan(checkerScore.laplacianScore, solidScore.laplacianScore)
        XCTAssertNotEqual(checkerScore.dHash, solidScore.dHash)
    }

    private func makeImage(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = pixel(x, y)
            }
        }
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
