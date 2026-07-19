import Foundation

public struct GeometryConditioningMeasurement: Codable, Sendable, Equatable {
    public static let provenance = "colmap-text-conditioning-v2"

    public let pointCount: Int
    public let observationCount: Int
    public let positiveDepthObservationCount: Int
    public let stronglyMeasuredViewCount: Int
    public let registeredViewCount: Int
    public let perViewObservationMinimum: Int
    public let perViewObservationP10: Int
    public let perViewObservationMedian: Double
    public let perViewObservationP90: Int
    public let distinctTrackLengthMinimum: Int
    public let distinctTrackLengthP10: Int
    public let distinctTrackLengthMedian: Double
    public let distinctTrackLengthP90: Int
    public let pointsAtLeast1Point5Degrees: Int
    public let pointsAtLeast2Degrees: Int
    public let pointsAtLeast3Degrees: Int
    public let observationsAtLeast1Point5Degrees: Int
    public let observationsAtLeast2Degrees: Int
    public let observationsAtLeast3Degrees: Int
    /// Median Euclidean camera-to-point range across accepted observations.
    public let medianObservedDepth: Double
    /// P10 of each camera's nearest-neighbor baseline divided by median observed depth.
    public let cameraBaselineToMedianDepthRatio: Double
    /// Scale-relative center clusters after merging numerically stationary poses.
    public let effectiveCameraCenterCount: Int
    public let largestCameraCenterClusterSize: Int
    public let cameraCenterMergeToleranceToMedianDepthRatio: Double
    /// Points whose maximum ray separation clears their residual-derived uncertainty floor.
    public let numericallyConditionedPointCount: Int
    /// Observations with at least one ray partner clearing residual-derived uncertainty.
    public let numericallyConditionedObservationCount: Int
    public let adaptiveParallaxThresholdMedianDegrees: Double
    public let adaptiveParallaxThresholdP90Degrees: Double
    /// Ascending, trace-normalized eigenvalues.
    public let cameraCenterEigenvalues: [Double]
    /// Ascending, trace-normalized eigenvalues after radial p99 winsorization.
    public let pointEigenvalues: [Double]
    /// Camera-center pair evaluations charged to the shared conditioning work budget.
    public let cameraPairEvaluationCount: Int
    /// Track-ray pair evaluations charged to the same shared conditioning work budget.
    public let rayPairEvaluationCount: Int

    public init(
        pointCount: Int,
        observationCount: Int,
        positiveDepthObservationCount: Int,
        stronglyMeasuredViewCount: Int,
        registeredViewCount: Int,
        perViewObservationMinimum: Int,
        perViewObservationP10: Int,
        perViewObservationMedian: Double,
        perViewObservationP90: Int,
        distinctTrackLengthMinimum: Int,
        distinctTrackLengthP10: Int,
        distinctTrackLengthMedian: Double,
        distinctTrackLengthP90: Int,
        pointsAtLeast1Point5Degrees: Int,
        pointsAtLeast2Degrees: Int,
        pointsAtLeast3Degrees: Int,
        observationsAtLeast1Point5Degrees: Int,
        observationsAtLeast2Degrees: Int,
        observationsAtLeast3Degrees: Int,
        medianObservedDepth: Double,
        cameraBaselineToMedianDepthRatio: Double,
        effectiveCameraCenterCount: Int,
        largestCameraCenterClusterSize: Int,
        cameraCenterMergeToleranceToMedianDepthRatio: Double,
        numericallyConditionedPointCount: Int,
        numericallyConditionedObservationCount: Int,
        adaptiveParallaxThresholdMedianDegrees: Double,
        adaptiveParallaxThresholdP90Degrees: Double,
        cameraCenterEigenvalues: [Double],
        pointEigenvalues: [Double],
        cameraPairEvaluationCount: Int,
        rayPairEvaluationCount: Int
    ) {
        self.pointCount = pointCount
        self.observationCount = observationCount
        self.positiveDepthObservationCount = positiveDepthObservationCount
        self.stronglyMeasuredViewCount = stronglyMeasuredViewCount
        self.registeredViewCount = registeredViewCount
        self.perViewObservationMinimum = perViewObservationMinimum
        self.perViewObservationP10 = perViewObservationP10
        self.perViewObservationMedian = perViewObservationMedian
        self.perViewObservationP90 = perViewObservationP90
        self.distinctTrackLengthMinimum = distinctTrackLengthMinimum
        self.distinctTrackLengthP10 = distinctTrackLengthP10
        self.distinctTrackLengthMedian = distinctTrackLengthMedian
        self.distinctTrackLengthP90 = distinctTrackLengthP90
        self.pointsAtLeast1Point5Degrees = pointsAtLeast1Point5Degrees
        self.pointsAtLeast2Degrees = pointsAtLeast2Degrees
        self.pointsAtLeast3Degrees = pointsAtLeast3Degrees
        self.observationsAtLeast1Point5Degrees = observationsAtLeast1Point5Degrees
        self.observationsAtLeast2Degrees = observationsAtLeast2Degrees
        self.observationsAtLeast3Degrees = observationsAtLeast3Degrees
        self.medianObservedDepth = medianObservedDepth
        self.cameraBaselineToMedianDepthRatio = cameraBaselineToMedianDepthRatio
        self.effectiveCameraCenterCount = effectiveCameraCenterCount
        self.largestCameraCenterClusterSize = largestCameraCenterClusterSize
        self.cameraCenterMergeToleranceToMedianDepthRatio =
            cameraCenterMergeToleranceToMedianDepthRatio
        self.numericallyConditionedPointCount = numericallyConditionedPointCount
        self.numericallyConditionedObservationCount = numericallyConditionedObservationCount
        self.adaptiveParallaxThresholdMedianDegrees = adaptiveParallaxThresholdMedianDegrees
        self.adaptiveParallaxThresholdP90Degrees = adaptiveParallaxThresholdP90Degrees
        self.cameraCenterEigenvalues = cameraCenterEigenvalues
        self.pointEigenvalues = pointEigenvalues
        self.cameraPairEvaluationCount = cameraPairEvaluationCount
        self.rayPairEvaluationCount = rayPairEvaluationCount
    }
}

struct GeometryConditioningAnalysis: Sendable {
    let residuals: ColmapResidualAnalyzer.Result
    let measurement: GeometryConditioningMeasurement
    let modelSnapshot: GeometryModelSnapshot.Verified
}

enum GeometryConditioningFailure: Error, LocalizedError, Equatable {
    case insufficientDistinctTrackViews(pointID: Int64, distinctViewCount: Int)
    case insufficientViewSupport(GeometryConditioningMeasurement)
    case collapsedCameraTrajectory(GeometryConditioningMeasurement)
    case insufficientParallax(GeometryConditioningMeasurement)
    case degeneratePointDistribution(GeometryConditioningMeasurement)
    case rayPairWorkLimitExceeded(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientDistinctTrackViews(let pointID, let count):
            return "COLMAP point \(pointID) is observed by only \(count) distinct image(s)."
        case .insufficientViewSupport:
            return "Too few registered views contain enough tracked observations."
        case .collapsedCameraTrajectory:
            return "The registered camera centers are numerically collapsed."
        case .insufficientParallax:
            return "The reconstruction does not contain enough triangulation parallax."
        case .degeneratePointDistribution:
            return "The reconstructed points are numerically collinear."
        case .rayPairWorkLimitExceeded(let maximum):
            return "Geometry conditioning exceeded its \(maximum)-pair work limit."
        }
    }
}
