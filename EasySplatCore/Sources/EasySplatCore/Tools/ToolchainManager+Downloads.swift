import CryptoKit
import Darwin
import Foundation

extension ToolchainManager {
    static let installStateFilename = ".easysplat_toolchain_state.json"

    // The signed manifest carries the exact Python runtime closure. Keep the
    // unauthenticated response and cached receipt bounded above that real size.
    static let maximumManifestDownloadBytes = 16 * 1_024 * 1_024
    private static let maximumInstallStateBytes = 16 * 1_024 * 1_024

    final class RedirectValidationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let validate: @Sendable (URL) throws -> Void

        init(validate: @escaping @Sendable (URL) throws -> Void) {
            self.validate = validate
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                completionHandler(nil)
                return
            }
            do {
                try validate(url)
                completionHandler(request)
            } catch {
                completionHandler(nil)
            }
        }
    }

    final class ManifestDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maximumBytes: Int
        private let validateRedirect: @Sendable (URL) throws -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private weak var task: URLSessionDataTask?
        private var data = Data()
        private var completed = false

        init(
            maximumBytes: Int,
            validateRedirect: @escaping @Sendable (URL) throws -> Void
        ) {
            self.maximumBytes = maximumBytes
            self.validateRedirect = validateRedirect
        }

        func setContinuation(_ continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func attachTask(_ task: URLSessionDataTask) {
            lock.lock()
            let shouldCancel = completed
            self.task = task
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
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
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                finish(with: ToolchainError.downloadFailed)
                return
            }
            guard http.statusCode == 200 else {
                completionHandler(.cancel)
                let resourceURL = http.url
                    ?? dataTask.currentRequest?.url
                    ?? dataTask.originalRequest?.url
                if let resourceURL {
                    finish(
                        with: ToolchainError.manifestHTTPFailure(
                            statusCode: http.statusCode,
                            resourceURL: resourceURL
                        )
                    )
                } else {
                    finish(with: ToolchainError.downloadFailed)
                }
                return
            }

            let expectedLength = response.expectedContentLength
            guard expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
                completionHandler(.cancel)
                finish(with: ToolchainError.manifestTooLarge(maximumBytes: maximumBytes))
                return
            }

            if expectedLength > 0 {
                lock.lock()
                if !completed {
                    data.reserveCapacity(Int(expectedLength))
                }
                lock.unlock()
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            var failure: Error?

            lock.lock()
            if !completed {
                if chunk.count > maximumBytes || data.count > maximumBytes - chunk.count {
                    failure = ToolchainError.manifestTooLarge(maximumBytes: maximumBytes)
                } else {
                    data.append(chunk)
                }
            }
            lock.unlock()

            if let failure {
                dataTask.cancel()
                finish(with: failure)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(with: error)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                completionHandler(nil)
                finish(with: ToolchainError.invalidArtifactURL("redirect without URL"))
                return
            }
            do {
                try validateRedirect(url)
                completionHandler(request)
            } catch {
                completionHandler(nil)
                finish(with: error)
            }
        }

        private func finish(with error: Error?) {
            let continuation: CheckedContinuation<Data, Error>?
            let completedData: Data

            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            completedData = data
            data.removeAll(keepingCapacity: false)
            lock.unlock()

            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: completedData)
            }
        }
    }

    enum ResumableResponseMode: Equatable {
        case append
        case restart
    }

    final class ResumableDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partialURL: URL
        private let expectedSize: UInt64
        private let initialOffset: UInt64
        private let label: String
        private let onProgress: @Sendable (Double, String) -> Void
        private let fileManager: FileManager
        private let validateRedirect: @Sendable (URL) throws -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private weak var task: URLSessionDataTask?
        private var fileHandle: FileHandle?
        private var receivedBytes: UInt64
        private var completed = false
        private let startedAt = Date()
        private var lastUpdate = Date.distantPast

        init(
            partialURL: URL,
            expectedSize: UInt64,
            initialOffset: UInt64,
            label: String,
            onProgress: @escaping @Sendable (Double, String) -> Void,
            fileManager: FileManager,
            validateRedirect: @escaping @Sendable (URL) throws -> Void
        ) {
            self.partialURL = partialURL
            self.expectedSize = expectedSize
            self.initialOffset = initialOffset
            self.label = label
            self.onProgress = onProgress
            self.fileManager = fileManager
            self.validateRedirect = validateRedirect
            self.receivedBytes = initialOffset
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

        func attachTask(_ task: URLSessionDataTask) {
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
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                finish(with: ToolchainError.downloadFailed)
                return
            }

            guard let mode = ToolchainManager.resumableResponseMode(
                for: http,
                requestedOffset: initialOffset,
                expectedSize: expectedSize
            ) else {
                if http.statusCode == 206 || http.statusCode == 416 {
                    try? fileManager.removeItem(at: partialURL)
                }
                completionHandler(.cancel)
                finish(with: ToolchainError.downloadFailed)
                return
            }

            do {
                if mode == .restart {
                    try Data().write(to: partialURL, options: .atomic)
                } else if !fileManager.fileExists(atPath: partialURL.path) {
                    guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                        throw ToolchainError.fileIOFailed("Failed to create the partial toolchain download.")
                    }
                }
                let handle = try FileHandle(forWritingTo: partialURL)
                let offset = try handle.seekToEnd()

                lock.lock()
                guard !completed else {
                    lock.unlock()
                    try? handle.close()
                    completionHandler(.cancel)
                    return
                }
                fileHandle = handle
                receivedBytes = offset
                lock.unlock()
                completionHandler(.allow)
            } catch {
                completionHandler(.cancel)
                finish(with: error)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            var failure: Error?
            var total: UInt64 = 0

            lock.lock()
            if !completed, let fileHandle {
                let byteCount = UInt64(data.count)
                let (newTotal, overflow) = receivedBytes.addingReportingOverflow(byteCount)
                if overflow || newTotal > expectedSize {
                    failure = ToolchainError.hashMismatch
                } else {
                    do {
                        try fileHandle.write(contentsOf: data)
                        receivedBytes = newTotal
                        total = newTotal
                    } catch {
                        failure = ToolchainError.fileIOFailed(
                            "Failed to save the toolchain download. \(error.localizedDescription)"
                        )
                    }
                }
            }
            lock.unlock()

            if let failure {
                try? fileManager.removeItem(at: partialURL)
                dataTask.cancel()
                finish(with: failure)
                return
            }
            reportProgress(totalBytes: total)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(with: error)
            } else {
                finish(with: nil)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                completionHandler(nil)
                finish(with: ToolchainError.invalidArtifactURL("redirect without URL"))
                return
            }
            do {
                try validateRedirect(url)
                completionHandler(request)
            } catch {
                completionHandler(nil)
                finish(with: error)
            }
        }

        private func reportProgress(totalBytes: UInt64) {
            guard expectedSize > 0 else { return }
            let now = Date()
            if now.timeIntervalSince(lastUpdate) < 0.2, totalBytes < expectedSize {
                return
            }
            lastUpdate = now
            let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
            let transferred = totalBytes >= initialOffset ? totalBytes - initialOffset : totalBytes
            let rate = UInt64(Double(transferred) / elapsed)
            let message = "\(label) \(formatBytes(totalBytes))/\(formatBytes(expectedSize)) (\(formatBytes(rate))/s)"
            onProgress(Double(totalBytes) / Double(expectedSize), message)
        }

        private func finish(with error: Error?) {
            let continuation: CheckedContinuation<Void, Error>?
            let handle: FileHandle?
            let total: UInt64
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            handle = fileHandle
            fileHandle = nil
            total = receivedBytes
            lock.unlock()

            try? handle?.close()
            if let error {
                continuation?.resume(throwing: error)
            } else {
                reportProgress(totalBytes: total)
                continuation?.resume()
            }
        }

        private func formatBytes(_ value: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
        }
    }

    func downloadManifest(url: URL) async throws -> ToolchainManifest {
        let remoteURL = try validatedRemoteURL(url.absoluteString)
        return try await withTransientRetries {
            let data = try await downloadManifestData(from: remoteURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data) else {
                throw ToolchainError.invalidManifest
            }
            return manifest
        }
    }

    private func downloadManifestData(from url: URL) async throws -> Data {
        let delegate = ManifestDownloadDelegate(
            maximumBytes: Self.maximumManifestDownloadBytes,
            validateRedirect: { [self] redirectedURL in
                try validateRedirectTarget(redirectedURL)
            }
        )
        let session = URLSession(
            configuration: urlSession.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                let task = session.dataTask(with: URLRequest(url: url))
                delegate.attachTask(task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
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
            case .downloadFailed:
                return true
            case .manifestHTTPFailure(let statusCode, _):
                return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
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


    func shouldUseDataTaskForTests() -> Bool {
        if RuntimeEnvironment.current["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }


    func downloadVerifiedArtifact(
        _ artifact: ToolchainManifest.Component,
        from url: URL,
        to destination: URL,
        installationRoot: URL,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        guard artifact.sizeBytes > 0, artifact.sizeBytes <= UInt64(Int64.max) else {
            throw ToolchainError.invalidManifest
        }
        let partialURL = try preparePartialDownload(
            artifact: artifact,
            url: url,
            installationRoot: installationRoot
        )

        if fileManager.fileExists(atPath: destination.path) {
            if try downloadedFileMatches(
                destination,
                expectedSize: artifact.sizeBytes,
                expectedSHA256: artifact.sha256
            ) {
                try? fileManager.removeItem(at: partialURL)
                return
            }
            try fileManager.removeItem(at: destination)
        }

        try await withTransientRetries(onRetry: { nextAttempt, _ in
            onProgress(-1.0, "Retrying \(label) (\(nextAttempt)/3)")
        }) {
            try Task.checkCancellation()
            if try reusablePartial(
                partialURL,
                expectedSize: artifact.sizeBytes,
                expectedSHA256: artifact.sha256
            ) {
                return
            }

            let offset = try fileSize(at: partialURL)
            if shouldUseDataTaskForTests() {
                try await downloadArtifactViaDataTask(
                    url: url,
                    partialURL: partialURL,
                    offset: offset,
                    expectedSize: artifact.sizeBytes
                )
            } else {
                try await downloadArtifactViaStreamingTask(
                    url: url,
                    partialURL: partialURL,
                    offset: offset,
                    expectedSize: artifact.sizeBytes,
                    label: label,
                    onProgress: onProgress
                )
            }

            do {
                guard try validatedCompletePartial(
                    partialURL,
                    expectedSize: artifact.sizeBytes,
                    expectedSHA256: artifact.sha256
                ) else {
                    throw URLError(.networkConnectionLost)
                }
            } catch ToolchainError.hashMismatch where offset > 0 {
                throw URLError(.networkConnectionLost)
            }
        }

        try Task.checkCancellation()
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: partialURL, to: destination)
            removeEmptyDownloadDirectories(startingAt: partialURL.deletingLastPathComponent())
        } catch {
            throw ToolchainError.fileIOFailed(
                "Failed to finish the toolchain download. \(error.localizedDescription)"
            )
        }
    }

    func preparePartialDownload(
        artifact: ToolchainManifest.Component,
        url: URL,
        installationRoot: URL
    ) throws -> URL {
        let rootName = installationRoot.lastPathComponent
        let stagingMarker = rootName.range(of: ".staging-", options: .backwards)
        let version = stagingMarker.map { String(rootName[..<$0.lowerBound]) } ?? rootName
        let cacheBase = installationRoot.deletingLastPathComponent()
            .appendingPathComponent(".easysplat-downloads", isDirectory: true)
        let versionKey = sha256String(version)
        let componentKey = sha256String(artifact.name)
        let identityKey = sha256String(
            "\(version)\n\(artifact.name)\n\(url.absoluteString)\n\(artifact.sha256.lowercased())\n\(artifact.sizeBytes)"
        )
        let versionDirectory = cacheBase.appendingPathComponent(versionKey, isDirectory: true)
        let componentDirectory = versionDirectory.appendingPathComponent(componentKey, isDirectory: true)
        let partialURL = componentDirectory.appendingPathComponent("\(identityKey).partial")

        try fileManager.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
        if stagingMarker != nil,
           let cachedVersions = try? fileManager.contentsOfDirectory(
            at: cacheBase,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for cachedVersion in cachedVersions where cachedVersion.lastPathComponent != versionKey {
                try? fileManager.removeItem(at: cachedVersion)
            }
        }
        if let staleFiles = try? fileManager.contentsOfDirectory(
            at: componentDirectory,
            includingPropertiesForKeys: nil
        ) {
            for staleFile in staleFiles
            where staleFile.standardizedFileURL.path != partialURL.standardizedFileURL.path {
                try? fileManager.removeItem(at: staleFile)
            }
        }
        if try fileSize(at: partialURL) > artifact.sizeBytes {
            try fileManager.removeItem(at: partialURL)
        }
        return partialURL
    }

    func downloadArtifactViaDataTask(
        url: URL,
        partialURL: URL,
        offset: UInt64,
        expectedSize: UInt64
    ) async throws {
        let request = resumableRequest(url: url, offset: offset)
        let delegate = RedirectValidationDelegate { [self] redirectedURL in
            try validateRedirectTarget(redirectedURL)
        }
        let (data, response) = try await urlSession.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse,
              let mode = Self.resumableResponseMode(
                for: http,
                requestedOffset: offset,
                expectedSize: expectedSize
              ) else {
            if let statusCode = (response as? HTTPURLResponse)?.statusCode,
               statusCode == 206 || statusCode == 416 {
                try? fileManager.removeItem(at: partialURL)
            }
            throw ToolchainError.downloadFailed
        }

        let incomingSize = UInt64(data.count)
        if mode == .restart {
            guard incomingSize <= expectedSize else {
                try? fileManager.removeItem(at: partialURL)
                throw ToolchainError.hashMismatch
            }
            try data.write(to: partialURL, options: .atomic)
            return
        }

        let (combinedSize, overflow) = offset.addingReportingOverflow(incomingSize)
        guard !overflow, combinedSize <= expectedSize else {
            try? fileManager.removeItem(at: partialURL)
            throw ToolchainError.hashMismatch
        }
        if !fileManager.fileExists(atPath: partialURL.path) {
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw ToolchainError.fileIOFailed("Failed to create the partial toolchain download.")
            }
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func downloadArtifactViaStreamingTask(
        url: URL,
        partialURL: URL,
        offset: UInt64,
        expectedSize: UInt64,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let request = resumableRequest(url: url, offset: offset)
        let delegate = ResumableDownloadDelegate(
            partialURL: partialURL,
            expectedSize: expectedSize,
            initialOffset: offset,
            label: label,
            onProgress: onProgress,
            fileManager: fileManager,
            validateRedirect: { [self] redirectedURL in
                try validateRedirectTarget(redirectedURL)
            }
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                if Task.isCancelled {
                    delegate.cancel()
                    return
                }
                let task = session.dataTask(with: request)
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

    static func resumableResponseMode(
        for response: HTTPURLResponse,
        requestedOffset: UInt64,
        expectedSize: UInt64
    ) -> ResumableResponseMode? {
        if let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !contentEncoding.isEmpty,
           contentEncoding != "identity" {
            return nil
        }
        if response.statusCode == 200 {
            return .restart
        }
        guard response.statusCode == 206,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = parseContentRange(contentRange),
              parsed.start == requestedOffset,
              parsed.end >= parsed.start,
              parsed.end < parsed.total,
              parsed.total == expectedSize else {
            return nil
        }
        if response.expectedContentLength > 0,
           UInt64(response.expectedContentLength) != parsed.end - parsed.start + 1 {
            return nil
        }
        return .append
    }

    static func parseContentRange(_ value: String) -> (start: UInt64, end: UInt64, total: UInt64)? {
        let fields = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = fields[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2,
              let total = UInt64(rangeAndTotal[1]) else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = UInt64(bounds[0]),
              let end = UInt64(bounds[1]) else { return nil }
        return (start, end, total)
    }

    func resumableRequest(url: URL, offset: UInt64) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    func validatedCompletePartial(
        _ partialURL: URL,
        expectedSize: UInt64,
        expectedSHA256: String
    ) throws -> Bool {
        let size = try fileSize(at: partialURL)
        if size > expectedSize {
            try fileManager.removeItem(at: partialURL)
            throw ToolchainError.hashMismatch
        }
        guard size == expectedSize else { return false }
        guard try sha256Hex(url: partialURL).lowercased() == expectedSHA256.lowercased() else {
            try fileManager.removeItem(at: partialURL)
            throw ToolchainError.hashMismatch
        }
        return true
    }

    func reusablePartial(
        _ partialURL: URL,
        expectedSize: UInt64,
        expectedSHA256: String
    ) throws -> Bool {
        do {
            return try validatedCompletePartial(
                partialURL,
                expectedSize: expectedSize,
                expectedSHA256: expectedSHA256
            )
        } catch ToolchainError.hashMismatch {
            return false
        }
    }

    func downloadedFileMatches(
        _ url: URL,
        expectedSize: UInt64,
        expectedSHA256: String
    ) throws -> Bool {
        guard try fileSize(at: url) == expectedSize else { return false }
        return try sha256Hex(url: url).lowercased() == expectedSHA256.lowercased()
    }

    func fileSize(at url: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func sha256String(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func removeEmptyDownloadDirectories(startingAt directory: URL) {
        var current = directory
        for _ in 0..<3 {
            guard (try? fileManager.contentsOfDirectory(atPath: current.path).isEmpty) == true else {
                return
            }
            try? fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
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

    func unzip(
        zipURL: URL,
        to destination: URL,
        exactComponent: ToolchainManifest.Component? = nil,
        forceInspection: Bool = false
    ) throws {
        let archiveEntries = try inspectArchiveEntries(zipURL: zipURL, forceInspection: forceInspection)
        try validateArchiveEntries(archiveEntries)
        if let exactComponent {
            try validateExactArchiveContents(archiveEntries, component: exactComponent)
        }
        let result = try runner.run("/usr/bin/unzip", ["-o", zipURL.path, "-d", destination.path])
        guard result.exitCode == 0 else {
            throw ToolchainError.unzipFailed
        }
        try validateExtractedLinks(root: destination)
    }

    func localToolchainOverrideURL() -> URL? {
        localToolchainRoot
    }

    func installStateURL(root: URL) -> URL {
        root.appendingPathComponent(Self.installStateFilename)
    }

    func loadInstallState(root: URL) -> ToolchainInstallState {
        let url = installStateURL(root: root)
        guard let data = try? BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: Self.maximumInstallStateBytes
        ) else {
            return ToolchainInstallState()
        }
        return (try? JSONDecoder().decode(ToolchainInstallState.self, from: data)) ?? ToolchainInstallState()
    }

    func saveInstallState(_ state: ToolchainInstallState, root: URL) throws {
        let url = installStateURL(root: root)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }

    func validatedRemoteURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ToolchainError.invalidArtifactURL(urlString)
        }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw ToolchainError.invalidArtifactURL(urlString)
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (allowInsecureLoopbackHTTP && scheme == "http" && isLoopback) else {
            throw ToolchainError.invalidArtifactURL(urlString)
        }
        return url
    }

    func validatedArtifactURL(_ urlString: String) throws -> URL {
        try validatedRemoteURL(urlString)
    }

    func validateRedirectTarget(_ url: URL) throws {
        _ = try validatedRemoteURL(url.absoluteString)
    }

    func ensureArtifact(
        _ artifact: ToolchainManifest.Component,
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
            return "Downloading tools (\(name))"
        }()

        try await downloadVerifiedArtifact(
            artifact,
            from: url,
            to: zipURL,
            installationRoot: root,
            label: label,
            onProgress: onProgress
        )

        try installVerifiedArchive(
            artifact,
            archiveURL: zipURL,
            root: root,
            forceArchiveInspection: false,
            onProgress: onProgress
        )
        try? fileManager.removeItem(at: zipURL)

        state.installedArtifacts[name] = artifact.sha256
        try? saveInstallState(state, root: root)
    }

    func installVerifiedArchive(
        _ artifact: ToolchainManifest.Component,
        archiveURL: URL,
        root: URL,
        forceArchiveInspection: Bool,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        guard try isRegularSingleLinkFile(archiveURL, exactSize: artifact.sizeBytes),
              try sha256Hex(url: archiveURL).lowercased() == artifact.sha256.lowercased() else {
            throw ToolchainError.hashMismatch
        }
        onProgress(-1.0, "Verified download integrity (\(artifactLabel(for: artifact.name)))")

        let unpackMessage = unpackingMessage(for: artifact.name)
        onProgress(-1.0, unpackMessage)
        try unzip(
            zipURL: archiveURL,
            to: root,
            exactComponent: artifact.capabilities.isEmpty ? nil : artifact,
            forceInspection: forceArchiveInspection
        )
        try enforceExpectedContents(
            artifact: artifact,
            root: root,
            unpackMessage: unpackMessage,
            onProgress: onProgress
        )
        try validateCriticalFileHashes(artifact.criticalFileHashes, root: root)
    }

    func isRegularSingleLinkFile(_ url: URL, exactSize: UInt64) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size >= 0
            && UInt64(metadata.st_size) == exactSize
    }

    func inspectArchiveEntries(zipURL: URL, forceInspection: Bool = false) throws -> [String] {
        // Existing URLProtocol tests deliberately use fake zip bytes and mock extraction.
        // Production downloads always take this path before `/usr/bin/unzip` is allowed to write.
        if shouldUseDataTaskForTests(), !forceInspection {
            return []
        }
        let inspection = ArchiveInspectionAccumulator(
            maximumEntryBytes: Self.maximumManifestDownloadBytes,
            maximumEntryCount: 250_000
        )
        let metadata = try runner.run(
            "/usr/bin/zipinfo",
            ["-l", zipURL.path],
            onStdout: inspection.inspectMetadataLine
        )
        guard metadata.exitCode == 0 else {
            throw ToolchainError.unzipFailed
        }
        if inspection.foundSymbolicLink() {
            throw ToolchainError.invalidToolchain("Archive contains a symbolic link entry.")
        }
        let result = try runner.run(
            "/usr/bin/unzip",
            ["-Z1", zipURL.path],
            onStdout: inspection.appendEntry
        )
        guard result.exitCode == 0 else {
            throw ToolchainError.unzipFailed
        }
        let listing = inspection.entrySnapshot()
        guard !listing.exceededLimit else {
            throw ToolchainError.invalidToolchain("Archive entry listing exceeds the inspection limit.")
        }
        return listing.entries
    }

    func validateArchiveEntries(_ entries: [String]) throws {
        for entry in entries {
            guard !entry.isEmpty,
                  !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  !entry.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ToolchainError.invalidToolchain("Archive contains an unsafe entry path.")
            }
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                throw ToolchainError.invalidToolchain("Archive contains a path traversal entry: \(entry).")
            }
        }
    }

    func validateExtractedLinks(root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ToolchainError.invalidToolchain("Extracted toolchain could not be enumerated.")
        }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
                continue
            }
            let destination: String
            do {
                destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            } catch {
                throw ToolchainError.invalidToolchain("Archive contains an unreadable symbolic link.")
            }
            let resolved = (destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination).standardizedFileURL
                : url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL)
                .resolvingSymlinksInPath()
            guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
                throw ToolchainError.invalidToolchain("Archive symbolic link escapes the toolchain root: \(url.lastPathComponent).")
            }
        }
    }

    func validateCriticalFileHashes(_ hashes: [String: String], root: URL) throws {
        for (relativePath, expectedHash) in hashes {
            try validateArchiveEntries([relativePath])
            guard expectedHash == expectedHash.lowercased(), isLowercaseSHA256(expectedHash) else {
                throw ToolchainError.invalidManifest
            }
            let url = root.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: url.path),
                  try sha256Hex(url: url) == expectedHash else {
                throw ToolchainError.invalidToolchain("Critical toolchain hash mismatch: \(relativePath).")
            }
        }
    }

    func artifactLabel(for name: String) -> String {
        if name.hasSuffix("-core") { return "core" }
        return name
    }

    func unpackingMessage(for name: String) -> String {
        if name.hasSuffix("-core") { return "Unpacking tools (core)" }
        return "Unpacking tools"
    }

    func expectedContentsCheck(
        artifact: ToolchainManifest.Component,
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
        artifact: ToolchainManifest.Component,
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

private final class ArchiveInspectionAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEntryBytes: Int
    private let maximumEntryCount: Int
    private var entries: [String] = []
    private var entryBytes = 0
    private var exceededLimit = false
    private var containsSymbolicLink = false

    init(maximumEntryBytes: Int, maximumEntryCount: Int) {
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumEntryCount = maximumEntryCount
    }

    func inspectMetadataLine(_ line: String) {
        guard line.first == "l" else { return }
        lock.lock()
        containsSymbolicLink = true
        lock.unlock()
    }

    func appendEntry(_ entry: String) {
        guard !entry.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        let addedBytes = entry.utf8.count.addingReportingOverflow(1)
        let nextBytes = entryBytes.addingReportingOverflow(addedBytes.partialValue)
        guard !addedBytes.overflow,
              !nextBytes.overflow,
              nextBytes.partialValue <= maximumEntryBytes,
              entries.count < maximumEntryCount else {
            exceededLimit = true
            return
        }
        entries.append(entry)
        entryBytes = nextBytes.partialValue
    }

    func foundSymbolicLink() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return containsSymbolicLink
    }

    func entrySnapshot() -> (entries: [String], exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (entries, exceededLimit)
    }
}
