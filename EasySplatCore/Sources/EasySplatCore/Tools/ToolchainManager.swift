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
        targetName: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths
}

public extension ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        try await ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: publicKeyBase64,
            targetName: targetName,
            request: .default,
            onProgress: onProgress
        )
    }
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

    /// Preserves the pre-component installer behavior for existing protocol callers.
    public static let `default` = ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small])
}

/// Downloads, verifies, installs, and validates toolchains for the app.
public final class ToolchainManager: @unchecked Sendable, ToolchainManaging {
    struct ToolchainInstallState: Codable, Sendable {
        var schemaVersion: Int
        var installedArtifacts: [String: String]
        var installedCapabilities: [String]
        var signedManifest: ToolchainManifest?

        init(
            schemaVersion: Int = 1,
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

    public init(
        runner: SubprocessRunning = SubprocessRunner(),
        urlSession: URLSession = .shared,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        localToolchainRoot: URL? = DevelopmentOverrides.fromProcessEnvironment().localToolchainRoot
    ) {
        self.runner = runner
        self.urlSession = urlSession
        self.appVersion = appVersion
        self.localToolchainRoot = localToolchainRoot
    }

    public func toolchainRoot() -> URL {
        (try? toolchainRootURL()) ?? fileManager.temporaryDirectory.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)
    }

    func toolchainRootURL() throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ToolchainError.noApplicationSupportDirectory
        }
        return base.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)
    }

    public func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String = "macos-arm64",
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        try await ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: publicKeyBase64,
            targetName: targetName,
            request: .default,
            onProgress: onProgress
        )
    }

    /// Installs only components providing the requested capabilities and their dependencies.
    public func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String = "macos-arm64",
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

        if manifest.schemaVersion >= ToolchainManifest.currentSchemaVersion {
            try validateSchema2Manifest(manifest, publicKeyBase64: publicKeyBase64)
            let components: [ToolchainManifest.Component]
            do {
                components = try manifest.resolvedComponents(requesting: request.manifestCapabilities)
            } catch {
                throw ToolchainError.invalidManifest
            }
            guard !components.isEmpty else { throw ToolchainError.artifactNotFound }

            let versionedRoot = try toolchainRootURL().appendingPathComponent(manifest.version, isDirectory: true)
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

            try preflightDiskSpace(for: missingComponents, at: versionedRoot)
            let toolchain = try await installToolchainAtomically(
                versionedRoot: versionedRoot,
                requiredCapabilities: validationCapabilities,
                seedFromExistingRoot: reusableState == nil ? nil : versionedRoot,
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

        let versionedRoot = try toolchainRootURL().appendingPathComponent(manifest.version, isDirectory: true)

        if fileManager.fileExists(atPath: versionedRoot.path) {
            onProgress(-1.0, "Validating tools")
            if let toolchain = try? validateToolchain(root: versionedRoot) {
                onProgress(1.0, "Tools ready (cached)")
                return toolchain
            }
        }

        // Backward compatible: older manifests shipped a single monolithic artifact ("macos-arm64").
        if let artifact = manifest.artifacts.first(where: { $0.name == targetName }) {
            let toolchain = try await installToolchainAtomically(versionedRoot: versionedRoot, onProgress: onProgress) { stagingRoot in
                let artifactURL = try validatedArtifactURL(artifact.url)
                let zipURL = stagingRoot.appendingPathComponent("toolchain.zip")
                try await downloadFile(url: artifactURL, to: zipURL, label: "Downloading tools", onProgress: onProgress)

                let downloadedSize = try fileManager.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber
                guard downloadedSize?.uint64Value == artifact.sizeBytes else {
                    throw ToolchainError.hashMismatch
                }
                let computedHash = try sha256Hex(url: zipURL)
                guard computedHash.lowercased() == artifact.sha256.lowercased() else {
                    throw ToolchainError.hashMismatch
                }

                let unpackMessage = "Unpacking tools"
                onProgress(-1.0, unpackMessage)
                try unzip(zipURL: zipURL, to: stagingRoot)
                try? fileManager.removeItem(at: zipURL)
                try enforceExpectedContents(
                    artifact: artifact,
                    root: stagingRoot,
                    unpackMessage: unpackMessage,
                    onProgress: onProgress
                )
            }
            onProgress(1.0, "Tools ready")
            return toolchain
        }

        // Split toolchain: keep core binaries/env small-ish, ship model weights separately.
        let coreName = "\(targetName)-core"
        let modelsName = "\(targetName)-models"
        guard let coreArtifact = manifest.artifacts.first(where: { $0.name == coreName }),
              let modelsArtifact = manifest.artifacts.first(where: { $0.name == modelsName }) else {
            throw ToolchainError.artifactNotFound
        }

        let toolchain = try await installToolchainAtomically(versionedRoot: versionedRoot, onProgress: onProgress) { stagingRoot in
            var state = loadInstallState(root: stagingRoot)
            try await ensureArtifact(coreArtifact, root: stagingRoot, state: &state, onProgress: onProgress)
            try await ensureArtifact(modelsArtifact, root: stagingRoot, state: &state, onProgress: onProgress)
        }
        onProgress(1.0, "Tools ready")
        return toolchain
    }
}
