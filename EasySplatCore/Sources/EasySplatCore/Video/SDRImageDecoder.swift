import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SDRImageDecoder {
    enum BridgeReason: Equatable {
        case hdrGainMap
        case isoGainMap
        case extendedDynamicRangeHeadroom
    }

    static var imageHeadroomPropertyKey: CFString { "Headroom" as CFString }

    static func bridgeReason(
        source: CGImageSource,
        properties: [CFString: Any]
    ) -> BridgeReason? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return bridgeReason(
            hasHDRGainMap: CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                index,
                kCGImageAuxiliaryDataTypeHDRGainMap
            ) != nil,
            hasISOGainMap: CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                index,
                kCGImageAuxiliaryDataTypeISOGainMap
            ) != nil,
            properties: properties
        )
    }

    static func bridgeReason(
        hasHDRGainMap: Bool,
        hasISOGainMap: Bool,
        properties: [CFString: Any]
    ) -> BridgeReason? {
        if hasHDRGainMap { return .hdrGainMap }
        if hasISOGainMap { return .isoGainMap }

        // Some Samsung adaptive-HDR JPEGs expose their gain-map headroom only
        // through ImageIO's top-level metadata, not either public auxiliary-data
        // type. Keep this narrow fallback until ImageIO identifies those files.
        let value = properties[imageHeadroomPropertyKey]
        let headroom: Double?
        if let number = value as? NSNumber {
            headroom = number.doubleValue
        } else if let string = value as? NSString {
            headroom = string.doubleValue
        } else {
            headroom = nil
        }
        guard let headroom, headroom.isFinite, headroom > 1 else { return nil }
        return .extendedDynamicRangeHeadroom
    }

    static func createOrientedThumbnail(
        source: CGImageSource,
        properties: [CFString: Any],
        maximumPixelDimension: Int
    ) -> CGImage? {
        guard maximumPixelDimension > 0 else { return nil }
        let decodeSource: CGImageSource
        if bridgeReason(source: source, properties: properties) != nil {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImageFromSource(
                destination,
                source,
                CGImageSourceGetPrimaryImageIndex(source),
                [
                    kCGImageDestinationImageMaxPixelSize: maximumPixelDimension,
                    kCGImageDestinationLossyCompressionQuality: 1.0,
                    kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToSDR,
                    kCGImageDestinationPreserveGainMap: false,
                ] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination),
                  let bridgedSource = CGImageSourceCreateWithData(data, nil) else {
                return nil
            }
            decodeSource = bridgedSource
        } else {
            decodeSource = source
        }
        return CGImageSourceCreateThumbnailAtIndex(
            decodeSource,
            CGImageSourceGetPrimaryImageIndex(decodeSource),
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                kCGImageSourceShouldCache: false,
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
            ] as CFDictionary
        )
    }
}
