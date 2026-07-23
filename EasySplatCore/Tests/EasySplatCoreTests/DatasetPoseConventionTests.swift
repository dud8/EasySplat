import Foundation
import XCTest
@testable import EasySplatCore

final class DatasetPoseConventionTests: XCTestCase {
    // An identity Nerfstudio camera-to-world (camera at the origin, OpenGL
    // axes aligned with the world) is a 180-degree rotation about X in
    // COLMAP's convention: hand-computed golden values.
    func testIdentityCameraToWorldBecomesXFlip() throws {
        let pose = try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ])
        XCTAssertEqual(pose.qw, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.qx, 1, accuracy: 1e-12)
        XCTAssertEqual(pose.qy, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.qz, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.tx, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.ty, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.tz, 0, accuracy: 1e-12)
    }

    func testTranslationUsesNegatedRotatedCameraCenter() throws {
        let pose = try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
            [1, 0, 0, 1],
            [0, 1, 0, 2],
            [0, 0, 1, 3],
        ])
        // R_w2c = diag(1,-1,-1), so t = -R_w2c * (1,2,3) = (-1, 2, 3).
        XCTAssertEqual(pose.tx, -1, accuracy: 1e-12)
        XCTAssertEqual(pose.ty, 2, accuracy: 1e-12)
        XCTAssertEqual(pose.tz, 3, accuracy: 1e-12)
    }

    // Camera looking along +X world with +Y world up. Hand-derived:
    // world-to-camera rotation [[0,0,1],[0,-1,0],[1,0,0]] whose quaternion is
    // (0, sqrt(2)/2, 0, sqrt(2)/2).
    func testCameraLookingAlongWorldXGolden() throws {
        let pose = try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
            [0, 0, -1, 0],
            [0, 1, 0, 0],
            [1, 0, 0, 0],
            [0, 0, 0, 1],
        ])
        let half = (2.0).squareRoot() / 2
        XCTAssertEqual(pose.qw, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.qx, half, accuracy: 1e-12)
        XCTAssertEqual(pose.qy, 0, accuracy: 1e-12)
        XCTAssertEqual(pose.qz, half, accuracy: 1e-12)
    }

    func testPolycamRowMajorElementsMatchNerfstudioMatrixForm() throws {
        let rows: [[Double]] = [
            [0, 0, -1, 4],
            [0, 1, 0, 5],
            [1, 0, 0, 6],
        ]
        let fromMatrix = try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: rows)
        let fromElements = try DatasetPoseConvention.colmapPose(
            fromPolycamCameraToWorld: rows.flatMap { $0 }
        )
        XCTAssertEqual(fromMatrix, fromElements)
    }

    func testRoundTripThroughQuaternionRebuildsRotation() throws {
        // Compose an arbitrary rotation from axis-angle, run the conversion,
        // and verify the emitted quaternion reproduces the same
        // world-to-camera matrix.
        let angle = 0.7
        let axis = normalize((0.3, -0.5, 0.8))
        let rGL = rotationMatrix(axis: axis, angle: angle)
        let center = (1.5, -2.0, 0.25)
        let rows = [
            [rGL[0][0], rGL[0][1], rGL[0][2], center.0],
            [rGL[1][0], rGL[1][1], rGL[1][2], center.1],
            [rGL[2][0], rGL[2][1], rGL[2][2], center.2],
        ]
        let pose = try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: rows)

        // Expected world-to-camera rotation: transpose of R_gl with its
        // second and third columns negated.
        var expected = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            expected[0][i] = rGL[i][0]
            expected[1][i] = -rGL[i][1]
            expected[2][i] = -rGL[i][2]
        }
        let rebuilt = rotationMatrix(
            fromQuaternion: (pose.qw, pose.qx, pose.qy, pose.qz)
        )
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(rebuilt[i][j], expected[i][j], accuracy: 1e-10)
            }
        }
        // Unit quaternion.
        let norm = pose.qw * pose.qw + pose.qx * pose.qx + pose.qy * pose.qy + pose.qz * pose.qz
        XCTAssertEqual(norm, 1, accuracy: 1e-12)
    }

    func testCanonicalSignKeepsQWNonNegative() throws {
        // A rotation whose Shepperd extraction naturally lands on the
        // negative-w representative must be flipped for determinism.
        let rGL = rotationMatrix(axis: (0, 0, 1), angle: 3.0)
        let rows = [
            [rGL[0][0], rGL[0][1], rGL[0][2], 0],
            [rGL[1][0], rGL[1][1], rGL[1][2], 0],
            [rGL[2][0], rGL[2][1], rGL[2][2], 0],
        ]
        let pose = try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: rows)
        XCTAssertGreaterThanOrEqual(pose.qw, 0)
    }

    func testRejectsMirroredRotation() {
        XCTAssertThrowsError(
            try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
                [-1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
            ])
        ) { error in
            XCTAssertEqual(error as? DatasetPoseConvention.ConversionError, .mirroredRotation)
        }
    }

    func testRejectsNonOrthonormalRotation() {
        XCTAssertThrowsError(
            try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
                [1, 0.5, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
            ])
        ) { error in
            XCTAssertEqual(error as? DatasetPoseConvention.ConversionError, .notARotation)
        }
    }

    func testRejectsNonFiniteAndMalformedInput() {
        XCTAssertThrowsError(
            try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
                [1, 0, 0, .nan],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
            ])
        ) { error in
            XCTAssertEqual(error as? DatasetPoseConvention.ConversionError, .nonFiniteValue)
        }
        XCTAssertThrowsError(
            try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [[1, 0, 0, 0]])
        ) { error in
            XCTAssertEqual(error as? DatasetPoseConvention.ConversionError, .malformedMatrix)
        }
        XCTAssertThrowsError(
            try DatasetPoseConvention.colmapPose(fromPolycamCameraToWorld: [1, 2, 3])
        ) { error in
            XCTAssertEqual(error as? DatasetPoseConvention.ConversionError, .malformedMatrix)
        }
        // A 4x4 with a non-affine bottom row is malformed, not silently accepted.
        XCTAssertThrowsError(
            try DatasetPoseConvention.colmapPose(fromNerfstudioCameraToWorld: [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
                [0, 0, 0, 2],
            ])
        ) { error in
            XCTAssertEqual(error as? DatasetPoseConvention.ConversionError, .malformedMatrix)
        }
    }

    // MARK: - Helpers

    private func normalize(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        let n = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return (v.0 / n, v.1 / n, v.2 / n)
    }

    private func rotationMatrix(axis: (Double, Double, Double), angle: Double) -> [[Double]] {
        let (x, y, z) = axis
        let c = cos(angle)
        let s = sin(angle)
        let t = 1 - c
        return [
            [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
            [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
            [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
        ]
    }

    private func rotationMatrix(
        fromQuaternion q: (Double, Double, Double, Double)
    ) -> [[Double]] {
        let (w, x, y, z) = q
        return [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
    }
}
