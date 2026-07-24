import Foundation

public struct SubjectIsolationRequest: Sendable {
    public let projectPaths: ProjectPaths
    public let nativeExecutableURL: URL
    public let toolchainBuildIdentity: String
    public let memoryBudgetBytes: Int64
    public let anchor: SubjectAnchor?

    public init(
        projectPaths: ProjectPaths,
        nativeExecutableURL: URL,
        toolchainBuildIdentity: String,
        memoryBudgetBytes: Int64,
        anchor: SubjectAnchor? = nil
    ) {
        self.projectPaths = projectPaths
        self.nativeExecutableURL = nativeExecutableURL
        self.toolchainBuildIdentity = toolchainBuildIdentity
        self.memoryBudgetBytes = memoryBudgetBytes
        self.anchor = anchor
    }
}

public protocol SubjectIsolationCoordinating: Sendable {
    func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome
}

public enum SubjectIsolationCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case invalidProject
    case heldOutRejected

    public var errorDescription: String? {
        switch self {
        case .invalidProject:
            "This project does not contain a valid completed splat and camera dataset."
        case .heldOutRejected:
            "Subject isolation did not agree with the held-out camera views."
        }
    }
}

typealias SubjectIsolationNativeOperation = @Sendable (
    _ request: SubjectIsolationNativeRunRequest,
    _ onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
    _ onLog: @escaping @Sendable (String, Bool) -> Void
) async throws -> SubjectIsolationNativeRunResult

typealias SubjectIsolationMaskAcquisition = @Sendable (
    _ views: [SubjectIsolationAnalysisView],
    _ stagingDirectory: URL,
    _ startingOrdinal: Int,
    _ shouldCancel: @escaping @Sendable () -> Bool
) async throws -> [SubjectIsolationAcquiredMask]

public struct SubjectIsolationCoordinator: SubjectIsolationCoordinating, Sendable {
    private let nativeOperation: SubjectIsolationNativeOperation
    private let maskAcquisition: SubjectIsolationMaskAcquisition

    public init() {
        let native = SubjectIsolationNativeRunner()
        let vision = SubjectIsolationVisionMaskAcquirer()
        nativeOperation = { request, onProgress, onLog in
            try await native.run(
                request,
                onProgress: onProgress,
                onLog: onLog
            )
        }
        maskAcquisition = { views, directory, startingOrdinal, shouldCancel in
            try await vision.acquire(
                views: views,
                stagingDirectory: directory,
                startingOrdinal: startingOrdinal,
                shouldCancel: shouldCancel
            )
        }
    }

    init(
        nativeOperation: @escaping SubjectIsolationNativeOperation,
        maskAcquisition: @escaping SubjectIsolationMaskAcquisition
    ) {
        self.nativeOperation = nativeOperation
        self.maskAcquisition = maskAcquisition
    }

    public func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome {
        guard request.memoryBudgetBytes > 0,
              !request.toolchainBuildIdentity.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let paths = request.projectPaths
        let canonical: CanonicalSplatPublication
        let poses: [SubjectIsolationCameraPose]
        do {
            canonical = try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: paths
            )
            let sparse = paths.trainingURL.appendingPathComponent(
                "msplat_dataset/sparse/0",
                isDirectory: true
            )
            poses = try SubjectIsolationColmapPoseReader.read(
                sparseDirectory: sparse
            )
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let sampled = SubjectIsolationViewSampler.sample(
            poses,
            maximumCount: IsolationArtifact.maximumMaskCount
        )
        let stages = SubjectIsolationViewSampler.progressiveStages(for: sampled)
        guard !stages.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }

        onProgress(SubjectIsolationProgress(
            phase: .preparing,
            completedUnitCount: 0,
            totalUnitCount: 1
        ))
        try paths.ensureIsolationDirectories()
        let runID = UUID()
        let staging = paths.isolationStagingURL(for: runID)
        let masksDirectory = staging.appendingPathComponent("masks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: masksDirectory,
            withIntermediateDirectories: true
        )
        var preserveStaging = false
        defer {
            if !preserveStaging {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        let datasetURL = paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        let imagesURL = datasetURL.appendingPathComponent("images", isDirectory: true)
        let analysisCacheURL = staging.appendingPathComponent("analysis.cache")
        let digests = SubjectIsolationNativeDigests(
            sourcePly: canonical.outputEvidence.sha256,
            input: canonical.trainingInputDigest,
            geometry: canonical.trainingGeometryDigest,
            selectedFrames: canonical.selectedFramesDigest,
            trainingManifest: canonical.trainingManifestSHA256
        )
        var acquired: [SubjectIsolationAcquiredMask] = []
        var attempt = 0

        for (stageIndex, stage) in stages.enumerated() {
            try Task.checkCancellation()
            let orderedStageViews = (stage.workViews + stage.heldOutViews)
                .sorted { $0.samplePosition < $1.samplePosition }
            let newlyNeeded = orderedStageViews.dropFirst(acquired.count)
            let analysisViews = newlyNeeded.map {
                SubjectIsolationAnalysisView(
                    imageIdentity: $0.imageIdentity,
                    imageURL: imagesURL.appendingPathComponent($0.imageIdentity),
                    nativeCameraIndex: $0.nativeCameraIndex
                )
            }
            if !analysisViews.isEmpty {
                let newMasks = try await maskAcquisition(
                    analysisViews,
                    masksDirectory,
                    acquired.count,
                    { Task.isCancelled }
                )
                guard newMasks.map(\.imageIdentity)
                        == analysisViews.map(\.imageIdentity) else {
                    throw SubjectIsolationCoordinatorError.invalidProject
                }
                acquired.append(contentsOf: newMasks)
            }
            onProgress(SubjectIsolationProgress(
                phase: .segmenting,
                completedUnitCount: acquired.count,
                totalUnitCount: sampled.count
            ))
            let manifestURL = staging.appendingPathComponent(
                "mask-manifest-\(orderedStageViews.count).json"
            )
            try writeNativeMaskManifest(
                to: manifestURL,
                orderedViews: orderedStageViews,
                masks: acquired,
                workIdentities: Set(stage.workViews.map(\.imageIdentity)),
                digests: digests
            )

            let result = try await runNativeAttempt(
                request: request,
                datasetURL: datasetURL,
                maskManifestURL: manifestURL,
                analysisCacheURL: analysisCacheURL,
                stagingURL: staging,
                digests: digests,
                attempt: &attempt,
                anchor: nil,
                onProgress: onProgress,
                onLog: onLog
            )
            if case .completed(let completion) = result {
                return try publish(
                    completion: completion,
                    nativeOutputURL: staging.appendingPathComponent(
                        "attempt-\(attempt - 1).ply"
                    ),
                    request: request,
                    canonical: canonical,
                    acquiredMasks: acquired,
                    stagingURL: staging,
                    runID: runID,
                    subjectAnchor: nil,
                    onProgress: onProgress
                )
            }

            let isFinal = stageIndex == stages.count - 1
            guard isFinal else { continue }
            var finalResult = result
            if case .ambiguity = result, let anchor = request.anchor {
                finalResult = try await runNativeAttempt(
                    request: request,
                    datasetURL: datasetURL,
                    maskManifestURL: manifestURL,
                    analysisCacheURL: analysisCacheURL,
                    stagingURL: staging,
                    digests: digests,
                    attempt: &attempt,
                    anchor: anchor,
                    onProgress: onProgress,
                    onLog: onLog
                )
                if case .completed(let completion) = finalResult {
                    return try publish(
                        completion: completion,
                        nativeOutputURL: staging.appendingPathComponent(
                            "attempt-\(attempt - 1).ply"
                        ),
                        request: request,
                        canonical: canonical,
                        acquiredMasks: acquired,
                        stagingURL: staging,
                        runID: runID,
                        subjectAnchor: anchor,
                        onProgress: onProgress
                    )
                }
            }
            switch finalResult {
            case .noSubject:
                return .noSubject
            case .heldOutRejected:
                throw SubjectIsolationCoordinatorError.heldOutRejected
            case .ambiguity(let components):
                let choice = try choiceRequest(
                    components: components,
                    acquiredMasks: acquired,
                    imagesDirectory: imagesURL
                )
                preserveStaging = true
                return .ambiguity(choice)
            case .completed:
                throw SubjectIsolationCoordinatorError.invalidProject
            }
        }
        throw SubjectIsolationCoordinatorError.invalidProject
    }

    private func runNativeAttempt(
        request: SubjectIsolationRequest,
        datasetURL: URL,
        maskManifestURL: URL,
        analysisCacheURL: URL,
        stagingURL: URL,
        digests: SubjectIsolationNativeDigests,
        attempt: inout Int,
        anchor: SubjectAnchor?,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let outputURL = stagingURL.appendingPathComponent("attempt-\(attempt).ply")
        attempt += 1
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        return try await nativeOperation(
            SubjectIsolationNativeRunRequest(
                executableURL: request.nativeExecutableURL,
                datasetURL: datasetURL,
                sourcePlyURL: request.projectPaths.outputSplatURL,
                maskManifestURL: maskManifestURL,
                analysisCacheURL: analysisCacheURL,
                outputURL: outputURL,
                digests: digests,
                memoryBudgetBytes: request.memoryBudgetBytes,
                anchor: anchor
            ),
            onProgress,
            onLog
        )
    }

    private func publish(
        completion: SubjectIsolationNativeCompletion,
        nativeOutputURL: URL,
        request: SubjectIsolationRequest,
        canonical: CanonicalSplatPublication,
        acquiredMasks: [SubjectIsolationAcquiredMask],
        stagingURL: URL,
        runID: UUID,
        subjectAnchor: SubjectAnchor?,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void
    ) throws -> SubjectIsolationOutcome {
        onProgress(SubjectIsolationProgress(
            phase: .publishing,
            completedUnitCount: 0,
            totalUnitCount: 1
        ))
        let stagedOutputURL = stagingURL.appendingPathComponent("isolated.ply")
        try FileManager.default.moveItem(
            at: nativeOutputURL,
            to: stagedOutputURL
        )
        let masks = acquiredMasks.enumerated().map { index, mask in
            IsolationArtifact.Mask(
                relativePath: "Isolation/masks/\(runID.uuidString)-\(String(format: "%04d", index)).png",
                imageIdentity: mask.imageIdentity,
                imageSHA256: mask.imageSHA256,
                maskSHA256: mask.maskSHA256,
                pixelWidth: mask.pixelWidth,
                pixelHeight: mask.pixelHeight,
                instanceLabels: mask.instanceLabels
            )
        }
        let artifact = IsolationArtifact(
            sourcePlySHA256: canonical.outputEvidence.sha256,
            trainingManifestSHA256: canonical.trainingManifestSHA256,
            dataset: .init(
                inputDigest: canonical.trainingInputDigest,
                geometryDigest: canonical.trainingGeometryDigest,
                selectedFramesDigest: canonical.selectedFramesDigest,
                selectedImageOrder: canonical.selectedImageOrder
            ),
            masks: masks,
            toolchainBuildIdentity: request.toolchainBuildIdentity,
            nativeExecutableSHA256: try GeometryArtifactStore.sha256(
                of: request.nativeExecutableURL
            ),
            visionRequestRevision: 1,
            selectedViewIdentities: completion.selectedViewIdentities,
            heldOutViewIdentities: completion.heldOutViewIdentities,
            policy: .init(
                version: 1,
                minimumMaskConfidence: 0,
                minimumHeldOutMedianIoU: 0.70,
                minimumHeldOutFirstQuartileIoU: 0.50,
                minimumRetainedGaussianFraction: 0.001,
                maximumRetainedGaussianFraction: 0.90
            ),
            subjectAnchor: subjectAnchor,
            metrics: .init(
                meanMaskConfidence: 0,
                heldOutMeanIoU: completion.heldOutMeanIoU,
                heldOutMedianIoU: completion.heldOutMedianIoU,
                heldOutFirstQuartileIoU: completion.heldOutFirstQuartileIoU,
                retainedGaussianFraction: completion.retainedGaussianFraction
            ),
            output: .init(
                identity: runID,
                relativePath: "Output/isolated.ply",
                sha256: completion.outputSHA256,
                byteCount: completion.outputByteCount,
                gaussianCount: completion.gaussianCount,
                sceneBounds: completion.sceneBounds
            )
        )
        let output = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: stagedOutputURL,
            stagedMasksURL: stagingURL.appendingPathComponent(
                "masks",
                isDirectory: true
            ),
            paths: request.projectPaths
        )
        onProgress(SubjectIsolationProgress(
            phase: .publishing,
            completedUnitCount: 1,
            totalUnitCount: 1
        ))
        return .completed(output)
    }

    private func choiceRequest(
        components: [SubjectIsolationNativeComponent],
        acquiredMasks: [SubjectIsolationAcquiredMask],
        imagesDirectory: URL
    ) throws -> SubjectChoiceRequest {
        let orderedComponents = components.sorted {
            $0.score == $1.score
                ? $0.identity < $1.identity
                : $0.score > $1.score
        }
        guard let clearest = orderedComponents.first,
              let keyframe = bestKeyframe(in: clearest),
              let mask = acquiredMasks.first(where: {
                  $0.imageIdentity == keyframe.imageIdentity
              }) else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let candidates: [SubjectChoiceRequest.Candidate] = orderedComponents.compactMap { component in
            guard let contribution = component.keyframes
                .filter({ $0.imageIdentity == keyframe.imageIdentity })
                .max(by: keyframeLessThan) else {
                return nil
            }
            return SubjectChoiceRequest.Candidate(
                componentIdentity: component.identity,
                instanceLabel: contribution.instanceLabel,
                confidence: min(1, max(0, component.score)),
                previewMaskURL: mask.fileURL
            )
        }
        guard !candidates.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        return SubjectChoiceRequest(
            keyframeImageURL: imagesDirectory.appendingPathComponent(
                keyframe.imageIdentity
            ),
            combinedInstanceLabelMaskURL: mask.fileURL,
            pixelWidth: mask.pixelWidth,
            pixelHeight: mask.pixelHeight,
            candidates: candidates
        )
    }

    private func bestKeyframe(
        in component: SubjectIsolationNativeComponent
    ) -> SubjectIsolationNativeKeyframeContribution? {
        component.keyframes.max(by: keyframeLessThan)
    }

    private func keyframeLessThan(
        _ lhs: SubjectIsolationNativeKeyframeContribution,
        _ rhs: SubjectIsolationNativeKeyframeContribution
    ) -> Bool {
        if lhs.fraction != rhs.fraction { return lhs.fraction < rhs.fraction }
        if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
        return lhs.imageIdentity > rhs.imageIdentity
    }
}

private struct SubjectIsolationNativeMaskManifest: Encodable {
    let schemaVersion = 1
    let isolationModeVersion = 1
    let sourcePlyDigest: String
    let inputDigest: String
    let geometryDigest: String
    let selectedFramesDigest: String
    let trainingManifestDigest: String
    let selectedImageOrder: [String]
    let views: [View]

    struct View: Encodable {
        let imageIdentity: String
        let cameraIndex: Int
        let role: String
        let relativeMaskPath: String
        let maskSHA256: String
        let width: Int
        let height: Int

        enum CodingKeys: String, CodingKey {
            case imageIdentity = "image_identity"
            case cameraIndex = "camera_index"
            case role
            case relativeMaskPath = "relative_mask_path"
            case maskSHA256 = "mask_sha256"
            case width
            case height
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case isolationModeVersion = "isolation_mode_version"
        case sourcePlyDigest = "source_ply_digest"
        case inputDigest = "input_digest"
        case geometryDigest = "geometry_digest"
        case selectedFramesDigest = "selected_frames_digest"
        case trainingManifestDigest = "training_manifest_digest"
        case selectedImageOrder = "selected_image_order"
        case views
    }
}

private func writeNativeMaskManifest(
    to url: URL,
    orderedViews: [SubjectIsolationSampledView],
    masks: [SubjectIsolationAcquiredMask],
    workIdentities: Set<String>,
    digests: SubjectIsolationNativeDigests
) throws {
    guard orderedViews.count == masks.count,
          zip(orderedViews, masks).allSatisfy({
              $0.imageIdentity == $1.imageIdentity
          }) else {
        throw SubjectIsolationCoordinatorError.invalidProject
    }
    let manifest = SubjectIsolationNativeMaskManifest(
        sourcePlyDigest: digests.sourcePly,
        inputDigest: digests.input,
        geometryDigest: digests.geometry,
        selectedFramesDigest: digests.selectedFrames,
        trainingManifestDigest: digests.trainingManifest,
        selectedImageOrder: orderedViews.map(\.imageIdentity),
        views: zip(orderedViews, masks).map { view, mask in
            SubjectIsolationNativeMaskManifest.View(
                imageIdentity: view.imageIdentity,
                cameraIndex: view.nativeCameraIndex,
                role: workIdentities.contains(view.imageIdentity)
                    ? "work"
                    : "held_out",
                relativeMaskPath: "masks/\(mask.fileURL.lastPathComponent)",
                maskSHA256: mask.maskSHA256,
                width: mask.pixelWidth,
                height: mask.pixelHeight
            )
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: url, options: [.atomic])
}
