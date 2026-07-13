import Foundation

/// Resolved paths for a validated EasySplat toolchain installation.
public struct ToolchainPaths: Sendable {
    public var root: URL
    public var colmap: URL
    public var msplat: URL
    public var da3: Da3Toolchain

    public init(
        root: URL,
        colmap: URL,
        msplat: URL,
        da3: Da3Toolchain
    ) {
        self.root = root
        self.colmap = colmap
        self.msplat = msplat
        self.da3 = da3
    }
}

/// Paths for the bundled Depth Anything 3 runtime inside a toolchain install.
public struct Da3Toolchain: Sendable {
    public var root: URL
    public var sfmTool: URL
    public var python: URL
    public var models: URL
    public var modelBundle: URL
    public var fallbackModelBundle: URL

    public init(root: URL, sfmTool: URL, python: URL, models: URL, modelBundle: URL, fallbackModelBundle: URL) {
        self.root = root
        self.sfmTool = sfmTool
        self.python = python
        self.models = models
        self.modelBundle = modelBundle
        self.fallbackModelBundle = fallbackModelBundle
    }
}

/// Interface for acquiring and validating an EasySplat toolchain.
public protocol ToolchainManaging: Sendable {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths
}

public enum ToolchainCapability: String, Sendable, CaseIterable {
    case core = "runtime.core"
    case colmap = "geometry.colmap"
    case da3Runtime = "geometry.da3.runtime"
    case msplat = "training.msplat"
    case da3Base = "geometry.da3.base"
    case da3Small = "geometry.da3.small"
}

/// Typed capabilities requested from a schema-2 component manifest.
public struct ToolchainCapabilityRequest: Sendable, Equatable {
    public var capabilities: Set<ToolchainCapability>

    public init(capabilities: Set<ToolchainCapability>) {
        self.capabilities = capabilities
    }

    var manifestCapabilities: Set<String> {
        Set(capabilities.map(\.rawValue))
    }

}

/// Downloads, verifies, installs, and validates toolchains for the app.
public final class ToolchainManager: @unchecked Sendable, ToolchainManaging {
    struct ToolchainInstallState: Codable, Sendable {
        var schemaVersion: Int
        var installedArtifacts: [String: String]
        var installedCapabilities: [String]
        var signedManifest: ToolchainManifest?

        init(
            schemaVersion: Int = ToolchainManifest.currentSchemaVersion,
            installedArtifacts: [String: String] = [:],
            installedCapabilities: [String] = [],
            signedManifest: ToolchainManifest? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.installedArtifacts = installedArtifacts
            self.installedCapabilities = installedCapabilities
            self.signedManifest = signedManifest
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case installedArtifacts
            case installedCapabilities
            case signedManifest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            installedArtifacts = try container.decodeIfPresent([String: String].self, forKey: .installedArtifacts) ?? [:]
            installedCapabilities = try container.decodeIfPresent([String].self, forKey: .installedCapabilities) ?? []
            signedManifest = try container.decodeIfPresent(ToolchainManifest.self, forKey: .signedManifest)
        }
    }

    /// Errors that can occur while resolving or validating a toolchain install.
    public enum ToolchainError: Error, LocalizedError {
        case invalidManifest
        case signatureFailed
        case artifactNotFound
        case downloadFailed
        case manifestHTTPFailure(statusCode: Int, resourceURL: URL)
        case manifestTooLarge(maximumBytes: Int)
        case hashMismatch
        case unzipFailed
        case missingBinary(String)
        case missingLibrary(String)
        case invalidToolchain(String)
        case noApplicationSupportDirectory
        case invalidArtifactURL(String)
        case fileIOFailed(String)
        case insufficientDiskSpace(required: UInt64, available: UInt64)

        public var errorDescription: String? {
            switch self {
            case .invalidManifest:
                return "Toolchain manifest is invalid."
            case .signatureFailed:
                return "Toolchain signature verification failed."
            case .artifactNotFound:
                return "Toolchain artifact not found for this Mac."
            case .downloadFailed:
                return "Failed to download the toolchain."
            case .manifestHTTPFailure(let statusCode, let resourceURL):
                return "Toolchain manifest request failed with HTTP \(statusCode): \(resourceURL.absoluteString)"
            case .manifestTooLarge(let maximumBytes):
                return "Toolchain manifest exceeds the \(maximumBytes)-byte download limit."
            case .hashMismatch:
                return "Downloaded toolchain did not match the expected checksum."
            case .unzipFailed:
                return "Failed to unpack the downloaded toolchain."
            case .missingBinary(let name):
                return "Toolchain is missing required binary: \(name)."
            case .missingLibrary(let name):
                return "Toolchain is missing required library: \(name)."
            case .invalidToolchain(let message):
                return "Toolchain is invalid. \(message)"
            case .noApplicationSupportDirectory:
                return "Unable to locate the Application Support directory."
            case .invalidArtifactURL(let urlString):
                return "Toolchain artifact URL is invalid: \(urlString)"
            case .fileIOFailed(let message):
                return message
            case .insufficientDiskSpace(let required, let available):
                return "Not enough disk space for the toolchain (requires \(required) bytes, \(available) bytes available)."
            }
        }
    }

    let fileManager = FileManager.default
    let runner: SubprocessRunning
    let urlSession: URLSession
    let appVersion: String
    let localToolchainRoot: URL?
    let installationRoot: URL?
    let allowInsecureLoopbackHTTP: Bool

    public init(
        runner: SubprocessRunning = SubprocessRunner(),
        urlSession: URLSession = .shared,
        appVersion: String = EasySplatReleaseIdentity.version(),
        localToolchainRoot: URL? = DevelopmentOverrides.fromProcessEnvironment().localToolchainRoot,
        installationRoot: URL? = nil,
        allowInsecureLoopbackHTTP: Bool = false
    ) {
        self.runner = runner
        self.urlSession = urlSession
        self.appVersion = appVersion
        self.localToolchainRoot = localToolchainRoot
        self.installationRoot = installationRoot
        self.allowInsecureLoopbackHTTP = allowInsecureLoopbackHTTP
    }

    public func toolchainRoot() -> URL {
        (try? toolchainRootURL()) ?? fileManager.temporaryDirectory.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)
    }

    func toolchainRootURL() throws -> URL {
        if let installationRoot {
            return installationRoot
        }
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ToolchainError.noApplicationSupportDirectory
        }
        return base.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)
    }

    /// Installs only components providing the requested capabilities and their dependencies.
    public func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        guard !request.capabilities.isEmpty else {
            throw ToolchainError.invalidManifest
        }
        if let localRoot = localToolchainOverrideURL() {
            onProgress(-1.0, "Checking installed tools")
            onProgress(-1.0, "Validating tools")
            let toolchain = try validateToolchain(
                root: localRoot,
                requiredCapabilities: request.capabilities
            )
            onProgress(1.0, "Tools ready (local)")
            return toolchain
        }

        onProgress(-1.0, "Checking installed tools")
        let manifest: ToolchainManifest
        do {
            manifest = try await downloadManifest(url: manifestURL)
        } catch {
            if shouldAttemptOfflineFallback(forManifestError: error) {
                onProgress(-1.0, "Trying cached tools")
                if let cached = try? loadBestCachedToolchain(
                    publicKeyBase64: publicKeyBase64,
                    request: request
                ) {
                    onProgress(1.0, "Tools ready (offline cached)")
                    return cached
                }
            }
            throw error
        }
        guard manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            throw ToolchainError.signatureFailed
        }
        guard semanticVersionComponents(from: manifest.version) != nil else {
            throw ToolchainError.invalidManifest
        }

        try validateSchema2Manifest(manifest, publicKeyBase64: publicKeyBase64)
        let components: [ToolchainManifest.Component]
        do {
            components = try manifest.resolvedComponents(requesting: request.manifestCapabilities)
        } catch {
            throw ToolchainError.invalidManifest
        }
        guard !components.isEmpty else { throw ToolchainError.artifactNotFound }

        let versionedRoot = try versionedToolchainRoot(for: manifest.version)
        try recoverInterruptedInstalls(
            at: versionedRoot.deletingLastPathComponent(),
            publicKeyBase64: publicKeyBase64
        )
        if fileManager.fileExists(atPath: versionedRoot.path) {
            onProgress(-1.0, "Validating tools")
            if let receipt = try? validateSignedReceipt(
                root: versionedRoot,
                publicKeyBase64: publicKeyBase64,
                request: request
            ),
               receipt.signatureEd25519 == manifest.signatureEd25519,
               let toolchain = try? validateToolchain(
                root: versionedRoot,
                requiredCapabilities: request.capabilities
               ) {
                onProgress(1.0, "Tools ready (cached)")
                return toolchain
            }
        }

        let reusableState = try? validatedReusableInstallState(
            root: versionedRoot,
            publicKeyBase64: publicKeyBase64,
            matching: manifest
        )
        let reusableNames = Set(reusableState.map { Array($0.installedArtifacts.keys) } ?? [])
        let requestedNames = Set(components.map(\.name))
        let retainedNames = reusableNames.union(requestedNames)
        let retainedComponents = manifest.components.filter { retainedNames.contains($0.name) }
        let missingComponents = retainedComponents.filter { !reusableNames.contains($0.name) }
        let retainedCapabilities = Set(retainedComponents.flatMap(\.capabilities))
        let validationCapabilities = Set(retainedCapabilities.compactMap(ToolchainCapability.init(rawValue:)))

        let seedFromExistingRoot = reusableState == nil ? nil : versionedRoot
        try preflightDiskSpace(
            for: missingComponents,
            at: versionedRoot,
            seedFromExistingRoot: seedFromExistingRoot
        )
        let toolchain = try await installToolchainAtomically(
            versionedRoot: versionedRoot,
            requiredCapabilities: validationCapabilities,
            seedFromExistingRoot: seedFromExistingRoot,
            onProgress: onProgress
        ) { stagingRoot in
            var state = reusableState ?? ToolchainInstallState()
            state.schemaVersion = ToolchainManifest.currentSchemaVersion
            state.installedCapabilities = retainedCapabilities.sorted()
            state.signedManifest = manifest
            for component in retainedComponents {
                try await ensureArtifact(
                    component,
                    root: stagingRoot,
                    state: &state,
                    onProgress: onProgress
                )
            }
            try saveInstallState(state, root: stagingRoot)
        }
        pruneSchema2Toolchains(keeping: manifest.version, publicKeyBase64: publicKeyBase64)
        onProgress(1.0, "Tools ready")
        return toolchain
    }
}
