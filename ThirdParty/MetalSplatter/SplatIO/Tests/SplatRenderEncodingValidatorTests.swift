import simd
import XCTest
@testable import SplatIO

final class SplatRenderEncodingValidatorTests: XCTestCase {
    func testRejectsSphericalHarmonicOutsideFloat16Range() {
        var point = makePoint()
        point.color = .sphericalHarmonic(
            0,
            0,
            0,
            Array(repeating: 70_000, count: 45)
        )

        assertValidationError(.unrepresentableSphericalHarmonic) {
            try SplatRenderEncodingValidator.validate(point)
        }
    }

    func testRejectsLogScaleWhoseExponentialIsNonFinite() {
        var point = makePoint()
        point.scale.x = 100

        assertValidationError(.nonFiniteScale) {
            try SplatRenderEncodingValidator.validate(point)
        }
    }

    func testRejectsFiniteScaleWhoseCovarianceBecomesNonFinite() {
        var point = makePoint()
        point.scale.x = 45

        assertValidationError(.nonFiniteCovariance) {
            try SplatRenderEncodingValidator.validate(point)
        }
    }

    func testRejectsFiniteCovarianceOutsideFloat16Range() {
        var point = makePoint()
        point.scale.x = log(sqrt(66_000))

        assertValidationError(.unrepresentableCovariance) {
            try SplatRenderEncodingValidator.validate(point)
        }
    }

    func testStabilizesCovarianceMadeIndefiniteByFloat16Packing() throws {
        var point = makePoint()
        point.scale = SIMD3<Float>(4.3343487, -5.7033067, 3.8721263)
        point.rotation = simd_quatf(
            real: -0.37843282,
            imag: SIMD3<Float>(-0.25611334, 0.78376792, 0.42059768)
        )

        let encoding = try SplatRenderEncodingValidator.encode(point)

        assertPositiveSemidefiniteAfterHalfPacking(encoding)
    }

    func testStabilizesRealMsplatCovarianceAtViewerPrecision() throws {
        var point = makePoint()
        point.position = SIMD3<Float>(3.061717, -0.23588018, -1.3190962)
        point.opacity = -2.2156999
        point.scale = SIMD3<Float>(-8.549295, -5.457474, -4.375433)
        point.rotation = simd_quatf(
            real: 0.6233696,
            imag: SIMD3<Float>(-0.8226921, -0.4068475, -0.17318434)
        )

        let encoding = try SplatRenderEncodingValidator.encode(point)

        assertPositiveSemidefiniteAfterHalfPacking(encoding)
    }

    func testStabilizesHighlyAnisotropicMsplatCovarianceAtViewerPrecision() throws {
        var point = makePoint()
        point.position = SIMD3<Float>(0.7718016, -1.1667044, -2.2279339)
        point.opacity = 2.1665356
        point.scale = SIMD3<Float>(-3.0374317, -4.734968, -9.385075)
        point.rotation = simd_quatf(
            real: 0.85547656,
            imag: SIMD3<Float>(-0.085098766, -0.32880628, 0.57181054)
        )

        let encoding = try SplatRenderEncodingValidator.encode(point)

        assertPositiveSemidefiniteAfterHalfPacking(encoding)
    }

    func testRejectsZeroAndNearZeroQuaternions() {
        for magnitude: Float in [0, 1e-10] {
            var point = makePoint()
            point.rotation = simd_quatf(real: magnitude, imag: .zero)

            assertValidationError(.degenerateRotation) {
                try SplatRenderEncodingValidator.validate(point)
            }
        }
    }

    func testRejectsNonFiniteQuaternion() {
        var point = makePoint()
        point.rotation = simd_quatf(real: .infinity, imag: .zero)

        assertValidationError(.nonFiniteRotation) {
            try SplatRenderEncodingValidator.validate(point)
        }
    }

    func testRejectsNonFinitePositionOpacityAndLinearColor() {
        var point = makePoint()
        point.position.x = .nan
        assertValidationError(.nonFinitePosition) {
            try SplatRenderEncodingValidator.validate(point)
        }

        point = makePoint()
        point.opacity = .infinity
        assertValidationError(.nonFiniteOpacity) {
            try SplatRenderEncodingValidator.validate(point)
        }

        point = makePoint()
        point.color = .linearFloat(-1, 0, 0)
        assertValidationError(.invalidLinearColor) {
            try SplatRenderEncodingValidator.validate(point)
        }
    }

    func testAcceptsRepresentableCovarianceAndSphericalHarmonicBoundaries() throws {
        var point = makePoint()
        point.scale = SIMD3<Float>(repeating: log(sqrt(65_000)))
        let halfMaximum = Float(Float16.greatestFiniteMagnitude)
        point.color = .sphericalHarmonic(
            halfMaximum,
            -halfMaximum,
            0,
            Array(repeating: halfMaximum, count: 45)
        )

        let encoding = try SplatRenderEncodingValidator.encode(point)

        XCTAssertTrue(encoding.position.allFinite)
        XCTAssertTrue(encoding.colorOpacity.allFinite)
        XCTAssertTrue(encoding.covarianceA.allFinite)
        XCTAssertTrue(encoding.covarianceB.allFinite)
        let sphericalHarmonics = try XCTUnwrap(encoding.sphericalHarmonics)
        XCTAssertEqual(SplatRenderSphericalHarmonics.coefficientCount, 16)
        XCTAssertEqual(sphericalHarmonics[0], SIMD3<Float>(halfMaximum, -halfMaximum, 0))
        XCTAssertEqual(
            sphericalHarmonics[15],
            SIMD3<Float>(repeating: halfMaximum)
        )
        for value in [
            encoding.covarianceA.x,
            encoding.covarianceA.y,
            encoding.covarianceA.z,
            encoding.covarianceB.x,
            encoding.covarianceB.y,
            encoding.covarianceB.z,
        ] {
            XCTAssertTrue(Float16(value).isFinite)
        }
    }

    func testRobustlyNormalizesLargeFiniteQuaternion() throws {
        var point = makePoint()
        point.rotation = simd_quatf(
            real: Float.greatestFiniteMagnitude,
            imag: SIMD3<Float>(Float.greatestFiniteMagnitude, 0, 0)
        )

        let encoding = try SplatRenderEncodingValidator.encode(point)

        XCTAssertTrue(encoding.covarianceA.allFinite)
        XCTAssertTrue(encoding.covarianceB.allFinite)
    }

    private func makePoint() -> SplatScenePoint {
        SplatScenePoint(
            position: SIMD3<Float>(1, 2, 3),
            normal: .zero,
            color: .linearUInt8(255, 128, 0),
            opacity: 1,
            scale: .zero,
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    private func assertValidationError(
        _ expected: SplatRenderEncodingValidationError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? SplatRenderEncodingValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func assertPositiveSemidefiniteAfterHalfPacking(
        _ encoding: SplatRenderEncoding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let xx = Double(Float(Float16(encoding.covarianceA.x)))
        let xy = Double(Float(Float16(encoding.covarianceA.y)))
        let xz = Double(Float(Float16(encoding.covarianceA.z)))
        let yy = Double(Float(Float16(encoding.covarianceB.x)))
        let yz = Double(Float(Float16(encoding.covarianceB.y)))
        let zz = Double(Float(Float16(encoding.covarianceB.z)))

        XCTAssertGreaterThanOrEqual(xx, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(yy, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(zz, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(xx * yy - xy * xy, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(xx * zz - xz * xz, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(yy * zz - yz * yz, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            xx * (yy * zz - yz * yz)
                - xy * (xy * zz - yz * xz)
                + xz * (xy * yz - yy * xz),
            0,
            file: file,
            line: line
        )
    }
}

private extension SIMD3<Float> {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension SIMD4<Float> {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
