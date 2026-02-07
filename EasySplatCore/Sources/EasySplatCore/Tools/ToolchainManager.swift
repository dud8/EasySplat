import Foundation
import CryptoKit

public struct ToolchainPaths: Sendable {
    public var root: URL
    public var colmap: URL
    public var glomap: URL
    public var brush: URL
    public var vggt: VggtToolchain
    public var fastvggt: FastVggtToolchain

    public init(
        root: URL,
        colmap: URL,
        glomap: URL,
        brush: URL,
        vggt: VggtToolchain,
        fastvggt: FastVggtToolchain
    ) {
        self.root = root
        self.colmap = colmap
        self.glomap = glomap
        self.brush = brush
        self.vggt = vggt
        self.fastvggt = fastvggt
    }
}

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

public protocol ToolchainManaging: Sendable {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths
}

public final class ToolchainManager: @unchecked Sendable, ToolchainManaging {
    private struct ToolchainInstallState: Codable, Sendable {
        var installedArtifacts: [String: String]

        init(installedArtifacts: [String: String] = [:]) {
            self.installedArtifacts = installedArtifacts
        }
    }

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
    private let urlSession: URLSession

    public init(runner: SubprocessRunning = SubprocessRunner(), urlSession: URLSession = .shared) {
        self.runner = runner
        self.urlSession = urlSession
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
        if let localRoot = localToolchainOverrideURL() {
            onProgress(-1.0, "Checking installed tools")
            onProgress(-1.0, "Validating tools")
            let toolchain = try validateToolchain(root: localRoot)
            onProgress(1.0, "Tools ready (local)")
            return toolchain
        }

        onProgress(-1.0, "Checking installed tools")
        let manifest = try await downloadManifest(url: manifestURL)
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
            do {
                if fileManager.fileExists(atPath: versionedRoot.path) {
                    try? fileManager.removeItem(at: versionedRoot)
                }
                try fileManager.createDirectory(at: versionedRoot, withIntermediateDirectories: true)

                let artifactURL = try validatedArtifactURL(artifact.url)
                let zipURL = versionedRoot.appendingPathComponent("toolchain.zip")
                try await downloadFile(url: artifactURL, to: zipURL, label: "Downloading tools", onProgress: onProgress)

                let computedHash = try sha256Hex(url: zipURL)
                guard computedHash.lowercased() == artifact.sha256.lowercased() else {
                    throw ToolchainError.hashMismatch
                }

                onProgress(-1.0, "Unpacking tools")
                try unzip(zipURL: zipURL, to: versionedRoot)
                try fileManager.removeItem(at: zipURL)

                onProgress(-1.0, "Validating tools")
                let toolchain = try validateToolchain(root: versionedRoot)
                onProgress(1.0, "Tools ready")
                return toolchain
            } catch {
                try? fileManager.removeItem(at: versionedRoot)
                throw error
            }
        }

        // Split toolchain: keep core binaries/env small-ish, ship model weights separately.
        let coreName = "\(targetName)-core"
        let modelsName = "\(targetName)-models"
        guard let coreArtifact = manifest.artifacts.first(where: { $0.name == coreName }),
              let modelsArtifact = manifest.artifacts.first(where: { $0.name == modelsName }) else {
            throw ToolchainError.artifactNotFound
        }

        do {
            try fileManager.createDirectory(at: versionedRoot, withIntermediateDirectories: true)

            var state = loadInstallState(root: versionedRoot)
            try await ensureArtifact(coreArtifact, root: versionedRoot, state: &state, onProgress: onProgress)
            try await ensureArtifact(modelsArtifact, root: versionedRoot, state: &state, onProgress: onProgress)

            onProgress(-1.0, "Validating tools")
            let toolchain = try validateToolchain(root: versionedRoot)
            onProgress(1.0, "Tools ready")
            return toolchain
        } catch {
            try? fileManager.removeItem(at: versionedRoot)
            throw error
        }
    }

    private func validateToolchain(root: URL) throws -> ToolchainPaths {
        let colmap = root.appendingPathComponent("bin/colmap")
        let glomap = root.appendingPathComponent("bin/glomap")
        let brush = root.appendingPathComponent("bin/brush")
        let brushReal = root.appendingPathComponent("bin/brush.real")
        ensureExecutable(at: colmap)
        ensureExecutable(at: glomap)
        ensureExecutable(at: brush)
        guard fileManager.isExecutableFile(atPath: colmap.path) else { throw ToolchainError.missingBinary("colmap") }
        guard fileManager.isExecutableFile(atPath: glomap.path) else { throw ToolchainError.missingBinary("glomap") }
        guard fileManager.isExecutableFile(atPath: brush.path) else { throw ToolchainError.missingBinary("brush") }
        if fileHasShebang(at: brush) {
            ensureExecutable(at: brushReal)
            guard fileManager.isExecutableFile(atPath: brushReal.path) else { throw ToolchainError.missingBinary("brush.real") }
        }

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

        let brushCheck = try runner.run(brush.path, ["--help"])
        guard brushCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("Brush failed to launch (exit \(brushCheck.exitCode)).")
        }

        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let vggtSfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let vggtPython = vggtRoot.appendingPathComponent("python/bin/python3")
        let vggtModels = vggtRoot.appendingPathComponent("models", isDirectory: true)
        let vggtModelFile = vggtModels.appendingPathComponent("vggt_model.pt")
        // Upstream VGGT uses namespace packages (no __init__.py), so validate via a stable module file.
        let vggtVendorSentinel = vggtRoot.appendingPathComponent("vendor/vggt/vggt/models/vggt.py")

        guard fileManager.fileExists(atPath: vggtSfmTool.path) else {
            throw ToolchainError.missingBinary("vggt_mps/bin/easysplat_vggt_sfm")
        }
        guard fileManager.fileExists(atPath: vggtPython.path) else {
            throw ToolchainError.missingBinary("vggt_mps/python/bin/python3")
        }
        guard fileManager.fileExists(atPath: vggtModels.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/models")
        }
        guard fileManager.fileExists(atPath: vggtModelFile.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/models/vggt_model.pt")
        }
        guard fileManager.fileExists(atPath: vggtVendorSentinel.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/vendor/vggt")
        }

        ensureExecutable(at: vggtSfmTool)
        ensureExecutable(at: vggtPython)

        let vggtPythonArch = try? runner.run("/usr/bin/file", [vggtPython.path])
        if let output = vggtPythonArch?.stdout.lowercased(), !output.contains("arm64") {
            throw ToolchainError.invalidToolchain("vggt_mps python is not arm64 (Rosetta build detected).")
        }

        let vggt = VggtToolchain(
            root: vggtRoot,
            sfmTool: vggtSfmTool,
            python: vggtPython,
            models: vggtModels
        )

        let fastvggtRoot = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let fastvggtSfmTool = fastvggtRoot.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let fastvggtPython = fastvggtRoot.appendingPathComponent("python/bin/python3")
        let fastvggtModels = fastvggtRoot.appendingPathComponent("models", isDirectory: true)
        let fastvggtModelFile = fastvggtModels.appendingPathComponent("fastvggt_model.pt")
        let fastvggtVendorSentinel = fastvggtRoot.appendingPathComponent("vendor/fastvggt/vggt/models/vggt.py")

        guard fileManager.fileExists(atPath: fastvggtSfmTool.path) else {
            throw ToolchainError.missingBinary("fastvggt_mps/bin/easysplat_fastvggt_sfm")
        }
        guard fileManager.fileExists(atPath: fastvggtPython.path) else {
            throw ToolchainError.missingBinary("fastvggt_mps/python/bin/python3")
        }
        guard fileManager.fileExists(atPath: fastvggtModels.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/models")
        }
        guard fileManager.fileExists(atPath: fastvggtModelFile.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/models/fastvggt_model.pt")
        }
        guard fileManager.fileExists(atPath: fastvggtVendorSentinel.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/vendor/fastvggt")
        }

        ensureExecutable(at: fastvggtSfmTool)
        ensureExecutable(at: fastvggtPython)

        let fastvggtPythonArch = try? runner.run("/usr/bin/file", [fastvggtPython.path])
        if let output = fastvggtPythonArch?.stdout.lowercased(), !output.contains("arm64") {
            throw ToolchainError.invalidToolchain("fastvggt_mps python is not arm64 (Rosetta build detected).")
        }

        let fastvggt = FastVggtToolchain(
            root: fastvggtRoot,
            sfmTool: fastvggtSfmTool,
            python: fastvggtPython,
            models: fastvggtModels
        )

        return ToolchainPaths(
            root: root,
            colmap: colmap,
            glomap: glomap,
            brush: brush,
            vggt: vggt,
            fastvggt: fastvggt
        )
    }

    private func ensureExecutable(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if fileManager.isExecutableFile(atPath: url.path) { return }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fileHasShebang(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
        return data[0] == 0x23 && data[1] == 0x21
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let label: String
        private let onProgress: @Sendable (Double, String) -> Void
        private let fileManager: FileManager
        private var continuation: CheckedContinuation<Void, Error>?
        private weak var task: URLSessionDownloadTask?
        private var completed = false
        private let startedAt = Date()
        private var lastUpdate = Date.distantPast

        init(
            destination: URL,
            label: String,
            onProgress: @escaping @Sendable (Double, String) -> Void,
            fileManager: FileManager
        ) {
            self.destination = destination
            self.label = label
            self.onProgress = onProgress
            self.fileManager = fileManager
        }

        func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            if completed {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
        }

        func attachTask(_ task: URLSessionDownloadTask) {
            self.task = task
        }

        func cancel() {
            task?.cancel()
            finish(with: CancellationError())
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let now = Date()
            if now.timeIntervalSince(lastUpdate) < 0.2 {
                return
            }
            lastUpdate = now
            let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
            let rate = Int64(Double(totalBytesWritten) / elapsed)
            let message = "\(label) \(formatBytes(totalBytesWritten))/\(formatBytes(totalBytesExpectedToWrite)) (\(formatBytes(rate))/s)"
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), message)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard !completed else { return }
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                finish(with: ToolchainError.downloadFailed)
                return
            }

            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: location, to: destination)
                if let expected = downloadTask.response?.expectedContentLength, expected > 0 {
                    let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                    let rate = Int64(Double(expected) / elapsed)
                    let message = "\(label) \(formatBytes(expected))/\(formatBytes(expected)) (\(formatBytes(rate))/s)"
                    onProgress(1.0, message)
                } else {
                    onProgress(1.0, "\(label) downloaded")
                }
                finish(with: nil)
            } catch {
                finish(with: ToolchainError.fileIOFailed("Failed to write toolchain to disk. \(error.localizedDescription)"))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !completed else { return }
            if let error {
                finish(with: error)
            } else {
                finish(with: ToolchainError.downloadFailed)
            }
        }

        private func finish(with error: Error?) {
            guard !completed else { return }
            completed = true
            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        }

        private func formatBytes(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
    }

    private func downloadManifest(url: URL) async throws -> ToolchainManifest {
        let (data, response) = try await urlSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolchainError.downloadFailed }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data) else {
            throw ToolchainError.invalidManifest
        }
        return manifest
    }

    private func downloadFile(
        url: URL,
        to destination: URL,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        do {
            if shouldUseDataTaskForTests() {
                try await downloadFileViaDataTask(url: url, to: destination, label: label, onProgress: onProgress)
                return
            }
            try await downloadFileViaDownloadTask(url: url, to: destination, label: label, onProgress: onProgress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolchainError {
            throw error
        } catch let error as URLError {
            throw error
        } catch {
            throw ToolchainError.fileIOFailed("Failed to write toolchain to disk. \(error.localizedDescription)")
        }
    }

    private func downloadFileViaDataTask(
        url: URL,
        to destination: URL,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        let (data, response) = try await urlSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolchainError.downloadFailed }
        try data.write(to: destination, options: [.atomic])
        onProgress(1.0, "\(label) downloaded")
    }

    private func shouldUseDataTaskForTests() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    private func downloadFileViaDownloadTask(
        url: URL,
        to destination: URL,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }

        let delegate = DownloadDelegate(
            destination: destination,
            label: label,
            onProgress: onProgress,
            fileManager: fileManager
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let request = URLRequest(url: url)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                if Task.isCancelled {
                    delegate.cancel()
                    return
                }
                let task = session.downloadTask(with: request)
                delegate.attachTask(task)
                if Task.isCancelled {
                    delegate.cancel()
                    return
                }
                task.resume()
            }
        }, onCancel: {
            delegate.cancel()
        })
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

    private func localToolchainOverrideURL() -> URL? {
        guard let value = ProcessInfo.processInfo.environment["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private func installStateURL(root: URL) -> URL {
        root.appendingPathComponent(".easysplat_toolchain_state.json")
    }

    private func loadInstallState(root: URL) -> ToolchainInstallState {
        let url = installStateURL(root: root)
        guard let data = try? Data(contentsOf: url) else {
            return ToolchainInstallState()
        }
        return (try? JSONDecoder().decode(ToolchainInstallState.self, from: data)) ?? ToolchainInstallState()
    }

    private func saveInstallState(_ state: ToolchainInstallState, root: URL) throws {
        let url = installStateURL(root: root)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }

    private func validatedArtifactURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ToolchainError.invalidArtifactURL(urlString)
        }
        guard let scheme = url.scheme else {
            throw ToolchainError.invalidArtifactURL(urlString)
        }
        if scheme != "file", url.host == nil {
            throw ToolchainError.invalidArtifactURL(urlString)
        }
        return url
    }

    private func ensureArtifact(
        _ artifact: ToolchainManifest.Artifact,
        root: URL,
        state: inout ToolchainInstallState,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let name = artifact.name
        let expectedSha = artifact.sha256.lowercased()

        if let installedSha = state.installedArtifacts[name]?.lowercased(),
           installedSha == expectedSha,
           artifactLooksInstalled(name: name, root: root) {
            return
        }

        let url = try validatedArtifactURL(artifact.url)
        let zipURL = root.appendingPathComponent("\(name).zip")

        let label: String = {
            if name.hasSuffix("-core") { return "Downloading tools (core)" }
            if name.hasSuffix("-models") { return "Downloading tools (models)" }
            return "Downloading tools (\(name))"
        }()

        try await downloadFile(url: url, to: zipURL, label: label, onProgress: onProgress)

        let computedHash = try sha256Hex(url: zipURL)
        guard computedHash.lowercased() == expectedSha else {
            throw ToolchainError.hashMismatch
        }
        onProgress(-1.0, "Verified download integrity (\(artifactLabel(for: name)))")

        let unpackMessage = unpackingMessage(for: name)
        onProgress(-1.0, unpackMessage)

        try unzip(zipURL: zipURL, to: root)
        try? fileManager.removeItem(at: zipURL)
        let contentsCheck = expectedContentsCheck(artifact: artifact, root: root)
        onProgress(
            -1.0,
            "\(unpackMessage): found \(contentsCheck.found)/\(contentsCheck.expected) expected files"
        )

        state.installedArtifacts[name] = artifact.sha256
        try? saveInstallState(state, root: root)
    }

    private func artifactLabel(for name: String) -> String {
        if name.hasSuffix("-core") { return "core" }
        if name.hasSuffix("-models") { return "models" }
        return name
    }

    private func unpackingMessage(for name: String) -> String {
        if name.hasSuffix("-core") { return "Unpacking tools (core)" }
        if name.hasSuffix("-models") { return "Unpacking tools (models)" }
        return "Unpacking tools"
    }

    private func expectedContentsCheck(
        artifact: ToolchainManifest.Artifact,
        root: URL
    ) -> (found: Int, expected: Int) {
        var expected = 0
        var found = 0
        for rawPath in artifact.contents {
            var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            while normalized.hasPrefix("/") {
                normalized.removeFirst()
            }
            while normalized.hasSuffix("/") {
                normalized.removeLast()
            }
            guard !normalized.isEmpty else { continue }
            expected += 1
            let expectedURL = root.appendingPathComponent(normalized)
            if fileManager.fileExists(atPath: expectedURL.path) {
                found += 1
            }
        }
        return (found, expected)
    }

    private func artifactLooksInstalled(name: String, root: URL) -> Bool {
        if name.hasSuffix("-core") {
            return coreToolchainLooksInstalled(root: root)
        }
        if name.hasSuffix("-models") {
            return modelsToolchainLooksInstalled(root: root)
        }
        return false
    }

    private func coreToolchainLooksInstalled(root: URL) -> Bool {
        let colmap = root.appendingPathComponent("bin/colmap")
        let glomap = root.appendingPathComponent("bin/glomap")
        let brush = root.appendingPathComponent("bin/brush")
        let brushReal = root.appendingPathComponent("bin/brush.real")
        let libcrypto = root.appendingPathComponent("lib/libcrypto.3.dylib")
        let libssl = root.appendingPathComponent("lib/libssl.3.dylib")
        let vggt = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let vggtSfmTool = vggt.appendingPathComponent("bin/easysplat_vggt_sfm")
        let vggtPython = vggt.appendingPathComponent("python/bin/python3")
        // Upstream VGGT uses namespace packages (no __init__.py). Validate via a stable module file.
        let vggtVendorSentinel = vggt.appendingPathComponent("vendor/vggt/vggt/models/vggt.py")
        let fastvggt = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let fastvggtSfmTool = fastvggt.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let fastvggtPython = fastvggt.appendingPathComponent("python/bin/python3")
        let fastvggtVendorSentinel = fastvggt.appendingPathComponent("vendor/fastvggt/vggt/models/vggt.py")

        let brushOK: Bool = {
            guard fileManager.isExecutableFile(atPath: brush.path) else { return false }
            if fileHasShebang(at: brush) {
                return fileManager.isExecutableFile(atPath: brushReal.path)
            }
            return true
        }()

        return fileManager.isExecutableFile(atPath: colmap.path)
            && fileManager.isExecutableFile(atPath: glomap.path)
            && brushOK
            && fileManager.fileExists(atPath: libcrypto.path)
            && fileManager.fileExists(atPath: libssl.path)
            && fileManager.fileExists(atPath: vggtSfmTool.path)
            && fileManager.fileExists(atPath: vggtPython.path)
            && fileManager.fileExists(atPath: vggtVendorSentinel.path)
            && fileManager.fileExists(atPath: fastvggtSfmTool.path)
            && fileManager.fileExists(atPath: fastvggtPython.path)
            && fileManager.fileExists(atPath: fastvggtVendorSentinel.path)
    }

    private func modelsToolchainLooksInstalled(root: URL) -> Bool {
        let vggtModel = root
            .appendingPathComponent("vggt_mps/models/vggt_model.pt")
        let fastvggtModel = root
            .appendingPathComponent("fastvggt_mps/models/fastvggt_model.pt")
        return fileManager.fileExists(atPath: vggtModel.path)
            && fileManager.fileExists(atPath: fastvggtModel.path)
    }
}

#if DEBUG
extension ToolchainManager {
    func test_validateToolchain(root: URL) throws -> ToolchainPaths {
        try validateToolchain(root: root)
    }

    func test_coreToolchainLooksInstalled(root: URL) -> Bool {
        coreToolchainLooksInstalled(root: root)
    }

    func test_modelsToolchainLooksInstalled(root: URL) -> Bool {
        modelsToolchainLooksInstalled(root: root)
    }

    func test_fileHasShebang(at url: URL) -> Bool {
        fileHasShebang(at: url)
    }

    func test_sha256Hex(url: URL) throws -> String {
        try sha256Hex(url: url)
    }

    func test_ensureArtifact(
        _ artifact: ToolchainManifest.Artifact,
        root: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        var state = ToolchainInstallState()
        try await ensureArtifact(artifact, root: root, state: &state, onProgress: onProgress)
    }
}
#endif
