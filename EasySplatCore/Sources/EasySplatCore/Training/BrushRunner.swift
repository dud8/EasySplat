import Foundation

public final class BrushRunner {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runTrain(
        brushPath: URL,
        datasetPath: URL,
        totalSteps: Int? = nil,
        exportEvery: Int? = nil,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: brushPath.path) else {
            throw SubprocessFailure(
                tool: "brush",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Brush binary is not executable: \(brushPath.path)"
            )
        }
        guard fm.fileExists(atPath: datasetPath.path) else {
            throw SubprocessFailure(
                tool: "brush",
                command: "train",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Dataset path does not exist: \(datasetPath.path)"
            )
        }

        let workingDirectory = datasetPath.deletingLastPathComponent()
        var environment = ["RUST_BACKTRACE": "1"]
        if let override = ProcessInfo.processInfo.environment["EASYSPLAT_BRUSH_RUST_LOG"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["RUST_LOG"] = override
        }
        if ProcessInfo.processInfo.environment["TERM"] == nil {
            environment["TERM"] = "xterm-256color"
        }

        func runBrush(_ arguments: [String]) async throws -> SubprocessResult {
            do {
                if let ptyRunner = runner as? PseudoTTYCapableSubprocessRunning {
                    do {
                        return try await ptyRunner.runAsyncPseudoTTY(
                            brushPath.path,
                            arguments,
                            currentDirectory: workingDirectory,
                            environment: environment,
                            onStdout: { onLog($0, false) },
                            onStderr: { onLog($0, true) }
                        )
                    } catch let error as PseudoTTYFailure {
                        onLog("EasySplat: pseudo-tty unavailable (\(error.localizedDescription)); retrying without tty.", true)
                    }
                }
                return try await runner.runAsync(
                    brushPath.path,
                    arguments,
                    currentDirectory: workingDirectory,
                    environment: environment,
                    onStdout: { onLog($0, false) },
                    onStderr: { onLog($0, true) }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SubprocessFailure(
                    tool: "brush",
                    command: "train",
                    exitCode: -1,
                    terminationReason: .exit,
                    stdoutTail: "",
                    stderrTail: "Failed to launch brush: \(error)"
                )
            }
        }

        func intEnv(_ key: String) -> Int? {
            guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let value = Int(raw),
                  value > 0 else { return nil }
            return value
        }

        func resolveInt(_ key: String, fallback: Int?) -> Int? {
            if let envValue = intEnv(key) {
                return envValue
            }
            return fallback
        }

        // Brush CLI changed from `brush train <dataset>` to `brush <dataset>`; attempt the
        // modern form first and fall back to the legacy form when it looks required.
        var flagArgs: [String] = []
        if let resolvedTotalSteps = resolveInt("EASYSPLAT_BRUSH_TOTAL_STEPS", fallback: totalSteps) {
            flagArgs += ["--total-steps", "\(resolvedTotalSteps)"]
        }
        if let resolvedExportEvery = resolveInt("EASYSPLAT_BRUSH_EXPORT_EVERY", fallback: exportEvery) {
            flagArgs += ["--export-every", "\(resolvedExportEvery)"]
        }

        var primaryArgs = flagArgs
        primaryArgs.append(datasetPath.path)

        onLog("EasySplat: running brush (cwd=\(workingDirectory.path))", false)
        if let rustLog = environment["RUST_LOG"] {
            onLog("EasySplat: brush env RUST_LOG=\(rustLog)", false)
        }
        onLog("EasySplat: brush argv: \(brushPath.path) \(primaryArgs.joined(separator: " "))", false)
        let primary = try await runBrush(primaryArgs)
        if primary.exitCode == 0 {
            return
        }

        let combined = (primary.stderr + "\n" + primary.stdout).lowercased()
        let looksLikeLegacySubcommandRequired =
            combined.contains("unrecognized subcommand")
            || combined.contains("unknown subcommand")
            || combined.contains("unknown command")
            || combined.contains("commands:")

        if looksLikeLegacySubcommandRequired {
            onLog("EasySplat: brush CLI looks like it requires legacy `train` subcommand; retrying.", true)
            let legacyArgs = ["train"] + flagArgs + [datasetPath.path]
            onLog("EasySplat: brush argv: \(brushPath.path) \(legacyArgs.joined(separator: " "))", false)
            let legacy = try await runBrush(legacyArgs)
            if legacy.exitCode == 0 {
                return
            }
            if !flagArgs.isEmpty {
                onLog("EasySplat: brush legacy CLI rejected training flags; retrying without flags.", true)
                let legacyFallbackArgs = ["train", datasetPath.path]
                onLog("EasySplat: brush argv: \(brushPath.path) \(legacyFallbackArgs.joined(separator: " "))", false)
                let legacyFallback = try await runBrush(legacyFallbackArgs)
                guard legacyFallback.exitCode == 0 else {
                    throw SubprocessFailure(
                        tool: "brush",
                        command: "train",
                        exitCode: legacyFallback.exitCode,
                        terminationReason: legacyFallback.terminationReason,
                        stdoutTail: TextTails.tailLines(legacyFallback.stdout, limit: 40),
                        stderrTail: TextTails.tailLines(legacyFallback.stderr, limit: 40)
                    )
                }
                return
            }
            throw SubprocessFailure(
                tool: "brush",
                command: "train",
                exitCode: legacy.exitCode,
                terminationReason: legacy.terminationReason,
                stdoutTail: TextTails.tailLines(legacy.stdout, limit: 40),
                stderrTail: TextTails.tailLines(legacy.stderr, limit: 40)
            )
        }

        throw SubprocessFailure(
            tool: "brush",
            command: "train",
            exitCode: primary.exitCode,
            terminationReason: primary.terminationReason,
            stdoutTail: TextTails.tailLines(primary.stdout, limit: 40),
            stderrTail: TextTails.tailLines(primary.stderr, limit: 40)
        )
    }

    public func findLatestPly(in directory: URL) -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var latest: (URL, Date)?
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "ply" else { continue }
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if let current = latest {
                if date > current.1 {
                    latest = (item, date)
                }
            } else {
                latest = (item, date)
            }
        }
        return latest?.0
    }
}
