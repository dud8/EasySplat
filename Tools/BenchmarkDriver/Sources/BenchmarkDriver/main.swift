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
    } else if arguments.count == 20,
              arguments[1] == "extract-orientation",
              arguments[2] == "--geometry-manifest",
              arguments[4] == "--geometry-manifest-sha256",
              arguments[6] == "--candidate-images",
              arguments[8] == "--candidate-images-sha256",
              arguments[10] == "--ground-truth-poses",
              arguments[12] == "--ground-truth-poses-sha256",
              arguments[14] == "--orientation-label",
              arguments[16] == "--orientation-label-sha256",
              arguments[18] == "--output" {
        let outputURL = URL(fileURLWithPath: arguments[19])
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw BenchmarkDriverError.invalidJob(
                "The orientation evidence output already exists."
            )
        }
        let evidence = try OrientationEvidenceExtractor.extract(
            geometryManifestURL: URL(fileURLWithPath: arguments[3]),
            expectedGeometryManifestSHA256: arguments[5],
            candidateImagesURL: URL(fileURLWithPath: arguments[7]),
            expectedCandidateImagesSHA256: arguments[9],
            groundTruthPosesURL: URL(fileURLWithPath: arguments[11]),
            expectedGroundTruthPosesSHA256: arguments[13],
            orientationLabelURL: URL(fileURLWithPath: arguments[15]),
            expectedOrientationLabelSHA256: arguments[17]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(evidence) + Data("\n".utf8)).write(
            to: outputURL,
            options: [.atomic]
        )
    } else if arguments.count == 10,
              arguments[1] == "monitor-host-state",
              arguments[2] == "--sample-interval",
              arguments[4] == "--max-samples",
              arguments[6] == "--ready-fd",
              arguments[8] == "--stop-fd",
              let sampleInterval = TimeInterval(arguments[3]),
              let maximumSamples = Int(arguments[5]),
              let readyFileDescriptor = Int32(arguments[7]),
              let stopFileDescriptor = Int32(arguments[9]) {
        let receipt = try HostStateMonitor.capture(
            sampleIntervalSeconds: sampleInterval,
            readyFileDescriptor: readyFileDescriptor,
            stopFileDescriptor: stopFileDescriptor,
            maximumSampleCount: maximumSamples
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(receipt) + Data("\n".utf8))
    } else {
        fail(
            "usage: EasySplatBenchmarkDriver render --job <job.json> "
                + "--artifact-root <directory> --output <rendering-manifest.json>\n"
                + "   or: EasySplatBenchmarkDriver extract-orientation "
                + "--geometry-manifest <geometry_manifest.json> "
                + "--geometry-manifest-sha256 <sha256:...> "
                + "--candidate-images <images.txt> "
                + "--candidate-images-sha256 <sha256:...> "
                + "--ground-truth-poses <ground-truth-poses.json> "
                + "--ground-truth-poses-sha256 <sha256:...> "
                + "--orientation-label <orientation-label.json> "
                + "--orientation-label-sha256 <sha256:...> --output <orientation-metrics.json>\n"
                + "   or: EasySplatBenchmarkDriver monitor-host-state "
                + "--sample-interval <seconds> --max-samples <count> "
                + "--ready-fd <descriptor> --stop-fd <descriptor>",
            status: 64
        )
    }
} catch {
    fail("EasySplat benchmark driver failed: \(error.localizedDescription)", status: 1)
}
