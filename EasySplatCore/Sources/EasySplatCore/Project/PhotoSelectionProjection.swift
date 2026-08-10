import Foundation

enum PhotoSelectionProjectionPolicy: Equatable, Sendable {
    case rankedPrefix
    case evenlySpaced
    case preserve
}

enum PhotoSelectionProjectionError: Error, LocalizedError, Equatable {
    case invalidInputCombination
    case missingSelectionReceipt
    case missingResolvedRunPlan
    case invalidSelectionReceipt
    case artifactVerificationFailed(PhotoSelectionArtifactStoreError)
    case planMismatch
    case receiptBindingMismatch
    case invalidTargetCount(Int)
    case useAllRequiresFullCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidInputCombination:
            "The project photo inputs are incomplete."
        case .missingSelectionReceipt:
            "The project is missing its photo selection receipt."
        case .missingResolvedRunPlan:
            "The project is missing its resolved photo selection plan."
        case .invalidSelectionReceipt:
            "The photo selection receipt is invalid or stale."
        case .artifactVerificationFailed:
            "The photo selection evidence could not be verified."
        case .planMismatch:
            "The photo selection evidence does not match the resolved run plan."
        case .receiptBindingMismatch:
            "The retained photos do not match the photo selection evidence."
        case .invalidTargetCount(let targetCount):
            "Photo selection target \(targetCount) is outside the admitted range."
        case .useAllRequiresFullCount(let expected, let actual):
            "Use All requires \(expected) photos, but the projection requested \(actual)."
        }
    }
}

struct PhotoSelectionProjection: Equatable, Sendable {
    let artifact: PhotoSelectionArtifact
    let canonicalReceipts: [PhotoInputReceipt]
    let rankOrderedReceipts: [PhotoInputReceipt]
    let policy: PhotoSelectionProjectionPolicy

    static func loadVerified(
        metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws -> Self? {
        try loadProjectBoundVerified(
            metadata: metadata,
            paths: paths
        ).projection
    }

    static func loadProjectBoundVerified(
        metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws -> (
        projection: Self?,
        leaseEvidence: PhotoSelectionArtifactLeaseEvidence?
    ) {
        let receipts = metadata.photoInputReceipts ?? []
        switch metadata.input {
        case .video:
            guard receipts.isEmpty, metadata.photoSelectionReceipt == nil else {
                throw PhotoSelectionProjectionError.invalidInputCombination
            }
            return (nil, nil)
        case .photos, .dataset:
            guard !receipts.isEmpty else {
                throw PhotoSelectionProjectionError.invalidInputCombination
            }
        case .mixed:
            if receipts.isEmpty {
                guard metadata.photoSelectionReceipt == nil,
                      metadata.videoInputReceipts?.isEmpty == false else {
                    throw PhotoSelectionProjectionError.invalidInputCombination
                }
                return (nil, nil)
            }
        }

        guard let selectionReceipt = metadata.photoSelectionReceipt else {
            throw PhotoSelectionProjectionError.missingSelectionReceipt
        }
        guard let plan = metadata.resolvedRunPlan else {
            throw PhotoSelectionProjectionError.missingResolvedRunPlan
        }
        guard selectionReceipt.isCurrentStructurallyValid else {
            throw PhotoSelectionProjectionError.invalidSelectionReceipt
        }

        do {
            try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        } catch {
            throw PhotoSelectionProjectionError.receiptBindingMismatch
        }

        do {
            _ = try paths.validateReservedProjectPath(
                paths.photoSelectionArtifactURL,
                relativePath: PhotoSelectionArtifactStore.projectRelativePath
            )
        } catch {
            throw PhotoSelectionProjectionError.artifactVerificationFailed(.invalidArtifact)
        }

        let loaded: (
            artifact: PhotoSelectionArtifact,
            leaseEvidence: PhotoSelectionArtifactLeaseEvidence
        )
        do {
            loaded = try PhotoSelectionArtifactStore.loadProjectBoundVerified(
                from: paths.photoSelectionArtifactURL,
                projectPaths: paths,
                expectedByteCount: selectionReceipt.byteCount,
                expectedSHA256: selectionReceipt.sha256,
                expectedAnalysisRecipeVersion: selectionReceipt.analysisRecipeVersion,
                expectedAnalysisRecipeSHA256: selectionReceipt.analysisRecipeSHA256,
                expectedSelectorPolicyVersion: selectionReceipt.selectorPolicyVersion,
                expectedSelectorPolicySHA256: selectionReceipt.selectorPolicySHA256
            )
        } catch let error as PhotoSelectionArtifactStoreError {
            throw PhotoSelectionProjectionError.artifactVerificationFailed(error)
        } catch {
            throw PhotoSelectionProjectionError.artifactVerificationFailed(.invalidArtifact)
        }
        let artifact = loaded.artifact

        guard let expectedStrategy = expectedStrategy(for: plan),
              artifact.schemaVersion == selectionReceipt.artifactSchemaVersion,
              artifact.inputOrdering == plan.inputOrdering,
              artifact.requestedPhotoSelection == plan.photoSelection,
              artifact.strategy == expectedStrategy else {
            throw PhotoSelectionProjectionError.planMismatch
        }

        let canonicalSourceSHA256s = receipts.map(\.source.sha256)
        guard canonicalSourceSHA256s
                == artifact.canonicalRetainedSourceSHA256s,
              receipts.count == artifact.retainedSourceSHA256s.count else {
            throw PhotoSelectionProjectionError.receiptBindingMismatch
        }

        let candidateBySourceSHA256 = Dictionary(
            uniqueKeysWithValues: artifact.candidates.map {
                ($0.evidence.sourceSHA256, $0)
            }
        )
        guard receipts.allSatisfy({ receipt in
            guard let candidate = candidateBySourceSHA256[receipt.source.sha256] else {
                return false
            }
            return receipt.schemaVersion == PhotoInputReceipt.currentSchemaVersion
                && receipt.analysisEvidence == candidate.evidence
                && receipt.retainedRank == candidate.retainedRank
        }) else {
            throw PhotoSelectionProjectionError.receiptBindingMismatch
        }

        let rankOrderedReceipts = receipts.sorted {
            $0.retainedRank < $1.retainedRank
        }
        guard rankOrderedReceipts.map(\.retainedRank)
                == Array(0..<receipts.count),
              rankOrderedReceipts.map(\.source.sha256)
                == artifact.retainedSourceSHA256s else {
            throw PhotoSelectionProjectionError.receiptBindingMismatch
        }

        return (
            Self(
                artifact: artifact,
                canonicalReceipts: receipts,
                rankOrderedReceipts: rankOrderedReceipts,
                policy: policy(for: artifact.strategy)
            ),
            loaded.leaseEvidence
        )
    }

    func project(targetCount: Int) throws -> [PhotoInputReceipt] {
        if policy == .preserve {
            guard targetCount == canonicalReceipts.count else {
                throw PhotoSelectionProjectionError.useAllRequiresFullCount(
                    expected: canonicalReceipts.count,
                    actual: targetCount
                )
            }
            return canonicalReceipts
        }
        guard (0...canonicalReceipts.count).contains(targetCount) else {
            throw PhotoSelectionProjectionError.invalidTargetCount(targetCount)
        }
        switch policy {
        case .rankedPrefix:
            return Array(rankOrderedReceipts.prefix(targetCount))
        case .evenlySpaced:
            return Self.evenlySpaced(
                canonicalReceipts,
                targetCount: targetCount
            )
        case .preserve:
            return canonicalReceipts
        }
    }

    private static func expectedStrategy(
        for plan: ResolvedRunPlan
    ) -> PhotoSelectionStrategy? {
        switch (plan.photoSelection, plan.inputOrdering) {
        case (.automatic, .continuous):
            .continuousEvenSpacing
        case (.automatic, .unordered):
            .visualDiversity
        case (.useAllValidPhotos, .continuous),
             (.useAllValidPhotos, .unordered):
            .useAll
        case (_, .automatic):
            nil
        }
    }

    private static func policy(
        for strategy: PhotoSelectionStrategy
    ) -> PhotoSelectionProjectionPolicy {
        switch strategy {
        case .visualDiversity:
            .rankedPrefix
        case .continuousEvenSpacing:
            .evenlySpaced
        case .useAll:
            .preserve
        }
    }

    private static func evenlySpaced<Element>(
        _ items: [Element],
        targetCount: Int
    ) -> [Element] {
        guard targetCount > 0, !items.isEmpty else { return [] }
        guard items.count > targetCount else { return items }
        guard targetCount > 1 else { return [items[items.count / 2]] }
        let step = Double(items.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            items[Int((Double(index) * step).rounded())]
        }
    }
}

extension PhotoSelectionReceipt {
    var isCurrentStructurallyValid: Bool {
        schemaVersion == PhotoSelectionReceipt.currentSchemaVersion
            && projectRelativePath == PhotoSelectionReceipt.projectRelativePath
            && projectRelativePath == PhotoSelectionArtifactStore.projectRelativePath
            && byteCount > 0
            && byteCount <= Int64(PhotoSelectionArtifactStore.maximumArtifactBytes)
            && sha256.utf8.count == 64
            && sha256.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
            && artifactSchemaVersion == PhotoSelectionArtifact.currentSchemaVersion
            && analysisRecipeVersion == PhotoAnalysisEvidenceBuilder.recipeVersion
            && analysisRecipeSHA256 == PhotoAnalysisEvidenceBuilder.recipeSHA256
            && selectorPolicyVersion == PhotoDiversitySelector.selectorPolicyVersion
            && selectorPolicySHA256 == PhotoDiversitySelector.selectorPolicySHA256
    }
}
