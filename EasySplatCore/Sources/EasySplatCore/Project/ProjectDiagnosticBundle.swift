import Foundation

/// Builds a paste-ready diagnostic summary for a single project. The output is a
/// markdown-flavored text block containing pipeline metadata, stage timings, and
/// trimmed tails of the relevant log files. Designed for bug reports: no
/// machine-specific home-directory paths leak through, byte budgets keep the
/// text manageable in chat/email clients, and missing or empty logs are skipped
/// without making bundle creation fail.
public enum ProjectDiagnosticBundle {
    /// Maximum lines retained from each log tail. Tuned to keep the bundle under
    /// ~64 KB even when several logs are present.
    public static let defaultTailLineLimit = 120
    public static let defaultTailByteLimit = 32 * 1024

    /// Schema version embedded in the machine-readable JSON block. Bump
    /// when adding/removing/renaming top-level keys so downstream tools can
    /// detect a format change.
    public static let machineReadableSchemaVersion = 19

    /// Scrub a user-visible technical payload before it reaches a clipboard,
    /// save panel, or share surface. Project identity is included when the
    /// project metadata is readable; path and URL scrubbing always applies.
    public static func sanitizeForSharing(
        _ text: String,
        projectURL: URL? = nil
    ) -> String {
        var sensitiveValues: [String] = []
        if let projectURL {
            sensitiveValues.append(projectURL.lastPathComponent)
            if let metadata = try? ProjectMetadataStore.load(
                from: ProjectPaths(root: projectURL).metadataURL
            ) {
                sensitiveValues.append(metadata.title)
                sensitiveValues.append(metadata.id.uuidString)
            }
        }
        return HomePathSanitizer(sensitiveValues: sensitiveValues).sanitize(text)
    }

    /// Compose the diagnostic text for the project rooted at `projectURL`.
    /// `hardwareLine` lets the caller inject a one-line hardware summary that
    /// only the app knows (e.g., macOS version, Mac model). Returns `nil` when
    /// the project metadata cannot be loaded — there is nothing useful to share.
    ///
    /// `includeNotes` defaults to `false` so the bundle is safe to paste into
    /// a public bug report. Notes are user-authored free text and can contain
    /// locations, names, or other private context the user did not intend to
    /// share. Opt in explicitly when the caller knows the destination is
    /// trustworthy.
    public static func build(
        projectURL: URL,
        hardwareLine: String? = nil,
        includeNotes: Bool = false,
        now: Date = Date(),
        tailLineLimit: Int = defaultTailLineLimit,
        tailByteLimit: Int = defaultTailByteLimit
    ) -> String? {
        let paths = ProjectPaths(root: projectURL)
        let snapshot = try? ProjectArtifactSnapshotStore.load(projectURL: projectURL)
        guard let metadata = snapshot?.metadata
                ?? (try? ProjectMetadataStore.load(from: paths.metadataURL)) else {
            return nil
        }
        // A corrupt or torn sidecar is exactly when diagnostics matter most.
        // Keep artifact facts absent unless the combined snapshot authenticated
        // them; metadata and bounded logs remain safe to report.
        let geometry = snapshot?.geometryArtifact
        let training = snapshot?.trainingArtifact
        let pathSanitizer = HomePathSanitizer(
            sensitiveValues: [metadata.title, metadata.id.uuidString, projectURL.lastPathComponent]
        )
        let pairMatchingRecovery = validatedPairMatchingRecovery(
            metadata: metadata,
            paths: paths
        )
        let rejectedVocabularyRetrievals = validatedRejectedVocabularyRetrievals(
            metadata: metadata,
            paths: paths
        )
        let subjectIsolation = SubjectIsolationArtifactStore.load(paths: paths)

        var sections: [String] = []
        sections.append(buildHeader(metadata: metadata, now: now, hardwareLine: hardwareLine, includeNotes: includeNotes))

        if includeNotes,
           let notes = metadata.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            // Cap the note body so a runaway entry can't dominate the bundle
            // and sanitize the home path the same way log tails are.
            let cap = 2048
            let truncated = String(notes.prefix(cap))
            let sanitized = pathSanitizer.sanitize(truncated)
            let suffix = notes.count > cap ? "\n…(notes truncated to \(cap) characters)" : ""
            sections.append("## Notes\n\(sanitized)\(suffix)")
        }
        if let reconstructionSection = reconstructionSection(
            metadata: metadata,
            geometry: geometry,
            sanitizer: pathSanitizer
        ) {
            sections.append(reconstructionSection)
        }
        if let timingSection = stageTimingSection(metadata: metadata) {
            sections.append(timingSection)
        }
        if let stateSection = stateSection(
            metadata: metadata,
            training: training,
            pairMatchingRecovery: pairMatchingRecovery,
            rejectedVocabularyRetrievals: rejectedVocabularyRetrievals,
            sanitizer: pathSanitizer
        ) {
            sections.append(stateSection)
        }
        sections.append(subjectIsolationSection(subjectIsolation))
        if let machineSection = machineReadableSection(
            metadata: metadata,
            geometry: geometry,
            training: training,
            pairMatchingRecovery: pairMatchingRecovery,
            rejectedVocabularyRetrievals: rejectedVocabularyRetrievals,
            sanitizer: pathSanitizer
        ) {
            sections.append(machineSection)
        }

        let logSources: [(label: String, url: URL)] = [
            ("pipeline.log", paths.pipelineLogURL),
            ("colmap.log", paths.colmapLogURL),
            ("da3.log", paths.da3LogURL),
            ("msplat.log", paths.msplatLogURL),
            ("isolation.log", paths.isolationLogURL)
        ]
        for source in logSources {
            guard (try? paths.projectRelativePath(for: source.url)) != nil else { continue }
            if let tail = logTailSection(label: source.label, url: source.url, sanitizer: pathSanitizer, tailLineLimit: tailLineLimit, tailByteLimit: tailByteLimit) {
                sections.append(tail)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private static func buildHeader(
        metadata: ProjectMetadata,
        now: Date,
        hardwareLine: String?,
        includeNotes: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("# EasySplat Diagnostic Bundle")
        lines.append("Generated: \(iso8601(now))")
        lines.append("Privacy: \(includeNotes ? "notes opted in" : "notes excluded by default")")
        lines.append("Created: \(iso8601(metadata.createdAt))")
        let options = metadata.requestedRunOptions
        lines.append("Options: capture=\(options.capturePath.rawValue) detail=\(options.detailProfile.rawValue)")
        if let workers = metadata.resolvedRunPlan?.geometryWorkerBudget {
            let videoSourceLimit = workers.maximumConcurrentVideoSourceAnalysisTasks
            let clipNoun = videoSourceLimit == 1 ? "clip" : "clips"
            lines.append(
                "Geometry workers: extract \(workers.featureExtractionWorkers) · "
                    + "match \(workers.coupledMatchingWorkers) · "
                    + "retrieve \(workers.vocabularyRetrievalWorkers)"
            )
            lines.append(
                "Video source analysis: up to "
                    + "\(videoSourceLimit) \(clipNoun) at once"
            )
        }
        switch metadata.input {
        case .video(let files):
            lines.append("Input: \(files.count) video(s)")
        case .photos:
            lines.append("Input: photos folder")
        case .mixed(let videos, _):
            lines.append("Input: mixed (\(videos.count) videos + photos folder)")
        }
        if let hardwareLine, !hardwareLine.isEmpty {
            lines.append("Hardware: \(hardwareLine)")
        }
        return lines.joined(separator: "\n")
    }

    private static func reconstructionSection(
        metadata: ProjectMetadata,
        geometry: GeometryArtifact?,
        sanitizer: HomePathSanitizer
    ) -> String? {
        guard let geometry else { return nil }
        let mapping = geometry.mapping
        var lines: [String] = ["## Reconstruction"]
        lines.append("Solver: \(geometry.solverVersion)")
        lines.append("Registered: \(geometry.registeredViewCount) / \(geometry.totalViewCount)")
        lines.append("Points: \(geometry.pointCount)")
        lines.append("Observations: \(geometry.observationCount)")
        lines.append(
            "Median residual: \(String(format: "%.3f px", geometry.medianPixelResidual))"
        )
        lines.append(
            "P90 residual: \(String(format: "%.3f px", geometry.p90PixelResidual))"
        )
        if let grouping = geometry.cameraGroupingReceipt {
            lines.append(
                "Camera grouping: \(grouping.mode.rawValue) · \(geometry.totalViewCount) images · "
                    + "\(grouping.cameraCountBefore) → \(grouping.cameraCountAfter) cameras"
            )
        }
        lines.append(
            "Models: \(mapping.modelCount) "
                + "(largest \(mapping.largestModelRegisteredViewCount), "
                + "second \(mapping.secondLargestModelRegisteredViewCount))"
        )
        lines.append("Union registered: \(mapping.unionRegisteredViewCount)")
        lines.append("Mapping attempts: \(mapping.attemptCount)")
        lines.append(
            "Accepted mapping attempt: \(mapping.acceptedMappingAttemptOrdinal)"
        )
        let invocationLabel = mapping.acceptedRefinementInvocationCount == 1
            ? "invocation"
            : "invocations"
        let refinementName = switch mapping.acceptedRefinementKind {
        case .incrementalGlobal: "Incremental global"
        case .seededBundleAdjustment: "Seeded bundle adjustment"
        }
        lines.append(
            "Accepted refinement: \(refinementName) "
                + "(\(mapping.acceptedRefinementInvocationCount) \(invocationLabel))"
        )
        if let plannedCadence = mapping.plannedIncrementalCadence,
           plannedCadence != mapping.incrementalCadence {
            lines.append(
                "Bundle adjustment plan: local \(plannedCadence.localMaxRefinements), "
                    + "global \(String(format: "%.1f", plannedCadence.globalFramesRatio))× frames / "
                    + "\(String(format: "%.1f", plannedCadence.globalPointsRatio))× points, "
                    + "up to \(plannedCadence.globalMaxRefinements) refinements"
            )
        }
        if let cadence = mapping.incrementalCadence {
            let label = mapping.plannedIncrementalCadence == cadence
                ? "Bundle adjustment"
                : "Bundle adjustment accepted"
            lines.append(
                "\(label): local \(cadence.localMaxRefinements), "
                    + "global \(String(format: "%.1f", cadence.globalFramesRatio))× frames / "
                    + "\(String(format: "%.1f", cadence.globalPointsRatio))× points, "
                    + "up to \(cadence.globalMaxRefinements) refinements"
            )
        }
        if let trigger = mapping.cadenceFallbackTrigger {
            lines.append("Bundle adjustment retry trigger: \(trigger.rawValue)")
        }
        if let fallbackReason = mapping.fallbackReason {
            lines.append("Mapping fallback: \(sanitizer.sanitize(fallbackReason))")
        }
        return lines.joined(separator: "\n")
    }

    private static func stageTimingSection(metadata: ProjectMetadata) -> String? {
        let timings = metadata.stageTimings ?? []
        guard metadata.createToViewerReadySeconds != nil || !timings.isEmpty else { return nil }
        var lines: [String] = ["## Stage Timings"]
        if let total = metadata.createToViewerReadySeconds {
            lines.append("Create-to-viewer-ready: \(Int(total.rounded()))s")
        }
        for record in timings.sorted(by: { $0.startedAt < $1.startedAt }) {
            let seconds = Int(record.durationSeconds.rounded())
            lines.append("- \(record.stage.rawValue): \(seconds)s")
        }
        if let total = timings.totalDurationSeconds {
            lines.append("Stage total: \(Int(total.rounded()))s")
        }
        return lines.joined(separator: "\n")
    }

    private static func subjectIsolationSection(
        _ result: IsolationArtifactLoadResult
    ) -> String {
        var lines = ["## Subject Isolation"]
        switch result {
        case .noArtifact:
            lines.append("Status: no artifact")
        case .invalid:
            lines.append("Status: invalid")
        case .stale(let reason):
            lines.append("Status: stale (\(staleReasonLabel(reason)))")
        case .valid(let artifact, let output):
            lines.append("Status: valid")
            lines.append("Variant: subject")
            lines.append(
                "Provenance: canonical source, training receipt, and dataset identity matched"
            )
            lines.append("Toolchain build identity: recorded")
            lines.append("Native executable SHA-256: \(artifact.nativeExecutableSHA256)")
            lines.append(
                "Mask views: \(artifact.masks.count) · selected: "
                    + "\(artifact.selectedViewIdentities.count) · held out: "
                    + "\(artifact.heldOutViewIdentities.count)"
            )
            lines.append(
                "Vision request revision: \(artifact.visionRequestRevision) · "
                    + "policy revision: \(artifact.policy.version)"
            )
            lines.append(
                "Subject output: \(output.gaussianCount) gaussians · "
                    + "\(output.byteCount) bytes"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func staleReasonLabel(_ reason: IsolationArtifactStaleReason) -> String {
        switch reason {
        case .sourceOutput: "source output"
        case .trainingManifest: "training receipt"
        case .datasetIdentity: "dataset identity"
        }
    }

    private static func stateSection(
        metadata: ProjectMetadata,
        training: TrainingArtifact?,
        pairMatchingRecovery: PairGraphRecoveryState?,
        rejectedVocabularyRetrievals: [RejectedVocabularyRetrievalExecutionEvidence],
        sanitizer: HomePathSanitizer
    ) -> String? {
        var lines: [String] = ["## Pipeline State"]
        lines.append("Current stage: \(metadata.state.stage.rawValue)")
        if let lastFailureAt = metadata.lastFailureAt {
            lines.append("Last failure: \(iso8601(lastFailureAt))")
        }
        if let lastError = metadata.state.lastError, !lastError.isEmpty {
            lines.append("Last error: \(sanitizer.sanitize(lastError))")
        }
        if let checkpoint = metadata.checkpoint {
            lines.append("Checkpoint stage: \(checkpoint.stage.rawValue)")
            if let progress = checkpoint.progressFraction {
                lines.append("Checkpoint progress: \(String(format: "%.1f%%", progress * 100))")
            }
            if let message = checkpoint.message, !message.isEmpty {
                lines.append("Checkpoint message: \(sanitizer.sanitize(message))")
            }
        }
        if let recovery = metadata.geometryRecovery {
            lines.append("Recovery backend: \(recovery.activeBackend.rawValue)")
            lines.append("Recovery mapping attempts: \(recovery.mappingAttemptCount)")
            if let mode = recovery.colmapComputeMode {
                lines.append("Recovery compute: \(mode.rawValue)")
            }
            if let level = recovery.pendingPairRecoveryLevel {
                lines.append("Pending pair recovery: \(level.rawValue)")
            }
            if let trigger = recovery.cadenceFallbackTrigger {
                lines.append("Recovery cadence retry: \(trigger.rawValue)")
            }
            if let pairAttempt = recovery.acceptedPairAttemptOrdinal {
                lines.append("Recovery pair attempt: \(pairAttempt)")
            }
            for reason in recovery.mappingFallbackReasons {
                lines.append("Recovery reason: \(sanitizer.sanitize(reason))")
            }
        }
        if let trainingResource = trainingResourceEvidence(training: training) {
            lines.append(
                "Training memory: \(trainingResource.memoryBudgetBytes) bytes budgeted of "
                    + "\(trainingResource.admission.allowedTrainerBytes) bytes admitted; "
                    + "\(trainingResource.peakMemoryBytes) bytes peak"
            )
        }
        if let pairMatchingRecovery {
            lines.append("Matching attempts: \(pairMatchingRecovery.attempts.count)")
            lines.append(String(
                format: "Matching time: %.2fs",
                pairMatchingRecovery.matchingDurationSeconds
            ))
            for attempt in pairMatchingRecovery.attempts.map(\.artifact) {
                lines.append(
                    "Matching attempt \(attempt.attemptNumber): "
                        + "\(attempt.matcher.rawValue), \(attempt.outcome.rawValue) · "
                        + "\(attempt.scheduledPairCount) scheduled · "
                        + "\(attempt.attemptedPairCount) attempted · "
                        + "\(attempt.rawMatchedPairCount) raw · "
                        + "\(attempt.spatiallyVerifiedPairCount) verified · "
                        + String(format: "%.2fs", attempt.durationSeconds)
                )
            }
        }
        if !rejectedVocabularyRetrievals.isEmpty {
            lines.append(
                "Rejected retrieval attempts: \(rejectedVocabularyRetrievals.count)"
            )
            for attempt in rejectedVocabularyRetrievals {
                let noNeighborCount = attempt.retrieval.queryOutcomes.count {
                    $0.status == .noRankedNeighbors
                }
                lines.append(
                    "Retrieval rejection \(attempt.retrievalAttemptOrdinal): "
                        + "\(attempt.recoveryLevel.rawValue) · "
                        + "\(attempt.retrieval.queryOutcomes.count) queries · "
                        + "\(noNeighborCount) without ranked neighbors · "
                        + String(format: "%.2fs", attempt.durationSeconds)
                )
            }
        }
        if lines.count == 1 { return nil }
        return lines.joined(separator: "\n")
    }

    /// Emit a JSON-fenced block carrying the run's structured metrics so
    /// downstream analysis tools (or future EasySplat builds) can ingest a
    /// diagnostic bundle without parsing markdown. Excludes notes and project
    /// identifiers regardless of `includeNotes`.
    private static func machineReadableSection(
        metadata: ProjectMetadata,
        geometry: GeometryArtifact?,
        training: TrainingArtifact?,
        pairMatchingRecovery: PairGraphRecoveryState?,
        rejectedVocabularyRetrievals: [RejectedVocabularyRetrievalExecutionEvidence],
        sanitizer: HomePathSanitizer
    ) -> String? {
        guard geometry != nil
            || metadata.geometryRecovery != nil
            || training != nil
            || (metadata.stageTimings?.isEmpty == false)
            || metadata.createToViewerReadySeconds != nil
            || metadata.lastFailureAt != nil
            || !rejectedVocabularyRetrievals.isEmpty else {
            return nil
        }
        struct DiagnosticMapping: Encodable {
            var modelCount: Int
            var largestModelRegisteredViewCount: Int
            var secondLargestModelRegisteredViewCount: Int
            var unionRegisteredViewCount: Int
            var attemptCount: Int
            var acceptedMappingAttemptOrdinal: Int
            var acceptedRefinementKind: String
            var acceptedRefinementInvocationCount: Int
            var plannedIncrementalCadence: IncrementalMappingCadenceArtifact?
            var incrementalCadence: IncrementalMappingCadenceArtifact?
            var cadenceFallbackTrigger: String?
            var fallbackReason: String?

            init(_ mapping: MappingArtifact) {
                modelCount = mapping.modelCount
                largestModelRegisteredViewCount = mapping.largestModelRegisteredViewCount
                secondLargestModelRegisteredViewCount = mapping.secondLargestModelRegisteredViewCount
                unionRegisteredViewCount = mapping.unionRegisteredViewCount
                attemptCount = mapping.attemptCount
                acceptedMappingAttemptOrdinal = mapping.acceptedMappingAttemptOrdinal
                acceptedRefinementKind = mapping.acceptedRefinementKind.rawValue
                acceptedRefinementInvocationCount = mapping.acceptedRefinementInvocationCount
                plannedIncrementalCadence = mapping.plannedIncrementalCadence
                incrementalCadence = mapping.incrementalCadence
                cadenceFallbackTrigger = mapping.cadenceFallbackTrigger?.rawValue
                fallbackReason = mapping.fallbackReason
            }
        }
        struct DiagnosticReconstruction: Encodable {
            var solverVersion: String
            var registeredViewCount: Int
            var totalViewCount: Int
            var pointCount: Int
            var observationCount: Int
            var medianPixelResidual: Double
            var p90PixelResidual: Double
            var residualProvenance: String

            init(_ geometry: GeometryArtifact) {
                solverVersion = geometry.solverVersion
                registeredViewCount = geometry.registeredViewCount
                totalViewCount = geometry.totalViewCount
                pointCount = geometry.pointCount
                observationCount = geometry.observationCount
                medianPixelResidual = geometry.medianPixelResidual
                p90PixelResidual = geometry.p90PixelResidual
                residualProvenance = geometry.residualProvenance
            }
        }
        struct DiagnosticGeometryRecovery: Encodable {
            var activeBackend: String
            var mappingAttemptCount: Int
            var mappingFallbackReasons: [String]
            var pendingPairRecoveryLevel: String?
            var colmapComputeMode: String?
            var plannedIncrementalCadence: IncrementalMappingCadenceArtifact?
            var activeIncrementalCadence: IncrementalMappingCadenceArtifact?
            var cadenceFallbackTrigger: String?
            var acceptedPairAttemptOrdinal: Int?
            var pairListDigest: String?
            var matchingDatabaseDigest: String?

            init(_ recovery: GeometryRecoveryState) {
                activeBackend = recovery.activeBackend.rawValue
                mappingAttemptCount = recovery.mappingAttemptCount
                mappingFallbackReasons = recovery.mappingFallbackReasons
                pendingPairRecoveryLevel = recovery.pendingPairRecoveryLevel?.rawValue
                colmapComputeMode = recovery.colmapComputeMode?.rawValue
                plannedIncrementalCadence = recovery.plannedIncrementalCadence
                activeIncrementalCadence = recovery.activeIncrementalCadence
                cadenceFallbackTrigger = recovery.cadenceFallbackTrigger?.rawValue
                acceptedPairAttemptOrdinal = recovery.acceptedPairAttemptOrdinal
                pairListDigest = recovery.pairListDigest
                matchingDatabaseDigest = recovery.matchingDatabaseDigest
            }
        }
        struct DiagnosticPairMatchingRecovery: Encodable {
            var attempts: [PairMatchingAttemptArtifact]
            var matchingDurationSeconds: Double

            init(_ recovery: PairGraphRecoveryState) {
                attempts = recovery.attempts.map(\.artifact)
                matchingDurationSeconds = recovery.matchingDurationSeconds
            }
        }
        struct DiagnosticRejectedVocabularyRetrieval: Encodable {
            var retrievalAttemptOrdinal: Int
            var pairAttemptOrdinal: Int
            var pairingPolicy: String
            var recoveryLevel: String
            var selectedViewCount: Int
            var queryCount: Int
            var noRankedNeighborQueryCount: Int
            var candidateCount: Int
            var returnedNeighborCount: Int
            var durationSeconds: Double
            var retrievalRequestDigest: String
            var retrievalOutputDigest: String

            init(_ evidence: RejectedVocabularyRetrievalExecutionEvidence) {
                retrievalAttemptOrdinal = evidence.retrievalAttemptOrdinal
                pairAttemptOrdinal = evidence.invocation.pairExecution?.attemptOrdinal ?? 0
                pairingPolicy = evidence.pairingPolicy.rawValue
                recoveryLevel = evidence.recoveryLevel.rawValue
                selectedViewCount = evidence.imageNames.count
                queryCount = evidence.retrieval.queryOutcomes.count
                noRankedNeighborQueryCount = evidence.retrieval.queryOutcomes.count {
                    $0.status == .noRankedNeighbors
                }
                candidateCount = evidence.retrieval.candidateCount
                returnedNeighborCount = evidence.retrieval.returnedNeighborCount
                durationSeconds = evidence.durationSeconds
                retrievalRequestDigest = evidence.invocation.pairExecution?
                    .retrievalRequestDigest ?? ""
                retrievalOutputDigest = evidence.invocation.pairExecution?
                    .retrievalOutputDigest ?? ""
            }
        }
        struct Payload: Encodable {
            var schemaVersion: Int
            var requestedRunOptions: RequestedRunOptions
            var resolvedGeometryExecutionBudget: GeometryWorkerBudget?
            var reconstruction: DiagnosticReconstruction?
            var cameraGrouping: ColmapCameraGroupingReceipt?
            var mapping: DiagnosticMapping?
            var geometryRecovery: DiagnosticGeometryRecovery?
            var pairMatchingRecovery: DiagnosticPairMatchingRecovery?
            var rejectedVocabularyRetrievalAttempts: [
                DiagnosticRejectedVocabularyRetrieval
            ]
            var trainingResource: TrainingResourceDiagnosticEvidence?
            var stageTimings: [StageTimingRecord]?
            var createToViewerReadySeconds: Double?
            var lastFailureAt: Date?
        }
        let payload = Payload(
            schemaVersion: ProjectDiagnosticBundle.machineReadableSchemaVersion,
            requestedRunOptions: metadata.requestedRunOptions,
            resolvedGeometryExecutionBudget: metadata.resolvedRunPlan?.geometryWorkerBudget,
            reconstruction: geometry.map(DiagnosticReconstruction.init),
            cameraGrouping: geometry?.cameraGroupingReceipt,
            mapping: geometry.map { DiagnosticMapping($0.mapping) },
            geometryRecovery: metadata.geometryRecovery.map(DiagnosticGeometryRecovery.init),
            pairMatchingRecovery: pairMatchingRecovery.map(
                DiagnosticPairMatchingRecovery.init
            ),
            rejectedVocabularyRetrievalAttempts: rejectedVocabularyRetrievals.map(
                DiagnosticRejectedVocabularyRetrieval.init
            ),
            trainingResource: trainingResourceEvidence(training: training),
            stageTimings: metadata.stageTimings,
            createToViewerReadySeconds: metadata.createToViewerReadySeconds,
            lastFailureAt: metadata.lastFailureAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "## Metrics (machine readable)\n```json\n\(sanitizer.sanitize(json))\n```"
    }

    private static func validatedPairMatchingRecovery(
        metadata: ProjectMetadata,
        paths: ProjectPaths
    ) -> PairGraphRecoveryState? {
        guard let geometryRecovery = metadata.geometryRecovery,
              geometryRecovery.activeBackend == .colmap,
              let pendingLevel = geometryRecovery.pendingPairRecoveryLevel,
              let state = try? PairGraphRecoveryStore.loadBound(
                  from: paths.pairGraphRecoveryURL,
                  expectedImageNames: geometryRecovery.orderedImageNames,
                  projectPaths: paths
              ),
              state.activeRecoveryLevel == pendingLevel,
              state.computeMode == geometryRecovery.colmapComputeMode,
              state.fallbackReasons == geometryRecovery.mappingFallbackReasons else {
            return nil
        }
        return state
    }

    private static func validatedRejectedVocabularyRetrievals(
        metadata: ProjectMetadata,
        paths: ProjectPaths
    ) -> [RejectedVocabularyRetrievalExecutionEvidence] {
        guard let plan = metadata.resolvedRunPlan,
              let artifact = try? GeometryWorkerExecutionArtifactStore.load(
                from: paths.workerExecutionURL,
                expectedBudget: plan.geometryWorkerBudget,
                projectPaths: paths
              ),
              artifact.rejectedVocabularyRetrievalInvocations.allSatisfy({
                  $0.pairingPolicy == plan.pairingPolicy
                      && $0.planBinding == PairGraphPlanBinding(plan)
              }) else {
            return []
        }
        if let recovery = metadata.geometryRecovery,
           !artifact.rejectedVocabularyRetrievalInvocations.allSatisfy({
               $0.imageNames == recovery.orderedImageNames
           }) {
            return []
        }
        return artifact.rejectedVocabularyRetrievalInvocations
    }

    private static func trainingResourceEvidence(
        training: TrainingArtifact?
    ) -> TrainingResourceDiagnosticEvidence? {
        guard let training,
              TrainingMemoryBudget.isValid(training.resourceAdmission),
              let memoryBudgetBytes = UInt64(exactly: training.memoryBudgetBytes),
              memoryBudgetBytes > 0,
              memoryBudgetBytes <= training.resourceAdmission.allowedTrainerBytes,
              let peakMemoryBytes = UInt64(exactly: training.peakMemoryBytes),
              let growthCount = UInt64(exactly: training.rasterExactBufferGrowthCount),
              let bytesAdded = UInt64(exactly: training.rasterExactBufferBytesAdded) else {
            return nil
        }
        return TrainingResourceDiagnosticEvidence(
            admission: training.resourceAdmission,
            memoryBudgetBytes: memoryBudgetBytes,
            peakMemoryBytes: peakMemoryBytes,
            rasterExactBufferGrowthCount: growthCount,
            rasterExactBufferBytesAdded: bytesAdded
        )
    }

    private static func logTailSection(
        label: String,
        url: URL,
        sanitizer: HomePathSanitizer,
        tailLineLimit: Int,
        tailByteLimit: Int
    ) -> String? {
        guard let tail = boundedTail(of: url, byteLimit: tailByteLimit), !tail.isEmpty else { return nil }
        let limitedByLines = TextTails.tailLines(tail, limit: tailLineLimit, byteLimit: tailByteLimit)
        let sanitized = sanitizer.sanitize(limitedByLines)
        return "## \(label) (tail)\n```\n\(sanitized)\n```"
    }

    /// Read at most `byteLimit` bytes from the end of `url` without slurping
    /// the entire file into memory. Decodes the result as UTF-8, dropping a
    /// partial leading byte if seeking landed mid-codepoint.
    private static func boundedTail(of url: URL, byteLimit: Int) -> String? {
        guard byteLimit > 0 else { return nil }
        guard let tail = try? BoundedFileReader.readRegularFileTail(
            at: url,
            maximumBytes: byteLimit
        ), !tail.data.isEmpty else { return nil }
        // If we started mid-UTF8-codepoint, drop bytes until we hit a valid leading byte.
        var trimmed = tail.data
        if !tail.startsAtFileBeginning {
            while let first = trimmed.first, first & 0b1100_0000 == 0b1000_0000 {
                trimmed.removeFirst()
            }
        }
        return String(data: trimmed, encoding: .utf8)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Removes local identity from paths and URLs before diagnostics leave the app.
struct HomePathSanitizer {
    let homePath: String
    let sensitiveValues: [String]

    init(sensitiveValues: [String] = []) {
        self.homePath = NSHomeDirectory()
        self.sensitiveValues = sensitiveValues
    }

    init(homePath: String, sensitiveValues: [String] = []) {
        self.homePath = homePath
        self.sensitiveValues = sensitiveValues
    }

    func sanitize(_ text: String) -> String {
        var sanitized = text
        for value in sensitiveValues
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: value)
            sanitized = replacingMatches(
                in: sanitized,
                pattern: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                template: "<redacted>"
            )
        }
        if !homePath.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: homePath, with: "~")
        }
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"/Volumes/[^/\r\n]+(?=/)"#,
            template: "/Volumes/<redacted>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"/Volumes/[^/\r\n\"']+(?=[\"']|$)"#,
            template: "/Volumes/<redacted>"
        )
        return replacingMatches(
            in: sanitized,
            pattern: #"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@"#,
            template: "$1"
        )
    }

    private func replacingMatches(in text: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
