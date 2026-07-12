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
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
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
        try run(launchPath, arguments, currentDirectory: nil, environment: [:], onStdout: onStdout, onStderr: onStderr)
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SubprocessResult {
        try await runAsync(launchPath, arguments, currentDirectory: nil, environment: [:], onStdout: onStdout, onStderr: onStderr)
    }
}

/// Captured subprocess termination details and collected output streams.
public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let terminationReason: Process.TerminationReason
    public let stdout: String
    public let stderr: String
}

/// Default Foundation-based subprocess runner used throughout EasySplatCore.
public final class SubprocessRunner: @unchecked Sendable, SubprocessRunning {
    public init() {}

    private static func mergedEnvironment(with overrides: [String: String]) -> [String: String] {
        RuntimeEnvironment.current.merging(overrides) { _, new in new }
    }

    public func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if !environment.isEmpty {
            process.environment = Self.mergedEnvironment(with: environment)
        }

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
            stderr: stderrCollector.value()
        )
    }

    public func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if !environment.isEmpty {
            process.environment = Self.mergedEnvironment(with: environment)
        }

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

        let completion = SubprocessAsyncCompletion()
        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            stdoutCollector.drainAndFinish {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            stderrCollector.drainAndFinish {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            completion.finish(.success(SubprocessResult(
                exitCode: proc.terminationStatus,
                terminationReason: proc.terminationReason,
                stdout: stdoutCollector.value(),
                stderr: stderrCollector.value()
            )))
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
            completion.finish(.failure(error))
            throw error
        }

        let result = try await withTaskCancellationHandler(operation: {
            try await completion.wait()
        }, onCancel: {
            if process.isRunning {
                Self.requestGracefulTermination(process)
            }
        })

        if Task.isCancelled {
            throw CancellationError()
        }

        return result
    }
}

#if canImport(Darwin)
private extension SubprocessRunner {
    static func requestGracefulTermination(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else {
            process.terminate()
            return
        }

        _ = kill(pid, SIGINT)

        // Resolve the PID against the live Process to avoid signaling a recycled PID
        // after the original child has exited and been reaped.
        let escalation = Task.detached { [weak process] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if Task.isCancelled { return }
            guard let process, process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGTERM)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            guard process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }

        // Chain into the existing termination handler so the escalation is cancelled
        // the moment the process actually exits, even if it exits before our timers fire.
        let previousHandler = process.terminationHandler
        process.terminationHandler = { proc in
            escalation.cancel()
            previousHandler?(proc)
        }
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
