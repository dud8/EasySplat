import Darwin
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
        XCTAssertEqual(result.observationCountByImage, ["frame_000001.jpg": 2])
        XCTAssertEqual(result.pointCount, 2)
        XCTAssertEqual(result.observationCount, 2)
        XCTAssertEqual(result.cameraModel, "SIMPLE_PINHOLE")
        XCTAssertEqual(result.cameraSamples.count, 1)
        XCTAssertEqual(result.cameraSamples[0].imageName, "frame_000001.jpg")
        XCTAssertEqual(result.cameraSamples[0].trackedObservationCount, 2)
        XCTAssertEqual(result.cameraSamples[0].rotationWorldToCamera, .identity)
        XCTAssertEqual(result.cameraSamples[0].translation, .zero)
        XCTAssertEqual(result.meanPixelResidual, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.medianPixelResidual, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.p90PixelResidual, 1, accuracy: 0.000_001)
        XCTAssertEqual(result.provenance, "colmap-text-tracks-v1")
    }

    func testPointTrackTopologyDigestIgnoresIdentifiersOrderAndContinuousValues() throws {
        let baseline = try makeModel(
            cameras: """
            1 SIMPLE_PINHOLE 640 480 100 320 240
            2 PINHOLE 640 480 110 120 320 240
            """,
            images: """
            10 1 0 0 0 0 0 0 1 alpha.jpg
            320 240 100 330 240 200
            20 1 0 0 0 0 0 0 2 beta.jpg
            320 240 200 330 240 100
            """,
            points: """
            100 0 0 10 1 2 3 0.25 10 0 20 1
            200 1 0 10 4 5 6 0.5 10 1 20 0
            """
        )
        let renumberedAndReordered = try makeModel(
            cameras: """
            77 PINHOLE 800 600 160 170 400 300
            88 SIMPLE_PINHOLE 800 600 150 400 300
            """,
            images: """
            7 1 0 0 0 0 0.5 0 77 beta.jpg
            410 305 300 420 305 400
            99 1 0 0 0 0.5 0 0 88 alpha.jpg
            410 305 400 420 305 300
            """,
            points: """
            300 2 1 20 60 50 40 1.75 7 0 99 1
            400 -2 1 20 30 20 10 1.25 7 1 99 0
            """
        )

        let baselineDigest = try ColmapResidualAnalyzer.analyze(
            modelDirectory: baseline
        ).pointTrackTopologySHA256
        let reorderedDigest = try ColmapResidualAnalyzer.analyze(
            modelDirectory: renumberedAndReordered
        ).pointTrackTopologySHA256

        XCTAssertEqual(reorderedDigest, baselineDigest)
        XCTAssertEqual(
            baselineDigest,
            "8897a913281d2ce10e2315983b96654b4e69aece19a746fb64fc7cc44a9976e5"
        )
        XCTAssertNotNil(
            baselineDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression)
        )
    }

    func testPointTrackTopologyDigestChangesForPartitionNameOrObservationIndex() throws {
        let baseline = try makeTopologyModel(
            secondImageName: "beta.jpg",
            firstImageObservations: "320 240 100 330 240 200",
            secondImageObservations: "320 240 200 330 240 100",
            points: """
            100 0 0 10 1 2 3 0.25 10 0 20 1
            200 1 0 10 4 5 6 0.5 10 1 20 0
            """
        )
        let repartitioned = try makeTopologyModel(
            secondImageName: "beta.jpg",
            firstImageObservations: "320 240 100 330 240 200",
            secondImageObservations: "320 240 100 330 240 200",
            points: """
            100 0 0 10 1 2 3 0.25 10 0 20 0
            200 1 0 10 4 5 6 0.5 10 1 20 1
            """
        )
        let renamed = try makeTopologyModel(
            secondImageName: "beta-renamed.jpg",
            firstImageObservations: "320 240 100 330 240 200",
            secondImageObservations: "320 240 200 330 240 100",
            points: """
            100 0 0 10 1 2 3 0.25 10 0 20 1
            200 1 0 10 4 5 6 0.5 10 1 20 0
            """
        )
        let shiftedIndices = try makeTopologyModel(
            secondImageName: "beta.jpg",
            firstImageObservations: "0 0 -1 320 240 100 330 240 200",
            secondImageObservations: "320 240 200 330 240 100",
            points: """
            100 0 0 10 1 2 3 0.25 10 1 20 1
            200 1 0 10 4 5 6 0.5 10 2 20 0
            """
        )

        let baselineResult = try ColmapResidualAnalyzer.analyze(modelDirectory: baseline)
        let mutations = try [repartitioned, renamed, shiftedIndices].map {
            try ColmapResidualAnalyzer.analyze(modelDirectory: $0)
        }

        XCTAssertTrue(mutations.allSatisfy {
            $0.pointCount == baselineResult.pointCount
                && $0.observationCount == baselineResult.observationCount
                && $0.pointTrackTopologySHA256 != baselineResult.pointTrackTopologySHA256
        })
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

    func testPreservesImageNameWhitespace() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 folder/frame  001.jpg
            320 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )

        let result = try ColmapResidualAnalyzer.analyze(modelDirectory: model)

        XCTAssertEqual(result.registeredImageNames, ["folder/frame  001.jpg"])
        XCTAssertEqual(result.measuredImageNames, ["folder/frame  001.jpg"])
        XCTAssertEqual(result.cameraSamples.map(\.imageName), ["folder/frame  001.jpg"])
    }

    func testAcceptsASCIIAndUnicodeWhitespaceWithoutChangingMeasurements() throws {
        let ordinary = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: "1 1 0 0 0 0 0 0 1 frame.jpg\n320 240 1\n",
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )
        let mixedWhitespace = try makeModel(
            cameras: "\u{2003}# camera\n\t1\u{00A0}SIMPLE_PINHOLE\t640 480\u{2003}100 320 240\n",
            images: "\u{2003}# image\n1\t1 0\u{00A0}0 0 0 0 0\t1 frame.jpg\n320\u{2003}240\t1\n",
            points: "\u{00A0}# point\n1\t0 0\u{2003}10 255 255 255 0\t1 0\n"
        )

        XCTAssertEqual(
            try ColmapResidualAnalyzer.analyze(modelDirectory: mixedWhitespace),
            try ColmapResidualAnalyzer.analyze(modelDirectory: ordinary)
        )
    }

    func testPreservesWhitespaceCharacterWithCombiningScalar() throws {
        let ordinary = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: "1 1 0 0 0 0 0 0 1 frame.jpg\n320 240 1\n",
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )
        let combinedWhitespace = " \u{0301}"
        let combined = try makeModel(
            cameras: "1\(combinedWhitespace)SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: "1\(combinedWhitespace)1 0 0 0 0 0 0 1 frame.jpg\n"
                + "320\(combinedWhitespace)240 1\n",
            points: "1\(combinedWhitespace)0 0 10 255 255 255 0 1 0\n"
        )

        XCTAssertEqual(
            try ColmapResidualAnalyzer.analyze(modelDirectory: combined),
            try ColmapResidualAnalyzer.analyze(modelDirectory: ordinary)
        )
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
                .nonPositiveDepthObservation(pointID: 2, imageLine: 1)
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
        ) { error in
            XCTAssertEqual(
                error as? ColmapResidualAnalyzer.Error,
                .inconsistentTrack(pointID: 1, imageID: 1, point2DIndex: 0)
            )
        }

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
        ) { error in
            XCTAssertEqual(
                error as? ColmapResidualAnalyzer.Error,
                .duplicateTrack(imageID: 1, point2DIndex: 0)
            )
        }
    }

    func testMeasuresDistinctSameImageObservationsInOneColmapTrack() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1 323 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0 1 1\n"
        )

        let result = try ColmapResidualAnalyzer.analyze(modelDirectory: model)

        XCTAssertEqual(result.registeredViewCount, 1)
        XCTAssertEqual(result.measuredImageNames, ["frame.jpg"])
        XCTAssertEqual(result.pointCount, 1)
        XCTAssertEqual(result.observationCount, 2)
        XCTAssertEqual(result.observationCountByImage, ["frame.jpg": 2])
        XCTAssertEqual(result.meanPixelResidual, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(result.medianPixelResidual, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(result.p90PixelResidual, 3, accuracy: 0.000_001)
    }

    func testRejectsRepeatedIdenticalTrackElement() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0 1 0\n"
        )

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) { error in
            XCTAssertEqual(
                error as? ColmapResidualAnalyzer.Error,
                .duplicateTrack(imageID: 1, point2DIndex: 0)
            )
        }
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

    func testRejectsInvalidAndNonFiniteUnmeasuredRecords() throws {
        let malformedCameras = [
            "0 SIMPLE_PINHOLE 640 480 100 320 240\n",
            "1 SIMPLE_PINHOLE 0 480 100 320 240\n",
            "1 SIMPLE_PINHOLE 640 480 0 320 240\n",
            "1 PINHOLE 640 480 100 -100 320 240\n",
            "1 SIMPLE_PINHOLE 640 480 nan 320 240\n",
        ]
        for cameras in malformedCameras {
            let model = try makeModel(
                cameras: cameras,
                images: "1 1 0 0 0 0 0 0 1 frame.jpg\n0 0 -1\n",
                points: "# no points\n"
            )
            XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) {
                XCTAssertEqual(
                    $0 as? ColmapResidualAnalyzer.Error,
                    .malformedRecord(file: "cameras.txt", line: 1)
                )
            }
        }

        let malformedImages = [
            "0 1 0 0 0 0 0 0 1 frame.jpg\n0 0 -1\n",
            "1 nan 0 0 0 0 0 0 1 frame.jpg\n0 0 -1\n",
            "1 1 0 0 0 0 0 0 1 frame.jpg\nnan 0 -1\n",
            "1 1 0 0 0 0 0 0 1 frame.jpg\n0 0 -2\n",
        ]
        for images in malformedImages {
            let model = try makeModel(
                cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
                images: images,
                points: "# no points\n"
            )
            XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) {
                guard case .malformedRecord(file: "images.txt", line: _) =
                    $0 as? ColmapResidualAnalyzer.Error else {
                    return XCTFail("Expected malformed images.txt record, got \($0)")
                }
            }
        }
    }

    func testRejectsSymlinkedAndHardLinkedRequiredModelFiles() throws {
        for fileName in ["cameras.txt", "images.txt", "points3D.txt"] {
            for hardLink in [false, true] {
                let model = try makeModel(
                    cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
                    images: """
                    1 1 0 0 0 0 0 0 1 frame.jpg
                    320 240 1
                    """,
                    points: "1 0 0 10 255 255 255 0 1 0\n"
                )
                let requiredURL = model.appendingPathComponent(fileName)
                let externalURL = model.appendingPathComponent("external-\(fileName)")
                try FileManager.default.moveItem(at: requiredURL, to: externalURL)
                if hardLink {
                    XCTAssertEqual(Darwin.link(externalURL.path, requiredURL.path), 0)
                } else {
                    try FileManager.default.createSymbolicLink(
                        at: requiredURL,
                        withDestinationURL: externalURL
                    )
                }

                XCTAssertThrowsError(
                    try ColmapResidualAnalyzer.analyze(modelDirectory: model),
                    "\(hardLink ? "hard link" : "symlink") for \(fileName)"
                )
            }
        }
    }

    func testRejectsOversizedRequiredFileBeforeParsing() throws {
        let model = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            1 1 0 0 0 0 0 0 1 frame.jpg
            320 240 1
            """,
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )
        let camerasURL = model.appendingPathComponent("cameras.txt")
        XCTAssertEqual(
            Darwin.truncate(camerasURL.path, off_t(16 * 1_024 * 1_024 + 1)),
            0
        )

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyze(modelDirectory: model)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "cameras.txt is not an ordinary file within the allowed size."
            )
        }
    }

    func testStreamingUTF8AcrossReadBoundaryAndRejectsInvalidSequence() throws {
        let readChunkBytes = 64 * 1_024
        let posePrefix = "1 1 0 0 0 0 0 0 1 frame_"
        let bytesBeforeCommentPadding = 2 + posePrefix.utf8.count
        let paddingCount = (
            readChunkBytes - 1 - bytesBeforeCommentPadding % readChunkBytes + readChunkBytes
        ) % readChunkBytes
        let prefix = "#" + String(repeating: "x", count: paddingCount) + "\n" + posePrefix
        XCTAssertEqual(prefix.utf8.count % readChunkBytes, readChunkBytes - 1)

        let validModel = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: "placeholder\n",
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )
        var validImages = Data(prefix.utf8)
        validImages.append(contentsOf: "é.jpg\n320 240 1\n".utf8)
        try validImages.write(to: validModel.appendingPathComponent("images.txt"), options: .atomic)

        let validResult = try ColmapResidualAnalyzer.analyze(modelDirectory: validModel)
        XCTAssertEqual(validResult.registeredImageNames, ["frame_é.jpg"])

        let invalidModel = try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: "placeholder\n",
            points: "1 0 0 10 255 255 255 0 1 0\n"
        )
        var invalidImages = Data(prefix.utf8)
        invalidImages.append(contentsOf: [0xC3, 0x28])
        invalidImages.append(contentsOf: ".jpg\n320 240 1\n".utf8)
        try invalidImages.write(to: invalidModel.appendingPathComponent("images.txt"), options: .atomic)

        XCTAssertThrowsError(
            try ColmapResidualAnalyzer.analyze(modelDirectory: invalidModel)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "COLMAP model contains invalid UTF-8 in images.txt."
            )
        }
    }

    func testBoundedLineReaderRejectsLineLargerThanCallerLimit() throws {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized-line.txt")
        try Data((String(repeating: "x", count: 65) + "\n").utf8).write(to: file)

        let reader = try BoundedUTF8LineReader(
            at: file,
            maximumBytes: 66,
            maximumLineBytes: 64,
            readChunkBytes: 8
        )
        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "oversized-line.txt contains a line larger than the allowed size."
            )
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

    private func makeTopologyModel(
        secondImageName: String,
        firstImageObservations: String,
        secondImageObservations: String,
        points: String
    ) throws -> URL {
        try makeModel(
            cameras: "1 SIMPLE_PINHOLE 640 480 100 320 240\n",
            images: """
            10 1 0 0 0 0 0 0 1 alpha.jpg
            \(firstImageObservations)
            20 1 0 0 0 0 0 0 1 \(secondImageName)
            \(secondImageObservations)
            """,
            points: points
        )
    }
}
