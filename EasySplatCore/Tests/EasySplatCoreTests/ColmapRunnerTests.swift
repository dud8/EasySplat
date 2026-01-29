#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class ColmapRunnerTests: XCTestCase {
    func testFeatureExtractorPassesMaxNumFeatures() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftExtraction.max_num_features", in: args), "5000")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runFeatureExtractor(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            maxImageSize: 1024,
            cameraModel: "SIMPLE_RADIAL",
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 2,
                matchThreads: 1,
                sequentialOverlap: 10,
                maxNumFeatures: 5000
            ),
            onLog: { _, _ in }
        )
    }

    func testExhaustiveMatcherPassesSafeOptions() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["exhaustive_matcher"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--FeatureMatching.max_num_matches", in: args), "7000")
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                    XCTAssertEqual(self.value(for: "--ExhaustiveMatching.block_size", in: args), "12")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatcherExhaustive(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 1,
                sequentialOverlap: 10,
                maxNumMatches: 7000,
                useBruteForceMatcher: true,
                exhaustiveBlockSize: 12
            ),
            onLog: { _, _ in }
        )
    }

    func testSequentialMatcherPassesMaxMatches() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["sequential_matcher"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--FeatureMatching.max_num_matches", in: args), "9000")
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatcherSequential(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 1,
                sequentialOverlap: 5,
                maxNumMatches: 9000,
                useBruteForceMatcher: true
            ),
            onLog: { _, _ in }
        )
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
