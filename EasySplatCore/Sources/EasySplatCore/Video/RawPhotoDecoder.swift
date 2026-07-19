import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct RawPixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct RawCompanionEvidence: Equatable, Sendable {
    struct Capture: Equatable, Sendable {
        let cameraMake: String
        let cameraModel: String
        let bodySerialNumber: String
        let originalDateTime: String
        let originalSubsecond: String
        let exposureTime: Double
        let aperture: Double?
        let isoSpeeds: [Double]?
        let focalLength: Double?
        let focalLength35mm: Double?
        let lensModel: String?
    }

    let imageUniqueID: String?
    let capture: Capture?

    func matches(_ other: RawCompanionEvidence) -> Bool {
        if let imageUniqueID, let otherID = other.imageUniqueID {
            return imageUniqueID == otherID
        }
        guard let capture, let otherCapture = other.capture else { return false }
        return capture == otherCapture
    }
}

struct RawCompanionCandidate: Equatable, Sendable {
    let relativePath: String
    let typeIdentifier: String
    let isRaw: Bool
    let dimensions: RawPixelDimensions
    let orientation: Int
    let evidence: RawCompanionEvidence
}

struct RawPhotoInspection: Equatable, Sendable {
    let decoderVersion: String
    let nativeDimensions: RawPixelDimensions
    let sourceOrientation: Int
    let proxySHA256: String
    let analysisMeasurements: PhotoAnalysisMeasurements
    let companionEvidence: RawCompanionEvidence?
}

struct RawPhotoDevelopment: Equatable, Sendable {
    let evidence: RawDevelopmentEvidence
    let controlledDimensions: RawPixelDimensions
}

enum RawPhotoDecodingError: Error, Equatable, Sendable {
    case unsupportedOrCorrupt
    case invalidDimensions
    case renderFailed
    case invalidControlledOutput
}

protocol RawPhotoDecoding: Sendable {
    func inspect(stagedSource: URL, maximumProxyDimension: Int) throws -> RawPhotoInspection
    func develop(
        stagedSource: URL,
        destination: URL,
        maximumPixelDimension: Int
    ) throws -> RawPhotoDevelopment
}

// CIContext is safe to reuse across operations, but macOS 15 SDKs predate its Sendable annotation.
struct RawPhotoDecoder: RawPhotoDecoding, @unchecked Sendable {
    static let decoderIdentifier = "com.apple.CoreImage.CIRAWFilter"
    static let outputColorSpaceName = "sRGB IEC61966-2.1"

    private let context: CIContext
    private let outputColorSpace: CGColorSpace

    init() {
        outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(
                mtlDevice: device,
                options: [
                    .workingColorSpace: outputColorSpace,
                    .outputColorSpace: outputColorSpace,
                    .cacheIntermediates: false,
                ]
            )
        } else {
            context = CIContext(options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: outputColorSpace,
                .outputColorSpace: outputColorSpace,
                .cacheIntermediates: false,
            ])
        }
    }

    func inspect(stagedSource: URL, maximumProxyDimension: Int) throws -> RawPhotoInspection {
        try Task.checkCancellation()
        guard maximumProxyDimension > 0,
              let filter = CIRAWFilter(imageURL: stagedSource) else {
            throw RawPhotoDecodingError.unsupportedOrCorrupt
        }
        let native = try Self.validNativeDimensions(filter.nativeSize)
        let orientation = Int(filter.orientation.rawValue)
        guard (1...8).contains(orientation) else { throw RawPhotoDecodingError.invalidDimensions }
        filter.isDraftModeEnabled = true
        filter.scaleFactor = min(1, Float(maximumProxyDimension) / Float(max(native.width, native.height)))
        filter.extendedDynamicRangeAmount = 0
        guard let output = filter.outputImage else { throw RawPhotoDecodingError.unsupportedOrCorrupt }
        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0,
              extent.width <= CGFloat(maximumProxyDimension + 2),
              extent.height <= CGFloat(maximumProxyDimension + 2),
              let proxy = context.createCGImage(
                output,
                from: extent,
                format: .RGBA8,
                colorSpace: outputColorSpace
              ),
              let provider = proxy.dataProvider,
              let bytes = provider.data else {
            throw RawPhotoDecodingError.renderFailed
        }
        try Task.checkCancellation()
        let analysisMeasurements: PhotoAnalysisMeasurements
        do {
            analysisMeasurements = try PhotoAnalysisEvidenceBuilder.measure(
                orientedImage: proxy
            )
        } catch {
            throw RawPhotoDecodingError.renderFailed
        }
        let digest = SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
        return RawPhotoInspection(
            decoderVersion: filter.decoderVersion.rawValue,
            nativeDimensions: native,
            sourceOrientation: orientation,
            proxySHA256: digest,
            analysisMeasurements: analysisMeasurements,
            companionEvidence: Self.companionEvidence(properties: filter.properties)
        )
    }

    func develop(
        stagedSource: URL,
        destination: URL,
        maximumPixelDimension: Int
    ) throws -> RawPhotoDevelopment {
        try Task.checkCancellation()
        guard maximumPixelDimension > 0,
              let filter = CIRAWFilter(imageURL: stagedSource) else {
            throw RawPhotoDecodingError.unsupportedOrCorrupt
        }
        let native = try Self.validNativeDimensions(filter.nativeSize)
        let sourceOrientation = Int(filter.orientation.rawValue)
        guard (1...8).contains(sourceOrientation) else { throw RawPhotoDecodingError.invalidDimensions }
        let orientedNative = Self.orientedDimensions(
            width: native.width,
            height: native.height,
            orientation: sourceOrientation
        )
        let settings = RawDevelopmentSettings.production(maximumPixelDimension: maximumPixelDimension)
        filter.isDraftModeEnabled = settings.draftModeEnabled
        filter.scaleFactor = min(
            1,
            Float(maximumPixelDimension) / Float(max(orientedNative.width, orientedNative.height))
        )
        filter.isLensCorrectionEnabled = settings.lensCorrectionEnabled
        filter.luminanceNoiseReductionAmount = settings.luminanceNoiseReductionAmount
        filter.colorNoiseReductionAmount = settings.colorNoiseReductionAmount
        filter.sharpnessAmount = settings.sharpnessAmount
        filter.detailAmount = settings.detailAmount
        filter.moireReductionAmount = settings.moireReductionAmount
        filter.extendedDynamicRangeAmount = settings.extendedDynamicRangeAmount
        guard let output = filter.outputImage else { throw RawPhotoDecodingError.unsupportedOrCorrupt }
        let sanitizedProperties = Self.sanitizedOutputProperties(from: filter.properties)
        let controlledOutput = output.settingProperties(sanitizedProperties)
        let extent = controlledOutput.extent.integral
        guard extent.width > 0, extent.height > 0,
              extent.width <= CGFloat(maximumPixelDimension + 2),
              extent.height <= CGFloat(maximumPixelDimension + 2) else {
            throw RawPhotoDecodingError.invalidDimensions
        }
        do {
            try context.writePNGRepresentation(
                of: controlledOutput,
                to: destination,
                format: .RGBA8,
                colorSpace: outputColorSpace,
                options: [:]
            )
        } catch {
            throw RawPhotoDecodingError.renderFailed
        }
        try Task.checkCancellation()
        let dimensions = try Self.validateControlledOutput(
            at: destination,
            expectedMaximumPixelDimension: maximumPixelDimension,
            expectedProperties: sanitizedProperties
        )
        return RawPhotoDevelopment(
            evidence: RawDevelopmentEvidence(
                decoderIdentifier: Self.decoderIdentifier,
                decoderVersion: filter.decoderVersion.rawValue,
                settings: settings,
                nativePixelWidth: native.width,
                nativePixelHeight: native.height,
                sourceOrientation: sourceOrientation
            ),
            controlledDimensions: dimensions
        )
    }

    static func orientedDimensions(width: Int, height: Int, orientation: Int) -> RawPixelDimensions {
        [5, 6, 7, 8].contains(orientation)
            ? RawPixelDimensions(width: height, height: width)
            : RawPixelDimensions(width: width, height: height)
    }

    static func validateControlledOutput(
        at url: URL,
        expectedMaximumPixelDimension: Int,
        expectedProperties: [AnyHashable: Any]? = nil
    ) throws -> RawPixelDimensions {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1,
              expectedProperties.map({ cameraProperties(in: properties, exactlyMatch: $0) }) ?? true,
              width.intValue > 0,
              height.intValue > 0,
              max(width.intValue, height.intValue) <= expectedMaximumPixelDimension + 2,
              (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.bitsPerComponent == 8,
              image.colorSpace?.name == CGColorSpace.sRGB else {
            throw RawPhotoDecodingError.invalidControlledOutput
        }
        return RawPixelDimensions(width: width.intValue, height: height.intValue)
    }

    static func sanitizedOutputProperties(from properties: [AnyHashable: Any]) -> [AnyHashable: Any] {
        var sanitized: [AnyHashable: Any] = [kCGImagePropertyOrientation: 1]
        if let sourceTIFF = properties[kCGImagePropertyTIFFDictionary] as? [AnyHashable: Any] {
            var tiff: [AnyHashable: Any] = [:]
            if let make = boundedMetadataString(sourceTIFF[kCGImagePropertyTIFFMake]) {
                tiff[kCGImagePropertyTIFFMake] = make
            }
            if let model = boundedMetadataString(sourceTIFF[kCGImagePropertyTIFFModel]) {
                tiff[kCGImagePropertyTIFFModel] = model
            }
            if !tiff.isEmpty {
                sanitized[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        if let sourceExif = properties[kCGImagePropertyExifDictionary] as? [AnyHashable: Any] {
            var exif: [AnyHashable: Any] = [:]
            for key in [kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm] {
                if let value = boundedPositiveNumber(sourceExif[key]) {
                    exif[key] = value
                }
            }
            if let lensModel = boundedMetadataString(sourceExif[kCGImagePropertyExifLensModel]) {
                exif[kCGImagePropertyExifLensModel] = lensModel
            }
            if !exif.isEmpty {
                sanitized[kCGImagePropertyExifDictionary] = exif
            }
        }
        return sanitized
    }

    private static func cameraProperties(
        in actual: [CFString: Any],
        exactlyMatch expected: [AnyHashable: Any]
    ) -> Bool {
        let actualSanitized = sanitizedOutputProperties(from: actual)
        guard metadataDictionariesEqual(actualSanitized, expected) else { return false }
        let actualTIFF = actual[kCGImagePropertyTIFFDictionary] as? [AnyHashable: Any] ?? [:]
        let expectedTIFF = expected[kCGImagePropertyTIFFDictionary] as? [AnyHashable: Any] ?? [:]
        let actualExif = actual[kCGImagePropertyExifDictionary] as? [AnyHashable: Any] ?? [:]
        let expectedExif = expected[kCGImagePropertyExifDictionary] as? [AnyHashable: Any] ?? [:]
        let generatedTIFFKeys: Set<AnyHashable> = [kCGImagePropertyTIFFOrientation]
        let generatedExifKeys: Set<AnyHashable> = [
            kCGImagePropertyExifColorSpace,
            kCGImagePropertyExifPixelXDimension,
            kCGImagePropertyExifPixelYDimension,
        ]
        guard Set(actualTIFF.keys).subtracting(expectedTIFF.keys).isSubset(of: generatedTIFFKeys),
              Set(actualExif.keys).subtracting(expectedExif.keys).isSubset(of: generatedExifKeys) else {
            return false
        }
        for (key, value) in actual {
            guard value is [AnyHashable: Any] else { continue }
            if key != kCGImagePropertyTIFFDictionary,
               key != kCGImagePropertyExifDictionary,
               key != kCGImagePropertyPNGDictionary {
                return false
            }
        }
        return true
    }

    private static func metadataDictionariesEqual(
        _ lhs: [AnyHashable: Any],
        _ rhs: [AnyHashable: Any]
    ) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private static func boundedMetadataString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256, !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    private static func boundedPositiveNumber(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber,
              value.doubleValue.isFinite,
              value.doubleValue > 0,
              value.doubleValue <= 10_000 else {
            return nil
        }
        return value
    }

    private static func validNativeDimensions(_ size: CGSize) throws -> RawPixelDimensions {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 131_072, size.height <= 131_072 else {
            throw RawPhotoDecodingError.invalidDimensions
        }
        return RawPixelDimensions(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    static func companionEvidence(properties: [AnyHashable: Any]) -> RawCompanionEvidence? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let uniqueID = normalizedCompanionString(exif?[kCGImagePropertyExifImageUniqueID])
        let capture: RawCompanionEvidence.Capture?
        if let make = normalizedCompanionString(tiff?[kCGImagePropertyTIFFMake]),
           let model = normalizedCompanionString(tiff?[kCGImagePropertyTIFFModel]),
           let serial = normalizedCompanionString(exif?[kCGImagePropertyExifBodySerialNumber]),
           let captured = normalizedCompanionString(exif?[kCGImagePropertyExifDateTimeOriginal]),
           let subsecond = normalizedCompanionString(exif?[kCGImagePropertyExifSubsecTimeOriginal]),
           let exposure = positiveDouble(exif?[kCGImagePropertyExifExposureTime]) {
            let focalLength = positiveDouble(exif?[kCGImagePropertyExifFocalLength])
            let focal35 = positiveDouble(exif?[kCGImagePropertyExifFocalLenIn35mmFilm])
            let lens = normalizedCompanionString(exif?[kCGImagePropertyExifLensModel])
            if focalLength != nil || focal35 != nil || lens != nil {
                capture = RawCompanionEvidence.Capture(
                    cameraMake: make,
                    cameraModel: model,
                    bodySerialNumber: serial,
                    originalDateTime: captured,
                    originalSubsecond: subsecond,
                    exposureTime: exposure,
                    aperture: positiveDouble(exif?[kCGImagePropertyExifFNumber]),
                    isoSpeeds: isoSpeeds(exif?[kCGImagePropertyExifISOSpeedRatings]),
                    focalLength: focalLength,
                    focalLength35mm: focal35,
                    lensModel: lens
                )
            } else {
                capture = nil
            }
        } else {
            capture = nil
        }
        guard uniqueID != nil || capture != nil else { return nil }
        return RawCompanionEvidence(imageUniqueID: uniqueID, capture: capture)
    }

    static func areCompanions(_ first: RawCompanionCandidate, _ second: RawCompanionCandidate) -> Bool {
        guard first.isRaw != second.isRaw else { return false }
        let rendered = first.isRaw ? second : first
        guard isEligibleRenderedCompanionType(rendered.typeIdentifier),
              normalizedRelativeParent(first.relativePath) == normalizedRelativeParent(second.relativePath),
              normalizedStem(first.relativePath) == normalizedStem(second.relativePath),
              orientedDimensions(
                width: first.dimensions.width,
                height: first.dimensions.height,
                orientation: first.orientation
              ) == orientedDimensions(
                width: second.dimensions.width,
                height: second.dimensions.height,
                orientation: second.orientation
              ) else {
            return false
        }
        return first.evidence.matches(second.evidence)
    }

    static func companionPathKey(_ relativePath: String) -> String {
        normalizedRelativeParent(relativePath) + "\0" + normalizedStem(relativePath)
    }

    private static func isEligibleRenderedCompanionType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .jpeg)
            || type.conforms(to: .heic)
            || identifier == "public.heif"
    }

    private static func normalizedRelativeParent(_ relativePath: String) -> String {
        (relativePath as NSString).deletingLastPathComponent.precomposedStringWithCanonicalMapping
    }

    private static func normalizedStem(_ relativePath: String) -> String {
        let leaf = (relativePath as NSString).lastPathComponent as NSString
        return leaf.deletingPathExtension.precomposedStringWithCanonicalMapping
    }

    private static func normalizedCompanionString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, normalized.utf8.count <= 256, !normalized.contains("\0") else {
            return nil
        }
        return normalized
    }

    private static func positiveDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue > 0 else {
            return nil
        }
        return number.doubleValue
    }

    private static func isoSpeeds(_ value: Any?) -> [Double]? {
        let values: [NSNumber]
        if let array = value as? [NSNumber] {
            values = array
        } else if let number = value as? NSNumber {
            values = [number]
        } else {
            return nil
        }
        let speeds = values.map(\.doubleValue)
        guard !speeds.isEmpty, speeds.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return speeds
    }
}
