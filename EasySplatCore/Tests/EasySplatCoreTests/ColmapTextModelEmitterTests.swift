import Foundation
import XCTest
@testable import EasySplatCore

final class ColmapTextModelEmitterTests: XCTestCase {
    func testEmitsDeterministicSortedOutput() throws {
        let pose = DatasetPoseConvention.ColmapPose(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 0, tz: 0)
        let model = ColmapTextModel(
            cameras: [
                ColmapTextCamera(id: 2, model: "PINHOLE", width: 640, height: 480, parameters: [100, 100, 320, 240]),
                ColmapTextCamera(id: 1, model: "SIMPLE_PINHOLE", width: 640, height: 480, parameters: [100, 320, 240]),
            ],
            images: [
                ColmapTextImage(id: 2, pose: pose, cameraID: 2, name: "b.jpg"),
                ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg"),
            ]
        )
        let first = try ColmapTextModelEmitter.emit(model)
        var shuffled = model
        shuffled.cameras.reverse()
        shuffled.images.reverse()
        let second = try ColmapTextModelEmitter.emit(shuffled)
        XCTAssertEqual(first.camerasTxt, second.camerasTxt)
        XCTAssertEqual(first.imagesTxt, second.imagesTxt)
        XCTAssertEqual(first.points3DTxt, second.points3DTxt)

        XCTAssertTrue(first.camerasTxt.contains("1 SIMPLE_PINHOLE 640 480 100.0 320.0 240.0\n"))
        XCTAssertTrue(first.imagesTxt.contains("1 1.0 0.0 0.0 0.0 0.0 0.0 0.0 1 a.jpg\n"))
        // Pose-only images still carry the (empty) observations line.
        XCTAssertTrue(first.imagesTxt.hasSuffix("2 1.0 0.0 0.0 0.0 0.0 0.0 0.0 2 b.jpg\n\n"))
        XCTAssertTrue(first.points3DTxt.contains("# Number of points: 0"))
    }

    func testEmittedModelParsesThroughResidualAnalyzer() throws {
        // Identity pose, SIMPLE_PINHOLE f=100 c=(320,240); observations
        // hand-projected from the emitted points so residuals are exactly zero.
        let pose = DatasetPoseConvention.ColmapPose(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 0, tz: 0)
        let model = ColmapTextModel(
            cameras: [
                ColmapTextCamera(id: 1, model: "SIMPLE_PINHOLE", width: 640, height: 480, parameters: [100, 320, 240])
            ],
            images: [
                ColmapTextImage(
                    id: 1,
                    pose: pose,
                    cameraID: 1,
                    name: "frame_000001.jpg",
                    observations: [
                        ColmapTextObservation(x: 320, y: 240, point3DID: 1),
                        ColmapTextObservation(x: 331, y: 240, point3DID: 2),
                    ]
                )
            ],
            points: [
                ColmapTextPoint3D(
                    id: 1, x: 0, y: 0, z: 1, red: 200, green: 10, blue: 10, error: 0,
                    track: [ColmapTextTrackElement(imageID: 1, point2DIndex: 0)]
                ),
                ColmapTextPoint3D(
                    id: 2, x: 0.11, y: 0, z: 1, red: 10, green: 200, blue: 10, error: 0,
                    track: [ColmapTextTrackElement(imageID: 1, point2DIndex: 1)]
                ),
            ]
        )
        let emitted = try ColmapTextModelEmitter.emit(model)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try emitted.camerasTxt.write(
            to: directory.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8
        )
        try emitted.imagesTxt.write(
            to: directory.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8
        )
        try emitted.points3DTxt.write(
            to: directory.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8
        )

        let result = try ColmapResidualAnalyzer.analyze(modelDirectory: directory)
        XCTAssertEqual(result.registeredViewCount, 1)
        XCTAssertEqual(result.registeredImageNames, ["frame_000001.jpg"])
        XCTAssertEqual(result.pointCount, 2)
        XCTAssertEqual(result.observationCount, 2)
        XCTAssertEqual(result.cameraModelsByID, [1: "SIMPLE_PINHOLE"])
    }

    func testRejectsStructuralInconsistencies() {
        let pose = DatasetPoseConvention.ColmapPose(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 0, tz: 0)
        let camera = ColmapTextCamera(id: 1, model: "PINHOLE", width: 10, height: 10, parameters: [1, 1, 5, 5])

        func expectError(_ model: ColmapTextModel, _ expected: ColmapTextModelEmitter.EmitError, line: UInt = #line) {
            XCTAssertThrowsError(try ColmapTextModelEmitter.emit(model), line: line) { error in
                XCTAssertEqual(error as? ColmapTextModelEmitter.EmitError, expected, line: line)
            }
        }

        expectError(ColmapTextModel(cameras: [], images: []), .noCameras)
        expectError(ColmapTextModel(cameras: [camera], images: []), .noImages)
        expectError(
            ColmapTextModel(
                cameras: [camera, camera],
                images: [ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg")]
            ),
            .duplicateCameraID(1)
        )
        expectError(
            ColmapTextModel(
                cameras: [camera],
                images: [
                    ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg"),
                    ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "b.jpg"),
                ]
            ),
            .duplicateImageID(1)
        )
        expectError(
            ColmapTextModel(
                cameras: [camera],
                images: [
                    ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg"),
                    ColmapTextImage(id: 2, pose: pose, cameraID: 1, name: "a.jpg"),
                ]
            ),
            .duplicateImageName("a.jpg")
        )
        expectError(
            ColmapTextModel(
                cameras: [camera],
                images: [ColmapTextImage(id: 1, pose: pose, cameraID: 9, name: "a.jpg")]
            ),
            .unknownCameraReference(imageID: 1, cameraID: 9)
        )
        expectError(
            ColmapTextModel(
                cameras: [camera],
                images: [ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "bad\nname.jpg")]
            ),
            .invalidImageName("bad\nname.jpg")
        )
        expectError(
            ColmapTextModel(
                cameras: [camera],
                images: [ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg")],
                points: [
                    ColmapTextPoint3D(
                        id: 1, x: 0, y: 0, z: 1, red: 0, green: 0, blue: 0, error: 0,
                        track: [ColmapTextTrackElement(imageID: 5, point2DIndex: 0)]
                    )
                ]
            ),
            .unknownTrackImage(pointID: 1, imageID: 5)
        )
        expectError(
            ColmapTextModel(
                cameras: [camera],
                images: [ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg")],
                points: [
                    ColmapTextPoint3D(id: 1, x: 0, y: 0, z: 1, red: 300, green: 0, blue: 0, error: 0, track: [])
                ]
            ),
            .invalidColorComponent(pointID: 1)
        )
        expectError(
            ColmapTextModel(
                cameras: [ColmapTextCamera(id: 1, model: "PINHOLE", width: 10, height: 10, parameters: [.infinity])],
                images: [ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "a.jpg")]
            ),
            .nonFiniteValue
        )
    }

    func testImageNamesWithInteriorSpacesAreAllowed() throws {
        // COLMAP treats everything after CAMERA_ID as the name; the in-repo
        // readers use remainder-based parsing, so interior spaces survive.
        let pose = DatasetPoseConvention.ColmapPose(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 0, tz: 0)
        let model = ColmapTextModel(
            cameras: [ColmapTextCamera(id: 1, model: "SIMPLE_PINHOLE", width: 10, height: 10, parameters: [1, 5, 5])],
            images: [ColmapTextImage(id: 1, pose: pose, cameraID: 1, name: "IMG 0001.jpg")]
        )
        let emitted = try ColmapTextModelEmitter.emit(model)
        XCTAssertTrue(emitted.imagesTxt.contains(" 1 IMG 0001.jpg\n"))
    }
}
