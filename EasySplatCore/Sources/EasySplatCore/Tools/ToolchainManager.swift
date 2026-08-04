import Foundation

/// Resolved paths for a validated EasySplat toolchain.
public struct ToolchainPaths: Sendable {
    /// Executable root: `<root>/bin/colmap`, `<root>/lib/libomp.dylib`.
    public var root: URL
    /// Non-executable payload root: `default.metallib`, `msplat/`, `provenance/`,
    /// `supply-chain/`. A single-root tree keeps this equal to `root`.
    public var dataRoot: URL
    /// Identity persisted with per-project geometry provenance.
    public var toolchainIdentity: String
    public var colmap: URL
    public var msplat: URL
    public var metallib: URL
    public var da3: Da3Toolchain

    public init(
        root: URL,
        dataRoot: URL,
        toolchainIdentity: String,
        colmap: URL,
        msplat: URL,
        metallib: URL,
        da3: Da3Toolchain
    ) {
        self.root = root
        self.dataRoot = dataRoot
        self.toolchainIdentity = toolchainIdentity
        self.colmap = colmap
        self.msplat = msplat
        self.metallib = metallib
        self.da3 = da3
    }
}

/// Paths for the bundled Depth Anything 3 runtime inside a toolchain tree.
public struct Da3Toolchain: Sendable {
    public var root: URL
    public var sfmTool: URL
    public var python: URL
    public var models: URL
    public var modelBundle: URL
    public var smallModelBundle: URL

    public init(root: URL, sfmTool: URL, python: URL, models: URL, modelBundle: URL, smallModelBundle: URL) {
        self.root = root
        self.sfmTool = sfmTool
        self.python = python
        self.models = models
        self.modelBundle = modelBundle
        self.smallModelBundle = smallModelBundle
    }
}

/// Evidence for one exact installed toolchain closure.
///
/// Every field is derived from the installed tree after it has been revalidated;
/// no caller-supplied value is reflected directly.
public struct ToolchainInstallationEvidence: Sendable, Equatable {
    public struct SignedComponent: Sendable, Equatable {
        public let name: String
        public let archiveSHA256: String
        public let expandedClosureSHA256: String
        public let capabilities: [String]
        public let declaredContents: [String]

        public init(
            name: String,
            archiveSHA256: String,
            expandedClosureSHA256: String,
            capabilities: [String],
            declaredContents: [String]
        ) {
            self.name = name
            self.archiveSHA256 = archiveSHA256
            self.expandedClosureSHA256 = expandedClosureSHA256
            self.capabilities = capabilities
            self.declaredContents = declaredContents
        }
    }

    public struct ProvenanceRecord: Sendable, Equatable {
        public let path: String
        public let fileSHA256: String
        public let canonicalJSONSHA256: String
        public let stringFields: [String: String]

        public init(
            path: String,
            fileSHA256: String,
            canonicalJSONSHA256: String,
            stringFields: [String: String]
        ) {
            self.path = path
            self.fileSHA256 = fileSHA256
            self.canonicalJSONSHA256 = canonicalJSONSHA256
            self.stringFields = stringFields
        }
    }

    public let toolchainVersion: String
    public let keyID: String
    public let canonicalManifestSHA256: String
    public let signatureSHA256: String
    public let closureSHA256: String
    public let installationIdentitySHA256: String
    public let installedArtifacts: [String: String]
    public let installedCapabilities: [String]
    public let installedCriticalFileSHA256: [String: String]
    public let nativeTrainerBuildDigest: String
    public let signedComponents: [SignedComponent]
    public let provenanceRecords: [ProvenanceRecord]

    public init(
        toolchainVersion: String,
        keyID: String,
        canonicalManifestSHA256: String,
        signatureSHA256: String,
        closureSHA256: String,
        installationIdentitySHA256: String,
        installedArtifacts: [String: String],
        installedCapabilities: [String],
        installedCriticalFileSHA256: [String: String],
        nativeTrainerBuildDigest: String,
        signedComponents: [SignedComponent] = [],
        provenanceRecords: [ProvenanceRecord] = []
    ) {
        self.toolchainVersion = toolchainVersion
        self.keyID = keyID
        self.canonicalManifestSHA256 = canonicalManifestSHA256
        self.signatureSHA256 = signatureSHA256
        self.closureSHA256 = closureSHA256
        self.installationIdentitySHA256 = installationIdentitySHA256
        self.installedArtifacts = installedArtifacts
        self.installedCapabilities = installedCapabilities
        self.installedCriticalFileSHA256 = installedCriticalFileSHA256
        self.nativeTrainerBuildDigest = nativeTrainerBuildDigest
        self.signedComponents = signedComponents
        self.provenanceRecords = provenanceRecords
    }
}

/// Interface for resolving and validating the toolchain a run executes.
public protocol ToolchainManaging: Sendable {
    func resolveToolchain(
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

    /// Depth Anything 3 is a development-only route; it is never shipped.
    public var isDa3: Bool {
        switch self {
        case .da3Runtime, .da3Base, .da3Small:
            return true
        case .core, .colmap, .msplat:
            return false
        }
    }
}

/// Capabilities a run needs from the toolchain.
public struct ToolchainCapabilityRequest: Sendable, Equatable {
    public var capabilities: Set<ToolchainCapability>

    public init(capabilities: Set<ToolchainCapability>) {
        self.capabilities = capabilities
    }
}

/// Resolves and validates the toolchain a run executes.
public final class ToolchainManager: @unchecked Sendable, ToolchainManaging {
    /// Errors that can occur while resolving or validating a toolchain.
    public enum ToolchainError: Error, LocalizedError {
        case artifactNotFound
        case missingBinary(String)
        case missingLibrary(String)
        case invalidToolchain(String)
        case fileIOFailed(String)

        public var errorDescription: String? {
            switch self {
            case .artifactNotFound:
                return "Toolchain artifact not found for this Mac."
            case .missingBinary(let name):
                return "Toolchain is missing required binary: \(name)."
            case .missingLibrary(let name):
                return "Toolchain is missing required library: \(name)."
            case .invalidToolchain(let message):
                return "Toolchain is invalid. \(message)"
            case .fileIOFailed(let message):
                return message
            }
        }
    }

    private struct ValidatedToolchain {
        var validated: Set<ToolchainCapability>
        var paths: ToolchainPaths
    }

    let fileManager = FileManager.default
    let runner: SubprocessRunning
    let appVersion: String
    private let locator: BundledToolchainLocator
    private let memoLock = NSLock()
    private var memo: [String: ValidatedToolchain] = [:]

    public init(
        runner: SubprocessRunning = SubprocessRunner(),
        appVersion: String = EasySplatReleaseIdentity.version(),
        locator: BundledToolchainLocator = BundledToolchainLocator()
    ) {
        self.runner = runner
        self.appVersion = appVersion
        self.locator = locator
    }

    /// Validates the toolchain this build is allowed to execute, once per
    /// capability set. Validation spawns the tools it attests, so repeat
    /// requests for an already validated set reuse the first result.
    public func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        guard !request.capabilities.isEmpty else {
            throw ToolchainError.invalidToolchain("No toolchain capabilities were requested.")
        }
        let source = try locator.locate()
        if case .appBundle = source, request.capabilities.contains(where: \.isDa3) {
            throw ToolchainError.artifactNotFound
        }

        let key = source.root.standardizedFileURL.path
        if let cached = memoizedPaths(key: key, satisfying: request.capabilities) {
            onProgress(1.0, "Tools ready")
            return cached
        }

        onProgress(-1.0, "Checking tools")
        let paths = try validateToolchain(
            root: source.root,
            dataRoot: source.dataRoot,
            metallib: source.metallib,
            requiredCapabilities: request.capabilities,
            repairExecutablePermissions: source.isDevelopmentOverride,
            toolchainIdentity: toolchainIdentity(for: source)
        )
        recordValidation(key: key, capabilities: request.capabilities, paths: paths)
        onProgress(1.0, "Tools ready")
        return paths
    }

    /// `root.lastPathComponent` is meaningless for a bundle, and the identity is
    /// persisted per project, so a bundle reports the app version instead.
    private func toolchainIdentity(for source: ToolchainSource) -> String {
        switch source {
        case .appBundle:
            return appVersion
        case .developmentOverride(let root):
            return "local-\(root.lastPathComponent)"
        }
    }

    private func memoizedPaths(
        key: String,
        satisfying capabilities: Set<ToolchainCapability>
    ) -> ToolchainPaths? {
        memoLock.lock()
        defer { memoLock.unlock() }
        guard let entry = memo[key], capabilities.isSubset(of: entry.validated) else {
            return nil
        }
        return entry.paths
    }

    private func recordValidation(
        key: String,
        capabilities: Set<ToolchainCapability>,
        paths: ToolchainPaths
    ) {
        memoLock.lock()
        defer { memoLock.unlock() }
        let validated = (memo[key]?.validated ?? []).union(capabilities)
        memo[key] = ValidatedToolchain(validated: validated, paths: paths)
    }
}
