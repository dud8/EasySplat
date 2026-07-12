import Foundation
import SQLite3

extension PipelineRunner {
    /// Rebuild a transient `ReconstructionScore` from the persisted summary so
    /// resume-from-SfM runs do not lose the per-run quality data the trainer
    /// selection guard relies on. The persisted summary is the same data the
    /// runner originally stored when SfM accepted a model.
    static func reconstructionScore(fromPersistedSummary summary: ReconstructionSummary) -> ReconstructionScore {
        return ReconstructionScore(
            registeredImages: summary.registeredImages,
            totalImages: summary.totalImages,
            meanReprojectionError: summary.meanReprojectionError,
            pointCount: summary.pointCount,
            observationCount: summary.observationCount,
            meanTrackLength: summary.meanTrackLength
        )
    }

    enum PipelineError: Error {
        case invalidInput
        case insufficientInputImages(Int)
        case lowQualityReconstruction(ReconstructionScore, mapper: String?)
        case imageTranscodeFailed(String)
        case outputMissing
    }

    enum StageOutputStatus: Equatable, Sendable {
        case valid
        case missing
        case corrupt(reason: String)
    }

    struct ColmapSparseTextStats: Sendable {
        var registeredImageCount: Int?
        var pointCount: Int?
        var observationCount: Int?
        var meanTrackLength: Double?
    }

    func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeIfExists(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    func cleanForRetry(failedStage: PipelineStage, paths: ProjectPaths) throws {
        switch failedStage {
        case .importInput:
            return
        case .extractFrames:
            self.removeIfExists(paths.framesRawURL)
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.framesSelectedManifestURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
        case .selectFrames:
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.framesSelectedManifestURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
        case .sfmFeatures, .sfmMatching:
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
        case .sfmMapping:
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
        case .trainBrush:
            return
        case .exportSplat:
            return
        case .done:
            return
        }
    }

    func failureMessages(for error: Error, stage: PipelineStage) -> (userMessage: String, debugMessage: String) {
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .invalidInput:
                return ("No usable photos or video frames were found.", String(reflecting: pipelineError))
            case let .insufficientInputImages(actual):
                return ("At least two usable photos or video frames are required.", "Insufficient input images after selection: \(actual).")
            case let .lowQualityReconstruction(score, mapper):
                let summary = mapper.map { ReconstructionScorer.summary(score, mapper: $0) }
                    ?? ReconstructionScorer.summary(score)
                return ("I couldn't get a stable camera solve. Try a slower capture and more light.", "Low-quality reconstruction. \(summary).")
            case let .imageTranscodeFailed(message):
                return ("Failed to convert photos for processing. Try exporting as JPEG/PNG.", message)
            case .outputMissing:
                return ("Processing failed. Expected outputs were missing.", String(reflecting: pipelineError))
            }
        }
        if let subprocessFailure = error as? SubprocessFailure {
            return ("Processing failed. Check details for more info.", subprocessFailure.debugDescription)
        }
        if let colmapError = error as? ColmapRunnerError {
            let debug = debugDescription(for: colmapError)
            switch colmapError {
            case let .failed(_, exitCode, reason, _, _) where reason == .uncaughtSignal && exitCode == 10:
                return ("COLMAP crashed while matching images. Try fewer frames or a lower quality preset.", debug)
            default:
                return ("Processing failed. Check details for more info.", debug)
            }
        }
        return ("Processing failed. Check details for more info.", String(reflecting: error))
    }

    func glomapErrorIndicatesMissingOpenSSL(_ error: Error) -> Bool {
        guard let failure = error as? SubprocessFailure else { return false }
        let text = "\(failure.stdoutTail)\n\(failure.stderrTail)".lowercased()
        if text.contains("library not loaded: @rpath/libcrypto.3.dylib") { return true }
        if text.contains("no lc_rpath") { return true }
        return false
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

    /// Warn once an accepted COLMAP/GLOMAP solve's mean track length is below this. A healthy
    /// solve threads each point through several views (~3-6); a shorter average means a thin,
    /// fragmented reconstruction.
    static let weakTrackLengthThreshold = 3.0

    /// Advisory only. The COLMAP/GLOMAP acceptance gate checks registration ratio plus that
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

    func validateStageOutput(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) throws -> StageOutputStatus {
        let fm = FileManager.default
        switch stage {
        case .importInput:
            if metadata.input.videoFiles.isEmpty && metadata.input.photosFolder == nil {
                return .missing
            }
            let importedVideos = importedVideoURLs(for: metadata.input.videoFiles, paths: paths)
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
                let dest = paths.originalsURL.appendingPathComponent(name, isDirectory: true)
                guard fm.fileExists(atPath: dest.path) else { return .missing }
                let photos = try loadPhotos(in: dest)
                if photos.isEmpty {
                    return .corrupt(reason: "photos folder \(name) is empty")
                }
            }
            return .valid
        case .extractFrames:
            guard metadata.input.hasVideos else { return .valid }
            for index in metadata.input.videoFiles.indices {
                let rawDir = rawFramesDirectory(index: index, paths: paths)
                guard fm.fileExists(atPath: rawDir.path) else { return .missing }
                let frames = try loadImages(in: rawDir)
                if frames.isEmpty {
                    return .corrupt(reason: "raw frame folder \(rawDir.lastPathComponent) is empty")
                }
                let readableCount = frames.reduce(into: 0) { partial, frameURL in
                    let size = (try? fm.attributesOfItem(atPath: frameURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if size > 0 {
                        partial += 1
                    }
                }
                if readableCount <= 0 {
                    return .corrupt(reason: "raw frame folder \(rawDir.lastPathComponent) has no readable frames")
                }
            }
            return .valid
        case .selectFrames:
            guard fm.fileExists(atPath: paths.framesSelectedURL.path) else { return .missing }
            guard fm.fileExists(atPath: paths.framesSelectedManifestURL.path) else {
                return .corrupt(reason: "selected frame manifest is missing")
            }
            let manifest: [SelectedFrameMapping]
            do {
                manifest = try loadSelectedFrameManifest(from: paths.framesSelectedManifestURL)
            } catch {
                return .corrupt(reason: "selected frame manifest is invalid JSON")
            }
            if manifest.isEmpty {
                return .corrupt(reason: "selected frame manifest is empty")
            }
            let files = try loadImages(in: paths.framesSelectedURL)
            if files.count != manifest.count {
                return .corrupt(reason: "selected frame file count (\(files.count)) does not match manifest (\(manifest.count))")
            }
            let names = Set(files.map(\.lastPathComponent))
            for entry in manifest where !names.contains(entry.outputFileName) {
                return .corrupt(reason: "manifest references missing file \(entry.outputFileName)")
            }
            return .valid
        case .sfmFeatures:
            let seedZero = paths.colmapSeedModelURL
            if sparseModelFilesExist(at: seedZero) {
                return .valid
            }
            return validateColmapDatabaseOutput(paths: paths, requireMatches: false)
        case .sfmMatching:
            return validateColmapDatabaseOutput(paths: paths, requireMatches: true)
        case .sfmMapping:
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            guard sparseModelFilesExist(at: sparseZero) else { return .missing }
            let textStats = colmapSparseTextStats(at: sparseZero)
            // VGGT-direct writes points3D.txt with empty track entries when BA is disabled
            // (Tools/VggtSfm/easysplat_vggt_sfm/run.py); the matching quality gate in
            // vggtDirectQualityFailureReason accepts this shape, so recovery must too.
            let allowsTracklessSparse: Bool = {
                if case let .sfmMapping(checkpoint)? = metadata.checkpoint?.details {
                    return checkpoint.mapper == "vggt"
                }
                if metadata.checkpoint?.stage == .sfmMapping {
                    return false
                }
                if let completed = metadata.completedSfmMapping {
                    return completed.mapper == "vggt"
                }
                return false
            }()
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
                if !allowsTracklessSparse {
                    guard (textStats.observationCount ?? 0) > 0 else {
                        return .corrupt(reason: "points3D.txt has no observations")
                    }
                }
            }
            let imagesTxt = sparseZero.appendingPathComponent("images.txt")
            if fm.fileExists(atPath: imagesTxt.path) {
                let text = (try? String(contentsOf: imagesTxt, encoding: .utf8)) ?? ""
                let imageRows = text.split(separator: "\n").filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                }
                if imageRows.isEmpty {
                    return .corrupt(reason: "images.txt has no registered images")
                }
            } else {
                let imagesBin = sparseZero.appendingPathComponent("images.bin")
                let size = (try? fm.attributesOfItem(atPath: imagesBin.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 8 {
                    return .corrupt(reason: "images.bin appears truncated")
                }
            }
            let da3Issues = da3DirectSparseValidationIssues(paths: paths, textStats: textStats)
            if !da3Issues.isEmpty {
                return .corrupt(reason: "DA3 sparse manifest is invalid: \(da3Issues.joined(separator: "; "))")
            }
            return .valid
        case .trainBrush:
            if let artifact = metadata.trainingArtifact {
                switch artifact.completionStatus {
                case .checkpointed:
                    return .missing
                case .completed:
                    guard artifact.detailProfile == metadata.effectiveDetailProfile else {
                        return .corrupt(
                            reason: "completed training profile does not match the requested detail"
                        )
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
                        let identity = try currentMsplatDatasetIdentity(paths: paths)
                        guard artifact.inputDigest == identity.inputDigest,
                              artifact.geometryDigest == identity.geometryDigest else {
                            return .corrupt(
                                reason: "completed training manifest does not match current input or geometry"
                            )
                        }
                    } catch {
                        return .corrupt(
                            reason: "completed training identity could not be verified: \(error.localizedDescription)"
                        )
                    }
                    return .valid
                }
            }
            guard let latest = latestBrushExport(
                in: paths.trainingURL,
                minModificationDate: trainingExportMinimumDate(metadata: metadata)
            )?.file else { return .missing }
            return validatePlyFile(at: latest)
        case .exportSplat, .done:
            let output: URL
            if let persisted = metadata.outputs?.splatPlyPath {
                do {
                    output = try paths.resolveProjectRelativePath(persisted)
                } catch {
                    return .corrupt(reason: error.localizedDescription)
                }
            } else {
                output = paths.outputURL.appendingPathComponent("splat.ply")
            }
            return validatePlyFile(at: output)
        }
    }

    func colmapSparseTextStats(at sparseZero: URL) -> ColmapSparseTextStats {
        let imagesTxt = sparseZero.appendingPathComponent("images.txt")
        var registeredImageCount: Int?
        if let text = try? String(contentsOf: imagesTxt, encoding: .utf8) {
            registeredImageCount = text
                .components(separatedBy: .newlines)
                .filter { isColmapImagePoseRow($0) }
                .count
        }

        let pointsTxt = sparseZero.appendingPathComponent("points3D.txt")
        var pointCount: Int?
        var observationCount: Int?
        if let text = try? String(contentsOf: pointsTxt, encoding: .utf8) {
            var points = 0
            var observations = 0
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: " ")
                guard parts.count >= 8 else { continue }
                points += 1
                observations += max(0, (parts.count - 8) / 2)
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

    func trainingExportMinimumDate(metadata: ProjectMetadata) -> Date? {
        if let lastRunStartedAt = metadata.lastRunStartedAt {
            return lastRunStartedAt
        }
        if metadata.checkpoint?.stage == .trainBrush {
            return metadata.checkpoint?.updatedAt
        }
        return nil
    }

    private func isColmapImagePoseRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        let parts = trimmed.split(maxSplits: 9, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 10 else { return false }
        guard Int(parts[0]) != nil else { return false }
        return parts[1..<9].allSatisfy { Double(String($0)) != nil }
            && Int(parts[8]) != nil
            && String(parts[9]).rangeOfCharacter(from: .letters) != nil
    }

    func da3DirectSparseValidationIssues(
        paths: ProjectPaths,
        textStats: ColmapSparseTextStats
    ) -> [String] {
        let fm = FileManager.default
        let databaseExists = fm.fileExists(atPath: paths.colmapDatabaseURL.path)
        let databaseSize = (try? fm.attributesOfItem(atPath: paths.colmapDatabaseURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard fm.fileExists(atPath: paths.da3CoverageManifestURL.path) else {
            if databaseExists, databaseSize <= 0 {
                return ["DA3 coverage manifest was missing for zero-byte direct sparse database marker"]
            }
            return []
        }
        let da3ManifestDate = (try? fm.attributesOfItem(atPath: paths.da3CoverageManifestURL.path)[.modificationDate] as? Date) ?? .distantPast
        if let mapAnythingManifestDate = try? fm.attributesOfItem(atPath: paths.mapanythingCoverageManifestURL.path)[.modificationDate] as? Date,
           mapAnythingManifestDate > da3ManifestDate {
            return []
        }
        guard databaseSize <= 0 else {
            return []
        }

        let selectedImageNames: [String]
        do {
            selectedImageNames = try loadImages(in: paths.framesSelectedURL).map(\.lastPathComponent)
        } catch {
            return ["selected images could not be loaded for DA3 manifest validation (\(error.localizedDescription))"]
        }
        let manifest: Da3CoverageManifest
        do {
            manifest = try Da3CoverageManifest.load(from: paths.da3CoverageManifestURL)
        } catch {
            return ["manifest could not be decoded (\(error.localizedDescription))"]
        }

        var issues = manifest.validationIssues(
            expectedMode: .direct,
            selectedImageNames: selectedImageNames
        )
        if textStats.registeredImageCount == nil {
            issues.append("images.txt was missing from DA3 direct sparse output")
        }
        if textStats.pointCount == nil {
            issues.append("points3D.txt was missing from DA3 direct sparse output")
        }
        if let registeredImageCount = textStats.registeredImageCount,
           let manifestRegistered = manifest.registeredImageCount,
           registeredImageCount != manifestRegistered {
            issues.append("registered_image_count \(manifestRegistered) did not match images.txt \(registeredImageCount)")
        }
        if let pointCount = textStats.pointCount,
           let manifestPoints = manifest.fusedSparsePointCount,
           pointCount != manifestPoints {
            issues.append("fused_sparse_point_count \(manifestPoints) did not match points3D.txt \(pointCount)")
        }
        if let observationCount = textStats.observationCount,
           let manifestObservations = manifest.finalObservationCount,
           observationCount != manifestObservations {
            issues.append("final_observation_count \(manifestObservations) did not match points3D.txt observations \(observationCount)")
        }
        if let meanTrackLength = textStats.meanTrackLength,
           let manifestMeanTrackLength = manifest.meanTrackLength,
           abs(meanTrackLength - manifestMeanTrackLength) > 0.01 {
            issues.append(String(
                format: "mean_track_length %.2f did not match points3D.txt %.2f",
                manifestMeanTrackLength,
                meanTrackLength
            ))
        }
        issues.append(contentsOf: da3SparseTextTrackIssues(paths: paths))
        return issues
    }

    private func da3SparseTextTrackIssues(paths: ProjectPaths) -> [String] {
        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let imagesTxt = sparseZero.appendingPathComponent("images.txt")
        let pointsTxt = sparseZero.appendingPathComponent("points3D.txt")
        guard let imagesText = try? String(contentsOf: imagesTxt, encoding: .utf8),
              let pointsText = try? String(contentsOf: pointsTxt, encoding: .utf8) else {
            return []
        }

        var imageObservationCounts: [Int: Int] = [:]
        let imageLines = imagesText.components(separatedBy: .newlines)
        var index = 0
        while index < imageLines.count {
            let poseLine = imageLines[index]
            guard isColmapImagePoseRow(poseLine) else {
                index += 1
                continue
            }
            let poseParts = poseLine.split(maxSplits: 9, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let imageID = Int(poseParts[0]) else {
                index += 1
                continue
            }
            let pointsLine = index + 1 < imageLines.count ? imageLines[index + 1] : ""
            let pointParts = pointsLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            imageObservationCounts[imageID] = pointParts.count / 3
            index += 2
        }

        var issues: [String] = []
        for line in pointsText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 8 else {
                issues.append("points3D.txt row had too few columns")
                continue
            }
            guard (parts.count - 8).isMultiple(of: 2) else {
                issues.append("points3D.txt track row had an incomplete observation pair")
                continue
            }
            var trackIndex = 8
            while trackIndex + 1 < parts.count {
                guard let imageID = Int(parts[trackIndex]),
                      let point2DIndex = Int(parts[trackIndex + 1]) else {
                    issues.append("points3D.txt track row had a non-numeric observation reference")
                    break
                }
                guard let observationCount = imageObservationCounts[imageID] else {
                    issues.append("points3D.txt track references missing image id \(imageID)")
                    break
                }
                guard point2DIndex >= 0, point2DIndex < observationCount else {
                    issues.append("points3D.txt track references image \(imageID) point2D index \(point2DIndex) outside 0..<\(observationCount)")
                    break
                }
                trackIndex += 2
            }
        }
        return issues
    }

    func isStageComplete(_ stage: PipelineStage, paths: ProjectPaths, metadata: ProjectMetadata) -> Bool {
        (try? validateStageOutput(stage, paths: paths, metadata: metadata)) == .valid
    }

    func validateColmapDatabaseOutput(paths: ProjectPaths, requireMatches: Bool) -> StageOutputStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.colmapDatabaseURL.path) else { return .missing }

        let size = (try? fm.attributesOfItem(atPath: paths.colmapDatabaseURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            if sparseModelFilesExist(at: sparseZero) {
                let da3Issues = da3DirectSparseValidationIssues(
                    paths: paths,
                    textStats: colmapSparseTextStats(at: sparseZero)
                )
                if !da3Issues.isEmpty {
                    return .corrupt(reason: "DA3 sparse manifest is invalid: \(da3Issues.joined(separator: "; "))")
                }
                return .valid
            }
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
