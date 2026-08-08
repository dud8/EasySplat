import Foundation
import ImageIO
import SQLite3

enum CaptureFailureType: String, Sendable, Equatable {
    case disconnectedInput = "disconnected_input"
    case insufficientOverlap = "insufficient_overlap"
    case multipleScenes = "multiple_scenes"
}

extension PipelineRunner {
    enum ClassicalFeaturePreparationError: Error, LocalizedError, Equatable {
        case databaseStillPresent

        var errorDescription: String? {
            "The previous COLMAP feature database could not be removed safely."
        }
    }

    enum PipelineError: Error {
        case invalidInput
        case insufficientInputImages(Int)
        case lowQualityReconstruction(ReconstructionScore, mapper: String?)
        case fragmentedReconstruction(MappingFragmentationEvidence)
        case geometryCoverageTooLow(registered: Int, total: Int)
        case geometryResidualCoverageTooLow(measured: Int, total: Int)
        case geometryRegisteredImagesMismatch
        case geometryResidualsUnavailable(String)
        case geometryResidualsTooHigh(median: Double, p90: Double)
        case geometryConditioningRejected(GeometryConditioningFailure)
        case geometryProvenanceUnavailable(String)
        case geometryCameraModelMismatch(expected: String, actual: [String])
        case videoFrameBudgetTooSmall(required: Int, available: Int)
        case photoSelectionExceedsBudget(selected: Int, maximum: Int)
        case incompatibleSharedCameraDimensions
        case imageTranscodeFailed(String)
        case outputMissing
    }

    enum StageOutputStatus: Equatable, Sendable {
        case valid
        case missing
        case corrupt(reason: String)
    }

    static func captureFailureType(for error: Error) -> CaptureFailureType? {
        if error is CaptureRetrievalConnectionFailure
            || error is CaptureConnectionFailure {
            return .disconnectedInput
        }
        if let pairError = error as? ColmapPairPlanningError {
            switch pairError {
            case .disconnectedPairSchedule, .disconnectedVerifiedGraph:
                return .disconnectedInput
            case .invalidPairPlan, .pairLimitExceeded, .repeatedAttempt:
                return nil
            }
        }
        guard let pipelineError = error as? PipelineError else { return nil }
        switch pipelineError {
        case .fragmentedReconstruction:
            return .multipleScenes
        case .geometryConditioningRejected(let failure):
            switch failure {
            case .insufficientViewSupport,
                 .collapsedCameraTrajectory,
                 .insufficientParallax,
                 .degeneratePointDistribution:
                return .insufficientOverlap
            case .insufficientDistinctTrackViews,
                 .rayPairWorkLimitExceeded:
                return nil
            }
        case .lowQualityReconstruction,
             .geometryCoverageTooLow,
             .geometryResidualCoverageTooLow,
             .geometryResidualsTooHigh:
            return .insufficientOverlap
        case .invalidInput,
             .insufficientInputImages,
             .geometryRegisteredImagesMismatch,
             .geometryResidualsUnavailable,
             .geometryProvenanceUnavailable,
             .geometryCameraModelMismatch,
             .videoFrameBudgetTooSmall,
             .photoSelectionExceedsBudget,
             .incompatibleSharedCameraDimensions,
             .imageTranscodeFailed,
             .outputMissing:
            return nil
        }
    }

    struct ColmapSparseTextStats: Sendable {
        var registeredImageCount: Int?
        var pointCount: Int?
        var observationCount: Int?
        var meanTrackLength: Double?
    }

    private enum ColmapSparseTextScanError: Error, LocalizedError {
        case malformedRecord(file: String, line: Int)
        case countOverflow(file: String)

        var errorDescription: String? {
            switch self {
            case .malformedRecord(let file, let line):
                return "COLMAP model has a malformed \(file) record at line \(line)."
            case .countOverflow(let file):
                return "COLMAP model has too many records in \(file)."
            }
        }
    }

    func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItemIfPresent(_ url: URL) throws {
        let fm = FileManager.default
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
        if fm.fileExists(atPath: url.path) || isSymlink {
            try fm.removeItem(at: url)
        }
    }

    func removeIfExists(_ url: URL) {
        try? removeItemIfPresent(url)
    }

    func cleanupRawFramesAfterDurableSelection(
        paths: ProjectPaths,
        metadata: ProjectMetadata
    ) throws {
        let fileManager = FileManager.default
        let rawManifestExists = fileManager.fileExists(
            atPath: paths.framesRawManifestURL.path
        ) || ((try? fileManager.destinationOfSymbolicLink(
            atPath: paths.framesRawManifestURL.path
        )) != nil)
        guard metadata.input.hasVideos,
              rawManifestExists,
              try validateStageOutput(
                .selectFrames,
                paths: paths,
                metadata: metadata
              ) == .valid else {
            return
        }
        let rawExists = fileManager.fileExists(atPath: paths.framesRawURL.path)
            || ((try? fileManager.destinationOfSymbolicLink(
                atPath: paths.framesRawURL.path
            )) != nil)
        if rawExists {
            try fileManager.removeItem(at: paths.framesRawURL)
        }
        let rawStillExists = fileManager.fileExists(atPath: paths.framesRawURL.path)
            || ((try? fileManager.destinationOfSymbolicLink(
                atPath: paths.framesRawURL.path
            )) != nil)
        guard !rawStillExists else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: paths.framesRawURL.path]
            )
        }
        try fileManager.removeItem(at: paths.framesRawManifestURL)
    }

    /// Clears every artifact that could make a new feature database appear to belong
    /// to an earlier matching run. Public output is deliberately outside this set: a
    /// failed replacement run must not destroy the last validated splat.
    func prepareForClassicalFeatureExtraction(paths: ProjectPaths) throws {
        let fileManager = FileManager.default
        func removeItemIfPresent(_ url: URL) throws {
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(
                atPath: url.path
            )) != nil
            if fileManager.fileExists(atPath: url.path) || isSymlink {
                try fileManager.removeItem(at: url)
            }
        }

        let databaseURL = try paths.resolveProjectRelativePath(
            "SfM/colmap/database.db"
        )
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            URL(fileURLWithPath: databaseURL.path + "-journal"),
            paths.colmapFeatureEvidenceURL,
            paths.pairGraphEvidenceURL,
            paths.pairGraphRecoveryURL,
            paths.colmapSeedURL,
            paths.colmapSparseURL,
            paths.geometryManifestURL,
            paths.trainingURL,
        ] {
            try removeItemIfPresent(url)
        }

        let databaseIsSymlink = (try? fileManager.destinationOfSymbolicLink(
            atPath: databaseURL.path
        )) != nil
        guard !fileManager.fileExists(atPath: databaseURL.path),
              !databaseIsSymlink else {
            throw ClassicalFeaturePreparationError.databaseStillPresent
        }

        try resetDirectory(paths.colmapSeedURL)
        try resetDirectory(paths.colmapSparseURL)
    }

    func hasBoundTerminalPairRecovery(
        paths: ProjectPaths,
        resolvedRunPlan: ResolvedRunPlan
    ) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.pairGraphRecoveryURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedManifestURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedURL.path) else {
            return false
        }
        do {
            let manifest = try loadSelectedFrameManifest(
                from: paths.framesSelectedManifestURL
            )
            let imageNames = try loadImages(in: paths.framesSelectedURL)
                .map(\.lastPathComponent)
            guard imageNames == manifest.map(\.outputFileName) else {
                return false
            }
            let groups = try Self.colmapPairGroups(
                imageNames: imageNames,
                manifest: manifest
            )
            let recovered = try PairGraphRecoveryStore.loadBound(
                from: paths.pairGraphRecoveryURL,
                expectedImageNames: imageNames,
                expectedGroups: groups,
                projectPaths: paths
            ).restoredRecovery()
            return recovered.mode == .terminalExact
                && recovered.planBinding == PairGraphPlanBinding(resolvedRunPlan)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    func cleanForRetry(
        failedStage: PipelineStage,
        paths: ProjectPaths,
        preservingPairGraphRecovery: Bool = false
    ) throws {
        func removeAcceptedGeometryAndTraining() throws {
            try self.removeItemIfPresent(
                paths.colmapRefinementSeedModelURL.deletingLastPathComponent()
            )
            try self.removeItemIfPresent(paths.colmapSparseURL)
            try self.removeItemIfPresent(paths.geometryManifestURL)
            try self.removeItemIfPresent(paths.trainingURL)
        }

        switch failedStage {
        case .importInput:
            try removeAcceptedGeometryAndTraining()
        case .extractFrames:
            try self.removeItemIfPresent(paths.framesRawURL)
            try self.removeItemIfPresent(paths.framesRawManifestURL)
            try self.removeItemIfPresent(paths.framesSelectedURL)
            try self.removeItemIfPresent(paths.framesSelectedManifestURL)
            try self.removeItemIfPresent(paths.colmapDatabaseURL)
            try self.removeItemIfPresent(paths.colmapFeatureEvidenceURL)
            try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
            try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
            try self.removeItemIfPresent(paths.colmapSeedURL)
            try removeAcceptedGeometryAndTraining()
        case .selectFrames:
            try self.removeItemIfPresent(paths.framesSelectedURL)
            try self.removeItemIfPresent(paths.framesSelectedManifestURL)
            try self.removeItemIfPresent(paths.colmapDatabaseURL)
            try self.removeItemIfPresent(paths.colmapFeatureEvidenceURL)
            try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
            try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
            try self.removeItemIfPresent(paths.colmapSeedURL)
            try removeAcceptedGeometryAndTraining()
        case .sfmFeatures:
            try self.removeItemIfPresent(paths.colmapDatabaseURL)
            try self.removeItemIfPresent(paths.colmapFeatureEvidenceURL)
            try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
            try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
            try self.removeItemIfPresent(paths.colmapSeedURL)
            try removeAcceptedGeometryAndTraining()
        case .sfmMatching:
            let databaseIsSymlink =
                (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: paths.colmapDatabaseURL.path
                )) != nil
            if databaseIsSymlink {
                try self.removeItemIfPresent(paths.colmapDatabaseURL)
            } else if FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path),
                      !preservingPairGraphRecovery {
                // A preserved terminal recovery refers to the matches the
                // exact attempt left in the database; resume re-inspects them
                // instead of re-running the matcher. Any genuine re-matching
                // clears these tables itself before importing.
                try ColmapDatabaseMatchStore.clearMatchingResults(
                    at: paths.colmapDatabaseURL
                )
            }
            try self.removeItemIfPresent(paths.pairGraphEvidenceURL)
            if !preservingPairGraphRecovery {
                try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
            }
            try removeAcceptedGeometryAndTraining()
        case .sfmMapping:
            try self.removeItemIfPresent(paths.pairGraphRecoveryURL)
            try removeAcceptedGeometryAndTraining()
        case .trainSplat:
            return
        case .exportSplat:
            return
        case .done:
            return
        }
    }

    @discardableResult
    func invalidateAcceptedArtifactsForGeometryRerun(
        startingAt stage: PipelineStage,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws -> ProjectMetadata {
        try removeItemIfPresent(
            paths.colmapRefinementSeedModelURL.deletingLastPathComponent()
        )
        try removeItemIfPresent(paths.colmapSparseURL)
        try removeItemIfPresent(paths.geometryManifestURL)
        try removeItemIfPresent(paths.trainingURL)

        metadata.checkpoint = nil
        let rerunIndex = PipelineStage.allCases.firstIndex(of: stage) ?? 0
        metadata.stageTimings = metadata.stageTimings?.filter { timing in
            (PipelineStage.allCases.firstIndex(of: timing.stage) ?? 0) < rerunIndex
        }
        return try persistRequiredMetadata(
            metadata,
            paths: paths,
            operation: .runStart,
            stage: stage
        )
    }

    /// Invalidates every artifact downstream of a changed run policy before the new
    /// policy is committed. If the process stops during cleanup, project.json still
    /// contains the old policy and resume validation sees the missing output. Once the
    /// save succeeds, the persisted stage boundary is sufficient to resume safely.
    @discardableResult
    func persistResolvedPlanChange(
        _ resolvedPlan: ResolvedRunPlan,
        completedBoundary: PipelineStage?,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws -> ProjectMetadata {
        let fileManager = FileManager.default
        func removeInvalidatedItem(_ url: URL) throws {
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
            if fileManager.fileExists(atPath: url.path) || isSymlink {
                try fileManager.removeItem(at: url)
            }
        }

        let stages = PipelineStage.allCases
        let boundaryIndex = completedBoundary.flatMap(stages.firstIndex(of:)) ?? -1
        let extractFramesIndex = stages.firstIndex(of: .extractFrames) ?? 1
        let selectFramesIndex = stages.firstIndex(of: .selectFrames) ?? 2
        let featuresIndex = stages.firstIndex(of: .sfmFeatures) ?? 3
        let matchingIndex = stages.firstIndex(of: .sfmMatching) ?? 4
        let mappingIndex = stages.firstIndex(of: .sfmMapping) ?? 5
        let trainingIndex = stages.firstIndex(of: .trainSplat) ?? 6

        if boundaryIndex < extractFramesIndex {
            try removeInvalidatedItem(paths.framesRawURL)
            try removeInvalidatedItem(paths.framesRawManifestURL)
        }
        if boundaryIndex < selectFramesIndex {
            try removeInvalidatedItem(paths.framesSelectedURL)
            try removeInvalidatedItem(paths.framesSelectedManifestURL)
        }
        if boundaryIndex < featuresIndex {
            try removeInvalidatedItem(paths.colmapDatabaseURL)
            try removeInvalidatedItem(paths.colmapFeatureEvidenceURL)
            try removeInvalidatedItem(paths.colmapSeedURL)
            try removeInvalidatedItem(paths.da3CoverageManifestURL)
        } else if boundaryIndex < matchingIndex,
                  FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path) {
            try ColmapDatabaseMatchStore.clearMatchingResults(at: paths.colmapDatabaseURL)
        }
        if boundaryIndex < matchingIndex {
            try removeInvalidatedItem(paths.pairGraphEvidenceURL)
            try removeInvalidatedItem(paths.pairGraphRecoveryURL)
        }
        if boundaryIndex < mappingIndex {
            try removeInvalidatedItem(paths.colmapSparseURL)
            try removeInvalidatedItem(paths.geometryManifestURL)
        }
        if boundaryIndex < trainingIndex {
            try removeInvalidatedItem(paths.trainingURL)
        }

        metadata.stageTimings = metadata.stageTimings?.filter { timing in
            (stages.firstIndex(of: timing.stage) ?? stages.count) <= boundaryIndex
        }
        metadata.resolvedRunPlan = resolvedPlan
        metadata.geometryRecovery = nil
        metadata.state = PipelineState(stage: completedBoundary ?? .importInput, lastError: nil)
        metadata.checkpoint = nil
        metadata.lastFailureAt = nil
        try paths.ensureDirectories()
        return try persistRequiredMetadata(
            metadata,
            paths: paths,
            operation: .runStart,
            stage: completedBoundary ?? .importInput
        )
    }

    func failureMessages(for error: Error, stage: PipelineStage) -> (userMessage: String, debugMessage: String) {
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .invalidInput:
                return ("No usable photos or video frames were found.", String(reflecting: pipelineError))
            case let .insufficientInputImages(actual):
                return (
                    "At least \(RunPlanResolver.minimumReconstructionImageCount) usable photos or video frames are required.",
                    "Insufficient input images after selection: \(actual)."
                )
            case let .lowQualityReconstruction(score, _):
                let summary = ReconstructionScorer.summary(score)
                let onlyCoverageFailed = score.registeredImages > 0
                    && ReconstructionScorer.isAcceptable(
                        ReconstructionScore(
                            registeredImages: score.registeredImages,
                            totalImages: score.registeredImages,
                            meanReprojectionError: score.meanReprojectionError,
                            pointCount: score.pointCount,
                            observationCount: score.observationCount,
                            meanTrackLength: score.meanTrackLength
                        ),
                        capturePath: .automatic
                    )
                if onlyCoverageFailed {
                    return (
                        "The camera solve could only include \(score.registeredImages) of \(score.totalImages) photos, which is too few to build a reliable splat. Add photos that overlap the missing areas with clear shared detail.",
                        "Low-quality reconstruction. \(summary)."
                    )
                }
                return ("The camera solve was unstable. Try a slower capture with more light.", "Low-quality reconstruction. \(summary).")
            case let .fragmentedReconstruction(evidence):
                return (
                    "The scene could not be connected. Keep the subject and surroundings still, and include more shared detail between views.",
                    "Fragmented reconstruction: selected model \(evidence.selectedModelOrder) registered \(evidence.selectedRegisteredViewCount) of \(evidence.totalSelectedViewCount) views; credible union registered \(evidence.credibleUnionRegisteredViewCount), leaving \(evidence.omittedRecoverableViewCount) recoverable views outside the selected model."
                )
            case let .geometryCoverageTooLow(registered, total):
                return (
                    "The scene could not be connected. Keep the subject and surroundings still, and include more shared detail between views.",
                    "Accepted reconstruction registered \(registered) of \(total) selected views; at least 90% is required."
                )
            case let .geometryResidualCoverageTooLow(measured, total):
                return (
                    "Not enough of the capture could be verified. Try again with more overlap.",
                    "Only \(measured) of \(total) selected views contributed measurable tracks; at least 90% is required."
                )
            case .geometryRegisteredImagesMismatch:
                return (
                    "The camera solve did not match this capture. Try again.",
                    "Accepted reconstruction contains image names outside the selected-frame set."
                )
            case let .geometryResidualsUnavailable(reason):
                return (
                    "The camera solve could not be verified. Try a slower capture with more overlap.",
                    "Real pixel residuals were unavailable: \(reason)"
                )
            case let .geometryResidualsTooHigh(median, p90):
                return (
                    "The camera solve was not stable enough. Try a slower capture with more overlap.",
                    String(format: "Measured pixel residuals exceeded the gate: median %.3f px, p90 %.3f px.", median, p90)
                )
            case let .geometryConditioningRejected(failure):
                let debugMessage = "Geometry conditioning rejected the solve: \(failure.localizedDescription)"
                switch failure {
                case .insufficientViewSupport:
                    return (
                        "Not enough views contained reliable shared detail. Try again with more overlap.",
                        debugMessage
                    )
                case .collapsedCameraTrajectory:
                    return (
                        "The capture did not move through enough space. Move around or through the scene as you record.",
                        debugMessage
                    )
                case .insufficientParallax:
                    return (
                        "The views were too similar to recover stable depth. Move around or through the scene as you record.",
                        debugMessage
                    )
                case .degeneratePointDistribution:
                    return (
                        "The capture did not contain enough three-dimensional detail. Try more viewpoints with shared detail.",
                        debugMessage
                    )
                case .insufficientDistinctTrackViews:
                    return (
                        "The camera solve contained inconsistent track data.",
                        debugMessage
                    )
                case .rayPairWorkLimitExceeded:
                    return (
                        "This reconstruction exceeded the safe geometry-verification limit.",
                        debugMessage
                    )
                }
            case let .geometryProvenanceUnavailable(reason):
                return (
                    "The installed reconstruction tools could not be verified. Reinstall the required tools.",
                    "Geometry provenance was unavailable: \(reason)"
                )
            case let .geometryCameraModelMismatch(expected, actual):
                return (
                    "The reconstruction returned an incompatible camera model.",
                    "Expected DA3 camera model \(expected), received \(actual.joined(separator: ", "))."
                )
            case let .videoFrameBudgetTooSmall(required, available):
                return (
                    "This capture has too many separate clips for the selected detail.",
                    "Preserving clip endpoints requires \(required) frames; the resolved budget is \(available)."
                )
            case let .photoSelectionExceedsBudget(selected, maximum):
                return (
                    "Use all valid photos exceeds this Mac's safe plan. Choose Automatic selection.",
                    "Use all valid photos requested \(selected) photos; the resolved safe limit is \(maximum)."
                )
            case .incompatibleSharedCameraDimensions:
                return (
                    "These images do not share one pixel size. Choose Automatic or Mixed cameras or lenses.",
                    "Same camera and lens was requested, but the selected images have different pixel dimensions."
                )
            case let .imageTranscodeFailed(message):
                return ("Failed to convert photos for processing. Try exporting as JPEG/PNG.", message)
            case .outputMissing:
                return ("Processing failed. Expected outputs were missing.", String(reflecting: pipelineError))
            }
        }
        if case ColmapPairPlanningError.disconnectedPairSchedule = error {
            return (
                "The scene could not be connected. Keep the subject and surroundings still, and include more shared detail between views.",
                "The planned pair schedule remained disconnected before matching."
            )
        }
        if case ColmapPairPlanningError.disconnectedVerifiedGraph = error {
            return (
                "The scene could not be connected. Keep the subject and surroundings still, and include more shared detail between views.",
                "The spatially verified pair graph remained disconnected after matching."
            )
        }
        if let failure = error as? CaptureRetrievalConnectionFailure {
            let attempts = failure.attempts.map { attempt in
                let noNeighborCount = attempt.retrieval.queryOutcomes.count {
                    $0.status == .noRankedNeighbors
                }
                return "retrieval attempt \(attempt.retrievalAttemptOrdinal): "
                    + "recovery \(attempt.recoveryLevel.rawValue); "
                    + "\(attempt.retrieval.candidateCount) candidates; "
                    + "\(attempt.retrieval.returnedNeighborCount) requested neighbors; "
                    + "\(attempt.retrieval.queryOutcomes.count) queries; "
                    + "\(noNeighborCount) without ranked neighbors; "
                    + String(format: "%.2fs", attempt.durationSeconds)
            }.joined(separator: " | ")
            return (
                "EasySplat found separate parts of the capture. Add views between the gaps with clear shared detail, and keep the scene still.",
                "Capture connection failed before matching after all retrieval recovery attempts: policy \(failure.pairingPolicy.rawValue); \(failure.selectedViewCount) selected views; \(attempts)."
            )
        }
        if let failure = error as? CaptureConnectionFailure {
            let attempt = failure.attempt
            let largestGroup = failure.componentViewCounts.first ?? 0
            return (
                "EasySplat could not connect this capture into one scene. The largest connected group is \(largestGroup) of \(failure.selectedViewCount) photos. Add photos that overlap the missing areas with clear shared detail, and keep the scene still.",
                "Capture connection failed after all recovery attempts: policy \(failure.pairingPolicy.rawValue); \(failure.selectedViewCount) selected views; attempt \(attempt.attemptNumber); matcher \(attempt.matcher.rawValue); recovery \(attempt.recoveryLevel.rawValue); scheduled \(attempt.scheduledPairCount); attempted \(attempt.attemptedPairCount); raw matched \(attempt.rawMatchedPairCount); verified \(attempt.spatiallyVerifiedPairCount); \(failure.connectedComponentCount) components; \(failure.isolatedViewCount) isolated; \(failure.descriptorlessViewCount) descriptorless; component sizes \(failure.componentViewCounts); degree p10/median/p90 \(failure.degreeP10)/\(failure.degreeMedian)/\(failure.degreeP90)."
            )
        }
        if let memoryError = error as? MsplatRasterMemoryBudgetExceeded {
            return (
                "Training needs more memory than this run allows.",
                "Exact raster allocation required \(memoryError.requiredBytes) bytes at iteration \(memoryError.iteration); resolved budget \(memoryError.budgetBytes) bytes."
            )
        }
        if let resourceError = error as? MsplatRasterResourceLimitExceeded {
            return (
                "This scene exceeded Metal's size limit for one training buffer.",
                "Exact raster allocation required \(resourceError.requiredBytes) bytes at iteration \(resourceError.iteration); Metal maximum \(resourceError.maximumBufferBytes) bytes."
            )
        }
        if let allocationError = error as? MsplatMetalAllocationUnavailable {
            let intersections = allocationError.intersectionCount.map {
                "; \($0) intersections"
            } ?? ""
            return (
                "Training could not reserve unified memory. Close other demanding apps, then try again.",
                "Metal allocation failed at iteration \(allocationError.iteration): requested \(allocationError.requestedBytes) bytes; currently allocated \(allocationError.currentAllocatedBytes) bytes; required \(allocationError.requiredBytes) bytes; budget \(allocationError.budgetBytes) bytes; recommended working set \(allocationError.recommendedWorkingSetBytes) bytes; maximum buffer \(allocationError.maximumBufferBytes) bytes\(intersections)."
            )
        }
        if let admissionError = error as? TrainingResourceAdmissionError {
            switch admissionError {
            case .invalidObservation:
                return (
                    "Current memory availability could not be verified. Try again.",
                    "Live trainer admission rejected contradictory or invalid memory evidence."
                )
            case .staleObservation:
                return (
                    "Memory availability changed before training could start. Try again.",
                    "Live trainer admission evidence was older than the five-second launch boundary or came from a different boot."
                )
            case let .insufficientAvailableMemory(requiredBytes, availableBytes):
                return (
                    "Training needs more free unified memory. Close other demanding apps, then try again.",
                    "Live trainer admission required \(requiredBytes) bytes; available \(availableBytes) bytes."
                )
            }
        }
        if let subprocessFailure = error as? SubprocessFailure {
            return ("Processing failed. Check details for more info.", subprocessFailure.debugDescription)
        }
        if let colmapError = error as? ColmapRunnerError {
            let debug = debugDescription(for: colmapError)
            switch colmapError {
            case let .failed(_, exitCode, reason, _, _) where reason == .uncaughtSignal && exitCode == 10:
                return ("Image matching stopped. Try fewer frames or Fast detail.", debug)
            default:
                return ("Processing failed. Check details for more info.", debug)
            }
        }
        return ("Processing failed. Check details for more info.", String(reflecting: error))
    }

    static func requireDa3SeedCameraModel(
        at modelDirectory: URL,
        expectedCameraModel: String
    ) throws {
        let cameraModels = try ColmapResidualAnalyzer.cameraModels(
            modelDirectory: modelDirectory
        )
        let actualModels = Set(cameraModels.values)
        guard !actualModels.isEmpty,
              actualModels == [expectedCameraModel] else {
            throw PipelineError.geometryCameraModelMismatch(
                expected: expectedCameraModel,
                actual: actualModels.sorted()
            )
        }
    }

    func debugDescription(for error: ColmapRunnerError) -> String {
        switch error {
        case let .failed(command, exitCode, reason, stdoutTail, stderrTail):
            return """
            Colmap error: \(command)
            Exit code: \(exitCode)
            Termination reason: \(reason)
            Stdout tail:
            \(stdoutTail)
            Stderr tail:
            \(stderrTail)
            """
        case .executionEvidenceUnavailable(let command):
            return "COLMAP worker execution evidence was unavailable for \(command)."
        }
    }

    /// Surfaces a failed COLMAP attempt's cause at a retry boundary (matching OR mapping) as
    /// one prefixed log line: command, exit code, termination reason, and the last stderr line.
    /// Without this, a transient crash — e.g. a SIGSEGV that emits little or no stderr — shows
    /// only "failed, retrying" and the cause stays invisible unless a terminal failure follows,
    /// which it may not if the retry succeeds. The full stdout/stderr tails remain in the COLMAP
    /// tool log; non-COLMAP errors are left to the terminal path, which renders them in full.
    func emitColmapRetryDiagnostics(_ error: Error, stage: PipelineStage, emit: (PipelineEvent) -> Void) {
        guard case let ColmapRunnerError.failed(command, exitCode, reason, _, stderrTail) = error else { return }
        let lastStderrLine = stderrTail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        var detail = "Previous \(command) attempt failed: exit \(exitCode), \(reason)"
        if let lastStderrLine, !lastStderrLine.isEmpty {
            detail += " — \(lastStderrLine)"
        }
        emit(.stageLog(stage: stage, line: detail, isError: true))
    }

    /// Warn once an accepted COLMAP solve's mean track length is below this. A healthy
    /// solve threads each point through several views (~3-6); a shorter average means a thin,
    /// fragmented reconstruction.
    static let weakTrackLengthThreshold = 3.0

    /// Advisory only. The COLMAP acceptance gate checks registration ratio plus that
    /// metrics are non-empty, so a thin solve can pass where the neural-direct backends enforce
    /// real floors. This logs a heads-up for the COLMAP path without changing accept/reject, so
    /// a weak-but-accepted solve is not silent.
    func warnIfWeakAcceptedSolve(score: ReconstructionScore, mapper: String, emit: (PipelineEvent) -> Void) {
        guard let tracks = score.meanTrackLength, tracks < Self.weakTrackLengthThreshold else { return }
        emit(.stageLog(
            stage: .sfmMapping,
            line: "Accepted \(mapper) solve has a short mean track length (\(String(format: "%.1f", tracks)) < \(Self.weakTrackLengthThreshold)); it met the coverage bar but the geometry is thin, so the splat may be sparse or fragmented.",
            isError: true
        ))
    }

    /// Warn once a frame extracted fewer keypoints than this. A well-textured image yields
    /// thousands; a handful signals a flat/low-texture/degenerate frame that can fragment SfM.
    static let lowKeypointWarningThreshold = 100

    /// Reads the true per-image keypoint counts back from the COLMAP database after feature
    /// extraction and logs them. This build's COLMAP silently ignores the requested feature
    /// cap, so the count is content-driven; surfacing the real totals (and flagging frames
    /// that extracted almost nothing) turns an otherwise opaque stage into an honest signal.
    func logKeypointStats(database: URL, stage: PipelineStage = .sfmFeatures, emit: (PipelineEvent) -> Void) {
        guard let stats = ColmapDatabaseProgressPoller(databasePath: database).readKeypointStats() else { return }
        emit(.stageLog(
            stage: stage,
            line: "Extracted \(stats.totalKeypoints) keypoints across \(stats.imageCount) images (avg \(stats.averageKeypoints)/image, min \(stats.minKeypoints)).",
            isError: false
        ))
        if stats.minKeypoints < Self.lowKeypointWarningThreshold {
            emit(.stageLog(
                stage: stage,
                line: "At least one of \(stats.imageCount) frames extracted only \(stats.minKeypoints) keypoints (below \(Self.lowKeypointWarningThreshold)); low-texture or degenerate frames can weaken or fragment the reconstruction.",
                isError: true
            ))
        }
    }

    func validateStageOutput(
        _ stage: PipelineStage,
        paths: ProjectPaths,
        metadata: ProjectMetadata
    ) throws -> StageOutputStatus {
        try validateStageOutput(
            stage,
            paths: paths,
            metadata: metadata,
            selectedFrameSourceSHA256: { try GeometryArtifactStore.sha256(of: $0) }
        )
    }

    func validateStageOutput(
        _ stage: PipelineStage,
        paths: ProjectPaths,
        metadata: ProjectMetadata,
        selectedFrameSourceSHA256: (URL) throws -> String
    ) throws -> StageOutputStatus {
        let fm = FileManager.default
        switch stage {
        case .importInput:
            if metadata.input.videoFiles.isEmpty && metadata.input.photosFolder == nil {
                return .missing
            }
            let importedVideos = try importedVideoURLs(for: metadata.input.videoFiles, paths: paths)
            for dest in importedVideos {
                let name = dest.lastPathComponent
                guard fm.fileExists(atPath: dest.path) else { return .missing }
                let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 0 {
                    return .corrupt(reason: "input file \(name) has zero size")
                }
            }
            if let photosFolder = metadata.input.photosFolder {
                let name = URL(fileURLWithPath: photosFolder).lastPathComponent
                let dest = paths.importedPhotosURL
                guard fm.fileExists(atPath: dest.path) else { return .missing }
                let photos = try loadPhotos(in: dest)
                if photos.isEmpty, !metadata.input.hasVideos {
                    return .corrupt(reason: "photos folder \(name) is empty")
                }
            }
            return .valid
        case .extractFrames:
            guard metadata.input.hasVideos else { return .valid }
            let currentIndex = PipelineStage.allCases.firstIndex(of: metadata.state.stage) ?? 0
            let selectIndex = PipelineStage.allCases.firstIndex(of: .selectFrames) ?? 2
            if currentIndex >= selectIndex,
               try validateStageOutput(
                    .selectFrames,
                    paths: paths,
                    metadata: metadata,
                    selectedFrameSourceSHA256: selectedFrameSourceSHA256
               ) == .valid {
                return .valid
            }
            do {
                guard let receipts = metadata.videoInputReceipts,
                      receipts.count == metadata.input.videoFiles.count else {
                    return .corrupt(reason: "raw frame manifest has no input receipts")
                }
                let processingReceipts = try Self.videoReceiptsInProcessingOrder(
                    receipts,
                    pairingPolicy: metadata.resolvedRunPlan?.pairingPolicy
                )
                _ = try ExtractedFrameManifestStore.loadVerified(
                    paths: paths,
                    expectedSourceEvidence: processingReceipts.map(
                        ExtractedFrameSourceEvidence.init(receipt:)
                    ),
                    maximumTotalFrames: metadata.resolvedRunPlan?.keyframeBudget ?? 3_000
                )
            } catch ExtractedFrameManifestError.missingManifest {
                return .missing
            } catch {
                return .corrupt(reason: "raw frame manifest or extracted frames are invalid")
            }
            return .valid
        case .selectFrames:
            guard fm.fileExists(atPath: paths.framesSelectedURL.path) else { return .missing }
            let selectedDirectoryValues = try paths.framesSelectedURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard selectedDirectoryValues.isDirectory == true,
                  selectedDirectoryValues.isSymbolicLink != true else {
                return .corrupt(reason: "selected frame directory is unsafe")
            }
            guard fm.fileExists(atPath: paths.framesSelectedManifestURL.path) else {
                return .corrupt(reason: "selected frame manifest is missing")
            }
            let manifest: [SelectedFrameMapping]
            do {
                manifest = try loadSelectedFrameManifest(from: paths.framesSelectedManifestURL)
            } catch {
                return .corrupt(reason: "selected frame manifest is invalid JSON")
            }
            if manifest.count < RunPlanResolver.minimumReconstructionImageCount {
                return .corrupt(
                    reason: "selected frame manifest has fewer than "
                        + "\(RunPlanResolver.minimumReconstructionImageCount) frames"
                )
            }
            let files = try loadImages(in: paths.framesSelectedURL)
            if files.count != manifest.count {
                return .corrupt(reason: "selected frame file count (\(files.count)) does not match manifest (\(manifest.count))")
            }
            let imageNames = files.map(\.lastPathComponent)
            guard Set(imageNames).count == imageNames.count,
                  Set(manifest.map(\.outputFileName)).count == manifest.count,
                  imageNames == manifest.map(\.outputFileName) else {
                return .corrupt(reason: "selected frame manifest does not match the selected files")
            }
            guard let plan = metadata.resolvedRunPlan else {
                return .corrupt(reason: "selected frame manifest has no resolved run plan")
            }
            let photoSelectionProjection: PhotoSelectionProjection?
            do {
                photoSelectionProjection = try PhotoSelectionProjection.loadVerified(
                    metadata: metadata,
                    paths: paths
                )
            } catch {
                return .corrupt(reason: "photo selection evidence is missing or invalid")
            }
            let receiptPairs = (metadata.videoInputReceipts ?? []).map {
                ($0.projectRelativePath, $0.sha256)
            } + (metadata.photoInputReceipts ?? []).map {
                ($0.projectRelativePath, $0.sha256)
            }
            guard receiptPairs.count
                    == (metadata.videoInputReceipts?.count ?? 0)
                        + (metadata.photoInputReceipts?.count ?? 0),
                  Set(receiptPairs.map(\.0)).count == receiptPairs.count else {
                return .corrupt(reason: "selected frame receipts are invalid")
            }
            let receiptDigests = Dictionary(uniqueKeysWithValues: receiptPairs)
            let photoReceiptRanks = Dictionary(uniqueKeysWithValues:
                (metadata.photoInputReceipts ?? []).map {
                    ($0.projectRelativePath, $0.retainedRank)
                }
            )
            let expectedVideoGroups: [String: String]
            do {
                let videoReceipts = metadata.videoInputReceipts ?? []
                let identities = try VideoClipIdentityResolver.resolve(
                    sourceSHA256s: videoReceipts.map(\.sha256),
                    pairingPolicy: plan.pairingPolicy
                )
                expectedVideoGroups = Dictionary(uniqueKeysWithValues: identities.map {
                    let receipt = videoReceipts[$0.sourceIndex]
                    return (receipt.projectRelativePath, $0.groupID)
                })
            } catch {
                return .corrupt(reason: "selected video groups cannot be resolved")
            }
            var selectedPhotoLineage: [(path: String, retainedRank: Int)] = []
            var sourceSHA256ByPath: [String: String] = [:]
            for (index, entry) in manifest.enumerated() {
                let expectedPrefix = String(format: "frame_%06d.", index)
                guard entry.schemaVersion == SelectedFrameMapping.currentSchemaVersion,
                      entry.outputFileName.hasPrefix(expectedPrefix),
                      let sourcePath = entry.sourceProjectRelativePath,
                      sourcePath.hasPrefix("Originals/"),
                      let sourceSHA256 = entry.sourceSHA256,
                      GeometryArtifactStore.isSHA256(sourceSHA256),
                      receiptDigests[sourcePath] == sourceSHA256,
                      let selectedSHA256 = entry.selectedSHA256,
                      GeometryArtifactStore.isSHA256(selectedSHA256),
                      let selectedPixelSHA256 = entry.selectedPixelSHA256,
                      GeometryArtifactStore.isSHA256(selectedPixelSHA256),
                      let normalization = entry.normalization,
                      normalization.maximumPixelDimension == plan.maximumImageDimension else {
                    return .corrupt(reason: "selected frame manifest has incomplete lineage")
                }
                let source: URL
                do {
                    source = try paths.resolveProjectRelativePath(sourcePath)
                } catch {
                    return .corrupt(reason: "selected frame source path is unsafe")
                }
                let selected = paths.framesSelectedURL.appendingPathComponent(
                    entry.outputFileName
                )
                guard let selectedIdentity = try? Self.selectedFrameContentIdentity(
                    at: selected,
                    maximumPixelDimension: plan.maximumImageDimension
                ) else {
                    return .corrupt(reason: "selected frame lineage digest changed")
                }
                let observedSourceSHA256: String
                if let cached = sourceSHA256ByPath[sourcePath] {
                    observedSourceSHA256 = cached
                } else {
                    guard let calculated = try? selectedFrameSourceSHA256(source) else {
                        return .corrupt(reason: "selected frame lineage digest changed")
                    }
                    sourceSHA256ByPath[sourcePath] = calculated
                    observedSourceSHA256 = calculated
                }
                guard observedSourceSHA256 == sourceSHA256,
                      selectedIdentity.sha256 == selectedSHA256,
                      selectedIdentity.pixelSHA256 == selectedPixelSHA256 else {
                    return .corrupt(reason: "selected frame lineage digest changed")
                }
                if entry.isVideo {
                    guard entry.photoRetainedRank == nil,
                          entry.videoSource?.projectRelativePath == sourcePath,
                          entry.videoSource?.sourceSHA256 == sourceSHA256,
                          entry.videoSource?.isValidEvidence == true,
                          entry.videoOrigin?.isValidEvidence == true,
                          entry.timestampSeconds == entry.videoOrigin?.timestampSeconds,
                          expectedVideoGroups[sourcePath] == entry.groupId else {
                        return .corrupt(reason: "selected video sample lineage is invalid")
                    }
                } else {
                    guard let retainedRank = entry.photoRetainedRank,
                          retainedRank >= 0,
                          photoReceiptRanks[sourcePath] == retainedRank,
                          entry.groupId == "photos",
                          entry.videoSource == nil,
                          entry.videoOrigin == nil,
                          entry.timestampSeconds == nil else {
                        return .corrupt(reason: "selected photo lineage contains video evidence")
                    }
                    selectedPhotoLineage.append((sourcePath, retainedRank))
                }
            }
            let expectedPhotoLineage: [(path: String, retainedRank: Int)]
            do {
                expectedPhotoLineage = try photoSelectionProjection?
                    .project(targetCount: selectedPhotoLineage.count)
                    .map { ($0.projectRelativePath, $0.retainedRank) } ?? []
            } catch {
                return .corrupt(reason: "selected photo count does not match its projection")
            }
            guard selectedPhotoLineage.elementsEqual(
                expectedPhotoLineage,
                by: { observed, expected in
                    observed.path == expected.path
                        && observed.retainedRank == expected.retainedRank
                }
            ) else {
                return .corrupt(reason: "selected photos do not match their projection")
            }
            do {
                _ = try Self.colmapPairGroups(
                    imageNames: imageNames,
                    manifest: manifest
                )
            } catch {
                return .corrupt(reason: "selected frame manifest has invalid groups or timestamps")
            }
            if files.contains(where: { !ExtractedFrameManifestStore.isSafeRegularFrameFile($0) }) {
                return .corrupt(reason: "selected frame directory contains an unsafe file")
            }
            if files.contains(where: { !Self.canDecodeSelectedFrame($0) }) {
                return .corrupt(reason: "selected frame directory contains an unreadable image")
            }
            return .valid
        case .sfmFeatures:
            // Only the DA3 route publishes its raw aligned seed as the feature
            // boundary; a leftover seed must not mask missing classical
            // feature evidence on the COLMAP or imported-pose routes.
            let seedZero = paths.colmapSeedModelURL
            if metadata.resolvedRunPlan?.geometryBackend == .da3,
               sparseModelFilesExist(at: seedZero) {
                return .valid
            }
            let databaseStatus = validateColmapDatabaseOutput(
                paths: paths,
                requireMatches: false
            )
            guard databaseStatus == .valid else { return databaseStatus }
            guard let resolvedRunPlan = metadata.resolvedRunPlan else {
                return .corrupt(reason: "the resolved reconstruction plan is missing")
            }
            let checkpointReceipt: ColmapCameraGroupingReceipt?
            let checkpointInitializationReceipt: ColmapCameraInitializationReceipt?
            let checkpointFeatureDigest: String?
            if metadata.checkpoint?.stage == .sfmFeatures {
                guard case let .sfmFeatures(featureCheckpoint)? = metadata.checkpoint?.details,
                      let receipt = featureCheckpoint.cameraGroupingReceipt,
                      let initializationReceipt = featureCheckpoint.cameraInitializationReceipt,
                      let featureDigest = featureCheckpoint.featureDatabaseDigest else {
                    return .corrupt(reason: "the camera grouping checkpoint is missing")
                }
                checkpointReceipt = receipt
                checkpointInitializationReceipt = initializationReceipt
                checkpointFeatureDigest = featureDigest
            } else {
                checkpointReceipt = nil
                checkpointInitializationReceipt = nil
                checkpointFeatureDigest = nil
            }
            return try validateClassicalFeatureEvidence(
                paths: paths,
                resolvedRunPlan: resolvedRunPlan,
                detailProfile: metadata.requestedRunOptions.detailProfile,
                checkpointReceipt: checkpointReceipt,
                checkpointInitializationReceipt: checkpointInitializationReceipt,
                checkpointFeatureDigest: checkpointFeatureDigest
            )
        case .sfmMatching:
            let databaseStatus = validateColmapDatabaseOutput(
                paths: paths,
                requireMatches: true
            )
            guard databaseStatus == .valid else { return databaseStatus }
            guard let resolvedRunPlan = metadata.resolvedRunPlan else {
                return .corrupt(reason: "the resolved reconstruction plan is missing")
            }
            if resolvedRunPlan.geometryBackend == .da3 {
                let featureStatus = try validateClassicalFeatureEvidence(
                    paths: paths,
                    resolvedRunPlan: resolvedRunPlan,
                    detailProfile: metadata.requestedRunOptions.detailProfile,
                    checkpointReceipt: nil,
                    checkpointInitializationReceipt: nil,
                    checkpointFeatureDigest: nil
                )
                guard featureStatus == .valid else { return featureStatus }
                return try validateDa3MatchingEvidence(
                    paths: paths,
                    resolvedRunPlan: resolvedRunPlan
                )
            }
            let featureStatus = try validateClassicalFeatureEvidence(
                paths: paths,
                resolvedRunPlan: resolvedRunPlan,
                detailProfile: metadata.requestedRunOptions.detailProfile,
                checkpointReceipt: nil,
                checkpointInitializationReceipt: nil,
                checkpointFeatureDigest: nil
            )
            guard featureStatus == .valid else { return featureStatus }
            return try validateClassicalMatchingEvidence(
                paths: paths,
                resolvedRunPlan: resolvedRunPlan
            )
        case .sfmMapping:
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            guard sparseModelFilesExist(at: sparseZero) else { return .missing }
            let textStats: ColmapSparseTextStats
            do {
                textStats = try colmapSparseTextStats(at: sparseZero)
            } catch {
                return .corrupt(reason: error.localizedDescription)
            }
            for name in ["cameras.bin", "images.bin", "points3D.bin", "cameras.txt", "images.txt", "points3D.txt"] {
                let fileURL = sparseZero.appendingPathComponent(name)
                if !fm.fileExists(atPath: fileURL.path) { continue }
                let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 0 {
                    return .corrupt(reason: "sparse model file \(name) is empty")
                }
            }
            let pointsTxt = sparseZero.appendingPathComponent("points3D.txt")
            if fm.fileExists(atPath: pointsTxt.path) {
                guard (textStats.pointCount ?? 0) > 0 else {
                    return .corrupt(reason: "points3D.txt has no sparse points")
                }
                guard (textStats.observationCount ?? 0) > 0 else {
                    return .corrupt(reason: "points3D.txt has no observations")
                }
            }
            let imagesTxt = sparseZero.appendingPathComponent("images.txt")
            if fm.fileExists(atPath: imagesTxt.path) {
                if (textStats.registeredImageCount ?? 0) <= 0 {
                    return .corrupt(reason: "images.txt has no registered images")
                }
            } else {
                let imagesBin = sparseZero.appendingPathComponent("images.bin")
                let size = (try? fm.attributesOfItem(atPath: imagesBin.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 8 {
                    return .corrupt(reason: "images.bin appears truncated")
                }
            }
            do {
                _ = try GeometryArtifactStore.load(
                    from: paths.geometryManifestURL,
                    projectPaths: paths,
                    expectedInput: metadata.input
                )
            } catch {
                return .corrupt(reason: error.localizedDescription)
            }
            return .valid
        case .trainSplat:
            let artifact: TrainingArtifact
            do {
                artifact = try TrainingArtifactStore.load(
                    from: paths.trainingManifestURL,
                    projectPaths: paths
                )
            } catch where BoundedFileReader.isMissingFileError(error) {
                return .missing
            } catch {
                return .corrupt(reason: error.localizedDescription)
            }
            switch artifact.completionStatus {
                case .checkpointed:
                    return .missing
                case .completed:
                    do {
                        try TrainingArtifactStore.validateArtifact(
                            artifact,
                            projectPaths: paths
                        )
                    } catch {
                        return .corrupt(reason: error.localizedDescription)
                    }
                    guard artifact.detailProfile == metadata.effectiveDetailProfile else {
                        return .corrupt(
                            reason: "completed training profile does not match the requested detail"
                        )
                    }
                    if let plan = metadata.resolvedRunPlan {
                        guard artifact.matchesResolvedTrainingPlan(
                            plan,
                            resourcePolicy: metadata.requestedRunOptions.resourcePolicy
                        ) else {
                            return .corrupt(
                                reason: "completed training manifest does not match the resolved training plan"
                            )
                        }
                    }
                    guard let outputPath = artifact.outputPath else {
                        return .corrupt(reason: "completed training manifest has no output path")
                    }
                    let outputStatus: StageOutputStatus
                    do {
                        outputStatus = validatePlyFile(
                            at: try paths.resolveProjectRelativePath(outputPath)
                        )
                    } catch {
                        return .corrupt(reason: error.localizedDescription)
                    }
                    guard outputStatus == .valid else { return outputStatus }
                    do {
                        guard let plan = metadata.resolvedRunPlan else {
                            return .corrupt(
                                reason: "completed training has no current geometry or run plan"
                            )
                        }
                        let geometryArtifact = try GeometryArtifactStore.load(
                            from: paths.geometryManifestURL,
                            projectPaths: paths,
                            expectedInput: metadata.input
                        )
                        let derivation = try currentMsplatDatasetDerivation(
                            paths: paths,
                            geometryArtifact: geometryArtifact,
                            maxImageSize: plan.maximumImageDimension
                        )
                        guard artifact.inputDigest == derivation.datasetInputDigest,
                              artifact.geometryDigest == derivation.datasetGeometryDigest,
                              artifact.datasetDerivation == derivation else {
                            return .corrupt(
                                reason: "completed training manifest does not match current input, geometry, or derivation"
                            )
                        }
                    } catch {
                        return .corrupt(
                            reason: "completed training identity could not be verified: \(error.localizedDescription)"
                        )
                    }
                    return .valid
            }
        case .exportSplat, .done:
            let trainingArtifact: TrainingArtifact
            do {
                trainingArtifact = try TrainingArtifactStore.load(
                    from: paths.trainingManifestURL,
                    projectPaths: paths
                )
            } catch where BoundedFileReader.isMissingFileError(error) {
                return .missing
            } catch {
                return .corrupt(reason: error.localizedDescription)
            }
            guard trainingArtifact.completionStatus == .completed,
                  trainingArtifact.outputPath == "Output/splat.ply" else {
                return .missing
            }
            return validatePlyFile(at: paths.outputSplatURL)
        }
    }

    private static func videoReceiptsInProcessingOrder(
        _ receipts: [VideoInputReceipt],
        pairingPolicy: ResolvedPairingPolicy?
    ) throws -> [VideoInputReceipt] {
        guard let pairingPolicy else { return receipts }
        let identities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: receipts.map(\.sha256),
            pairingPolicy: pairingPolicy
        )
        return identities.map { receipts[$0.sourceIndex] }
    }

    private static func canDecodeSelectedFrame(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return false
        }
        return image.width > 0 && image.height > 0
    }

    func colmapSparseTextStats(at sparseZero: URL) throws -> ColmapSparseTextStats {
        let fileManager = FileManager.default
        let imagesTxt = sparseZero.appendingPathComponent("images.txt")
        var registeredImageCount: Int?
        if fileManager.fileExists(atPath: imagesTxt.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: imagesTxt.path)) != nil {
            let reader = try BoundedUTF8LineReader(
                at: imagesTxt,
                maximumBytes: ColmapTextFileLimits.images,
                maximumLineBytes: ColmapTextFileLimits.maximumLine
            )
            var count = 0
            var pendingPoseLine: Int?
            while let rawLine = try reader.next() {
                let line = rawLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if pendingPoseLine != nil {
                    try validateColmapImageObservations(line, lineNumber: rawLine.number)
                    pendingPoseLine = nil
                    continue
                }
                if line.isEmpty || line.hasPrefix("#") { continue }
                try validateColmapImagePose(line, lineNumber: rawLine.number)
                let increment = count.addingReportingOverflow(1)
                guard !increment.overflow else {
                    throw ColmapSparseTextScanError.countOverflow(file: "images.txt")
                }
                count = increment.partialValue
                pendingPoseLine = rawLine.number
            }
            if let pendingPoseLine {
                throw ColmapSparseTextScanError.malformedRecord(
                    file: "images.txt",
                    line: pendingPoseLine
                )
            }
            registeredImageCount = count
        }

        let pointsTxt = sparseZero.appendingPathComponent("points3D.txt")
        var pointCount: Int?
        var observationCount: Int?
        if fileManager.fileExists(atPath: pointsTxt.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: pointsTxt.path)) != nil {
            let reader = try BoundedUTF8LineReader(
                at: pointsTxt,
                maximumBytes: ColmapTextFileLimits.points,
                maximumLineBytes: ColmapTextFileLimits.maximumLine
            )
            var points = 0
            var observations = 0
            while let rawLine = try reader.next() {
                let line = rawLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let trackCount = try validateColmapPoint(line, lineNumber: rawLine.number)
                let nextPoints = points.addingReportingOverflow(1)
                guard !nextPoints.overflow else {
                    throw ColmapSparseTextScanError.countOverflow(file: "points3D.txt")
                }
                let nextObservations = observations.addingReportingOverflow(trackCount)
                guard !nextObservations.overflow else {
                    throw ColmapSparseTextScanError.countOverflow(file: "points3D.txt")
                }
                points = nextPoints.partialValue
                observations = nextObservations.partialValue
            }
            pointCount = points
            observationCount = observations
        }
        let meanTrackLength: Double?
        if let pointCount, let observationCount, pointCount > 0 {
            meanTrackLength = Double(observationCount) / Double(pointCount)
        } else {
            meanTrackLength = nil
        }

        return ColmapSparseTextStats(
            registeredImageCount: registeredImageCount,
            pointCount: pointCount,
            observationCount: observationCount,
            meanTrackLength: meanTrackLength
        )
    }

    private func validateColmapImagePose(_ line: String, lineNumber: Int) throws {
        var fields = ColmapTextTokenScanner(line)
        guard let imageIDField = fields.next(),
              let qwField = fields.next(),
              let qxField = fields.next(),
              let qyField = fields.next(),
              let qzField = fields.next(),
              let txField = fields.next(),
              let tyField = fields.next(),
              let tzField = fields.next(),
              let cameraIDField = fields.next(),
              fields.next() != nil,
              let imageID = Int(imageIDField), imageID > 0,
              let qw = Double(qwField), qw.isFinite,
              let qx = Double(qxField), qx.isFinite,
              let qy = Double(qyField), qy.isFinite,
              let qz = Double(qzField), qz.isFinite,
              let tx = Double(txField), tx.isFinite,
              let ty = Double(tyField), ty.isFinite,
              let tz = Double(tzField), tz.isFinite,
              let cameraID = Int(cameraIDField), cameraID > 0 else {
            throw ColmapSparseTextScanError.malformedRecord(
                file: "images.txt",
                line: lineNumber
            )
        }
        let quaternionNormSquared = qw * qw + qx * qx + qy * qy + qz * qz
        guard quaternionNormSquared.isFinite,
              quaternionNormSquared > 0 else {
            throw ColmapSparseTextScanError.malformedRecord(
                file: "images.txt",
                line: lineNumber
            )
        }
    }

    private func validateColmapImageObservations(_ line: String, lineNumber: Int) throws {
        var fields = ColmapTextTokenScanner(line)
        while let xField = fields.next() {
            guard let yField = fields.next(),
                  let pointIDField = fields.next(),
                  let x = Double(xField), x.isFinite,
                  let y = Double(yField), y.isFinite,
                  let pointID = Int64(pointIDField), pointID == -1 || pointID > 0 else {
                throw ColmapSparseTextScanError.malformedRecord(
                    file: "images.txt",
                    line: lineNumber
                )
            }
        }
    }

    private func validateColmapPoint(_ line: String, lineNumber: Int) throws -> Int {
        var fields = ColmapTextTokenScanner(line)
        guard let pointIDField = fields.next(),
              let xField = fields.next(),
              let yField = fields.next(),
              let zField = fields.next(),
              let redField = fields.next(),
              let greenField = fields.next(),
              let blueField = fields.next(),
              let errorField = fields.next(),
              let pointID = Int64(pointIDField), pointID > 0,
              let x = Double(xField), x.isFinite,
              let y = Double(yField), y.isFinite,
              let z = Double(zField), z.isFinite,
              let red = Int(redField), (0...255).contains(red),
              let green = Int(greenField), (0...255).contains(green),
              let blue = Int(blueField), (0...255).contains(blue),
              let error = Double(errorField), error.isFinite, error >= 0 else {
            throw ColmapSparseTextScanError.malformedRecord(
                file: "points3D.txt",
                line: lineNumber
            )
        }
        var trackCount = 0
        while let imageIDField = fields.next() {
            guard let point2DIndexField = fields.next(),
                  let imageID = Int(imageIDField), imageID > 0,
                  let point2DIndex = Int(point2DIndexField), point2DIndex >= 0 else {
                throw ColmapSparseTextScanError.malformedRecord(
                    file: "points3D.txt",
                    line: lineNumber
                )
            }
            let increment = trackCount.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw ColmapSparseTextScanError.countOverflow(file: "points3D.txt")
            }
            trackCount = increment.partialValue
        }
        guard trackCount > 0 else {
            throw ColmapSparseTextScanError.malformedRecord(
                file: "points3D.txt",
                line: lineNumber
            )
        }
        return trackCount
    }

    private struct ColmapTextTokenScanner {
        private let text: String
        private var index: String.Index

        init(_ text: String) {
            self.text = text
            index = text.startIndex
        }

        mutating func next() -> Substring? {
            while index < text.endIndex, text[index].isWhitespace {
                text.formIndex(after: &index)
            }
            guard index < text.endIndex else { return nil }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                text.formIndex(after: &index)
            }
            return text[start..<index]
        }
    }

    func isStageComplete(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) -> Bool {
        (try? validateStageOutput(stage, paths: paths, metadata: metadata)) == .valid
    }

    func validateColmapDatabaseOutput(paths: ProjectPaths, requireMatches: Bool) -> StageOutputStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.colmapDatabaseURL.path) else { return .missing }

        let size = (try? fm.attributesOfItem(atPath: paths.colmapDatabaseURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            return .corrupt(reason: "database.db is empty")
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let rc = sqlite3_open_v2(paths.colmapDatabaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            return .corrupt(reason: "database.db is unreadable")
        }

        func queryCount(_ sql: String) -> Int? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return nil
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Int(sqlite3_column_int64(statement, 0))
        }

        let imageCount = queryCount("SELECT COUNT(*) FROM images;")
        let keypointCount = queryCount("SELECT COUNT(*) FROM keypoints;")
        let matchesCount = queryCount("SELECT COUNT(*) FROM two_view_geometries;") ?? queryCount("SELECT COUNT(*) FROM matches;")

        guard let imageCount else {
            return .corrupt(reason: "database missing images table")
        }
        guard imageCount > 0 else {
            return .missing
        }
        guard let keypointCount else {
            return .corrupt(reason: "database missing keypoints table")
        }
        if keypointCount <= 0 {
            return .missing
        }
        if requireMatches {
            guard let matchesCount else {
                return .corrupt(reason: "database missing matches/two_view_geometries table")
            }
            if matchesCount <= 0 {
                return .missing
            }
        }
        return .valid
    }

    func validateClassicalMatchingEvidence(
        paths: ProjectPaths,
        resolvedRunPlan: ResolvedRunPlan
    ) throws -> StageOutputStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.pairGraphEvidenceURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedManifestURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedURL.path) else {
            return .missing
        }

        let manifest: [SelectedFrameMapping]
        let selectedFiles: [URL]
        do {
            manifest = try loadSelectedFrameManifest(from: paths.framesSelectedManifestURL)
            selectedFiles = try loadImages(in: paths.framesSelectedURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .corrupt(reason: "selected frame evidence is unreadable")
        }
        let manifestNames = manifest.map(\.outputFileName)
        let selectedNames = selectedFiles.map(\.lastPathComponent)
        guard !manifestNames.isEmpty,
              Set(manifestNames).count == manifestNames.count,
              manifestNames.allSatisfy({
                  !$0.isEmpty && !$0.contains(where: \.isWhitespace)
              }),
              selectedNames.count == manifestNames.count,
              Set(selectedNames) == Set(manifestNames) else {
            return .corrupt(reason: "selected frame evidence does not match the manifest")
        }

        do {
            let evidence = try PairGraphEvidenceStore.loadVerified(
                from: paths.pairGraphEvidenceURL,
                expectedImageNames: selectedNames,
                databaseURL: paths.colmapDatabaseURL,
                projectPaths: paths
            )
            guard evidence.planBinding == PairGraphPlanBinding(resolvedRunPlan) else {
                return .corrupt(reason: "image-pair evidence uses an obsolete camera initialization")
            }
            try PairGraphEvidenceStore.validateSchedule(
                evidence,
                resolvedPlan: resolvedRunPlan,
                groups: try Self.colmapPairGroups(
                    imageNames: selectedNames,
                    manifest: manifest
                )
            )
            return .valid
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .corrupt(reason: error.localizedDescription)
        }
    }

    func validateDa3MatchingEvidence(
        paths: ProjectPaths,
        resolvedRunPlan: ResolvedRunPlan
    ) throws -> StageOutputStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.pairGraphEvidenceURL.path),
              fileManager.fileExists(atPath: paths.da3CoverageManifestURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedManifestURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedURL.path),
              fileManager.fileExists(atPath: paths.workerExecutionURL.path) else {
            return .missing
        }
        do {
            let manifest = try loadSelectedFrameManifest(
                from: paths.framesSelectedManifestURL
            )
            let selectedFiles = try loadImages(in: paths.framesSelectedURL)
            let manifestNames = manifest.map(\.outputFileName)
            let selectedNames = selectedFiles.map(\.lastPathComponent)
            guard !manifestNames.isEmpty,
                  Set(manifestNames).count == manifestNames.count,
                  selectedNames.count == manifestNames.count,
                  Set(selectedNames) == Set(manifestNames) else {
                return .corrupt(
                    reason: "selected frame evidence does not match the manifest"
                )
            }
            let da3Manifest = try Da3CoverageManifest.load(
                from: paths.da3CoverageManifestURL
            )
            let pairPlan = try ColmapPairEstimator.validatedDa3RefinementPairPlan(
                manifest: da3Manifest,
                imageNames: selectedNames,
                resolvedPlan: resolvedRunPlan
            )
            let planBinding = PairGraphPlanBinding(resolvedRunPlan)
            let evidence = try PairGraphEvidenceStore.loadVerifiedDa3Refinement(
                from: paths.pairGraphEvidenceURL,
                expectedImageNames: selectedNames,
                expectedPlanBinding: planBinding,
                expectedPairPlan: pairPlan,
                databaseURL: paths.colmapDatabaseURL,
                projectPaths: paths
            )
            let workerExecution = try GeometryWorkerExecutionArtifactStore.load(
                from: paths.workerExecutionURL,
                expectedBudget: resolvedRunPlan.geometryWorkerBudget,
                projectPaths: paths
            )
            try PairGraphEvidenceStore.validateDa3WorkerExecution(
                evidence,
                expectedPlanBinding: planBinding,
                expectedPairPlan: pairPlan,
                workerExecution: workerExecution
            )
            return .valid
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .corrupt(reason: error.localizedDescription)
        }
    }

    func validateClassicalFeatureEvidence(
        paths: ProjectPaths,
        resolvedRunPlan: ResolvedRunPlan,
        detailProfile: DetailProfile,
        checkpointReceipt: ColmapCameraGroupingReceipt?,
        checkpointInitializationReceipt: ColmapCameraInitializationReceipt?,
        checkpointFeatureDigest: String?
    ) throws -> StageOutputStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.colmapFeatureEvidenceURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedManifestURL.path),
              fileManager.fileExists(atPath: paths.framesSelectedURL.path) else {
            return .missing
        }
        do {
            let manifest = try loadSelectedFrameManifest(
                from: paths.framesSelectedManifestURL
            )
            let selectedFiles = try loadImages(in: paths.framesSelectedURL)
            let manifestNames = manifest.map(\.outputFileName)
            let selectedNames = selectedFiles.map(\.lastPathComponent)
            guard !manifestNames.isEmpty,
                  Set(manifestNames).count == manifestNames.count,
                  selectedNames.count == manifestNames.count,
                  Set(selectedNames) == Set(manifestNames) else {
                return .corrupt(
                    reason: "selected frame evidence does not match the manifest"
                )
            }
            let cameraEvidence = try Self.colmapCameraGroupingEvidence(
                imageNames: selectedNames,
                manifest: manifest
            )
            let expectedCameraInitialization = try ColmapCameraInitializationReceipt.resolve(
                plan: resolvedRunPlan,
                detailProfile: detailProfile,
                selectedImages: selectedFiles
            )
            let evidence = try ColmapFeatureEvidenceStore.loadVerified(
                from: paths.colmapFeatureEvidenceURL,
                expectedImageNames: selectedNames,
                expectedCameraEvidence: cameraEvidence,
                expectedCameraGroupingMode: Self.colmapCameraGroupingMode(
                    cameraGrouping: resolvedRunPlan.cameraGrouping,
                    evidence: cameraEvidence
                ),
                expectedCameraInitializationReceipt: expectedCameraInitialization,
                databaseURL: paths.colmapDatabaseURL,
                projectPaths: paths
            )
            guard checkpointReceipt.map({
                evidence.cameraGroupingReceipt == $0
            }) ?? true,
                  checkpointInitializationReceipt.map({
                      evidence.cameraInitializationReceipt == $0
                  }) ?? true,
                  checkpointFeatureDigest.map({
                      evidence.featureDatabaseDigest == $0
                  }) ?? true else {
                return .corrupt(
                    reason: "the camera grouping checkpoint does not match feature evidence"
                )
            }
            return .valid
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .corrupt(reason: error.localizedDescription)
        }
    }

    func validatePlyFile(at url: URL) -> StageOutputStatus {
        switch ProjectArtifactValidator.validatePlyFile(at: url) {
        case .valid:
            return .valid
        case .missing:
            return .missing
        case .corrupt(let reason):
            return .corrupt(reason: reason)
        }
    }
}
