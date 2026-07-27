import Foundation
import simd

public enum SplatRenderEncodingValidationError: LocalizedError, Sendable, Equatable {
    case nonFinitePosition
    case invalidSphericalHarmonicCount(Int)
    case unrepresentableSphericalHarmonic
    case invalidLinearColor
    case nonFiniteOpacity
    case nonFiniteLogScale
    case nonFiniteScale
    case nonFiniteRotation
    case degenerateRotation
    case nonFiniteCovariance
    case unrepresentableCovariance
    case indefiniteQuantizedCovariance
    case unrepresentableColor

    public var errorDescription: String? {
        switch self {
        case .nonFinitePosition:
            "A splat position is not finite."
        case .invalidSphericalHarmonicCount(let count):
            "Expected 45 higher-order spherical-harmonic values, found \(count)."
        case .unrepresentableSphericalHarmonic:
            "A spherical-harmonic value cannot be represented by the renderer."
        case .invalidLinearColor:
            "A floating-point color is outside the supported 0 through 255 range."
        case .nonFiniteOpacity:
            "A splat opacity is not finite."
        case .nonFiniteLogScale:
            "A splat log scale is not finite."
        case .nonFiniteScale:
            "A splat log scale produces a non-finite physical scale."
        case .nonFiniteRotation:
            "A splat rotation is not finite."
        case .degenerateRotation:
            "A splat rotation has zero or near-zero magnitude."
        case .nonFiniteCovariance:
            "A splat scale and rotation produce a non-finite covariance."
        case .unrepresentableCovariance:
            "A splat covariance cannot be represented by the renderer."
        case .indefiniteQuantizedCovariance:
            "A splat covariance becomes invalid at the renderer's storage precision."
        case .unrepresentableColor:
            "A splat color cannot be represented by the renderer."
        }
    }
}

/// CPU-only values produced by the same transform used for Metal splat storage.
/// Instances come from ``SplatRenderEncodingValidator`` so every value is finite
/// and every half-precision field is representable before a GPU buffer is allocated.
public struct SplatRenderEncoding: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let colorOpacity: SIMD4<Float>
    public let covarianceA: SIMD3<Float>
    public let covarianceB: SIMD3<Float>
    public let sphericalHarmonics: SplatRenderSphericalHarmonics?

    fileprivate init(
        position: SIMD3<Float>,
        colorOpacity: SIMD4<Float>,
        covarianceA: SIMD3<Float>,
        covarianceB: SIMD3<Float>,
        sphericalHarmonics: SplatRenderSphericalHarmonics?
    ) {
        self.position = position
        self.colorOpacity = colorOpacity
        self.covarianceA = covarianceA
        self.covarianceB = covarianceB
        self.sphericalHarmonics = sphericalHarmonics
    }
}

/// The channel-major SH values copied from a Gaussian-splat PLY row.
/// Subscripted values use the basis-major RGB order consumed by the Metal shader.
public struct SplatRenderSphericalHarmonics: Sendable, Equatable {
    public static let coefficientCount = 16

    private let rawDC: SIMD3<Float>
    private let higherOrder: [Float]

    fileprivate init(rawDC: SIMD3<Float>, higherOrder: [Float]) {
        self.rawDC = rawDC
        self.higherOrder = higherOrder
    }

    public subscript(index: Int) -> SIMD3<Float> {
        precondition((0..<Self.coefficientCount).contains(index))
        guard index > 0 else { return rawDC }
        let basis = index - 1
        let basisCount = Self.coefficientCount - 1
        return SIMD3<Float>(
            higherOrder[basis],
            higherOrder[basisCount + basis],
            higherOrder[2 * basisCount + basis]
        )
    }
}

public enum SplatRenderEncodingValidator {
    private static let higherOrderSphericalHarmonicCount = 45
    private static let minimumRotationMagnitude = 1e-8
    private static let sphericalHarmonicC0: Float = 0.28209479177387814

    public static func validate(_ point: SplatScenePoint) throws {
        _ = try encode(point)
    }

    public static func encode(_ point: SplatScenePoint) throws -> SplatRenderEncoding {
        guard point.position.allFinite else {
            throw SplatRenderEncodingValidationError.nonFinitePosition
        }
        guard point.opacity.isFinite else {
            throw SplatRenderEncodingValidationError.nonFiniteOpacity
        }
        guard point.scale.allFinite else {
            throw SplatRenderEncodingValidationError.nonFiniteLogScale
        }

        let physicalScale = SIMD3<Float>(
            Foundation.exp(point.scale.x),
            Foundation.exp(point.scale.y),
            Foundation.exp(point.scale.z)
        )
        guard physicalScale.allFinite else {
            throw SplatRenderEncodingValidationError.nonFiniteScale
        }

        let rotation = try normalizedRotation(point.rotation)
        let transform = simd_float3x3(rotation) * simd_float3x3(diagonal: physicalScale)
        let covariance = transform * transform.transpose
        let covarianceA = SIMD3<Float>(
            covariance[0, 0],
            covariance[0, 1],
            covariance[0, 2]
        )
        let covarianceB = SIMD3<Float>(
            covariance[1, 1],
            covariance[1, 2],
            covariance[2, 2]
        )
        guard covarianceA.allFinite, covarianceB.allFinite else {
            throw SplatRenderEncodingValidationError.nonFiniteCovariance
        }
        guard covarianceA.allHalfRepresentable, covarianceB.allHalfRepresentable else {
            throw SplatRenderEncodingValidationError.unrepresentableCovariance
        }
        let quantizedCovariance = try stabilizedQuantizedCovariance(
            covarianceA: covarianceA,
            covarianceB: covarianceB
        )

        let color = try encodedColor(point.color)
        let opacity = stableSigmoid(point.opacity)
        let colorOpacity = SIMD4<Float>(color, opacity)
        guard colorOpacity.allFinite,
              colorOpacity.allHalfRepresentable else {
            throw SplatRenderEncodingValidationError.unrepresentableColor
        }

        return SplatRenderEncoding(
            position: point.position,
            colorOpacity: colorOpacity,
            covarianceA: quantizedCovariance.a,
            covarianceB: quantizedCovariance.b,
            sphericalHarmonics: sphericalHarmonics(point.color)
        )
    }

    private static func normalizedRotation(_ rotation: simd_quatf) throws -> simd_quatf {
        let components = [
            rotation.imag.x,
            rotation.imag.y,
            rotation.imag.z,
            rotation.real,
        ]
        guard components.allSatisfy(\.isFinite) else {
            throw SplatRenderEncodingValidationError.nonFiniteRotation
        }
        let magnitude = sqrt(components.reduce(0.0) {
            $0 + Double($1) * Double($1)
        })
        guard magnitude >= minimumRotationMagnitude else {
            throw SplatRenderEncodingValidationError.degenerateRotation
        }
        let inverseMagnitude = Float(1 / magnitude)
        let normalized = simd_quatf(
            real: rotation.real * inverseMagnitude,
            imag: rotation.imag * inverseMagnitude
        )
        guard normalized.vector.allFinite else {
            throw SplatRenderEncodingValidationError.nonFiniteRotation
        }
        return normalized
    }

    private static func stabilizedQuantizedCovariance(
        covarianceA: SIMD3<Float>,
        covarianceB: SIMD3<Float>
    ) throws -> (a: SIMD3<Float>, b: SIMD3<Float>) {
        var xx = Float16(covarianceA.x)
        let xy = Float16(covarianceA.y)
        let xz = Float16(covarianceA.z)
        var yy = Float16(covarianceB.x)
        let yz = Float16(covarianceB.y)
        var zz = Float16(covarianceB.z)

        for _ in 0..<2 where !quantizedCovarianceIsPositiveSemidefinite(
            xx: xx,
            xy: xy,
            xz: xz,
            yy: yy,
            yz: yz,
            zz: zz
        ) {
            // Half-precision component rounding can make a valid covariance
            // microscopically indefinite. A bounded diagonal ULP adjustment
            // restores the storage invariant without changing its orientation.
            xx = xx.nextUp
            yy = yy.nextUp
            zz = zz.nextUp
        }

        guard xx.isFinite,
              yy.isFinite,
              zz.isFinite,
              quantizedCovarianceIsPositiveSemidefinite(
                  xx: xx,
                  xy: xy,
                  xz: xz,
                  yy: yy,
                  yz: yz,
                  zz: zz
              ) else {
            throw SplatRenderEncodingValidationError.indefiniteQuantizedCovariance
        }

        return (
            SIMD3<Float>(Float(xx), Float(xy), Float(xz)),
            SIMD3<Float>(Float(yy), Float(yz), Float(zz))
        )
    }

    private static func quantizedCovarianceIsPositiveSemidefinite(
        xx: Float16,
        xy: Float16,
        xz: Float16,
        yy: Float16,
        yz: Float16,
        zz: Float16
    ) -> Bool {
        let xx = Double(Float(xx))
        let xy = Double(Float(xy))
        let xz = Double(Float(xz))
        let yy = Double(Float(yy))
        let yz = Double(Float(yz))
        let zz = Double(Float(zz))
        let xyMinor = xx * yy - xy * xy
        let xzMinor = xx * zz - xz * xz
        let yzMinor = yy * zz - yz * yz
        let determinant = xx * (yy * zz - yz * yz)
            - xy * (xy * zz - yz * xz)
            + xz * (xy * yz - yy * xz)
        return xx >= 0
            && yy >= 0
            && zz >= 0
            && xyMinor >= 0
            && xzMinor >= 0
            && yzMinor >= 0
            && determinant >= 0
    }

    private static func encodedColor(_ color: SplatScenePoint.Color) throws -> SIMD3<Float> {
        switch color {
        case let .sphericalHarmonic(r, g, b, rest):
            guard rest.count == higherOrderSphericalHarmonicCount else {
                throw SplatRenderEncodingValidationError.invalidSphericalHarmonicCount(rest.count)
            }
            try validateRepresentableSphericalHarmonics(r: r, g: g, b: b, rest: rest)
            return sphericalHarmonicColor(r: r, g: g, b: b)
        case let .firstOrderSphericalHarmonic(r, g, b):
            guard r.isFinite, g.isFinite, b.isFinite else {
                throw SplatRenderEncodingValidationError.unrepresentableSphericalHarmonic
            }
            return sphericalHarmonicColor(r: r, g: g, b: b)
        case let .linearFloat(r, g, b):
            let values = SIMD3<Float>(r, g, b)
            guard values.allFinite,
                  values.x >= 0, values.x <= 255,
                  values.y >= 0, values.y <= 255,
                  values.z >= 0, values.z <= 255 else {
                throw SplatRenderEncodingValidationError.invalidLinearColor
            }
            return values / 255
        case let .linearUInt8(r, g, b):
            return SIMD3<Float>(Float(r), Float(g), Float(b)) / 255
        case .none:
            return .zero
        }
    }

    /// Clamped below only. The trainer bounds a gaussian's colour at zero and lets the
    /// composite saturate, so pre-clamping to 1 here would drop the contribution of a
    /// bright gaussian at partial alpha relative to what the model was fitted against.
    private static func sphericalHarmonicColor(
        r: Float,
        g: Float,
        b: Float
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            max(0, 0.5 + sphericalHarmonicC0 * r),
            max(0, 0.5 + sphericalHarmonicC0 * g),
            max(0, 0.5 + sphericalHarmonicC0 * b)
        )
    }

    private static func sphericalHarmonics(
        _ color: SplatScenePoint.Color
    ) -> SplatRenderSphericalHarmonics? {
        guard case let .sphericalHarmonic(r, g, b, rest) = color else {
            return nil
        }
        return SplatRenderSphericalHarmonics(
            rawDC: SIMD3<Float>(r, g, b),
            higherOrder: rest
        )
    }

    private static func validateRepresentableSphericalHarmonics(
        r: Float,
        g: Float,
        b: Float,
        rest: [Float]
    ) throws {
        guard isHalfRepresentable(r),
              isHalfRepresentable(g),
              isHalfRepresentable(b),
              rest.allSatisfy(isHalfRepresentable) else {
            throw SplatRenderEncodingValidationError.unrepresentableSphericalHarmonic
        }
    }

    private static func isHalfRepresentable(_ value: Float) -> Bool {
        value.isFinite && Float16(value).isFinite
    }

    private static func stableSigmoid(_ value: Float) -> Float {
        if value >= 0 {
            return 1 / (1 + Foundation.exp(-value))
        }
        let exponential = Foundation.exp(value)
        return exponential / (1 + exponential)
    }
}

private extension SIMD3<Float> {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    var allHalfRepresentable: Bool {
        Float16(x).isFinite && Float16(y).isFinite && Float16(z).isFinite
    }
}

private extension SIMD4<Float> {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }

    var allHalfRepresentable: Bool {
        Float16(x).isFinite
            && Float16(y).isFinite
            && Float16(z).isFinite
            && Float16(w).isFinite
    }
}
