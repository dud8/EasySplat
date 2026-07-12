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
