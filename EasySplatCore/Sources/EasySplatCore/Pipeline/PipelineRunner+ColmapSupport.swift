import Darwin
import Foundation

struct MappedSparseModelCandidate: Sendable {
    let url: URL
    let order: Int
    let score: ReconstructionScore
}

struct MappedSparseModelSnapshot: Sendable {
    fileprivate let directory: SparseDirectoryState
    fileprivate let files: [String: SparseFileState]
}

private enum SparseModelPublicationError: Error, LocalizedError {
    case unsafeLayout
    case atomicRenameFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeLayout:
            return "COLMAP produced an unsafe sparse-model layout."
        case .atomicRenameFailed(let code):
            return "Could not publish the selected COLMAP model atomically (errno \(code))."
        }
    }
}

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

    func mappedSparseModelDirectories(in root: URL) throws -> [(url: URL, order: Int)] {
        guard privateDirectoryState(at: root) != nil else {
            throw SparseModelPublicationError.unsafeLayout
        }
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.compactMap { child -> (url: URL, order: Int)? in
            let name = child.lastPathComponent
            guard let order = Int(name), order >= 0, String(order) == name,
                  isSafeSparseModelDirectory(child) else {
                return nil
            }
            return (child, order)
        }.sorted { lhs, rhs in
            lhs.order < rhs.order
        }
        guard !candidates.isEmpty else { throw PipelineError.outputMissing }
        return candidates
    }

    func captureMappedSparseModel(at url: URL) throws -> MappedSparseModelSnapshot {
        guard let initialDirectory = privateDirectoryState(at: url) else {
            throw SparseModelPublicationError.unsafeLayout
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var files: [String: SparseFileState] = [:]
        files.reserveCapacity(entries.count)
        for entry in entries {
            guard let state = privateRegularFileState(at: entry),
                  files.updateValue(state, forKey: entry.lastPathComponent) == nil else {
                throw SparseModelPublicationError.unsafeLayout
            }
        }
        let binary = ["cameras.bin", "images.bin", "points3D.bin"]
        let text = ["cameras.txt", "images.txt", "points3D.txt"]
        guard binary.allSatisfy({ files[$0] != nil })
                || text.allSatisfy({ files[$0] != nil }),
              privateDirectoryState(at: url) == initialDirectory else {
            throw SparseModelPublicationError.unsafeLayout
        }
        for (name, state) in files
            where privateRegularFileState(at: url.appendingPathComponent(name)) != state {
            throw SparseModelPublicationError.unsafeLayout
        }
        return MappedSparseModelSnapshot(directory: initialDirectory, files: files)
    }

    func validateMappedSparseModel(
        _ snapshot: MappedSparseModelSnapshot,
        at url: URL
    ) throws {
        guard privateDirectoryState(at: url) == snapshot.directory else {
            throw SparseModelPublicationError.unsafeLayout
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        guard names == snapshot.files.keys.sorted() else {
            throw SparseModelPublicationError.unsafeLayout
        }
        for (name, expected) in snapshot.files
            where privateRegularFileState(at: url.appendingPathComponent(name)) != expected {
            throw SparseModelPublicationError.unsafeLayout
        }
    }

    static func preferredMappedSparseModel(
        _ lhs: MappedSparseModelCandidate,
        over rhs: MappedSparseModelCandidate
    ) -> Bool {
        if lhs.score.registeredImages != rhs.score.registeredImages {
            return lhs.score.registeredImages > rhs.score.registeredImages
        }
        let lhsObservations = lhs.score.observationCount ?? -1
        let rhsObservations = rhs.score.observationCount ?? -1
        if lhsObservations != rhsObservations {
            return lhsObservations > rhsObservations
        }
        let lhsPoints = lhs.score.pointCount ?? -1
        let rhsPoints = rhs.score.pointCount ?? -1
        if lhsPoints != rhsPoints {
            return lhsPoints > rhsPoints
        }
        let lhsResidual = lhs.score.meanReprojectionError.flatMap { $0.isFinite ? $0 : nil }
            ?? .infinity
        let rhsResidual = rhs.score.meanReprojectionError.flatMap { $0.isFinite ? $0 : nil }
            ?? .infinity
        if lhsResidual != rhsResidual {
            return lhsResidual < rhsResidual
        }
        return lhs.order < rhs.order
    }

    static func selectMappedSparseModel(
        from candidates: [MappedSparseModelCandidate],
        capturePath: CapturePath
    ) -> MappedSparseModelCandidate? {
        guard !candidates.isEmpty else { return nil }
        let acceptable = candidates.filter {
            ReconstructionScorer.isAcceptable($0.score, capturePath: capturePath)
        }
        let pool = acceptable.isEmpty ? candidates : acceptable
        var selected = pool[0]
        for candidate in pool.dropFirst()
            where preferredMappedSparseModel(candidate, over: selected) {
            selected = candidate
        }
        return selected
    }

    func publishCanonicalSparseModel(
        from selectedModel: URL,
        snapshot: MappedSparseModelSnapshot,
        at sparseRoot: URL,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        let canonical = sparseRoot.appendingPathComponent("0", isDirectory: true)
        guard selectedModel.deletingLastPathComponent().standardizedFileURL
                == sparseRoot.standardizedFileURL,
              let selectedOrder = Int(selectedModel.lastPathComponent),
              selectedOrder >= 0,
              String(selectedOrder) == selectedModel.lastPathComponent else {
            throw SparseModelPublicationError.unsafeLayout
        }
        try validateMappedSparseModel(snapshot, at: selectedModel)
        try checkCancellation()

        if selectedOrder != 0 {
            let rootDescriptor = Darwin.open(
                sparseRoot.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootDescriptor >= 0 else {
                throw SparseModelPublicationError.unsafeLayout
            }
            defer { Darwin.close(rootDescriptor) }
            let canonicalExists = privateDirectoryState(at: canonical) != nil
            let flags = canonicalExists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
            let renameResult = selectedModel.lastPathComponent.withCString { selectedName in
                "0".withCString { canonicalName in
                    renameatx_np(
                        rootDescriptor,
                        selectedName,
                        rootDescriptor,
                        canonicalName,
                        flags
                    )
                }
            }
            guard renameResult == 0 else {
                throw SparseModelPublicationError.atomicRenameFailed(errno)
            }
            guard Darwin.fsync(rootDescriptor) == 0 else {
                throw SparseModelPublicationError.atomicRenameFailed(errno)
            }
        }

        try validateMappedSparseModel(snapshot, at: canonical)
        let children = try FileManager.default.contentsOfDirectory(
            at: sparseRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where child.lastPathComponent != "0" {
            let name = child.lastPathComponent
            guard let order = Int(name), order >= 0, String(order) == name else { continue }
            try removeItemIfPresent(child)
        }
    }

    private func isSafeSparseModelDirectory(_ url: URL) -> Bool {
        (try? captureMappedSparseModel(at: url)) != nil
    }

    private func privateDirectoryState(at url: URL) -> SparseDirectoryState? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return SparseDirectoryState(metadata)
    }

    private func privateRegularFileState(at url: URL) -> SparseFileState? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            return nil
        }
        return SparseFileState(metadata)
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

struct SparseFileState: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        byteCount = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

struct SparseDirectoryState: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
    }
}
