import Foundation

/// Resolved paths for a validated EasySplat toolchain installation.
public struct ToolchainPaths: Sendable {
    public var root: URL
    public var colmap: URL
    public var glomap: URL
    public var brush: URL
    public var mapanything: MapAnythingToolchain
    public var vggt: VggtToolchain
    public var fastvggt: FastVggtToolchain

    public init(
        root: URL,
        colmap: URL,
        glomap: URL,
        brush: URL,
        mapanything: MapAnythingToolchain,
        vggt: VggtToolchain,
        fastvggt: FastVggtToolchain
    ) {
        self.root = root
        self.colmap = colmap
        self.glomap = glomap
        self.brush = brush
        self.mapanything = mapanything
        self.vggt = vggt
        self.fastvggt = fastvggt
    }

    public init(
        root: URL,
        colmap: URL,
        glomap: URL,
        brush: URL,
        vggt: VggtToolchain,
        fastvggt: FastVggtToolchain
    ) {
        let mapAnythingRoot = root.appendingPathComponent("mapanything_mps", isDirectory: true)
        let mapanything = MapAnythingToolchain(
            root: mapAnythingRoot,
            sfmTool: mapAnythingRoot.appendingPathComponent("bin/easysplat_mapanything_sfm"),
            python: mapAnythingRoot.appendingPathComponent("python/bin/python3"),
            models: mapAnythingRoot.appendingPathComponent("models", isDirectory: true),
            modelBundle: mapAnythingRoot.appendingPathComponent("models/map-anything-apache", isDirectory: true),
            dinov2Weights: mapAnythingRoot.appendingPathComponent("models/dinov2/dinov2_vitg14_pretrain.pth")
        )
        self.init(
            root: root,
            colmap: colmap,
            glomap: glomap,
            brush: brush,
            mapanything: mapanything,
            vggt: vggt,
            fastvggt: fastvggt
        )
    }
}

/// Paths for the bundled MapAnything runtime inside a toolchain install.
public struct MapAnythingToolchain: Sendable {
    public var root: URL
    public var sfmTool: URL
    public var python: URL
    public var models: URL
    public var modelBundle: URL
    public var dinov2Weights: URL

    public init(root: URL, sfmTool: URL, python: URL, models: URL, modelBundle: URL, dinov2Weights: URL) {
        self.root = root
        self.sfmTool = sfmTool
        self.python = python
        self.models = models
        self.modelBundle = modelBundle
        self.dinov2Weights = dinov2Weights
    }
}

/// Paths for the bundled VGGT runtime inside a toolchain install.
public struct VggtToolchain: Sendable {
    public var root: URL
    public var sfmTool: URL
    public var python: URL
    public var models: URL

    public init(root: URL, sfmTool: URL, python: URL, models: URL) {
        self.root = root
        self.sfmTool = sfmTool
        self.python = python
        self.models = models
    }
}

/// Paths for the bundled FastVGGT runtime inside a toolchain install.
public struct FastVggtToolchain: Sendable {
    public var root: URL
    public var sfmTool: URL
    public var python: URL
    public var models: URL

    public init(root: URL, sfmTool: URL, python: URL, models: URL) {
        self.root = root
        self.sfmTool = sfmTool
        self.python = python
        self.models = models
    }
}

/// Interface for acquiring and validating an EasySplat toolchain.
public protocol ToolchainManaging: Sendable {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths
}

/// Downloads, verifies, installs, and validates toolchains for the app.
public final class ToolchainManager: @unchecked Sendable, ToolchainManaging {
    struct ToolchainInstallState: Codable, Sendable {
        var installedArtifacts: [String: String]

        init(installedArtifacts: [String: String] = [:]) {
            self.installedArtifacts = installedArtifacts
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
            }
        }
    }

    let fileManager = FileManager.default
    let runner: SubprocessRunning
    let urlSession: URLSession

    public init(runner: SubprocessRunning = SubprocessRunner(), urlSession: URLSession = .shared) {
        self.runner = runner
        self.urlSession = urlSession
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
        if let localRoot = localToolchainOverrideURL() {
            onProgress(-1.0, "Checking installed tools")
            onProgress(-1.0, "Validating tools")
            let toolchain = try validateToolchain(root: localRoot)
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
                if let cached = try? loadBestCachedToolchain() {
                    onProgress(1.0, "Tools ready (offline cached)")
                    return cached
                }
            }
            throw error
        }
        guard manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            throw ToolchainError.signatureFailed
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
