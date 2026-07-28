import Foundation
import PLYIO
import simd

/// The chunked PLY layout that SuperSplat and the PlayCanvas engine write.
///
/// It is still a PLY, so the header and element streaming are unchanged; what differs is
/// that a `vertex` carries four packed `uint32`s instead of float positions, and the real
/// range lives in a `chunk` element covering 256 vertices at a time. Without this a
/// perfectly ordinary `.ply` saved out of SuperSplat fails to open.
struct CompressedPLYMapping {
    static let verticesPerChunk = 256

    /// The 10-bit quaternion components cover [-1/√2, 1/√2], which is the widest any
    /// non-largest component can be once the largest has been factored out.
    private static let quaternionComponentScale = Float(2.0).squareRoot()

    struct ChunkRange {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>

        func lerp(_ t: SIMD3<Float>) -> SIMD3<Float> {
            minimum + (maximum - minimum) * t
        }
    }

    struct Chunk {
        var position: ChunkRange
        var scale: ChunkRange
        var color: ChunkRange?
    }

    let chunkElementTypeIndex: Int
    let vertexElementTypeIndex: Int

    let minPositionIndices: SIMD3<Int>
    let maxPositionIndices: SIMD3<Int>
    let minScaleIndices: SIMD3<Int>
    let maxScaleIndices: SIMD3<Int>
    let minColorIndices: SIMD3<Int>?
    let maxColorIndices: SIMD3<Int>?

    let packedPositionIndex: Int
    let packedRotationIndex: Int
    let packedScaleIndex: Int
    let packedColorIndex: Int

    /// Returns nil when the header is an ordinary uncompressed splat PLY, so the caller
    /// can fall back rather than treating a normal file as malformed.
    static func mapping(for header: PLYHeader) throws -> CompressedPLYMapping? {
        guard let chunkElementTypeIndex = header.index(forElementNamed: "chunk"),
              let vertexElementTypeIndex = header.index(forElementNamed: "vertex") else {
            return nil
        }
        let vertex = header.elements[vertexElementTypeIndex]
        guard vertex.hasProperty(forName: ["packed_position"]) else { return nil }

        let chunk = header.elements[chunkElementTypeIndex]
        func chunkAxes(_ prefix: String) throws -> SIMD3<Int> {
            SIMD3(
                try chunk.index(forFloat32PropertyNamed: ["\(prefix)_x"]),
                try chunk.index(forFloat32PropertyNamed: ["\(prefix)_y"]),
                try chunk.index(forFloat32PropertyNamed: ["\(prefix)_z"])
            )
        }
        func optionalChunkChannels(_ prefix: String) throws -> SIMD3<Int>? {
            guard let r = try chunk.index(forOptionalFloat32PropertyNamed: ["\(prefix)_r"]),
                  let g = try chunk.index(forOptionalFloat32PropertyNamed: ["\(prefix)_g"]),
                  let b = try chunk.index(forOptionalFloat32PropertyNamed: ["\(prefix)_b"]) else {
                return nil
            }
            return SIMD3(r, g, b)
        }

        func packed(_ name: String) throws -> Int {
            try vertex.index(forPropertyNamed: [name], type: .uint32)
        }

        return CompressedPLYMapping(
            chunkElementTypeIndex: chunkElementTypeIndex,
            vertexElementTypeIndex: vertexElementTypeIndex,
            minPositionIndices: try chunkAxes("min"),
            maxPositionIndices: try chunkAxes("max"),
            minScaleIndices: try chunkAxes("min_scale"),
            maxScaleIndices: try chunkAxes("max_scale"),
            minColorIndices: try optionalChunkChannels("min"),
            maxColorIndices: try optionalChunkChannels("max"),
            packedPositionIndex: try packed("packed_position"),
            packedRotationIndex: try packed("packed_rotation"),
            packedScaleIndex: try packed("packed_scale"),
            packedColorIndex: try packed("packed_color")
        )
    }

    func chunk(from element: PLYElement) throws -> Chunk {
        func read(_ indices: SIMD3<Int>) throws -> SIMD3<Float> {
            SIMD3(
                try element.float32Value(forPropertyIndex: indices.x),
                try element.float32Value(forPropertyIndex: indices.y),
                try element.float32Value(forPropertyIndex: indices.z)
            )
        }
        var color: ChunkRange?
        if let minColorIndices, let maxColorIndices {
            color = ChunkRange(
                minimum: try read(minColorIndices),
                maximum: try read(maxColorIndices)
            )
        }
        return Chunk(
            position: ChunkRange(minimum: try read(minPositionIndices), maximum: try read(maxPositionIndices)),
            scale: ChunkRange(minimum: try read(minScaleIndices), maximum: try read(maxScaleIndices)),
            color: color
        )
    }

    func apply(from element: PLYElement, in chunk: Chunk, to point: inout SplatScenePoint) throws {
        let position = try element.uint32Value(forPropertyIndex: packedPositionIndex)
        let rotation = try element.uint32Value(forPropertyIndex: packedRotationIndex)
        let scale = try element.uint32Value(forPropertyIndex: packedScaleIndex)
        let color = try element.uint32Value(forPropertyIndex: packedColorIndex)

        point.position = chunk.position.lerp(Self.unpack11_10_11(position))
        // These are log scales, the same quantity an uncompressed splat PLY stores in
        // scale_0..2, so no exponentiation belongs here.
        point.scale = chunk.scale.lerp(Self.unpack11_10_11(scale))
        point.rotation = Self.unpackRotation(rotation)
        point.normal = .zero

        var rgb = SIMD3<Float>(
            Float((color >> 24) & 0xFF),
            Float((color >> 16) & 0xFF),
            Float((color >> 8) & 0xFF)
        ) / 255
        if let range = chunk.color {
            rgb = range.lerp(rgb)
        }
        point.color = .linearFloat(rgb.x * 255, rgb.y * 255, rgb.z * 255)

        // The packed alpha is the post-sigmoid opacity; SplatScenePoint carries the logit.
        let alpha = Float(color & 0xFF) / 255
        point.opacity = Self.inverseSigmoid(alpha)
    }

    static func unpack11_10_11(_ value: UInt32) -> SIMD3<Float> {
        SIMD3(
            Float((value >> 21) & 0x7FF) / 2047,
            Float((value >> 11) & 0x3FF) / 1023,
            Float(value & 0x7FF) / 2047
        )
    }

    static func unpackRotation(_ value: UInt32) -> simd_quatf {
        let scale = quaternionComponentScale
        let a = (Float((value >> 20) & 0x3FF) / 1023 - 0.5) * scale
        let b = (Float((value >> 10) & 0x3FF) / 1023 - 0.5) * scale
        let c = (Float(value & 0x3FF) / 1023 - 0.5) * scale
        // Quantization can push the three stored components just past unit length, and
        // the square root of a negative would hand the renderer a NaN quaternion.
        let m = max(0, 1 - (a * a + b * b + c * c)).squareRoot()
        let largest = (value >> 30) & 0x3
        // The dropped component is the largest one, restored from unit length. Order is
        // (w, x, y, z) to match rot_0..rot_3 in an uncompressed splat PLY.
        return switch largest {
        case 0: simd_quatf(real: m, imag: SIMD3(a, b, c))
        case 1: simd_quatf(real: a, imag: SIMD3(m, b, c))
        case 2: simd_quatf(real: a, imag: SIMD3(b, m, c))
        default: simd_quatf(real: a, imag: SIMD3(b, c, m))
        }
    }

    /// Bounded so a fully opaque or fully transparent splat cannot produce a non-finite
    /// logit, which the render encoder rejects outright.
    static func inverseSigmoid(_ value: Float) -> Float {
        let clamped = min(max(value, 1e-6), 1 - 1e-6)
        return Foundation.log(clamped / (1 - clamped))
    }
}
