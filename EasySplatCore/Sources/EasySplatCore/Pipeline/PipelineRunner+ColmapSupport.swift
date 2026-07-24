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

struct Da3MatchingExecution: Sendable {
    let attempts: [PairGraphAttemptEvidence]
    let acceptedInspection: ColmapPairGraphInspection

    var matchingDurationSeconds: Double {
        attempts.reduce(0) { $0 + $1.artifact.durationSeconds }
    }
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
    func prepareTextSparseModelForCanonicalPublication(
        at url: URL,
        mappingAttemptOrdinal: Int,
        workerExecutionRecorder: GeometryWorkerExecutionRecorder
    ) throws -> CanonicalModelPublicationArtifact {
        let binaryNames = ["cameras.bin", "images.bin", "points3D.bin"]
        let textNames = ["cameras.txt", "images.txt", "points3D.txt"]
        let hasBinarySource = binaryNames.allSatisfy {
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent($0).path
            )
        }
        let sourceNames = hasBinarySource ? binaryNames : textNames
        let sourceHashes = try Dictionary(uniqueKeysWithValues: sourceNames.map { name in
            (name, try GeometryArtifactStore.sha256(of: url.appendingPathComponent(name)))
        })
        let candidateProjectRelativePath = try ProjectPaths(root: projectURL)
            .projectRelativePath(for: url)
        let converterInvocationCountBefore = workerExecutionRecorder
            .modelConverterInvocationCount(
                mappingAttemptOrdinal: mappingAttemptOrdinal
            )
        let successfulConverterCountBefore = workerExecutionRecorder
            .successfulModelConverterInvocationCount(
                mappingAttemptOrdinal: mappingAttemptOrdinal
            )
        let converted = try ensureTextSparseModelFiles(
            at: url,
            mappingAttemptOrdinal: mappingAttemptOrdinal,
            candidateProjectRelativePath: candidateProjectRelativePath
        )
        let converterInvocationCountAfter = workerExecutionRecorder
            .modelConverterInvocationCount(
                mappingAttemptOrdinal: mappingAttemptOrdinal
            )
        let successfulConverterCountAfter = workerExecutionRecorder
            .successfulModelConverterInvocationCount(
                mappingAttemptOrdinal: mappingAttemptOrdinal
            )
        if hasBinarySource {
            guard converted,
                  converterInvocationCountAfter == converterInvocationCountBefore + 1,
                  successfulConverterCountAfter == successfulConverterCountBefore + 1,
                  let invocation = workerExecutionRecorder.modelConverterInvocation(
                      mappingAttemptOrdinal: mappingAttemptOrdinal,
                      oneBasedOrdinal: converterInvocationCountAfter
                  ),
                  invocation.succeeded,
                  let workerEvidence = invocation.modelConversion,
                  let sourceDigest = GeometryArtifactStore.modelClosureDigest(
                      sourceHashes,
                      expectedNames: binaryNames
                  ),
                  workerEvidence.sourceModelDigest == sourceDigest,
                  workerEvidence.candidateIdentitySHA256
                    == GeometryArtifactStore.modelCandidateIdentity(
                        mappingAttemptOrdinal: mappingAttemptOrdinal,
                        candidateProjectRelativePath: candidateProjectRelativePath,
                        sourceModelDigest: sourceDigest
                    ) else {
                throw PipelineError.outputMissing
            }
            return CanonicalModelPublicationArtifact(
                kind: .convertedFromBinary,
                sourceModelHashes: sourceHashes,
                conversion: CanonicalModelConversionArtifact(
                    invocationOrdinal: converterInvocationCountAfter,
                    workerEvidence: workerEvidence
                )
            )
        }
        guard !converted,
              converterInvocationCountAfter == converterInvocationCountBefore,
              successfulConverterCountAfter == successfulConverterCountBefore else {
            throw PipelineError.outputMissing
        }
        return CanonicalModelPublicationArtifact(
            kind: .directText,
            sourceModelHashes: sourceHashes,
            conversion: nil
        )
    }

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
        totalSelectedViewCount: Int,
        admittedImageIDs: Set<UInt32>? = nil
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
        // Views matching already excluded from the admitted component are
        // expected losses, not mapper fragmentation; only count omitted views
        // the pair graph said belong with the selected reconstruction.
        var omitted = credibleUnion.subtracting(selectedImageIDs)
        if let admittedImageIDs {
            omitted.formIntersection(admittedImageIDs)
        }
        let omittedCount = omitted.count
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
        mappingAttemptOrdinal: Int? = nil,
        candidateProjectRelativePath: String? = nil,
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

        let conversionContext: ColmapModelConversionWorkerInvocationContext?
        switch (mappingAttemptOrdinal, candidateProjectRelativePath) {
        case let (.some(attempt), .some(candidatePath)):
            let paths = ProjectPaths(root: projectURL)
            conversionContext = ColmapModelConversionWorkerInvocationContext(
                mappingAttemptOrdinal: attempt,
                projectRootURL: projectURL,
                candidateProjectRelativePath: candidatePath,
                inputProjectRelativePath: try paths.projectRelativePath(for: binaryInput),
                outputProjectRelativePath: try paths.projectRelativePath(for: textOutput),
                inputURL: binaryInput,
                outputURL: textOutput
            )
        case (nil, nil):
            conversionContext = nil
        default:
            throw PipelineError.outputMissing
        }
        try tooling.colmap.runModelConverter(
            colmapPath: config.toolchain.colmap,
            inputPath: binaryInput,
            outputPath: textOutput,
            outputType: "TXT",
            environment: colmapUtilityEnvironment(),
            recordGeometryWorkerExecution: conversionContext != nil,
            modelConversionContext: conversionContext,
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

    /// Copies an externally produced COLMAP text seed (a DA3 aligned seed or an
    /// imported dataset pose seed) into the refinement staging area with bounded
    /// readers, then remaps its image and camera IDs onto the live feature
    /// database. Returns true when normalization or remapping changed the model.
    func prepareExternalRefinementSeed(
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

    /// Rewrites the persisted dataset pose seed (`Import/seed`) so its image
    /// NAME fields reference the selected frame files, then stages the result
    /// under `SfM/colmap/seed/import/0` for database ID remapping. The seed's
    /// NAMEs are dataset-declared paths; the adoption receipt binds each
    /// declared path to the adopted photo, and the selected-frame manifest
    /// binds that photo (by source digest) to its `Frames/selected` output.
    /// Every seed image must resolve.
    func finalizeImportedPoseSeed(
        receipt: DatasetPoseSeedReceipt,
        paths: ProjectPaths,
        selectedFrameManifest: [SelectedFrameMapping],
        checkCancellation: () throws -> Void = {},
        onLog: (String) -> Void = { _ in }
    ) throws -> URL {
        var model = try ColmapModelReader.readText(modelDirectory: paths.importSeedURL)
        let entriesByDeclaredPath = Dictionary(
            receipt.entries.map { ($0.declaredPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var selectedNameBySourceSHA256: [String: String] = [:]
        for mapping in selectedFrameManifest {
            if let sourceSHA256 = mapping.sourceSHA256,
               selectedNameBySourceSHA256[sourceSHA256] == nil {
                selectedNameBySourceSHA256[sourceSHA256] = mapping.outputFileName
            }
        }
        for index in model.images.indices {
            try checkCancellation()
            let declaredPath = model.images[index].name
            guard let entry = entriesByDeclaredPath[declaredPath] else {
                onLog("The imported pose seed lists \(declaredPath), which has no adoption receipt entry.")
                throw PipelineError.geometryRegisteredImagesMismatch
            }
            guard let selectedName = selectedNameBySourceSHA256[entry.sourceSHA256] else {
                onLog("The imported pose seed image \(declaredPath) has no selected frame.")
                throw PipelineError.geometryRegisteredImagesMismatch
            }
            model.images[index].name = selectedName
        }
        let emitted = try ColmapTextModelEmitter.emit(model)
        let stagingRootURL = paths.colmapSeedURL.appendingPathComponent(
            "import",
            isDirectory: true
        )
        let stagingModelURL = stagingRootURL.appendingPathComponent("0", isDirectory: true)
        try removeItemIfPresent(stagingRootURL)
        do {
            try checkCancellation()
            try FileManager.default.createDirectory(
                at: stagingModelURL,
                withIntermediateDirectories: true
            )
            let files = [
                ("cameras.txt", emitted.camerasTxt),
                ("images.txt", emitted.imagesTxt),
                ("points3D.txt", emitted.points3DTxt),
            ]
            for (name, contents) in files {
                try contents.write(
                    to: stagingModelURL.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            try removeItemIfPresent(stagingRootURL)
            throw error
        }
        return stagingModelURL
    }

    /// The shared seeded-triangulation mapping tail: point_triangulator against
    /// a prepared refinement seed, one bounded bundle adjustment, then the
    /// canonical-text, conditioning, membership, and scorer acceptance gates.
    /// Both the DA3 aligned-seed branch and the imported-pose dataset branch
    /// run this single implementation.
    func runSeededTriangulationMapping(
        seedModelURL: URL,
        paths: ProjectPaths,
        selectedFrames: [URL],
        capturePath: CapturePath,
        bundleOptions: ColmapBundleAdjustmentOptions,
        mapperLabel: String,
        toolLogSectionTitle: String,
        refinementLogNoun: String,
        scoreLogLabel: String,
        beginMappingAttempt: () throws -> Int,
        currentMappingAttemptCount: () -> Int,
        prepareCanonicalTextCandidate: (URL, Int) throws -> CanonicalModelPublicationArtifact,
        emit: (PipelineEvent) -> Void
    ) async throws -> (artifact: MappingArtifact, conditioning: GeometryConditioningAnalysis) {
        let fm = FileManager.default
        let sparseZero = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let mappingAttemptOrdinal = try beginMappingAttempt()
        try resetDirectory(paths.colmapSparseURL)
        try resetDirectory(sparseZero)
        let colmapToolLog = ToolLogWriter(fileURL: paths.colmapLogURL, toolName: "colmap")
        colmapToolLog.beginSection(
            title: toolLogSectionTitle,
            metadata: [
                "database": paths.colmapDatabaseURL.path,
                "images": paths.framesSelectedURL.path,
                "seed": seedModelURL.path,
                "output": sparseZero.path,
                "tool": config.toolchain.colmap.path
            ]
        )
        emit(.stageLog(
            stage: .sfmMapping,
            line: "Running \(refinementLogNoun): point_triangulator.",
            isError: false
        ))
        try tooling.checkCancellation()
        try await tooling.colmap.runPointTriangulator(
            colmapPath: config.toolchain.colmap,
            database: paths.colmapDatabaseURL,
            imagePath: paths.framesSelectedURL,
            inputPath: seedModelURL,
            outputPath: sparseZero,
            environment: [:],
            onLog: { line, isErr in
                colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
            }
        )

        let baOutput = paths.colmapSparseURL.appendingPathComponent("0_ba", isDirectory: true)
        removeIfExists(baOutput)
        try fm.createDirectory(at: baOutput, withIntermediateDirectories: true)
        emit(.stageLog(
            stage: .sfmMapping,
            line: "Running \(refinementLogNoun): bundle_adjuster.",
            isError: false
        ))
        try await tooling.colmap.runBundleAdjuster(
            colmapPath: config.toolchain.colmap,
            inputPath: sparseZero,
            outputPath: baOutput,
            environment: [:],
            bundleOptions: bundleOptions,
            onLog: { line, isErr in
                colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
            }
        )
        guard sparseModelFilesExist(at: baOutput) else {
            throw PipelineError.outputMissing
        }
        removeIfExists(sparseZero)
        try fm.moveItem(at: baOutput, to: sparseZero)
        let canonicalModelPublication = try prepareCanonicalTextCandidate(
            sparseZero,
            mappingAttemptOrdinal
        )
        let conditioningAnalysis = try validatedConditionedGeometry(
            modelDirectory: sparseZero,
            selectedFrames: selectedFrames,
            requireStrongObservationCoverage: true
        )

        let membership = try ColmapSparseModelMembershipReader(
            databaseURL: paths.colmapDatabaseURL,
            selectedImageNames: selectedFrames.map(\.lastPathComponent)
        ).read(
            modelDirectories: [sparseZero],
            checkCancellation: tooling.checkCancellation
        )

        let report = try await tooling.colmap.runModelAnalyzer(
            colmapPath: config.toolchain.colmap,
            modelPath: sparseZero,
            environment: [:]
        )
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            colmapToolLog.append(stream: "stdout", line: String(line))
        }
        let score = ReconstructionScorer.applyingExpectedTotalImages(
            ReconstructionScorer.parseModelAnalyzerOutput(report),
            expectedTotalImages: selectedFrames.count
        )
        emit(.stageLog(
            stage: .sfmMapping,
            line: "\(scoreLogLabel): \(ReconstructionScorer.summary(score)).",
            isError: false
        ))
        guard ReconstructionScorer.isAcceptable(
            score,
            capturePath: capturePath
        ),
              score.registeredImages
                == membership.largestModelRegisteredViewCount,
              conditioningAnalysis.residuals.registeredViewCount
                == score.registeredImages,
              let residual = score.meanReprojectionError,
              residual.isFinite else {
            throw PipelineError.lowQualityReconstruction(score, mapper: mapperLabel)
        }
        let artifact = MappingArtifact(
            modelCount: membership.modelCount,
            largestModelRegisteredViewCount:
                membership.largestModelRegisteredViewCount,
            secondLargestModelRegisteredViewCount:
                membership.secondLargestModelRegisteredViewCount,
            unionRegisteredViewCount: membership.unionRegisteredViewCount,
            attemptCount: currentMappingAttemptCount(),
            acceptedMappingAttemptOrdinal: mappingAttemptOrdinal,
            acceptedRefinementKind: .seededBundleAdjustment,
            acceptedRefinementInvocationCount: 1,
            incrementalCadence: nil,
            canonicalModelPublication: canonicalModelPublication,
            fallbackReason: nil
        )
        return (artifact, conditioningAnalysis)
    }

    func colmapOptionsForExtraction(workerCount: Int) -> ColmapOptions {
        return ColmapOptions(
            useGPU: false,
            extractThreads: workerCount,
            matchThreads: 1,
            maxNumFeatures: 8192,
            maxNumMatches: nil,
            descriptorMatcher: .faiss,
            environment: colmapWorkerEnvironment(workerCount: workerCount)
        )
    }

    func colmapOptionsForMatching(workerCount: Int) -> ColmapOptions {
        return ColmapOptions(
            useGPU: false,
            extractThreads: workerCount,
            matchThreads: workerCount,
            maxNumFeatures: nil,
            maxNumMatches: 8192,
            descriptorMatcher: .faiss,
            environment: colmapWorkerEnvironment(workerCount: workerCount)
        )
    }

    func colmapUtilityEnvironment() -> [String: String] {
        [:]
    }

    func colmapWorkerEnvironment(workerCount: Int) -> [String: String] {
        [
            "OMP_NUM_THREADS": "\(workerCount)",
            "OPENBLAS_NUM_THREADS": "\(workerCount)",
            "MKL_NUM_THREADS": "\(workerCount)",
        ]
    }

    func runDa3MatchesImporterWithOneShotExactRecovery(
        database: URL,
        matchListPath: URL,
        pairPlan: ColmapPairPlan,
        randomSeed: UInt64,
        options: ColmapOptions,
        onLog: @escaping @Sendable (String, Bool) -> Void,
        emit: @escaping @Sendable (PipelineEvent) -> Void,
        onExactRecovery: (DescriptorMatcherRecoveryReason) throws -> Void
    ) async throws -> Da3MatchingExecution {
        guard !pairPlan.imageNames.isEmpty,
              !pairPlan.pairs.isEmpty,
              GeometryArtifactStore.isSHA256(pairPlan.sha256),
              options.descriptorMatcher == .faiss else {
            throw GeometryRecoveryState.ValidationError.invalidBackendFields
        }
        let schedule = ColmapPairSchedule(
            imageNames: pairPlan.imageNames,
            pairs: pairPlan.pairs
        )
        let clock = ContinuousClock()
        var attempts: [PairGraphAttemptEvidence] = []
        var attemptOptions = options

        func inspect(
            completion: ColmapPairAttemptCompletion
        ) throws -> ColmapPairGraphInspection {
            try ColmapDatabaseDurability.seal(at: database)
            return try ColmapPairGraphInspector(databaseURL: database).inspect(
                schedule: schedule,
                completion: completion
            )
        }

        func attemptEvidence(
            number: Int,
            matcher: DescriptorMatcher,
            outcome: PairMatchingAttemptOutcome,
            exactRecoveryReason: DescriptorMatcherRecoveryReason?,
            inspection: ColmapPairGraphInspection,
            durationSeconds: Double
        ) -> PairGraphAttemptEvidence {
            PairGraphAttemptEvidence(
                artifact: PairMatchingAttemptArtifact(
                    attemptNumber: number,
                    matcher: matcher,
                    recoveryLevel: .normal,
                    outcome: outcome,
                    exactRecoveryReason: exactRecoveryReason,
                    scheduledPairCount: pairPlan.pairs.count,
                    attemptedPairCount: inspection.attemptedPairCount,
                    rawMatchedPairCount: inspection.rawMatchedPairCount,
                    spatiallyVerifiedPairCount:
                        inspection.spatiallyVerifiedPairCount,
                    durationSeconds: durationSeconds
                ),
                scheduledPairs: pairPlan.pairs,
                retrieval: nil,
                retrievalWasExecuted: false
            )
        }

        let faissStart = clock.now
        do {
            try await tooling.colmap.runMatchesImporter(
                colmapPath: config.toolchain.colmap,
                database: database,
                matchListPath: matchListPath,
                matchType: "pairs",
                randomSeed: randomSeed,
                options: attemptOptions,
                pairContext: ColmapPairWorkerInvocationContext(
                    attemptOrdinal: 1,
                    descriptorMatcher: .faiss,
                    scheduledPairCount: pairPlan.pairs.count,
                    pairListDigest: pairPlan.sha256
                ),
                onLog: onLog
            )
            let duration = Self.durationInSeconds(clock.now - faissStart)
            let accepted = try inspect(completion: .succeeded)
            guard accepted.hasAcceptableDominantVerifiedComponent(
                allowMinorVerifiedComponents: false
            ) else {
                throw ColmapPairPlanningError.disconnectedVerifiedGraph
            }
            attempts.append(attemptEvidence(
                number: 1,
                matcher: .faiss,
                outcome: .completed,
                exactRecoveryReason: nil,
                inspection: accepted,
                durationSeconds: duration
            ))
            return Da3MatchingExecution(
                attempts: attempts,
                acceptedInspection: accepted
            )
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard let reason = DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: attemptOptions.descriptorMatcher,
                scheduledPairCount: pairPlan.pairs.count
            ) else {
                throw error
            }

            let faissDuration = Self.durationInSeconds(clock.now - faissStart)
            let failedInspection = try inspect(completion: .failed)
            attempts.append(attemptEvidence(
                number: 1,
                matcher: .faiss,
                outcome: .failed,
                exactRecoveryReason: nil,
                inspection: failedInspection,
                durationSeconds: faissDuration
            ))
            attemptOptions.descriptorMatcher = .exact
            try onExactRecovery(reason)
            try ColmapDatabaseMatchStore.clearMatchingResults(at: database)
            emit(.stageLog(
                stage: .sfmMatching,
                line: "FAISS matching failed (\(reason.rawValue)); preserving features and retrying with exact matching.",
                isError: true
            ))
            emitColmapRetryDiagnostics(error, stage: .sfmMatching, emit: emit)
            try Task.checkCancellation()
            let exactStart = clock.now
            try await tooling.colmap.runMatchesImporter(
                colmapPath: config.toolchain.colmap,
                database: database,
                matchListPath: matchListPath,
                matchType: "pairs",
                randomSeed: randomSeed,
                options: attemptOptions,
                pairContext: ColmapPairWorkerInvocationContext(
                    attemptOrdinal: 2,
                    descriptorMatcher: .exact,
                    scheduledPairCount: pairPlan.pairs.count,
                    pairListDigest: pairPlan.sha256,
                    exactRecoveryReason: reason
                ),
                onLog: onLog
            )
            let exactDuration = Self.durationInSeconds(clock.now - exactStart)
            let accepted = try inspect(completion: .succeeded)
            guard accepted.hasAcceptableDominantVerifiedComponent(
                allowMinorVerifiedComponents: false
            ) else {
                throw ColmapPairPlanningError.disconnectedVerifiedGraph
            }
            attempts.append(attemptEvidence(
                number: 2,
                matcher: .exact,
                outcome: .completed,
                exactRecoveryReason: reason,
                inspection: accepted,
                durationSeconds: exactDuration
            ))
            return Da3MatchingExecution(
                attempts: attempts,
                acceptedInspection: accepted
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
