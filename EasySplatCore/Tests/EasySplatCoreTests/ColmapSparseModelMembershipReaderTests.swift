#if canImport(XCTest)
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapSparseModelMembershipReaderTests: XCTestCase {
    func testReadsBinaryMembershipAndBindsEveryImageToDatabase() throws {
        let fixture = try makeFixture(images: [(1, "first.jpg"), (7, "second frame.jpg")])
        let model = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: [
                BinaryImage(id: 7, name: "second frame.jpg", points: [(4, 5, 11)]),
                BinaryImage(id: 1, name: "first.jpg"),
            ]
        )

        let result = try makeReader(fixture).read(modelDirectories: [model])

        XCTAssertEqual(
            result.models,
            [ColmapSparseModelMembership(modelOrder: 0, imageIDs: [1, 7])]
        )
        XCTAssertEqual(result.modelCount, 1)
        XCTAssertEqual(result.largestModelRegisteredViewCount, 2)
        XCTAssertEqual(result.secondLargestModelRegisteredViewCount, 0)
        XCTAssertEqual(result.unionRegisteredViewCount, 2)
        XCTAssertEqual(result.unionImageIDs, [1, 7])
    }

    func testReadsTextMembershipWithNamesContainingSpacesAndValidObservationTriples() throws {
        let fixture = try makeFixture(images: [(2, "front room.jpg"), (9, "hall.jpg")])
        let model = try makeTextModel(
            in: fixture.root,
            order: 3,
            imagesText: "# Image list\n"
                + "2 1 0 0 0 0 0 0 1 front room.jpg\n"
                + "12.5 8.25 -1 20.0 11.0 44\n"
                + "9 0.7071067811865476 0.7071067811865476 0 0 1 2 3 1 hall.jpg\n\n"
        )

        let result = try makeReader(fixture).read(modelDirectories: [model])

        XCTAssertEqual(
            result.models,
            [ColmapSparseModelMembership(modelOrder: 3, imageIDs: [2, 9])]
        )
    }

    func testCompleteBinaryFamilyIsAuthoritativeAndCorruptionDoesNotFallBackToText() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let model = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: [BinaryImage(id: 1, name: "one.jpg")]
        )
        try writeTextFamily(
            at: model,
            imagesText: "1 1 0 0 0 0 0 0 1 one.jpg\n\n"
        )
        try Data([1]).write(to: model.appendingPathComponent("images.bin"))

        assertMalformedBinary(
            tryRead(fixture, models: [model]),
            modelOrder: 0,
            issue: .truncated
        )
    }

    func testRejectsTruncatedAndTrailingBinaryPayloads() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let truncated = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            data: Data(binaryRecordPrefix(id: 1).prefix(20))
        )
        assertMalformedBinary(
            tryRead(fixture, models: [truncated]),
            modelOrder: 0,
            issue: .truncated
        )

        let trailing = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            records: [BinaryImage(id: 1, name: "one.jpg")]
        )
        let handle = try FileHandle(forWritingTo: trailing.appendingPathComponent("images.bin"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        assertMalformedBinary(
            tryRead(fixture, models: [trailing]),
            modelOrder: 1,
            issue: .trailingBytes
        )
    }

    func testRejectsZeroAndUnboundedBinaryImageCountsBeforeAllocating() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let empty = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            data: binaryHeader(imageCount: 0)
        )
        assertMalformedBinary(
            tryRead(fixture, models: [empty]),
            modelOrder: 0,
            issue: .invalidImageCount
        )

        let huge = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            data: binaryHeader(imageCount: .max)
        )
        assertMalformedBinary(
            tryRead(fixture, models: [huge]),
            modelOrder: 1,
            issue: .invalidImageCount
        )
    }

    func testRejectsMissingOrOverlongBinaryNameTerminator() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let short = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            data: binaryRecordPrefix(id: 1) + Data("unterminated".utf8)
        )
        assertMalformedBinary(
            tryRead(fixture, models: [short]),
            modelOrder: 0,
            issue: .missingNameTerminator
        )

        let long = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            data: binaryRecordPrefix(id: 1) + Data(repeating: 0x61, count: 4_097)
        )
        assertMalformedBinary(
            tryRead(fixture, models: [long]),
            modelOrder: 1,
            issue: .nameTooLong
        )
    }

    func testRejectsMalformedBinaryUTF8PoseAndPointCount() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let invalidUTF8 = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: [BinaryImage(id: 1, nameBytes: [0xC3, 0x28])]
        )
        assertMalformedBinary(
            tryRead(fixture, models: [invalidUTF8]),
            modelOrder: 0,
            issue: .invalidUTF8
        )

        let nonfinite = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            records: [BinaryImage(id: 1, name: "one.jpg", quaternion: [.nan, 0, 0, 0])]
        )
        assertMalformedBinary(
            tryRead(fixture, models: [nonfinite]),
            modelOrder: 1,
            issue: .nonfinitePose
        )

        let zeroQuaternion = try makeBinaryModel(
            in: fixture.root,
            order: 2,
            records: [BinaryImage(id: 1, name: "one.jpg", quaternion: [0, 0, 0, 0])]
        )
        assertMalformedBinary(
            tryRead(fixture, models: [zeroQuaternion]),
            modelOrder: 2,
            issue: .zeroQuaternion
        )

        var pointOverflow = binaryRecordPrefix(id: 1)
        pointOverflow.append(contentsOf: Data("one.jpg".utf8))
        pointOverflow.append(0)
        append(UInt64.max, to: &pointOverflow)
        let overflow = try makeBinaryModel(
            in: fixture.root,
            order: 3,
            data: pointOverflow
        )
        assertMalformedBinary(
            tryRead(fixture, models: [overflow]),
            modelOrder: 3,
            issue: .pointCountOverflow
        )
    }

    func testRejectsDuplicateModelIdentityAndDatabaseBindingMismatch() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg"), (2, "two.jpg")])
        let duplicateID = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: [
                BinaryImage(id: 1, name: "one.jpg"),
                BinaryImage(id: 1, name: "two.jpg"),
            ]
        )
        XCTAssertEqual(
            tryRead(fixture, models: [duplicateID]) as? ColmapSparseModelMembershipReaderError,
            .duplicateModelImageID(modelOrder: 0, imageID: 1)
        )

        let wrongName = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            records: [BinaryImage(id: 1, name: "two.jpg")]
        )
        XCTAssertEqual(
            tryRead(fixture, models: [wrongName]) as? ColmapSparseModelMembershipReaderError,
            .imageBindingMismatch(
                modelOrder: 1,
                imageID: 1,
                expectedName: "one.jpg",
                actualName: "two.jpg"
            )
        )

        let unknownID = try makeBinaryModel(
            in: fixture.root,
            order: 2,
            records: [BinaryImage(id: 99, name: "one.jpg")]
        )
        XCTAssertEqual(
            tryRead(fixture, models: [unknownID]) as? ColmapSparseModelMembershipReaderError,
            .unknownModelImageID(modelOrder: 2, imageID: 99)
        )
    }

    func testRejectsDatabaseImageSetThatDiffersFromSelectedInput() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg"), (2, "two.jpg")])
        let model = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: [BinaryImage(id: 1, name: "one.jpg")]
        )
        let reader = ColmapSparseModelMembershipReader(
            databaseURL: fixture.database,
            selectedImageNames: ["one.jpg", "missing.jpg"]
        )

        XCTAssertEqual(
            tryRead(reader, models: [model]) as? ColmapSparseModelMembershipReaderError,
            .databaseImageSetMismatch(
                expected: ["missing.jpg", "one.jpg"],
                actual: ["one.jpg", "two.jpg"]
            )
        )
    }

    func testAggregatesOverlappingModelsWithoutDoubleCountingUnion() throws {
        let images = (1...100).map { (UInt32($0), "frame-\($0).jpg") }
        let fixture = try makeFixture(images: images)
        let first = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: (1...80).map { BinaryImage(id: UInt32($0), name: "frame-\($0).jpg") }
        )
        let second = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            records: (1...100).map { BinaryImage(id: UInt32($0), name: "frame-\($0).jpg") }
        )

        let result = try makeReader(fixture).read(modelDirectories: [second, first])

        XCTAssertEqual(result.models.map(\.modelOrder), [0, 1])
        XCTAssertEqual(result.modelCount, 2)
        XCTAssertEqual(result.largestModelRegisteredViewCount, 100)
        XCTAssertEqual(result.secondLargestModelRegisteredViewCount, 80)
        XCTAssertEqual(result.unionRegisteredViewCount, 100)
        XCTAssertEqual(result.unionImageIDs, Set((1...100).map(UInt32.init)))
    }

    func testRejectsPartialModelFamilies() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let model = try makeModelDirectory(in: fixture.root, order: 0)
        try Data().write(to: model.appendingPathComponent("cameras.bin"))
        try makeBinaryData(records: [BinaryImage(id: 1, name: "one.jpg")])
            .write(to: model.appendingPathComponent("images.bin"))

        XCTAssertEqual(
            tryRead(fixture, models: [model]) as? ColmapSparseModelMembershipReaderError,
            .partialModelFamily(modelOrder: 0, format: .binary)
        )
    }

    func testRejectsMalformedTextPoseAndObservationAlternation() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let missingObservations = try makeTextModel(
            in: fixture.root,
            order: 0,
            imagesText: "1 1 0 0 0 0 0 0 1 one.jpg\n"
        )
        XCTAssertEqual(
            tryRead(fixture, models: [missingObservations])
                as? ColmapSparseModelMembershipReaderError,
            .malformedText(
                modelOrder: 0,
                line: 1,
                issue: .missingObservationLine
            )
        )

        let invalidTriples = try makeTextModel(
            in: fixture.root,
            order: 1,
            imagesText: "1 1 0 0 0 0 0 0 1 one.jpg\n1.0 2.0\n"
        )
        XCTAssertEqual(
            tryRead(fixture, models: [invalidTriples])
                as? ColmapSparseModelMembershipReaderError,
            .malformedText(
                modelOrder: 1,
                line: 2,
                issue: .invalidObservationLine
            )
        )
    }

    func testChecksCancellationDuringStreamingRead() throws {
        let images = (1...50).map { (UInt32($0), "frame-\($0).jpg") }
        let fixture = try makeFixture(images: images)
        let model = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: images.map { BinaryImage(id: $0.0, name: $0.1) }
        )
        var checks = 0

        XCTAssertThrowsError(
            try makeReader(fixture).read(
                modelDirectories: [model],
                checkCancellation: {
                    checks += 1
                    if checks == 8 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(checks, 8)
    }

    func testRejectsSymlinkAndHardLinkedBinaryFiles() throws {
        let fixture = try makeFixture(images: [(1, "one.jpg")])
        let data = makeBinaryData(records: [BinaryImage(id: 1, name: "one.jpg")])

        let symlinkModel = try makeBinaryModel(
            in: fixture.root,
            order: 0,
            records: [BinaryImage(id: 1, name: "one.jpg")]
        )
        let symlinkTarget = fixture.root.appendingPathComponent("external-images.bin")
        try data.write(to: symlinkTarget)
        let symlinkImages = symlinkModel.appendingPathComponent("images.bin")
        try FileManager.default.removeItem(at: symlinkImages)
        try FileManager.default.createSymbolicLink(
            at: symlinkImages,
            withDestinationURL: symlinkTarget
        )
        XCTAssertEqual(
            tryRead(fixture, models: [symlinkModel])
                as? ColmapSparseModelMembershipReaderError,
            .unsafeModelFile(modelOrder: 0, file: "images.bin")
        )

        let hardlinkModel = try makeBinaryModel(
            in: fixture.root,
            order: 1,
            records: [BinaryImage(id: 1, name: "one.jpg")]
        )
        let hardlinkTarget = fixture.root.appendingPathComponent("hardlink-source.bin")
        try data.write(to: hardlinkTarget)
        let hardlinkImages = hardlinkModel.appendingPathComponent("images.bin")
        try FileManager.default.removeItem(at: hardlinkImages)
        try FileManager.default.linkItem(at: hardlinkTarget, to: hardlinkImages)
        XCTAssertEqual(
            tryRead(fixture, models: [hardlinkModel])
                as? ColmapSparseModelMembershipReaderError,
            .unsafeModelFile(modelOrder: 1, file: "images.bin")
        )
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let imageNames: [String]
    }

    private struct BinaryImage {
        let id: UInt32
        let quaternion: [Double]
        let translation: [Double]
        let cameraID: UInt32
        let nameBytes: [UInt8]
        let points: [(Double, Double, UInt64)]

        init(
            id: UInt32,
            name: String,
            quaternion: [Double] = [1, 0, 0, 0],
            translation: [Double] = [0, 0, 0],
            cameraID: UInt32 = 1,
            points: [(Double, Double, UInt64)] = []
        ) {
            self.init(
                id: id,
                nameBytes: Array(name.utf8),
                quaternion: quaternion,
                translation: translation,
                cameraID: cameraID,
                points: points
            )
        }

        init(
            id: UInt32,
            nameBytes: [UInt8],
            quaternion: [Double] = [1, 0, 0, 0],
            translation: [Double] = [0, 0, 0],
            cameraID: UInt32 = 1,
            points: [(Double, Double, UInt64)] = []
        ) {
            self.id = id
            self.quaternion = quaternion
            self.translation = translation
            self.cameraID = cameraID
            self.nameBytes = nameBytes
            self.points = points
        }
    }

    private func makeFixture(images: [(UInt32, String)]) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("database.db")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        guard let handle else {
            throw NSError(domain: "ColmapSparseModelMembershipReaderTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        try execute(handle, "CREATE TABLE images(image_id INTEGER, name TEXT);")
        try execute(handle, "BEGIN IMMEDIATE TRANSACTION;")
        for (id, name) in images {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    handle,
                    "INSERT INTO images(image_id, name) VALUES (?, ?);",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            guard let statement else {
                throw NSError(domain: "ColmapSparseModelMembershipReaderTests", code: 2)
            }
            sqlite3_bind_int64(statement, 1, Int64(id))
            let step = name.withCString { pointer in
                sqlite3_bind_text(statement, 2, pointer, -1, nil)
                return sqlite3_step(statement)
            }
            XCTAssertEqual(step, SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        try execute(handle, "COMMIT;")
        return Fixture(root: root, database: database, imageNames: images.map(\.1))
    }

    private func makeReader(_ fixture: Fixture) -> ColmapSparseModelMembershipReader {
        ColmapSparseModelMembershipReader(
            databaseURL: fixture.database,
            selectedImageNames: fixture.imageNames
        )
    }

    private func makeModelDirectory(in root: URL, order: Int) throws -> URL {
        let model = root.appendingPathComponent(String(order), isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        return model
    }

    private func makeBinaryModel(
        in root: URL,
        order: Int,
        records: [BinaryImage]
    ) throws -> URL {
        try makeBinaryModel(
            in: root,
            order: order,
            data: makeBinaryData(records: records)
        )
    }

    private func makeBinaryModel(
        in root: URL,
        order: Int,
        data: Data
    ) throws -> URL {
        let model = try makeModelDirectory(in: root, order: order)
        for name in ["cameras.bin", "points3D.bin"] {
            try Data().write(to: model.appendingPathComponent(name))
        }
        try data.write(to: model.appendingPathComponent("images.bin"))
        return model
    }

    private func makeTextModel(
        in root: URL,
        order: Int,
        imagesText: String
    ) throws -> URL {
        let model = try makeModelDirectory(in: root, order: order)
        try writeTextFamily(at: model, imagesText: imagesText)
        return model
    }

    private func writeTextFamily(at model: URL, imagesText: String) throws {
        try Data().write(to: model.appendingPathComponent("cameras.txt"))
        try Data(imagesText.utf8).write(to: model.appendingPathComponent("images.txt"))
        try Data().write(to: model.appendingPathComponent("points3D.txt"))
    }

    private func makeBinaryData(records: [BinaryImage]) -> Data {
        var data = binaryHeader(imageCount: UInt64(records.count))
        for record in records {
            append(record.id, to: &data)
            for value in record.quaternion { append(value, to: &data) }
            for value in record.translation { append(value, to: &data) }
            append(record.cameraID, to: &data)
            data.append(contentsOf: record.nameBytes)
            data.append(0)
            append(UInt64(record.points.count), to: &data)
            for point in record.points {
                append(point.0, to: &data)
                append(point.1, to: &data)
                append(point.2, to: &data)
            }
        }
        return data
    }

    private func binaryHeader(imageCount: UInt64) -> Data {
        var data = Data()
        append(imageCount, to: &data)
        return data
    }

    private func binaryRecordPrefix(id: UInt32) -> Data {
        var data = binaryHeader(imageCount: 1)
        append(id, to: &data)
        for value in [1.0, 0, 0, 0, 0, 0, 0] { append(value, to: &data) }
        append(UInt32(1), to: &data)
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func append(_ value: Double, to data: inout Data) {
        append(value.bitPattern, to: &data)
    }

    private func tryRead(_ fixture: Fixture, models: [URL]) -> Error? {
        tryRead(makeReader(fixture), models: models)
    }

    private func tryRead(
        _ reader: ColmapSparseModelMembershipReader,
        models: [URL]
    ) -> Error? {
        do {
            _ = try reader.read(modelDirectories: models)
            XCTFail("Expected membership inspection to fail")
            return nil
        } catch {
            return error
        }
    }

    private func assertMalformedBinary(
        _ error: Error?,
        modelOrder: Int,
        issue: ColmapSparseModelBinaryIssue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            error as? ColmapSparseModelMembershipReaderError,
            .malformedBinary(modelOrder: modelOrder, issue: issue),
            file: file,
            line: line
        )
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw NSError(
                domain: "ColmapSparseModelMembershipReaderTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
#endif
