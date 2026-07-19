#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ResolvedRunPlanCameraPolicyTests: XCTestCase {
    func testRejectsIncompatibleDA3CameraPolicies() throws {
        let hardware = HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        )
        let input = InputSpec.video(files: ["/tmp/clip.mov"])
        let colmapPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(lensProjection: .perspective),
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        let da3Plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(lensProjection: .perspective),
            input: input,
            hardware: hardware,
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )

        XCTAssertNoThrow(try colmapPlan.validate())
        XCTAssertNoThrow(try da3Plan.validate())

        var fisheyeDA3 = da3Plan
        fisheyeDA3.lensProjection = .fisheye
        fisheyeDA3.cameraInitializationRecipe = .resolve(
            lensProjection: fisheyeDA3.lensProjection,
            cameraGrouping: fisheyeDA3.cameraGrouping
        )
        XCTAssertThrowsError(try fisheyeDA3.validate()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .incompatibleCameraPolicy
            )
        }

        var mixedCameraDA3 = da3Plan
        mixedCameraDA3.cameraGrouping = .mixedCamerasOrLenses
        mixedCameraDA3.cameraInitializationRecipe = .resolve(
            lensProjection: mixedCameraDA3.lensProjection,
            cameraGrouping: mixedCameraDA3.cameraGrouping
        )
        XCTAssertThrowsError(try mixedCameraDA3.validate()) { error in
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .incompatibleCameraPolicy
            )
        }
    }
}
#endif
