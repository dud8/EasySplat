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
                    XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "1")
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

    func testFeatureExtractorAllowsPerImageCameras() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "0")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runFeatureExtractor(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            maxImageSize: 1024,
            cameraModel: "SIMPLE_PINHOLE",
            singleCamera: false,
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 2,
                matchThreads: 1,
                sequentialOverlap: 10
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

    func testMatchesImporterPassesBruteForceFlag() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    // matches_importer runs SIFT matching per pair; on the FLANN-segfaulting
                    // build it must carry the brute-force flag like the other matchers.
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                    XCTAssertEqual(self.value(for: "--match_type", in: args), "pairs")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatchesImporter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 1,
                sequentialOverlap: 5,
                useBruteForceMatcher: true
            ),
            onLog: { _, _ in }
        )
    }

    func testMatchesImporterOmitsBruteForceFlagWhenDisabled() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertFalse(args.contains("--SiftMatching.cpu_brute_force_matcher"),
                                   "The brute-force flag must be absent when it is not requested.")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runMatchesImporter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            matchListPath: URL(fileURLWithPath: "/tmp/pairs.txt"),
            matchType: "pairs",
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 1,
                sequentialOverlap: 5,
                useBruteForceMatcher: false
            ),
            onLog: { _, _ in }
        )
    }

    func testPointTriangulatorUsesSeedAndOutputPaths() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["point_triangulator"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--database_path", in: args), "/tmp/db")
                    XCTAssertEqual(self.value(for: "--image_path", in: args), "/tmp/images")
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/seed")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/sparse")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runPointTriangulator(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            inputPath: URL(fileURLWithPath: "/tmp/seed"),
            outputPath: URL(fileURLWithPath: "/tmp/sparse"),
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1, sequentialOverlap: 10),
            onLog: { _, _ in }
        )
    }

    func testBundleAdjusterPassesRefinementKnobs() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/in")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/out")
                    XCTAssertEqual(self.value(for: "--BundleAdjustmentCeres.max_num_iterations", in: args), "35")
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.refine_focal_length", in: args), "0")
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.refine_principal_point", in: args), "1")
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.refine_extra_params", in: args), "1")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runBundleAdjuster(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1, sequentialOverlap: 10),
            bundleOptions: ColmapBundleAdjustmentOptions(
                maxNumIterations: 35,
                refineFocalLength: false,
                refinePrincipalPoint: true,
                refineExtraParams: true
            ),
            onLog: { _, _ in }
        )
    }

    func testBundleAdjusterCreatesOutputDirectoryWhenMissing() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputPath = temp.appendingPathComponent("in", isDirectory: true)
        let outputPath = temp.appendingPathComponent("missing_out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputPath, withIntermediateDirectories: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: outputPath.path, isDirectory: &isDirectory)
                    XCTAssertTrue(exists)
                    XCTAssertTrue(isDirectory.boolValue)
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runBundleAdjuster(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: inputPath,
            outputPath: outputPath,
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1, sequentialOverlap: 10),
            bundleOptions: ColmapBundleAdjustmentOptions(
                maxNumIterations: 10,
                refineFocalLength: true,
                refinePrincipalPoint: false,
                refineExtraParams: false
            ),
            onLog: { _, _ in }
        )
    }

    func testBundleAdjusterRetriesWithLegacyIterationFlag() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "Failed to parse options - unrecognised option '--BundleAdjustmentCeres.max_num_iterations'."
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--BundleAdjustmentCeres.max_num_iterations", in: args), "20")
                    XCTAssertNil(self.value(for: "--BundleAdjustment.max_num_iterations", in: args))
                }
            ),
            .init(
                path: "/mock/colmap",
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--BundleAdjustment.max_num_iterations", in: args), "20")
                    XCTAssertNil(self.value(for: "--BundleAdjustmentCeres.max_num_iterations", in: args))
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try await colmap.runBundleAdjuster(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1, sequentialOverlap: 10),
            bundleOptions: ColmapBundleAdjustmentOptions(
                maxNumIterations: 20,
                refineFocalLength: true,
                refinePrincipalPoint: false,
                refineExtraParams: false
            ),
            onLog: { _, _ in }
        )
    }

    func testModelConverterUsesTxtOutput() throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/in")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/out")
                    XCTAssertEqual(self.value(for: "--output_type", in: args), "TXT")
                }
            )
        ])

        let colmap = ColmapRunner(runner: runner)
        try colmap.runModelConverter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            inputPath: URL(fileURLWithPath: "/tmp/in"),
            outputPath: URL(fileURLWithPath: "/tmp/out"),
            onLog: { _, _ in }
        )
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
