import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotCaptureError: Error, LocalizedError {
    case appWindowNotFound(pid_t)
    case bitmapContext
    case destination
    case finalize
    case emptyFile
    case unexpectedDimensions(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)

    var errorDescription: String? {
        switch self {
        case .appWindowNotFound(let processIdentifier):
            return "ScreenCaptureKit could not find the app window for process \(processIdentifier)."
        case .bitmapContext:
            return "Could not create a bitmap context for screenshot analysis."
        case .destination:
            return "Could not create the PNG screenshot destination."
        case .finalize:
            return "Could not finalize the PNG screenshot."
        case .emptyFile:
            return "The PNG screenshot is empty."
        case .unexpectedDimensions(let expectedWidth, let expectedHeight, let actualWidth, let actualHeight):
            return "The PNG screenshot is \(actualWidth)x\(actualHeight), expected \(expectedWidth)x\(expectedHeight)."
        }
    }
}

struct ScreenshotCaptureResult {
    var luminance: Double
    var sizeBytes: Int64
    var sha256: String
}

enum ScreenshotCapture {
    static func capture(
        processIdentifier: pid_t,
        viewport: VerificationViewport,
        to url: URL
    ) async throws -> ScreenshotCaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows
            .filter({ $0.owningApplication?.processID == processIdentifier && $0.isOnScreen })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw ScreenshotCaptureError.appWindowNotFound(processIdentifier)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let expectedWidth = viewport.width
        let expectedHeight = viewport.height
        configuration.width = expectedWidth
        configuration.height = expectedHeight
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.finalize
        }
        let metadata = try ScreenshotEvidenceAnalyzer.metadata(at: url)
        guard metadata.sizeBytes > 0 else {
            throw ScreenshotCaptureError.emptyFile
        }
        guard metadata.width == expectedWidth, metadata.height == expectedHeight else {
            throw ScreenshotCaptureError.unexpectedDimensions(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: metadata.width,
                actualHeight: metadata.height
            )
        }
        return ScreenshotCaptureResult(
            luminance: try averageLuminance(of: image),
            sizeBytes: metadata.sizeBytes,
            sha256: metadata.sha256
        )
    }

    private static func averageLuminance(of image: CGImage) throws -> Double {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw ScreenshotCaptureError.bitmapContext }

        var total = 0.0
        var samples = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            samples += 1
        }
        guard samples > 0 else { throw ScreenshotCaptureError.emptyFile }
        return total / Double(samples)
    }
}
