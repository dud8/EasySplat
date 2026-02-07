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
            "EASYSPLAT_FASTVGGT_BA_REFINE_EXTRA": " nO "
        ]) {
            XCTAssertTrue(runner.test_vggtUseBundleAdjustmentPreference())
            XCTAssertFalse(runner.test_vggtFineTrackingPreference())
            XCTAssertFalse(runner.test_fastvggtUseBundleAdjustmentPreference())
            XCTAssertTrue(runner.test_fastvggtRequireRefinedModelPreference())
            XCTAssertTrue(runner.test_fastvggtBaRefineFocalPreference())
            XCTAssertTrue(runner.test_fastvggtBaRefinePrincipalPointPreference())
            XCTAssertFalse(runner.test_fastvggtBaRefineExtraParamsPreference())
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

    private func makeRunner() -> PipelineRunner {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vggt = VggtToolchain(root: root, sfmTool: root, python: root, models: root)
        let fastvggt = FastVggtToolchain(root: root, sfmTool: root, python: root, models: root)
        let toolchain = ToolchainPaths(root: root, colmap: root, glomap: root, brush: root, vggt: vggt, fastvggt: fastvggt)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: root, config: config)
    }
}
