import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class RawPhotoDecoderTests: XCTestCase {
    func testDecoderSourceUsesOnlyMacOS15CoreImageDeclarationsAndLocalSendability() throws {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: coreRoot.appendingPathComponent(
                "Sources/EasySplatCore/Video/RawPhotoDecoder.swift"
            ),
            encoding: .utf8
        )

        for unavailableDeclaration in [
            "isHighlightRecoverySupported",
            "isHighlightRecoveryEnabled",
        ] {
            XCTAssertFalse(
                source.contains(unavailableDeclaration),
                "The macOS 15 / Xcode 16.4 SDK does not declare \(unavailableDeclaration)."
            )
        }
        XCTAssertTrue(
            source.contains("struct RawPhotoDecoder: RawPhotoDecoding, @unchecked Sendable"),
            "CIContext lacks its Sendable annotation in the macOS 15 SDK; localize that audited compatibility promise to RawPhotoDecoder."
        )
        XCTAssertFalse(
            source.contains("@preconcurrency import CoreImage"),
            "Do not suppress CoreImage concurrency checking for the whole source file."
        )
    }

    func testProductionSettingsAreFixedSDRSRGBEightBitPNG() {
        let settings = RawDevelopmentSettings.production(maximumPixelDimension: 4_096)

        XCTAssertFalse(settings.draftModeEnabled)
        XCTAssertTrue(settings.lensCorrectionEnabled)
        XCTAssertTrue(settings.highlightRecoveryEnabled)
        XCTAssertEqual(settings.extendedDynamicRangeAmount, 0)
        XCTAssertEqual(settings.outputTypeIdentifier, UTType.png.identifier)
        XCTAssertEqual(settings.outputColorSpace, "sRGB IEC61966-2.1")
        XCTAssertEqual(settings.outputBitDepth, 8)
    }

    func testOrientedOutputDimensionsCoverAllExifOrientations() {
        for orientation in 1...8 {
            let dimensions = RawPhotoDecoder.orientedDimensions(
                width: 6_000,
                height: 4_000,
                orientation: orientation
            )
            if [5, 6, 7, 8].contains(orientation) {
                XCTAssertEqual(dimensions, RawPixelDimensions(width: 4_000, height: 6_000))
            } else {
                XCTAssertEqual(dimensions, RawPixelDimensions(width: 6_000, height: 4_000))
            }
        }
    }

    func testOutputValidationRejectsUntaggedOrWrongColorSpacePNG() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("developed.png")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: output,
            size: 16,
            value: 90,
            utType: .png
        ))

        XCTAssertThrowsError(try RawPhotoDecoder.validateControlledOutput(
            at: output,
            expectedMaximumPixelDimension: 16,
            expectedProperties: [kCGImagePropertyOrientation: 1]
        ))
    }

    func testSanitizedOutputPropertiesRetainOnlyControlledCameraMetadata() throws {
        let properties: [AnyHashable: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 39.0],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: " Camera Maker ",
                kCGImagePropertyTIFFModel: "Camera Model",
                kCGImagePropertyTIFFArtist: "Private Owner",
                kCGImagePropertyTIFFCopyright: "Private Copyright",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:19 12:34:56",
                kCGImagePropertyExifBodySerialNumber: "SECRET-SERIAL",
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifFocalLenIn35mmFilm: 52,
                kCGImagePropertyExifLensModel: "Prime 35mm",
                kCGImagePropertyExifMakerNote: Data([1, 2, 3]),
            ],
            "UnknownPrivateDictionary": ["owner": "secret"],
        ]

        let sanitized = RawPhotoDecoder.sanitizedOutputProperties(from: properties)

        XCTAssertEqual(sanitized[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(
            sanitized[kCGImagePropertyTIFFDictionary] as? [CFString: String],
            [
                kCGImagePropertyTIFFMake: "Camera Maker",
                kCGImagePropertyTIFFModel: "Camera Model",
            ]
        )
        let exif = try XCTUnwrap(sanitized[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue, 35)
        XCTAssertEqual((exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue, 52)
        XCTAssertEqual(exif[kCGImagePropertyExifLensModel] as? String, "Prime 35mm")
        XCTAssertEqual(exif.count, 3)
        XCTAssertEqual(sanitized.count, 3)
    }

    func testControlledOutputValidationRequiresExactSanitizedCameraMetadataAndOrientationOne() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Camera Maker",
                kCGImagePropertyTIFFModel: "Camera Model",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifFocalLenIn35mmFilm: 52,
                kCGImagePropertyExifLensModel: "Prime 35mm",
            ] as [CFString: Any],
        ]
        let valid = root.appendingPathComponent("valid.png")
        try writeRGBPNG(at: valid, properties: expected)
        XCTAssertNoThrow(try RawPhotoDecoder.validateControlledOutput(
            at: valid,
            expectedMaximumPixelDimension: 16,
            expectedProperties: expected
        ))

        var wrongOrientation = expected
        wrongOrientation[kCGImagePropertyOrientation] = 6
        let invalid = root.appendingPathComponent("wrong-orientation.png")
        try writeRGBPNG(at: invalid, properties: wrongOrientation)
        XCTAssertThrowsError(try RawPhotoDecoder.validateControlledOutput(
            at: invalid,
            expectedMaximumPixelDimension: 16,
            expectedProperties: expected
        ))

        var unexpectedCameraMetadata = expected
        var unexpectedTIFF = try XCTUnwrap(
            expected[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        )
        unexpectedTIFF[kCGImagePropertyTIFFArtist] = "Private Owner"
        unexpectedCameraMetadata[kCGImagePropertyTIFFDictionary] = unexpectedTIFF
        let privateMetadata = root.appendingPathComponent("private-metadata.png")
        try writeRGBPNG(at: privateMetadata, properties: unexpectedCameraMetadata)
        XCTAssertThrowsError(try RawPhotoDecoder.validateControlledOutput(
            at: privateMetadata,
            expectedMaximumPixelDimension: 16,
            expectedProperties: expected
        ))
    }
}

private func writeRGBPNG(at url: URL, properties: [CFString: Any]) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 64,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}
