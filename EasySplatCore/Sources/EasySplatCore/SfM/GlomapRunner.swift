import Foundation

public final class GlomapRunner {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runMapper(
        glomapPath: URL,
        database: URL,
        imagePath: URL,
        outputPath: URL,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let args = [
            "mapper",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--output_path", outputPath.path
        ]
        onLog("EasySplat: glomap argv: \(glomapPath.path) \(args.joined(separator: " "))", false)
        let result = try await runner.runAsync(glomapPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else {
            throw SubprocessFailure(
                tool: "glomap",
                command: "mapper",
                exitCode: result.exitCode,
                terminationReason: result.terminationReason,
                stdoutTail: TextTails.tailLines(result.stdout, limit: 40),
                stderrTail: TextTails.tailLines(result.stderr, limit: 40)
            )
        }
    }
}
