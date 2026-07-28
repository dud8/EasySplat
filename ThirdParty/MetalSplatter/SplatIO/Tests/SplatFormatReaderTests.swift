import Foundation
import XCTest
import simd
@testable import SplatIO

private final class Collector: SplatSceneReaderDelegate {
    var points: [SplatScenePoint] = []
    var declaredCount: UInt32?
    var finished = false
    var failure: Error?

    func didStartReading(withPointCount pointCount: UInt32) { declaredCount = pointCount }
    func didRead(points: [SplatScenePoint]) { self.points.append(contentsOf: points) }
    func didFinishReading() { finished = true }
    func didFailReading(withError error: Error?) { failure = error ?? CancellationError() }
}

/// Round trips for the containers added alongside the uncompressed splat PLY. Each one
/// packs known values by hand and requires the reader to recover them, because a
/// mis-decoded bit field produces a plausible-looking scene rather than an error.
final class SplatFormatReaderTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - .splat

    func testBinarySplatRoundTripsAKnownRecord() throws {
        let url = base.appendingPathComponent("scene.splat")
        var data = Data()
        appendFloats(&data, [1.5, -2.5, 3.25])          // position
        appendFloats(&data, [0.5, 0.25, 2])             // linear scale
        data.append(contentsOf: [10, 20, 30, 204])      // rgba
        data.append(contentsOf: [255, 128, 128, 128])   // rotation w,x,y,z
        try data.write(to: url)

        let collector = Collector()
        SplatBinarySceneReader(url).read(to: collector)

        XCTAssertNil(collector.failure)
        XCTAssertTrue(collector.finished)
        XCTAssertEqual(collector.declaredCount, 1)
        let point = try XCTUnwrap(collector.points.first)

        XCTAssertEqual(point.position, SIMD3(1.5, -2.5, 3.25))
        // Stored linearly, surfaced as log scale.
        XCTAssertEqual(point.scale.x, Foundation.log(0.5), accuracy: 1e-5)
        XCTAssertEqual(point.scale.z, Foundation.log(2), accuracy: 1e-5)
        guard case let .linearUInt8(r, g, b) = point.color else {
            return XCTFail("Expected a rendered base colour")
        }
        XCTAssertEqual([r, g, b], [10, 20, 30])
        // 204/255 = 0.8 opacity, carried as its logit.
        XCTAssertEqual(point.opacity, Foundation.log(0.8 / 0.2), accuracy: 1e-3)
        XCTAssertEqual(point.rotation.real, (255 - 128) / 128, accuracy: 1e-6)
        XCTAssertEqual(point.rotation.imag.x, 0, accuracy: 1e-6)
    }

    func testBinarySplatRejectsATruncatedRecord() throws {
        let url = base.appendingPathComponent("short.splat")
        try Data(repeating: 0, count: 40).write(to: url)

        let collector = Collector()
        SplatBinarySceneReader(url).read(to: collector)

        XCTAssertEqual(collector.failure as? SplatBinarySceneReader.Error, .truncatedRecord(40))
        XCTAssertFalse(collector.finished)
    }

    func testBinarySplatRejectsAnEmptyFile() throws {
        let url = base.appendingPathComponent("empty.splat")
        try Data().write(to: url)

        let collector = Collector()
        SplatBinarySceneReader(url).read(to: collector)

        XCTAssertEqual(collector.failure as? SplatBinarySceneReader.Error, .emptyFile)
    }

    // MARK: - compressed PLY

    func testCompressedPLYDequantizesAgainstItsChunk() throws {
        let url = base.appendingPathComponent("compressed.ply")
        // Midpoint in every packed field, so each value must land halfway through the
        // chunk range. An off-by-one bit field would move it off centre.
        let position = pack11_10_11(2047 / 2, 1023 / 2, 2047 / 2)
        let scale = pack11_10_11(0, 0, 2047)
        let rotation = (UInt32(0) << 30) | (511 << 20) | (511 << 10) | 511
        let color: UInt32 = (10 << 24) | (20 << 16) | (30 << 8) | 204

        var body = Data()
        appendFloats(&body, [-1, -2, -3, 1, 2, 3])                  // position range
        appendFloats(&body, [-4, -4, -4, -1, -1, -1])               // log-scale range
        appendUInt32s(&body, [position, rotation, scale, color])
        try (compressedHeader(chunks: 1, vertices: 1) + body).write(to: url)

        let collector = Collector()
        SplatPLYSceneReader(url, validatesRenderEncoding: false).read(to: collector)

        XCTAssertNil(collector.failure)
        XCTAssertTrue(collector.finished)
        let point = try XCTUnwrap(collector.points.first)

        XCTAssertEqual(point.position.x, 0, accuracy: 0.01)
        XCTAssertEqual(point.position.y, 0, accuracy: 0.01)
        XCTAssertEqual(point.position.z, 0, accuracy: 0.01)
        XCTAssertEqual(point.scale.x, -4, accuracy: 0.01)
        XCTAssertEqual(point.scale.z, -1, accuracy: 0.01)
        XCTAssertEqual(point.opacity, Foundation.log(0.8 / 0.2), accuracy: 1e-3)
        // Mid-range 10-bit components decode to ~0, so the dropped largest component
        // carries the whole rotation.
        XCTAssertEqual(point.rotation.real, 1, accuracy: 0.01)
        XCTAssertEqual(simd_length(point.rotation.imag), 0, accuracy: 0.01)
    }

    func testCompressedPLYRefusesAVertexWithNoChunk() throws {
        let url = base.appendingPathComponent("chunkless.ply")
        var body = Data()
        appendUInt32s(&body, [0, 0, 0, 0])
        try (compressedHeader(chunks: 0, vertices: 1) + body).write(to: url)

        let collector = Collector()
        SplatPLYSceneReader(url, validatesRenderEncoding: false).read(to: collector)

        XCTAssertNotNil(collector.failure)
        XCTAssertFalse(collector.finished)
    }

    func testUncompressedPLYStillTakesTheOriginalPath() throws {
        let url = base.appendingPathComponent("plain.ply")
        let text = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        1 2 3 0.1 0.2 0.3 -4 -4 -4 1 1 0 0 0
        """
        try text.write(to: url, atomically: true, encoding: .utf8)

        let collector = Collector()
        SplatPLYSceneReader(url, validatesRenderEncoding: false).read(to: collector)

        XCTAssertNil(collector.failure)
        let point = try XCTUnwrap(collector.points.first)
        XCTAssertEqual(point.position, SIMD3(1, 2, 3))
    }

    // Three components at full scale exceed unit length, so the dropped component's
    // square root goes negative. A NaN quaternion would reach the renderer looking like
    // ordinary geometry, so it has to be clamped rather than propagated.
    func testCompressedPLYRotationStaysFiniteWhenComponentsOverflowUnitLength() {
        let packed = (UInt32(0) << 30) | (1023 << 20) | (1023 << 10) | 1023

        let rotation = CompressedPLYMapping.unpackRotation(packed)

        XCTAssertTrue(rotation.real.isFinite)
        XCTAssertTrue(rotation.imag.x.isFinite)
        XCTAssertTrue(rotation.imag.y.isFinite)
        XCTAssertTrue(rotation.imag.z.isFinite)
        XCTAssertEqual(rotation.real, 0, accuracy: 1e-6)
    }

    func testInverseSigmoidStaysFiniteAtTheExtremes() {
        XCTAssertTrue(CompressedPLYMapping.inverseSigmoid(0).isFinite)
        XCTAssertTrue(CompressedPLYMapping.inverseSigmoid(1).isFinite)
        XCTAssertEqual(CompressedPLYMapping.inverseSigmoid(0.5), 0, accuracy: 1e-6)
    }

    // MARK: - factory

    func testFactoryPicksAReaderByExtension() throws {
        XCTAssertTrue(
            try SplatSceneReaderFactory.reader(for: URL(fileURLWithPath: "/tmp/a.ply"))
                is SplatPLYSceneReader
        )
        XCTAssertTrue(
            try SplatSceneReaderFactory.reader(for: URL(fileURLWithPath: "/tmp/a.splat"))
                is SplatBinarySceneReader
        )
        XCTAssertThrowsError(
            try SplatSceneReaderFactory.reader(for: URL(fileURLWithPath: "/tmp/a.spz"))
        ) { error in
            XCTAssertEqual(
                error as? SplatSceneReaderFactory.Error,
                .unsupportedFormat("spz")
            )
        }
    }

    // MARK: - helpers

    private func pack11_10_11(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        ((x & 0x7FF) << 21) | ((y & 0x3FF) << 11) | (z & 0x7FF)
    }

    private func appendFloats(_ data: inout Data, _ values: [Float]) {
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    private func appendUInt32s(_ data: inout Data, _ values: [UInt32]) {
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    private func compressedHeader(chunks: Int, vertices: Int) -> Data {
        let text = """
        ply
        format binary_little_endian 1.0
        element chunk \(chunks)
        property float min_x
        property float min_y
        property float min_z
        property float max_x
        property float max_y
        property float max_z
        property float min_scale_x
        property float min_scale_y
        property float min_scale_z
        property float max_scale_x
        property float max_scale_y
        property float max_scale_z
        element vertex \(vertices)
        property uint packed_position
        property uint packed_rotation
        property uint packed_scale
        property uint packed_color
        end_header

        """
        return Data(text.utf8)
    }
}
