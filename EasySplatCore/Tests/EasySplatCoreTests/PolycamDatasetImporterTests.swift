import Foundation
import XCTest
@testable import EasySplatCore

final class PolycamDatasetImporterTests: XCTestCase {
    private func makeCamera(fx: Double = 800, blurScore: Double? = nil) -> PolycamDatasetImporter.KeyframeCamera {
        PolycamDatasetImporter.KeyframeCamera(
            fx: fx, fy: 800, cx: 512, cy: 384,
            width: 1024, height: 768,
            blurScore: blurScore,
            transformRowMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
        )
    }

    func testBuildsPinholeModelSortedByStem() throws {
        let plan = try PolycamDatasetImporter.plan(
            fromKeyframes: [
                .init(stem: "b", imagePath: "keyframes/images/b.jpg", camera: makeCamera()),
                .init(stem: "a", imagePath: "keyframes/images/a.jpg", camera: makeCamera()),
            ],
            usedCorrectedCameras: false
        )
        XCTAssertEqual(plan.kind, .polycam)
        XCTAssertEqual(plan.route, .seedTriangulate)
        XCTAssertEqual(plan.images.map(\.entryID), ["a", "b"])
        XCTAssertEqual(plan.model.images.map(\.name), ["keyframes/images/a.jpg", "keyframes/images/b.jpg"])
        XCTAssertEqual(plan.model.cameras.count, 1)
        XCTAssertEqual(plan.model.cameras.first?.model, "PINHOLE")
        XCTAssertEqual(plan.model.cameras.first?.parameters, [800, 800, 512, 384])
        XCTAssertTrue(plan.model.points.isEmpty)
    }

    func testDistinctIntrinsicsGetDistinctCameras() throws {
        let plan = try PolycamDatasetImporter.plan(
            fromKeyframes: [
                .init(stem: "a", imagePath: "keyframes/images/a.jpg", camera: makeCamera(fx: 800)),
                .init(stem: "b", imagePath: "keyframes/images/b.jpg", camera: makeCamera(fx: 810)),
            ],
            usedCorrectedCameras: false
        )
        XCTAssertEqual(plan.model.cameras.count, 2)
    }

    func testBlurryKeyframesAreKeptAndNoted() throws {
        let plan = try PolycamDatasetImporter.plan(
            fromKeyframes: [
                .init(stem: "a", imagePath: "keyframes/images/a.jpg", camera: makeCamera(blurScore: 5)),
                .init(stem: "b", imagePath: "keyframes/images/b.jpg", camera: makeCamera(blurScore: 250)),
            ],
            usedCorrectedCameras: true
        )
        XCTAssertEqual(plan.images.count, 2)
        XCTAssertTrue(plan.notes.contains { $0.contains("1 of 2 keyframes look blurry") })
        XCTAssertTrue(plan.notes.contains { $0.contains("corrected cameras") })
    }

    func testDecodesPolycamCameraJSON() throws {
        let json = """
        {"fx": 763.2, "fy": 762.9, "cx": 512.1, "cy": 383.7,
         "width": 1024, "height": 768, "blur_score": 132.5,
         "t_00": 1, "t_01": 0, "t_02": 0, "t_03": 0.5,
         "t_10": 0, "t_11": 1, "t_12": 0, "t_13": -0.25,
         "t_20": 0, "t_21": 0, "t_22": 1, "t_23": 2.0,
         "manual_keyframe": false}
        """
        let camera = try JSONDecoder().decode(
            PolycamDatasetImporter.KeyframeCamera.self, from: Data(json.utf8)
        )
        XCTAssertEqual(camera.fx, 763.2)
        XCTAssertEqual(camera.blurScore, 132.5)
        XCTAssertEqual(camera.transformRowMajor, [1, 0, 0, 0.5, 0, 1, 0, -0.25, 0, 0, 1, 2.0])
    }

    func testRejections() {
        XCTAssertThrowsError(
            try PolycamDatasetImporter.plan(fromKeyframes: [], usedCorrectedCameras: false)
        ) { error in
            XCTAssertEqual(error as? PolycamDatasetImporter.ImportError, .noKeyframes)
        }
        XCTAssertThrowsError(
            try PolycamDatasetImporter.plan(
                fromKeyframes: [
                    .init(stem: "a", imagePath: "x/a.jpg", camera: makeCamera()),
                    .init(stem: "a", imagePath: "x/a.jpg", camera: makeCamera()),
                ],
                usedCorrectedCameras: false
            )
        ) { error in
            XCTAssertEqual(error as? PolycamDatasetImporter.ImportError, .duplicateStem("a"))
        }
        XCTAssertThrowsError(
            try PolycamDatasetImporter.plan(
                fromKeyframes: [.init(stem: "a", imagePath: "/etc/a.jpg", camera: makeCamera())],
                usedCorrectedCameras: false
            )
        ) { error in
            XCTAssertEqual(error as? PolycamDatasetImporter.ImportError, .invalidImagePath("/etc/a.jpg"))
        }
        var zeroHeight = makeCamera()
        zeroHeight.height = 0
        XCTAssertThrowsError(
            try PolycamDatasetImporter.plan(
                fromKeyframes: [.init(stem: "a", imagePath: "x/a.jpg", camera: zeroHeight)],
                usedCorrectedCameras: false
            )
        ) { error in
            XCTAssertEqual(error as? PolycamDatasetImporter.ImportError, .invalidDimensions(stem: "a"))
        }
        var mirrored = makeCamera()
        mirrored.transformRowMajor = [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
        XCTAssertThrowsError(
            try PolycamDatasetImporter.plan(
                fromKeyframes: [.init(stem: "a", imagePath: "x/a.jpg", camera: mirrored)],
                usedCorrectedCameras: false
            )
        ) { error in
            XCTAssertEqual(
                error as? PolycamDatasetImporter.ImportError,
                .invalidPose(stem: "a", underlying: .mirroredRotation)
            )
        }
    }
}
