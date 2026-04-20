import Foundation
import SQLite3

extension PipelineRunner {
    enum PipelineError: Error {
        case invalidInput
        case insufficientInputImages(Int)
        case lowQualityReconstruction(ReconstructionScore)
        case imageTranscodeFailed(String)
        case outputMissing
    }

    enum StageOutputStatus: Equatable, Sendable {
        case valid
        case missing
        case corrupt(reason: String)
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
            self.removeIfExists(paths.outputURL)
        case .selectFrames:
            self.removeIfExists(paths.framesSelectedURL)
            self.removeIfExists(paths.framesSelectedManifestURL)
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .sfmFeatures, .sfmMatching:
            self.removeIfExists(paths.colmapDatabaseURL)
            self.removeIfExists(paths.colmapSeedURL)
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .sfmMapping:
            self.removeIfExists(paths.colmapSparseURL)
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .trainBrush:
            self.removeIfExists(paths.trainingURL)
            self.removeIfExists(paths.outputURL)
        case .exportSplat:
            self.removeIfExists(paths.outputURL)
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
            case let .lowQualityReconstruction(score):
                return ("I couldn't get a stable camera solve. Try a slower capture and more light.", "Low-quality reconstruction. \(ReconstructionScorer.summary(score)).")
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
            for name in ["cameras.bin", "images.bin", "points3D.bin", "cameras.txt", "images.txt", "points3D.txt"] {
                let fileURL = sparseZero.appendingPathComponent(name)
                if !fm.fileExists(atPath: fileURL.path) { continue }
                let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                if size <= 0 {
                    return .corrupt(reason: "sparse model file \(name) is empty")
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
            return .valid
        case .trainBrush:
            guard let latest = tooling.brush.findLatestPly(in: paths.trainingURL) else { return .missing }
            return validatePlyFile(at: latest)
        case .exportSplat, .done:
            let output = paths.outputURL.appendingPathComponent("splat.ply")
            guard fm.fileExists(atPath: output.path) else { return .missing }
            return validatePlyFile(at: output)
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
            let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
            if sparseModelFilesExist(at: sparseZero) {
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
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            return .corrupt(reason: "\(url.lastPathComponent) is empty")
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else {
            return .corrupt(reason: "\(url.lastPathComponent) is not valid UTF-8 near header")
        }
        guard text.lowercased().hasPrefix("ply") else {
            return .corrupt(reason: "\(url.lastPathComponent) is not a PLY file")
        }
        guard text.contains("end_header") else {
            return .corrupt(reason: "\(url.lastPathComponent) is missing end_header")
        }
        let lines = text.split(separator: "\n").map(String.init)
        if let vertexLine = lines.first(where: { $0.lowercased().hasPrefix("element vertex ") }) {
            let comps = vertexLine.split(separator: " ")
            if let raw = comps.last, let count = Int(raw), count > 0 {
                return .valid
            }
            return .corrupt(reason: "\(url.lastPathComponent) has invalid vertex count")
        }
        return .corrupt(reason: "\(url.lastPathComponent) is missing vertex element metadata")
    }
}
