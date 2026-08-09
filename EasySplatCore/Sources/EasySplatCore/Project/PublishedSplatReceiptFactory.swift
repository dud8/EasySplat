import CryptoKit
import Foundation

package enum PublishedSplatReceiptFactoryError: Error, Equatable {
    case inconsistentArtifacts
}

/// Builds the deliberately small authority receipt from already-validated run
/// artifacts. The caller supplies the exact rebound training-manifest bytes and
/// descriptor-bound geometry-manifest digest so the receipt, its presentation,
/// and the later manifest write cannot silently diverge.
package enum PublishedSplatReceiptFactory {
    /// Compares immutable result identity while deliberately ignoring timing
    /// fields that can be healed after publication. This is the crash-recovery
    /// predicate for adopting a receipt whose commit preceded the rebound
    /// training-manifest write.
    package static func isBound(
        _ existing: PublishedSplatReceipt,
        to proposed: PublishedSplatReceipt
    ) -> Bool {
        existing.publicationID == proposed.publicationID
            && existing.projectID == proposed.projectID
            && existing.publishedAt == proposed.publishedAt
            && existing.outputPath == proposed.outputPath
            && existing.outputEvidence == proposed.outputEvidence
            && existing.lineage == proposed.lineage
            && existing.presentation.requestedRunOptions
                == proposed.presentation.requestedRunOptions
            && existing.presentation.resolvedRunPlan
                == proposed.presentation.resolvedRunPlan
            && existing.presentation.reconstruction
                == proposed.presentation.reconstruction
            && existing.presentation.orientation
                == proposed.presentation.orientation
            && existing.presentation.autoTunerSnapshot
                == proposed.presentation.autoTunerSnapshot
            && existing.presentation.trainerVersion
                == proposed.presentation.trainerVersion
            && existing.presentation.runtimeVersion
                == proposed.presentation.runtimeVersion
            && existing.presentation.completedIteration
                == proposed.presentation.completedIteration
            && existing.presentation.trainingDurationSeconds
                == proposed.presentation.trainingDurationSeconds
    }

    /// Rebuilds the immutable binding for an already-committed publication
    /// while retaining its receipt-era timing fields. A retry can record a new
    /// export attempt after the original publication timestamp; those retry
    /// timings must not make the historical receipt impossible to adopt.
    package static func makeAdoptionCandidate(
        existing: PublishedSplatReceipt,
        metadata: ProjectMetadata,
        resolvedRunPlan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        geometryManifestDigest: String,
        reboundTraining: TrainingArtifact,
        reboundTrainingManifestData: Data,
        outputEvidence: ValidatedPlyArtifactEvidence,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil
    ) throws -> PublishedSplatReceipt {
        var receiptEraMetadata = metadata
        receiptEraMetadata.stageTimings = existing.presentation.stageTimings
        receiptEraMetadata.createToViewerReadySeconds =
            existing.presentation.createToViewerReadySeconds
        return try make(
            metadata: receiptEraMetadata,
            resolvedRunPlan: resolvedRunPlan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest,
            reboundTraining: reboundTraining,
            reboundTrainingManifestData: reboundTrainingManifestData,
            outputEvidence: outputEvidence,
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            publicationID: existing.publicationID,
            publishedAt: existing.publishedAt
        )
    }

    package static func make(
        metadata: ProjectMetadata,
        resolvedRunPlan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        geometryManifestDigest: String,
        reboundTraining: TrainingArtifact,
        reboundTrainingManifestData: Data,
        outputEvidence: ValidatedPlyArtifactEvidence,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32? = nil,
        publicationID: UUID,
        publishedAt: Date
    ) throws -> PublishedSplatReceipt {
        guard publicationID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              publishedAt.timeIntervalSinceReferenceDate.isFinite,
              metadata.resolvedRunPlan == resolvedRunPlan,
              isLowercaseSHA256(geometryManifestDigest),
              geometryManifestDigest
                  == reboundTraining.datasetDerivation.sourceGeometryManifestSHA256,
              reboundTraining.geometryDigest
                  == reboundTraining.datasetDerivation.datasetGeometryDigest,
              reboundTraining.completionStatus == .completed,
              reboundTraining.outputPath == PublishedSplatReceipt.canonicalOutputPath,
              reboundTraining.detailProfile == metadata.requestedRunOptions.detailProfile,
              reboundTraining.matchesResolvedTrainingPlan(
                  resolvedRunPlan,
                  resourcePolicy: metadata.requestedRunOptions.resourcePolicy
              ),
              reboundTraining.outputSHA256 == outputEvidence.sha256,
              reboundTraining.outputBytes == Int64(exactly: outputEvidence.byteCount),
              reboundTraining.gaussianCount == outputEvidence.vertexCount,
              reboundTraining.sceneBounds.map({
                  SplatSceneBoundsCalculator.matches($0, outputEvidence.sceneBounds)
              }) == true,
              reboundTraining.datasetDerivation.sourceSelectedFramesDigest
                  == geometry.selectedFramesDigest,
              reboundTraining.datasetDerivation.registeredImageNames
                  == geometry.orderedImageNames,
              let trainingDuration = reboundTraining.elapsedSeconds,
              trainingDuration.isFinite,
              trainingDuration >= 0,
              reboundTrainingManifestData == (try encodedManifestData(
                  reboundTraining,
                  projectPaths: projectPaths,
                  projectRootDescriptor: projectRootDescriptor
              )) else {
            throw PublishedSplatReceiptFactoryError.inconsistentArtifacts
        }

        var receiptStageTimings = metadata.stageTimings ?? []
        if !receiptStageTimings.contains(where: { $0.stage == .trainSplat }) {
            receiptStageTimings.append(StageTimingRecord(
                stage: .trainSplat,
                startedAt: publishedAt.addingTimeInterval(-trainingDuration),
                durationSeconds: trainingDuration
            ))
        }

        let receipt = PublishedSplatReceipt(
            publicationID: publicationID,
            projectID: metadata.id,
            publishedAt: publishedAt,
            outputEvidence: outputEvidence,
            lineage: PublishedSplatLineage(
                trainingManifestSHA256: sha256(reboundTrainingManifestData),
                trainingInputDigest: reboundTraining.inputDigest,
                trainingGeometryDigest: reboundTraining.geometryDigest
            ),
            presentation: PublishedResultPresentation(
                requestedRunOptions: metadata.requestedRunOptions,
                resolvedRunPlan: resolvedRunPlan,
                reconstruction: PublishedReconstructionSummary(geometry: geometry),
                orientation: PublishedOrientationSummary(geometry: geometry),
                stageTimings: receiptStageTimings,
                autoTunerSnapshot: PublishedAutoTunerSnapshot(
                    resolvedRunPlan: resolvedRunPlan
                ),
                trainerVersion: reboundTraining.trainerVersion,
                runtimeVersion: reboundTraining.runtimeVersion,
                completedIteration: reboundTraining.completedIteration,
                trainingDurationSeconds: trainingDuration,
                createToViewerReadySeconds: metadata.createToViewerReadySeconds
            )
        )
        do {
            _ = try PublishedSplatReceiptStore.encode(receipt)
        } catch {
            throw PublishedSplatReceiptFactoryError.inconsistentArtifacts
        }
        return receipt
    }

    private static func encodedManifestData(
        _ training: TrainingArtifact,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32?
    ) throws -> Data {
        if let projectRootDescriptor {
            return try TrainingArtifactStore.encodedManifestData(
                training,
                projectPaths: projectPaths,
                projectRootDescriptor: projectRootDescriptor
            )
        }
        return try TrainingArtifactStore.encodedManifestData(
            training,
            projectPaths: projectPaths
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

}
