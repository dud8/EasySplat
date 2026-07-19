import Darwin
import Foundation

final class GeometryWorkerExecutionRecorder: @unchecked Sendable {
    private enum QuarantineReason {
        case corrupt
        case staleBudget
        case staleRuntimeClosure

        var fileNamePrefix: String {
            switch self {
            case .corrupt:
                return "worker_execution.corrupt-"
            case .staleBudget:
                return "worker_execution.stale-budget-"
            case .staleRuntimeClosure:
                return "worker_execution.stale-runtime-closure-"
            }
        }
    }

    private let lock = NSLock()
    private let paths: ProjectPaths
    private let budget: GeometryWorkerBudget
    private let runtimeClosure: ColmapRuntimeClosureEvidence
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

    func successfulModelConverterInvocationCount(
        mappingAttemptOrdinal: Int
    ) -> Int {
        lock.withLock {
            artifact.mappingAndRefinementInvocations.count {
                $0.mappingAttemptOrdinal == mappingAttemptOrdinal
                    && $0.command == .modelConverter
                    && $0.succeeded
            }
        }
    }

    func modelConverterInvocationCount(mappingAttemptOrdinal: Int) -> Int {
        lock.withLock {
            artifact.mappingAndRefinementInvocations.count {
                $0.mappingAttemptOrdinal == mappingAttemptOrdinal
                    && $0.command == .modelConverter
            }
        }
    }

    func modelConverterInvocation(
        mappingAttemptOrdinal: Int,
        oneBasedOrdinal: Int
    ) -> ColmapWorkerInvocationEvidence? {
        lock.withLock {
            let invocations = artifact.mappingAndRefinementInvocations.filter {
                $0.mappingAttemptOrdinal == mappingAttemptOrdinal
                    && $0.command == .modelConverter
            }
            guard oneBasedOrdinal > 0, oneBasedOrdinal <= invocations.count else {
                return nil
            }
            return invocations[oneBasedOrdinal - 1]
        }
    }

    func hasSuccessfulVocabularyRetrieval(attemptOrdinal: Int) -> Bool {
        lock.withLock {
            artifact.vocabularyRetrievalInvocations.contains {
                $0.succeeded && $0.pairExecution?.attemptOrdinal == attemptOrdinal
            }
        }
    }

    func matchingInvocations(
        attemptOrdinal: Int
    ) -> [ColmapWorkerInvocationEvidence] {
        lock.withLock {
            artifact.matchingInvocations.filter {
                $0.pairExecution?.attemptOrdinal == attemptOrdinal
            }
        }
    }

    init(
        paths: ProjectPaths,
        budget: GeometryWorkerBudget,
        runtimeClosure: ColmapRuntimeClosureEvidence,
        resumeAfter lastCompletedStage: PipelineStage?,
        inputHasVideos: Bool,
        resetForPlanChange: Bool = false
    ) throws {
        self.paths = paths
        self.budget = budget
        self.runtimeClosure = runtimeClosure
        guard runtimeClosure.isValid else {
            throw GeometryWorkerExecutionArtifactError.invalidRuntimeClosure
        }
        artifact = Self.emptyArtifact(budget: budget, runtimeClosure: runtimeClosure)
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
                artifact = Self.emptyArtifact(budget: budget, runtimeClosure: runtimeClosure)
                maximumSafeResumeBoundary = inputHasVideos ? .importInput : .selectFrames
                recoveryBaselinePending = true
            }
            if !recoveryBaselinePending {
                if artifact.colmapRuntimeClosure != runtimeClosure {
                    try Self.quarantineLedger(
                        at: url,
                        paths: paths,
                        reason: .staleRuntimeClosure
                    )
                    artifact = Self.emptyArtifact(
                        budget: budget,
                        runtimeClosure: runtimeClosure
                    )
                    maximumSafeResumeBoundary = inputHasVideos ? .importInput : .selectFrames
                    recoveryBaselinePending = true
                } else if resetForPlanChange {
                    artifact.resolvedBudget = budget
                    resetInvalidatedStages(after: lastCompletedStage)
                } else if artifact.resolvedBudget != budget {
                    try Self.quarantineLedger(
                        at: url,
                        paths: paths,
                        reason: .staleBudget
                    )
                    artifact = Self.emptyArtifact(budget: budget, runtimeClosure: runtimeClosure)
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
            artifact = Self.emptyArtifact(budget: budget, runtimeClosure: runtimeClosure)
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
                if invocation.succeeded,
                   let binding = invocation.pairExecution,
                   let existing = artifact.rejectedVocabularyRetrievalInvocations.first(where: {
                       $0.invocation.pairExecution?.retrievalRequestDigest
                            == binding.retrievalRequestDigest
                           && $0.invocation.pairExecution?.retrievalOutputDigest
                            == binding.retrievalOutputDigest
                   }) {
                    guard existing.invocation == invocation else {
                        throw GeometryWorkerExecutionArtifactError.incompleteStage
                    }
                    return
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

    func rejectCompletedVocabularyRetrieval(
        pairAttemptOrdinal: Int,
        planBinding: PairGraphPlanBinding,
        recoveryLevel: PairGraphRecoveryLevel,
        imageNames: [String],
        groups: [ColmapPairGroup],
        retrieval: PairGraphRetrievalAttemptEvidence,
        durationSeconds: Double
    ) throws {
        try lock.withLock {
            let requestDigest = PairGraphEvidenceStore.retrievalRequestDigest(retrieval)
            let outputDigest = retrieval.outputDigest
            if artifact.rejectedVocabularyRetrievalInvocations.contains(where: {
                $0.pairingPolicy == planBinding.pairingPolicy
                    && $0.planBinding == planBinding
                    && $0.recoveryLevel == recoveryLevel
                    && $0.imageNames == imageNames
                    && $0.groups == groups
                    && $0.retrieval == retrieval
                    && $0.invocation.pairExecution?.attemptOrdinal == pairAttemptOrdinal
                    && $0.invocation.pairExecution?.retrievalRequestDigest == requestDigest
                    && $0.invocation.pairExecution?.retrievalOutputDigest == outputDigest
            }) {
                return
            }
            let matches = artifact.vocabularyRetrievalInvocations.indices.filter { index in
                let invocation = artifact.vocabularyRetrievalInvocations[index]
                return invocation.command == .localVocabularyRetriever
                    && invocation.succeeded
                    && invocation.pairExecution?.attemptOrdinal == pairAttemptOrdinal
                    && invocation.pairExecution?.retrievalRequestDigest == requestDigest
                    && invocation.pairExecution?.retrievalOutputDigest == outputDigest
            }
            guard matches.count <= 1 else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }

            var candidate = artifact
            let invocation: ColmapWorkerInvocationEvidence
            if let invocationIndex = matches.first {
                invocation = candidate.vocabularyRetrievalInvocations.remove(
                    at: invocationIndex
                )
            } else if let prior = candidate.rejectedVocabularyRetrievalInvocations
                .last(where: {
                    $0.invocation.pairExecution?.attemptOrdinal == pairAttemptOrdinal
                        && $0.invocation.pairExecution?.retrievalRequestDigest == requestDigest
                        && $0.invocation.pairExecution?.retrievalOutputDigest == outputDigest
                }) {
                invocation = prior.invocation
            } else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            candidate.rejectedVocabularyRetrievalInvocations.append(
                RejectedVocabularyRetrievalExecutionEvidence(
                    retrievalAttemptOrdinal:
                        candidate.rejectedVocabularyRetrievalInvocations.count + 1,
                    pairingPolicy: planBinding.pairingPolicy,
                    planBinding: planBinding,
                    recoveryLevel: recoveryLevel,
                    imageNames: imageNames,
                    groups: groups,
                    invocation: invocation,
                    retrieval: retrieval,
                    durationSeconds: durationSeconds
                )
            )
            try candidate.validate(expectedBudget: budget)
            try GeometryWorkerExecutionArtifactStore.save(
                candidate,
                to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
                expectedBudget: budget,
                projectPaths: paths
            )
            artifact = candidate
        }
    }

    func discardPairPreparationWithoutMatcher(attemptOrdinal: Int) throws {
        try lock.withLock {
            guard attemptOrdinal > 0,
                  !artifact.matchingInvocations.contains(where: {
                      $0.pairExecution?.attemptOrdinal == attemptOrdinal
                  }) else {
                throw GeometryWorkerExecutionArtifactError.invalidInvocationCount
            }
            artifact.vocabularyRetrievalInvocations.removeAll {
                $0.pairExecution?.attemptOrdinal == attemptOrdinal
            }
            try persistLocked()
        }
    }

    /// Removes matcher receipts that were persisted by the subprocess termination
    /// callback but never committed to pair-graph attempt evidence. Vocabulary
    /// receipts remain durable because a restored policy attempt can reuse them.
    func discardUnacceptedMatcherInvocation(attemptOrdinal: Int) throws {
        try lock.withLock {
            guard attemptOrdinal > 0 else {
                throw GeometryWorkerExecutionArtifactError.invalidInvocationCount
            }
            let originalCount = artifact.matchingInvocations.count
            artifact.matchingInvocations.removeAll {
                $0.pairExecution?.attemptOrdinal == attemptOrdinal
            }
            guard artifact.matchingInvocations.count != originalCount else { return }
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

    func recordMapperEvaluation(
        mappingAttemptOrdinal: Int,
        evaluation: ColmapMapperEvaluationEvidence
    ) throws {
        try lock.withLock {
            guard mappingAttemptOrdinal > 0,
                  evaluation.isValid else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            let matches = artifact.mappingAndRefinementInvocations.indices.filter { index in
                let invocation = artifact.mappingAndRefinementInvocations[index]
                return invocation.command == .mapper
                    && invocation.mappingAttemptOrdinal == mappingAttemptOrdinal
                    && invocation.succeeded
            }
            guard matches.count == 1, let index = matches.first else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            if let existing = artifact.mappingAndRefinementInvocations[index]
                .mapperExecution?.evaluation {
                guard existing == evaluation else {
                    throw GeometryWorkerExecutionArtifactError.incompleteStage
                }
                return
            }
            guard artifact.mappingAndRefinementInvocations[index].mapperExecution != nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            var candidate = artifact
            candidate.mappingAndRefinementInvocations[index]
                .mapperExecution?.evaluation = evaluation
            try candidate.validate(expectedBudget: budget)
            try GeometryWorkerExecutionArtifactStore.save(
                candidate,
                to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
                expectedBudget: budget,
                projectPaths: paths
            )
            artifact = candidate
        }
    }

    func invalidate(startingAt stage: PipelineStage) throws {
        try lock.withLock {
            switch stage {
            case .importInput, .extractFrames:
                artifact = Self.emptyArtifact(budget: budget, runtimeClosure: runtimeClosure)
                activeMappingAttemptOrdinal = nil
            case .selectFrames:
                artifact.featureExtractionInvocations.removeAll(keepingCapacity: false)
                artifact.matchingInvocations.removeAll(keepingCapacity: false)
                artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
                artifact.rejectedVocabularyRetrievalInvocations.removeAll(
                    keepingCapacity: false
                )
                artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
                activeMappingAttemptOrdinal = nil
            case .sfmFeatures:
                artifact.featureExtractionInvocations.removeAll(keepingCapacity: false)
                artifact.matchingInvocations.removeAll(keepingCapacity: false)
                artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
                artifact.rejectedVocabularyRetrievalInvocations.removeAll(
                    keepingCapacity: false
                )
                artifact.mappingAndRefinementInvocations.removeAll(keepingCapacity: false)
                activeMappingAttemptOrdinal = nil
            case .sfmMatching:
                artifact.matchingInvocations.removeAll(keepingCapacity: false)
                artifact.vocabularyRetrievalInvocations.removeAll(keepingCapacity: false)
                artifact.rejectedVocabularyRetrievalInvocations.removeAll(
                    keepingCapacity: false
                )
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

    func rebindColmapRuntimeClosure(
        _ closure: ColmapRuntimeClosureEvidence
    ) throws {
        try lock.withLock {
            guard closure.isValid, closure == runtimeClosure else {
                throw GeometryWorkerExecutionArtifactError.invalidRuntimeClosure
            }
            artifact.colmapRuntimeClosure = closure
            try persistLocked()
        }
    }

    private static func emptyArtifact(
        budget: GeometryWorkerBudget,
        runtimeClosure: ColmapRuntimeClosureEvidence
    ) -> GeometryWorkerExecutionArtifact {
        GeometryWorkerExecutionArtifact(
            colmapRuntimeClosure: runtimeClosure,
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
            artifact = Self.emptyArtifact(budget: budget, runtimeClosure: runtimeClosure)
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
            artifact.rejectedVocabularyRetrievalInvocations.removeAll(
                keepingCapacity: false
            )
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
