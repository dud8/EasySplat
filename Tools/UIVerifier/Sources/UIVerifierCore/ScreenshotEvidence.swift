import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum ScreenshotEvidenceError: Error, LocalizedError {
    case invalidImage(String)
    case dimensionMismatch

    var errorDescription: String? {
        switch self {
        case .invalidImage(let path):
            "Screenshot is not a complete decodable image: \(path)"
        case .dimensionMismatch:
            "Screenshot dimensions do not match for pixel comparison."
        }
    }
}

struct ScreenshotEvidenceMetadata {
    var width: Int
    var height: Int
    var sizeBytes: Int64
    var sha256: String
}

enum ScreenshotEvidenceAnalyzer {
    static func metadata(at url: URL) throws -> ScreenshotEvidenceMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotEvidenceError.invalidImage(url.path)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else {
            throw ScreenshotEvidenceError.invalidImage(url.path)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ScreenshotEvidenceMetadata(
            width: image.width,
            height: image.height,
            sizeBytes: size,
            sha256: digest
        )
    }

    static func normalizedPixelDistance(between first: URL, and second: URL) throws -> Double {
        let firstImage = try decodedPixels(at: first)
        let secondImage = try decodedPixels(at: second)
        guard firstImage.width == secondImage.width,
              firstImage.height == secondImage.height else {
            throw ScreenshotEvidenceError.dimensionMismatch
        }
        var totalDifference: UInt64 = 0
        for offset in stride(from: 0, to: firstImage.pixels.count, by: 4) {
            totalDifference += UInt64(abs(Int(firstImage.pixels[offset]) - Int(secondImage.pixels[offset])))
            totalDifference += UInt64(abs(Int(firstImage.pixels[offset + 1]) - Int(secondImage.pixels[offset + 1])))
            totalDifference += UInt64(abs(Int(firstImage.pixels[offset + 2]) - Int(secondImage.pixels[offset + 2])))
        }
        let pixelCount = UInt64(firstImage.width * firstImage.height)
        let maximumDifference = Double(pixelCount * 3 * 255)
        return maximumDifference > 0 ? Double(totalDifference) / maximumDifference : 0
    }

    private static func decodedPixels(at url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotEvidenceError.invalidImage(url.path)
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw ScreenshotEvidenceError.invalidImage(url.path)
        }
        return (width, height, pixels)
    }
}

enum ViewerShortcutEvidenceValidator {
    static let minimumOrbitPanZoomDistance = 0.0005
    static let minimumFitDistance = 0.0003
    static let maximumResetDistance = 0.001

    static func validate(_ evidence: ViewerShortcutVerificationEvidence) throws {
        let grouped = Dictionary(grouping: evidence.groups, by: \.group)
        guard evidence.groups.count == ViewerShortcutGroup.allCases.count,
              ViewerShortcutGroup.allCases.allSatisfy({ grouped[$0]?.count == 1 }),
              isLowercaseSHA256(evidence.baselineScreenshotSHA256),
              evidence.baselineScreenshotSizeBytes > 0,
              (evidence.baselineScreenshotPath as NSString).isAbsolutePath,
              let orbit = grouped[.orbitPanZoom]?.first,
              let fit = grouped[.fit]?.first,
              let reset = grouped[.reset]?.first,
              evidence.groups.allSatisfy({
                  ($0.screenshotPath as NSString).isAbsolutePath
                      && $0.screenshotSizeBytes > 0
                      && isLowercaseSHA256($0.screenshotSHA256)
                      && $0.normalizedPixelDistance.isFinite
                      && $0.normalizedPixelDistance >= 0
                      && $0.normalizedPixelDistance <= 1
              }),
              orbit.screenshotSHA256 != evidence.baselineScreenshotSHA256,
              fit.screenshotSHA256 != orbit.screenshotSHA256,
              orbit.normalizedPixelDistance >= minimumOrbitPanZoomDistance,
              fit.normalizedPixelDistance >= minimumFitDistance,
              reset.normalizedPixelDistance <= maximumResetDistance,
              reset.normalizedPixelDistance <= orbit.normalizedPixelDistance * 0.5 + 0.0001 else {
            throw UIHarnessValidationError.invalid(
                "Viewer shortcut screenshots do not prove camera mutation and restoration."
            )
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
