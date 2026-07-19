import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Abstraction for launching subprocesses and streaming their output.
public protocol SubprocessRunning: Sendable {
    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult

    /// Calls `onTermination` exactly once after a launched child exits. A callback error is an
    /// integrity failure and takes precedence over task cancellation; launch failures never call it.
    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onTermination: @escaping @Sendable (SubprocessResult) throws -> Void,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult
}

public extension SubprocessRunning {
    func run(
        _ launchPath: String,
        _ arguments: [String],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> SubprocessResult {
        try run(
            launchPath,
            arguments,
            currentDirectory: nil,
            environment: [:],
            removingEnvironmentKeys: [],
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SubprocessResult {
        try await runAsync(
            launchPath,
            arguments,
            currentDirectory: nil,
            environment: [:],
            removingEnvironmentKeys: [],
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        try run(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: [],
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try await runAsync(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: [],
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onTermination: @escaping @Sendable (SubprocessResult) throws -> Void,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        let result = try await runAsync(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: removingEnvironmentKeys,
            onStdout: onStdout,
            onStderr: onStderr
        )
        try onTermination(result)
        return result
    }
}

/// Captured subprocess termination details and collected output streams.
public struct SubprocessEnvironmentReceipt: Sendable, Equatable {
    public let explicitOverrides: [String: String]
    public let removedKeys: Set<String>
    public let effectiveValuesForControlledKeys: [String: String]

    public init(
        explicitOverrides: [String: String],
        removedKeys: Set<String>,
        effectiveValuesForControlledKeys: [String: String]
    ) {
        self.explicitOverrides = explicitOverrides
        self.removedKeys = removedKeys
        self.effectiveValuesForControlledKeys = effectiveValuesForControlledKeys
    }
}

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let terminationReason: Process.TerminationReason
    public let stdout: String
    public let stderr: String
    public let environmentReceipt: SubprocessEnvironmentReceipt?

    public init(
        exitCode: Int32,
        terminationReason: Process.TerminationReason,
        stdout: String,
        stderr: String,
        environmentReceipt: SubprocessEnvironmentReceipt? = nil
    ) {
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.stdout = stdout
        self.stderr = stderr
        self.environmentReceipt = environmentReceipt
    }
}

/// Default Foundation-based subprocess runner used throughout EasySplatCore.
public final class SubprocessRunner: @unchecked Sendable, SubprocessRunning {
    public init() {}

    static func ambientSensitiveEnvironmentKeys(
        in environment: [String: String] = RuntimeEnvironment.current
    ) -> Set<String> {
        let exact: Set<String> = [
            "ALL_PROXY",
            "AWS_CONFIG_FILE",
            "AWS_SHARED_CREDENTIALS_FILE",
            "CURL_CA_BUNDLE",
            "GH_TOKEN",
            "GIT_ASKPASS",
            "GIT_SSH",
            "GIT_SSH_COMMAND",
            "GITHUB_PERSONAL_ACCESS_TOKEN",
            "GITHUB_TOKEN",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "NETRC",
            "NO_PROXY",
            "REQUESTS_CA_BUNDLE",
            "SSH_ASKPASS",
            "SSH_AUTH_SOCK",
            "SSL_CERT_DIR",
            "SSL_CERT_FILE"
        ]
        let suffixes = [
            "_ACCESS_KEY",
            "_API_KEY",
            "_CLIENT_SECRET",
            "_CREDENTIAL",
            "_CREDENTIALS",
            "_PASSWD",
            "_PASSWORD",
            "_PRIVATE_KEY",
            "_SECRET",
            "_TOKEN"
        ]
        return Set(environment.keys.filter { key in
            let uppercased = key.uppercased()
            return exact.contains(uppercased)
                || uppercased.hasPrefix("DYLD_")
                || uppercased.hasPrefix("GIT_CONFIG_")
                || suffixes.contains(where: { uppercased.hasSuffix($0) })
        })
    }

    static func sanitizedAmbientEnvironment(
        _ environment: [String: String] = RuntimeEnvironment.current
    ) -> [String: String] {
        environment.filter { !ambientSensitiveEnvironmentKeys(in: environment).contains($0.key) }
    }

    private static func resolvedEnvironment(
        with overrides: [String: String],
        removing keys: Set<String>
    ) -> (environment: [String: String], receipt: SubprocessEnvironmentReceipt) {
        var environment = RuntimeEnvironment.current
        let removedKeys = ambientSensitiveEnvironmentKeys(in: environment).union(keys)
        for key in removedKeys {
            environment.removeValue(forKey: key)
        }
        environment.merge(overrides) { _, new in new }
        let controlledKeys = removedKeys.union(overrides.keys)
        let effectiveValues = Dictionary(
            uniqueKeysWithValues: controlledKeys.compactMap { key in
                environment[key].map { (key, $0) }
            }
        )
        return (
            environment,
            SubprocessEnvironmentReceipt(
                explicitOverrides: overrides,
                removedKeys: removedKeys,
                effectiveValuesForControlledKeys: effectiveValues
            )
        )
    }

    public func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let environmentResolution = Self.resolvedEnvironment(
            with: environment,
            removing: removingEnvironmentKeys
        )
        process.environment = environmentResolution.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = SubprocessStreamCollector(onLine: onStdout)
        let stderrCollector = SubprocessStreamCollector(onLine: onStderr)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.appendAvailableData(from: handle)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.appendAvailableData(from: handle)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw error
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        stdoutCollector.drainAndFinish {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        stderrCollector.drainAndFinish {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        return SubprocessResult(
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason,
            stdout: stdoutCollector.value(),
            stderr: stderrCollector.value(),
            environmentReceipt: environmentResolution.receipt
        )
    }

    public func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SubprocessResult {
        try await runAsync(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: removingEnvironmentKeys,
            onTermination: { _ in },
            onStdout: onStdout,
            onStderr: onStderr
        )
    }

    public func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        removingEnvironmentKeys: Set<String>,
        onTermination: @escaping @Sendable (SubprocessResult) throws -> Void,
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let environmentResolution = Self.resolvedEnvironment(
            with: environment,
            removing: removingEnvironmentKeys
        )
        process.environment = environmentResolution.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = SubprocessStreamCollector(onLine: onStdout)
        let stderrCollector = SubprocessStreamCollector(onLine: onStderr)
        let cancellationState = SubprocessCancellationState()
        let pipeFinalization = SubprocessPipeFinalization()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.appendAvailableData(from: handle)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.appendAvailableData(from: handle)
        }

        let completion = SubprocessAsyncCompletion()
        process.terminationHandler = { proc in
            let cancellationPrecededFinalization = cancellationState.beginPipeFinalization {
                pipeFinalization.cancelPendingReads()
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            if cancellationPrecededFinalization {
                stdoutCollector.finishBufferedOutput()
                stderrCollector.finishBufferedOutput()
            } else {
                // Drain both streams concurrently. A child can fill one pipe while
                // holding the other open, so serial EOF reads can deadlock even
                // without cancellation.
                let drains = DispatchGroup()
                drains.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutCollector.drainAndFinish {
                        pipeFinalization.readRemaining(from: stdoutPipe.fileHandleForReading)
                    }
                    drains.leave()
                }
                drains.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrCollector.drainAndFinish {
                        pipeFinalization.readRemaining(from: stderrPipe.fileHandleForReading)
                    }
                    drains.leave()
                }
                drains.wait()
            }
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            let cancellationObserved = cancellationState.finishPipeFinalization()
            if cancellationObserved {
                cancellationState.waitForCleanup()
            }
            let result = SubprocessResult(
                exitCode: proc.terminationStatus,
                terminationReason: proc.terminationReason,
                stdout: stdoutCollector.value(),
                stderr: stderrCollector.value(),
                environmentReceipt: environmentResolution.receipt
            )
            do {
                try onTermination(result)
                completion.finish(.success(result))
            } catch {
                completion.finish(.failure(error))
            }
        }

        let completionResult: Result<SubprocessResult, Error>
        do {
            completionResult = .success(try await withTaskCancellationHandler(operation: {
                do {
                    try Task.checkCancellation()
                    try cancellationState.launch(process) {
                        try process.run()
                    }
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    completion.finish(.failure(error))
                    throw error
                }
                return try await completion.wait()
            }, onCancel: {
                cancellationState.requestCancellation()
            }))
        } catch {
            completionResult = .failure(error)
        }

        let result = try completionResult.get()
        if Task.isCancelled {
            // Cancellation can arrive after pipe finalization but while the
            // termination callback is persisting its result. Do not let that
            // narrow window return before its already-started cleanup finishes.
            cancellationState.requestCancellation()
            cancellationState.waitForCleanup()
            throw CancellationError()
        }

        return result
    }
}

#if canImport(Darwin)
private final class SubprocessCancellationState: @unchecked Sendable {
    private struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init?(_ pid: pid_t) {
            guard pid > 1, pid != getpid() else { return nil }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
            self.pid = pid
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }

        var isCurrentProcess: Bool {
            guard let current = ProcessIdentity(pid) else { return false }
            return current == self
        }

        func send(_ signal: Int32) {
            guard isCurrentProcess else { return }
            _ = kill(pid, signal)
        }
    }

    private let lock = NSLock()
    private let cancellationCleanup = DispatchGroup()
    private var cancellationRequested = false
    private var terminationRequested = false
    private var rootIdentity: ProcessIdentity?
    private var isolatedProcessGroupID: pid_t?
    private var pipeCancellationHook: (@Sendable () -> Void)?
    private weak var launchedProcess: Process?

    func launch(_ process: Process, operation: () throws -> Void) throws {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            throw CancellationError()
        }
        do {
            // Hold the state lock across Foundation's short spawn operation. A
            // concurrent cancellation either wins before this point and prevents
            // launch, or waits and immediately terminates the launched process.
            try operation()
            launchedProcess = process
            for _ in 0..<4 where rootIdentity == nil || isolatedProcessGroupID == nil {
                refreshContainmentIdentity()
                if rootIdentity != nil, isolatedProcessGroupID != nil { break }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.001)
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func requestCancellation() {
        let request: (
            shouldTerminate: Bool,
            root: ProcessIdentity?,
            processGroupID: pid_t?,
            pipeHook: (@Sendable () -> Void)?
        ) = lock.withLock {
            cancellationRequested = true
            refreshContainmentIdentity()
            let pipeHook = pipeCancellationHook
            guard !terminationRequested,
                  rootIdentity != nil || isolatedProcessGroupID != nil else {
                return (false, nil, nil, pipeHook)
            }
            terminationRequested = true
            cancellationCleanup.enter()
            return (true, rootIdentity, isolatedProcessGroupID, pipeHook)
        }
        request.pipeHook?()
        guard request.shouldTerminate else { return }

        let initialTargets = Self.currentTargets(
            root: request.root,
            processGroupID: request.processGroupID
        )
        initialTargets.forEach { $0.send(SIGINT) }

        DispatchQueue.global(qos: .userInitiated).async { [cancellationCleanup] in
            Self.runEscalation(
                root: request.root,
                processGroupID: request.processGroupID,
                initiallyInterrupted: initialTargets
            )
            cancellationCleanup.leave()
        }
    }

    /// Installs the hook while holding the same lock used by cancellation. The
    /// caller therefore either observes an earlier cancellation or publishes a
    /// hook that every later cancellation must invoke.
    func beginPipeFinalization(
        onCancellation: @escaping @Sendable () -> Void
    ) -> Bool {
        let wasCancelled = lock.withLock {
            pipeCancellationHook = onCancellation
            return cancellationRequested
        }
        if wasCancelled {
            onCancellation()
        }
        return wasCancelled
    }

    func finishPipeFinalization() -> Bool {
        lock.withLock {
            pipeCancellationHook = nil
            return cancellationRequested
        }
    }

    func waitForCleanup() {
        _ = cancellationCleanup.wait(timeout: .now() + 2)
    }

    private static func runEscalation(
        root: ProcessIdentity?,
        processGroupID: pid_t?,
        initiallyInterrupted: Set<ProcessIdentity>
    ) {
        let started = Date()
        var interrupted = initiallyInterrupted
        var terminated: Set<ProcessIdentity> = []
        var killed: Set<ProcessIdentity> = []
        while true {
            let elapsed = Date().timeIntervalSince(started)
            let targets = currentTargets(root: root, processGroupID: processGroupID)
            if targets.isEmpty { return }

            for target in targets {
                let isRoot = target == root
                if isRoot {
                    if elapsed >= 15, killed.insert(target).inserted {
                        target.send(SIGKILL)
                    } else if elapsed >= 12, terminated.insert(target).inserted {
                        target.send(SIGTERM)
                    }
                } else if elapsed >= 0.75, killed.insert(target).inserted {
                    target.send(SIGKILL)
                } else if elapsed >= 0.25, terminated.insert(target).inserted {
                    target.send(SIGTERM)
                } else if interrupted.insert(target).inserted {
                    target.send(SIGINT)
                }
            }

            if root?.isCurrentProcess != true,
               elapsed >= 1.5,
               targets.allSatisfy({ killed.contains($0) }) {
                return
            }
            if elapsed >= 15.5 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func refreshContainmentIdentity() {
        guard let process = launchedProcess, process.isRunning else { return }
        let rootPID = process.processIdentifier
        if rootIdentity == nil {
            rootIdentity = ProcessIdentity(rootPID)
        }
        guard isolatedProcessGroupID == nil else { return }
        let processGroupID = getpgid(rootPID)
        // Foundation creates a dedicated process group before exec. Retain it
        // only when it is demonstrably isolated from this app; otherwise the
        // pinned root and repeatedly enumerated child tree remain the fallback.
        if processGroupID == rootPID,
           processGroupID > 1,
           processGroupID != getpgrp() {
            isolatedProcessGroupID = processGroupID
        }
    }

    private static func currentTargets(
        root: ProcessIdentity?,
        processGroupID: pid_t?
    ) -> Set<ProcessIdentity> {
        if let processGroupID {
            return processGroupMembers(processGroupID)
        }
        guard let root, root.isCurrentProcess else { return [] }
        return Set([root]).union(descendants(of: root.pid))
    }

    private static func processGroupMembers(_ processGroupID: pid_t) -> Set<ProcessIdentity> {
        guard processGroupID > 1, processGroupID != getpgrp() else { return [] }
        let estimatedCount = max(proc_listallpids(nil, 0), 0)
        guard estimatedCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let listedCount = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard listedCount > 0 else { return [] }
        return Set(pids.prefix(Int(listedCount)).compactMap { pid in
            guard pid > 1,
                  pid != getpid(),
                  getpgid(pid) == processGroupID else { return nil }
            return ProcessIdentity(pid)
        })
    }

    private static func descendants(of rootPID: pid_t) -> [ProcessIdentity] {
        var discovered: Set<ProcessIdentity> = []
        var visited: Set<pid_t> = [rootPID]
        var pending: [pid_t] = [rootPID]
        while let parent = pending.popLast() {
            for child in childPIDs(of: parent) where visited.insert(child).inserted {
                guard let identity = ProcessIdentity(child) else { continue }
                discovered.insert(identity)
                pending.append(child)
            }
        }
        return discovered.sorted { $0.pid < $1.pid }
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 4_096 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = proc_listchildpids(
                parent,
                &buffer,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
            guard count >= 0 else { return [] }
            if count < capacity || capacity == 4_096 {
                return Array(buffer.prefix(Int(count))).filter { $0 > 1 }
            }
            capacity *= 2
        }
        return []
    }

}

private final class SubprocessPipeFinalization: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    func cancelPendingReads() {
        lock.withLock { cancellationRequested = true }
    }

    func readRemaining(from handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return Data()
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while !lock.withLock({ cancellationRequested }) {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                collected.append(contentsOf: buffer.prefix(Int(bytesRead)))
                continue
            }
            if bytesRead == 0 { break }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { break }

            var pending = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            _ = Darwin.poll(&pending, 1, 25)
        }
        return collected
    }
}
#endif

private final class SubprocessAsyncCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SubprocessResult, Error>?
    private var result: Result<SubprocessResult, Error>?

    func wait() async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<SubprocessResult, Error>?
            lock.lock()
            if let result {
                completed = result
            } else {
                self.continuation = continuation
                completed = nil
            }
            lock.unlock()

            if let completed {
                continuation.resume(with: completed)
            }
        }
    }

    func finish(_ result: Result<SubprocessResult, Error>) {
        let continuation: CheckedContinuation<SubprocessResult, Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class SubprocessStreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let output = OutputBuffer()
    private let lineBuffer = SubprocessLineBuffer()
    private let decoder = Utf8StreamDecoder()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func appendAvailableData(from handle: FileHandle) {
        lockedAppendAndEmit {
            handle.availableData
        }
    }

    func drainAndFinish(readRemaining: () -> Data) {
        lockedAppendAndEmit(readRemaining, flush: true)
    }

    func finishBufferedOutput() {
        lockedAppendAndEmit({ Data() }, flush: true)
    }

    func value() -> String {
        output.value()
    }

    private func lockedAppendAndEmit(_ readRemaining: () -> Data, flush: Bool = false) {
        lock.lock()
        var lines = appendLocked(readRemaining())
        if flush {
            if let remaining = decoder.flush(), !remaining.isEmpty {
                output.append(remaining)
                lines.append(contentsOf: lineBuffer.append(remaining))
            }
            if let remaining = lineBuffer.flush() {
                lines.append(remaining)
            }
        }
        for line in lines {
            onLine(line)
        }
        lock.unlock()
    }

    private func appendLocked(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let text = decoder.decode(data)
        guard !text.isEmpty else { return [] }
        output.append(text)
        return lineBuffer.append(text)
    }

}

private final class OutputBuffer: @unchecked Sendable {
    private static let maxBytes = 1_048_576
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        trimIfNeeded()
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func trimIfNeeded() {
        if storage.utf8.count > Self.maxBytes {
            storage = TextByteLimiter.validUTF8Suffix(storage, byteLimit: Self.maxBytes)
        }
    }
}

private final class Utf8StreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func decode(_ data: Data) -> String {
        lock.lock()
        pending.append(data)
        let cut = validUtf8PrefixLength(pending)
        if cut <= 0 {
            lock.unlock()
            return ""
        }
        let prefix = pending.prefix(cut)
        pending.removeFirst(cut)
        lock.unlock()
        return String(decoding: prefix, as: UTF8.self)
    }

    func flush() -> String? {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return nil
        }
        let remainder = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        return String(decoding: remainder, as: UTF8.self)
    }

    private func validUtf8PrefixLength(_ data: Data) -> Int {
        // We only trim off an incomplete trailing UTF-8 sequence. Most tool output is valid UTF-8,
        // but read boundaries can split multi-byte scalars (e.g. emoji), so decoding must be incremental.
        let count = data.count
        guard count > 0 else { return 0 }

        // Find how many continuation bytes (10xxxxxx) are at the end.
        var continuationCount = 0
        var idx = count - 1
        while idx >= 0 {
            let byte = data[data.index(data.startIndex, offsetBy: idx)]
            if (byte & 0xC0) == 0x80 {
                continuationCount += 1
                idx -= 1
                continue
            }
            break
        }
        let startIndex: Int
        if continuationCount == 0 {
            startIndex = count - 1
        } else {
            if continuationCount > 3 {
                // Invalid trailing sequence; let String(decoding:) handle it.
                return count
            }
            guard idx >= 0 else { return 0 }
            startIndex = idx
        }

        let startByte = data[data.index(data.startIndex, offsetBy: startIndex)]
        guard let expectedLength = expectedUtf8Length(for: startByte) else {
            // Invalid start byte; treat the buffer as decodable (String(decoding:) will replace as needed).
            return count
        }

        let availableLength = count - startIndex
        if availableLength < expectedLength {
            return startIndex
        }
        return count
    }

    private func expectedUtf8Length(for byte: UInt8) -> Int? {
        if (byte & 0x80) == 0x00 {
            return 1
        }
        if (byte & 0xE0) == 0xC0 {
            return 2
        }
        if (byte & 0xF0) == 0xE0 {
            return 3
        }
        if (byte & 0xF8) == 0xF0 {
            return 4
        }
        return nil
    }
}

#if DEBUG
struct TestUtf8StreamDecoder {
    private var decoder = Utf8StreamDecoder()

    mutating func decode(_ bytes: [UInt8]) -> String {
        decoder.decode(Data(bytes))
    }

    mutating func flush() -> String? {
        decoder.flush()
    }
}
#endif

final class SubprocessLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var remainder = ""

    func append(_ chunk: String) -> [String] {
        lock.lock()
        remainder += chunk
        var lines: [String] = []
        // Split on both "\n" and "\r" so we can capture progress bars that redraw the current
        // line using carriage returns (e.g., indicatif). In Swift's `Character` view, "\r\n"
        // can be treated as a single extended grapheme cluster, so scan Unicode scalars.
        while true {
            guard let scalarIndex = remainder.unicodeScalars.firstIndex(where: { $0.value == 10 || $0.value == 13 }) else {
                lock.unlock()
                return lines
            }
            guard let delimiterStart = scalarIndex.samePosition(in: remainder) else {
                lock.unlock()
                return lines
            }

            let line = String(remainder[..<delimiterStart])
            lines.append(line)

            var scalarEnd = remainder.unicodeScalars.index(after: scalarIndex)
            if remainder.unicodeScalars[scalarIndex].value == 13,
               scalarEnd < remainder.unicodeScalars.endIndex,
               remainder.unicodeScalars[scalarEnd].value == 10 {
                // Consume CRLF as a single delimiter.
                scalarEnd = remainder.unicodeScalars.index(after: scalarEnd)
            }
            let delimiterEnd = scalarEnd.samePosition(in: remainder) ?? remainder.endIndex
            remainder.removeSubrange(remainder.startIndex..<delimiterEnd)
        }
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !remainder.isEmpty else { return nil }
        var line = remainder
        remainder = ""
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        return line.isEmpty ? nil : line
    }
}
