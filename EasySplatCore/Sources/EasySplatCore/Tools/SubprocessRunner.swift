import Foundation

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

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let terminationReason: Process.TerminationReason
    public let stdout: String
    public let stderr: String
}

public final class SubprocessRunner: @unchecked Sendable, SubprocessRunning {
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

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collectedOut.append(text)
            stdoutLines.append(text).forEach { line in onStdout(line) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collectedErr.append(text)
            stderrLines.append(text).forEach { line in onStderr(line) }
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if let remaining = stdoutLines.flush() {
            onStdout(remaining)
        }
        if let remaining = stderrLines.flush() {
            onStderr(remaining)
        }

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

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collectedOut.append(text)
            stdoutLines.append(text).forEach { line in onStdout(line) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collectedErr.append(text)
            stderrLines.append(text).forEach { line in onStderr(line) }
        }

        try process.run()

        let result = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if let remaining = stdoutLines.flush() {
                        onStdout(remaining)
                    }
                    if let remaining = stderrLines.flush() {
                        onStderr(remaining)
                    }
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
                process.terminate()
            }
        })

        if Task.isCancelled {
            throw CancellationError()
        }

        return result
    }
}

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

final class SubprocessLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var remainder = ""

    func append(_ chunk: String) -> [String] {
        lock.lock()
        remainder += chunk
        var lines: [String] = []
        while let range = remainder.range(of: "\n") {
            var line = String(remainder[..<range.lowerBound])
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            lines.append(line)
            remainder.removeSubrange(remainder.startIndex..<range.upperBound)
        }
        lock.unlock()
        return lines
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
