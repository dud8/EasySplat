import CoreGraphics
import CryptoKit
import Foundation

struct PhotoAnalysisMeasurements: Equatable, Sendable {
    let spatialDescriptor: [UInt8]
    let qualityBucket: UInt8
    let dHash: UInt64
    let proxyPixelWidth: Int
    let proxyPixelHeight: Int
    let proxyPixelSHA256: String
    let analysisRecipeVersion: Int
    let analysisRecipeSHA256: String

    func evidence(sourceSHA256: String) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: sourceSHA256,
            spatialDescriptor: spatialDescriptor,
            qualityBucket: qualityBucket,
            dHash: dHash,
            proxyPixelWidth: proxyPixelWidth,
            proxyPixelHeight: proxyPixelHeight,
            proxyPixelSHA256: proxyPixelSHA256,
            analysisRecipeVersion: analysisRecipeVersion,
            analysisRecipeSHA256: analysisRecipeSHA256
        )
    }
}

enum PhotoAnalysisEvidenceBuilder {
    enum Error: Swift.Error, Equatable {
        case invalidSourceSHA256
        case invalidImageDimensions
        case renderFailed
    }

    static let recipeVersion = PhotoAnalysisEvidence.currentRecipeVersion
    // SHA-256 of the fixed, domain-separated recipe documented by the descriptor
    // construction below. Changing any sampling or quantization rule requires v2.
    static let recipeSHA256 = PhotoAnalysisEvidence.currentRecipeSHA256

    static func build(
        sourceSHA256: String,
        orientedImage: CGImage
    ) throws -> PhotoAnalysisEvidence {
        guard isLowercaseSHA256(sourceSHA256) else { throw Error.invalidSourceSHA256 }
        return try measure(orientedImage: orientedImage).evidence(sourceSHA256: sourceSHA256)
    }

    static func measure(orientedImage: CGImage) throws -> PhotoAnalysisMeasurements {
        guard orientedImage.width > 0, orientedImage.height > 0 else {
            throw Error.invalidImageDimensions
        }

        let maximumDimension = 256
        let sourceMaximum = max(orientedImage.width, orientedImage.height)
        let width = max(
            1,
            Int((Double(orientedImage.width) * Double(maximumDimension)
                / Double(sourceMaximum)).rounded())
        )
        let height = max(
            1,
            Int((Double(orientedImage.height) * Double(maximumDimension)
                / Double(sourceMaximum)).rounded())
        )
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let madeImage = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(
                orientedImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return context.makeImage()
        }
        guard let normalizedImage = madeImage else { throw Error.renderFailed }

        let luma = lumaPixels(from: pixels)
        let lumaGrid = channelMeans(
            pixels: pixels,
            width: width,
            height: height,
            columns: 8,
            rows: 4,
            channel: lumaChannel
        )
        let lumaMean = lumaGrid.reduce(0, +) / max(1, lumaGrid.count)
        let lumaMAD = lumaGrid.reduce(0) { $0 + abs($1 - lumaMean) }
            / max(1, lumaGrid.count)
        let normalizationScale = max(8, lumaMAD)

        var descriptor: [UInt8] = lumaGrid.map { value in
            quantizedByte(128 + (value - lumaMean) * 64 / normalizationScale)
        }
        let chromaGrid = channelMeans(
            pixels: pixels,
            width: width,
            height: height,
            columns: 4,
            rows: 2,
            channel: chromaChannels
        )
        for value in chromaGrid {
            descriptor.append(quantizedByte(value.cb))
            descriptor.append(quantizedByte(value.cr))
        }
        descriptor.append(contentsOf: gradientDescriptor(
            luma: luma,
            width: width,
            height: height
        ))
        let coarseLuma = channelMeans(
            pixels: pixels,
            width: width,
            height: height,
            columns: 2,
            rows: 2,
            channel: lumaChannel
        )
        descriptor.append(contentsOf: coarseLuma.map { value in
            quantizedByte(128 + (value - lumaMean) * 64 / normalizationScale)
        })
        descriptor.append(aspectBucket(width: width, height: height))
        descriptor.append(quantizedByte(lumaMAD * 4))
        descriptor.append(meanSaturation(pixels))
        descriptor.append(meanGradientStrength(luma: luma, width: width, height: height))
        guard descriptor.count == PhotoAnalysisEvidence.spatialDescriptorLength else {
            throw Error.renderFailed
        }

        let score = FrameScoring.scoreFrame(cgImage: normalizedImage)
        return PhotoAnalysisMeasurements(
            spatialDescriptor: descriptor,
            qualityBucket: qualityBucket(score),
            dHash: score.dHash,
            proxyPixelWidth: width,
            proxyPixelHeight: height,
            proxyPixelSHA256: pixelDigest(pixels: pixels, width: width, height: height),
            analysisRecipeVersion: recipeVersion,
            analysisRecipeSHA256: recipeSHA256
        )
    }

    private static func lumaPixels(from pixels: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: pixels.count / 4)
        for index in result.indices {
            let offset = index * 4
            result[index] = quantizedByte(lumaChannel(
                pixels[offset],
                pixels[offset + 1],
                pixels[offset + 2]
            ))
        }
        return result
    }

    private static func channelMeans(
        pixels: [UInt8],
        width: Int,
        height: Int,
        columns: Int,
        rows: Int,
        channel: (UInt8, UInt8, UInt8) -> Int
    ) -> [Int] {
        var sums = [Int64](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        for y in 0..<height {
            let cellY = min(rows - 1, y * rows / height)
            for x in 0..<width {
                let cellX = min(columns - 1, x * columns / width)
                let cell = cellY * columns + cellX
                let offset = (y * width + x) * 4
                sums[cell] += Int64(channel(
                    pixels[offset],
                    pixels[offset + 1],
                    pixels[offset + 2]
                ))
                counts[cell] += 1
            }
        }
        return sums.indices.map { index in
            Int(sums[index] / Int64(max(1, counts[index])))
        }
    }

    private static func channelMeans(
        pixels: [UInt8],
        width: Int,
        height: Int,
        columns: Int,
        rows: Int,
        channel: (UInt8, UInt8, UInt8) -> (cb: Int, cr: Int)
    ) -> [(cb: Int, cr: Int)] {
        var cbSums = [Int64](repeating: 0, count: columns * rows)
        var crSums = [Int64](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        for y in 0..<height {
            let cellY = min(rows - 1, y * rows / height)
            for x in 0..<width {
                let cellX = min(columns - 1, x * columns / width)
                let cell = cellY * columns + cellX
                let offset = (y * width + x) * 4
                let value = channel(
                    pixels[offset],
                    pixels[offset + 1],
                    pixels[offset + 2]
                )
                cbSums[cell] += Int64(value.cb)
                crSums[cell] += Int64(value.cr)
                counts[cell] += 1
            }
        }
        return cbSums.indices.map { index in
            let count = Int64(max(1, counts[index]))
            return (Int(cbSums[index] / count), Int(crSums[index] / count))
        }
    }

    private static func lumaChannel(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Int {
        (77 * Int(red) + 150 * Int(green) + 29 * Int(blue) + 128) >> 8
    }

    private static func chromaChannels(
        _ red: UInt8,
        _ green: UInt8,
        _ blue: UInt8
    ) -> (cb: Int, cr: Int) {
        let r = Int(red)
        let g = Int(green)
        let b = Int(blue)
        return (
            128 + ((-43 * r - 85 * g + 128 * b + 128) >> 8),
            128 + ((128 * r - 107 * g - 21 * b + 128) >> 8)
        )
    }

    private static func gradientDescriptor(
        luma: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard width > 2, height > 2 else { return [UInt8](repeating: 0, count: 8) }
        var bins = [Int64](repeating: 0, count: 8)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let dx = Int(luma[y * width + x + 1]) - Int(luma[y * width + x - 1])
                let dy = Int(luma[(y + 1) * width + x]) - Int(luma[(y - 1) * width + x])
                let absoluteX = abs(dx)
                let absoluteY = abs(dy)
                let direction: Int
                if absoluteX > absoluteY * 2 {
                    direction = 0
                } else if absoluteY > absoluteX * 2 {
                    direction = 1
                } else {
                    direction = (dx >= 0) == (dy >= 0) ? 2 : 3
                }
                let region = x < width / 2 ? 0 : 1
                bins[region * 4 + direction] += Int64(absoluteX + absoluteY)
            }
        }
        var output: [UInt8] = []
        output.reserveCapacity(8)
        for region in 0..<2 {
            let start = region * 4
            let total = max(1, bins[start..<(start + 4)].reduce(0, +))
            for direction in 0..<4 {
                output.append(quantizedByte(Int(bins[start + direction] * 255 / total)))
            }
        }
        return output
    }

    private static func aspectBucket(width: Int, height: Int) -> UInt8 {
        let extent = max(width, height)
        return quantizedByte(128 + (width - height) * 127 / max(1, extent))
    }

    private static func meanSaturation(_ pixels: [UInt8]) -> UInt8 {
        var total: Int64 = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let maximum = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
            let minimum = min(pixels[offset], pixels[offset + 1], pixels[offset + 2])
            total += Int64(maximum - minimum)
        }
        return quantizedByte(Int(total / Int64(max(1, pixels.count / 4))))
    }

    private static func meanGradientStrength(
        luma: [UInt8],
        width: Int,
        height: Int
    ) -> UInt8 {
        guard width > 2, height > 2 else { return 0 }
        var total: Int64 = 0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let horizontal = abs(
                    Int(luma[y * width + x + 1]) - Int(luma[y * width + x - 1])
                )
                let vertical = abs(
                    Int(luma[(y + 1) * width + x]) - Int(luma[(y - 1) * width + x])
                )
                total += Int64(horizontal + vertical)
                count += 1
            }
        }
        return quantizedByte(Int(total / Int64(max(1, count))))
    }

    private static func qualityBucket(_ score: FrameScore) -> UInt8 {
        let sharpness = min(180, Int(log2(max(0, score.laplacianScore) + 1) * 18))
        let localContrast = min(50, Int(max(0, score.blurScore) * 2))
        let exposurePenalty = Int(abs(score.brightness - 0.45) * 120)
        let clippingPenalty = Int(max(0, score.clippedFraction) * 150)
        let darknessPenalty = score.brightness < 0.05 ? 40 : 0
        return quantizedByte(
            40 + sharpness + localContrast - exposurePenalty - clippingPenalty - darknessPenalty
        )
    }

    private static func pixelDigest(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat oriented photo proxy pixels v1".utf8))
        for value in [width, height] {
            var encoded = UInt64(value).bigEndian
            withUnsafeBytes(of: &encoded) { hasher.update(bufferPointer: $0) }
        }
        hasher.update(data: Data(pixels))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func quantizedByte(_ value: Int) -> UInt8 {
        UInt8(clamping: value)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }
}
