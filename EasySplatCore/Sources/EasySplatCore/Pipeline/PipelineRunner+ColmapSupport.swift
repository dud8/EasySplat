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

    func prepareDa3RefinementSeed(
        rawModelURL: URL,
        outputModelURL: URL,
        databaseURL: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> Bool {
        let fileManager = FileManager.default
        let outputRootURL = outputModelURL.deletingLastPathComponent()
        try removeItemIfPresent(outputRootURL)
        let files = [
            (name: "cameras.txt", maximumBytes: ColmapTextFileLimits.cameras),
            (name: "images.txt", maximumBytes: ColmapTextFileLimits.images),
            (name: "points3D.txt", maximumBytes: ColmapTextFileLimits.points),
        ]
        do {
            try checkCancellation()
            try fileManager.createDirectory(
                at: outputModelURL,
                withIntermediateDirectories: true
            )
            for file in files {
                try checkCancellation()
                let reader = try BoundedUTF8LineReader(
                    at: rawModelURL.appendingPathComponent(file.name),
                    maximumBytes: file.maximumBytes,
                    maximumLineBytes: min(
                        file.maximumBytes,
                        ColmapTextFileLimits.maximumLine
                    )
                )
                let writer = try BufferedUTF8LineWriter(
                    at: outputModelURL.appendingPathComponent(file.name)
                )
                while let line = try reader.next(checkCancellation: checkCancellation) {
                    try writer.write(line)
                }
                try writer.finish()
            }
            let normalized = try ColmapTextModelNormalizer.normalizeImagesTxtIfNeeded(
                at: outputModelURL.appendingPathComponent("images.txt"),
                checkCancellation: checkCancellation
            )
            let remapped = try ColmapTextModelNormalizer.remapSeedModelIDsToDatabase(
                seedModelURL: outputModelURL,
                databaseURL: databaseURL,
                checkCancellation: checkCancellation
            )
            try checkCancellation()
            return normalized || remapped
        } catch {
            try removeItemIfPresent(outputRootURL)
            throw error
        }
    }

    func colmapOptionsForExtraction() -> ColmapOptions {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let extractThreads = min(8, max(2, cores / 2))
        return ColmapOptions(
            useGPU: false,
            extractThreads: extractThreads,
            matchThreads: 1,
            maxNumFeatures: 8192,
            maxNumMatches: nil,
            descriptorMatcher: .faiss,
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
            maxNumFeatures: nil,
            maxNumMatches: 8192,
            descriptorMatcher: .faiss,
            environment: [
                "OMP_NUM_THREADS": "\(matchThreads)",
                "OPENBLAS_NUM_THREADS": "\(matchThreads)",
                "MKL_NUM_THREADS": "\(matchThreads)"
            ]
        )
    }

    func runDa3MatchesImporterWithOneShotExactRecovery(
        database: URL,
        matchListPath: URL,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void,
        emit: @escaping @Sendable (PipelineEvent) -> Void,
        onExactRecovery: () -> Void
    ) async throws {
        var attemptOptions = options
        do {
            try await tooling.colmap.runMatchesImporter(
                colmapPath: config.toolchain.colmap,
                database: database,
                matchListPath: matchListPath,
                matchType: "pairs",
                options: attemptOptions,
                onLog: onLog
            )
            return
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard let reason = DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: attemptOptions.descriptorMatcher
            ) else {
                throw error
            }

            try ColmapDatabaseMatchStore.clearMatchingResults(at: database)
            attemptOptions.descriptorMatcher = .exact
            onExactRecovery()
            emit(.stageLog(
                stage: .sfmMatching,
                line: "FAISS matching failed (\(reason.rawValue)); preserving features and retrying with exact matching.",
                isError: true
            ))
            emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
            try Task.checkCancellation()
            try await tooling.colmap.runMatchesImporter(
                colmapPath: config.toolchain.colmap,
                database: database,
                matchListPath: matchListPath,
                matchType: "pairs",
                options: attemptOptions,
                onLog: onLog
            )
        }
    }

}
