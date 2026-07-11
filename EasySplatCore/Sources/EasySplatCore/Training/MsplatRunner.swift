import Foundation

public final class MsplatRunner {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runTrain(
        msplatPath: URL,
        datasetPath: URL,
        outputPath: URL,
        iterations: Int? = nil,
        numDownscales: Int? = nil,
        downscaleFactor: Double? = nil,
        evaluate: Bool = false,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: msplatPath.path) else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "easysplat-train is not executable: \(msplatPath.path)"
            )
        }
        guard fm.fileExists(atPath: datasetPath.path) else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Dataset path does not exist: \(datasetPath.path)"
            )
        }

        try fm.createDirectory(at: outputPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        let resolvedIterations = resolvePositiveInt(
            key: "EASYSPLAT_MSPLAT_ITERS",
            fallback: iterations ?? 7_000
        )
        let resolvedNumDownscales = resolveNonNegativeInt(
            key: "EASYSPLAT_MSPLAT_NUM_DOWNSCALES",
            fallback: numDownscales ?? 0
        )
        let resolvedDownscaleFactor = resolvePositiveDouble(
            key: "EASYSPLAT_MSPLAT_DOWNSCALE_FACTOR",
            fallback: downscaleFactor ?? 1.0
        )

        var args = [
            "--input", datasetPath.path,
            "--output", outputPath.path,
            "--num-iters", "\(resolvedIterations)",
            "--num-downscales", "\(resolvedNumDownscales)",
            "--downscale-factor", Self.formatDouble(resolvedDownscaleFactor)
        ]
        if evaluate {
            args.append("--eval")
        }

        var environment: [String: String] = [:]
        if RuntimeEnvironment.current["TERM"] == nil {
            environment["TERM"] = "xterm-256color"
        }

        onLog("EasySplat: running msplat (cwd=\(datasetPath.deletingLastPathComponent().path))", false)
        onLog("EasySplat: msplat argv: \(msplatPath.path) \(args.joined(separator: " "))", false)

        let result: SubprocessResult
        do {
            result = try await runner.runAsync(
                msplatPath.path,
                args,
                currentDirectory: datasetPath.deletingLastPathComponent(),
                environment: environment,
                onStdout: { onLog($0, false) },
                onStderr: { onLog($0, true) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Failed to launch easysplat-train: \(error)"
            )
        }

        guard result.exitCode == 0 else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "train",
                exitCode: result.exitCode,
                terminationReason: result.terminationReason,
                stdoutTail: TextTails.tailLines(result.stdout, limit: 40),
                stderrTail: TextTails.tailLines(result.stderr, limit: 40)
            )
        }
    }

    private func resolvePositiveInt(key: String, fallback: Int) -> Int {
        guard let raw = envValue(key), let value = Int(raw), value > 0 else {
            return max(1, fallback)
        }
        return value
    }

    private func resolveNonNegativeInt(key: String, fallback: Int) -> Int {
        guard let raw = envValue(key), let value = Int(raw), value >= 0 else {
            return max(0, fallback)
        }
        return value
    }

    private func resolvePositiveDouble(key: String, fallback: Double) -> Double {
        guard let raw = envValue(key), let value = Double(raw), value > 0 else {
            return max(0.000_001, fallback)
        }
        return value
    }

    private func envValue(_ key: String) -> String? {
        guard let raw = RuntimeEnvironment.current[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func formatDouble(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }
}
