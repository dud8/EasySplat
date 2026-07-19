import Foundation

public struct PackagedProjectMarker: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let releaseVerificationTokenSHA256: String
    public let appVersion: String
    public let executablePath: String
    public let executableBytes: UInt64
    public let executableSHA256: String
    public let toolchainRoot: String
    public let requestedCapabilities: [String]
    public let inputPath: String
    public let inputManifestSHA256: String
    public let projectRoot: String
    public let outputPlyPath: String
    public let outputBytes: UInt64
    public let outputVertices: Int
    public let outputFormat: String
    public let outputSHA256: String

    public init(
        schemaVersion: Int,
        releaseVerificationTokenSHA256: String,
        appVersion: String,
        executablePath: String,
        executableBytes: UInt64,
        executableSHA256: String,
        toolchainRoot: String,
        requestedCapabilities: [String],
        inputPath: String,
        inputManifestSHA256: String,
        projectRoot: String,
        outputPlyPath: String,
        outputBytes: UInt64,
        outputVertices: Int,
        outputFormat: String,
        outputSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.releaseVerificationTokenSHA256 = releaseVerificationTokenSHA256
        self.appVersion = appVersion
        self.executablePath = executablePath
        self.executableBytes = executableBytes
        self.executableSHA256 = executableSHA256
        self.toolchainRoot = toolchainRoot
        self.requestedCapabilities = requestedCapabilities
        self.inputPath = inputPath
        self.inputManifestSHA256 = inputManifestSHA256
        self.projectRoot = projectRoot
        self.outputPlyPath = outputPlyPath
        self.outputBytes = outputBytes
        self.outputVertices = outputVertices
        self.outputFormat = outputFormat
        self.outputSHA256 = outputSHA256
    }
}

public enum PackagedProjectMarkerCodecError: Error, LocalizedError, Equatable {
    case invalidSchema
    case noncanonical

    public var errorDescription: String? {
        switch self {
        case .invalidSchema:
            return "The packaged-app marker is not strict schema 3 evidence."
        case .noncanonical:
            return "The packaged-app marker is not in canonical schema 3 form."
        }
    }
}

public enum PackagedProjectMarkerCodec {
    private static let expectedKeys: Set<String> = [
        "schemaVersion",
        "releaseVerificationTokenSHA256",
        "appVersion",
        "executablePath",
        "executableBytes",
        "executableSHA256",
        "toolchainRoot",
        "requestedCapabilities",
        "inputPath",
        "inputManifestSHA256",
        "projectRoot",
        "outputPlyPath",
        "outputBytes",
        "outputVertices",
        "outputFormat",
        "outputSHA256",
    ]

    public static func encodeCanonical(_ marker: PackagedProjectMarker) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(marker)
        guard try decodeCanonical(data) == marker else {
            throw PackagedProjectMarkerCodecError.invalidSchema
        }
        return data
    }

    public static func decodeCanonical(_ data: Data) throws -> PackagedProjectMarker {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marker = try? JSONDecoder().decode(PackagedProjectMarker.self, from: data) else {
            throw PackagedProjectMarkerCodecError.invalidSchema
        }
        guard Set(object.keys) == expectedKeys,
              marker.schemaVersion == 3,
              isLowercaseSHA256(marker.releaseVerificationTokenSHA256),
              isSafeAppVersion(marker.appVersion),
              [
                marker.executablePath,
                marker.toolchainRoot,
                marker.inputPath,
                marker.projectRoot,
                marker.outputPlyPath,
              ].allSatisfy(hasNoASCIIControlCharacters),
              (marker.executablePath as NSString).isAbsolutePath,
              marker.executableBytes > 0,
              isLowercaseSHA256(marker.executableSHA256),
              (marker.toolchainRoot as NSString).isAbsolutePath,
              (marker.inputPath as NSString).isAbsolutePath,
              (marker.projectRoot as NSString).isAbsolutePath,
              (marker.outputPlyPath as NSString).isAbsolutePath,
              marker.requestedCapabilities == marker.requestedCapabilities.sorted(),
              Set(marker.requestedCapabilities).count == marker.requestedCapabilities.count,
              !marker.requestedCapabilities.isEmpty,
              isLowercaseSHA256(marker.inputManifestSHA256),
              marker.outputBytes > 0,
              marker.outputVertices > 0,
              ["ascii", "binary_little_endian", "binary_big_endian"]
                .contains(marker.outputFormat),
              isLowercaseSHA256(marker.outputSHA256) else {
            throw PackagedProjectMarkerCodecError.invalidSchema
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(marker) == data else {
            throw PackagedProjectMarkerCodecError.noncanonical
        }
        return marker
    }

    private static func hasNoASCIIControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isSafeAppVersion(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$",
            options: .regularExpression
        ) != nil
    }
}
