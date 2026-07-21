import Foundation
@testable import EasySplatCore

final class MockSubprocessRunner: @unchecked Sendable, SubprocessRunning {
    struct Script {
        let path: String
        let argsPrefix: [String]
        let result: SubprocessResult
        let stdoutLines: [String]
        let stdoutLinesProvider: (([String]) -> [String])?
        let stderrLines: [String]
        let onRun: (([String]) throws -> Void)?

        init(
            path: String,
            argsPrefix: [String],
            result: SubprocessResult,
            stdoutLines: [String] = [],
            stdoutLinesProvider: (([String]) -> [String])? = nil,
            stderrLines: [String] = [],
            onRun: (([String]) throws -> Void)? = nil
        ) {
            self.path = path
            self.argsPrefix = argsPrefix
            self.result = result
            self.stdoutLines = stdoutLines
            self.stdoutLinesProvider = stdoutLinesProvider
            self.stderrLines = stderrLines
            self.onRun = onRun
        }
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var recordedCalls: [(String, [String])] = []
    private var recordedEnvironments: [[String: String]] = []
    private var recordedRemovedEnvironmentKeys: [Set<String>] = []

    var calls: [(String, [String])] {
        lock.withLock { recordedCalls }
    }

    var environments: [[String: String]] {
        lock.withLock { recordedEnvironments }
    }

    var removedEnvironmentKeys: [Set<String>] {
        lock.withLock { recordedRemovedEnvironmentKeys }
    }

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        let script: Script = try lock.withLock {
            guard let index = scripts.firstIndex(where: { $0.path == launchPath && arguments.starts(with: $0.argsPrefix) }) else {
                throw NSError(domain: "MockSubprocessRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected command: \(launchPath) \(arguments)"])
            }
            let script = scripts.remove(at: index)
            recordedCalls.append((launchPath, arguments))
            recordedEnvironments.append(environment)
            recordedRemovedEnvironmentKeys.append(removingEnvironmentKeys)
            return script
        }
        try script.onRun?(arguments)
        (script.stdoutLinesProvider?(arguments) ?? script.stdoutLines).forEach(onStdout)
        script.stderrLines.forEach(onStderr)
        let controlledKeys = removingEnvironmentKeys.union(environment.keys)
        let effectiveValues = Dictionary(
            uniqueKeysWithValues: controlledKeys.compactMap { key in
                environment[key].map { (key, $0) }
            }
        )
        return SubprocessResult(
            exitCode: script.result.exitCode,
            terminationReason: script.result.terminationReason,
            stdout: script.result.stdout,
            stderr: script.result.stderr,
            environmentReceipt: SubprocessEnvironmentReceipt(
                explicitOverrides: environment,
                removedKeys: removingEnvironmentKeys,
                effectiveValuesForControlledKeys: effectiveValues
            )
        )
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try run(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: removingEnvironmentKeys,
            onStdout: onStdout,
            onStderr: onStderr
        )
    }
}

final class CheckpointCancellingSubprocessRunner: @unchecked Sendable, SubprocessRunning {
    private let backing: MockSubprocessRunner
    private let launchPath: String
    private let events: String

    init(backing: MockSubprocessRunner, launchPath: String, events: String) {
        self.backing = backing
        self.launchPath = launchPath
        self.events = events
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        try backing.run(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: removingEnvironmentKeys,
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
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        guard launchPath == self.launchPath else {
            return try await backing.runAsync(
                launchPath,
                arguments,
                currentDirectory: currentDirectory,
                environment: environment,
                removingEnvironmentKeys: removingEnvironmentKeys,
                onStdout: onStdout,
                onStderr: onStderr
            )
        }
        for line in events.split(whereSeparator: \.isNewline) {
            onStdout(String(line))
        }
        throw CancellationError()
    }
}
