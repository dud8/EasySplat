import Darwin
import Foundation

final class GeometryWorkerExecutionRecorder: @unchecked Sendable {
    private enum QuarantineReason {
        case corrupt
        case staleBudget

        var fileNamePrefix: String {
            switch self {
            case .corrupt:
                return "worker_execution.corrupt-"
            case .staleBudget:
                return "worker_execution.stale-budget-"
            }
        }
    }

    private let lock = NSLock()
    private let paths: ProjectPaths
    private let budget: GeometryWorkerBudget
    private var artifact: GeometryWorkerExecutionArtifact
    private var recoveryBaselinePending = false
    private var activeMappingAttemptOrdinal: Int?

    private(set) var maximumSafeResumeBoundary: PipelineStage?

    var maximumRecordedMappingAttemptOrdinal: Int {
        lock.withLock {
            artifact.mappingAndRefinementInvocations
                .compactMap(\.mappingAttemptOrdinal)
                .max() ?? 0
        }
    }

    init(
        paths: ProjectPaths,
        budget: GeometryWorkerBudget,
        resumeAfter lastCompletedStage: PipelineStage?,
        inputHasVideos: Bool,
        resetForPlanChange: Bool = false
    ) throws {
        self.paths = paths
        self.budget = budget
        artifact = Self.emptyArtifact(budget: budget)
        maximumSafeResumeBoundary = nil
        let url = GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths)
        if Self.pathEntryExists(at: url) {
            do {
                artifact = try GeometryWorkerExecutionArtifactStore.load(
                    from: url,
                    projectPaths: paths
                )
            } catch {
                try Self.quarantineLedger(at: url, paths: paths, reason: .corrupt)
                artifact = Self.emptyArtifact(budget: budget)
                maximumSafeResumeBoundary = inputHasVideos ? .importInput : .selectFrames
                recoveryBaselinePending = true
            }
            if !recoveryBaselinePending {
                if resetForPlanChange {
                    artifact.resolvedBudget = budget
                    resetInvalidatedStages(after: lastCompletedStage)
                } else if artifact.resolvedBudget != budget {
                    try Self.quarantineLedger(
                        at: url,
                        paths: paths,
                        reason: .staleBudget
                    )
                    artifact = Self.emptyArtifact(budget: budget)
                    maximumSafeResumeBoundary = inputHasVideos ? .importInput : .selectFrames
                    recoveryBaselinePending = true
                }
            }
        } else if Self.evidenceShouldExist(
            after: lastCompletedStage,
            inputHasVideos: inputHasVideos
        ) {
            maximumSafeResumeBoundary = inputHasVideos ? .importInput : .selectFrames
            recoveryBaselinePending = true
        } else {
            artifact = Self.emptyArtifact(budget: budget)
        }
        if !recoveryBaselinePending {
            try persistLocked()
        }
    }

    func commitRecoveryBaseline() throws {
        try lock.withLock {
            guard recoveryBaselinePending else { return }
            guard !Self.pathEntryExists(
                at: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths)
            ) else {
                throw GeometryWorkerExecutionArtifactError.invalidLocation
            }
            try persistLocked()
            recoveryBaselinePending = false
        }
    }

    func record(_ invocation: ColmapWorkerInvocationEvidence) throws {
        try lock.withLock {
            var invocation = invocation
            switch invocation.command {
            case .featureExtractor, .featureImporter:
                guard invocation.mappingAttemptOrdinal == nil else {
                    throw GeometryWorkerExecutionArtifactError.invalidMappingAttemptOrdinal
                }
                artifact.featureExtractionInvocations.append(invocation)
            case .matchesImporter:
                guard invocation.mappingAttemptOrdinal == nil else {
                    throw GeometryWorkerExecutionArtifactError.invalidMappingAttemptOrdinal
                }
                artifact.matchingInvocations.append(invocation)
            case .localVocabularyRetriever:
                guard invocation.mappingAttemptOrdinal == nil else {
                    throw GeometryWorkerExecutionArtifactError.invalidMappingAttemptOrdinal
                }
                artifact.vocabularyRetrievalInvocations.append(invocation)
            case .mapper, .pointTriangulator, .bundleAdjuster, .modelAnalyzer,
                 .modelConverter:
                guard invocation.mappingAttemptOrdinal == nil,
                      let activeMappingAttemptOrdinal else {
                    throw GeometryWorkerExecutionArtifactError.invalidMappingAttemptOrdinal
                }
                invocation.mappingAttemptOrdinal = activeMappingAttemptOrdinal
                artifact.mappingAndRefinementInvocations.append(invocation)
            }
            try persistLocked()
        }
    }

    func beginMappingAttempt() throws -> Int {
        try lock.withLock {
            let maximum = artifact.mappingAndRefinementInvocations
                .compactMap(\.mappingAttemptOrdinal)
                .max() ?? 0
            let allocatedMaximum = max(maximum, activeMappingAttemptOrdinal ?? 0)
            guard allocatedMaximum < GeometryRecoveryState.maximumMappingAttemptCount else {
                throw GeometryRecoveryState.ValidationError.invalidMappingAttemptCount
            }
            let ordinal = allocatedMaximum + 1
            activeMappingAttemptOrdinal = ordinal
            return ordinal
        }
    }

    func invalidate(startingAt stage: PipelineStage) throws {
        try lock.withLock {
            switch stage {
            case .importInput, .extractFrames:
                artifact = Self.emptyArtifact(budget: budget)
                activeMappingAttemptOrdinal = nil
            case .selectFrames:
                artifact.featureExtractionInvocations.removeAll(keepingCapacity: false)
                artifact.matchingInvocations.removeAll(keepingCapacity: false)
                artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
                artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
                activeMappingAttemptOrdinal = nil
            case .sfmFeatures:
                artifact.featureExtractionInvocations.removeAll(keepingCapacity: false)
                artifact.matchingInvocations.removeAll(keepingCapacity: false)
                artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
                artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
                activeMappingAttemptOrdinal = nil
            case .sfmMatching:
                artifact.matchingInvocations.removeAll(keepingCapacity: false)
                artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
                artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
                activeMappingAttemptOrdinal = nil
            case .sfmMapping:
                artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
                activeMappingAttemptOrdinal = nil
            case .trainSplat, .exportSplat, .done:
                break
            }
            try persistLocked()
        }
    }

    func recordVideoSourceAnalysis(
        videoSourceCount: Int,
        snapshot: VideoSourceAnalysisConcurrencySnapshot
    ) throws {
        try lock.withLock {
            artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: videoSourceCount,
                startedAnalysisTaskCount: snapshot.startedAnalysisTaskCount,
                peakInFlightAnalysisTaskCount: snapshot.peakInFlightAnalysisTaskCount
            )
            try persistLocked()
        }
    }

    func validatedArtifact() throws -> GeometryWorkerExecutionArtifact {
        try lock.withLock {
            try artifact.validate(expectedBudget: budget)
            return artifact
        }
    }

    private static func emptyArtifact(
        budget: GeometryWorkerBudget
    ) -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
            resolvedBudget: budget,
            featureExtractionInvocations: [],
            matchingInvocations: [],
            vocabularyRetrievalInvocations: [],
            mappingAndRefinementInvocations: [],
            videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 0,
                startedAnalysisTaskCount: 0,
                peakInFlightAnalysisTaskCount: 0
            )
        )
    }

    private static func evidenceShouldExist(
        after lastCompletedStage: PipelineStage?,
        inputHasVideos: Bool
    ) -> Bool {
        guard let lastCompletedStage,
              let completedIndex = PipelineStage.allCases.firstIndex(of: lastCompletedStage),
              let evidenceIndex = PipelineStage.allCases.firstIndex(
                of: inputHasVideos ? .extractFrames : .sfmFeatures
              ) else {
            return false
        }
        return completedIndex >= evidenceIndex
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        if Darwin.lstat(url.path, &metadata) == 0 {
            return true
        }
        return errno != ENOENT
    }

    private static func quarantineLedger(
        at url: URL,
        paths: ProjectPaths,
        reason: QuarantineReason
    ) throws {
        do {
            _ = try paths.validateReservedProjectPath(
                url,
                relativePath: "SfM/worker_execution.json"
            )
        } catch {
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }

        var source = stat()
        guard Darwin.lstat(url.path, &source) == 0,
              (source.st_mode & S_IFMT) == S_IFREG,
              source.st_nlink == 1 else {
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }

        let fileName = reason.fileNamePrefix + UUID().uuidString.lowercased() + ".json"
        let destination = paths.logsURL.appendingPathComponent(fileName)
        do {
            _ = try paths.validateReservedProjectPath(
                destination,
                relativePath: "Logs/\(fileName)"
            )
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }

        var quarantined = stat()
        guard Darwin.lstat(destination.path, &quarantined) == 0,
              (quarantined.st_mode & S_IFMT) == S_IFREG,
              quarantined.st_nlink == 1,
              quarantined.st_dev == source.st_dev,
              quarantined.st_ino == source.st_ino else {
            _ = Darwin.unlink(destination.path)
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }
    }

    private func resetInvalidatedStages(after lastCompletedStage: PipelineStage?) {
        guard let lastCompletedStage,
              let completedIndex = PipelineStage.allCases.firstIndex(of: lastCompletedStage) else {
            artifact = Self.emptyArtifact(budget: budget)
            return
        }
        func completed(_ stage: PipelineStage) -> Bool {
            guard let index = PipelineStage.allCases.firstIndex(of: stage) else { return false }
            return index <= completedIndex
        }
        if !completed(.extractFrames) {
            artifact.videoSourceAnalysis = VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 0,
                startedAnalysisTaskCount: 0,
                peakInFlightAnalysisTaskCount: 0
            )
        }
        if !completed(.sfmFeatures) {
            artifact.featureExtractionInvocations.removeAll(keepingCapacity: false)
        }
        if !completed(.sfmMatching) {
            artifact.matchingInvocations.removeAll(keepingCapacity: false)
            artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
        }
        if !completed(.sfmMapping) {
            artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
        }
    }

    private func persistLocked() throws {
        try GeometryWorkerExecutionArtifactStore.save(
            artifact,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: budget,
            projectPaths: paths
        )
    }
}
