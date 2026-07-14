#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class ColmapRunnerTests: XCTestCase {
    func testMapperReceivesBoundedGlobalBundleAdjustmentPolicy() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_max_num_iterations", in: args),
                        "75"
                    )
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: args), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: args), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_max_refinements", in: args), "5")
                    XCTAssertEqual(self.value(for: "--Mapper.random_seed", in: args), "42")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_refine_focal_length", in: args), "1")
                }
            )
        ])

        try await ColmapRunner(runner: runner).runMapper(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            outputPath: URL(fileURLWithPath: "/tmp/sparse"),
            options: ColmapOptions(
                useGPU: false,
                extractThreads: 1,
                matchThreads: 1
            ),
            mapperOptions: try ColmapMapperOptions(
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true
            ),
            onLog: { _, _ in }
        )
    }

    func testMapperOptionsRejectInvalidBundleAdjustmentPolicy() {
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1,
            globalPointsRatio: 1.4,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .invalidRatio("Global frame ratio")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: .infinity,
            globalPointsRatio: 1.4,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        ))
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: .nan,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .invalidRatio("Global point ratio")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            globalMaxRefinements: 0,
            globalMaxNumIterations: 75,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Global refinement limit")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 0,
            randomSeed: 42,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .nonPositiveValue("Global iteration limit")
            )
        }
        XCTAssertThrowsError(try ColmapMapperOptions(
            globalFramesRatio: 1.4,
            globalPointsRatio: 1.4,
            globalMaxRefinements: 5,
            globalMaxNumIterations: 75,
            randomSeed: UInt64(Int32.max) + 1,
            refineFocalLength: true
        )) { error in
            XCTAssertEqual(
                error as? ColmapMapperOptionsValidationError,
                .randomSeedOutOfRange
            )
        }
    }

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
                matchThreads: 1
            ),
            onLog: { _, _ in }
        )
    }

    func testMatchesImporterUsesFaissByDefault() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
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
                matchThreads: 1
            ),
            onLog: { _, _ in }
        )
    }

    func testLocalVocabularyRetrieverUsesPinnedOfflineConfiguration() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--database_path", in: args), "/tmp/database.db")
                    XCTAssertEqual(self.value(for: "--output_pair_list_path", in: args), "/tmp/retrieval.txt")
                    XCTAssertEqual(self.value(for: "--query_image_list_path", in: args), "/tmp/queries.txt")
                    XCTAssertEqual(self.value(for: "--excluded_pair_list_path", in: args), "/tmp/excluded.txt")
                    XCTAssertEqual(self.value(for: "--num_images", in: args), "40")
                    XCTAssertEqual(self.value(for: "--returned_neighbor_count", in: args), "16")
                    XCTAssertEqual(self.value(for: "--minimum_frame_separation", in: args), "25")
                    XCTAssertEqual(self.value(for: "--num_visual_words", in: args), "512")
                    XCTAssertEqual(self.value(for: "--max_features_per_image", in: args), "512")
                    XCTAssertEqual(self.value(for: "--max_training_descriptors", in: args), "65536")
                    XCTAssertEqual(self.value(for: "--num_iterations", in: args), "10")
                    XCTAssertEqual(self.value(for: "--num_rounds", in: args), "1")
                    XCTAssertEqual(self.value(for: "--num_checks", in: args), "64")
                    XCTAssertEqual(self.value(for: "--num_threads", in: args), "8")
                }
            )
        ])

        try await ColmapRunner(runner: runner).runLocalVocabularyRetriever(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            database: URL(fileURLWithPath: "/tmp/database.db"),
            outputPairListPath: URL(fileURLWithPath: "/tmp/retrieval.txt"),
            queryImageListPath: URL(fileURLWithPath: "/tmp/queries.txt"),
            excludedPairListPath: URL(fileURLWithPath: "/tmp/excluded.txt"),
            options: try ColmapVocabularyRetrievalOptions(
                candidateCount: 40,
                returnedNeighborCount: 16,
                minimumFrameSeparation: 25,
                threadCount: 8
            ),
            onLog: { _, _ in }
        )
    }

    func testLocalVocabularyRetrieverRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 8,
            returnedNeighborCount: 9,
            minimumFrameSeparation: 0,
            threadCount: 1
        )) { error in
            XCTAssertEqual(
                error as? ColmapVocabularyRetrievalOptionsValidationError,
                .neighborCountExceedsCandidateCount
            )
        }
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: -1,
            threadCount: 1
        ))
        XCTAssertThrowsError(try ColmapVocabularyRetrievalOptions(
            candidateCount: 20,
            returnedNeighborCount: 8,
            minimumFrameSeparation: 0,
            threadCount: 0
        ))
    }

    func testExactRecoveryUsesBruteForceMatching() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
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
                descriptorMatcher: .exact
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
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1),
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
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1),
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
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1),
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
            options: ColmapOptions(useGPU: false, extractThreads: 1, matchThreads: 1),
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

    func testImageUndistorterProducesBoundedColmapWorkspace() async throws {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/mock/colmap",
                argsPrefix: ["image_undistorter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--image_path", in: args), "/tmp/images")
                    XCTAssertEqual(self.value(for: "--input_path", in: args), "/tmp/sparse")
                    XCTAssertEqual(self.value(for: "--output_path", in: args), "/tmp/undistorted")
                    XCTAssertEqual(self.value(for: "--output_type", in: args), "COLMAP")
                    XCTAssertEqual(self.value(for: "--copy_policy", in: args), "COPY")
                    XCTAssertEqual(self.value(for: "--max_image_size", in: args), "2048")
                }
            )
        ])

        try await ColmapRunner(runner: runner).runImageUndistorter(
            colmapPath: URL(fileURLWithPath: "/mock/colmap"),
            imagePath: URL(fileURLWithPath: "/tmp/images"),
            inputPath: URL(fileURLWithPath: "/tmp/sparse"),
            outputPath: URL(fileURLWithPath: "/tmp/undistorted"),
            maxImageSize: 2_048,
            environment: [:],
            onLog: { _, _ in }
        )
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif
