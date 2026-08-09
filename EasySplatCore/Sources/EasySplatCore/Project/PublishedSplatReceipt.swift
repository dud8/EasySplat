import Foundation

package struct PublishedSplatReceipt: Sendable, Equatable {
    package static let currentSchemaVersion = 1
    package static let canonicalOutputPath = "Output/splat.ply"

    package let schemaVersion: Int
    package let publicationID: UUID
    package let projectID: UUID
    package let publishedAt: Date
    package let outputPath: String
    package let outputEvidence: ValidatedPlyArtifactEvidence
    package let lineage: PublishedSplatLineage
    package let presentation: PublishedResultPresentation

    package init(
        schemaVersion: Int = Self.currentSchemaVersion,
        publicationID: UUID,
        projectID: UUID,
        publishedAt: Date,
        outputPath: String = Self.canonicalOutputPath,
        outputEvidence: ValidatedPlyArtifactEvidence,
        lineage: PublishedSplatLineage,
        presentation: PublishedResultPresentation
    ) {
        self.schemaVersion = schemaVersion
        self.publicationID = publicationID
        self.projectID = projectID
        self.publishedAt = publishedAt
        self.outputPath = outputPath
        self.outputEvidence = outputEvidence
        self.lineage = lineage
        self.presentation = presentation
    }
}

package struct PublishedSplatLineage: Sendable, Equatable {
    package let trainingManifestSHA256: String
    package let trainingInputDigest: String
    package let trainingGeometryDigest: String

    package init(
        trainingManifestSHA256: String,
        trainingInputDigest: String,
        trainingGeometryDigest: String
    ) {
        self.trainingManifestSHA256 = trainingManifestSHA256
        self.trainingInputDigest = trainingInputDigest
        self.trainingGeometryDigest = trainingGeometryDigest
    }
}

package struct PublishedResultPresentation: Sendable, Equatable {
    package let requestedRunOptions: RequestedRunOptions
    package let resolvedRunPlan: ResolvedRunPlan
    package let reconstruction: PublishedReconstructionSummary
    package let orientation: PublishedOrientationSummary
    package let stageTimings: [StageTimingRecord]
    package let autoTunerSnapshot: PublishedAutoTunerSnapshot
    package let trainerVersion: String
    package let runtimeVersion: String
    package let completedIteration: Int
    package let trainingDurationSeconds: Double
    package let createToViewerReadySeconds: Double?

    package init(
        requestedRunOptions: RequestedRunOptions,
        resolvedRunPlan: ResolvedRunPlan,
        reconstruction: PublishedReconstructionSummary,
        orientation: PublishedOrientationSummary,
        stageTimings: [StageTimingRecord],
        autoTunerSnapshot: PublishedAutoTunerSnapshot,
        trainerVersion: String,
        runtimeVersion: String,
        completedIteration: Int,
        trainingDurationSeconds: Double,
        createToViewerReadySeconds: Double?
    ) {
        self.requestedRunOptions = requestedRunOptions
        self.resolvedRunPlan = resolvedRunPlan
        self.reconstruction = reconstruction
        self.orientation = orientation
        self.stageTimings = stageTimings
        self.autoTunerSnapshot = autoTunerSnapshot
        self.trainerVersion = trainerVersion
        self.runtimeVersion = runtimeVersion
        self.completedIteration = completedIteration
        self.trainingDurationSeconds = trainingDurationSeconds
        self.createToViewerReadySeconds = createToViewerReadySeconds
    }
}

package struct PublishedReconstructionSummary: Sendable, Equatable {
    package let registeredViewCount: Int
    package let totalViewCount: Int
    package let pointCount: Int
    package let observationCount: Int
    package let medianPixelResidual: Double
    package let p90PixelResidual: Double
    package let solverVersion: String
    package let modelVersion: String
    package let cameraModel: String
    package let residualProvenance: String
    package let usedPartialCoverageAcceptance: Bool
    package let secondLargestModelRegisteredViewCount: Int

    package init(
        registeredViewCount: Int,
        totalViewCount: Int,
        pointCount: Int,
        observationCount: Int,
        medianPixelResidual: Double,
        p90PixelResidual: Double,
        solverVersion: String,
        modelVersion: String,
        cameraModel: String,
        residualProvenance: String,
        usedPartialCoverageAcceptance: Bool,
        secondLargestModelRegisteredViewCount: Int
    ) {
        self.registeredViewCount = registeredViewCount
        self.totalViewCount = totalViewCount
        self.pointCount = pointCount
        self.observationCount = observationCount
        self.medianPixelResidual = medianPixelResidual
        self.p90PixelResidual = p90PixelResidual
        self.solverVersion = solverVersion
        self.modelVersion = modelVersion
        self.cameraModel = cameraModel
        self.residualProvenance = residualProvenance
        self.usedPartialCoverageAcceptance = usedPartialCoverageAcceptance
        self.secondLargestModelRegisteredViewCount = secondLargestModelRegisteredViewCount
    }

    package init(geometry: GeometryArtifact) {
        self.init(
            registeredViewCount: geometry.registeredViewCount,
            totalViewCount: geometry.totalViewCount,
            pointCount: geometry.pointCount,
            observationCount: geometry.observationCount,
            medianPixelResidual: geometry.medianPixelResidual,
            p90PixelResidual: geometry.p90PixelResidual,
            solverVersion: geometry.solverVersion,
            modelVersion: geometry.modelVersion,
            cameraModel: geometry.cameraModel,
            residualProvenance: geometry.residualProvenance,
            usedPartialCoverageAcceptance: geometry.usedPartialCoverageAcceptance,
            secondLargestModelRegisteredViewCount:
                geometry.mapping.secondLargestModelRegisteredViewCount
        )
    }
}

package struct PublishedOrientationSummary: Sendable, Equatable {
    package let status: CanonicalOrientationStatus
    package let openingDirection: CanonicalDirection?
    package let allowsViewOnlyUprightFlip: Bool

    package init(
        status: CanonicalOrientationStatus,
        openingDirection: CanonicalDirection?,
        allowsViewOnlyUprightFlip: Bool
    ) {
        self.status = status
        self.openingDirection = openingDirection
        self.allowsViewOnlyUprightFlip = allowsViewOnlyUprightFlip
    }

    package init(geometry: GeometryArtifact) {
        self.init(
            status: geometry.canonicalOrientation.status,
            openingDirection: geometry.canonicalOrientation.canonicalOpeningViewDirection,
            allowsViewOnlyUprightFlip: geometry.allowsViewOnlyUprightFlip
        )
    }
}

/// The historical AutoTuner record that can be reconstructed without inventing
/// host facts. Every value is an exact projection of the persisted run plan.
package struct PublishedAutoTunerSnapshot: Sendable, Equatable {
    package let memoryTier: String
    package let keyframeBudget: Int
    package let maximumImageDimension: Int
    package let colmapMaximumImageDimension: Int
    package let trainerIterationLimit: Int
    package let trainerMemoryBudgetBytes: Int64
    package let colmapMaximumFeatureCount: Int
    package let colmapMaximumMatchCount: Int
    package let geometryWorkerBudget: GeometryWorkerBudget

    package init(
        memoryTier: String,
        keyframeBudget: Int,
        maximumImageDimension: Int,
        colmapMaximumImageDimension: Int,
        trainerIterationLimit: Int,
        trainerMemoryBudgetBytes: Int64,
        colmapMaximumFeatureCount: Int,
        colmapMaximumMatchCount: Int,
        geometryWorkerBudget: GeometryWorkerBudget
    ) {
        self.memoryTier = memoryTier
        self.keyframeBudget = keyframeBudget
        self.maximumImageDimension = maximumImageDimension
        self.colmapMaximumImageDimension = colmapMaximumImageDimension
        self.trainerIterationLimit = trainerIterationLimit
        self.trainerMemoryBudgetBytes = trainerMemoryBudgetBytes
        self.colmapMaximumFeatureCount = colmapMaximumFeatureCount
        self.colmapMaximumMatchCount = colmapMaximumMatchCount
        self.geometryWorkerBudget = geometryWorkerBudget
    }

    package init(resolvedRunPlan plan: ResolvedRunPlan) {
        self.init(
            memoryTier: plan.memoryTier,
            keyframeBudget: plan.keyframeBudget,
            maximumImageDimension: plan.maximumImageDimension,
            colmapMaximumImageDimension: plan.colmapMaximumImageDimension,
            trainerIterationLimit: plan.trainerIterationLimit,
            trainerMemoryBudgetBytes: plan.trainerMemoryBudgetBytes,
            colmapMaximumFeatureCount: plan.colmapMaximumFeatureCount,
            colmapMaximumMatchCount: plan.colmapMaximumMatchCount,
            geometryWorkerBudget: plan.geometryWorkerBudget
        )
    }
}
