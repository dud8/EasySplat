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

    func testRejectsCovarianceMadeIndefiniteByFloat16Packing() {
        var point = makePoint()
        point.scale = SIMD3<Float>(4.3343487, -5.7033067, 3.8721263)
        point.rotation = simd_quatf(
            real: -0.37843282,
            imag: SIMD3<Float>(-0.25611334, 0.78376792, 0.42059768)
        )

        assertValidationError(.indefiniteQuantizedCovariance) {
            try SplatRenderEncodingValidator.validate(point)
        }
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
        XCTAssertTrue(encoding.linearColorOpacity.allFinite)
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
}

private extension SIMD3<Float> {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension SIMD4<Float> {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
