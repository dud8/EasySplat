import EasySplatBenchmarkDriverCore
import Foundation

private func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(status)
}

let arguments = CommandLine.arguments

do {
    if arguments.count == 8,
       arguments[1] == "render",
       arguments[2] == "--job",
       arguments[4] == "--artifact-root",
       arguments[6] == "--output" {
        let jobURL = URL(fileURLWithPath: arguments[3])
        let artifactRoot = URL(fileURLWithPath: arguments[5], isDirectory: true)
        let outputURL = URL(fileURLWithPath: arguments[7])
        let data = try Data(contentsOf: jobURL, options: [.mappedIfSafe])
        let job = try JSONDecoder().decode(BenchmarkRenderJob.self, from: data)
        let renderer = try MetalOffscreenRenderer()
        let driver = BenchmarkRenderDriver(renderer: renderer)
        guard let executableURL = Bundle.main.executableURL else {
            throw BenchmarkDriverError.invalidJob("The renderer executable path is unavailable.")
        }
        try driver.execute(
            job: job,
            artifactRoot: artifactRoot,
            manifestURL: outputURL,
            rendererExecutableURL: executableURL
        )
    } else if arguments.count == 16,
              arguments[1] == "extract-orientation",
              arguments[2] == "--geometry-manifest",
              arguments[4] == "--candidate-images",
              arguments[6] == "--ground-truth-poses",
              arguments[8] == "--ground-truth-poses-sha256",
              arguments[10] == "--orientation-label",
              arguments[12] == "--orientation-label-sha256",
              arguments[14] == "--output" {
        let outputURL = URL(fileURLWithPath: arguments[15])
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw BenchmarkDriverError.invalidJob(
                "The orientation evidence output already exists."
            )
        }
        let evidence = try OrientationEvidenceExtractor.extract(
            geometryManifestURL: URL(fileURLWithPath: arguments[3]),
            candidateImagesURL: URL(fileURLWithPath: arguments[5]),
            groundTruthPosesURL: URL(fileURLWithPath: arguments[7]),
            expectedGroundTruthPosesSHA256: arguments[9],
            orientationLabelURL: URL(fileURLWithPath: arguments[11]),
            expectedOrientationLabelSHA256: arguments[13]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(evidence) + Data("\n".utf8)).write(
            to: outputURL,
            options: [.atomic]
        )
    } else {
        fail(
            "usage: EasySplatBenchmarkDriver render --job <job.json> "
                + "--artifact-root <directory> --output <rendering-manifest.json>\n"
                + "   or: EasySplatBenchmarkDriver extract-orientation "
                + "--geometry-manifest <geometry_manifest.json> "
                + "--candidate-images <images.txt> "
                + "--ground-truth-poses <ground-truth-poses.json> "
                + "--ground-truth-poses-sha256 <sha256:...> "
                + "--orientation-label <orientation-label.json> "
                + "--orientation-label-sha256 <sha256:...> --output <orientation-metrics.json>",
            status: 64
        )
    }
} catch {
    fail("EasySplat benchmark driver failed: \(error.localizedDescription)", status: 1)
}
