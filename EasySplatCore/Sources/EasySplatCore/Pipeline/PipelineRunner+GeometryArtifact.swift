import Darwin
import Foundation

extension PipelineRunner {
    func persistMeasuredGeometryArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        resolvedPlan: ResolvedRunPlan,
        mapper: String,
        selectedFrames: [URL],
        selectedFrameManifest: [SelectedFrameMapping]
    ) throws {
        let modelDirectory = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        // Legacy projects may have only COLMAP's binary model. Measurement and the
        // public artifact contract use the canonical text form so the residual source
        // remains inspectable and hashable across trainer versions.
        _ = try ensureTextSparseModelFiles(at: modelDirectory)
        let residuals: ColmapResidualAnalyzer.Result
        do {
            residuals = try ColmapResidualAnalyzer.analyze(modelDirectory: modelDirectory)
        } catch {
            throw PipelineError.geometryResidualsUnavailable(error.localizedDescription)
        }
        let requiredRegisteredViews = Int(ceil(
            Double(selectedFrames.count) * GeometryArtifactStore.minimumRegisteredViewFraction
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
        guard residuals.medianPixelResidual <= GeometryArtifactStore.maximumMedianPixelResidual,
              residuals.p90PixelResidual <= GeometryArtifactStore.maximumP90PixelResidual else {
            throw PipelineError.geometryResidualsTooHigh(
                median: residuals.medianPixelResidual,
                p90: residuals.p90PixelResidual
            )
        }

        let orderedFrames = selectedFrames.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let mappingByName = Dictionary(
            selectedFrameManifest.map { ($0.outputFileName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedTimestamps = orderedFrames.map { mappingByName[$0.lastPathComponent]?.timestampSeconds }
        guard let peakMemoryBytes = Self.peakResidentMemoryBytes(), peakMemoryBytes > 0 else {
            throw PipelineError.geometryResidualsUnavailable("Peak resident memory could not be measured")
        }
        let modelFiles = ["cameras.txt", "images.txt", "points3D.txt"].map {
            modelDirectory.appendingPathComponent($0)
        }
        let modelHashes = try Dictionary(uniqueKeysWithValues: modelFiles.map { file in
            (file.lastPathComponent, try GeometryArtifactStore.sha256(of: file))
        })
        let fallbackReason = resolvedPlan.routeIdentifier == SfmBackend.da3.rawValue
            && !mapper.lowercased().contains("da3")
            ? "learned geometry did not pass; used classical compatibility solve"
            : nil
        let timings = Dictionary(uniqueKeysWithValues: (metadata.stageTimings ?? []).map {
            ($0.stage.rawValue, $0.durationSeconds)
        })
        let artifact = GeometryArtifact(
            schemaVersion: 1,
            solverVersion: mapper,
            runtimeVersion: "easysplat-core-v2",
            modelVersion: resolvedPlan.modelIdentifier,
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: orderedFrames.map(\.lastPathComponent),
                projectPaths: paths
            ),
            orderedImageNames: orderedFrames.map(\.lastPathComponent),
            orderedImageTimestamps: orderedTimestamps,
            canonicalModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: try Self.firstCameraModel(in: modelFiles[0]),
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
            modelHashes: modelHashes,
            fallbackReason: fallbackReason
        )
        try GeometryArtifactStore.persist(
            artifact,
            metadata: &metadata,
            paths: paths,
            measuredResiduals: residuals
        )
    }

    private static func firstCameraModel(in camerasFile: URL) throws -> String {
        let text = try String(contentsOf: camerasFile, encoding: .utf8)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2 { return String(fields[1]) }
        }
        throw PipelineError.geometryResidualsUnavailable("cameras.txt contains no camera record")
    }

    static func peakResidentMemoryBytes() -> Int64? {
        var ownUsage = rusage()
        guard getrusage(RUSAGE_SELF, &ownUsage) == 0 else { return nil }
        var childUsage = rusage()
        let childPeak = getrusage(RUSAGE_CHILDREN, &childUsage) == 0
            ? Int64(childUsage.ru_maxrss)
            : 0
        return max(Int64(ownUsage.ru_maxrss), childPeak)
    }

}
