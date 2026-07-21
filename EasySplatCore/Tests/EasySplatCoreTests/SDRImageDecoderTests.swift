#if canImport(XCTest)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class SDRImageDecoderTests: XCTestCase {
    func testSamsungHeadroomFallbackUsesSDRBridgeWithoutLosingVisiblePixels() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("adaptive-hdr-source.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: sourceURL,
            size: 64,
            value: 96,
            utType: .jpeg
        ))
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(sourceURL as CFURL, nil)
        )
        var properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        )
        properties[SDRImageDecoder.imageHeadroomPropertyKey] = "4.924578"

        XCTAssertEqual(
            SDRImageDecoder.bridgeReason(
                hasHDRGainMap: false,
                hasISOGainMap: false,
                properties: properties
            ),
            .extendedDynamicRangeHeadroom
        )

        let decoded = try XCTUnwrap(SDRImageDecoder.createOrientedThumbnail(
            source: source,
            properties: properties,
            maximumPixelDimension: 32
        ))
        let score = FrameScoring.scoreFrame(cgImage: decoded)

        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertGreaterThan(score.brightness, 0.25)
        XCTAssertLessThan(score.brightness, 0.5)
    }

    func testPublicGainMapDetectionTakesPriorityOverHeadroomFallback() {
        XCTAssertEqual(
            SDRImageDecoder.bridgeReason(
                hasHDRGainMap: true,
                hasISOGainMap: false,
                properties: [:]
            ),
            .hdrGainMap
        )
        XCTAssertEqual(
            SDRImageDecoder.bridgeReason(
                hasHDRGainMap: false,
                hasISOGainMap: true,
                properties: [SDRImageDecoder.imageHeadroomPropertyKey: 4.9]
            ),
            .isoGainMap
        )
    }

    func testOrdinaryJPEGBypassesSDRBridge() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("ordinary.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: sourceURL,
            size: 24,
            value: 128,
            utType: .jpeg
        ))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        XCTAssertNil(SDRImageDecoder.bridgeReason(source: source, properties: properties))
        let decoded = try XCTUnwrap(SDRImageDecoder.createOrientedThumbnail(
            source: source,
            properties: properties,
            maximumPixelDimension: 12
        ))
        XCTAssertEqual(decoded.width, 12)
        XCTAssertEqual(decoded.height, 12)
        XCTAssertGreaterThan(FrameScoring.scoreFrame(cgImage: decoded).brightness, 0.4)
    }

    func testBridgedThumbnailAppliesExifOrientationOnceAndRespectsMaximumDimension() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("portrait-rotated.jpg")
        try writeOrientedJPEG(
            to: sourceURL,
            width: 8,
            height: 12,
            orientation: 6
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        var properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        properties[SDRImageDecoder.imageHeadroomPropertyKey] = "4.924578"

        let decoded = try XCTUnwrap(SDRImageDecoder.createOrientedThumbnail(
            source: source,
            properties: properties,
            maximumPixelDimension: 10
        ))

        XCTAssertEqual(decoded.width, 10)
        XCTAssertEqual(decoded.height, 7)
    }

    func testOnlyFiniteHeadroomAboveSDRRequestsTheFallbackBridge() {
        let key = SDRImageDecoder.imageHeadroomPropertyKey
        XCTAssertNil(SDRImageDecoder.bridgeReason(
            hasHDRGainMap: false,
            hasISOGainMap: false,
            properties: [:]
        ))
        XCTAssertNil(SDRImageDecoder.bridgeReason(
            hasHDRGainMap: false,
            hasISOGainMap: false,
            properties: [key: 1]
        ))
        XCTAssertNil(SDRImageDecoder.bridgeReason(
            hasHDRGainMap: false,
            hasISOGainMap: false,
            properties: [key: "invalid"]
        ))
        XCTAssertEqual(
            SDRImageDecoder.bridgeReason(
                hasHDRGainMap: false,
                hasISOGainMap: false,
                properties: [key: 1.01]
            ),
            .extendedDynamicRangeHeadroom
        )
        XCTAssertEqual(
            SDRImageDecoder.bridgeReason(
                hasHDRGainMap: false,
                hasISOGainMap: false,
                properties: [key: "4.924578"]
            ),
            .extendedDynamicRangeHeadroom
        )
    }

    private func writeOrientedJPEG(
        to url: URL,
        width: Int,
        height: Int,
        orientation: Int
    ) throws {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = x < width / 2 ? 224 : 32
                pixels[offset + 1] = y < height / 2 ? 160 : 48
                pixels[offset + 2] = 96
                pixels[offset + 3] = 255
            }
        }
        let image = try pixels.withUnsafeMutableBytes { raw -> CGImage in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
