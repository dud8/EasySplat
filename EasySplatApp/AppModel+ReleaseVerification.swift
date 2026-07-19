import CryptoKit
import Darwin
import EasySplatCore
import EasySplatReleaseVerifierCore
import Foundation

struct ReleaseVerificationMarkerSystemCalls {
    var synchronize: (Int32) -> Int32
    var renameExclusively: (Int32, String, String) -> Int32
    var destinationStatus: (Int32, String, UnsafeMutablePointer<stat>) -> Int32
    var removeDestination: (Int32, String) -> Int32
    var afterPublicationRename: (Int32) -> Void

    static func system() -> Self {
        Self(
            synchronize: { fsync($0) },
            renameExclusively: { directory, source, destination in
                source.withCString { sourcePointer in
                    destination.withCString { destinationPointer in
                        renameatx_np(
                            directory,
                            sourcePointer,
                            directory,
                            destinationPointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            },
            destinationStatus: { directory, name, status in
                name.withCString {
                    fstatat(directory, $0, status, AT_SYMLINK_NOFOLLOW)
                }
            },
            removeDestination: { directory, name in
                name.withCString { unlinkat(directory, $0, 0) }
            },
            afterPublicationRename: { _ in }
        )
    }
}

enum ReleaseVerificationMarkerError: Error, Equatable, LocalizedError {
    case operationFailed(operation: String, errno: Int32)
    case destinationExists
    case rollbackDestinationChanged
    case rollbackFailed(operation: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let code):
            return "Release verification could not \(operation) (POSIX error \(code))."
        case .destinationExists:
            return "Release verification did not replace an existing success marker."
        case .rollbackDestinationChanged:
            return "Release verification could not make the success marker durable, and the destination changed before rollback. The replacement was preserved."
        case .rollbackFailed(let operation, let code):
            return "Release verification could not make the success marker durable, and rollback could not \(operation) (POSIX error \(code)). The marker state is uncertain."
        }
    }
}

enum ReleaseVerificationRunError: Error, Equatable, LocalizedError {
    case invalidInput
    case invalidReleaseIdentity
    case invalidExecutable
    case executableChanged
    case inputChanged
    case pipelineFailed
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Release verification requires one ordinary video or photo folder."
        case .invalidReleaseIdentity:
            return "Release verification requires a valid run token and app version."
        case .invalidExecutable:
            return "Release verification could not authenticate its packaged executable."
        case .executableChanged:
            return "The packaged executable changed while release verification was running."
        case .inputChanged:
            return "The packaged input changed while release verification was running."
        case .pipelineFailed:
            return "Release verification did not complete the packaged app pipeline."
        case .invalidResult:
            return "Release verification did not produce a validated project and PLY."
        }
    }
}

extension AppModel {
    private struct ReleaseVerificationFileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
        }
    }

    func runBundledPipelineForReleaseVerification(
        inputManifestURL: URL,
        inputRootURL: URL,
        successMarkerURL: URL,
        verificationToken: String,
        appVersion: String,
        executableURL: URL,
        markerSystemCalls: ReleaseVerificationMarkerSystemCalls = .system()
    ) async throws {
        let normalizedAppVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppConfig.isValidReleaseVerificationToken(verificationToken),
              !normalizedAppVersion.isEmpty else {
            throw ReleaseVerificationRunError.invalidReleaseIdentity
        }
        let initialExecutableEvidence = try Self.releaseVerificationExecutableEvidence(
            at: executableURL
        )
        let initialInput: ResolvedPackagedProjectInput
        let initialInputSnapshot: FinishedProjectExpectedInputContinuitySnapshot
        do {
            initialInput = try PackagedProjectInputResolver.resolve(
                manifestURL: inputManifestURL,
                inputRoot: inputRootURL
            )
            initialInputSnapshot = try ProjectArtifactValidator.captureExpectedInputSnapshot(
                initialInput.expectedInput
            )
        } catch {
            throw ReleaseVerificationRunError.invalidInput
        }
        let canonicalInput = initialInput.boundaryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let input = Self.releaseVerificationInputSpec(initialInput.expectedInput)

        requestedRunOptions = RequestedRunOptions(detailProfile: .fast)
        guard let toolchain = await startProject(
            input: input,
            title: "Release Verification"
        ), viewState == .viewer,
              lastError == nil,
              let projectURL = currentProjectURL,
              let displayedOutputURL = outputPlyURL,
              let validatedOutputURL = try await validatedFinishedOutputURL(
                  projectURL: projectURL
              ),
              ProjectSummary.hasSameLocation(displayedOutputURL, validatedOutputURL) else {
            throw ReleaseVerificationRunError.pipelineFailed
        }

        let paths = ProjectPaths(root: projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        guard metadata.state.stage == .done,
              metadata.state.lastError == nil,
              let plan = metadata.resolvedRunPlan else {
            throw ReleaseVerificationRunError.invalidResult
        }
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: validatedOutputURL
        )
        let request = try plan.toolchainCapabilityRequest()
        try Self.requireUnchangedReleaseVerificationInput(
            manifestURL: inputManifestURL,
            inputRoot: inputRootURL,
            initialInput: initialInput,
            initialSnapshot: initialInputSnapshot
        )
        let finalExecutableEvidence: ReleaseVerificationExecutableEvidence
        do {
            finalExecutableEvidence = try Self.releaseVerificationExecutableEvidence(
                at: executableURL
            )
        } catch {
            throw ReleaseVerificationRunError.executableChanged
        }
        guard finalExecutableEvidence == initialExecutableEvidence else {
            throw ReleaseVerificationRunError.executableChanged
        }

        let evidence = PackagedProjectMarker(
            schemaVersion: 3,
            releaseVerificationTokenSHA256: SHA256.hash(data: Data(verificationToken.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            appVersion: normalizedAppVersion,
            executablePath: initialExecutableEvidence.path,
            executableBytes: initialExecutableEvidence.byteCount,
            executableSHA256: initialExecutableEvidence.sha256,
            toolchainRoot: toolchain.root.standardizedFileURL.path,
            requestedCapabilities: request.capabilities.map(\.rawValue).sorted(),
            inputPath: canonicalInput.path,
            inputManifestSHA256: SHA256.hash(data: initialInput.manifestData)
                .map { String(format: "%02x", $0) }
                .joined(),
            projectRoot: projectURL.standardizedFileURL.path,
            outputPlyPath: validatedOutputURL.standardizedFileURL.path,
            outputBytes: outputEvidence.byteCount,
            outputVertices: outputEvidence.vertexCount,
            outputFormat: outputEvidence.format,
            outputSHA256: outputEvidence.sha256
        )
        try Self.writeReleaseVerificationMarker(
            try PackagedProjectMarkerCodec.encodeCanonical(evidence),
            to: successMarkerURL,
            systemCalls: markerSystemCalls,
            validateBeforePublication: {
                do {
                    guard try Self.releaseVerificationExecutableEvidence(
                        at: executableURL
                    ) == initialExecutableEvidence else {
                        throw ReleaseVerificationRunError.executableChanged
                    }
                    try Self.requireUnchangedReleaseVerificationInput(
                        manifestURL: inputManifestURL,
                        inputRoot: inputRootURL,
                        initialInput: initialInput,
                        initialSnapshot: initialInputSnapshot
                    )
                } catch {
                    if error as? ReleaseVerificationRunError == .inputChanged {
                        throw error
                    }
                    throw ReleaseVerificationRunError.executableChanged
                }
            }
        )
    }

    private nonisolated static func releaseVerificationInputSpec(
        _ expectedInput: FinishedProjectExpectedInput
    ) -> InputSpec {
        switch expectedInput {
        case .videoFiles(let files):
            return .video(files: files.map(\.path))
        case .photoFolder(let folder):
            return .photos(folder: folder.path)
        case .mixed(let videoFiles, let photoFolder):
            return .mixed(
                videos: videoFiles.map(\.path),
                photosFolder: photoFolder.path
            )
        }
    }

    private nonisolated static func requireUnchangedReleaseVerificationInput(
        manifestURL: URL,
        inputRoot: URL,
        initialInput: ResolvedPackagedProjectInput,
        initialSnapshot: FinishedProjectExpectedInputContinuitySnapshot
    ) throws {
        do {
            let currentInput = try PackagedProjectInputResolver.resolve(
                manifestURL: manifestURL,
                inputRoot: inputRoot
            )
            let currentSnapshot = try ProjectArtifactValidator.captureExpectedInputSnapshot(
                currentInput.expectedInput
            )
            guard currentInput == initialInput,
                  currentSnapshot == initialSnapshot else {
                throw ReleaseVerificationRunError.inputChanged
            }
        } catch let error as ReleaseVerificationRunError {
            throw error
        } catch {
            throw ReleaseVerificationRunError.inputChanged
        }
    }

    struct ReleaseVerificationExecutableEvidence: Equatable {
        var path: String
        var byteCount: UInt64
        var sha256: String
        fileprivate var identity: ReleaseVerificationStableFileIdentity
    }

    fileprivate struct ReleaseVerificationStableFileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
        var mode: mode_t
        var linkCount: nlink_t
        var size: off_t
        var modifiedSeconds: time_t
        var modifiedNanoseconds: Int64
        var changedSeconds: time_t
        var changedNanoseconds: Int64

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            mode = status.st_mode
            linkCount = status.st_nlink
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    nonisolated static func releaseVerificationExecutableEvidence(
        at suppliedURL: URL,
        afterInitialDescriptorStatus: (Int32) throws -> Void = { _ in }
    ) throws -> ReleaseVerificationExecutableEvidence {
        let canonicalURL = suppliedURL.standardizedFileURL.resolvingSymlinksInPath()
        var suppliedStatus = stat()
        guard lstat(suppliedURL.path, &suppliedStatus) == 0,
              (suppliedStatus.st_mode & S_IFMT) == S_IFREG,
              suppliedStatus.st_nlink == 1,
              suppliedStatus.st_size > 0,
              suppliedStatus.st_uid == geteuid(),
              (suppliedStatus.st_mode & mode_t(S_IXUSR)) != 0,
              (suppliedStatus.st_mode & 0o7022) == 0 else {
            throw ReleaseVerificationRunError.invalidExecutable
        }
        var canonicalStatus = stat()
        guard lstat(canonicalURL.path, &canonicalStatus) == 0,
              ReleaseVerificationStableFileIdentity(canonicalStatus)
                == ReleaseVerificationStableFileIdentity(suppliedStatus) else {
            throw ReleaseVerificationRunError.invalidExecutable
        }

        let descriptor = open(
            canonicalURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ReleaseVerificationRunError.invalidExecutable
        }
        defer { close(descriptor) }

        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              ReleaseVerificationStableFileIdentity(initialStatus)
                == ReleaseVerificationStableFileIdentity(canonicalStatus) else {
            throw ReleaseVerificationRunError.invalidExecutable
        }
        try afterInitialDescriptorStatus(descriptor)
        var digest = SHA256()
        var consumed: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw ReleaseVerificationRunError.invalidExecutable
            }
            if count == 0 { break }
            digest.update(data: Data(buffer[0..<count]))
            consumed += UInt64(count)
        }

        var finalStatus = stat()
        var finalPathStatus = stat()
        let initialIdentity = ReleaseVerificationStableFileIdentity(initialStatus)
        guard fstat(descriptor, &finalStatus) == 0,
              lstat(canonicalURL.path, &finalPathStatus) == 0,
              consumed == UInt64(initialStatus.st_size),
              ReleaseVerificationStableFileIdentity(finalStatus) == initialIdentity,
              ReleaseVerificationStableFileIdentity(finalPathStatus) == initialIdentity else {
            throw ReleaseVerificationRunError.executableChanged
        }
        return ReleaseVerificationExecutableEvidence(
            path: canonicalURL.path,
            byteCount: consumed,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            identity: initialIdentity
        )
    }

    nonisolated static func writeReleaseVerificationMarker(
        _ data: Data,
        to destination: URL,
        systemCalls: ReleaseVerificationMarkerSystemCalls = .system(),
        validateBeforePublication: () throws -> Void = {}
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else {
            throw releaseVerificationWriteError("open the marker directory", errno: errno)
        }
        defer { close(directory) }

        let temporaryName = ".release-verification-marker-\(UUID().uuidString).tmp"
        let temporary = temporaryName.withCString {
            openat(
                directory,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporary >= 0 else {
            throw releaseVerificationWriteError("create the marker staging file", errno: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            close(temporary)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = write(
                    temporary,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw releaseVerificationWriteError("write the marker", errno: errno)
                }
                guard count > 0 else {
                    throw releaseVerificationWriteError("write the marker", errno: EIO)
                }
                written += count
            }
        }
        guard fchmod(temporary, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw releaseVerificationWriteError("set marker permissions", errno: errno)
        }
        try synchronizeReleaseVerificationDescriptor(
            temporary,
            operation: "sync the marker staging file",
            systemCalls: systemCalls
        )

        var stagedStatus = stat()
        var stagedPathStatus = stat()
        guard fstat(temporary, &stagedStatus) == 0,
              temporaryName.withCString({
                  fstatat(directory, $0, &stagedPathStatus, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              ReleaseVerificationStableFileIdentity(stagedStatus)
                == ReleaseVerificationStableFileIdentity(stagedPathStatus),
              (stagedStatus.st_mode & S_IFMT) == S_IFREG,
              (stagedStatus.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              stagedStatus.st_uid == geteuid(),
              stagedStatus.st_nlink == 1,
              stagedStatus.st_size == data.count else {
            throw releaseVerificationWriteError("inspect the marker staging file", errno: errno)
        }
        let stagedIdentity = ReleaseVerificationFileIdentity(stagedStatus)
        let stagedStableIdentity = ReleaseVerificationStableFileIdentity(stagedStatus)
        try validateBeforePublication()
        var validatedStagedStatus = stat()
        var validatedStagedPathStatus = stat()
        guard fstat(temporary, &validatedStagedStatus) == 0,
              temporaryName.withCString({
                  fstatat(directory, $0, &validatedStagedPathStatus, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              ReleaseVerificationStableFileIdentity(validatedStagedStatus)
                == stagedStableIdentity,
              ReleaseVerificationStableFileIdentity(validatedStagedPathStatus)
                == stagedStableIdentity else {
            throw releaseVerificationWriteError(
                "validate marker staging identity",
                errno: EIO
            )
        }

        let renameResult = temporaryName.withCString { temporaryPointer in
            destination.lastPathComponent.withCString { destinationPointer in
                renameatx_np(
                    directory,
                    temporaryPointer,
                    directory,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameResult != 0, errno == EEXIST {
            throw ReleaseVerificationMarkerError.destinationExists
        }
        guard renameResult == 0 else {
            throw releaseVerificationWriteError("publish the marker", errno: errno)
        }
        shouldRemoveTemporary = false
        do {
            systemCalls.afterPublicationRename(temporary)
            var renamedStatus = stat()
            guard fstat(temporary, &renamedStatus) == 0,
                  ReleaseVerificationRenameStableFileIdentity(renamedStatus)
                    == ReleaseVerificationRenameStableFileIdentity(validatedStagedStatus),
                  try releaseVerificationDescriptorData(
                      temporary,
                      expectedBytes: data.count
                  ) == data else {
                throw releaseVerificationWriteError(
                    "validate the marker immediately after publication",
                    errno: EIO
                )
            }
            let renamedStableIdentity = ReleaseVerificationStableFileIdentity(renamedStatus)
            var contentValidatedStatus = stat()
            guard fstat(temporary, &contentValidatedStatus) == 0,
                  ReleaseVerificationStableFileIdentity(contentValidatedStatus)
                    == renamedStableIdentity else {
                throw releaseVerificationWriteError(
                    "validate the marker immediately after publication",
                    errno: EIO
                )
            }
            try synchronizeReleaseVerificationDescriptor(
                directory,
                operation: "sync the marker directory",
                systemCalls: systemCalls
            )
            var publishedDescriptorStatus = stat()
            var publishedPathStatus = stat()
            guard fstat(temporary, &publishedDescriptorStatus) == 0,
                  destination.lastPathComponent.withCString({
                      fstatat(directory, $0, &publishedPathStatus, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  ReleaseVerificationStableFileIdentity(publishedDescriptorStatus)
                    == renamedStableIdentity,
                  ReleaseVerificationStableFileIdentity(publishedPathStatus)
                    == renamedStableIdentity else {
                throw releaseVerificationWriteError(
                    "validate the published marker identity",
                    errno: EIO
                )
            }
        } catch {
            try rollbackReleaseVerificationMarker(
                named: destination.lastPathComponent,
                expectedIdentity: stagedIdentity,
                directory: directory,
                systemCalls: systemCalls
            )
            throw error
        }
    }

    private struct ReleaseVerificationRenameStableFileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
        var owner: uid_t
        var mode: mode_t
        var linkCount: nlink_t
        var size: off_t
        var modifiedSeconds: time_t
        var modifiedNanoseconds: Int64

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            owner = status.st_uid
            mode = status.st_mode
            linkCount = status.st_nlink
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        }
    }

    private nonisolated static func releaseVerificationDescriptorData(
        _ descriptor: Int32,
        expectedBytes: Int
    ) throws -> Data {
        var result = Data(count: expectedBytes)
        try result.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var consumed = 0
            while consumed < expectedBytes {
                let count = pread(
                    descriptor,
                    base.advanced(by: consumed),
                    expectedBytes - consumed,
                    off_t(consumed)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw releaseVerificationWriteError(
                        "read the published marker",
                        errno: count < 0 ? errno : EIO
                    )
                }
                consumed += count
            }
        }
        return result
    }

    private nonisolated static func synchronizeReleaseVerificationDescriptor(
        _ descriptor: Int32,
        operation: String,
        systemCalls: ReleaseVerificationMarkerSystemCalls
    ) throws {
        while true {
            guard systemCalls.synchronize(descriptor) != 0 else { return }
            let code = errno
            if code == EINTR { continue }
            throw releaseVerificationWriteError(operation, errno: code)
        }
    }

    private nonisolated static func rollbackReleaseVerificationMarker(
        named destinationName: String,
        expectedIdentity: ReleaseVerificationFileIdentity,
        directory: Int32,
        systemCalls: ReleaseVerificationMarkerSystemCalls
    ) throws {
        let quarantineName = ".release-verification-rollback-\(UUID().uuidString).tmp"
        func synchronizeRollbackDirectory(_ operation: String) throws {
            do {
                try synchronizeReleaseVerificationDescriptor(
                    directory,
                    operation: operation,
                    systemCalls: systemCalls
                )
            } catch let ReleaseVerificationMarkerError.operationFailed(operation, code) {
                throw ReleaseVerificationMarkerError.rollbackFailed(
                    operation: operation,
                    errno: code
                )
            }
        }
        guard systemCalls.renameExclusively(directory, destinationName, quarantineName) == 0 else {
            let code = errno
            if code == ENOENT {
                try synchronizeRollbackDirectory("sync the absent marker destination")
                return
            }
            throw ReleaseVerificationMarkerError.rollbackFailed(
                operation: "quarantine the published marker",
                errno: code
            )
        }

        var quarantinedStatus = stat()
        guard systemCalls.destinationStatus(directory, quarantineName, &quarantinedStatus) == 0 else {
            throw ReleaseVerificationMarkerError.rollbackFailed(
                operation: "inspect the quarantined marker",
                errno: errno
            )
        }
        guard ReleaseVerificationFileIdentity(quarantinedStatus) == expectedIdentity else {
            guard systemCalls.renameExclusively(directory, quarantineName, destinationName) == 0 else {
                throw ReleaseVerificationMarkerError.rollbackFailed(
                    operation: "restore the changed marker destination",
                    errno: errno
                )
            }
            try synchronizeRollbackDirectory("sync the restored marker destination")
            throw ReleaseVerificationMarkerError.rollbackDestinationChanged
        }

        guard systemCalls.removeDestination(directory, quarantineName) == 0 else {
            let code = errno
            if code == ENOENT {
                try synchronizeRollbackDirectory("sync the marker removal")
                return
            }
            throw ReleaseVerificationMarkerError.rollbackFailed(
                operation: "remove the quarantined marker",
                errno: code
            )
        }
        try synchronizeRollbackDirectory("sync the marker removal")
    }

    private nonisolated static func releaseVerificationWriteError(
        _ operation: String,
        errno value: Int32
    ) -> ReleaseVerificationMarkerError {
        .operationFailed(operation: operation, errno: value)
    }
}
