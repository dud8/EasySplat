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

    func testEnvironmentLoaderAcceptsOnlyTheTypedDevelopmentSurface() {
        let overrides = DevelopmentOverrides.fromEnvironment([
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/tmp/easysplat-toolchain",
            "EASYSPLAT_CANDIDATE_ROUTE": "colmap",
            "EASYSPLAT_STOP_AFTER_STAGE": "sfmMapping",
            "EASYSPLAT_SKIP_TRAINING": "yes",
            "EASYSPLAT_BENCHMARK_SEED": "17",
            "UNRELATED_SETTING": "ignored"
        ])

        XCTAssertEqual(overrides.localToolchainRoot?.path, "/tmp/easysplat-toolchain")
        XCTAssertEqual(overrides.candidateRoute, .colmap)
        XCTAssertEqual(overrides.stopAfterStage, .sfmMapping)
        XCTAssertTrue(overrides.skipTraining)
        XCTAssertEqual(overrides.benchmarkSeed, 17)
    }
}
