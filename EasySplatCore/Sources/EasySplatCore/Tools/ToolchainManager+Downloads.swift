import CryptoKit
import Foundation

extension ToolchainManager {
    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let label: String
        private let onProgress: @Sendable (Double, String) -> Void
        private let fileManager: FileManager
        private let lock = NSLock()
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
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func attachTask(_ task: URLSessionDownloadTask) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = task
            lock.unlock()
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
            lock.lock()
            let isCompleted = completed
            lock.unlock()
            guard !isCompleted else { return }
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
            lock.lock()
            let isCompleted = completed
            lock.unlock()
            guard !isCompleted else { return }
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
            lock.lock()
            let isCompleted = completed
            lock.unlock()
            guard !isCompleted else { return }
            if let error {
                finish(with: error)
            } else {
                finish(with: ToolchainError.downloadFailed)
            }
        }

        private func finish(with error: Error?) {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
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

    func downloadManifest(url: URL) async throws -> ToolchainManifest {
        try await withTransientRetries {
            let (data, response) = try await urlSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolchainError.downloadFailed }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data) else {
                throw ToolchainError.invalidManifest
            }
            return manifest
        }
    }

    func downloadFile(
        url: URL,
        to destination: URL,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try await withTransientRetries(onRetry: { nextAttempt, _ in
            onProgress(-1.0, "Retrying \(label) (\(nextAttempt)/3)")
        }) {
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
    }

    func withTransientRetries<T>(
        maxAttempts: Int = 3,
        onRetry: ((Int, Error) -> Void)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        precondition(maxAttempts >= 1)
        var attempt = 1
        var delay = retryInitialDelayNanoseconds()

        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= maxAttempts || !isTransientRetryable(error) {
                    throw error
                }
                let nextAttempt = attempt + 1
                onRetry?(nextAttempt, error)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                if delay > 0 {
                    let doubled: UInt64
                    if delay > UInt64.max / 2 {
                        doubled = UInt64.max
                    } else {
                        doubled = delay * 2
                    }
                    delay = min(doubled, retryMaxDelayNanoseconds())
                }
                attempt = nextAttempt
            }
        }
    }

    func isTransientRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return isTransient(urlError)
        }
        if let toolchainError = error as? ToolchainError {
            switch toolchainError {
            case .downloadFailed, .invalidManifest:
                return true
            default:
                return false
            }
        }
        return false
    }

    func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .cannotLoadFromNetwork,
             .secureConnectionFailed,
             .resourceUnavailable,
             .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    func retryInitialDelayNanoseconds() -> UInt64 {
        shouldUseDataTaskForTests() ? 0 : 250_000_000
    }

    func retryMaxDelayNanoseconds() -> UInt64 {
        shouldUseDataTaskForTests() ? 0 : 2_000_000_000
    }

    func downloadFileViaDataTask(
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

    func shouldUseDataTaskForTests() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    func downloadFileViaDownloadTask(
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

    func sha256Hex(url: URL) throws -> String {
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

    func unzip(zipURL: URL, to destination: URL) throws {
        let result = try runner.run("/usr/bin/unzip", ["-o", zipURL.path, "-d", destination.path])
        guard result.exitCode == 0 else {
            throw ToolchainError.unzipFailed
        }
    }

    func localToolchainOverrideURL() -> URL? {
        guard let value = ProcessInfo.processInfo.environment["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    func installStateURL(root: URL) -> URL {
        root.appendingPathComponent(".easysplat_toolchain_state.json")
    }

    func loadInstallState(root: URL) -> ToolchainInstallState {
        let url = installStateURL(root: root)
        guard let data = try? Data(contentsOf: url) else {
            return ToolchainInstallState()
        }
        return (try? JSONDecoder().decode(ToolchainInstallState.self, from: data)) ?? ToolchainInstallState()
    }

    func saveInstallState(_ state: ToolchainInstallState, root: URL) throws {
        let url = installStateURL(root: root)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }

    func validatedArtifactURL(_ urlString: String) throws -> URL {
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

    func ensureArtifact(
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
        try enforceExpectedContents(
            artifact: artifact,
            root: root,
            unpackMessage: unpackMessage,
            onProgress: onProgress
        )

        state.installedArtifacts[name] = artifact.sha256
        try? saveInstallState(state, root: root)
    }

    func artifactLabel(for name: String) -> String {
        if name.hasSuffix("-core") { return "core" }
        if name.hasSuffix("-models") { return "models" }
        return name
    }

    func unpackingMessage(for name: String) -> String {
        if name.hasSuffix("-core") { return "Unpacking tools (core)" }
        if name.hasSuffix("-models") { return "Unpacking tools (models)" }
        return "Unpacking tools"
    }

    func expectedContentsCheck(
        artifact: ToolchainManifest.Artifact,
        root: URL
    ) -> (found: Int, expected: Int, missing: [String]) {
        var expected = 0
        var found = 0
        var missing: [String] = []
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
            } else {
                missing.append(normalized)
            }
        }
        return (found, expected, missing)
    }

    func enforceExpectedContents(
        artifact: ToolchainManifest.Artifact,
        root: URL,
        unpackMessage: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        let contentsCheck = expectedContentsCheck(artifact: artifact, root: root)
        onProgress(
            -1.0,
            "\(unpackMessage): found \(contentsCheck.found)/\(contentsCheck.expected) expected files"
        )
        guard contentsCheck.expected > 0, !contentsCheck.missing.isEmpty else {
            return
        }
        let missingPreview = contentsCheck.missing.prefix(5).joined(separator: ", ")
        let remaining = contentsCheck.missing.count - min(5, contentsCheck.missing.count)
        let suffix = remaining > 0 ? " (+\(remaining) more)" : ""
        throw ToolchainError.invalidToolchain(
            "Artifact '\(artifact.name)' is missing expected files: \(missingPreview)\(suffix)."
        )
    }
}
