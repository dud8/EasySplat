import Foundation
import simd

/// The flat `.splat` container used by antimatter15's viewer and most web players.
///
/// Fixed 32-byte records, no header and no compression, so the point count is the file
/// length divided by the record size. Colour is the rendered base colour rather than an
/// SH coefficient and there are no higher-order bands, so a `.splat` is view-independent
/// by construction.
public class SplatBinarySceneReader: SplatSceneReader {
    public enum Error: LocalizedError, Equatable {
        case cannotOpenSource
        case emptyFile
        case truncatedRecord(UInt64)

        public var errorDescription: String? {
            switch self {
            case .cannotOpenSource:
                "The splat file could not be opened."
            case .emptyFile:
                "The splat file contains no gaussians."
            case .truncatedRecord(let length):
                "The splat file is \(length) bytes, which is not a whole number of "
                    + "\(SplatBinarySceneReader.bytesPerPoint)-byte records."
            }
        }
    }

    static let bytesPerPoint = 32
    /// Points handed to the delegate per batch. Keeps peak memory flat regardless of file
    /// size, matching how the PLY reader streams.
    private static let batchSize = 8192

    private let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public func read(to delegate: SplatSceneReaderDelegate) {
        read(to: delegate, shouldCancel: { false })
    }

    public func read(
        to delegate: SplatSceneReaderDelegate,
        shouldCancel: @escaping @Sendable () -> Bool
    ) {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let length = try handle.seekToEnd()
            guard length > 0 else { throw Error.emptyFile }
            guard length % UInt64(Self.bytesPerPoint) == 0 else {
                throw Error.truncatedRecord(length)
            }
            let pointCount = length / UInt64(Self.bytesPerPoint)
            guard let expectedPointCount = UInt32(exactly: pointCount) else {
                throw Error.truncatedRecord(length)
            }
            try handle.seek(toOffset: 0)
            delegate.didStartReading(withPointCount: expectedPointCount)

            var remaining = Int(expectedPointCount)
            while remaining > 0 {
                if shouldCancel() {
                    delegate.didFailReading(withError: CancellationError())
                    return
                }
                let batch = min(remaining, Self.batchSize)
                guard let data = try handle.read(upToCount: batch * Self.bytesPerPoint),
                      data.count == batch * Self.bytesPerPoint else {
                    throw Error.truncatedRecord(length)
                }
                delegate.didRead(points: Self.points(in: data, count: batch))
                remaining -= batch
            }
            delegate.didFinishReading()
        } catch let error as Error {
            delegate.didFailReading(withError: error)
        } catch {
            delegate.didFailReading(withError: error)
        }
    }

    static func points(in data: Data, count: Int) -> [SplatScenePoint] {
        data.withUnsafeBytes { raw -> [SplatScenePoint] in
            (0..<count).map { index in
                let base = index * bytesPerPoint
                func float(_ offset: Int) -> Float {
                    // The file is little-endian regardless of host, so convert *from*
                    // little-endian rather than to it.
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                        fromByteOffset: base + offset,
                        as: UInt32.self
                    )))
                }
                func byte(_ offset: Int) -> UInt8 {
                    raw.loadUnaligned(fromByteOffset: base + offset, as: UInt8.self)
                }

                // Scales are stored linearly here; SplatScenePoint carries log scale.
                let scale = SIMD3<Float>(float(12), float(16), float(20))
                let logScale = SIMD3<Float>(
                    Foundation.log(max(scale.x, .leastNormalMagnitude)),
                    Foundation.log(max(scale.y, .leastNormalMagnitude)),
                    Foundation.log(max(scale.z, .leastNormalMagnitude))
                )

                // Quaternion components are stored as (q * 128) + 128 in w, x, y, z order.
                func component(_ offset: Int) -> Float {
                    (Float(byte(offset)) - 128) / 128
                }
                let rotation = simd_quatf(
                    real: component(28),
                    imag: SIMD3(component(29), component(30), component(31))
                )

                return SplatScenePoint(
                    position: SIMD3(float(0), float(4), float(8)),
                    normal: .zero,
                    // Already a rendered base colour, not an SH coefficient.
                    color: .linearUInt8(byte(24), byte(25), byte(26)),
                    opacity: CompressedPLYMapping.inverseSigmoid(Float(byte(27)) / 255),
                    scale: logScale,
                    rotation: rotation
                )
            }
        }
    }
}
