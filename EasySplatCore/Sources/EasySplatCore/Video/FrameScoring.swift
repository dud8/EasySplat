import Foundation
import CoreGraphics
import ImageIO

public struct FrameScore: Sendable {
    public var blurScore: Double
    public var laplacianScore: Double
    public var brightness: Double
    public var maximumColorComponent: Double
    public var clippedFraction: Double
    public var lowLightExposureEV: Double
    public var dHash: UInt64
}

public enum FrameScoring {
    public static func scoreFrame(at url: URL) throws -> FrameScore {
        guard let cgImage = loadCGImage(url: url) else {
            throw NSError(domain: "FrameScoring", code: 1)
        }
        return scoreFrame(cgImage: cgImage)
    }

    public static func scoreFrame(cgImage: CGImage) -> FrameScore {
        let grayscale = grayscalePixels(cgImage: cgImage, width: 64, height: 64)
        let blur = blurScore(pixels: grayscale, width: 64, height: 64)
        let laplacian = laplacianVariance(pixels: grayscale, width: 64, height: 64)
        let exposure = exposureScore(pixels: grayscale)
        let maximumColorComponent = maximumColorComponent(cgImage: cgImage, width: 64, height: 64)
        let hash = dHash(pixels: grayscale, width: 64, height: 64)
        return FrameScore(
            blurScore: blur,
            laplacianScore: laplacian,
            brightness: exposure.brightness,
            maximumColorComponent: maximumColorComponent,
            clippedFraction: exposure.clippedFraction,
            lowLightExposureEV: lowLightExposureEV(
                brightness: exposure.brightness,
                maximumColorComponent: maximumColorComponent
            ),
            dHash: hash
        )
    }

    private static func loadCGImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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

    private static func laplacianVariance(pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2 else { return 0 }
        var sum: Double = 0
        var sumSquares: Double = 0
        var count: Double = 0
        for y in 1..<(height - 1) {
            let row = y * width
            let prev = (y - 1) * width
            let next = (y + 1) * width
            for x in 1..<(width - 1) {
                let center = Double(pixels[row + x])
                let up = Double(pixels[prev + x])
                let down = Double(pixels[next + x])
                let left = Double(pixels[row + x - 1])
                let right = Double(pixels[row + x + 1])
                let value = (4.0 * center) - up - down - left - right
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = (sumSquares / count) - (mean * mean)
        return variance
    }

    private static func exposureScore(
        pixels: [UInt8]
    ) -> (brightness: Double, clippedFraction: Double) {
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

    private static func maximumColorComponent(
        cgImage: CGImage,
        width: Int,
        height: Int
    ) -> Double {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            if let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.noneSkipLast.rawValue
            ) {
                context.interpolationQuality = .high
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        var maximum: UInt8 = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            maximum = max(maximum, pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
        return Double(maximum) / 255.0
    }

    private static func lowLightExposureEV(
        brightness: Double,
        maximumColorComponent: Double
    ) -> Double {
        guard brightness >= 0.02,
              brightness < 0.18,
              maximumColorComponent > 0,
              maximumColorComponent < 0.98 else {
            return 0
        }
        let desiredEV = log2(0.24 / brightness)
        let clippingSafeEV = log2(0.98 / maximumColorComponent)
        let exposureEV = min(1.0, desiredEV, clippingSafeEV)
        return exposureEV >= 0.15 ? exposureEV : 0
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
