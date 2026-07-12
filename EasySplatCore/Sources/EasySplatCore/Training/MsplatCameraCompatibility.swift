import Foundation

enum MsplatCameraCompatibility {
    enum Error: Swift.Error {
        case invalidCameraModel
    }

    static func requiresUndistortion(modelDirectory: URL) throws -> Bool {
        let camerasURL = modelDirectory.appendingPathComponent("cameras.txt")
        let values = try camerasURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 1_048_576 else {
            throw Error.invalidCameraModel
        }

        let contents = try String(contentsOf: camerasURL, encoding: .utf8)
        var foundCamera = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5 else { throw Error.invalidCameraModel }
            foundCamera = true
            let model = String(fields[1])
            let parameters = fields.dropFirst(4).compactMap { Double($0) }
            guard parameters.count == fields.count - 4,
                  parameters.allSatisfy(\.isFinite) else {
                throw Error.invalidCameraModel
            }
            let distortionParameters: ArraySlice<Double>
            switch model {
            case "SIMPLE_PINHOLE" where parameters.count == 3,
                 "PINHOLE" where parameters.count == 4:
                distortionParameters = []
            case "SIMPLE_RADIAL" where parameters.count == 4:
                distortionParameters = parameters[3...]
            case "RADIAL" where parameters.count == 5:
                distortionParameters = parameters[3...]
            case "OPENCV" where parameters.count == 8:
                distortionParameters = parameters[4...]
            default:
                return true
            }
            if distortionParameters.contains(where: { abs($0) > 1e-12 }) { return true }
        }
        guard foundCamera else { throw Error.invalidCameraModel }
        return false
    }
}
