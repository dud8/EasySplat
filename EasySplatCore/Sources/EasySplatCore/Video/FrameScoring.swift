import Foundation
import CoreGraphics
import ImageIO

public struct FrameScore: Sendable {
    public var blurScore: Double
    public var brightness: Double
    public var clippedFraction: Double
    public var dHash: UInt64
}

public enum FrameScoring {
    public static func scoreFrame(at url: URL) throws -> FrameScore {
        guard let cgImage = loadCGImage(url: url) else {
            throw NSError(domain: "FrameScoring", code: 1)
        }
        let grayscale = grayscalePixels(cgImage: cgImage, width: 64, height: 64)
        let blur = blurScore(pixels: grayscale, width: 64, height: 64)
        let (brightness, clipped) = exposureScore(pixels: grayscale)
        let hash = dHash(pixels: grayscale, width: 64, height: 64)
        return FrameScore(blurScore: blur, brightness: brightness, clippedFraction: clipped, dHash: hash)
    }

    private static func loadCGImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func grayscalePixels(cgImage: CGImage, width: Int, height: Int) -> [UInt8] {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        let bytesPerRow = width
        pixels.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return pixels
    }

    private static func blurScore(pixels: [UInt8], width: Int, height: Int) -> Double {
        var sumDiff: Int64 = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<(width - 1) {
                let a = Int64(pixels[row + x])
                let b = Int64(pixels[row + x + 1])
                sumDiff += abs(a - b)
            }
        }
        for y in 0..<(height - 1) {
            let row = y * width
            let next = (y + 1) * width
            for x in 0..<width {
                let a = Int64(pixels[row + x])
                let b = Int64(pixels[next + x])
                sumDiff += abs(a - b)
            }
        }
        return Double(sumDiff) / Double(width * height)
    }

    private static func exposureScore(pixels: [UInt8]) -> (Double, Double) {
        var sum: Int64 = 0
        var clipped: Int64 = 0
        for p in pixels {
            sum += Int64(p)
            if p <= 5 || p >= 250 { clipped += 1 }
        }
        let brightness = Double(sum) / Double(pixels.count) / 255.0
        let clippedFraction = Double(clipped) / Double(pixels.count)
        return (brightness, clippedFraction)
    }

    private static func dHash(pixels: [UInt8], width: Int, height: Int) -> UInt64 {
        let targetW = 9
        let targetH = 8
        let sample = downsample(pixels: pixels, width: width, height: height, targetW: targetW, targetH: targetH)
        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for y in 0..<targetH {
            for x in 0..<(targetW - 1) {
                let left = sample[y * targetW + x]
                let right = sample[y * targetW + x + 1]
                if left > right {
                    hash |= bit
                }
                bit <<= 1
            }
        }
        return hash
    }

    private static func downsample(pixels: [UInt8], width: Int, height: Int, targetW: Int, targetH: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: targetW * targetH)
        for y in 0..<targetH {
            for x in 0..<targetW {
                let srcX = x * width / targetW
                let srcY = y * height / targetH
                output[y * targetW + x] = pixels[srcY * width + srcX]
            }
        }
        return output
    }
}
