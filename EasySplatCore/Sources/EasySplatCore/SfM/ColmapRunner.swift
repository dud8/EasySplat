import Foundation

public final class ColmapRunner {
    private let runner: SubprocessRunning

    public init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    public func runFeatureExtractor(
        colmapPath: URL,
        database: URL,
        imagePath: URL,
        maxImageSize: Int,
        cameraModel: String,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        let args = [
            "feature_extractor",
            "--database_path", database.path,
            "--image_path", imagePath.path,
            "--ImageReader.single_camera", "1",
            "--ImageReader.camera_model", cameraModel,
            "--SiftExtraction.max_image_size", "\(maxImageSize)"
        ]
        let result = try runner.run(colmapPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else { throw NSError(domain: "ColmapRunner", code: Int(result.exitCode)) }
    }

    public func runMatcherSequential(
        colmapPath: URL,
        database: URL,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        let args = ["sequential_matcher", "--database_path", database.path]
        let result = try runner.run(colmapPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else { throw NSError(domain: "ColmapRunner", code: Int(result.exitCode)) }
    }

    public func runMatcherExhaustive(
        colmapPath: URL,
        database: URL,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) throws {
        let args = ["exhaustive_matcher", "--database_path", database.path]
        let result = try runner.run(colmapPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else { throw NSError(domain: "ColmapRunner", code: Int(result.exitCode)) }
    }

    public func runMapper(
        colmapPath: URL,
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
        let result = try runner.run(colmapPath.path, args, onStdout: { onLog($0, false) }, onStderr: { onLog($0, true) })
        guard result.exitCode == 0 else { throw NSError(domain: "ColmapRunner", code: Int(result.exitCode)) }
    }

    public func runModelAnalyzer(
        colmapPath: URL,
        modelPath: URL
    ) throws -> String {
        let args = ["model_analyzer", "--path", modelPath.path]
        let result = try runner.run(colmapPath.path, args)
        guard result.exitCode == 0 else { throw NSError(domain: "ColmapRunner", code: Int(result.exitCode)) }
        return result.stdout
    }
}
