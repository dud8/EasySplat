import CryptoKit
import Darwin
import Foundation

extension ToolchainManager {
    static let installStateFilename = ".easysplat_toolchain_state.json"

    // The signed manifest carries the exact Python runtime closure. Keep the
    // unauthenticated response and cached receipt bounded above that real size.
    static let maximumManifestDownloadBytes = ToolchainManifest.maximumEncodedBytes
    private static let maximumInstallStateBytes = ToolchainManifest.maximumInstallStateEnvelopeBytes

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

    final class PartialDownloadFile: @unchecked Sendable {
        let directoryDescriptor: Int32
        let fileDescriptor: Int32
        let leafName: String
        let url: URL

        init(
            directoryDescriptor: Int32,
            fileDescriptor: Int32,
            leafName: String,
            url: URL
        ) {
            self.directoryDescriptor = directoryDescriptor
            self.fileDescriptor = fileDescriptor
            self.leafName = leafName
            self.url = url
        }

        deinit {
            Darwin.close(fileDescriptor)
            Darwin.close(directoryDescriptor)
        }

        func size() throws -> UInt64 {
            let status = try verifiedStatus()
            guard status.st_size >= 0 else {
                throw ToolchainError.fileIOFailed("The partial toolchain download has an invalid size.")
            }
            return UInt64(status.st_size)
        }

        func reset() throws {
            guard Darwin.ftruncate(fileDescriptor, 0) == 0,
                  Darwin.lseek(fileDescriptor, 0, SEEK_SET) == 0 else {
                throw partialWriteError("reset", errno: errno)
            }
            _ = try verifiedStatus()
        }

        func append(_ data: Data, expectedOffset: UInt64) throws {
            guard try size() == expectedOffset,
                  expectedOffset <= UInt64(Int64.max),
                  Darwin.lseek(fileDescriptor, off_t(expectedOffset), SEEK_SET) >= 0 else {
                throw ToolchainError.fileIOFailed(
                    "The partial toolchain download changed before it could be resumed."
                )
            }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(
                        fileDescriptor,
                        base.advanced(by: written),
                        bytes.count - written
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw partialWriteError("write", errno: count < 0 ? errno : EIO)
                    }
                    written += count
                }
            }
            _ = try verifiedStatus()
        }

        func replace(with data: Data) throws {
            try reset()
            try append(data, expectedOffset: 0)
        }

        func synchronize() throws {
            while Darwin.fsync(fileDescriptor) != 0 {
                if errno == EINTR { continue }
                throw partialWriteError("sync", errno: errno)
            }
            _ = try verifiedStatus()
        }

        func sha256(
            maximumBytes: UInt64,
            namedDirectoryDescriptor: Int32? = nil,
            namedLeafName: String? = nil
        ) throws -> String {
            let initial = try verifiedStatus(
                namedDirectoryDescriptor: namedDirectoryDescriptor,
                namedLeafName: namedLeafName
            )
            guard initial.st_size >= 0, UInt64(initial.st_size) <= maximumBytes else {
                throw ToolchainError.hashMismatch
            }
            var hasher = SHA256()
            var offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while offset < initial.st_size {
                let remaining = min(Int64(buffer.count), initial.st_size - offset)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(fileDescriptor, bytes.baseAddress, Int(remaining), off_t(offset))
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw partialWriteError("read", errno: count < 0 ? errno : EIO) }
                hasher.update(data: Data(buffer[0..<count]))
                offset += Int64(count)
            }
            let final = try verifiedStatus(
                namedDirectoryDescriptor: namedDirectoryDescriptor,
                namedLeafName: namedLeafName
            )
            guard sameMutableFileObject(initial, final), final.st_size == initial.st_size else {
                throw ToolchainError.fileIOFailed(
                    "The partial toolchain download changed while it was being verified."
                )
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func unlinkNamedFile() throws {
            _ = try verifiedStatus()
            let result = leafName.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            guard result == 0 || errno == ENOENT else {
                throw partialWriteError("discard", errno: errno)
            }
        }

        func verifiedStatus(
            namedDirectoryDescriptor: Int32? = nil,
            namedLeafName: String? = nil
        ) throws -> stat {
            let namedDirectoryDescriptor = namedDirectoryDescriptor ?? directoryDescriptor
            let namedLeafName = namedLeafName ?? leafName
            var descriptorStatus = stat()
            var namedStatus = stat()
            let namedResult = namedLeafName.withCString {
                Darwin.fstatat(namedDirectoryDescriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(fileDescriptor, &descriptorStatus) == 0,
                  namedResult == 0,
                  (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
                  (namedStatus.st_mode & S_IFMT) == S_IFREG,
                  descriptorStatus.st_nlink == 1,
                  namedStatus.st_nlink == 1,
                  descriptorStatus.st_uid == getuid(),
                  namedStatus.st_uid == getuid(),
                  descriptorStatus.st_mode & 0o777 == 0o600,
                  namedStatus.st_mode & 0o777 == 0o600,
                  sameMutableFileObject(descriptorStatus, namedStatus) else {
                throw ToolchainError.fileIOFailed(
                    "The partial toolchain download is not a safe ordinary file."
                )
            }
            return descriptorStatus
        }

        private func sameMutableFileObject(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev
                && lhs.st_ino == rhs.st_ino
                && lhs.st_nlink == rhs.st_nlink
                && lhs.st_uid == rhs.st_uid
                && lhs.st_mode == rhs.st_mode
        }

        private func partialWriteError(_ action: String, errno value: Int32) -> ToolchainError {
            ToolchainError.fileIOFailed(
                "Failed to \(action) the partial toolchain download (errno \(value))."
            )
        }
    }

    final class ResumableDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partialFile: PartialDownloadFile
        private let expectedSize: UInt64
        private let initialOffset: UInt64
        private let label: String
        private let onProgress: @Sendable (Double, String) -> Void
        private let validateRedirect: @Sendable (URL) throws -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private weak var task: URLSessionDataTask?
        private var receivedBytes: UInt64
        private var completed = false
        private let startedAt = Date()
        private var lastUpdate = Date.distantPast

        init(
            partialFile: PartialDownloadFile,
            expectedSize: UInt64,
            initialOffset: UInt64,
            label: String,
            onProgress: @escaping @Sendable (Double, String) -> Void,
            validateRedirect: @escaping @Sendable (URL) throws -> Void
        ) {
            self.partialFile = partialFile
            self.expectedSize = expectedSize
            self.initialOffset = initialOffset
            self.label = label
            self.onProgress = onProgress
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

            guard http.statusCode == 200 || http.statusCode == 206 else {
                if http.statusCode == 416 {
                    try? partialFile.unlinkNamedFile()
                }
                completionHandler(.cancel)
                finish(
                    with: ToolchainError.artifactHTTPFailure(
                        statusCode: http.statusCode,
                        resourceURL: http.url
                            ?? dataTask.currentRequest?.url
                            ?? dataTask.originalRequest?.url
                            ?? partialFile.url
                    )
                )
                return
            }

            guard let mode = ToolchainManager.resumableResponseMode(
                for: http,
                requestedOffset: initialOffset,
                expectedSize: expectedSize
            ) else {
                if http.statusCode == 206 || http.statusCode == 416 {
                    try? partialFile.unlinkNamedFile()
                }
                completionHandler(.cancel)
                finish(with: ToolchainError.downloadFailed)
                return
            }

            do {
                if mode == .restart {
                    try partialFile.reset()
                } else if try partialFile.size() != initialOffset {
                    throw ToolchainError.fileIOFailed(
                        "The partial toolchain download changed before it could be resumed."
                    )
                }
                let offset = try partialFile.size()

                lock.lock()
                guard !completed else {
                    lock.unlock()
                    completionHandler(.cancel)
                    return
                }
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
            if !completed {
                let byteCount = UInt64(data.count)
                let (newTotal, overflow) = receivedBytes.addingReportingOverflow(byteCount)
                if overflow || newTotal > expectedSize {
                    failure = ToolchainError.hashMismatch
                } else {
                    do {
                        try partialFile.append(data, expectedOffset: receivedBytes)
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
                try? partialFile.unlinkNamedFile()
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
                do {
                    try partialFile.synchronize()
                    finish(with: nil)
                } catch {
                    finish(with: error)
                }
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
            let total: UInt64
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            total = receivedBytes
            lock.unlock()

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
            case .artifactHTTPFailure(let statusCode, _):
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
                try? discardPartialDownload(at: partialURL)
                return
            }
            try fileManager.removeItem(at: destination)
        }

        var retriedRangeNotSatisfiableWithoutRange = false
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
            do {
                try await downloadArtifactAttempt(
                    url: url,
                    partialURL: partialURL,
                    offset: offset,
                    expectedSize: artifact.sizeBytes,
                    label: label,
                    onProgress: onProgress
                )
            } catch ToolchainError.artifactHTTPFailure(let statusCode, _)
                where statusCode == 416 && offset > 0 && !retriedRangeNotSatisfiableWithoutRange {
                retriedRangeNotSatisfiableWithoutRange = true
                try await downloadArtifactAttempt(
                    url: url,
                    partialURL: partialURL,
                    offset: 0,
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
            try promotePartialDownload(
                at: partialURL,
                to: destination,
                expectedSize: artifact.sizeBytes,
                expectedSHA256: artifact.sha256
            )
        } catch {
            throw ToolchainError.fileIOFailed(
                "Failed to finish the toolchain download. \(error.localizedDescription)"
            )
        }
    }

    private func discardPartialDownload(at url: URL) throws {
        if let partialFile = try openPartialDownloadFile(at: url, create: false) {
            try partialFile.unlinkNamedFile()
        }
    }

    private func promotePartialDownload(
        at partialURL: URL,
        to destination: URL,
        expectedSize: UInt64,
        expectedSHA256: String
    ) throws {
        guard let partialFile = try openPartialDownloadFile(at: partialURL, create: false),
              try partialFile.size() == expectedSize,
              try partialFile.sha256(maximumBytes: expectedSize).lowercased()
                == expectedSHA256.lowercased() else {
            throw ToolchainError.hashMismatch
        }
        try partialFile.synchronize()
        let destinationDirectoryURL = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: destinationDirectoryURL,
            withIntermediateDirectories: true
        )
        let destinationDirectory = Darwin.open(
            destinationDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDirectory >= 0 else {
            throw ToolchainError.fileIOFailed(
                "The toolchain download destination could not be opened safely."
            )
        }
        defer { Darwin.close(destinationDirectory) }
        var destinationDirectoryStatus = stat()
        var namedDestinationDirectoryStatus = stat()
        guard fstat(destinationDirectory, &destinationDirectoryStatus) == 0,
              lstat(destinationDirectoryURL.path, &namedDestinationDirectoryStatus) == 0,
              (destinationDirectoryStatus.st_mode & S_IFMT) == S_IFDIR,
              (namedDestinationDirectoryStatus.st_mode & S_IFMT) == S_IFDIR,
              destinationDirectoryStatus.st_uid == getuid(),
              namedDestinationDirectoryStatus.st_uid == getuid(),
              destinationDirectoryStatus.st_dev == namedDestinationDirectoryStatus.st_dev,
              destinationDirectoryStatus.st_ino == namedDestinationDirectoryStatus.st_ino else {
            throw ToolchainError.fileIOFailed(
                "The toolchain download destination is unsafe."
            )
        }
        let destinationLeaf = destination.lastPathComponent
        guard !destinationLeaf.isEmpty,
              destinationLeaf != ".",
              destinationLeaf != "..",
              !destinationLeaf.contains("/") else {
            throw ToolchainError.invalidManifest
        }
        let renameFlags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        let renameResult = partialFile.leafName.withCString { sourcePointer in
            destinationLeaf.withCString { destinationPointer in
                Darwin.renameatx_np(
                    partialFile.directoryDescriptor,
                    sourcePointer,
                    destinationDirectory,
                    destinationPointer,
                    renameFlags
                )
            }
        }
        guard renameResult == 0 else {
            throw ToolchainError.fileIOFailed(
                "Failed to publish the verified toolchain download (errno \(errno))."
            )
        }

        do {
            _ = try partialFile.verifiedStatus(
                namedDirectoryDescriptor: destinationDirectory,
                namedLeafName: destinationLeaf
            )
            guard try partialFile.sha256(
                maximumBytes: expectedSize,
                namedDirectoryDescriptor: destinationDirectory,
                namedLeafName: destinationLeaf
            ).lowercased() == expectedSHA256.lowercased() else {
                throw ToolchainError.hashMismatch
            }
            while Darwin.fsync(destinationDirectory) != 0 {
                if errno == EINTR { continue }
                throw ToolchainError.fileIOFailed(
                    "Failed to sync the toolchain download destination (errno \(errno))."
                )
            }
            while Darwin.fsync(partialFile.directoryDescriptor) != 0 {
                if errno == EINTR { continue }
                throw ToolchainError.fileIOFailed(
                    "Failed to sync the toolchain download cache (errno \(errno))."
                )
            }
        } catch {
            let rollback = destinationLeaf.withCString { destinationPointer in
                partialFile.leafName.withCString { sourcePointer in
                    Darwin.renameatx_np(
                        destinationDirectory,
                        destinationPointer,
                        partialFile.directoryDescriptor,
                        sourcePointer,
                        renameFlags
                    )
                }
            }
            if rollback == 0 {
                try? partialFile.synchronize()
            }
            throw error
        }
    }

    private func downloadArtifactAttempt(
        url: URL,
        partialURL: URL,
        offset: UInt64,
        expectedSize: UInt64,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        if shouldUseDataTaskForTests() {
            try await downloadArtifactViaDataTask(
                url: url,
                partialURL: partialURL,
                offset: offset,
                expectedSize: expectedSize
            )
        } else {
            try await downloadArtifactViaStreamingTask(
                url: url,
                partialURL: partialURL,
                offset: offset,
                expectedSize: expectedSize,
                label: label,
                onProgress: onProgress
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

        let preparedDirectory = try openDownloadComponentDirectory(
            for: partialURL,
            create: true
        )
        Darwin.close(preparedDirectory)
        if let staleFiles = try? fileManager.contentsOfDirectory(
            at: componentDirectory,
            includingPropertiesForKeys: nil
        ) {
            for staleFile in staleFiles
            where staleFile.standardizedFileURL.path != partialURL.standardizedFileURL.path {
                guard let stalePartial = try openPartialDownloadFile(
                    at: staleFile,
                    create: false
                ) else { continue }
                try stalePartial.unlinkNamedFile()
            }
        }
        if let partialFile = try openPartialDownloadFile(at: partialURL, create: false),
           try partialFile.size() > artifact.sizeBytes {
            try partialFile.unlinkNamedFile()
        }
        return partialURL
    }

    func openPartialDownloadFile(
        at url: URL,
        create: Bool
    ) throws -> PartialDownloadFile? {
        let leafName = url.lastPathComponent
        guard !leafName.isEmpty,
              leafName != ".",
              leafName != "..",
              !leafName.contains("/") else {
            throw ToolchainError.invalidManifest
        }
        let directoryDescriptor = try openDownloadComponentDirectory(for: url, create: false)

        var flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        if create { flags |= O_CREAT }
        let fileDescriptor = leafName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                flags,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        if fileDescriptor < 0, !create, errno == ENOENT {
            Darwin.close(directoryDescriptor)
            return nil
        }
        guard fileDescriptor >= 0 else {
            Darwin.close(directoryDescriptor)
            throw ToolchainError.fileIOFailed(
                "The partial toolchain download is not a safe ordinary file."
            )
        }
        var fileStatus = stat()
        var namedFileStatus = stat()
        let namedResult = leafName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &namedFileStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(fileDescriptor, &fileStatus) == 0,
              namedResult == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              (namedFileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_nlink == 1,
              namedFileStatus.st_nlink == 1,
              fileStatus.st_uid == getuid(),
              namedFileStatus.st_uid == getuid(),
              fileStatus.st_dev == namedFileStatus.st_dev,
              fileStatus.st_ino == namedFileStatus.st_ino else {
            Darwin.close(fileDescriptor)
            Darwin.close(directoryDescriptor)
            throw ToolchainError.fileIOFailed(
                "The partial toolchain download is not a safe ordinary file."
            )
        }
        if fileStatus.st_mode & 0o777 != 0o600 {
            guard Darwin.fchmod(fileDescriptor, 0o600) == 0 else {
                Darwin.close(fileDescriptor)
                Darwin.close(directoryDescriptor)
                throw ToolchainError.fileIOFailed(
                    "The partial toolchain download permissions could not be secured."
                )
            }
        }
        let partialFile = PartialDownloadFile(
            directoryDescriptor: directoryDescriptor,
            fileDescriptor: fileDescriptor,
            leafName: leafName,
            url: url
        )
        _ = try partialFile.verifiedStatus()
        return partialFile
    }

    private func openDownloadComponentDirectory(
        for partialURL: URL,
        create: Bool
    ) throws -> Int32 {
        let componentDirectory = partialURL.deletingLastPathComponent()
        let versionDirectory = componentDirectory.deletingLastPathComponent()
        let cacheDirectory = versionDirectory.deletingLastPathComponent()
        guard cacheDirectory.lastPathComponent == ".easysplat-downloads",
              componentDirectory.lastPathComponent.count == 64,
              versionDirectory.lastPathComponent.count == 64 else {
            let descriptor = Darwin.open(
                componentDirectory.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw ToolchainError.fileIOFailed(
                    "The partial toolchain download directory could not be opened safely."
                )
            }
            try validateOwnedDirectoryDescriptor(descriptor, namedAt: componentDirectory)
            return descriptor
        }

        let containerURL = cacheDirectory.deletingLastPathComponent()
        let container = Darwin.open(
            containerURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard container >= 0 else {
            throw ToolchainError.fileIOFailed(
                "The toolchain download cache container could not be opened safely."
            )
        }
        var descriptors = [container]
        var returningLeaf = false
        defer {
            let descriptorsToClose = returningLeaf ? descriptors.dropLast() : descriptors[...]
            descriptorsToClose.forEach { Darwin.close($0) }
        }
        do {
            try validateOwnedDirectoryDescriptor(container, namedAt: containerURL)
            for name in [
                cacheDirectory.lastPathComponent,
                versionDirectory.lastPathComponent,
                componentDirectory.lastPathComponent,
            ] {
                let parent = descriptors.last!
                if create {
                    let creation = name.withCString {
                        Darwin.mkdirat(parent, $0, mode_t(S_IRWXU))
                    }
                    guard creation == 0 || errno == EEXIST else {
                        throw ToolchainError.fileIOFailed(
                            "The toolchain download cache could not be created safely."
                        )
                    }
                }
                let child = name.withCString {
                    Darwin.openat(
                        parent,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw ToolchainError.fileIOFailed(
                        "The toolchain download cache path is unsafe."
                    )
                }
                do {
                    try validateOwnedDirectoryDescriptor(child, parent: parent, name: name)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                descriptors.append(child)
            }
            returningLeaf = true
            return descriptors.last!
        } catch {
            throw error
        }
    }

    private func validateOwnedDirectoryDescriptor(
        _ descriptor: Int32,
        namedAt url: URL
    ) throws {
        var descriptorStatus = stat()
        var namedStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &namedStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
              (namedStatus.st_mode & S_IFMT) == S_IFDIR,
              descriptorStatus.st_uid == getuid(),
              namedStatus.st_uid == getuid(),
              descriptorStatus.st_dev == namedStatus.st_dev,
              descriptorStatus.st_ino == namedStatus.st_ino else {
            throw ToolchainError.fileIOFailed(
                "The partial toolchain download directory is unsafe."
            )
        }
    }

    private func validateOwnedDirectoryDescriptor(
        _ descriptor: Int32,
        parent: Int32,
        name: String
    ) throws {
        var descriptorStatus = stat()
        var namedStatus = stat()
        let namedResult = name.withCString {
            Darwin.fstatat(parent, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &descriptorStatus) == 0,
              namedResult == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
              (namedStatus.st_mode & S_IFMT) == S_IFDIR,
              descriptorStatus.st_uid == getuid(),
              namedStatus.st_uid == getuid(),
              descriptorStatus.st_dev == namedStatus.st_dev,
              descriptorStatus.st_ino == namedStatus.st_ino,
              Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
            throw ToolchainError.fileIOFailed(
                "The toolchain download cache path is unsafe."
            )
        }
    }

    func downloadArtifactViaDataTask(
        url: URL,
        partialURL: URL,
        offset: UInt64,
        expectedSize: UInt64
    ) async throws {
        guard let partialFile = try openPartialDownloadFile(at: partialURL, create: true),
              try partialFile.size() == offset else {
            throw ToolchainError.fileIOFailed(
                "The partial toolchain download changed before it could be resumed."
            )
        }
        let request = resumableRequest(url: url, offset: offset)
        let delegate = RedirectValidationDelegate { [self] redirectedURL in
            try validateRedirectTarget(redirectedURL)
        }
        let (data, response) = try await urlSession.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw ToolchainError.downloadFailed
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            if http.statusCode == 416 {
                try? partialFile.unlinkNamedFile()
            }
            throw ToolchainError.artifactHTTPFailure(
                statusCode: http.statusCode,
                resourceURL: http.url ?? request.url ?? url
            )
        }
        guard let mode = Self.resumableResponseMode(
            for: http,
            requestedOffset: offset,
            expectedSize: expectedSize
        ) else {
            if http.statusCode == 206 {
                try? partialFile.unlinkNamedFile()
            }
            throw ToolchainError.downloadFailed
        }

        let incomingSize = UInt64(data.count)
        if mode == .restart {
            guard incomingSize <= expectedSize else {
                try? partialFile.unlinkNamedFile()
                throw ToolchainError.hashMismatch
            }
            try partialFile.replace(with: data)
            try partialFile.synchronize()
            return
        }

        let (combinedSize, overflow) = offset.addingReportingOverflow(incomingSize)
        guard !overflow, combinedSize <= expectedSize else {
            try? partialFile.unlinkNamedFile()
            throw ToolchainError.hashMismatch
        }
        try partialFile.append(data, expectedOffset: offset)
        try partialFile.synchronize()
    }

    func downloadArtifactViaStreamingTask(
        url: URL,
        partialURL: URL,
        offset: UInt64,
        expectedSize: UInt64,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        guard let partialFile = try openPartialDownloadFile(at: partialURL, create: true),
              try partialFile.size() == offset else {
            throw ToolchainError.fileIOFailed(
                "The partial toolchain download changed before it could be resumed."
            )
        }
        let request = resumableRequest(url: url, offset: offset)
        let delegate = ResumableDownloadDelegate(
            partialFile: partialFile,
            expectedSize: expectedSize,
            initialOffset: offset,
            label: label,
            onProgress: onProgress,
            validateRedirect: { [self] redirectedURL in
                try validateRedirectTarget(redirectedURL)
            }
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = makeStreamingArtifactSession(
            delegate: delegate,
            delegateQueue: queue
        )
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

    func makeStreamingArtifactSession(
        delegate: URLSessionDelegate,
        delegateQueue: OperationQueue
    ) -> URLSession {
        URLSession(
            configuration: urlSession.configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
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
        guard let partialFile = try openPartialDownloadFile(at: partialURL, create: false) else {
            return false
        }
        let size = try partialFile.size()
        if size > expectedSize {
            try partialFile.unlinkNamedFile()
            throw ToolchainError.hashMismatch
        }
        guard size == expectedSize else { return false }
        guard try partialFile.sha256(maximumBytes: expectedSize).lowercased()
            == expectedSHA256.lowercased() else {
            try partialFile.unlinkNamedFile()
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
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return 0 }
            throw ToolchainError.fileIOFailed("Could not inspect the toolchain download.")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == getuid(),
              status.st_size >= 0 else {
            throw ToolchainError.fileIOFailed(
                "The toolchain download is not a safe ordinary file."
            )
        }
        return UInt64(status.st_size)
    }

    func sha256String(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func sha256Hex(url: URL) throws -> String {
        try regularFileEvidence(at: url).sha256
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
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumInstallStateBytes else {
            throw ToolchainError.invalidManifest
        }

        let directory = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw installStateWriteError("open directory", errno: errno)
        }
        defer { Darwin.close(directory) }

        let temporaryName = ".easysplat-toolchain-state-\(UUID().uuidString).tmp"
        let temporary = temporaryName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporary >= 0 else {
            throw installStateWriteError("create temporary receipt", errno: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporary)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directory, $0, 0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    temporary,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw installStateWriteError("write receipt", errno: errno)
                }
                guard count > 0 else {
                    throw installStateWriteError("write receipt", errno: EIO)
                }
                written += count
            }
        }
        guard Darwin.fchmod(temporary, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw installStateWriteError("set receipt permissions", errno: errno)
        }
        try synchronizeInstallStateDescriptor(temporary, action: "sync receipt")

        let renamed = temporaryName.withCString { temporaryPointer in
            Self.installStateFilename.withCString { receiptPointer in
                Darwin.renameat(directory, temporaryPointer, directory, receiptPointer)
            }
        }
        guard renamed == 0 else {
            throw installStateWriteError("replace receipt", errno: errno)
        }
        shouldRemoveTemporary = false
        try synchronizeInstallStateDescriptor(directory, action: "sync receipt directory")
    }

    private func synchronizeInstallStateDescriptor(_ descriptor: Int32, action: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw installStateWriteError(action, errno: errno)
        }
    }

    private func installStateWriteError(_ action: String, errno value: Int32) -> ToolchainError {
        ToolchainError.fileIOFailed(
            "Failed to save the signed toolchain receipt (\(action), errno \(value))."
        )
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
        try validateExpandedClosure(artifact, root: root)
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
        let listing: SafeArchiveExtractor.ArchiveListing
        do {
            listing = try SafeArchiveExtractor.listArchive(
                zipURL: zipURL,
                runner: runner,
                maximumListingBytes: Self.maximumManifestDownloadBytes,
                maximumEntryCount: 250_000
            )
        } catch let error as SafeArchiveExtractor.ExtractionError {
            throw Self.toolchainError(forArchiveListing: error)
        }
        guard listing.breach == .none else {
            throw ToolchainError.invalidToolchain("Archive entry listing exceeds the inspection limit.")
        }
        return listing.names
    }

    /// Maps the shared extractor's listing failures back onto the toolchain's historical
    /// `ToolchainError` messages so the download path's observable behavior is unchanged.
    private static func toolchainError(
        forArchiveListing error: SafeArchiveExtractor.ExtractionError
    ) -> ToolchainError {
        switch error {
        case .symbolicLinkEntry:
            return .invalidToolchain("Archive contains a symbolic link entry.")
        case .specialFileEntry:
            return .invalidToolchain("Archive contains a special file entry.")
        default:
            return .unzipFailed
        }
    }

    func validateArchiveEntries(_ entries: [String]) throws {
        do {
            try SafeArchiveExtractor.validateEntryPaths(entries)
        } catch let error as SafeArchiveExtractor.ExtractionError {
            throw Self.toolchainError(forEntryValidation: error)
        }
    }

    /// Maps the shared extractor's entry-path failures back onto the toolchain's historical
    /// `ToolchainError` messages.
    private static func toolchainError(
        forEntryValidation error: SafeArchiveExtractor.ExtractionError
    ) -> ToolchainError {
        switch error {
        case .duplicateEntry:
            return .invalidToolchain("Archive contains duplicate entries.")
        case .pathTraversal(let entry):
            return .invalidToolchain("Archive contains a path traversal entry: \(entry).")
        default:
            return .invalidToolchain("Archive contains an unsafe entry path.")
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
            guard try regularFileEvidence(at: url).sha256 == expectedHash else {
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
