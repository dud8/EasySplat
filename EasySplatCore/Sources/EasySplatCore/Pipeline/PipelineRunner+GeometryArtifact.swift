import Foundation

extension PipelineRunner {
    func validatedGeometryMeasurement(
        modelDirectory: URL,
        selectedFrames: [URL],
        requireStrongObservationCoverage: Bool
    ) throws -> (
        residuals: ColmapResidualAnalyzer.Result,
        snapshot: GeometryModelSnapshot.Verified
    ) {
        let snapshot = try GeometryModelSnapshot.capture(in: modelDirectory)
        let residuals: ColmapResidualAnalyzer.Result
        do {
            residuals = try ColmapResidualAnalyzer.analyze(modelDirectory: modelDirectory)
            try GeometryModelSnapshot.validate(snapshot, at: modelDirectory)
        } catch {
            throw PipelineError.geometryResidualsUnavailable(error.localizedDescription)
        }
        let requiredRegisteredViews = Int(ceil(
            Double(selectedFrames.count) * ReconstructionScorer.minimumRegisteredViewFraction
        ))
        let selectedNames = Set(selectedFrames.map(\.lastPathComponent))
        guard Set(residuals.registeredImageNames).isSubset(of: selectedNames) else {
            throw PipelineError.geometryRegisteredImagesMismatch
        }
        guard residuals.registeredViewCount >= requiredRegisteredViews else {
            throw PipelineError.geometryCoverageTooLow(
                registered: residuals.registeredViewCount,
                total: selectedFrames.count
            )
        }
        guard residuals.measuredImageNames.count >= requiredRegisteredViews else {
            throw PipelineError.geometryResidualCoverageTooLow(
                measured: residuals.measuredImageNames.count,
                total: selectedFrames.count
            )
        }
        if requireStrongObservationCoverage {
            let stronglyMeasuredViews = residuals.observationCountByImage.values.filter {
                $0 >= GeometryArtifactStore.minimumLearnedObservationsPerView
            }.count
            guard stronglyMeasuredViews >= requiredRegisteredViews else {
                throw PipelineError.geometryResidualCoverageTooLow(
                    measured: stronglyMeasuredViews,
                    total: selectedFrames.count
                )
            }
        }
        guard residuals.medianPixelResidual <= GeometryArtifactStore.maximumMedianPixelResidual,
              residuals.p90PixelResidual <= GeometryArtifactStore.maximumP90PixelResidual else {
            throw PipelineError.geometryResidualsTooHigh(
                median: residuals.medianPixelResidual,
                p90: residuals.p90PixelResidual
            )
        }
        return (residuals, snapshot)
    }

    func persistMeasuredGeometryArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        resolvedPlan: ResolvedRunPlan,
        mapper: String,
        acceptedDa3ModelSubdirectory: String?,
        selectedFrames: [URL],
        selectedFrameManifest: [SelectedFrameMapping],
        peakMemoryBytes: Int64,
        pairGraph: PairGraphArtifact,
        mapping: MappingArtifact,
        acceptedReconstructionSummary: ReconstructionSummary?,
        currentMappingDurationSeconds: () -> TimeInterval?
    ) throws {
        let modelDirectory = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        // The artifact contract uses COLMAP's text form so residuals remain inspectable
        // and model files remain hashable across trainer versions.
        try requireTextSparseModelFiles(at: modelDirectory)
        let measurement = try validatedGeometryMeasurement(
            modelDirectory: modelDirectory,
            selectedFrames: selectedFrames,
            requireStrongObservationCoverage: acceptedDa3ModelSubdirectory != nil
        )
        let sourceSnapshot = measurement.snapshot
        let sourceModelHashes = sourceSnapshot.modelHashes
        let residuals = measurement.residuals

        let orderedFrames = selectedFrames.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let mappingByName = Dictionary(
            selectedFrameManifest.map { ($0.outputFileName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedTimestamps = orderedFrames.map { mappingByName[$0.lastPathComponent]?.timestampSeconds }
        guard peakMemoryBytes > 0 else {
            throw PipelineError.geometryResidualsUnavailable("Peak resident memory could not be measured")
        }
        let fallbackReason = resolvedPlan.routeIdentifier == SfmBackend.da3.rawValue
            && !mapper.lowercased().contains("da3")
            ? "learned geometry did not pass; used classical compatibility solve"
            : nil
        let provenance = try geometryProvenance(
            acceptedDa3ModelSubdirectory: acceptedDa3ModelSubdirectory
        )
        let solverRevision = provenance.solver.revision.prefix(7)
        let solverVersion = "\(mapper); COLMAP \(provenance.solver.version) (git \(solverRevision))"
        let runtimeVersion: String
        if let runtime = provenance.runtime {
            runtimeVersion = "toolchain \(provenance.toolchainVersion); \(runtime.identifier) \(runtime.version) (git \(runtime.revision.prefix(7)))"
        } else {
            runtimeVersion = "toolchain \(provenance.toolchainVersion)"
        }
        let modelVersion = provenance.model.map { "\($0.identifier)@\($0.revision)" } ?? "none"

        let orientationEstimationClock = ContinuousClock()
        let orientationEstimationStart = orientationEstimationClock.now
        let isOrderedInput: Bool
        switch resolvedPlan.pairingPolicy {
        case .unorderedRetrieval, .segmentedMixed:
            isOrderedInput = false
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
            isOrderedInput = true
        }
        let allowCameraUpFallback = resolvedPlan.pairingPolicy == .orderedContinuous
            || resolvedPlan.pairingPolicy == .orderedWalkthrough
        let orientation = CanonicalOrientationEstimator.estimate(
            cameras: residuals.cameraSamples,
            orderedImageNames: orderedFrames.map(\.lastPathComponent),
            orderedInput: isOrderedInput,
            allowCameraUpFallback: allowCameraUpFallback,
            deterministicSeed: resolvedPlan.deterministicSeed
        )
        let orientationEstimationDuration = orientationEstimationClock.now - orientationEstimationStart

        let learnedPointInitializer: LearnedPointInitializerArtifact?
        if provenance.model != nil {
            let manifest = try Da3CoverageManifest.load(from: paths.da3CoverageManifestURL)
            let maximumPointCount = da3MaxPointsPreference(
                detailProfile: metadata.requestedRunOptions.detailProfile
            )
            guard manifest.maxPoints == maximumPointCount,
                  let pointCount = manifest.fusedSparsePointCount,
                  pointCount > 0,
                  pointCount <= maximumPointCount else {
                throw PipelineError.outputMissing
            }
            let rawURL = paths.colmapSeedModelURL.appendingPathComponent("learned_points3D.txt")
            let validation = try Da3LearnedPointInitializer.inspect(
                learnedPointsURL: rawURL,
                expectedPointCount: pointCount,
                maximumPointCount: maximumPointCount
            )
            learnedPointInitializer = LearnedPointInitializerArtifact(
                path: "SfM/colmap/seed/0/learned_points3D.txt",
                sha256: validation.sha256,
                pointCount: validation.pointCount
            )
        } else {
            learnedPointInitializer = nil
        }
        var timings = Dictionary(uniqueKeysWithValues: (metadata.stageTimings ?? []).map {
            ($0.stage.rawValue, $0.durationSeconds)
        })
        if let mappingDuration = currentMappingDurationSeconds() {
            timings[PipelineStage.sfmMapping.rawValue] = mappingDuration
        }
        timings["orientation_estimation_seconds"] = max(
            0,
            TimeInterval(orientationEstimationDuration.components.seconds)
                + TimeInterval(orientationEstimationDuration.components.attoseconds) / 1e18
        )
        let artifact = GeometryArtifact(
            schemaVersion: GeometryArtifact.currentSchemaVersion,
            solverVersion: solverVersion,
            runtimeVersion: runtimeVersion,
            modelVersion: modelVersion,
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: orderedFrames.map(\.lastPathComponent),
                projectPaths: paths
            ),
            orderedImageNames: orderedFrames.map(\.lastPathComponent),
            orderedImageTimestamps: orderedTimestamps,
            sourceModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: residuals.cameraModel,
            cameraGrouping: resolvedPlan.cameraGrouping,
            registeredViewCount: residuals.registeredViewCount,
            totalViewCount: orderedFrames.count,
            trackCount: residuals.observationCount,
            pointCount: residuals.pointCount,
            residualProvenance: residuals.provenance,
            medianPixelResidual: residuals.medianPixelResidual,
            p90PixelResidual: residuals.p90PixelResidual,
            timings: timings,
            peakMemoryBytes: peakMemoryBytes,
            modelHashes: sourceModelHashes,
            fallbackReason: fallbackReason,
            provenance: provenance,
            pairGraph: pairGraph,
            mapping: mapping,
            learnedPointInitializer: learnedPointInitializer,
            canonicalOrientation: orientation.artifact
        )
        let reconstruction = ReconstructionSummary(
            mapper: mapper,
            capturedAt: acceptedReconstructionSummary?.capturedAt
                ?? metadata.reconstruction?.capturedAt
                ?? Date(),
            registeredImages: residuals.registeredViewCount,
            totalImages: orderedFrames.count,
            meanReprojectionError: residuals.meanPixelResidual,
            pointCount: residuals.pointCount,
            observationCount: residuals.observationCount,
            meanTrackLength: Double(residuals.observationCount)
                / Double(residuals.pointCount)
        )
        try Task.checkCancellation()
        var persistedMetadata = metadata
        persistedMetadata.reconstruction = reconstruction
        persistedMetadata.geometryRecovery = nil
        try GeometryArtifactStore.persist(
            artifact,
            metadata: &persistedMetadata,
            paths: paths,
            measuredResiduals: residuals,
            verifiedSourceSnapshot: sourceSnapshot
        )
        metadata = persistedMetadata
    }

    private func geometryProvenance(
        acceptedDa3ModelSubdirectory: String?
    ) throws -> GeometryProvenance {
        let toolchain = config.toolchain
        let toolchainVersion = toolchain.root.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolchainVersion.isEmpty else {
            throw PipelineError.geometryProvenanceUnavailable("toolchain version was empty")
        }

        let colmapReceiptURL = toolchain.root.appendingPathComponent("provenance/colmap.json")
        let colmapReceipt: ColmapBuildReceipt = try decodeProvenanceReceipt(
            at: colmapReceiptURL,
            label: "COLMAP"
        )
        let colmapSHA256 = try GeometryArtifactStore.sha256(of: toolchain.colmap)
        guard colmapReceipt.toolchainName == "colmap",
              !colmapReceipt.sourceVersion.isEmpty,
              !colmapReceipt.sourceCommit.isEmpty,
              colmapReceipt.executableSHA256 == colmapSHA256 else {
            throw PipelineError.geometryProvenanceUnavailable(
                "COLMAP receipt did not match the installed executable"
            )
        }
        let solver = GeometryComponentProvenance(
            identifier: "colmap",
            version: colmapReceipt.sourceVersion,
            revision: colmapReceipt.sourceCommit,
            payloadSHA256: colmapSHA256
        )

        guard let acceptedDa3ModelSubdirectory else {
            return GeometryProvenance(
                toolchainVersion: toolchainVersion,
                solver: solver,
                runtime: nil,
                model: nil
            )
        }

        let modelBundle: URL
        switch acceptedDa3ModelSubdirectory {
        case "DA3-BASE":
            modelBundle = toolchain.da3.modelBundle
        case "DA3-SMALL":
            modelBundle = toolchain.da3.fallbackModelBundle
        default:
            throw PipelineError.geometryProvenanceUnavailable(
                "DA3 selected an unrecognized model \(acceptedDa3ModelSubdirectory)"
            )
        }

        let da3ReceiptURL = toolchain.da3.root.appendingPathComponent("build_info.json")
        let da3Receipt: Da3BuildReceipt = try decodeProvenanceReceipt(
            at: da3ReceiptURL,
            label: "DA3"
        )
        guard da3Receipt.toolchainName == "da3_mps",
              !da3Receipt.sourceRef.isEmpty,
              !da3Receipt.sourceCommit.isEmpty else {
            throw PipelineError.geometryProvenanceUnavailable("DA3 build receipt was incomplete")
        }

        let modelInfoURL = modelBundle.appendingPathComponent("easysplat_model_info.json")
        let modelInfo: Da3ModelReceipt = try decodeProvenanceReceipt(
            at: modelInfoURL,
            label: acceptedDa3ModelSubdirectory
        )
        let expectedCheckpointCommit = acceptedDa3ModelSubdirectory == "DA3-BASE"
            ? da3Receipt.baseCheckpointCommit
            : da3Receipt.smallCheckpointCommit
        guard !modelInfo.repositoryID.isEmpty,
              !modelInfo.requestedRevision.isEmpty,
              !modelInfo.resolvedSHA.isEmpty,
              expectedCheckpointCommit == modelInfo.resolvedSHA else {
            throw PipelineError.geometryProvenanceUnavailable(
                "\(acceptedDa3ModelSubdirectory) receipt did not match the DA3 build"
            )
        }

        let da3BuildReceiptSHA256 = try GeometryArtifactStore.sha256(of: da3ReceiptURL)
        let modelWeightsSHA256 = try GeometryArtifactStore.sha256(
            of: modelBundle.appendingPathComponent("model.safetensors")
        )
        return GeometryProvenance(
            toolchainVersion: toolchainVersion,
            solver: solver,
            runtime: GeometryComponentProvenance(
                identifier: "da3_mps",
                version: da3Receipt.sourceRef,
                revision: da3Receipt.sourceCommit,
                payloadSHA256: da3BuildReceiptSHA256
            ),
            model: GeometryComponentProvenance(
                identifier: acceptedDa3ModelSubdirectory,
                version: modelInfo.requestedRevision,
                revision: modelInfo.resolvedSHA,
                payloadSHA256: modelWeightsSHA256
            )
        )
    }

    private func decodeProvenanceReceipt<T: Decodable>(
        at url: URL,
        label: String
    ) throws -> T {
        do {
            let data = try BoundedFileReader.readRegularFile(at: url, maximumBytes: 1_048_576)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PipelineError.geometryProvenanceUnavailable(
                "\(label) receipt could not be read: \(error.localizedDescription)"
            )
        }
    }

}

private struct ColmapBuildReceipt: Decodable {
    let toolchainName: String
    let sourceVersion: String
    let sourceCommit: String
    let executableSHA256: String

    enum CodingKeys: String, CodingKey {
        case toolchainName = "toolchain_name"
        case sourceVersion = "source_version"
        case sourceCommit = "source_commit"
        case executableSHA256 = "executable_sha256"
    }
}

private struct Da3BuildReceipt: Decodable {
    let toolchainName: String
    let sourceRef: String
    let sourceCommit: String
    let baseCheckpointCommit: String
    let smallCheckpointCommit: String

    enum CodingKeys: String, CodingKey {
        case toolchainName = "toolchain_name"
        case sourceRef = "source_ref"
        case sourceCommit = "source_commit"
        case baseCheckpointCommit = "base_checkpoint_commit"
        case smallCheckpointCommit = "small_checkpoint_commit"
    }
}

private struct Da3ModelReceipt: Decodable {
    let repositoryID: String
    let requestedRevision: String
    let resolvedSHA: String

    enum CodingKeys: String, CodingKey {
        case repositoryID = "repo_id"
        case requestedRevision = "requested_revision"
        case resolvedSHA = "resolved_sha"
    }
}
