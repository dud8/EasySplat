import Foundation
import CryptoKit

public struct ToolchainPaths: Sendable {
    public var root: URL
    public var colmap: URL
    public var glomap: URL
    public var brush: URL
    public var learnedSfm: LearnedSfmToolchain

    public init(root: URL, colmap: URL, glomap: URL, brush: URL, learnedSfm: LearnedSfmToolchain) {
        self.root = root
        self.colmap = colmap
        self.glomap = glomap
        self.brush = brush
        self.learnedSfm = learnedSfm
    }
}

public struct LearnedSfmToolchain: Sendable {
    public var root: URL
    public var matchTool: URL
    public var python: URL
    public var models: URL

    public init(root: URL, matchTool: URL, python: URL, models: URL) {
        self.root = root
        self.matchTool = matchTool
        self.python = python
        self.models = models
    }
}

public protocol ToolchainManaging: Sendable {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths
}

public final class ToolchainManager: @unchecked Sendable, ToolchainManaging {
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

    private let fileManager = FileManager.default
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func toolchainRoot() -> URL {
        (try? toolchainRootURL()) ?? fileManager.temporaryDirectory.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)
    }

    private func toolchainRootURL() throws -> URL {
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
        let manifest = try await downloadManifest(url: manifestURL)
        guard manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            throw ToolchainError.signatureFailed
        }
        guard let artifact = manifest.artifacts.first(where: { $0.name == targetName }) else {
            throw ToolchainError.artifactNotFound
        }

        let artifactURL: URL
        if let url = URL(string: artifact.url) {
            artifactURL = url
        } else {
            throw ToolchainError.invalidArtifactURL(artifact.url)
        }

        let versionedRoot = try toolchainRootURL().appendingPathComponent(manifest.version, isDirectory: true)
        if fileManager.fileExists(atPath: versionedRoot.path) {
            do {
                return try validateToolchain(root: versionedRoot)
            } catch {
                try? fileManager.removeItem(at: versionedRoot)
            }
        }

        do {
            try fileManager.createDirectory(at: versionedRoot, withIntermediateDirectories: true)
            let zipURL = versionedRoot.appendingPathComponent("toolchain.zip")
            try await downloadFile(url: artifactURL, to: zipURL, onProgress: onProgress)

            let computedHash = try sha256Hex(url: zipURL)
            guard computedHash.lowercased() == artifact.sha256.lowercased() else {
                throw ToolchainError.hashMismatch
            }

            try unzip(zipURL: zipURL, to: versionedRoot)
            try fileManager.removeItem(at: zipURL)

            return try validateToolchain(root: versionedRoot)
        } catch {
            try? fileManager.removeItem(at: versionedRoot)
            throw error
        }
    }

    private func validateToolchain(root: URL) throws -> ToolchainPaths {
        let colmap = root.appendingPathComponent("bin/colmap")
        let glomap = root.appendingPathComponent("bin/glomap")
        let brush = root.appendingPathComponent("bin/brush")
        ensureExecutable(at: colmap)
        ensureExecutable(at: glomap)
        ensureExecutable(at: brush)
        guard fileManager.isExecutableFile(atPath: colmap.path) else { throw ToolchainError.missingBinary("colmap") }
        guard fileManager.isExecutableFile(atPath: glomap.path) else { throw ToolchainError.missingBinary("glomap") }
        guard fileManager.isExecutableFile(atPath: brush.path) else { throw ToolchainError.missingBinary("brush") }

        // Validate OpenSSL dylibs and that COLMAP/GLOMAP can at least launch. Avoid requiring Xcode tools
        // (like `otool`) at runtime, since end users may not have them installed.
        let libcrypto = root.appendingPathComponent("lib/libcrypto.3.dylib")
        let libssl = root.appendingPathComponent("lib/libssl.3.dylib")
        guard fileManager.fileExists(atPath: libcrypto.path) else { throw ToolchainError.missingLibrary("libcrypto.3.dylib") }
        guard fileManager.fileExists(atPath: libssl.path) else { throw ToolchainError.missingLibrary("libssl.3.dylib") }

        let colmapCheck = try runner.run(colmap.path, ["-h"])
        guard colmapCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("COLMAP failed to launch (exit \(colmapCheck.exitCode)).")
        }

        let glomapCheck = try runner.run(glomap.path, ["--help"])
        if glomapCheck.exitCode != 0 {
            let text = "\(glomapCheck.stdout)\n\(glomapCheck.stderr)".lowercased()
            if text.contains("library not loaded") || text.contains("no lc_rpath") || text.contains("@rpath/libcrypto.3.dylib") {
                throw ToolchainError.invalidToolchain("GLOMAP failed to launch (missing dylib/rpath).")
            }
        }

        let learnedRoot = root.appendingPathComponent("learned_sfm", isDirectory: true)
        let learnedMatchTool = learnedRoot.appendingPathComponent("bin/easysplat_match")
        let learnedPython = learnedRoot.appendingPathComponent("python/bin/python3")
        let learnedModels = learnedRoot.appendingPathComponent("models", isDirectory: true)

        guard fileManager.fileExists(atPath: learnedMatchTool.path) else {
            throw ToolchainError.missingBinary("learned_sfm/bin/easysplat_match")
        }
        guard fileManager.fileExists(atPath: learnedPython.path) else {
            throw ToolchainError.missingBinary("learned_sfm/python/bin/python3")
        }
        guard fileManager.fileExists(atPath: learnedModels.path) else {
            throw ToolchainError.missingLibrary("learned_sfm/models")
        }

        ensureExecutable(at: learnedMatchTool)
        ensureExecutable(at: learnedPython)

        let learnedSfm = LearnedSfmToolchain(
            root: learnedRoot,
            matchTool: learnedMatchTool,
            python: learnedPython,
            models: learnedModels
        )

        return ToolchainPaths(root: root, colmap: colmap, glomap: glomap, brush: brush, learnedSfm: learnedSfm)
    }

    private func ensureExecutable(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if fileManager.isExecutableFile(atPath: url.path) { return }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func downloadManifest(url: URL) async throws -> ToolchainManifest {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolchainError.downloadFailed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data) else {
            throw ToolchainError.invalidManifest
        }
        return manifest
    }

    private func downloadFile(url: URL, to destination: URL, onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolchainError.downloadFailed }

        let expected = response.expectedContentLength
        let writer = BufferedByteStreamWriter(fileManager: fileManager)
        do {
            try await writer.write(bytes: stream, to: destination, expectedLength: expected, onProgress: onProgress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw error
        } catch {
            throw ToolchainError.fileIOFailed("Failed to write toolchain to disk. \(error.localizedDescription)")
        }
    }

    private func sha256Hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func unzip(zipURL: URL, to destination: URL) throws {
        let result = try runner.run("/usr/bin/unzip", ["-o", zipURL.path, "-d", destination.path])
        guard result.exitCode == 0 else {
            throw ToolchainError.unzipFailed
        }
    }
}
