import Foundation
import XCTest
@testable import EasySplatCore

final class NerfstudioDatasetImporterTests: XCTestCase {
    private func makeJSON(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private var identityMatrix: [[Double]] {
        [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    }

    func testConvertsGlobalIntrinsicsAndSortsFramesByPath() throws {
        let json = makeJSON([
            "camera_model": "OPENCV",
            "fl_x": 1000.0, "fl_y": 990.0, "cx": 640.0, "cy": 360.0,
            "w": 1280, "h": 720,
            "k1": 0.01, "k2": -0.002, "p1": 0.0001, "p2": -0.0001,
            "frames": [
                ["file_path": "images/frame_00002.jpg", "transform_matrix": identityMatrix],
                ["file_path": "./images/frame_00001.jpg", "transform_matrix": identityMatrix],
            ],
        ])
        let plan = try NerfstudioDatasetImporter.plan(fromTransformsJSON: json)

        XCTAssertEqual(plan.kind, .nerfstudio)
        XCTAssertEqual(plan.route, .seedTriangulate)
        XCTAssertEqual(plan.images.map(\.declaredPath), ["images/frame_00001.jpg", "images/frame_00002.jpg"])
        XCTAssertEqual(plan.model.images.map(\.id), [1, 2])
        XCTAssertEqual(plan.model.images.map(\.name), ["images/frame_00001.jpg", "images/frame_00002.jpg"])
        // Identical intrinsics collapse to one camera.
        XCTAssertEqual(plan.model.cameras.count, 1)
        let camera = try XCTUnwrap(plan.model.cameras.first)
        XCTAssertEqual(camera.model, "OPENCV")
        XCTAssertEqual(camera.width, 1280)
        XCTAssertEqual(camera.height, 720)
        XCTAssertEqual(camera.parameters, [1000, 990, 640, 360, 0.01, -0.002, 0.0001, -0.0001])
        // Identity camera-to-world in OpenGL convention is the X-flip pose.
        let pose = try XCTUnwrap(plan.model.images.first?.pose)
        XCTAssertEqual(pose.qx, 1, accuracy: 1e-12)
        XCTAssertTrue(plan.model.points.isEmpty)
    }

    func testPerFrameIntrinsicsProduceSeparateCameras() throws {
        let json = makeJSON([
            "fl_x": 500.0, "fl_y": 500.0, "cx": 320.0, "cy": 240.0, "w": 640, "h": 480,
            "frames": [
                ["file_path": "a.jpg", "transform_matrix": identityMatrix],
                ["file_path": "b.jpg", "transform_matrix": identityMatrix, "fl_x": 510.0],
            ],
        ])
        let plan = try NerfstudioDatasetImporter.plan(fromTransformsJSON: json)
        XCTAssertEqual(plan.model.cameras.count, 2)
        // No declared model and zero distortion infers PINHOLE.
        XCTAssertEqual(Set(plan.model.cameras.map(\.model)), ["PINHOLE"])
        XCTAssertEqual(plan.model.images.map(\.cameraID), [1, 2])
    }

    func testInfersOpencvWhenDistortionPresent() throws {
        let json = makeJSON([
            "fl_x": 500.0, "fl_y": 500.0, "cx": 320.0, "cy": 240.0, "w": 640, "h": 480,
            "k1": 0.05,
            "frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]],
        ])
        let plan = try NerfstudioDatasetImporter.plan(fromTransformsJSON: json)
        XCTAssertEqual(plan.model.cameras.first?.model, "OPENCV")
        XCTAssertEqual(plan.model.cameras.first?.parameters, [500, 500, 320, 240, 0.05, 0, 0, 0])
    }

    func testFisheyeModelCarriesRadialParameters() throws {
        let json = makeJSON([
            "camera_model": "OPENCV_FISHEYE",
            "fl_x": 500.0, "fl_y": 500.0, "cx": 320.0, "cy": 240.0, "w": 640, "h": 480,
            "k1": 0.1, "k2": 0.01, "k3": 0.001, "k4": 0.0001,
            "frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]],
        ])
        let plan = try NerfstudioDatasetImporter.plan(fromTransformsJSON: json)
        XCTAssertEqual(plan.model.cameras.first?.model, "OPENCV_FISHEYE")
        XCTAssertEqual(plan.model.cameras.first?.parameters, [500, 500, 320, 240, 0.1, 0.01, 0.001, 0.0001])
    }

    func testAppliedTransformSurfacesAsNoteOnly() throws {
        let json = makeJSON([
            "fl_x": 500.0, "fl_y": 500.0, "cx": 320.0, "cy": 240.0, "w": 640, "h": 480,
            "applied_transform": [[0, 1, 0, 0], [1, 0, 0, 0], [0, 0, -1, 0]],
            "frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]],
        ])
        let plan = try NerfstudioDatasetImporter.plan(fromTransformsJSON: json)
        XCTAssertTrue(plan.notes.contains { $0.contains("applied_transform") })
        // Poses are taken from the file's frame untouched.
        XCTAssertEqual(plan.model.images.first?.pose.qx ?? 0, 1, accuracy: 1e-12)
    }

    func testRejections() {
        func expectError(_ object: [String: Any], _ expected: NerfstudioDatasetImporter.ImportError, line: UInt = #line) {
            XCTAssertThrowsError(
                try NerfstudioDatasetImporter.plan(fromTransformsJSON: makeJSON(object)), line: line
            ) { error in
                XCTAssertEqual(error as? NerfstudioDatasetImporter.ImportError, expected, line: line)
            }
        }

        expectError(["frames": []], .noFrames)
        expectError(
            ["frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]]],
            .missingIntrinsics(frame: "a.jpg")
        )
        expectError(
            [
                "camera_model": "EQUIRECTANGULAR",
                "fl_x": 1.0, "fl_y": 1.0, "cx": 1.0, "cy": 1.0, "w": 2, "h": 2,
                "frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]],
            ],
            .unsupportedCameraModel("EQUIRECTANGULAR")
        )
        expectError(
            [
                "camera_model": "PINHOLE",
                "fl_x": 1.0, "fl_y": 1.0, "cx": 1.0, "cy": 1.0, "w": 2, "h": 2, "k1": 0.5,
                "frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]],
            ],
            .inconsistentDistortion(frame: "a.jpg", model: "PINHOLE")
        )
        expectError(
            [
                "fl_x": 1.0, "fl_y": 1.0, "cx": 1.0, "cy": 1.0, "w": 2, "h": 2,
                "frames": [
                    ["file_path": "a.jpg", "transform_matrix": identityMatrix],
                    ["file_path": "./a.jpg", "transform_matrix": identityMatrix],
                ],
            ],
            .duplicateFramePath("a.jpg")
        )
        expectError(
            [
                "fl_x": 1.0, "fl_y": 1.0, "cx": 1.0, "cy": 1.0, "w": 2, "h": 2,
                "frames": [["file_path": "../escape.jpg", "transform_matrix": identityMatrix]],
            ],
            .invalidFramePath("../escape.jpg")
        )
        expectError(
            [
                "fl_x": 1.0, "fl_y": 1.0, "cx": 1.0, "cy": 1.0, "w": 2, "h": 0,
                "frames": [["file_path": "a.jpg", "transform_matrix": identityMatrix]],
            ],
            .invalidDimensions(frame: "a.jpg")
        )
        expectError(
            [
                "fl_x": 1.0, "fl_y": 1.0, "cx": 1.0, "cy": 1.0, "w": 2, "h": 2,
                "frames": [[
                    "file_path": "a.jpg",
                    "transform_matrix": [[-1.0, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
                ]],
            ],
            .invalidPose(frame: "a.jpg", underlying: .mirroredRotation)
        )
        XCTAssertThrowsError(
            try NerfstudioDatasetImporter.plan(fromTransformsJSON: Data("not json".utf8))
        ) { error in
            XCTAssertEqual(error as? NerfstudioDatasetImporter.ImportError, .unreadableJSON)
        }
    }
}
