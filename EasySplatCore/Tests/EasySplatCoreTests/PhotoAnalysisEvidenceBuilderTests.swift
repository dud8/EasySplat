import CoreGraphics
import XCTest
@testable import EasySplatCore

final class PhotoAnalysisEvidenceBuilderTests: XCTestCase {
    func testBuildProducesStableVersionedEvidenceFromOrientedPixels() throws {
        let image = try makeImage(width: 40, height: 20) { x, y in
            (
                UInt8((x * 7 + y * 3) % 256),
                UInt8((x * 2 + y * 11) % 256),
                UInt8((x * 13 + y * 5) % 256)
            )
        }

        let first = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "a", count: 64),
            orientedImage: image
        )
        let second = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "a", count: 64),
            orientedImage: image
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.spatialDescriptor.count, PhotoAnalysisEvidence.spatialDescriptorLength)
        XCTAssertEqual(first.analysisRecipeVersion, PhotoAnalysisEvidenceBuilder.recipeVersion)
        XCTAssertEqual(first.analysisRecipeSHA256, PhotoAnalysisEvidenceBuilder.recipeSHA256)
        XCTAssertEqual(first.proxyPixelWidth, 256)
        XCTAssertEqual(first.proxyPixelHeight, 128)
        XCTAssertEqual(first.proxyPixelSHA256.count, 64)
        XCTAssertTrue(first.proxyPixelSHA256.allSatisfy(\.isHexDigit))
    }

    func testBuildPreservesPortraitAspectWithoutStretching() throws {
        let image = try makeImage(width: 20, height: 40) { x, y in
            (UInt8(x * 8), UInt8(y * 4), UInt8((x + y) * 3))
        }

        let evidence = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "b", count: 64),
            orientedImage: image
        )

        XCTAssertEqual(evidence.proxyPixelWidth, 128)
        XCTAssertEqual(evidence.proxyPixelHeight, 256)
    }

    func testBuildDistinguishesDifferentSpatialLayoutsWithTheSameGlobalColors() throws {
        let vertical = try makeImage(width: 64, height: 64) { x, _ in
            x < 32 ? (UInt8(20), UInt8(80), UInt8(220)) : (UInt8(230), UInt8(170), UInt8(30))
        }
        let horizontal = try makeImage(width: 64, height: 64) { _, y in
            y < 32 ? (UInt8(20), UInt8(80), UInt8(220)) : (UInt8(230), UInt8(170), UInt8(30))
        }

        let verticalEvidence = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "c", count: 64),
            orientedImage: vertical
        )
        let horizontalEvidence = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "d", count: 64),
            orientedImage: horizontal
        )

        XCTAssertNotEqual(verticalEvidence.spatialDescriptor, horizontalEvidence.spatialDescriptor)
        XCTAssertNotEqual(verticalEvidence.proxyPixelSHA256, horizontalEvidence.proxyPixelSHA256)
    }

    func testBuildQualityBucketPenalizesFlatClippedInput() throws {
        let detailed = try makeImage(width: 64, height: 64) { x, y in
            let value: UInt8 = (x + y).isMultiple(of: 2) ? 48 : 208
            return (value, value, value)
        }
        let clipped = try makeImage(width: 64, height: 64) { _, _ in
            (UInt8(255), UInt8(255), UInt8(255))
        }

        let detailedEvidence = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "e", count: 64),
            orientedImage: detailed
        )
        let clippedEvidence = try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: String(repeating: "f", count: 64),
            orientedImage: clipped
        )

        XCTAssertGreaterThan(detailedEvidence.qualityBucket, clippedEvidence.qualityBucket)
    }

    func testBuildRejectsInvalidSourceDigest() throws {
        let image = try makeImage(width: 8, height: 8) { _, _ in
            (UInt8(80), UInt8(90), UInt8(100))
        }

        XCTAssertThrowsError(try PhotoAnalysisEvidenceBuilder.build(
            sourceSHA256: "not-a-digest",
            orientedImage: image
        )) { error in
            XCTAssertEqual(error as? PhotoAnalysisEvidenceBuilder.Error, .invalidSourceSHA256)
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = value.0
                bytes[offset + 1] = value.1
                bytes[offset + 2] = value.2
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }
}
