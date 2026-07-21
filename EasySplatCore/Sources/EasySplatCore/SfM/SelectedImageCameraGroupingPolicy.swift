import Foundation
import ImageIO

struct SelectedImagePixelDimensions: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
}

enum SelectedImageCameraGroupingPolicy {
    enum Error: Swift.Error {
        case duplicateImageName(String)
        case unreadableImage(String)
    }

    enum Mode {
        case shared
        case colmapAutomatic
        case perImage
    }

    private enum ExpectedGroup: Hashable {
        case shared
        case colmap(String)
        case image(String)
    }

    private struct ImageProperties {
        let name: String
        let width: Int
        let height: Int
        let colmapCameraModel: String?
    }

    static func hasUniformPixelDimensions(_ images: [URL]) throws -> Bool {
        try uniformPixelDimensions(images) != nil
    }

    static func uniformPixelDimensions(
        _ images: [URL]
    ) throws -> SelectedImagePixelDimensions? {
        var expectedDimensions: SelectedImagePixelDimensions?
        for image in images {
            let imageProperties = try properties(of: image)
            let dimensions = SelectedImagePixelDimensions(
                width: imageProperties.width,
                height: imageProperties.height
            )
            if let expectedDimensions,
               expectedDimensions.width != dimensions.width
                || expectedDimensions.height != dimensions.height {
                return nil
            }
            expectedDimensions = dimensions
        }
        return expectedDimensions
    }

    static func cameraIDsMatchExpectedGroups(
        images: [URL],
        mode: Mode,
        cameraIDsByImageName: [String: Int]
    ) throws -> Bool {
        var seenNames = Set<String>()
        var expectedToActual: [ExpectedGroup: Int] = [:]
        var actualToExpected: [Int: ExpectedGroup] = [:]
        for image in images {
            let imageProperties = try properties(of: image)
            guard seenNames.insert(imageProperties.name).inserted else {
                throw Error.duplicateImageName(imageProperties.name)
            }
            guard let actualCameraID = cameraIDsByImageName[imageProperties.name] else {
                return false
            }
            let expectedGroup: ExpectedGroup
            switch mode {
            case .shared:
                expectedGroup = .shared
            case .colmapAutomatic:
                if let cameraModel = imageProperties.colmapCameraModel {
                    expectedGroup = .colmap(cameraModel)
                } else {
                    // COLMAP's automatic ImageReader creates a fresh camera when
                    // it cannot construct its complete EXIF camera signature.
                    expectedGroup = .image(imageProperties.name)
                }
            case .perImage:
                expectedGroup = .image(imageProperties.name)
            }

            if let existing = expectedToActual[expectedGroup],
               existing != actualCameraID {
                return false
            }
            if let existing = actualToExpected[actualCameraID],
               existing != expectedGroup {
                return false
            }
            expectedToActual[expectedGroup] = actualCameraID
            actualToExpected[actualCameraID] = expectedGroup
        }
        return seenNames == Set(cameraIDsByImageName.keys)
    }

    private static func properties(of image: URL) throws -> ImageProperties {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw Error.unreadableImage(image.lastPathComponent)
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let focalNumber = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber
            ?? exif?[kCGImagePropertyExifFocalLength] as? NSNumber
        let focalLength = focalNumber.map { Float($0.doubleValue) }
        let cameraModel: String?
        if let make,
           let model,
           let focalLength,
           focalLength.isFinite {
            // COLMAP reads this EXIF value into a float, then uses the exact
            // composite key produced by `%.6f`. Reproduce that key rather than
            // comparing its fields independently: rounding and delimiters are
            // part of ImageReader's grouping behavior.
            let formattedFocalLength = String(
                format: "%.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(focalLength)
            )
            cameraModel = "\(make)-\(model)-\(formattedFocalLength)-\(width)x\(height)"
        } else {
            cameraModel = nil
        }
        return ImageProperties(
            name: image.lastPathComponent,
            width: width,
            height: height,
            colmapCameraModel: cameraModel
        )
    }
}
