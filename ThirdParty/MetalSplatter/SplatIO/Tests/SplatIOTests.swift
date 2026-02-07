import XCTest
import Spatial
import SplatIO

final class SplatIOTests: XCTestCase {
    class ContentCounter: SplatSceneReaderDelegate {
        var expectedPointCount: UInt32?
        var pointCount: UInt32 = 0
        var didFinish = false
        var didFail = false

        func reset() {
            expectedPointCount = nil
            pointCount = 0
            didFinish = false
            didFail = false
        }

        func didStartReading(withPointCount pointCount: UInt32) {
            XCTAssertNil(expectedPointCount)
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            expectedPointCount = pointCount
        }

        func didRead(points: [SplatIO.SplatScenePoint]) {
            pointCount += UInt32(points.count)
        }

        func didFinishReading() {
            XCTAssertNotNil(expectedPointCount)
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            didFinish = true
        }

        func didFailReading(withError error: Error?) {
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            didFail = true
        }
    }

    let trainURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "ply", subdirectory: "TestData")!

    func testReadTrain() throws {
        try testRead(trainURL)
    }

    func testRead(_ url: URL) throws {
        let reader = SplatPLYSceneReader(url)

        let content = ContentCounter()
        reader.read(to: content)
        XCTAssertNotNil(content.expectedPointCount)
        XCTAssertTrue(content.didFinish)
        XCTAssertFalse(content.didFail)
        if let expectedPointCount = content.expectedPointCount {
            XCTAssertEqual(expectedPointCount, content.pointCount)
        }
    }

    func testReadFailsOnMissingProperties() throws {
        let url = try makeTempPLY(contents: """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        end_header
        0 0 0
        """)
        let reader = SplatPLYSceneReader(url)
        let content = ContentCounter()
        reader.read(to: content)
        XCTAssertTrue(content.didFail)
    }

    func testReadSucceedsWithoutNormals() throws {
        let url = try makeTempPLY(contents: """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 255 255 255 1 1 1 1 1 0 0 0
        """)
        let reader = SplatPLYSceneReader(url)
        let content = ContentCounter()
        reader.read(to: content)
        XCTAssertNotNil(content.expectedPointCount)
        XCTAssertTrue(content.didFinish)
        XCTAssertFalse(content.didFail)
    }

    private func makeTempPLY(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("temp.ply")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
