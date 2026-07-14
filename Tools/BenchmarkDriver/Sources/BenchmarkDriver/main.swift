import EasySplatBenchmarkDriverCore
import Foundation

private func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(status)
}

let arguments = CommandLine.arguments
guard arguments.count == 8,
      arguments[1] == "render",
      arguments[2] == "--job",
      arguments[4] == "--artifact-root",
      arguments[6] == "--output" else {
    fail(
        "usage: EasySplatBenchmarkDriver render --job <job.json> "
            + "--artifact-root <directory> --output <rendering-manifest.json>",
        status: 64
    )
}

do {
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
} catch {
    fail("EasySplat benchmark rendering failed: \(error.localizedDescription)", status: 1)
}
