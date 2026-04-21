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

/// Subprocess runner that can allocate a pseudo-terminal for CLI tools that require one.
public protocol PseudoTTYCapableSubprocessRunning: SubprocessRunning {
    func runAsyncPseudoTTY(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult
}

struct PseudoTTYFailure: Error, LocalizedError, Sendable {
    let function: String
    let errnoCode: Int32

    var errorDescription: String? {
        let message = String(cString: strerror(errnoCode))
        return "Pseudo-tty setup failed in \(function): \(message) (\(errnoCode))"
    }
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
public final class SubprocessRunner: @unchecked Sendable, SubprocessRunning, PseudoTTYCapableSubprocessRunning {
    public init() {}

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
            process.environment = process.environment?.merging(environment) { _, new in new } ?? environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collectedOut = OutputBuffer()
        let collectedErr = OutputBuffer()
        let stdoutLines = SubprocessLineBuffer()
        let stderrLines = SubprocessLineBuffer()
        let stdoutDecoder = Utf8StreamDecoder()
        let stderrDecoder = Utf8StreamDecoder()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = stdoutDecoder.decode(data)
            guard !text.isEmpty else { return }
            collectedOut.append(text)
            stdoutLines.append(text).forEach { line in onStdout(line) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = stderrDecoder.decode(data)
            guard !text.isEmpty else { return }
            collectedErr.append(text)
            stderrLines.append(text).forEach { line in onStderr(line) }
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

        if let remaining = stdoutDecoder.flush(), !remaining.isEmpty {
            collectedOut.append(remaining)
            stdoutLines.append(remaining).forEach { line in onStdout(line) }
        }
        if let remaining = stderrDecoder.flush(), !remaining.isEmpty {
            collectedErr.append(remaining)
            stderrLines.append(remaining).forEach { line in onStderr(line) }
        }

        if let remaining = stdoutLines.flush() {
            onStdout(remaining)
        }
        if let remaining = stderrLines.flush() {
            onStderr(remaining)
        }

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        return SubprocessResult(
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason,
            stdout: collectedOut.value(),
            stderr: collectedErr.value()
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
            process.environment = process.environment?.merging(environment) { _, new in new } ?? environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collectedOut = OutputBuffer()
        let collectedErr = OutputBuffer()
        let stdoutLines = SubprocessLineBuffer()
        let stderrLines = SubprocessLineBuffer()
        let stdoutDecoder = Utf8StreamDecoder()
        let stderrDecoder = Utf8StreamDecoder()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = stdoutDecoder.decode(data)
            guard !text.isEmpty else { return }
            collectedOut.append(text)
            stdoutLines.append(text).forEach { line in onStdout(line) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = stderrDecoder.decode(data)
            guard !text.isEmpty else { return }
            collectedErr.append(text)
            stderrLines.append(text).forEach { line in onStderr(line) }
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

        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    if let remaining = stdoutDecoder.flush(), !remaining.isEmpty {
                        collectedOut.append(remaining)
                        stdoutLines.append(remaining).forEach { line in onStdout(line) }
                    }
                    if let remaining = stderrDecoder.flush(), !remaining.isEmpty {
                        collectedErr.append(remaining)
                        stderrLines.append(remaining).forEach { line in onStderr(line) }
                    }

                    if let remaining = stdoutLines.flush() {
                        onStdout(remaining)
                    }
                    if let remaining = stderrLines.flush() {
                        onStderr(remaining)
                    }
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(returning: SubprocessResult(
                        exitCode: proc.terminationStatus,
                        terminationReason: proc.terminationReason,
                        stdout: collectedOut.value(),
                        stderr: collectedErr.value()
                    ))
                }
            }
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

    public func runAsyncPseudoTTY(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        onStdout: @escaping @Sendable (String) -> Void = { _ in },
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SubprocessResult {
        #if canImport(Darwin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if !environment.isEmpty {
            process.environment = process.environment?.merging(environment) { _, new in new } ?? environment
        }

        let stdoutTTY = try PseudoTTYPair.open()
        let stderrTTY = try PseudoTTYPair.open()
        process.standardOutput = stdoutTTY.slaveHandle
        process.standardError = stderrTTY.slaveHandle

        let collectedOut = OutputBuffer()
        let collectedErr = OutputBuffer()
        let stdoutLines = SubprocessLineBuffer()
        let stderrLines = SubprocessLineBuffer()
        let stdoutDecoder = Utf8StreamDecoder()
        let stderrDecoder = Utf8StreamDecoder()

        stdoutTTY.masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = stdoutDecoder.decode(data)
            guard !text.isEmpty else { return }
            collectedOut.append(text)
            stdoutLines.append(text).forEach { line in onStdout(line) }
        }

        stderrTTY.masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = stderrDecoder.decode(data)
            guard !text.isEmpty else { return }
            collectedErr.append(text)
            stderrLines.append(text).forEach { line in onStderr(line) }
        }

        do {
            try process.run()
        } catch {
            stdoutTTY.masterHandle.readabilityHandler = nil
            stderrTTY.masterHandle.readabilityHandler = nil
            stdoutTTY.masterHandle.closeFile()
            stderrTTY.masterHandle.closeFile()
            stdoutTTY.slaveHandle.closeFile()
            stderrTTY.slaveHandle.closeFile()
            throw error
        }
        stdoutTTY.slaveHandle.closeFile()
        stderrTTY.slaveHandle.closeFile()

        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stdoutTTY.masterHandle.readabilityHandler = nil
                    stderrTTY.masterHandle.readabilityHandler = nil

                    if let remaining = stdoutDecoder.flush(), !remaining.isEmpty {
                        collectedOut.append(remaining)
                        stdoutLines.append(remaining).forEach { line in onStdout(line) }
                    }
                    if let remaining = stderrDecoder.flush(), !remaining.isEmpty {
                        collectedErr.append(remaining)
                        stderrLines.append(remaining).forEach { line in onStderr(line) }
                    }

                    if let remaining = stdoutLines.flush() {
                        onStdout(remaining)
                    }
                    if let remaining = stderrLines.flush() {
                        onStderr(remaining)
                    }

                    stdoutTTY.masterHandle.closeFile()
                    stderrTTY.masterHandle.closeFile()

                    continuation.resume(returning: SubprocessResult(
                        exitCode: proc.terminationStatus,
                        terminationReason: proc.terminationReason,
                        stdout: collectedOut.value(),
                        stderr: collectedErr.value()
                    ))
                }
            }
        }, onCancel: {
            if process.isRunning {
                Self.requestGracefulTermination(process)
            }
        })

        if Task.isCancelled {
            throw CancellationError()
        }

        return result
        #else
        return try await runAsync(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            onStdout: onStdout,
            onStderr: onStderr
        )
        #endif
    }
}

#if canImport(Darwin)
private extension SubprocessRunner {
    static func requestGracefulTermination(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else {
            process.terminate()
            return
        }

        func isAlive(_ pid: pid_t) -> Bool {
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }

        _ = kill(pid, SIGINT)

        Task.detached {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard isAlive(pid) else { return }
            _ = kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard isAlive(pid) else { return }
            _ = kill(pid, SIGKILL)
        }
    }
}

private struct PseudoTTYPair {
    let masterHandle: FileHandle
    let slaveHandle: FileHandle

    static func open() throws -> PseudoTTYPair {
        var master: Int32 = -1
        var slave: Int32 = -1
        if openpty(&master, &slave, nil, nil, nil) != 0 {
            throw PseudoTTYFailure(function: "openpty", errnoCode: errno)
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        return PseudoTTYPair(masterHandle: masterHandle, slaveHandle: slaveHandle)
    }
}
#endif

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
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
