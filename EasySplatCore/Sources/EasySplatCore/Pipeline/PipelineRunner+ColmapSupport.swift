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

}
