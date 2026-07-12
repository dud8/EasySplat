import Foundation

extension PipelineRunner {
    func sparseModelFilesExist(at url: URL) -> Bool {
        let fm = FileManager.default
        let binFiles = ["cameras.bin", "images.bin", "points3D.bin"]
        let txtFiles = ["cameras.txt", "images.txt", "points3D.txt"]
        let binOK = binFiles.allSatisfy { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        if binOK { return true }
        let txtOK = txtFiles.allSatisfy { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        return txtOK
    }

    func resolveSparseModelDirectory(at candidate: URL) throws -> URL {
        if sparseModelFilesExist(at: candidate) {
            return candidate
        }

        let nested = candidate.appendingPathComponent("0", isDirectory: true)
        if sparseModelFilesExist(at: nested) {
            return nested
        }

        // Some mapper variants can emit files into the parent sparse directory.
        let parent = candidate.deletingLastPathComponent()
        if sparseModelFilesExist(at: parent) {
            return parent
        }

        throw PipelineError.outputMissing
    }

    @discardableResult
    func ensureTextSparseModelFiles(at url: URL) throws -> Bool {
        let fm = FileManager.default
        let txtFiles = ["cameras.txt", "images.txt", "points3D.txt"]
        if txtFiles.allSatisfy({ fm.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return false
        }

        let binFiles = ["cameras.bin", "images.bin", "points3D.bin"]
        guard binFiles.allSatisfy({ fm.fileExists(atPath: url.appendingPathComponent($0).path) }) else {
            throw PipelineError.outputMissing
        }

        let converterOptions = colmapOptionsForMatching()
        try tooling.colmap.runModelConverter(
            colmapPath: config.toolchain.colmap,
            inputPath: url,
            outputPath: url,
            outputType: "TXT",
            environment: converterOptions.environment,
            onLog: { _, _ in }
        )

        guard txtFiles.allSatisfy({ fm.fileExists(atPath: url.appendingPathComponent($0).path) }) else {
            throw PipelineError.outputMissing
        }
        return true
    }

    func colmapOptionsForExtraction() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let extractThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: extractThreads,
            matchThreads: 1,
            sequentialOverlap: 10,
            maxNumFeatures: 8192,
            maxNumMatches: nil,
            useBruteForceMatcher: false,
            exhaustiveBlockSize: nil,
            environment: [
                "OMP_NUM_THREADS": "\(extractThreads)",
                "OPENBLAS_NUM_THREADS": "\(extractThreads)",
                "MKL_NUM_THREADS": "\(extractThreads)"
            ]
        )
    }

    func colmapOptionsForMatching() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let matchThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: matchThreads,
            matchThreads: matchThreads,
            sequentialOverlap: 10,
            maxNumFeatures: nil,
            maxNumMatches: 8192,
            useBruteForceMatcher: true,
            exhaustiveBlockSize: 20,
            environment: [
                "OMP_NUM_THREADS": "\(matchThreads)",
                "OPENBLAS_NUM_THREADS": "\(matchThreads)",
                "MKL_NUM_THREADS": "\(matchThreads)"
            ]
        )
    }

    func tuneSeededRefinementColmapOptions(
        frameCount: Int,
        extractOptions: ColmapOptions,
        matchOptions: ColmapOptions
    ) -> (extract: ColmapOptions, match: ColmapOptions, notes: [String]) {
        var tunedExtract = extractOptions
        var tunedMatch = matchOptions
        var notes: [String] = []

        guard frameCount >= 200 else {
            return (extract: tunedExtract, match: tunedMatch, notes: notes)
        }

        let overlapCap = frameCount >= 450 ? 6 : 8
        if tunedMatch.sequentialOverlap > overlapCap {
            notes.append("Seeded refinement speed profile: reduced sequential overlap \(tunedMatch.sequentialOverlap) -> \(overlapCap) for \(frameCount) frames.")
            tunedMatch.sequentialOverlap = overlapCap
        }

        let matchCap = frameCount >= 450 ? 7_000 : 8_000
        if let currentMatches = tunedMatch.maxNumMatches {
            if currentMatches > matchCap {
                notes.append("Seeded refinement speed profile: capped max matches \(currentMatches) -> \(matchCap).")
                tunedMatch.maxNumMatches = matchCap
            }
        } else {
            notes.append("Seeded refinement speed profile: set max matches to \(matchCap).")
            tunedMatch.maxNumMatches = matchCap
        }

        let featureCap = frameCount >= 450 ? 8_192 : 9_000
        if let currentFeatures = tunedExtract.maxNumFeatures, currentFeatures > featureCap {
            notes.append("Seeded refinement speed profile: capped max features \(currentFeatures) -> \(featureCap).")
            tunedExtract.maxNumFeatures = featureCap
        }

        if frameCount >= 450 {
            let blockCap = 30
            if let currentBlock = tunedMatch.exhaustiveBlockSize {
                if currentBlock < blockCap {
                    notes.append("Seeded refinement speed profile: raised exhaustive block size \(currentBlock) -> \(blockCap).")
                    tunedMatch.exhaustiveBlockSize = blockCap
                }
            } else {
                notes.append("Seeded refinement speed profile: set exhaustive block size to \(blockCap).")
                tunedMatch.exhaustiveBlockSize = blockCap
            }
        }

        return (extract: tunedExtract, match: tunedMatch, notes: notes)
    }
}
