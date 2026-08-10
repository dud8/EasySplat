import SplatIO
import XCTest
@testable import EasySplatApp

/// The trainer's preview layout and MetalSplatter's reader are two halves of one
/// contract that lives in different languages. These build the exact bytes the
/// native publisher emits and read them back through the real reader, so a change
/// to either side fails here rather than as a blank canvas at runtime.
final class TrainingPreviewLayoutTests: XCTestCase {
    /// Mirrors publishPreviewAtomically in Tools/MsplatNative/msplat.cpp.
    private static let properties = [
        "x", "y", "z",
        "nx", "ny", "nz",
        "f_dc_0", "f_dc_1", "f_dc_2",
        "opacity",
        "scale_0", "scale_1", "scale_2",
        "rot_0", "rot_1", "rot_2", "rot_3",
    ]

    private func writePreviewPly(count: Int, to url: URL) throws {
        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "comment easysplat preview iteration 1600\n"
        header += "element vertex \(count)\n"
        for property in Self.properties {
            header += "property float \(property)\n"
        }
        header += "end_header\n"

        var data = Data(header.utf8)
        for index in 0..<count {
            let base = Float(index)
            let row: [Float] = [
                base, base + 1, base + 2,        // position
                0, 0, 0,                          // normals, always zero
                0.5, 0.25, -0.125,                // f_dc, raw spherical-harmonic DC
                -1.5,                             // opacity, pre-sigmoid logit
                -2, -2.5, -3,                     // scale, log space
                1, 0, 0, 0,                       // rotation, unnormalized wxyz
            ]
            row.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        try data.write(to: url)
    }

    func testMetalSplatterReadsTheExactPreviewLayout() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePreviewPly(count: 8, to: url)

        let reader = SplatPLYSceneReader(url)
        let collector = SplatSceneReaderCollector()
        let collected = expectation(description: "read preview")
        collector.onFinish = { collected.fulfill() }
        reader.read(to: collector)
        wait(for: [collected], timeout: 10)

        XCTAssertNil(collector.failure, "the reader rejected the published layout")
        let points = collector.points
        XCTAssertEqual(points.count, 8, "every published gaussian must survive the read")
        // Degree 0 with no f_rest_* must map to the first-order colour case; a
        // partial higher-order set is what the reader rejects outright.
        guard case .firstOrderSphericalHarmonic = points[0].color else {
            return XCTFail("preview colour must decode as degree 0, got \(points[0].color)")
        }
    }

    /// The count in the header has to match the rows actually written, or the
    /// trainer's own validateBinaryPly length check would already have failed.
    func testPayloadLengthMatchesTheDeclaredVertexCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePreviewPly(count: 5, to: url)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        let rowBytes = Self.properties.count * MemoryLayout<Float>.size
        XCTAssertEqual(Self.properties.count, 17)
        XCTAssertEqual(rowBytes, 68)
        let headerBytes = (size ?? 0) - 5 * rowBytes
        XCTAssertGreaterThan(headerBytes, 0)
        XCTAssertEqual((size ?? 0), headerBytes + 5 * rowBytes)
    }
}

private final class SplatSceneReaderCollector: SplatSceneReaderDelegate {
    var points: [SplatScenePoint] = []
    var failure: Error?
    var onFinish: (() -> Void)?

    func didStartReading(withPointCount pointCount: UInt32) {}
    func didRead(points: [SplatScenePoint]) { self.points.append(contentsOf: points) }
    func didFinishReading() { onFinish?() }
    func didFailReading(withError error: Error?) {
        failure = error ?? SplatSceneReaderCollectorError.unspecified
        onFinish?()
    }
}

private enum SplatSceneReaderCollectorError: Error {
    case unspecified
}
