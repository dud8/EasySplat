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
}

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
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

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collectedOut.append(text)
            text.split(separator: "\n").forEach { line in onStdout(String(line)) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collectedErr.append(text)
            text.split(separator: "\n").forEach { line in onStderr(String(line)) }
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        return SubprocessResult(exitCode: process.terminationStatus, stdout: collectedOut.value(), stderr: collectedErr.value())
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
