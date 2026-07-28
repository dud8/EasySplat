import Foundation

/// Orders the splat draw sequence by depth, in linear time and independently of how nearly
/// sorted the previous frame left it.
///
/// Each element is one `UInt64`: an order-preserving image of the Float32 sort key in the
/// high 32 bits, the splat index in the low 32. Only the key half is ever examined, so equal
/// keys keep the order they arrived in -- and since the array is built in index order, the
/// published draw order is a pure function of the camera and the scene. A comparison sort
/// gives no such guarantee: a real scene holds more splats than the key has distinguishable
/// Float32 values, so keys collide in the thousands, and `Array.sort` is not stable.
///
/// The linear cost is the point. A comparison sort's running time depends on the disorder of
/// its input, and the input here is the previous frame's output: a rotation-invariant key
/// leaves it almost sorted, a key that tracks the camera does not. That is the whole reason
/// the two orderings had such different sort latencies at the same splat count.
enum SplatDepthRadixSort {
    private static let radixBits = 8
    private static let buckets = 1 << radixBits
    private static let bucketMask = UInt64(buckets - 1)
    /// The four byte positions of the key half.
    private static let shifts = [32, 40, 48, 56]

    /// Maps a Float32 onto a `UInt32` whose unsigned ordering matches the float's ordering.
    /// Positives get their sign bit set; negatives are inverted whole, which reverses the
    /// descending order that sign-magnitude gives them. Undefined for NaN, which cannot
    /// reach here: positions are validated finite at load and the keys are a dot product and
    /// a squared length of finite values.
    @inline(__always)
    static func orderPreservingBits(_ value: Float) -> UInt32 {
        let bits = value.bitPattern
        return (bits & 0x8000_0000) != 0 ? ~bits : (bits | 0x8000_0000)
    }

    @inline(__always)
    static func pack(key: Float, index: UInt32) -> UInt64 {
        UInt64(orderPreservingBits(key)) << 32 | UInt64(index)
    }

    @inline(__always)
    static func index(of packed: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: packed)
    }

    /// Sorts `keys` ascending in place. `scratch` must hold at least `count` elements; its
    /// contents afterwards are undefined.
    static func sort(
        _ keys: UnsafeMutablePointer<UInt64>,
        scratch: UnsafeMutablePointer<UInt64>,
        count: Int
    ) {
        guard count > 1 else { return }

        // One pass builds every histogram. Reading the array four times to count would cost
        // more than the scatters do.
        var histograms = [Int](repeating: 0, count: buckets * shifts.count)
        histograms.withUnsafeMutableBufferPointer { counts in
            for element in 0..<count {
                let packed = keys[element]
                for (digit, shift) in shifts.enumerated() {
                    counts[digit * buckets + Int((packed >> UInt64(shift)) & bucketMask)] += 1
                }
            }

            var source = keys
            var destination = scratch
            for (digit, shift) in shifts.enumerated() {
                let base = digit * buckets
                // A digit every element shares carries no information; skipping it saves a
                // full scatter, which is what makes a narrow depth range cheap.
                if counts[base + Int((source[0] >> UInt64(shift)) & bucketMask)] == count {
                    continue
                }
                var offset = 0
                for bucket in 0..<buckets {
                    let size = counts[base + bucket]
                    counts[base + bucket] = offset
                    offset += size
                }
                for element in 0..<count {
                    let packed = source[element]
                    let bucket = base + Int((packed >> UInt64(shift)) & bucketMask)
                    destination[counts[bucket]] = packed
                    counts[bucket] += 1
                }
                swap(&source, &destination)
            }
            // An odd number of scatters leaves the result in the scratch buffer.
            if source != keys {
                keys.update(from: source, count: count)
            }
        }
    }
}
