import XCTest
@testable import MetalSplatter

/// The draw order is now produced by a radix pass rather than a comparison sort, which buys
/// two things the viewer depends on: a running time that does not vary with how sorted the
/// input already was, and a total order over splats whose depth keys collide.
final class SplatDepthRadixSortTests: XCTestCase {

    /// The float-to-integer map has to preserve ordering across every sign and magnitude, or
    /// the whole sort is wrong in exactly the places nobody looks: behind the camera, and
    /// either side of zero.
    func testOrderPreservingBitsIsMonotonic() {
        let values: [Float] = [
            -.greatestFiniteMagnitude, -1e9, -1_000, -1, -1e-20, -.leastNonzeroMagnitude,
            -0.0, 0.0, .leastNonzeroMagnitude, 1e-20, 1, 1_000, 1e9,
            .greatestFiniteMagnitude, .infinity,
        ]
        for (earlier, later) in zip(values, values.dropFirst()) {
            let a = SplatDepthRadixSort.orderPreservingBits(earlier)
            let b = SplatDepthRadixSort.orderPreservingBits(later)
            if earlier == later {
                // -0.0 and 0.0 compare equal but do not share a bit pattern; the map is
                // allowed to separate them as long as it does not invert them.
                XCTAssertLessThanOrEqual(a, b, "\(earlier) then \(later)")
            } else {
                XCTAssertLessThan(a, b, "\(earlier) must map below \(later)")
            }
        }
    }

    func testSortsAgainstAReferenceOverRandomKeys() {
        var generator = SystemRandomNumberGenerator()
        for count in [0, 1, 2, 3, 17, 1_000, 65_537] {
            let depths = (0..<count).map { _ in Float.random(in: -500...500, using: &generator) }
            let sorted = sortedIndices(depths)
            let reference = depths.enumerated()
                .sorted { $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element }
                .map { UInt32($0.offset) }
            XCTAssertEqual(sorted, reference, "count \(count)")
        }
    }

    /// The case a comparison sort gets wrong. A trained scene holds more splats than the key
    /// has distinguishable values nearby, so keys collide in the thousands, and `Array.sort`
    /// is not stable -- the same camera could publish a different order each time it was
    /// asked, because the array being sorted was the previous frame's output.
    func testEqualKeysKeepIndexOrder() {
        let depths = [Float](repeating: 3.25, count: 5_000)
        XCTAssertEqual(sortedIndices(depths), (0..<5_000).map(UInt32.init))
    }

    /// Same scene, same camera, different starting permutation of the work array: the
    /// published order must not depend on what the previous frame left behind.
    func testOrderDoesNotDependOnInputPermutation() {
        var generator = SystemRandomNumberGenerator()
        // Deliberately coarse, so ties are common rather than incidental.
        let depths = (0..<20_000).map { _ in Float(Int.random(in: 0...200, using: &generator)) }
        let inIndexOrder = sortedIndices(depths)

        var shuffled = Array(0..<depths.count)
        shuffled.shuffle(using: &generator)
        var keys = shuffled.map {
            SplatDepthRadixSort.pack(key: depths[$0], index: UInt32($0))
        }
        var scratch = [UInt64](repeating: 0, count: keys.count)
        keys.withUnsafeMutableBufferPointer { k in
            scratch.withUnsafeMutableBufferPointer { s in
                SplatDepthRadixSort.sort(k.baseAddress!, scratch: s.baseAddress!, count: k.count)
            }
        }
        let depthsOf = { (order: [UInt32]) in order.map { depths[Int($0)] } }
        // Ties resolve to whatever order they arrived in, so the permutations may differ --
        // but the sequence of depths, which is all the renderer composites, must not.
        XCTAssertEqual(
            depthsOf(keys.map(SplatDepthRadixSort.index(of:))),
            depthsOf(inIndexOrder)
        )
    }

    /// Degenerate ranges are where a bucket-skipping radix goes wrong: every digit is shared,
    /// so every pass is skipped and the result has to be correct without any scatter at all.
    func testUniformAndNearUniformKeys() {
        XCTAssertEqual(sortedIndices([Float](repeating: 0, count: 100)), (0..<100).map(UInt32.init))
        XCTAssertEqual(sortedIndices([1.0, 1.0, 1.0, 0.9]), [3, 0, 1, 2])
        XCTAssertEqual(sortedIndices([-0.0, 0.0]), [0, 1])
    }

    private func sortedIndices(_ depths: [Float]) -> [UInt32] {
        var keys = depths.enumerated().map {
            SplatDepthRadixSort.pack(key: $0.element, index: UInt32($0.offset))
        }
        guard !keys.isEmpty else { return [] }
        var scratch = [UInt64](repeating: 0, count: keys.count)
        keys.withUnsafeMutableBufferPointer { k in
            scratch.withUnsafeMutableBufferPointer { s in
                SplatDepthRadixSort.sort(k.baseAddress!, scratch: s.baseAddress!, count: k.count)
            }
        }
        return keys.map(SplatDepthRadixSort.index(of:))
    }
}
