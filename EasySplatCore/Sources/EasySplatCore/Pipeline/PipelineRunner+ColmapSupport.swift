import Darwin
import Foundation

struct MappedSparseModelCandidate: Sendable {
    let url: URL
    let order: Int
    let score: ReconstructionScore
}

struct MappingFragmentationEvidence: Sendable, Equatable {
    let selectedModelOrder: Int
    let selectedRegisteredViewCount: Int
    let credibleUnionRegisteredViewCount: Int
    let omittedRecoverableViewCount: Int
    let totalSelectedViewCount: Int
}

struct MappedSparseModelSnapshot: Sendable {
    fileprivate let directory: SparseDirectoryState
    fileprivate let files: [String: SparseFileState]
}

enum SparseTextPublicationCheckpoint: Sendable {
    case beforeSwap
    case afterSwap
    case beforePublishedValidation
}

private enum SparseModelPublicationError: Error, LocalizedError {
    case unsafeLayout
    case atomicRenameFailed(Int32)
    case atomicTextPublicationFailed(Int32)
    case atomicTextRollbackFailed(Int32, recoveryDirectory: String)

    var errorDescription: String? {
        switch self {
        case .unsafeLayout:
            return "COLMAP produced an unsafe sparse-model layout."
        case .atomicRenameFailed(let code):
            return "Could not publish the selected COLMAP model atomically (errno \(code))."
        case .atomicTextPublicationFailed(let code):
            return "Could not publish the COLMAP text model atomically (errno \(code))."
        case .atomicTextRollbackFailed(let code, let recoveryDirectory):
            return "Could not restore the previous COLMAP text model (errno \(code)). The preserved recovery directory is \(recoveryDirectory)."
        }
    }
}

extension PipelineRunner {
    static func normalizedUnusableSparseModelError(_ error: Error) -> Error {
        if let pathError = error as? ProjectPathError {
            switch pathError {
            case .escapesProjectRoot, .unsafeDirectory:
                return PipelineError.outputMissing
            case .emptyPath, .absolutePath, .unsafeComponent:
                return error
            }
        }
        guard let publicationError = error as? SparseModelPublicationError else {
            return error
        }
        switch publicationError {
        case .unsafeLayout:
            return PipelineError.outputMissing
        case .atomicRenameFailed, .atomicTextPublicationFailed,
                .atomicTextRollbackFailed:
            return error
        }
    }

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
        var candidates: [(url: URL, order: Int)] = []
        candidates.reserveCapacity(children.count)
        for child in children {
            let name = child.lastPathComponent
            let bytes = Array(name.utf8)
            let hasSign = bytes.first == 43 || bytes.first == 45
            let numericBytes = hasSign ? bytes.dropFirst() : bytes[...]
            let isNumericName = !numericBytes.isEmpty && numericBytes.allSatisfy {
                $0 >= 48 && $0 <= 57
            }
            guard isNumericName else { continue }
            guard let order = Int(name), order >= 0, String(order) == name,
                  isSafeSparseModelDirectory(child) else {
                throw SparseModelPublicationError.unsafeLayout
            }
            candidates.append((child, order))
        }
        candidates.sort { lhs, rhs in
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
        rankedMappedSparseModels(
            candidates,
            capturePath: capturePath
        ).first
    }

    static func rankedMappedSparseModels(
        _ candidates: [MappedSparseModelCandidate],
        capturePath: CapturePath
    ) -> [MappedSparseModelCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsAcceptable = ReconstructionScorer.isAcceptable(
                lhs.score,
                capturePath: capturePath
            )
            let rhsAcceptable = ReconstructionScorer.isAcceptable(
                rhs.score,
                capturePath: capturePath
            )
            if lhsAcceptable != rhsAcceptable {
                return lhsAcceptable
            }
            return preferredMappedSparseModel(lhs, over: rhs)
        }
    }

    static func mappingFragmentationEvidence(
        selected: MappedSparseModelCandidate,
        candidates: [MappedSparseModelCandidate],
        memberships: [ColmapSparseModelMembership],
        residualValidatedModelOrders: Set<Int>,
        totalSelectedViewCount: Int
    ) -> MappingFragmentationEvidence? {
        guard totalSelectedViewCount > 0 else { return nil }

        var membershipByOrder: [Int: Set<UInt32>] = [:]
        for membership in memberships {
            guard membershipByOrder[membership.modelOrder] == nil else { return nil }
            membershipByOrder[membership.modelOrder] = membership.imageIDs
        }
        guard let selectedImageIDs = membershipByOrder[selected.order],
              selectedImageIDs.count == selected.score.registeredImages,
              selectedImageIDs.count <= totalSelectedViewCount else {
            return nil
        }

        var credibleUnion = selectedImageIDs
        var seenCandidateOrders: Set<Int> = []
        for candidate in candidates {
            guard seenCandidateOrders.insert(candidate.order).inserted,
                  candidate.order != selected.order,
                  let imageIDs = membershipByOrder[candidate.order],
                  residualValidatedModelOrders.contains(candidate.order),
                  credibleFragmentCandidate(
                    candidate,
                    imageIDs: imageIDs,
                    totalSelectedViewCount: totalSelectedViewCount
                  ) else {
                continue
            }
            credibleUnion.formUnion(imageIDs)
        }

        guard credibleUnion.count <= totalSelectedViewCount else { return nil }
        let omittedCount = credibleUnion.subtracting(selectedImageIDs).count
        guard omittedCount > ColmapMappingPolicy.maximumAcceptedRecoverableViewLoss else {
            return nil
        }
        return MappingFragmentationEvidence(
            selectedModelOrder: selected.order,
            selectedRegisteredViewCount: selectedImageIDs.count,
            credibleUnionRegisteredViewCount: credibleUnion.count,
            omittedRecoverableViewCount: omittedCount,
            totalSelectedViewCount: totalSelectedViewCount
        )
    }

    static func credibleFragmentCandidate(
        _ candidate: MappedSparseModelCandidate,
        imageIDs: Set<UInt32>,
        totalSelectedViewCount: Int
    ) -> Bool {
        guard imageIDs.count == candidate.score.registeredImages,
              imageIDs.count > ColmapMappingPolicy.maximumAcceptedRecoverableViewLoss,
              imageIDs.count <= totalSelectedViewCount,
              let points = candidate.score.pointCount, points > 0,
              let observations = candidate.score.observationCount, observations > 0,
              let trackLength = candidate.score.meanTrackLength,
              trackLength.isFinite, trackLength > 0,
              let residual = candidate.score.meanReprojectionError,
              residual.isFinite,
              residual >= 0,
              residual <= ReconstructionScorer.maximumMeanReprojectionError else {
            return false
        }
        return true
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

    private func synchronizeSparseModelFile(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SparseModelPublicationError.atomicTextPublicationFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw SparseModelPublicationError.unsafeLayout
        }
        while Darwin.fsync(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw SparseModelPublicationError.atomicTextPublicationFailed(code)
        }
    }

    private func synchronizeSparseModelDirectory(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw SparseModelPublicationError.atomicTextPublicationFailed(code)
        }
    }

    @discardableResult
    func ensureTextSparseModelFiles(
        at url: URL,
        publicationCheckpoint: (SparseTextPublicationCheckpoint) throws -> Void = { _ in }
    ) throws -> Bool {
        let fm = FileManager.default
        let txtFiles = ["cameras.txt", "images.txt", "points3D.txt"]
        let binFiles = ["cameras.bin", "images.bin", "points3D.bin"]
        let hasBinaryModel = binFiles.allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        if !hasBinaryModel {
            guard txtFiles.allSatisfy({
                fm.fileExists(atPath: url.appendingPathComponent($0).path)
            }) else {
                throw PipelineError.outputMissing
            }
            _ = try captureMappedSparseModel(at: url)
            return false
        }

        let sourceSnapshot = try captureMappedSparseModel(at: url)
        let stagingRoot = url.deletingLastPathComponent().appendingPathComponent(
            ".text-model-\(UUID().uuidString)",
            isDirectory: true
        )
        let binaryInput = stagingRoot.appendingPathComponent("binary", isDirectory: true)
        let textOutput = stagingRoot.appendingPathComponent("text", isDirectory: true)
        let replacement = stagingRoot.appendingPathComponent("replacement", isDirectory: true)
        try fm.createDirectory(at: binaryInput, withIntermediateDirectories: true)
        try fm.createDirectory(at: textOutput, withIntermediateDirectories: true)
        var preserveStaging = false
        defer {
            if !preserveStaging {
                try? fm.removeItem(at: stagingRoot)
            }
        }
        for name in binFiles {
            try fm.copyItem(
                at: url.appendingPathComponent(name),
                to: binaryInput.appendingPathComponent(name)
            )
        }

        let converterOptions = colmapOptionsForMatching()
        try tooling.colmap.runModelConverter(
            colmapPath: config.toolchain.colmap,
            inputPath: binaryInput,
            outputPath: textOutput,
            outputType: "TXT",
            environment: converterOptions.environment,
            onLog: { _, _ in }
        )
        for name in txtFiles {
            guard let state = privateRegularFileState(
                at: textOutput.appendingPathComponent(name)
            ), state.byteCount > 0 else {
                throw PipelineError.outputMissing
            }
        }
        try validateMappedSparseModel(sourceSnapshot, at: url)
        try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
        for name in sourceSnapshot.files.keys.sorted() {
            try fm.copyItem(
                at: url.appendingPathComponent(name),
                to: replacement.appendingPathComponent(name)
            )
        }
        for name in txtFiles {
            let source = textOutput.appendingPathComponent(name)
            let destination = replacement.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: source, to: destination)
        }
        let replacementSnapshot = try captureMappedSparseModel(at: replacement)
        for name in txtFiles where replacementSnapshot.files[name]?.byteCount ?? 0 <= 0 {
            throw PipelineError.outputMissing
        }
        let convertedModel = try ColmapResidualAnalyzer.analyze(
            modelDirectory: replacement
        )
        guard convertedModel.registeredViewCount > 0,
              convertedModel.pointCount > 0,
              convertedModel.observationCount > 0 else {
            throw PipelineError.outputMissing
        }
        try validateMappedSparseModel(sourceSnapshot, at: url)

        for name in replacementSnapshot.files.keys.sorted() {
            try synchronizeSparseModelFile(at: replacement.appendingPathComponent(name))
        }
        let replacementDescriptor = Darwin.open(
            replacement.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard replacementDescriptor >= 0 else {
            throw SparseModelPublicationError.unsafeLayout
        }
        defer { Darwin.close(replacementDescriptor) }
        try synchronizeSparseModelDirectory(replacementDescriptor)

        let parent = url.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw SparseModelPublicationError.unsafeLayout
        }
        defer { Darwin.close(parentDescriptor) }
        let stagingDescriptor = Darwin.open(
            stagingRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard stagingDescriptor >= 0 else {
            throw SparseModelPublicationError.unsafeLayout
        }
        defer { Darwin.close(stagingDescriptor) }
        try synchronizeSparseModelDirectory(stagingDescriptor)

        func exchangeModels() -> Int32 {
            url.lastPathComponent.withCString { currentName in
                "replacement".withCString { replacementName in
                    renameatx_np(
                        parentDescriptor,
                        currentName,
                        stagingDescriptor,
                        replacementName,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        }
        try validateMappedSparseModel(replacementSnapshot, at: replacement)
        try publicationCheckpoint(.beforeSwap)
        let renameResult = exchangeModels()
        guard renameResult == 0 else {
            throw SparseModelPublicationError.atomicTextPublicationFailed(errno)
        }

        do {
            try publicationCheckpoint(.afterSwap)
            try synchronizeSparseModelDirectory(parentDescriptor)
            try synchronizeSparseModelDirectory(stagingDescriptor)
            try publicationCheckpoint(.beforePublishedValidation)
            try validateMappedSparseModel(replacementSnapshot, at: url)
        } catch {
            do {
                try validateMappedSparseModel(sourceSnapshot, at: replacement)
                let rollbackResult = exchangeModels()
                guard rollbackResult == 0 else {
                    let rollbackCode = errno
                    preserveStaging = true
                    throw SparseModelPublicationError.atomicTextRollbackFailed(
                        rollbackCode,
                        recoveryDirectory: stagingRoot.path
                    )
                }
                try synchronizeSparseModelDirectory(parentDescriptor)
                try synchronizeSparseModelDirectory(stagingDescriptor)
                try validateMappedSparseModel(sourceSnapshot, at: url)
            } catch let rollbackError as SparseModelPublicationError {
                if case .atomicTextRollbackFailed = rollbackError {
                    throw rollbackError
                }
                preserveStaging = true
                throw SparseModelPublicationError.atomicTextRollbackFailed(
                    EIO,
                    recoveryDirectory: stagingRoot.path
                )
            } catch {
                preserveStaging = true
                throw SparseModelPublicationError.atomicTextRollbackFailed(
                    EIO,
                    recoveryDirectory: stagingRoot.path
                )
            }
            throw error
        }
        try? fm.removeItem(at: replacement)
        try? synchronizeSparseModelDirectory(stagingDescriptor)
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
        onExactRecovery: () throws -> Void
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

            attemptOptions.descriptorMatcher = .exact
            try onExactRecovery()
            try ColmapDatabaseMatchStore.clearMatchingResults(at: database)
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
