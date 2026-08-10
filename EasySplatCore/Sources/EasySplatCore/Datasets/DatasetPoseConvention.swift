import Foundation

/// Converts camera poses from imported dataset conventions into COLMAP's
/// world-to-camera convention. Every axis flip and sign decision for dataset
/// imports lives here so a convention fix is a one-line change with golden
/// test coverage, never a scattered hunt.
///
/// Conventions handled:
/// - Nerfstudio `transform_matrix`: camera-to-world, OpenGL camera basis
///   (+X right, +Y up, camera looks along -Z).
/// - Polycam keyframe `t_00..t_23`: camera-to-world, row-major 3x4, ARKit
///   camera basis (same axes as OpenGL).
/// - COLMAP `images.txt`: world-to-camera, +X right, +Y down, +Z forward,
///   rotation as a wxyz unit quaternion.
public enum DatasetPoseConvention {
    /// A world-to-camera pose in COLMAP's convention. The quaternion is unit
    /// length with a canonical sign (qw >= 0) so emitted models are
    /// deterministic and digest-stable.
    public struct ColmapPose: Sendable, Equatable {
        public let qw: Double
        public let qx: Double
        public let qy: Double
        public let qz: Double
        public let tx: Double
        public let ty: Double
        public let tz: Double

        public init(qw: Double, qx: Double, qy: Double, qz: Double, tx: Double, ty: Double, tz: Double) {
            self.qw = qw
            self.qx = qx
            self.qy = qy
            self.qz = qz
            self.tx = tx
            self.ty = ty
            self.tz = tz
        }
    }

    public enum ConversionError: Swift.Error, LocalizedError, Equatable {
        case malformedMatrix
        case nonFiniteValue
        case notARotation
        case mirroredRotation

        public var errorDescription: String? {
            switch self {
            case .malformedMatrix:
                return "A camera pose matrix does not have the expected 3x4 or 4x4 shape."
            case .nonFiniteValue:
                return "A camera pose contains a value that is not a finite number."
            case .notARotation:
                return "A camera pose rotation is not orthonormal."
            case .mirroredRotation:
                return "A camera pose rotation is mirrored, which no supported capture produces."
            }
        }
    }

    /// Tolerance for orthonormality of imported rotations. Float32 pipelines
    /// (ARKit, JSON round-trips) introduce noise around 1e-6; anything beyond
    /// this bound is a malformed export rather than precision loss.
    private static let orthonormalityTolerance = 1e-3

    /// Converts a Nerfstudio `transform_matrix` (rows of 4 columns, 3x4 or
    /// 4x4, camera-to-world in the OpenGL basis) to a COLMAP pose.
    public static func colmapPose(fromNerfstudioCameraToWorld rows: [[Double]]) throws -> ColmapPose {
        try colmapPose(fromOpenGLCameraToWorld: rows)
    }

    /// Converts a Polycam keyframe pose (`t_00..t_23`, row-major 3x4,
    /// camera-to-world in the ARKit basis) to a COLMAP pose.
    public static func colmapPose(fromPolycamCameraToWorld elements: [Double]) throws -> ColmapPose {
        guard elements.count == 12 else { throw ConversionError.malformedMatrix }
        let rows = [
            Array(elements[0..<4]),
            Array(elements[4..<8]),
            Array(elements[8..<12]),
        ]
        return try colmapPose(fromOpenGLCameraToWorld: rows)
    }

    /// Shared core: camera-to-world with an OpenGL-style camera basis
    /// (+X right, +Y up, -Z forward) to COLMAP world-to-camera
    /// (+X right, +Y down, +Z forward). The world frame is preserved as-is;
    /// reconstruction and training only require self-consistency, and the
    /// pipeline re-derives display orientation downstream.
    static func colmapPose(fromOpenGLCameraToWorld rows: [[Double]]) throws -> ColmapPose {
        guard rows.count == 3 || rows.count == 4, rows.allSatisfy({ $0.count == 4 }) else {
            throw ConversionError.malformedMatrix
        }
        if rows.count == 4 {
            let bottom = rows[3]
            guard bottom[0] == 0, bottom[1] == 0, bottom[2] == 0, bottom[3] == 1 else {
                throw ConversionError.malformedMatrix
            }
        }
        for row in rows where !row.allSatisfy({ $0.isFinite }) {
            throw ConversionError.nonFiniteValue
        }

        // Camera-to-world rotation columns are the camera axes in world
        // coordinates. Negating the Y and Z columns rebases the camera from
        // the OpenGL axes to COLMAP's (+Y down, +Z forward).
        var r = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            r[i][0] = rows[i][0]
            r[i][1] = -rows[i][1]
            r[i][2] = -rows[i][2]
        }
        let center = (rows[0][3], rows[1][3], rows[2][3])

        try validateRotation(r)

        // World-to-camera: transpose of the (orthonormal) rotation, and
        // t = -R_w2c * C.
        let rw2c = [
            [r[0][0], r[1][0], r[2][0]],
            [r[0][1], r[1][1], r[2][1]],
            [r[0][2], r[1][2], r[2][2]],
        ]
        let tx = -(rw2c[0][0] * center.0 + rw2c[0][1] * center.1 + rw2c[0][2] * center.2)
        let ty = -(rw2c[1][0] * center.0 + rw2c[1][1] * center.1 + rw2c[1][2] * center.2)
        let tz = -(rw2c[2][0] * center.0 + rw2c[2][1] * center.1 + rw2c[2][2] * center.2)

        let q = canonicalized(normalized(quaternion(fromRotation: rw2c)))
        return ColmapPose(qw: q.0, qx: q.1, qy: q.2, qz: q.3, tx: tx, ty: ty, tz: tz)
    }

    private static func validateRotation(_ r: [[Double]]) throws {
        // R * R^T must be identity within tolerance.
        for i in 0..<3 {
            for j in 0..<3 {
                let dot = r[i][0] * r[j][0] + r[i][1] * r[j][1] + r[i][2] * r[j][2]
                let expected = i == j ? 1.0 : 0.0
                guard abs(dot - expected) <= orthonormalityTolerance else {
                    throw ConversionError.notARotation
                }
            }
        }
        let det = r[0][0] * (r[1][1] * r[2][2] - r[1][2] * r[2][1])
            - r[0][1] * (r[1][0] * r[2][2] - r[1][2] * r[2][0])
            + r[0][2] * (r[1][0] * r[2][1] - r[1][1] * r[2][0])
        guard det > 0 else { throw ConversionError.mirroredRotation }
        guard abs(det - 1) <= orthonormalityTolerance else { throw ConversionError.notARotation }
    }

    /// Shepperd's method: numerically stable quaternion extraction picking the
    /// largest diagonal pivot.
    private static func quaternion(fromRotation m: [[Double]]) -> (Double, Double, Double, Double) {
        let trace = m[0][0] + m[1][1] + m[2][2]
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return (s / 4, (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s)
        }
        if m[0][0] >= m[1][1], m[0][0] >= m[2][2] {
            let s = (1 + m[0][0] - m[1][1] - m[2][2]).squareRoot() * 2
            return ((m[2][1] - m[1][2]) / s, s / 4, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s)
        }
        if m[1][1] >= m[2][2] {
            let s = (1 + m[1][1] - m[0][0] - m[2][2]).squareRoot() * 2
            return ((m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s, s / 4, (m[1][2] + m[2][1]) / s)
        }
        let s = (1 + m[2][2] - m[0][0] - m[1][1]).squareRoot() * 2
        return ((m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, s / 4)
    }

    private static func normalized(_ q: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
        let norm = (q.0 * q.0 + q.1 * q.1 + q.2 * q.2 + q.3 * q.3).squareRoot()
        return (q.0 / norm, q.1 / norm, q.2 / norm, q.3 / norm)
    }

    /// q and -q encode the same rotation; pick the representative with
    /// qw > 0 (ties broken by the first nonzero component) so output is
    /// byte-deterministic.
    private static func canonicalized(_ q: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
        var leading = q.0
        if leading == 0 { leading = q.1 }
        if leading == 0 { leading = q.2 }
        if leading == 0 { leading = q.3 }
        if leading < 0 {
            return (-q.0, -q.1, -q.2, -q.3)
        }
        // Normalize a negative zero in qw so formatting stays stable.
        if q.0 == 0 {
            return (0, q.1, q.2, q.3)
        }
        return q
    }
}
