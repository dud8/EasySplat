import XCTest
@testable import EasySplatCore

final class PipelineRunnerEnvParsingTests: XCTestCase {
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

    private func makeRunner() -> PipelineRunner {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = TestToolchains.toolchainPaths(root: root)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: root, config: config)
    }
}
