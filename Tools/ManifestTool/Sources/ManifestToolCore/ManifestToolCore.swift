import CryptoKit
import Foundation

public struct ManifestDocument: Codable, Equatable {
    public enum ComponentRequirement: String, Codable, Equatable {
        case required
        case optional
    }

    public struct AppVersionRange: Codable, Equatable {
        public var minimum: String
        public var maximumExclusive: String?

        public init(minimum: String, maximumExclusive: String?) {
            self.minimum = minimum
            self.maximumExclusive = maximumExclusive
        }
    }

    public var schemaVersion: Int
    public var toolchainAPI: Int
    public var keyID: String
    public var version: String
    public var publishedAt: Date
    public var appVersionRange: AppVersionRange
    public var components: [Component]
    public var signatureEd25519: String

    public struct Component: Codable, Equatable {
        public var name: String
        public var capabilities: [String]
        public var url: String
        public var sha256: String
        public var sizeBytes: UInt64
        public var expandedSizeBytes: UInt64
        public var contents: [String]
        public var criticalFileHashes: [String: String]
        public var dependencies: [String]
        public var requirement: ComponentRequirement

        public init(
            name: String,
            capabilities: [String],
            url: String,
            sha256: String,
            sizeBytes: UInt64,
            expandedSizeBytes: UInt64? = nil,
            contents: [String],
            criticalFileHashes: [String: String],
            dependencies: [String],
            requirement: ComponentRequirement
        ) {
            self.name = name
            self.capabilities = capabilities
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.expandedSizeBytes = expandedSizeBytes ?? sizeBytes
            self.contents = contents
            self.criticalFileHashes = criticalFileHashes
            self.dependencies = dependencies
            self.requirement = requirement
        }
    }

    public init(
        schemaVersion: Int = 2,
        toolchainAPI: Int = 2,
        keyID: String,
        version: String,
        publishedAt: Date,
        appVersionRange: AppVersionRange,
        components: [Component],
        signatureEd25519: String
    ) {
        self.schemaVersion = schemaVersion
        self.toolchainAPI = toolchainAPI
        self.keyID = keyID
        self.version = version
        self.publishedAt = publishedAt
        self.appVersionRange = appVersionRange
        self.components = components
        self.signatureEd25519 = signatureEd25519
    }
}

public struct ManifestArtifactInput: Equatable {
    public var name: String
    public var artifactURL: String
    public var zipURL: URL
    public var contents: [String]
    public var capabilities: [String]
    public var dependencies: [String]
    public var requirement: ManifestDocument.ComponentRequirement
    public var criticalFilePaths: [String]
    public var deriveExactContents: Bool

    public init(
        name: String,
        artifactURL: String,
        zipURL: URL,
        capabilities: [String],
        dependencies: [String],
        requirement: ManifestDocument.ComponentRequirement,
        contents: [String] = [],
        criticalFilePaths: [String] = [],
        deriveExactContents: Bool = true
    ) {
        self.name = name
        self.artifactURL = artifactURL
        self.zipURL = zipURL
        self.contents = contents
        self.capabilities = capabilities
        self.dependencies = dependencies
        self.requirement = requirement
        self.criticalFilePaths = criticalFilePaths
        self.deriveExactContents = deriveExactContents
    }
}

public struct ReleaseSigningRequest: Codable, Equatable {
    public var schemaVersion: Int
    public var sourceRepository: String
    public var sourceCommit: String
    public var manifestSHA256: String
    public var manifest: ManifestDocument

    public init(
        schemaVersion: Int = 1,
        sourceRepository: String,
        sourceCommit: String,
        manifestSHA256: String,
        manifest: ManifestDocument
    ) {
        self.schemaVersion = schemaVersion
        self.sourceRepository = sourceRepository
        self.sourceCommit = sourceCommit
        self.manifestSHA256 = manifestSHA256
        self.manifest = manifest
    }
}

public enum ManifestBuilder {
    public static let maximumReleaseAssetBytes: UInt64 = 2_147_483_648
    public static let maximumCoreDownloadBytes: UInt64 = 2_500_000_000
    public static let maximumFullToolchainDownloadBytes: UInt64 = 6_000_000_000
    public static let maximumExpandedComponentBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    static let installStateFilename = ".easysplat_toolchain_state.json"

    public static func build(
        version: String,
        publishedAt: Date,
        appVersionRange: ManifestDocument.AppVersionRange,
        components: [ManifestArtifactInput],
        privateKeyBase64: String
    ) throws -> ManifestDocument {
        try requireValidToolchainVersion(version)
        guard validAppVersionRange(appVersionRange) else {
            throw NSError(
                domain: "ManifestTool",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey: "Schema-2 app version range must contain strict SemVer bounds with maximumExclusive greater than minimum."
                ]
            )
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.criticalFilePaths.isEmpty }) else {
            throw NSError(
                domain: "ManifestTool",
                code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey: "Schema-2 components must declare critical files to hash."
                ]
            )
        }
        let key = try privateKey(from: privateKeyBase64)
        let builtComponents = try components.map(makeComponent)
        try validateContentOwnership(builtComponents)
        let publicKeyData = key.publicKey.rawRepresentation
        let keyID = SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
        var manifest = ManifestDocument(
            keyID: keyID,
            version: version,
            publishedAt: publishedAt,
            appVersionRange: appVersionRange,
            components: builtComponents,
            signatureEd25519: ""
        )
        manifest.signatureEd25519 = try key.signature(for: canonicalData(for: manifest)).base64EncodedString()
        return manifest
    }

    public static func releaseComponentURLs(repository: String, version: String) -> [String: String] {
        let base = "https://github.com/\(repository)/releases/download/toolchain-v\(version)"
        return [
            "macos-arm64-core": "\(base)/toolchain-macos-arm64-\(version)-core.zip",
            "geometry-da3-base": "\(base)/toolchain-geometry-da3-base-\(version).zip",
            "geometry-da3-small": "\(base)/toolchain-geometry-da3-small-\(version).zip",
        ]
    }

    public static func prepareRelease(
        repository: String,
        sourceCommit: String,
        version: String,
        publishedAt: Date,
        appVersionRange: ManifestDocument.AppVersionRange,
        publicKeyBase64: String,
        components: [ManifestArtifactInput]
    ) throws -> ReleaseSigningRequest {
        try requireValidToolchainVersion(version)
        guard validAppVersionRange(appVersionRange) else {
            try releaseFailure("Release app version bounds are invalid.")
        }
        let publicKeyData = try validatedPublicKeyData(publicKeyBase64)
        let keyID = sha256Hex(data: publicKeyData)
        let builtComponents = try components.map(makeComponent)
        try validateContentOwnership(builtComponents)
        let manifest = ManifestDocument(
            keyID: keyID,
            version: version,
            publishedAt: publishedAt,
            appVersionRange: appVersionRange,
            components: builtComponents,
            signatureEd25519: ""
        )
        let request = ReleaseSigningRequest(
            sourceRepository: repository,
            sourceCommit: sourceCommit,
            manifestSHA256: sha256Hex(data: try canonicalData(for: manifest)),
            manifest: manifest
        )
        try validateReleaseSigningRequest(
            request,
            expectedRepository: repository,
            expectedSourceCommit: sourceCommit,
            expectedVersion: version,
            expectedAppVersionRange: appVersionRange,
            publicKeyData: publicKeyData
        )
        return request
    }

    public static func canonicalData(for request: ReleaseSigningRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(request)
    }

    public static func writeReleaseSigningRequest(
        _ request: ReleaseSigningRequest,
        to url: URL
    ) throws {
        try canonicalData(for: request).write(to: url, options: [.atomic])
    }

    public static func generateKeypair() -> (publicKeyBase64: String, privateKeyBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            privateKeyBase64: key.rawRepresentation.base64EncodedString()
        )
    }

    public static func canonicalData(for manifest: ManifestDocument) throws -> Data {
        var copy = manifest
        copy.signatureEd25519 = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    public static func verifySignature(for manifest: ManifestDocument, publicKeyBase64: String) -> Bool {
        guard let signatureData = Data(base64Encoded: manifest.signatureEd25519),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let canonical = try? canonicalData(for: manifest),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: canonical)
    }

    public static func verifyRelease(
        manifest: ManifestDocument,
        publicKeyBase64: String,
        expectedToolchainVersion: String,
        expectedAppVersion: String,
        expectedComponentURLs: [String: String],
        componentArchives: [String: URL]
    ) throws {
        func fail(_ message: String) throws -> Never {
            throw NSError(
                domain: "ManifestTool",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard manifest.schemaVersion == 2, manifest.toolchainAPI == 2 else {
            try fail("Release manifest must use schema 2 and toolchain API 2.")
        }
        guard semanticVersion(from: manifest.version) != nil,
              semanticVersion(from: expectedToolchainVersion) != nil,
              manifest.version == expectedToolchainVersion,
              appVersion(expectedAppVersion, isWithin: manifest.appVersionRange) else {
            try fail("Release manifest version or app compatibility range does not match the build.")
        }
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            try fail("Release public key is not valid base64.")
        }
        let expectedKeyID = SHA256.hash(data: publicKeyData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard manifest.keyID == expectedKeyID,
              verifySignature(for: manifest, publicKeyBase64: publicKeyBase64) else {
            try fail("Release manifest signature or key identifier is invalid.")
        }

        let componentsByName = Dictionary(grouping: manifest.components, by: \.name)
        let expectedNames = Set(expectedComponentURLs.keys)
        guard Set(componentsByName.keys) == expectedNames,
              componentsByName.values.allSatisfy({ $0.count == 1 }),
              Set(componentArchives.keys) == expectedNames else {
            try fail("Release manifest component set does not match the expected closure.")
        }
        try validateContentOwnership(manifest.components)

        for name in expectedNames.sorted() {
            guard let component = componentsByName[name]?.first,
                  let expectedURL = expectedComponentURLs[name],
                  let archiveURL = componentArchives[name],
                  component.url == expectedURL,
                  URL(string: component.url)?.scheme?.lowercased() == "https" else {
                try fail("Release component URL is missing, insecure, or unexpected: \(name)")
            }
            let size = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? UInt64 ?? 0
            guard size == component.sizeBytes,
                  try archiveExpandedSize(at: archiveURL) == component.expandedSizeBytes,
                  try sha256Hex(url: archiveURL) == component.sha256 else {
                try fail("Release component size or SHA-256 does not match the signed manifest: \(name)")
            }
            guard try archiveContents(at: archiveURL) == component.contents.sorted() else {
                try fail("Release component contents do not match the signed manifest: \(name)")
            }
            let hashes = try archiveCriticalFileHashes(
                zipURL: archiveURL,
                paths: component.criticalFileHashes.keys.sorted()
            )
            guard hashes == component.criticalFileHashes else {
                try fail("Release component critical-file hashes do not match: \(name)")
            }
        }
    }

    public static func writeManifest(_ manifest: ManifestDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }

    public static func sha256Hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateContentOwnership(_ components: [ManifestDocument.Component]) throws {
        let paths = components.flatMap(\.contents)
        let ownershipKeys = paths.map(pathOwnershipKey)
        let installStateKey = pathOwnershipKey(installStateFilename)
        guard Set(ownershipKeys).count == ownershipKeys.count,
              !ownershipKeys.contains(where: {
                  $0 == installStateKey || $0.hasPrefix(installStateKey + "/")
              }) else {
            throw NSError(
                domain: "ManifestTool",
                code: 13,
                userInfo: [
                    NSLocalizedDescriptionKey: "Release component content ownership overlaps or uses the reserved install-state path."
                ]
            )
        }
    }

    static func pathOwnershipKey(_ path: String) -> String {
        path
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func makeComponent(from input: ManifestArtifactInput) throws -> ManifestDocument.Component {
        let size = try FileManager.default.attributesOfItem(atPath: input.zipURL.path)[.size] as? UInt64 ?? 0
        guard size > 0, size < maximumReleaseAssetBytes else {
            throw NSError(
                domain: "ManifestTool",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey: "Release components must be smaller than GitHub's 2 GiB asset limit."
                ]
            )
        }
        let sha = try sha256Hex(url: input.zipURL)
        let contents = input.deriveExactContents ? try archiveContents(at: input.zipURL) : input.contents
        let expandedSize = try archiveExpandedSize(at: input.zipURL)
        var criticalFilePaths = Set(input.criticalFilePaths)
        if input.name == "macos-arm64-core" {
            criticalFilePaths.formUnion(
                ManifestToolDefaults.criticalCoreFiles(in: contents)
            )
            criticalFilePaths.formUnion(try archiveExecutablePaths(at: input.zipURL))
        } else if input.name == "geometry-da3-base" {
            criticalFilePaths.formUnion(
                ManifestToolDefaults.criticalDa3BaseFiles(in: contents)
            )
            criticalFilePaths.formUnion(try archiveExecutablePaths(at: input.zipURL))
        }
        let criticalFileHashes = try archiveCriticalFileHashes(
            zipURL: input.zipURL,
            paths: criticalFilePaths.sorted()
        )
        return ManifestDocument.Component(
            name: input.name,
            capabilities: input.capabilities,
            url: input.artifactURL,
            sha256: sha,
            sizeBytes: size,
            expandedSizeBytes: expandedSize,
            contents: contents,
            criticalFileHashes: criticalFileHashes,
            dependencies: input.dependencies,
            requirement: input.requirement
        )
    }

    private static func privateKey(from privateKeyBase64: String) throws -> Curve25519.Signing.PrivateKey {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw NSError(domain: "ManifestTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid private key base64"])
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    }

    private static func validateReleaseSigningRequest(
        _ request: ReleaseSigningRequest,
        expectedRepository: String,
        expectedSourceCommit: String,
        expectedVersion: String,
        expectedAppVersionRange: ManifestDocument.AppVersionRange,
        publicKeyData: Data
    ) throws {
        guard request.schemaVersion == 1 else {
            try releaseFailure("Release signing request schema is invalid.")
        }
        try requireValidRepository(expectedRepository)
        try requireValidSourceCommit(expectedSourceCommit)
        guard request.sourceRepository == expectedRepository,
              request.sourceCommit == expectedSourceCommit else {
            try releaseFailure("Release signing request source identity is invalid.")
        }

        let manifest = request.manifest
        guard manifest.schemaVersion == 2,
              manifest.toolchainAPI == 2,
              manifest.signatureEd25519.isEmpty,
              manifest.version == expectedVersion,
              manifest.appVersionRange == expectedAppVersionRange,
              validAppVersionRange(manifest.appVersionRange),
              semanticVersion(from: manifest.version) != nil else {
            try releaseFailure("Release signing request version or app bounds are invalid.")
        }
        guard request.manifestSHA256 == sha256Hex(data: try canonicalData(for: manifest)) else {
            try releaseFailure("Prepared release manifest was modified after derivation.")
        }
        guard manifest.keyID == sha256Hex(data: publicKeyData) else {
            try releaseFailure("Release signing request key identifier is invalid.")
        }

        let names = ["macos-arm64-core", "geometry-da3-base", "geometry-da3-small"]
        guard manifest.components.map(\.name) == names else {
            try releaseFailure("Release signing request component set or order is invalid.")
        }
        let urls = releaseComponentURLs(repository: expectedRepository, version: expectedVersion)
        for component in manifest.components {
            guard component.url == urls[component.name],
                  component.sha256.count == 64,
                  component.sha256.allSatisfy(isLowercaseHex),
                  component.sizeBytes > 0,
                  component.sizeBytes < maximumReleaseAssetBytes,
                  component.expandedSizeBytes > 0,
                  component.expandedSizeBytes <= maximumExpandedComponentBytes,
                  component.contents == component.contents.sorted(),
                  !component.contents.isEmpty,
                  Set(component.contents).count == component.contents.count,
                  !component.criticalFileHashes.isEmpty,
                  Set(component.criticalFileHashes.keys).isSubset(of: Set(component.contents)),
                  component.criticalFileHashes.values.allSatisfy({
                      $0.count == 64 && $0.allSatisfy(isLowercaseHex)
                  }) else {
                try releaseFailure("Release signing request component metadata is invalid: \(component.name)")
            }
        }
        let core = manifest.components[0]
        let base = manifest.components[1]
        let small = manifest.components[2]
        guard core.capabilities == ManifestToolDefaults.coreCapabilities,
              core.dependencies.isEmpty,
              core.requirement == .required,
              core.sizeBytes <= maximumCoreDownloadBytes,
              core.contents.allSatisfy(ManifestToolDefaults.isAllowedCoreFile),
              Set(core.contents.filter { $0.hasPrefix("lib/") }) == ["lib/libomp.dylib"],
              ManifestToolDefaults.criticalCoreFiles(in: core.contents)
                .isSubset(of: Set(core.criticalFileHashes.keys)),
              base.capabilities == ["geometry.da3.runtime", "geometry.da3.base"],
              base.dependencies == ["macos-arm64-core"],
              base.requirement == .optional,
              base.contents.allSatisfy(ManifestToolDefaults.isAllowedDa3BaseFile),
              ManifestToolDefaults.criticalDa3BaseFiles(in: base.contents)
                .isSubset(of: Set(base.criticalFileHashes.keys)),
              small.capabilities == ["geometry.da3.small"],
              small.dependencies == ["geometry-da3-base"],
              small.requirement == .optional,
              Set(small.contents) == Set(ManifestToolDefaults.da3SmallContents),
              Set(small.criticalFileHashes.keys) == Set(small.contents) else {
            try releaseFailure("Release signing request component policy is invalid.")
        }
        var totalDownloadBytes: UInt64 = 0
        for component in manifest.components {
            let sum = totalDownloadBytes.addingReportingOverflow(component.sizeBytes)
            guard !sum.overflow else {
                try releaseFailure("Release signing request component size total overflowed.")
            }
            totalDownloadBytes = sum.partialValue
        }
        guard totalDownloadBytes <= maximumFullToolchainDownloadBytes else {
            try releaseFailure("Release signing request exceeds the 6 GB full toolchain budget.")
        }
        try validateContentOwnership(manifest.components)
    }

    private static func validatedPublicKeyData(_ publicKeyBase64: String) throws -> Data {
        guard let data = Data(base64Encoded: publicKeyBase64),
              data.count == 32,
              data.base64EncodedString() == publicKeyBase64,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil else {
            try releaseFailure("Tracked release public key is invalid.")
        }
        return data
    }

    private static func requireValidRepository(_ repository: String) throws {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2,
              parts.allSatisfy({ part in
                  !part.isEmpty
                      && part != "."
                      && part != ".."
                      && part.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            try releaseFailure("Release repository identity is invalid.")
        }
    }

    private static func requireValidSourceCommit(_ sourceCommit: String) throws {
        guard sourceCommit.count == 40, sourceCommit.allSatisfy(isLowercaseHex) else {
            try releaseFailure("Release source commit must be a lowercase 40-character Git object ID.")
        }
    }

    private static func isLowercaseHex(_ character: Character) -> Bool {
        ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }

    private static func releaseFailure(_ message: String) throws -> Never {
        throw NSError(
            domain: "ManifestTool",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private struct SemanticVersion: Equatable {
        enum PrereleaseIdentifier: Equatable {
            case numeric(String)
            case text(String)
        }

        var major: String
        var minor: String
        var patch: String
        var prerelease: [PrereleaseIdentifier]
    }

    private static func validAppVersionRange(_ range: ManifestDocument.AppVersionRange) -> Bool {
        guard let minimum = semanticVersion(from: range.minimum),
              let maximumValue = range.maximumExclusive,
              let maximum = semanticVersion(from: maximumValue) else {
            return false
        }
        return compareSemanticVersions(minimum, maximum) == .orderedAscending
    }

    private static func requireValidToolchainVersion(_ version: String) throws {
        guard semanticVersion(from: version) != nil else {
            throw NSError(
                domain: "ManifestTool",
                code: 13,
                userInfo: [
                    NSLocalizedDescriptionKey: "Toolchain version must be strict SemVer."
                ]
            )
        }
    }

    private static func appVersion(
        _ value: String,
        isWithin range: ManifestDocument.AppVersionRange
    ) -> Bool {
        guard validAppVersionRange(range),
              let app = semanticVersion(from: value),
              let minimum = semanticVersion(from: range.minimum),
              let maximumValue = range.maximumExclusive,
              let maximum = semanticVersion(from: maximumValue) else {
            return false
        }
        return compareSemanticVersions(app, minimum) != .orderedAscending
            && compareSemanticVersions(app, maximum) == .orderedAscending
    }

    private static func semanticVersion(from value: String) -> SemanticVersion? {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2, !buildParts[0].isEmpty else { return nil }
        if buildParts.count == 2,
           !validSemanticIdentifiers(buildParts[1], allowNumericLeadingZero: true) {
            return nil
        }

        let versionParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = semanticCoreNumber(core[0]),
              let minor = semanticCoreNumber(core[1]),
              let patch = semanticCoreNumber(core[2]) else {
            return nil
        }

        var prerelease: [SemanticVersion.PrereleaseIdentifier] = []
        if versionParts.count == 2 {
            let raw = versionParts[1]
            guard validSemanticIdentifiers(raw, allowNumericLeadingZero: false) else { return nil }
            prerelease = raw.split(separator: ".", omittingEmptySubsequences: false).map { identifier in
                if identifier.allSatisfy(\.isNumber) {
                    return .numeric(String(identifier))
                }
                return .text(String(identifier))
            }
        }
        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    private static func compareSemanticVersions(
        _ lhs: SemanticVersion,
        _ rhs: SemanticVersion
    ) -> ComparisonResult {
        for (left, right) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] {
            let comparison = compareSemanticNumericIdentifiers(left, right)
            if comparison != .orderedSame { return comparison }
        }
        if lhs.prerelease.isEmpty, rhs.prerelease.isEmpty { return .orderedSame }
        if lhs.prerelease.isEmpty { return .orderedDescending }
        if rhs.prerelease.isEmpty { return .orderedAscending }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (left, right) {
            case let (.numeric(leftValue), .numeric(rightValue)):
                let comparison = compareSemanticNumericIdentifiers(leftValue, rightValue)
                if comparison != .orderedSame { return comparison }
            case (.numeric, .text):
                return .orderedAscending
            case (.text, .numeric):
                return .orderedDescending
            case let (.text(leftValue), .text(rightValue)):
                if leftValue > rightValue { return .orderedDescending }
                if leftValue < rightValue { return .orderedAscending }
            }
        }
        if lhs.prerelease.count > rhs.prerelease.count { return .orderedDescending }
        if lhs.prerelease.count < rhs.prerelease.count { return .orderedAscending }
        return .orderedSame
    }

    private static func semanticCoreNumber(_ value: Substring) -> String? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ ("0"..."9").contains(Character(String($0))) }),
              value == "0" || value.first != "0" else {
            return nil
        }
        return String(value)
    }

    private static func compareSemanticNumericIdentifiers(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        if lhs.count > rhs.count { return .orderedDescending }
        if lhs.count < rhs.count { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        if lhs < rhs { return .orderedAscending }
        return .orderedSame
    }

    private static func validSemanticIdentifiers(
        _ value: Substring,
        allowNumericLeadingZero: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      ("0"..."9").contains(Character(String(scalar)))
                          || ("A"..."Z").contains(Character(String(scalar)))
                          || ("a"..."z").contains(Character(String(scalar)))
                          || scalar == "-"
                  }) else {
                return false
            }
            if !allowNumericLeadingZero,
               identifier.allSatisfy(\.isNumber),
               identifier.count > 1,
               identifier.first == "0" {
                return false
            }
            return true
        }
    }

    private static func archiveContents(at zipURL: URL) throws -> [String] {
        try rejectArchiveLinks(at: zipURL)
        let output = try runUnzip(arguments: ["-Z1", zipURL.path])
        let entries = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/") }
        try validateArchivePaths(entries)
        guard !entries.isEmpty, Set(entries).count == entries.count else {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Archive contents are empty or duplicated"])
        }
        return entries.sorted()
    }

    private static func rejectArchiveLinks(at zipURL: URL) throws {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-l", zipURL.path]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to inspect component archive metadata"])
        }
        let text = String(decoding: output, as: UTF8.self)
        if text.split(whereSeparator: \.isNewline).contains(where: { $0.first == "l" }) {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Component archive contains a symbolic link"])
        }
    }

    private static func archiveExpandedSize(at zipURL: URL) throws -> UInt64 {
        try rejectArchiveLinks(at: zipURL)
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-l", zipURL.path]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(
                domain: "ManifestTool",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Unable to inspect expanded component size"]
            )
        }

        var total: UInt64 = 0
        var fileCount = 0
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.first == "-" else { continue }
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10, let size = UInt64(fields[3]) else {
                throw NSError(
                    domain: "ManifestTool",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to parse expanded component size"]
                )
            }
            fileCount += 1
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow, sum.partialValue <= maximumExpandedComponentBytes else {
                throw NSError(
                    domain: "ManifestTool",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Expanded component exceeds the 16 GiB safety limit."]
                )
            }
            total = sum.partialValue
        }
        guard fileCount > 0, total > 0 else {
            throw NSError(
                domain: "ManifestTool",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Component archive has no regular file payload."]
            )
        }
        return total
    }

    private static func archiveExecutablePaths(at zipURL: URL) throws -> Set<String> {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-l", zipURL.path]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(
                domain: "ManifestTool",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Unable to inspect component archive permissions"]
            )
        }

        var paths = Set<String>()
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let permissions = line.prefix(10)
            guard permissions.first == "-", permissions.contains("x") else { continue }
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10 else {
                throw NSError(
                    domain: "ManifestTool",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to parse executable archive entry"]
                )
            }
            paths.insert(String(fields[9]))
        }
        try validateArchivePaths(Array(paths))
        return paths
    }

    private static func archiveCriticalFileHashes(zipURL: URL, paths: [String]) throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        try validateArchivePaths(paths)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try runUnzip(arguments: ["-qq", zipURL.path, "-d", root.path])
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var result: [String: String] = [:]
        for path in paths {
            let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(resolvedRoot + "/"),
                  FileManager.default.fileExists(atPath: file.path) else {
                throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Critical file is missing or escapes the archive root: \(path)"])
            }
            result[path] = try sha256Hex(url: file)
        }
        return result
    }

    private static func runUnzip(arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to inspect component archive"])
        }
        return data
    }

    private static func validateArchivePaths(_ paths: [String]) throws {
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !parts.contains(where: { $0 == "." || $0 == ".." }) else {
                throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Archive contains an unsafe path"])
            }
        }
    }
}

public enum ManifestToolDefaults {
    public static let coreCapabilities = [
        "runtime.core",
        "geometry.colmap",
        "training.msplat",
    ]

    public static let criticalCoreAnchors = [
        "bin/colmap",
        "bin/easysplat-train",
        "bin/default.metallib",
        "lib/libomp.dylib",
        "provenance/colmap.json",
        "provenance/colmap-support.json",
        "provenance/ceres.json",
        "provenance/openimageio.json",
        "msplat/build_info.json",
        "msplat/LICENSE",
        "supply-chain/components.json",
    ]

    public static let criticalCoreFiles = criticalCoreAnchors

    public static func isAllowedCoreFile(_ path: String) -> Bool {
        criticalCoreAnchors.contains(path)
            || (path.hasPrefix("licenses/") && path.count > "licenses/".count)
    }

    public static func criticalCoreFiles(in contents: [String]) -> Set<String> {
        var required = Set(criticalCoreAnchors)
        for path in contents {
            let lowercased = path.lowercased()
            let pathExtension = URL(fileURLWithPath: lowercased).pathExtension
            let isLoadedLibrary = ["dylib", "so"].contains(pathExtension)
                && lowercased.hasPrefix("lib/")
            let isMetalLibrary = pathExtension == "metallib"
            let isExecutablePayload = lowercased.hasPrefix("bin/")
            let isReceiptOrLicense = lowercased.hasPrefix("provenance/")
                || lowercased.hasPrefix("licenses/")
                || lowercased.hasPrefix("msplat/")
                || lowercased.hasPrefix("supply-chain/")
            if isLoadedLibrary || isMetalLibrary || isExecutablePayload || isReceiptOrLicense {
                required.insert(path)
            }
        }
        return required
    }

    public static let da3BaseContents = [
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
        "da3_mps/build_info.json",
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/model.safetensors",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
        "da3_mps/models/DA3-BASE/LICENSE",
    ]

    public static func criticalDa3BaseFiles(in contents: [String]) -> Set<String> {
        var required = Set(da3BaseContents)
        for path in contents {
            let lowercased = path.lowercased()
            guard lowercased.hasPrefix("da3_mps/") else { continue }
            let pathExtension = URL(fileURLWithPath: lowercased).pathExtension
            let isPythonCode = ["py", "pyc", "pth"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("da3_mps/app/")
                        || lowercased.hasPrefix("da3_mps/vendor/")
                        || lowercased.hasPrefix("da3_mps/python/")
                )
            let isRuntimeConfiguration = ["yaml", "yml", "json", "toml"].contains(pathExtension)
            let isLoadedLibrary = ["dylib", "so"].contains(pathExtension)
            let pathComponents = lowercased.split(separator: "/")
            let isExecutablePayload = pathComponents.dropLast().contains(where: {
                $0 == "bin" || $0 == "libexec"
            })
            let filename = pathComponents.last.map(String.init) ?? ""
            let isLicenseOrNotice = lowercased.hasPrefix("da3_mps/licenses/")
                || filename.hasPrefix("license")
                || filename.hasPrefix("copying")
                || filename.hasPrefix("notice")
            if isPythonCode || isRuntimeConfiguration || isLoadedLibrary
                || isExecutablePayload || isLicenseOrNotice {
                required.insert(path)
            }
        }
        return required
    }

    public static func isAllowedDa3BaseFile(_ path: String) -> Bool {
        path == "da3_mps/build_info.json"
            || path.hasPrefix("da3_mps/bin/")
            || path.hasPrefix("da3_mps/python/")
            || path.hasPrefix("da3_mps/app/")
            || path.hasPrefix("da3_mps/vendor/")
            || path.hasPrefix("da3_mps/licenses/")
            || path.hasPrefix("da3_mps/models/DA3-BASE/")
    }

    public static let da3SmallContents = [
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/model.safetensors",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
        "da3_mps/models/DA3-SMALL/LICENSE",
    ]
}

public enum ManifestKeyInput {
    public static func resolvePrivateKeyBase64(parser: inout ArgParser) throws -> String {
        guard parser.value(for: "--private-key") == nil else {
            throw NSError(
                domain: "ManifestTool",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Private keys must be read from a file or environment variable, not a process argument."
                ]
            )
        }
        let filePath = parser.value(for: "--private-key-file")
        let envName = parser.value(for: "--private-key-env")
        let sources = [filePath, envName].compactMap { $0 }
        guard sources.count == 1 else {
            throw NSError(
                domain: "ManifestTool",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Specify exactly one private key source: --private-key-file or --private-key-env"]
            )
        }

        if let filePath {
            let url = URL(fileURLWithPath: filePath)
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let envName else {
            throw NSError(
                domain: "ManifestTool",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Specify exactly one private key source"]
            )
        }
        let trimmedName = envName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let value = ProcessInfo.processInfo.environment[trimmedName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw NSError(
                domain: "ManifestTool",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Environment variable \(envName) does not contain a private key"]
            )
        }
        return value
    }

    public static func writePrivateKeyBase64(_ value: String, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        guard fm.createFile(
            atPath: tempURL.path,
            contents: Data(value.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(
                domain: "ManifestTool",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create private key file at \(url.path)"]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case failure = 1
}

public struct ArgParser {
    private var args: [String]

    public init(_ args: [String]) {
        self.args = args
    }

    public mutating func require(_ key: String) throws -> String {
        guard let value = value(for: key) else {
            throw NSError(domain: "ManifestTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing \(key)"])
        }
        return value
    }

    public mutating func value(for key: String) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    public func requireOnly(_ allowed: Set<String>) throws {
        guard args.count.isMultiple(of: 2) else {
            throw NSError(
                domain: "ManifestTool",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Command options must be complete key-value pairs."]
            )
        }
        var seen = Set<String>()
        for index in stride(from: 0, to: args.count, by: 2) {
            let key = args[index]
            let value = args[index + 1]
            guard key.hasPrefix("--"),
                  allowed.contains(key),
                  !value.hasPrefix("--"),
                  seen.insert(key).inserted else {
                throw NSError(
                    domain: "ManifestTool",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Command contains an unknown, duplicate, or incomplete option: \(key)"]
                )
            }
        }
    }
}
