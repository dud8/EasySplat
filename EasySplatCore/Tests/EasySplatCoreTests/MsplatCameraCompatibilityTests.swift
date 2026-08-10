#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class MsplatCameraCompatibilityTests: XCTestCase {
    func testSupportedColmapCameraModelsTrainDirectly() throws {
        let model = try temporaryCameraModel(
            """
            # Camera list
            1 SIMPLE_PINHOLE 800 600 700 400 300
            2 PINHOLE 800 600 700 705 400 300
            3 SIMPLE_RADIAL 800 600 700 400 300 0
            4 RADIAL 800 600 700 400 300 0 0
            5 OPENCV 800 600 700 705 400 300 0 0 0 0
            """
        )

        XCTAssertFalse(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testFisheyeCameraRequiresUndistortion() throws {
        let model = try temporaryCameraModel(
            "1 OPENCV_FISHEYE 1920 1080 900 900 960 540 0.01 -0.001 0 0\n"
        )

        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testSupportedModelWithDistortionRequiresCorrectedImages() throws {
        let model = try temporaryCameraModel(
            "1 SIMPLE_RADIAL 1920 1080 900 960 540 0.015\n"
        )

        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testSubPixelDistortionSkipsUndistortion() throws {
        // 0.495 px at the worst corner. Undistortion resamples every pixel and
        // measurably softens it, so a correction this far inside the solver's own
        // reprojection residual is not worth paying for.
        let model = try temporaryCameraModel(
            "1 SIMPLE_RADIAL 1920 1080 900 960 540 0.0003\n"
        )

        XCTAssertFalse(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testDistortionJustAboveThresholdRequiresUndistortion() throws {
        // Same camera, 1.65 px. The gate has to trip on the near side too, or it is
        // just an unconditional skip.
        let model = try temporaryCameraModel(
            "1 SIMPLE_RADIAL 1920 1080 900 960 540 0.001\n"
        )

        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testTangentialYComponentCountsTowardDisplacement() throws {
        // Pure decentring, no radial term. Measuring only the x component gives
        // 0.69 px and skips undistortion; the full vector is 1.38 px and must not.
        let model = try temporaryCameraModel(
            "1 OPENCV 1920 1080 900 900 960 540 0 0 0.0006 0\n"
        )

        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testOffCentrePrincipalPointCountsTowardDisplacement() throws {
        // The far corner sits at 2.16 normalised radii from the principal point, not
        // the 1.22 a centred estimate assumes: 1.78 px rather than 0.33 px.
        let model = try temporaryCameraModel(
            "1 SIMPLE_RADIAL 1920 1080 900 200 200 0.0002\n"
        )

        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testInteriorDistortionPeakIsNotMissedByCornerSampling() throws {
        // Opposing radial signs put the peak inside the frame: this camera displaces
        // 0.0000 px at all four corners and 3.07 px around (244, 76). Sampling only the
        // corners reports zero and skips undistortion on a camera needing 3x the
        // threshold.
        let model = try temporaryCameraModel(
            "1 RADIAL 1920 1080 900 960 540 0.01 -0.00667656\n"
        )

        let displacement = MsplatCameraCompatibility.maximumDisplacementPixels(
            model: "RADIAL",
            width: 1920,
            height: 1080,
            parameters: [900, 960, 540, 0.01, -0.00667656]
        )
        XCTAssertGreaterThan(displacement, 3.0)
        XCTAssertLessThan(displacement, 3.2)
        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    func testMixedRigUndistortsWhenAnyCameraNeedsIt() throws {
        // COLMAP undistorts a model as a unit, so one camera over the threshold
        // decides for the rig.
        let model = try temporaryCameraModel(
            """
            1 SIMPLE_RADIAL 1920 1080 900 960 540 0.0003
            2 SIMPLE_RADIAL 1920 1080 900 960 540 0.015
            """
        )

        XCTAssertTrue(try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: model))
    }

    private func temporaryCameraModel(_ cameras: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try cameras.write(
            to: directory.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }
}
#endif
