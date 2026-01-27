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
    ) throws {
        let args = [
            "mapper",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--output_path", outputPath.path
        ]
        let result = try runner.run(glomapPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else { throw NSError(domain: "GlomapRunner", code: Int(result.exitCode)) }
    }
}
