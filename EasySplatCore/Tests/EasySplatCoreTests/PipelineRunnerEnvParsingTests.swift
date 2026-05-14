import XCTest
@testable import EasySplatCore

final class PipelineRunnerEnvParsingTests: XCTestCase {
    func testVggtPreferencesIgnoreInvalidNumbers() async {
        let runner = makeRunner()
        await withEnvironmentAsync([
            "EASYSPLAT_VGGT_VIS_THRESH": "nope",
            "EASYSPLAT_VGGT_QUERY_FRAMES": "-1",
            "EASYSPLAT_VGGT_MAX_QUERY_PTS": "0",
            "EASYSPLAT_VGGT_MAX_REPROJ_ERROR": "0",
            "EASYSPLAT_FASTVGGT_BA_MAX_ITERS": "nope"
        ]) {
            XCTAssertEqual(runner.test_vggtVisibilityThresholdPreference(), 0.2)
            XCTAssertEqual(runner.test_vggtQueryFrameCountPreference(), 8)
            XCTAssertEqual(runner.test_vggtMaxQueryPointsPreference(), 4096)
            XCTAssertEqual(runner.test_vggtMaxReprojectionErrorPreference(), 8.0)
            XCTAssertEqual(runner.test_fastvggtBaMaxIterationsPreference(), 50)
        }
    }

    func testBoolEnvValuesTrimAndLowercase() async {
        let runner = makeRunner()
        await withEnvironmentAsync([
            "EASYSPLAT_VGGT_USE_BA": "  YeS  ",
            "EASYSPLAT_VGGT_FINE_TRACKING": " NO ",
            "EASYSPLAT_FASTVGGT_USE_BA": " no ",
            "EASYSPLAT_FASTVGGT_REQUIRE_REFINED_MODEL": " 1 ",
            "EASYSPLAT_FASTVGGT_BA_REFINE_FOCAL": " yes ",
            "EASYSPLAT_FASTVGGT_BA_REFINE_PP": " tRuE ",
            "EASYSPLAT_FASTVGGT_BA_REFINE_EXTRA": " nO ",
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": " YES ",
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": " 1 ",
            "EASYSPLAT_FASTVGGT_GPU_ONLY": " true "
        ]) {
            XCTAssertTrue(runner.test_vggtUseBundleAdjustmentPreference())
            XCTAssertFalse(runner.test_vggtFineTrackingPreference())
            XCTAssertFalse(runner.test_fastvggtUseBundleAdjustmentPreference())
            XCTAssertTrue(runner.test_fastvggtRequireRefinedModelPreference())
            XCTAssertTrue(runner.test_fastvggtBaRefineFocalPreference())
            XCTAssertTrue(runner.test_fastvggtBaRefinePrincipalPointPreference())
            XCTAssertFalse(runner.test_fastvggtBaRefineExtraParamsPreference())
            XCTAssertTrue(runner.test_fastvggtFullCoveragePreference())
            XCTAssertTrue(runner.test_fastvggtNoFallbackPreference())
            XCTAssertTrue(runner.test_fastvggtGpuOnlyPreference())
        }
    }

    func testFastVggtCoveragePreferenceDefaultsAndValidation() async {
        let runner = makeRunner()
        await withEnvironmentAsync([
            "EASYSPLAT_FASTVGGT_POSTPROCESS": "invalid",
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": "weird",
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": "50",
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": "1.5",
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": "0",
            "EASYSPLAT_FASTVGGT_FULL_COVERAGE": nil,
            "EASYSPLAT_FASTVGGT_NO_FALLBACK": nil,
            "EASYSPLAT_FASTVGGT_GPU_ONLY": nil
        ]) {
            XCTAssertEqual(runner.test_fastvggtPostprocessPreference(), "gpu_ba_lite")
            XCTAssertEqual(runner.test_fastvggtCoveragePlannerPreference(), "auto")
            XCTAssertEqual(runner.test_fastvggtCoverageWindowTokensPreference(), 25_000)
            XCTAssertEqual(runner.test_fastvggtCoverageOverlapPreference(), 0.35, accuracy: 0.0001)
            XCTAssertEqual(runner.test_fastvggtCoverageMaxRoundsPreference(), 4)
            XCTAssertFalse(runner.test_fastvggtFullCoveragePreference())
            XCTAssertFalse(runner.test_fastvggtNoFallbackPreference())
            XCTAssertFalse(runner.test_fastvggtGpuOnlyPreference())
        }

        await withEnvironmentAsync([
            "EASYSPLAT_FASTVGGT_POSTPROCESS": "NoNe",
            "EASYSPLAT_FASTVGGT_COVERAGE_PLANNER": " appearance ",
            "EASYSPLAT_FASTVGGT_COVERAGE_WINDOW_TOKENS": "30000",
            "EASYSPLAT_FASTVGGT_COVERAGE_OVERLAP": "0.6",
            "EASYSPLAT_FASTVGGT_COVERAGE_MAX_ROUNDS": "7"
        ]) {
            XCTAssertEqual(runner.test_fastvggtPostprocessPreference(), "none")
            XCTAssertEqual(runner.test_fastvggtCoveragePlannerPreference(), "appearance")
            XCTAssertEqual(runner.test_fastvggtCoverageWindowTokensPreference(), 30_000)
            XCTAssertEqual(runner.test_fastvggtCoverageOverlapPreference(), 0.6, accuracy: 0.0001)
            XCTAssertEqual(runner.test_fastvggtCoverageMaxRoundsPreference(), 7)
        }
    }

    func testColmapGpuOverridePrecedence() async {
        let runner = makeRunner()

        await withEnvironmentAsync([
            "EASYSPLAT_COLMAP_FORCE_CPU": "1",
            "EASYSPLAT_COLMAP_FORCE_GPU": "1"
        ]) {
            XCTAssertEqual(runner.test_colmapGpuOverride(), false)
        }

        await withEnvironmentAsync([
            "EASYSPLAT_COLMAP_FORCE_CPU": nil,
            "EASYSPLAT_COLMAP_FORCE_GPU": nil,
            "EASYSPLAT_COLMAP_USE_GPU": " true "
        ]) {
            XCTAssertEqual(runner.test_colmapGpuOverride(), true)
        }

        await withEnvironmentAsync([
            "EASYSPLAT_COLMAP_FORCE_CPU": nil,
            "EASYSPLAT_COLMAP_FORCE_GPU": nil,
            "EASYSPLAT_COLMAP_USE_GPU": "maybe"
        ]) {
            XCTAssertNil(runner.test_colmapGpuOverride())
        }
    }

    func testColmapSequentialOverlapOverrideClamps() async {
        let runner = makeRunner()

        await withEnvironmentAsync(["EASYSPLAT_COLMAP_SEQUENTIAL_OVERLAP": nil]) {
            XCTAssertNil(runner.test_colmapSequentialOverlapOverride())
        }

        await withEnvironmentAsync(["EASYSPLAT_COLMAP_SEQUENTIAL_OVERLAP": "2"]) {
            XCTAssertEqual(runner.test_colmapSequentialOverlapOverride(), 2)
        }

        await withEnvironmentAsync(["EASYSPLAT_COLMAP_SEQUENTIAL_OVERLAP": "0"]) {
            XCTAssertEqual(runner.test_colmapSequentialOverlapOverride(), 1)
        }

        await withEnvironmentAsync(["EASYSPLAT_COLMAP_SEQUENTIAL_OVERLAP": "99"]) {
            XCTAssertEqual(runner.test_colmapSequentialOverlapOverride(), 30)
        }

        await withEnvironmentAsync(["EASYSPLAT_COLMAP_SEQUENTIAL_OVERLAP": "nope"]) {
            XCTAssertNil(runner.test_colmapSequentialOverlapOverride())
        }
    }

    func testTrainingBackendPreferenceDefaultsAndParsesMsplat() async {
        let runner = makeRunner()

        await withEnvironmentAsync([
            "EASYSPLAT_TRAINER": nil,
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_MSPLAT_BIN": nil
        ]) {
            XCTAssertEqual(runner.test_trainingBackendPreference(), "brush")
        }

        await withEnvironmentAsync([
            "EASYSPLAT_TRAINER": " msplat ",
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_MSPLAT_BIN": nil
        ]) {
            XCTAssertEqual(runner.test_trainingBackendPreference(), "msplat")
        }

        await withEnvironmentAsync([
            "EASYSPLAT_TRAINER": "unknown",
            "EASYSPLAT_SPEED_PROFILE": nil,
            "EASYSPLAT_MSPLAT_BIN": nil
        ]) {
            XCTAssertEqual(runner.test_trainingBackendPreference(), "brush")
        }
    }

    func testFastSpeedProfileUsesMsplatWhenExecutableIsAvailable() async throws {
        let msplat = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try TestFileBuilder.createExecutable(at: msplat)
        defer { try? FileManager.default.removeItem(at: msplat) }
        let runner = makeRunner()

        await withEnvironmentAsync([
            "EASYSPLAT_TRAINER": nil,
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_MSPLAT_BIN": msplat.path
        ]) {
            XCTAssertEqual(runner.test_trainingBackendPreference(), "msplat")
        }
    }

    func testFastSpeedProfileKeepsBrushWhenMsplatIsMissing() async {
        let runner = makeRunner()

        await withEnvironmentAsync([
            "EASYSPLAT_TRAINER": nil,
            "EASYSPLAT_SPEED_PROFILE": "fast",
            "EASYSPLAT_MSPLAT_BIN": "/tmp/easysplat-missing-msplat-\(UUID().uuidString)"
        ]) {
            XCTAssertEqual(runner.test_trainingBackendPreference(), "brush")
        }
    }

    private func makeRunner() -> PipelineRunner {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vggt = VggtToolchain(root: root, sfmTool: root, python: root, models: root)
        let fastvggt = FastVggtToolchain(root: root, sfmTool: root, python: root, models: root)
        let toolchain = ToolchainPaths(root: root, colmap: root, glomap: root, brush: root, vggt: vggt, fastvggt: fastvggt)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: root, config: config)
    }
}
