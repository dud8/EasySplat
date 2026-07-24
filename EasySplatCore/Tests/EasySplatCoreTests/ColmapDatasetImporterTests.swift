import Foundation
import XCTest
@testable import EasySplatCore

final class ColmapDatasetImporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private let camerasText = """
    # comment
    1 SIMPLE_PINHOLE 640 480 100 320 240
    """

    private func imagesText(names: [String], observations: Bool) -> String {
        names.enumerated().map { index, name in
            let pose = "\(index + 1) 1 0 0 0 0 0 \(Double(index)) 1 \(name)"
            let obs = observations ? "320 240 1 331 240 -1" : ""
            return pose + "\n" + obs
        }.joined(separator: "\n")
    }

    private func pointsText(count: Int) -> String {
        (1...count).map { id in
            "\(id) 0 0 1 200 10 10 0.5 1 0"
        }.joined(separator: "\n")
    }

    private func writeTextModel(
        at modelDirectory: URL,
        names: [String],
        pointCount: Int,
        observations: Bool
    ) throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try camerasText.write(
            to: modelDirectory.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8
        )
        try imagesText(names: names, observations: observations).write(
            to: modelDirectory.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8
        )
        try (pointCount > 0 ? pointsText(count: pointCount) : "").write(
            to: modelDirectory.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8
        )
    }

    private func writeImages(named names: [String], under directory: String? = "images") throws {
        let base = directory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root!
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for name in names {
            try Data([0xFF, 0xD8, 0xFF]).write(to: base.appendingPathComponent(name))
        }
    }

    // MARK: - Importer

    func testCompleteModelRoutesToDirectAdoption() throws {
        try writeTextModel(
            at: root.appendingPathComponent("sparse/0"),
            names: ["a.jpg", "b.jpg"],
            pointCount: ColmapDatasetImporter.minimumDirectAdoptionPoints,
            observations: true
        )
        try writeImages(named: ["a.jpg", "b.jpg"])

        let plan = try ColmapDatasetImporter.plan(datasetRoot: root)
        XCTAssertEqual(plan.kind, .colmap)
        XCTAssertEqual(plan.route, .adoptDirect)
        XCTAssertEqual(plan.images.map(\.declaredPath), ["images/a.jpg", "images/b.jpg"])
        XCTAssertEqual(plan.model.points.count, ColmapDatasetImporter.minimumDirectAdoptionPoints)
        XCTAssertEqual(plan.model.images.first?.observations.count, 2)
    }

    func testSparsePointsRouteToSeedTriangulationWithStrippedStructure() throws {
        try writeTextModel(
            at: root.appendingPathComponent("sparse/0"),
            names: ["a.jpg"],
            pointCount: 3,
            observations: true
        )
        try writeImages(named: ["a.jpg"])

        let plan = try ColmapDatasetImporter.plan(datasetRoot: root)
        XCTAssertEqual(plan.route, .seedTriangulate)
        XCTAssertTrue(plan.model.points.isEmpty)
        XCTAssertEqual(plan.model.images.first?.observations.count, 0)
        XCTAssertTrue(plan.notes.contains { $0.contains("re-triangulated") })
    }

    func testModelAtRootWithLooseImages() throws {
        try writeTextModel(at: root, names: ["a.jpg"], pointCount: 0, observations: false)
        try writeImages(named: ["a.jpg"], under: nil)

        let plan = try ColmapDatasetImporter.plan(datasetRoot: root)
        XCTAssertEqual(plan.route, .seedTriangulate)
        XCTAssertEqual(plan.images.map(\.declaredPath), ["a.jpg"])
    }

    func testMultipleSparseModelsAreRejected() throws {
        try writeTextModel(at: root.appendingPathComponent("sparse/0"), names: ["a.jpg"], pointCount: 0, observations: false)
        try writeTextModel(at: root.appendingPathComponent("sparse/1"), names: ["a.jpg"], pointCount: 0, observations: false)
        try writeImages(named: ["a.jpg"])

        XCTAssertThrowsError(try ColmapDatasetImporter.plan(datasetRoot: root)) { error in
            XCTAssertEqual(error as? ColmapDatasetImporter.ImportError, .multipleModels)
        }
    }

    func testMissingImageFilesAreRejectedWithCounts() throws {
        try writeTextModel(
            at: root.appendingPathComponent("sparse/0"),
            names: ["a.jpg", "b.jpg", "c.jpg"],
            pointCount: 0,
            observations: false
        )
        try writeImages(named: ["a.jpg"])

        XCTAssertThrowsError(try ColmapDatasetImporter.plan(datasetRoot: root)) { error in
            XCTAssertEqual(
                error as? ColmapDatasetImporter.ImportError,
                .missingImageFiles(missing: 2, total: 3)
            )
        }
    }

    func testUnposedImagesAreExcludedAndNoted() throws {
        try writeTextModel(at: root.appendingPathComponent("sparse/0"), names: ["a.jpg"], pointCount: 0, observations: false)
        try writeImages(named: ["a.jpg", "extra.jpg"])

        let plan = try ColmapDatasetImporter.plan(datasetRoot: root)
        XCTAssertEqual(plan.images.count, 1)
        XCTAssertTrue(plan.notes.contains { $0.contains("no camera pose") })
    }

    func testFolderWithoutModelIsRejected() throws {
        try writeImages(named: ["a.jpg"])
        XCTAssertThrowsError(try ColmapDatasetImporter.plan(datasetRoot: root)) { error in
            XCTAssertEqual(error as? ColmapDatasetImporter.ImportError, .noModelFound)
        }
    }

    // MARK: - Binary reader parity

    func testBinaryModelMatchesTextModel() throws {
        let textDirectory = root.appendingPathComponent("text")
        try writeTextModel(at: textDirectory, names: ["a.jpg", "b c.jpg"], pointCount: 2, observations: true)
        let textModel = try ColmapModelReader.readText(modelDirectory: textDirectory)

        let binaryDirectory = root.appendingPathComponent("binary")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try binaryCameras(textModel.cameras).write(to: binaryDirectory.appendingPathComponent("cameras.bin"))
        try binaryImages(textModel.images).write(to: binaryDirectory.appendingPathComponent("images.bin"))
        try binaryPoints(textModel.points).write(to: binaryDirectory.appendingPathComponent("points3D.bin"))

        let (binaryModel, format) = try ColmapModelReader.read(modelDirectory: binaryDirectory)
        XCTAssertEqual(format, .binary)
        XCTAssertEqual(binaryModel, textModel)
    }

    func testTruncatedBinaryModelIsRejectedNotCrashed() throws {
        let directory = root.appendingPathComponent("truncated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Declares 1000 cameras but contains none.
        var data = Data()
        appendUInt64(&data, 1000)
        try data.write(to: directory.appendingPathComponent("cameras.bin"))
        try Data().write(to: directory.appendingPathComponent("images.bin"))

        XCTAssertThrowsError(try ColmapModelReader.read(modelDirectory: directory)) { error in
            XCTAssertEqual(
                error as? ColmapModelReader.ReadError, .malformedBinary("cameras.bin")
            )
        }
    }

    func testUnknownCameraModelIsRejected() throws {
        let directory = root.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        appendUInt64(&data, 1)
        appendUInt32(&data, 1)
        appendInt32(&data, 99)
        appendUInt64(&data, 640)
        appendUInt64(&data, 480)
        try data.write(to: directory.appendingPathComponent("cameras.bin"))
        try Data().write(to: directory.appendingPathComponent("images.bin"))

        XCTAssertThrowsError(try ColmapModelReader.read(modelDirectory: directory)) { error in
            XCTAssertEqual(
                error as? ColmapModelReader.ReadError, .unknownBinaryCameraModel(99)
            )
        }
    }

    // MARK: - Binary encoding helpers

    private func appendUInt64(_ data: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendInt32(_ data: inout Data, _ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendDouble(_ data: inout Data, _ value: Double) {
        appendUInt64(&data, value.bitPattern)
    }

    private func binaryCameras(_ cameras: [ColmapTextCamera]) -> Data {
        var data = Data()
        appendUInt64(&data, UInt64(cameras.count))
        for camera in cameras {
            let modelID = ColmapModelReader.cameraModels.first { $0.name == camera.model }!.id
            appendUInt32(&data, UInt32(camera.id))
            appendInt32(&data, Int32(modelID))
            appendUInt64(&data, UInt64(camera.width))
            appendUInt64(&data, UInt64(camera.height))
            for parameter in camera.parameters {
                appendDouble(&data, parameter)
            }
        }
        return data
    }

    private func binaryImages(_ images: [ColmapTextImage]) -> Data {
        var data = Data()
        appendUInt64(&data, UInt64(images.count))
        for image in images {
            appendUInt32(&data, UInt32(image.id))
            for value in [image.pose.qw, image.pose.qx, image.pose.qy, image.pose.qz,
                          image.pose.tx, image.pose.ty, image.pose.tz] {
                appendDouble(&data, value)
            }
            appendUInt32(&data, UInt32(image.cameraID))
            data.append(contentsOf: Array(image.name.utf8))
            data.append(0)
            appendUInt64(&data, UInt64(image.observations.count))
            for observation in image.observations {
                appendDouble(&data, observation.x)
                appendDouble(&data, observation.y)
                appendUInt64(
                    &data,
                    observation.point3DID < 0 ? UInt64.max : UInt64(observation.point3DID)
                )
            }
        }
        return data
    }

    private func binaryPoints(_ points: [ColmapTextPoint3D]) -> Data {
        var data = Data()
        appendUInt64(&data, UInt64(points.count))
        for point in points {
            appendUInt64(&data, UInt64(point.id))
            appendDouble(&data, point.x)
            appendDouble(&data, point.y)
            appendDouble(&data, point.z)
            data.append(contentsOf: [UInt8(point.red), UInt8(point.green), UInt8(point.blue)])
            appendDouble(&data, point.error)
            appendUInt64(&data, UInt64(point.track.count))
            for element in point.track {
                appendUInt32(&data, UInt32(element.imageID))
                appendUInt32(&data, UInt32(element.point2DIndex))
            }
        }
        return data
    }
}
