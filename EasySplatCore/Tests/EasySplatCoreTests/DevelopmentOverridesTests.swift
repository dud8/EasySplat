import Foundation
import XCTest
@testable import EasySplatCore

final class DevelopmentOverridesTests: XCTestCase {
    func testDefaultsDoNotChangeProductPolicy() {
        XCTAssertEqual(DevelopmentOverrides(), .none)
        XCTAssertNil(DevelopmentOverrides.none.localToolchainRoot)
        XCTAssertNil(DevelopmentOverrides.none.candidateRoute)
        XCTAssertNil(DevelopmentOverrides.none.stopAfterStage)
        XCTAssertFalse(DevelopmentOverrides.none.skipTraining)
        XCTAssertNil(DevelopmentOverrides.none.benchmarkSeed)
    }

    func testInjectedCandidateRouteDoesNotReadLegacyBackendEnvironment() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = PipelineRunner.PipelineConfig(
            toolchain: TestToolchains.toolchainPaths(root: root),
            preset: PresetSpec(mode: .object, quality: .standard),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        let runner = PipelineRunner(projectURL: root, config: config)

        await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "colmap"]) {
            XCTAssertEqual(runner.test_sfmBackendPolicy(), .da3)
            XCTAssertEqual(runner.test_sfmBackendFallbackOrder(), [.da3])
        }
    }

    func testEnvironmentLoaderAcceptsOnlyTheTypedDevelopmentSurface() {
        let overrides = DevelopmentOverrides.fromEnvironment([
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/tmp/easysplat-toolchain",
            "EASYSPLAT_CANDIDATE_ROUTE": "colmap",
            "EASYSPLAT_STOP_AFTER_STAGE": "sfmMapping",
            "EASYSPLAT_SKIP_TRAINING": "yes",
            "EASYSPLAT_BENCHMARK_SEED": "17",
            "EASYSPLAT_SFM_BACKEND": "da3",
            "EASYSPLAT_DA3_PROCESS_RES": "9999"
        ])

        XCTAssertEqual(overrides.localToolchainRoot?.path, "/tmp/easysplat-toolchain")
        XCTAssertEqual(overrides.candidateRoute, .colmap)
        XCTAssertEqual(overrides.stopAfterStage, .sfmMapping)
        XCTAssertTrue(overrides.skipTraining)
        XCTAssertEqual(overrides.benchmarkSeed, 17)
    }
}
