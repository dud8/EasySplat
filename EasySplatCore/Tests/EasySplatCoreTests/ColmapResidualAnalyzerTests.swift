import Foundation
import XCTest
@testable import EasySplatCore

final class ColmapResidualAnalyzerTests: XCTestCase {
    func testComputesRealPixelResidualsFromTrackedPoints() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame_000001.jpg
            320 240 1 331 240 2
            """,
            points: """
            1 0 0 10 255 255 255 0 1 0
            2 1 0 10 255 255 255 0 1 1
            """
        )

        let result = try ColmapResidualAnalyzer.analyze(modelDirectory: model)

        XCTAssertEqual(result.registeredViewCount, 1)
        XCTAssertEqual(result.registeredImageNames, ["frame_000001.jpg"])
        XCTAssertEqual(result.measuredImageNames, ["frame_000001.jpg"])
        XCTAssertEqual(result.pointCount, 2)
        XCTAssertEqual(result.observationCount, 2)
        XCTAssertEqual(result.meanPixelResidual, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.medianPixelResidual, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.p90PixelResidual, 1, accuracy: 0.000_001)
        XCTAssertEqual(result.provenance, "colmap-text-tracks-v1")
    }

    func testAppliesWorldToCameraTranslation() throws {
        let model = try makeModel(
            cameras: "1 PINHOLE 640 480 100 100 320 240\n",
            images: """
            1 1 0 0 0 1 0 0 1 translated.jpg
            330 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )

        let result = try ColmapResidualAnalyzer.analyze(modelDirectory: model)

        XCTAssertEqual(result.meanPixelResidual, 0, accuracy: 0.000_001)
        XCTAssertEqual(result.medianPixelResidual, 0, accuracy: 0.000_001)
        XCTAssertEqual(result.p90PixelResidual, 0, accuracy: 0.000_001)
    }

    func testRejectsTracklessModelsInsteadOfInventingResiduals() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 -1
            """,
            points: "# no points\n"
        )

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) { error in
            XCTAssertEqual(error as? ColmapResidualAnalyzer.Error, .noTrackedObservations)
        }
    }

    func testRejectsTrackedPointBehindCameraInsteadOfDroppingItsResidual() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1 320 240 2
            """,
            points: """
            1 0 0 10 255 255 255 0 1 0
            2 0 0 -10 255 255 255 0 1 1
            """
        )

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) { error in
            XCTAssertEqual(
                error as? ColmapResidualAnalyzer.Error,
                .unprojectableObservation(pointID: 2, imageLine: 1)
            )
        }
    }

    func testRejectsNonReciprocalAndDuplicateTrackAssignments() throws {
        let nonReciprocal = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 1\n"
        )
        XCTAssertThrowsError(
            try ColmapResidualAnalyzer.analyze(modelDirectory: nonReciprocal)
        )

        let duplicate = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1 330 240 2
            """,
            points: """
            1 0 0 10 255 255 255 0 1 0
            2 1 0 10 255 255 255 0 1 0
            """
        )
        XCTAssertThrowsError(
            try ColmapResidualAnalyzer.analyze(modelDirectory: duplicate)
        )
    }

    func testAcceptsDistinctSameImageObservationsInOneColmapTrack() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1 320 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0 1 1\n"
        )

        let result = try ColmapResidualAnalyzer.analyze(modelDirectory: model)

        XCTAssertEqual(result.registeredViewCount, 1)
        XCTAssertEqual(result.measuredImageNames, ["frame.jpg"])
        XCTAssertEqual(result.pointCount, 1)
        XCTAssertEqual(result.observationCount, 2)
        XCTAssertEqual(result.medianPixelResidual, 0, accuracy: 0.000_001)
    }

    func testRejectsUnsupportedCameraModels() throws {
        let model = try makeModel(
            cameras: "1 FOV 640 480 100 320 240 0.5\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) { error in
            XCTAssertEqual(error as? ColmapResidualAnalyzer.Error, .unsupportedCameraModel("FOV"))
        }
    }

    private func makeModel(cameras: String, images: String, points: String) throws -> URL {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try cameras.write(to: root.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try images.write(to: root.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try points.write(to: root.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
        return root
    }
}
