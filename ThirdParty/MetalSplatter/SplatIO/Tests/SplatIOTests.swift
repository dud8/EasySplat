import XCTest
import Spatial
import SplatIO

final class SplatIOTests: XCTestCase {
    class ContentCounter: SplatSceneReaderDelegate {
        var expectedPointCount: UInt32?
        var pointCount: UInt32 = 0
        var didFinish = false
        var didFail = false
        var failure: Error?

        func reset() {
            expectedPointCount = nil
            pointCount = 0
            didFinish = false
            didFail = false
            failure = nil
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
            failure = error
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

    func testReadRejectsSphericalHarmonicPropertiesWithoutIndexZero() throws {
        let properties = (1...45).map { "property float f_rest_\($0)" }
        let values = (1...45).map(String.init)
        let url = try makeSphericalHarmonicPLY(
            restProperties: properties,
            restValues: values
        )
        let content = ContentCounter()

        SplatPLYSceneReader(url).read(to: content)

        XCTAssertTrue(content.didFail)
        XCTAssertFalse(content.didFinish)
    }

    func testReadRejectsExtraSphericalHarmonicProperty() throws {
        let properties = (0...45).map { "property float f_rest_\($0)" }
        let values = (0...45).map(String.init)
        let url = try makeSphericalHarmonicPLY(
            restProperties: properties,
            restValues: values
        )
        let content = ContentCounter()

        SplatPLYSceneReader(url).read(to: content)

        XCTAssertTrue(content.didFail)
        XCTAssertFalse(content.didFinish)
    }

    func testReadRejectsSphericalHarmonicOutsideRendererRange() throws {
        let content = ContentCounter()
        let url = try makeSphericalHarmonicPLY(
            restValues: Array(repeating: "70000", count: 45)
        )

        SplatPLYSceneReader(url).read(to: content)

        XCTAssertEqual(
            content.failure as? SplatRenderEncodingValidationError,
            .unrepresentableSphericalHarmonic
        )
        XCTAssertFalse(content.didFinish)
    }

    func testReadRejectsGeometryOutsideRendererRange() throws {
        let cases: [(body: String, error: SplatRenderEncodingValidationError)] = [
            ("0 0 0 255 255 255 100 0 0 1 1 0 0 0", .nonFiniteScale),
            ("0 0 0 255 255 255 45 0 0 1 1 0 0 0", .nonFiniteCovariance),
            (
                "0 0 0 255 255 255 \(log(sqrt(66_000 as Float))) 0 0 1 1 0 0 0",
                .unrepresentableCovariance
            ),
            ("0 0 0 255 255 255 0 0 0 1 0 0 0 0", .degenerateRotation),
            ("0 0 0 255 255 255 0 0 0 1 0.0000000001 0 0 0", .degenerateRotation),
        ]

        for testCase in cases {
            let content = ContentCounter()
            let url = try makeLinearColorPLY(body: testCase.body)

            SplatPLYSceneReader(url).read(to: content)

            XCTAssertEqual(
                content.failure as? SplatRenderEncodingValidationError,
                testCase.error,
                "Unexpected result for \(testCase.body)"
            )
            XCTAssertFalse(content.didFinish)
        }
    }

    func testReadCanDeferRenderValidationToAnEncodingDelegate() throws {
        let content = ContentCounter()
        let url = try makeLinearColorPLY(
            body: "0 0 0 255 255 255 100 0 0 1 0 0 0 0"
        )

        SplatPLYSceneReader(
            url,
            validatesRenderEncoding: false
        ).read(to: content)

        XCTAssertTrue(content.didFinish)
        XCTAssertFalse(content.didFail)
        XCTAssertEqual(content.pointCount, 1)
    }

    private func makeTempPLY(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("temp.ply")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeSphericalHarmonicPLY(
        restProperties: [String] = (0..<45).map { "property float f_rest_\($0)" },
        restValues: [String]
    ) throws -> URL {
        precondition(restProperties.count == restValues.count)
        return try makeTempPLY(contents: """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        \(restProperties.joined(separator: "\n"))
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 0 0 0 \(restValues.joined(separator: " ")) 0 0 0 0 1 0 0 0
        """)
    }

    private func makeLinearColorPLY(body: String) throws -> URL {
        try makeTempPLY(contents: """
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
        \(body)
        """)
    }
}
