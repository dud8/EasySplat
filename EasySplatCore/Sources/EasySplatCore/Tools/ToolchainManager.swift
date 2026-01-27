import Foundation
import CryptoKit

public struct ToolchainPaths: Sendable {
    public var root: URL
    public var colmap: URL
    public var glomap: URL
    public var brush: URL
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
    public enum ToolchainError: Error {
        case invalidManifest
        case signatureFailed
        case artifactNotFound
        case downloadFailed
        case hashMismatch
        case unzipFailed
        case missingBinary(String)
    }

    private let fileManager = FileManager.default
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func toolchainRoot() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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

        let versionedRoot = toolchainRoot().appendingPathComponent(manifest.version, isDirectory: true)
        if fileManager.fileExists(atPath: versionedRoot.path) {
            return try validateToolchain(root: versionedRoot)
        }

        try fileManager.createDirectory(at: versionedRoot, withIntermediateDirectories: true)
        let zipURL = versionedRoot.appendingPathComponent("toolchain.zip")
        try await downloadFile(url: URL(string: artifact.url)!, to: zipURL, onProgress: onProgress)

        let computedHash = try sha256Hex(url: zipURL)
        guard computedHash.lowercased() == artifact.sha256.lowercased() else {
            throw ToolchainError.hashMismatch
        }

        try unzip(zipURL: zipURL, to: versionedRoot)
        try fileManager.removeItem(at: zipURL)

        return try validateToolchain(root: versionedRoot)
    }

    private func validateToolchain(root: URL) throws -> ToolchainPaths {
        let colmap = root.appendingPathComponent("bin/colmap")
        let glomap = root.appendingPathComponent("bin/glomap")
        let brush = root.appendingPathComponent("bin/brush")
        guard fileManager.isExecutableFile(atPath: colmap.path) else { throw ToolchainError.missingBinary("colmap") }
        guard fileManager.isExecutableFile(atPath: glomap.path) else { throw ToolchainError.missingBinary("glomap") }
        guard fileManager.isExecutableFile(atPath: brush.path) else { throw ToolchainError.missingBinary("brush") }
        return ToolchainPaths(root: root, colmap: colmap, glomap: glomap, brush: brush)
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
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        var received: Int64 = 0
        for try await byte in stream {
            handle.write(Data([byte]))
            received += 1
            if expected > 0 {
                onProgress(Double(received) / Double(expected), "Downloading toolchain")
            }
        }
        try handle.close()
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
