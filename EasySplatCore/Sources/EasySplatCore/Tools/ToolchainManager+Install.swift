import Darwin
import Dispatch
import Foundation

extension ToolchainManager {
    private static let installProcessSemaphore = DispatchSemaphore(value: 1)

    func shouldAttemptOfflineFallback(forManifestError error: Error) -> Bool {
        if let toolchainError = error as? ToolchainError {
            switch toolchainError {
            case .downloadFailed, .manifestHTTPFailure:
                return true
            default:
                return false
            }
        }
        if let error = error as? URLError {
            return isTransient(error)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        return false
    }

    func shouldAttemptOfflineFallback(forComponentTransferError error: Error) -> Bool {
        if let toolchainError = error as? ToolchainError {
            switch toolchainError {
            case .downloadFailed, .artifactHTTPFailure:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            return isTransient(urlError)
        }
        return false
    }

    func resolveAuthenticatedOfflineToolchain(
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        bootstrap: ValidatedBootstrap?,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths? {
        onProgress(-1.0, "Trying cached tools")
        do {
            if let cached = try await loadBestCachedToolchainAsynchronously(
                publicKeyBase64: publicKeyBase64,
                request: request,
                minimumVersion: bootstrap?.manifest.version,
                minimumManifest: bootstrap?.manifest
            ) {
                onProgress(1.0, "Tools ready (offline cached)")
                return cached
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let canUseBundledCore = bootstrap.map {
                bundledCoreCanSatisfy(request, bootstrap: $0)
            } ?? false
            if !canUseBundledCore {
                throw ToolchainError.invalidToolchain(
                    "The download failed, and cached tools could not be verified. \(error.localizedDescription)"
                )
            }
        }
        if let bootstrap,
           bundledCoreCanSatisfy(request, bootstrap: bootstrap) {
            let installed = try await installBundledBootstrap(
                bootstrap,
                publicKeyBase64: publicKeyBase64,
                request: request,
                onProgress: onProgress
            )
            onProgress(1.0, "Tools ready (bundled)")
            return installed
        }
        return nil
    }

    func loadBestCachedToolchain(
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        minimumVersion: String? = nil,
        minimumManifest: ToolchainManifest? = nil,
        readOnly: Bool = false
    ) throws -> ToolchainPaths? {
        let root = try toolchainRootURL()
        guard fileManager.fileExists(atPath: root.path) else {
            return nil
        }
        if !readOnly {
            try recoverInterruptedInstalls(at: root, publicKeyBase64: publicKeyBase64)
        }

        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        struct Candidate {
            var url: URL
            var semanticVersion: SemanticVersion?
            var modifiedAt: Date
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(entries.count)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            if name.contains(".staging-") || name.contains(".backup-") { continue }
            candidates.append(
                Candidate(
                    url: entry,
                    semanticVersion: semanticVersionComponents(from: name),
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            )
        }

        candidates.sort { lhs, rhs in
            switch (lhs.semanticVersion, rhs.semanticVersion) {
            case let (.some(left), .some(right)):
                let cmp = compareSemanticVersions(left, right)
                if cmp != .orderedSame {
                    return cmp == .orderedDescending
                }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }

        let minimumSemanticVersion = (minimumVersion ?? minimumManifest?.version)
            .flatMap(semanticVersionComponents(from:))
        var firstRejectedCandidateError: Error?
        var validCandidates: [(version: SemanticVersion, toolchain: ToolchainPaths)] = []
        for candidate in candidates {
            do {
                let receipt = try validateSignedReceipt(
                    root: candidate.url,
                    publicKeyBase64: publicKeyBase64,
                    request: request
                )
                try validateVersionedToolchainRoot(
                    candidate.url,
                    expectedVersion: receipt.version
                )
                guard let receiptVersion = semanticVersionComponents(from: receipt.version) else {
                    throw ToolchainError.invalidManifest
                }
                if let minimumSemanticVersion,
                   compareSemanticVersions(receiptVersion, minimumSemanticVersion) == .orderedAscending {
                    continue
                }
                if let minimumManifest {
                    try validateImmutableVersionFloor(receipt, floor: minimumManifest)
                }
                let toolchain = try validateToolchain(
                    root: candidate.url,
                    requiredCapabilities: request.capabilities,
                    repairExecutablePermissions: !readOnly,
                    authenticatedVersion: receipt.version
                )
                validCandidates.append((receiptVersion, toolchain))
            } catch {
                if firstRejectedCandidateError == nil {
                    firstRejectedCandidateError = error
                }
                continue
            }
        }
        if let best = validCandidates.max(by: {
            compareSemanticVersions($0.version, $1.version) == .orderedAscending
        }) {
            return best.toolchain
        }
        if let firstRejectedCandidateError {
            throw firstRejectedCandidateError
        }
        return nil
    }

    func loadBestCachedToolchainAsynchronously(
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        minimumVersion: String? = nil,
        minimumManifest: ToolchainManifest? = nil
    ) async throws -> ToolchainPaths? {
        try Task.checkCancellation()
        let root = try toolchainRootURL()
        if fileManager.fileExists(atPath: root.path) {
            try await recoverInterruptedInstallsAsynchronously(
                at: root,
                publicKeyBase64: publicKeyBase64
            )
        }
        try Task.checkCancellation()
        return try loadBestCachedToolchain(
            publicKeyBase64: publicKeyBase64,
            request: request,
            minimumVersion: minimumVersion,
            minimumManifest: minimumManifest,
            readOnly: true
        )
    }

    struct SemanticVersion: Sendable, Equatable {
        enum PrereleaseIdentifier: Sendable, Equatable {
            case numeric(String)
            case text(String)
        }

        var major: String
        var minor: String
        var patch: String
        var prerelease: [PrereleaseIdentifier]
    }

    func semanticVersionComponents(from value: String) -> SemanticVersion? {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2, !buildParts[0].isEmpty else { return nil }
        if buildParts.count == 2, !validSemanticIdentifiers(buildParts[1], allowNumericLeadingZero: true) {
            return nil
        }

        let versionParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = semanticCoreNumber(core[0]),
              let minor = semanticCoreNumber(core[1]),
              let patch = semanticCoreNumber(core[2]) else {
            return nil
        }

        var prerelease: [SemanticVersion.PrereleaseIdentifier] = []
        if versionParts.count == 2 {
            let raw = versionParts[1]
            guard validSemanticIdentifiers(raw, allowNumericLeadingZero: false) else { return nil }
            prerelease = raw.split(separator: ".", omittingEmptySubsequences: false).map { identifier in
                if identifier.allSatisfy(\.isNumber) {
                    return .numeric(String(identifier))
                }
                return .text(String(identifier))
            }
        }
        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    func semanticVersionIdentity(from value: String) -> String? {
        guard semanticVersionComponents(from: value) != nil else { return nil }
        return String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    func compareSemanticVersions(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> ComparisonResult {
        for (left, right) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] {
            let comparison = compareSemanticNumericIdentifiers(left, right)
            if comparison != .orderedSame { return comparison }
        }
        if lhs.prerelease.isEmpty, rhs.prerelease.isEmpty { return .orderedSame }
        if lhs.prerelease.isEmpty { return .orderedDescending }
        if rhs.prerelease.isEmpty { return .orderedAscending }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (left, right) {
            case let (.numeric(leftValue), .numeric(rightValue)):
                let comparison = compareSemanticNumericIdentifiers(leftValue, rightValue)
                if comparison != .orderedSame { return comparison }
            case (.numeric, .text):
                return .orderedAscending
            case (.text, .numeric):
                return .orderedDescending
            case let (.text(leftValue), .text(rightValue)):
                if leftValue > rightValue { return .orderedDescending }
                if leftValue < rightValue { return .orderedAscending }
            }
        }
        if lhs.prerelease.count > rhs.prerelease.count { return .orderedDescending }
        if lhs.prerelease.count < rhs.prerelease.count { return .orderedAscending }
        return .orderedSame
    }

    private func semanticCoreNumber(_ value: Substring) -> String? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ ("0"..."9").contains(Character(String($0))) }),
              value == "0" || value.first != "0" else {
            return nil
        }
        return String(value)
    }

    private func compareSemanticNumericIdentifiers(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count > rhs.count { return .orderedDescending }
        if lhs.count < rhs.count { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        if lhs < rhs { return .orderedAscending }
        return .orderedSame
    }

    private func validSemanticIdentifiers(_ value: Substring, allowNumericLeadingZero: Bool) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      ("0"..."9").contains(Character(String(scalar)))
                          || ("A"..."Z").contains(Character(String(scalar)))
                          || ("a"..."z").contains(Character(String(scalar)))
                          || scalar == "-"
                  }) else {
                return false
            }
            if !allowNumericLeadingZero,
               identifier.allSatisfy(\.isNumber),
               identifier.count > 1,
               identifier.first == "0" {
                return false
            }
            return true
        }
    }

    func installToolchainAtomically(
        versionedRoot: URL,
        requiredCapabilities: Set<ToolchainCapability>,
        authenticatedManifest: ToolchainManifest? = nil,
        seedFromExistingRoot: URL? = nil,
        onProgress: @escaping @Sendable (Double, String) -> Void,
        installInto stagingInstall: (_ stagingRoot: URL) async throws -> Void
    ) async throws -> ToolchainPaths {
        try validateVersionedToolchainRoot(versionedRoot)
        return try await withInstallLock(for: versionedRoot) {
            try await installToolchainAtomicallyLocked(
                versionedRoot: versionedRoot,
                requiredCapabilities: requiredCapabilities,
                authenticatedManifest: authenticatedManifest,
                seedFromExistingRoot: seedFromExistingRoot,
                onProgress: onProgress,
                installInto: stagingInstall
            )
        }
    }

    func installToolchainAtomicallyLocked(
        versionedRoot: URL,
        requiredCapabilities: Set<ToolchainCapability>,
        authenticatedManifest: ToolchainManifest? = nil,
        seedFromExistingRoot: URL? = nil,
        beforeStagingPromotion: ((URL) throws -> Void)? = nil,
        onProgress: @escaping @Sendable (Double, String) -> Void,
        installInto stagingInstall: (_ stagingRoot: URL) async throws -> Void
    ) async throws -> ToolchainPaths {
        try validateVersionedToolchainRoot(versionedRoot)
        let stagingRoot = versionedRoot.deletingLastPathComponent().appendingPathComponent(
            "\(versionedRoot.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupRoot = versionedRoot.deletingLastPathComponent().appendingPathComponent(
            "\(versionedRoot.lastPathComponent).backup-\(UUID().uuidString)",
            isDirectory: true
        )
        var createdStagingIdentity: RecoveryDirectoryIdentity?

        guard !fileManager.fileExists(atPath: stagingRoot.path),
              !fileManager.fileExists(atPath: backupRoot.path) else {
            throw ToolchainError.fileIOFailed(
                "A private toolchain transaction directory already exists."
            )
        }

        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            createdStagingIdentity = try recoveryDirectoryIdentity(at: stagingRoot)
            if let seedFromExistingRoot {
                try copyInstallTree(from: seedFromExistingRoot, to: stagingRoot)
            }
            try await stagingInstall(stagingRoot)
            let candidate = try validatedStagedInstallCandidate(
                at: stagingRoot,
                expectedIdentity: versionedRoot.lastPathComponent,
                authenticatedManifest: authenticatedManifest
            )

            try beforeStagingPromotion?(stagingRoot)
            onProgress(-1.0, "Validating tools")
            return try promoteStagedInstallCandidate(
                candidate,
                to: versionedRoot,
                backup: backupRoot,
                requiredCapabilities: requiredCapabilities,
                authenticatedManifest: authenticatedManifest
            )
        } catch {
            if let createdStagingIdentity,
               let container = try? openRecoveryContainer(
                versionedRoot.deletingLastPathComponent()
               ) {
                try? removeRecoveryDirectoryIfUnchanged(
                    container,
                    name: stagingRoot.lastPathComponent,
                    identity: createdStagingIdentity
                )
                Darwin.close(container)
            }
            throw error
        }
    }

    func withInstallLock<T>(
        for versionedRoot: URL,
        operation: () async throws -> T
    ) async throws -> T {
        let lockDescriptor = try await acquireInstallLockAsynchronously(for: versionedRoot)
        defer { releaseInstallLock(lockDescriptor) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func withInstallLockSynchronously<T>(
        for versionedRoot: URL,
        operation: () throws -> T
    ) throws -> T {
        let lockDescriptor = try acquireInstallLock(for: versionedRoot)
        defer { releaseInstallLock(lockDescriptor) }
        return try operation()
    }

    private func releaseInstallLock(_ descriptor: Int32) {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
        Self.installProcessSemaphore.signal()
    }

    private func acquireInstallLockAsynchronously(for versionedRoot: URL) async throws -> Int32 {
        while !tryAcquireInstallProcessSemaphore() {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        do {
            try Task.checkCancellation()
            let descriptor = try openInstallLockDescriptor(for: versionedRoot)
            do {
                while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
                    if errno == EINTR { continue }
                    guard errno == EACCES || errno == EAGAIN else {
                        throw ToolchainError.fileIOFailed(
                            "Could not acquire the per-version install lock."
                        )
                    }
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard installLockIdentityIsSafe(
                    descriptor: descriptor,
                    path: installLockURL(for: versionedRoot).path
                ) else {
                    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
                    throw ToolchainError.fileIOFailed(
                        "The acquired per-version install lock is unsafe."
                    )
                }
                do {
                    try Task.checkCancellation()
                } catch {
                    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
                    throw error
                }
                return descriptor
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            Self.installProcessSemaphore.signal()
            throw error
        }
    }

    private func tryAcquireInstallProcessSemaphore() -> Bool {
        Self.installProcessSemaphore.wait(timeout: .now()) == .success
    }

    private func acquireInstallLock(for versionedRoot: URL) throws -> Int32 {
        Self.installProcessSemaphore.wait()
        do {
            return try acquireFileInstallLock(for: versionedRoot)
        } catch {
            Self.installProcessSemaphore.signal()
            throw error
        }
    }

    private func acquireFileInstallLock(for versionedRoot: URL) throws -> Int32 {
        let lockURL = installLockURL(for: versionedRoot)
        let descriptor = try openInstallLockDescriptor(for: versionedRoot)
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            Darwin.close(descriptor)
            throw ToolchainError.fileIOFailed("Could not acquire the per-version install lock.")
        }
        guard installLockIdentityIsSafe(descriptor: descriptor, path: lockURL.path) else {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
            throw ToolchainError.fileIOFailed("The acquired per-version install lock is unsafe.")
        }
        return descriptor
    }

    private func installLockURL(for versionedRoot: URL) -> URL {
        versionedRoot.deletingLastPathComponent()
            .appendingPathComponent(".\(versionedRoot.lastPathComponent).install.lock")
    }

    private func openInstallLockDescriptor(for versionedRoot: URL) throws -> Int32 {
        let lockURL = installLockURL(for: versionedRoot)
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ToolchainError.fileIOFailed("Could not open the per-version install lock.")
        }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(lockURL.path, &pathStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_uid == getuid(),
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              pathStatus.st_nlink == 1,
              (pathStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw ToolchainError.fileIOFailed("The per-version install lock is unsafe.")
        }
        if descriptorStatus.st_mode & 0o777 != 0o600 {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else {
                Darwin.close(descriptor)
                throw ToolchainError.fileIOFailed("Could not secure the per-version install lock.")
            }
        }
        guard installLockIdentityIsSafe(descriptor: descriptor, path: lockURL.path) else {
            Darwin.close(descriptor)
            throw ToolchainError.fileIOFailed("The secured per-version install lock is unsafe.")
        }
        return descriptor
    }

    private func installLockIdentityIsSafe(descriptor: Int32, path: String) -> Bool {
        var descriptorStatus = stat()
        var pathStatus = stat()
        return fstat(descriptor, &descriptorStatus) == 0
            && lstat(path, &pathStatus) == 0
            && (descriptorStatus.st_mode & S_IFMT) == S_IFREG
            && (pathStatus.st_mode & S_IFMT) == S_IFREG
            && descriptorStatus.st_nlink == 1
            && pathStatus.st_nlink == 1
            && descriptorStatus.st_uid == getuid()
            && pathStatus.st_uid == getuid()
            && descriptorStatus.st_mode & 0o777 == 0o600
            && pathStatus.st_mode & 0o777 == 0o600
            && descriptorStatus.st_dev == pathStatus.st_dev
            && descriptorStatus.st_ino == pathStatus.st_ino
    }

    func copyInstallTree(from source: URL, to destination: URL) throws {
        let expectedFiles = try validateInstalledTree(
            root: source,
            state: loadInstallState(root: source)
        )
        for relativePath in expectedFiles.sorted() {
            let sourceFile = source.appendingPathComponent(relativePath)
            let destinationFile = destination.appendingPathComponent(relativePath)
            let attributes = try fileManager.attributesOfItem(atPath: sourceFile.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ToolchainError.invalidToolchain(
                    "Toolchain file changed while preparing the install: \(relativePath)."
                )
            }
            if let references = attributes[.referenceCount] as? NSNumber,
               references.intValue != 1 {
                throw ToolchainError.invalidToolchain(
                    "Toolchain file became multiply linked while preparing the install: \(relativePath)."
                )
            }
            try fileManager.createDirectory(
                at: destinationFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceFile, to: destinationFile)
        }
    }

    func recoverInterruptedInstalls(
        at root: URL,
        publicKeyBase64: String,
        beforeCandidatePromotion: ((URL) throws -> Void)? = nil
    ) throws {
        try validateToolchainContainerRoot(root)
        guard fileManager.fileExists(atPath: root.path) else { return }
        let identities = try interruptedInstallIdentities(at: root)
        for identity in identities.sorted() {
            let versionedRoot = try versionedToolchainRoot(for: identity)
            try withInstallLockSynchronously(for: versionedRoot) {
                try recoverInterruptedInstallLocked(
                    at: root,
                    identity: identity,
                    publicKeyBase64: publicKeyBase64,
                    beforeCandidatePromotion: beforeCandidatePromotion
                )
            }
        }
    }

    func recoverInterruptedInstallsAsynchronously(
        at root: URL,
        publicKeyBase64: String
    ) async throws {
        try validateToolchainContainerRoot(root)
        guard fileManager.fileExists(atPath: root.path) else { return }
        let identities = try interruptedInstallIdentities(at: root)
        for identity in identities.sorted() {
            try Task.checkCancellation()
            let versionedRoot = try versionedToolchainRoot(for: identity)
            try await withInstallLock(for: versionedRoot) {
                try Task.checkCancellation()
                try recoverInterruptedInstallLocked(
                    at: root,
                    identity: identity,
                    publicKeyBase64: publicKeyBase64
                )
            }
        }
    }

    func recoverInterruptedInstallLocked(
        at root: URL,
        identity: String,
        publicKeyBase64: String,
        beforeCandidatePromotion: ((URL) throws -> Void)? = nil
    ) throws {
        let candidates = try interruptedInstallCandidates(at: root, identity: identity)
        guard !candidates.isEmpty else { return }
        let canonical = try versionedToolchainRoot(for: identity)
        let authenticatedManifests = ([canonical] + candidates).compactMap {
            authenticatedReceiptManifest(at: $0, publicKeyBase64: publicKeyBase64)
        }
        if let floor = authenticatedManifests.first {
            for manifest in authenticatedManifests.dropFirst() {
                try validateImmutableVersionFloor(manifest, floor: floor)
            }
        }

        let canonicalCandidate = try? validatedRecoveryCandidate(
            at: canonical,
            expectedIdentity: identity,
            publicKeyBase64: publicKeyBase64
        )
        let validCandidates = candidates.compactMap { candidate -> RecoveryCandidate? in
            try? validatedRecoveryCandidate(
                at: candidate,
                expectedIdentity: identity,
                publicKeyBase64: publicKeyBase64
            )
        }.sorted { lhs, rhs in
            if lhs.state.installedArtifacts.count != rhs.state.installedArtifacts.count {
                return lhs.state.installedArtifacts.count > rhs.state.installedArtifacts.count
            }
            let lhsIsStaging = lhs.url.lastPathComponent.contains(".staging-")
            let rhsIsStaging = rhs.url.lastPathComponent.contains(".staging-")
            if lhsIsStaging != rhsIsStaging { return lhsIsStaging }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        if let canonicalCandidate,
           validCandidates.first?.state.installedArtifacts.count ?? 0
           <= canonicalCandidate.state.installedArtifacts.count {
            for candidate in validCandidates {
                try? fileManager.removeItem(at: candidate.url)
            }
            return
        }
        guard let winner = validCandidates.first else { return }

        try beforeCandidatePromotion?(winner.url)
        try promoteRecoveryCandidate(
            winner,
            to: canonical,
            in: root,
            publicKeyBase64: publicKeyBase64
        )
        for candidate in candidates where candidate != winner.url {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private struct RecoveryDirectoryIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
        var linkCount: UInt64
        var owner: UInt32
        var mode: UInt16
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
    }

    private struct RecoveryFileIdentity: Equatable {
        var path: String
        var sha256: String
        var size: Int64
        var mode: UInt16
        var identity: String
    }

    private struct RecoveryCandidateAttestation: Equatable {
        var directory: RecoveryDirectoryIdentity
        var canonicalManifest: Data
        var signature: String
        var installedArtifacts: [String: String]
        var installedCapabilities: [String]
        var files: [RecoveryFileIdentity]
    }

    private struct RecoveryCandidate {
        var url: URL
        var state: ToolchainInstallState
        var modifiedAt: Date
        var attestation: RecoveryCandidateAttestation
    }

    private func validatedStagedInstallCandidate(
        at root: URL,
        expectedIdentity: String,
        authenticatedManifest: ToolchainManifest?
    ) throws -> RecoveryCandidate {
        let initialDirectory = try recoveryDirectoryIdentity(at: root)
        let state = loadInstallState(root: root)
        let receipt: ToolchainManifest?
        if let authenticatedManifest {
            guard let stagedManifest = state.signedManifest,
                  semanticVersionIdentity(from: stagedManifest.version) == expectedIdentity,
                  stagedManifest.signatureEd25519 == authenticatedManifest.signatureEd25519,
                  try stagedManifest.canonicalData() == authenticatedManifest.canonicalData() else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain receipt does not match the authenticated manifest."
                )
            }
            receipt = stagedManifest
        } else {
            receipt = state.signedManifest
        }

        let expectedFiles = try validateInstalledTree(root: root, state: state)
        if let authenticatedManifest {
            let installedNames = Set(state.installedArtifacts.keys)
            let installedComponents = authenticatedManifest.components.filter {
                installedNames.contains($0.name)
            }
            guard installedComponents.count == installedNames.count else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain receipt contains unknown components."
                )
            }
            for component in installedComponents {
                try validateExpandedClosure(component, root: root)
            }
        }
        let files = try expectedFiles.sorted().map { path in
            let evidence = try regularFileEvidence(root: root, relativePath: path)
            return RecoveryFileIdentity(
                path: path,
                sha256: evidence.sha256,
                size: evidence.size,
                mode: evidence.mode,
                identity: evidence.identity
            )
        }
        let finalDirectory = try recoveryDirectoryIdentity(at: root)
        guard finalDirectory == initialDirectory else {
            throw ToolchainError.invalidToolchain(
                "Staged toolchain changed while preparing the install."
            )
        }
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(initialDirectory.modifiedSeconds)
                + TimeInterval(initialDirectory.modifiedNanoseconds) / 1_000_000_000
        )
        return RecoveryCandidate(
            url: root,
            state: state,
            modifiedAt: modifiedAt,
            attestation: RecoveryCandidateAttestation(
                directory: initialDirectory,
                canonicalManifest: try receipt?.canonicalData() ?? Data(),
                signature: receipt?.signatureEd25519 ?? "",
                installedArtifacts: state.installedArtifacts,
                installedCapabilities: state.installedCapabilities,
                files: files
            )
        )
    }

    private func promoteStagedInstallCandidate(
        _ candidate: RecoveryCandidate,
        to canonical: URL,
        backup: URL,
        requiredCapabilities: Set<ToolchainCapability>,
        authenticatedManifest: ToolchainManifest?
    ) throws -> ToolchainPaths {
        let root = canonical.deletingLastPathComponent()
        let container = try openRecoveryContainer(root)
        defer { Darwin.close(container) }
        let candidateName = candidate.url.lastPathComponent
        let canonicalName = canonical.lastPathComponent
        let backupName = backup.lastPathComponent
        let quarantineName = "\(canonicalName).staging-promotion-\(UUID().uuidString)"
        let failedName = "\(canonicalName).invalid-promotion-\(UUID().uuidString)"
        let quarantine = root.appendingPathComponent(quarantineName, isDirectory: true)
        var candidateIsQuarantined = false
        var candidateIsCanonical = false
        var previousCanonicalIdentity: RecoveryDirectoryIdentity?

        do {
            guard try recoveryEntryIdentity(container, name: candidateName)
                == candidate.attestation.directory else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain changed while preparing the install."
                )
            }
            try renameRecoveryEntry(container, from: candidateName, to: quarantineName)
            candidateIsQuarantined = true
            try synchronizeRecoveryContainer(container)
            guard sameRecoveryDirectoryObject(
                try recoveryEntryIdentity(container, name: quarantineName),
                candidate.attestation.directory
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain changed while preparing the install."
                )
            }
            let quarantined = try validatedStagedInstallCandidate(
                at: quarantine,
                expectedIdentity: canonicalName,
                authenticatedManifest: authenticatedManifest
            )
            guard recoveryAttestationsMatchAcrossRename(
                quarantined.attestation,
                candidate.attestation
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain changed while preparing the install."
                )
            }

            if try recoveryEntryExists(container, name: canonicalName) {
                previousCanonicalIdentity = try recoveryEntryIdentity(
                    container,
                    name: canonicalName
                )
                try renameRecoveryEntry(container, from: canonicalName, to: backupName)
                try synchronizeRecoveryContainer(container)
                guard sameRecoveryDirectoryObject(
                    try recoveryEntryIdentity(container, name: backupName),
                    previousCanonicalIdentity!
                ) else {
                    throw ToolchainError.invalidToolchain(
                        "The existing toolchain changed while preparing its replacement."
                    )
                }
            }

            try renameRecoveryEntry(container, from: quarantineName, to: canonicalName)
            candidateIsQuarantined = false
            candidateIsCanonical = true
            try synchronizeRecoveryContainer(container)
            guard sameRecoveryDirectoryObject(
                try recoveryEntryIdentity(container, name: canonicalName),
                candidate.attestation.directory
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain changed while preparing the install."
                )
            }
            let promoted = try validatedStagedInstallCandidate(
                at: canonical,
                expectedIdentity: canonicalName,
                authenticatedManifest: authenticatedManifest
            )
            guard recoveryAttestationsMatchAcrossRename(
                promoted.attestation,
                candidate.attestation
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Staged toolchain changed while preparing the install."
                )
            }
            let toolchain = try validateToolchain(
                root: canonical,
                requiredCapabilities: requiredCapabilities,
                repairExecutablePermissions: authenticatedManifest == nil,
                authenticatedVersion: authenticatedManifest?.version
            )
            if authenticatedManifest != nil {
                let finallyAttested = try validatedStagedInstallCandidate(
                    at: canonical,
                    expectedIdentity: canonicalName,
                    authenticatedManifest: authenticatedManifest
                )
                guard recoveryAttestationsMatchAcrossRename(
                    finallyAttested.attestation,
                    candidate.attestation
                ) else {
                    throw ToolchainError.invalidToolchain(
                        "Staged toolchain changed during final validation."
                    )
                }
            }

            if let previousCanonicalIdentity,
               let currentBackup = try? recoveryEntryIdentity(container, name: backupName),
               sameRecoveryDirectoryObject(currentBackup, previousCanonicalIdentity) {
                try? removeRecoveryDirectoryIfUnchanged(
                    container,
                    name: backupName,
                    identity: previousCanonicalIdentity
                )
            }
            return toolchain
        } catch {
            if candidateIsCanonical,
               let current = try? recoveryEntryIdentity(container, name: canonicalName),
               sameRecoveryDirectoryObject(current, candidate.attestation.directory) {
                let rollbackName = previousCanonicalIdentity == nil ? candidateName : failedName
                try? renameRecoveryEntry(container, from: canonicalName, to: rollbackName)
                candidateIsCanonical = false
                try? synchronizeRecoveryContainer(container)
            }
            if let previousCanonicalIdentity,
               !(try recoveryEntryExists(container, name: canonicalName)),
               let currentBackup = try? recoveryEntryIdentity(container, name: backupName),
               sameRecoveryDirectoryObject(currentBackup, previousCanonicalIdentity) {
                try? renameRecoveryEntry(container, from: backupName, to: canonicalName)
                try? synchronizeRecoveryContainer(container)
            }
            if candidateIsQuarantined,
               !(try recoveryEntryExists(container, name: candidateName)),
               let current = try? recoveryEntryIdentity(container, name: quarantineName),
               sameRecoveryDirectoryObject(current, candidate.attestation.directory) {
                try? renameRecoveryEntry(container, from: quarantineName, to: candidateName)
                try? synchronizeRecoveryContainer(container)
            }
            let failed = root.appendingPathComponent(failedName, isDirectory: true)
            if let failedCandidate = try? validatedStagedInstallCandidate(
                at: failed,
                expectedIdentity: canonicalName,
                authenticatedManifest: authenticatedManifest
            ), recoveryAttestationsMatchAcrossRename(
                failedCandidate.attestation,
                candidate.attestation
            ) {
                try? removeRecoveryDirectoryIfUnchanged(
                    container,
                    name: failedName,
                    identity: failedCandidate.attestation.directory
                )
            }
            throw error
        }
    }

    private func validatedRecoveryCandidate(
        at root: URL,
        expectedIdentity: String,
        publicKeyBase64: String
    ) throws -> RecoveryCandidate {
        let initialDirectory = try recoveryDirectoryIdentity(at: root)
        let state = try validatedReusableInstallState(
            root: root,
            publicKeyBase64: publicKeyBase64,
            matching: nil
        )
        guard let receipt = state.signedManifest,
              semanticVersionIdentity(from: receipt.version) == expectedIdentity else {
            throw ToolchainError.invalidToolchain(
                "Interrupted toolchain receipt does not match its semantic version."
            )
        }
        let expectedFiles = try validateInstalledTree(root: root, state: state)
        let files = try expectedFiles.sorted().map { path in
            let evidence = try regularFileEvidence(root: root, relativePath: path)
            return RecoveryFileIdentity(
                path: path,
                sha256: evidence.sha256,
                size: evidence.size,
                mode: evidence.mode,
                identity: evidence.identity
            )
        }
        let finalDirectory = try recoveryDirectoryIdentity(at: root)
        guard finalDirectory == initialDirectory else {
            throw ToolchainError.invalidToolchain(
                "Interrupted toolchain changed while recovery was in progress."
            )
        }
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(initialDirectory.modifiedSeconds)
                + TimeInterval(initialDirectory.modifiedNanoseconds) / 1_000_000_000
        )
        return RecoveryCandidate(
            url: root,
            state: state,
            modifiedAt: modifiedAt,
            attestation: RecoveryCandidateAttestation(
                directory: initialDirectory,
                canonicalManifest: try receipt.canonicalData(),
                signature: receipt.signatureEd25519,
                installedArtifacts: state.installedArtifacts,
                installedCapabilities: state.installedCapabilities,
                files: files
            )
        )
    }

    private func promoteRecoveryCandidate(
        _ candidate: RecoveryCandidate,
        to canonical: URL,
        in root: URL,
        publicKeyBase64: String
    ) throws {
        let container = try openRecoveryContainer(root)
        defer { Darwin.close(container) }
        let candidateName = candidate.url.lastPathComponent
        let canonicalName = canonical.lastPathComponent
        let quarantineName = "\(canonicalName).staging-recovery-\(UUID().uuidString)"
        let discardedName = "\(canonicalName).backup-recovery-\(UUID().uuidString)"
        let failedName = "\(canonicalName).invalid-\(UUID().uuidString)"
        let quarantine = root.appendingPathComponent(quarantineName, isDirectory: true)
        let discarded = root.appendingPathComponent(discardedName, isDirectory: true)
        let failed = root.appendingPathComponent(failedName, isDirectory: true)
        var candidateIsQuarantined = false
        var previousCanonicalIsDiscarded = false
        var candidateIsCanonical = false

        do {
            guard try recoveryEntryIdentity(container, name: candidateName)
                == candidate.attestation.directory else {
                throw ToolchainError.invalidToolchain(
                    "Interrupted toolchain changed while recovery was in progress."
                )
            }
            try renameRecoveryEntry(container, from: candidateName, to: quarantineName)
            candidateIsQuarantined = true
            try synchronizeRecoveryContainer(container)
            guard sameRecoveryDirectoryObject(
                try recoveryEntryIdentity(container, name: quarantineName),
                candidate.attestation.directory
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Interrupted toolchain changed while recovery was in progress."
                )
            }
            let revalidated = try validatedRecoveryCandidate(
                at: quarantine,
                expectedIdentity: canonicalName,
                publicKeyBase64: publicKeyBase64
            )
            guard recoveryAttestationsMatchAcrossRename(
                revalidated.attestation,
                candidate.attestation
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Interrupted toolchain changed while recovery was in progress."
                )
            }

            if try recoveryEntryExists(container, name: canonicalName) {
                try renameRecoveryEntry(container, from: canonicalName, to: discardedName)
                previousCanonicalIsDiscarded = true
                try synchronizeRecoveryContainer(container)
            }
            try renameRecoveryEntry(container, from: quarantineName, to: canonicalName)
            candidateIsQuarantined = false
            candidateIsCanonical = true
            try synchronizeRecoveryContainer(container)
            guard sameRecoveryDirectoryObject(
                try recoveryEntryIdentity(container, name: canonicalName),
                candidate.attestation.directory
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Interrupted toolchain changed while recovery was in progress."
                )
            }
            let promoted = try validatedRecoveryCandidate(
                at: canonical,
                expectedIdentity: canonicalName,
                publicKeyBase64: publicKeyBase64
            )
            guard recoveryAttestationsMatchAcrossRename(
                promoted.attestation,
                candidate.attestation
            ) else {
                throw ToolchainError.invalidToolchain(
                    "Interrupted toolchain changed while recovery was in progress."
                )
            }
            if previousCanonicalIsDiscarded {
                try? fileManager.removeItem(at: discarded)
            }
        } catch {
            if candidateIsCanonical {
                if !(try recoveryEntryExists(container, name: candidateName)) {
                    try? renameRecoveryEntry(container, from: canonicalName, to: candidateName)
                } else {
                    try? renameRecoveryEntry(container, from: canonicalName, to: failedName)
                    try? fileManager.removeItem(at: failed)
                }
            }
            if previousCanonicalIsDiscarded,
               !(try recoveryEntryExists(container, name: canonicalName)),
               try recoveryEntryExists(container, name: discardedName) {
                try? renameRecoveryEntry(container, from: discardedName, to: canonicalName)
            }
            if candidateIsQuarantined,
               !(try recoveryEntryExists(container, name: candidateName)) {
                try? renameRecoveryEntry(container, from: quarantineName, to: candidateName)
            }
            throw error
        }
    }

    private func interruptedInstallIdentities(at root: URL) throws -> Set<String> {
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return Set(entries.compactMap { entry in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return interruptedInstallVersion(from: entry.lastPathComponent)
        })
    }

    private func sameRecoveryDirectoryObject(
        _ lhs: RecoveryDirectoryIdentity,
        _ rhs: RecoveryDirectoryIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.linkCount == rhs.linkCount
            && lhs.owner == rhs.owner
            && lhs.mode == rhs.mode
    }

    private func sameRecoveryDirectoryIdentity(
        _ lhs: RecoveryDirectoryIdentity,
        _ rhs: RecoveryDirectoryIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.owner == rhs.owner
    }

    private func recoveryAttestationsMatchAcrossRename(
        _ lhs: RecoveryCandidateAttestation,
        _ rhs: RecoveryCandidateAttestation
    ) -> Bool {
        guard sameRecoveryDirectoryObject(lhs.directory, rhs.directory) else { return false }
        var normalized = lhs
        normalized.directory = rhs.directory
        return normalized == rhs
    }

    private func interruptedInstallCandidates(
        at root: URL,
        identity: String
    ) throws -> [URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries.filter { entry in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
                && interruptedInstallVersion(from: entry.lastPathComponent) == identity
        }
    }

    private func recoveryDirectoryIdentity(at url: URL) throws -> RecoveryDirectoryIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid() else {
            throw ToolchainError.invalidToolchain(
                "Interrupted toolchain directory could not be opened safely."
            )
        }
        return recoveryDirectoryIdentity(status)
    }

    private func recoveryDirectoryIdentity(_ status: stat) -> RecoveryDirectoryIdentity {
        RecoveryDirectoryIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            linkCount: UInt64(status.st_nlink),
            owner: UInt32(status.st_uid),
            mode: UInt16(status.st_mode & 0o7777),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private func openRecoveryContainer(_ root: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ToolchainError.fileIOFailed("Could not open the toolchain recovery directory.")
        }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(root.path, &pathStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              descriptorStatus.st_uid == getuid(),
              pathStatus.st_uid == getuid(),
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            Darwin.close(descriptor)
            throw ToolchainError.fileIOFailed("The toolchain recovery directory is unsafe.")
        }
        return descriptor
    }

    private func recoveryEntryIdentity(
        _ container: Int32,
        name: String
    ) throws -> RecoveryDirectoryIdentity {
        guard recoveryEntryNameIsSafe(name) else {
            throw ToolchainError.invalidManifest
        }
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(container, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid() else {
            throw ToolchainError.invalidToolchain(
                "Interrupted toolchain directory changed while recovery was in progress."
            )
        }
        return recoveryDirectoryIdentity(status)
    }

    private func recoveryEntryExists(_ container: Int32, name: String) throws -> Bool {
        guard recoveryEntryNameIsSafe(name) else {
            throw ToolchainError.invalidManifest
        }
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(container, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw ToolchainError.fileIOFailed(
            "Could not inspect the toolchain recovery directory (errno \(errno))."
        )
    }

    private func removeRecoveryDirectoryIfUnchanged(
        _ container: Int32,
        name: String,
        identity: RecoveryDirectoryIdentity
    ) throws {
        guard sameRecoveryDirectoryIdentity(
            try recoveryEntryIdentity(container, name: name),
            identity
        ) else {
            throw ToolchainError.invalidToolchain(
                "The discarded toolchain transaction was replaced before cleanup."
            )
        }
        let directory = name.withCString {
            Darwin.openat(
                container,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directory >= 0 else {
            throw ToolchainError.fileIOFailed(
                "Could not open the discarded toolchain transaction safely."
            )
        }
        defer { Darwin.close(directory) }
        var openedStatus = stat()
        guard fstat(directory, &openedStatus) == 0,
              sameRecoveryDirectoryIdentity(
                recoveryDirectoryIdentity(openedStatus),
                identity
              ) else {
            throw ToolchainError.invalidToolchain(
                "The discarded toolchain transaction changed before cleanup."
            )
        }

        try removeRecoveryDirectoryContents(directory)
        guard sameRecoveryDirectoryIdentity(
            try recoveryEntryIdentity(container, name: name),
            identity
        ) else {
            throw ToolchainError.invalidToolchain(
                "The discarded toolchain transaction changed during cleanup."
            )
        }
        let removal = name.withCString {
            Darwin.unlinkat(container, $0, AT_REMOVEDIR)
        }
        guard removal == 0 else {
            throw ToolchainError.fileIOFailed(
                "Could not remove the discarded toolchain transaction (errno \(errno))."
            )
        }
        try synchronizeRecoveryContainer(container)
    }

    private func removeRecoveryDirectoryContents(_ directory: Int32) throws {
        for name in try recoveryDirectoryEntryNames(directory) {
            var namedStatus = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(directory, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }
            if statusResult != 0, errno == ENOENT { continue }
            guard statusResult == 0 else {
                throw ToolchainError.fileIOFailed(
                    "Could not inspect a discarded toolchain transaction entry."
                )
            }

            if (namedStatus.st_mode & S_IFMT) == S_IFDIR {
                let child = name.withCString {
                    Darwin.openat(
                        directory,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw ToolchainError.fileIOFailed(
                        "Could not open a discarded toolchain transaction directory safely."
                    )
                }
                do {
                    var childStatus = stat()
                    guard fstat(child, &childStatus) == 0,
                          childStatus.st_dev == namedStatus.st_dev,
                          childStatus.st_ino == namedStatus.st_ino,
                          childStatus.st_uid == getuid() else {
                        throw ToolchainError.invalidToolchain(
                            "A discarded toolchain transaction directory changed during cleanup."
                        )
                    }
                    try removeRecoveryDirectoryContents(child)
                    var finalStatus = stat()
                    let finalResult = name.withCString {
                        Darwin.fstatat(directory, $0, &finalStatus, AT_SYMLINK_NOFOLLOW)
                    }
                    guard finalResult == 0,
                          finalStatus.st_dev == childStatus.st_dev,
                          finalStatus.st_ino == childStatus.st_ino else {
                        throw ToolchainError.invalidToolchain(
                            "A discarded toolchain transaction directory changed during cleanup."
                        )
                    }
                    let removal = name.withCString {
                        Darwin.unlinkat(directory, $0, AT_REMOVEDIR)
                    }
                    guard removal == 0 else {
                        throw ToolchainError.fileIOFailed(
                            "Could not remove a discarded toolchain transaction directory."
                        )
                    }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            } else {
                let removal = name.withCString {
                    Darwin.unlinkat(directory, $0, 0)
                }
                if removal != 0, errno != ENOENT {
                    throw ToolchainError.fileIOFailed(
                        "Could not remove a discarded toolchain transaction entry."
                    )
                }
            }
        }
        while Darwin.fsync(directory) != 0 {
            if errno == EINTR { continue }
            throw ToolchainError.fileIOFailed(
                "Could not sync the discarded toolchain transaction."
            )
        }
    }

    private func recoveryDirectoryEntryNames(_ directory: Int32) throws -> [String] {
        let duplicate = Darwin.dup(directory)
        guard duplicate >= 0 else {
            throw ToolchainError.fileIOFailed(
                "Could not inspect the discarded toolchain transaction."
            )
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ToolchainError.fileIOFailed(
                "Could not inspect the discarded toolchain transaction."
            )
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard recoveryEntryNameIsSafe(name) else {
                throw ToolchainError.invalidToolchain(
                    "A discarded toolchain transaction contains an unsafe entry name."
                )
            }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else {
            throw ToolchainError.fileIOFailed(
                "Could not finish inspecting the discarded toolchain transaction."
            )
        }
        return names
    }

    private func renameRecoveryEntry(
        _ container: Int32,
        from source: String,
        to destination: String
    ) throws {
        guard recoveryEntryNameIsSafe(source), recoveryEntryNameIsSafe(destination) else {
            throw ToolchainError.invalidManifest
        }
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.renameat(container, sourcePointer, container, destinationPointer)
            }
        }
        guard result == 0 else {
            throw ToolchainError.fileIOFailed(
                "Could not promote the recovered toolchain (errno \(errno))."
            )
        }
    }

    private func synchronizeRecoveryContainer(_ container: Int32) throws {
        while Darwin.fsync(container) != 0 {
            if errno == EINTR { continue }
            throw ToolchainError.fileIOFailed(
                "Could not sync the recovered toolchain directory (errno \(errno))."
            )
        }
    }

    private func recoveryEntryNameIsSafe(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func authenticatedReceiptManifest(
        at root: URL,
        publicKeyBase64: String
    ) -> ToolchainManifest? {
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              rootStatus.st_uid == getuid(),
              let data = try? BoundedFileReader.readRegularFile(
                at: installStateURL(root: root),
                maximumBytes: ToolchainManifest.maximumInstallStateEnvelopeBytes
              ),
              let state = try? JSONDecoder().decode(ToolchainInstallState.self, from: data),
              state.schemaVersion == ToolchainManifest.currentSchemaVersion,
              let manifest = state.signedManifest,
              manifest.schemaVersion == ToolchainManifest.currentSchemaVersion,
              manifest.toolchainAPI == ToolchainManifest.currentToolchainAPI,
              manifest.hasMatchingKeyID(publicKeyBase64: publicKeyBase64),
              semanticVersionComponents(from: manifest.version) != nil,
              manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            return nil
        }
        return manifest
    }

    func validateAuthenticatedPublicationIdentity(
        _ manifest: ToolchainManifest,
        in root: URL,
        publicKeyBase64: String
    ) throws {
        guard let identity = semanticVersionIdentity(from: manifest.version) else {
            throw ToolchainError.invalidManifest
        }
        try validateToolchainContainerRoot(root)
        guard fileManager.fileExists(atPath: root.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            let entryIdentity = semanticVersionIdentity(from: name)
                ?? interruptedInstallVersion(from: name)
            guard entryIdentity == identity,
                  let authenticated = authenticatedReceiptManifest(
                    at: entry,
                    publicKeyBase64: publicKeyBase64
                  ) else {
                continue
            }
            try validateImmutableVersionFloor(manifest, floor: authenticated)
        }
    }

    private func interruptedInstallVersion(from name: String) -> String? {
        for marker in [".backup-", ".staging-"] {
            if let range = name.range(of: marker, options: .backwards), range.lowerBound != name.startIndex {
                let version = String(name[..<range.lowerBound])
                return semanticVersionIdentity(from: version)
            }
        }
        return nil
    }

    func versionedToolchainRoot(for version: String) throws -> URL {
        guard let identity = semanticVersionIdentity(from: version) else {
            throw ToolchainError.invalidManifest
        }
        let container = try toolchainRootURL().standardizedFileURL
        let candidate = container
            .appendingPathComponent(identity, isDirectory: true)
            .standardizedFileURL
        guard candidate.lastPathComponent == identity,
              candidate.deletingLastPathComponent().standardizedFileURL.path == container.path else {
            throw ToolchainError.invalidManifest
        }
        return candidate
    }

    private func validateToolchainContainerRoot(_ root: URL) throws {
        let expected = try toolchainRootURL().standardizedFileURL
        guard root.standardizedFileURL.path == expected.path else {
            throw ToolchainError.invalidManifest
        }
    }

    func validateVersionedToolchainRoot(_ root: URL) throws {
        let version = root.lastPathComponent
        let expected = try versionedToolchainRoot(for: version)
        guard root.standardizedFileURL.path == expected.path else {
            throw ToolchainError.invalidManifest
        }
    }

    func validateVersionedToolchainRoot(
        _ root: URL,
        expectedVersion: String
    ) throws {
        let expected = try versionedToolchainRoot(for: expectedVersion)
        guard root.standardizedFileURL.path == expected.path else {
            throw ToolchainError.invalidToolchain(
                "Authenticated toolchain root does not match signed version \(expectedVersion)."
            )
        }
    }

    func pruneSchema2Toolchains(
        keeping currentVersion: String,
        publicKeyBase64: String
    ) {
        guard let currentIdentity = semanticVersionIdentity(from: currentVersion),
              let root = try? toolchainRootURL(),
              let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        var compatible: [(url: URL, version: SemanticVersion)] = []
        for entry in entries {
            guard semanticVersionIdentity(from: entry.lastPathComponent) != currentIdentity,
                  !entry.lastPathComponent.contains(".staging-"),
                  !entry.lastPathComponent.contains(".backup-") else { continue }
            do {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                let state = try validatedReusableInstallState(
                    root: entry,
                    publicKeyBase64: publicKeyBase64,
                    matching: nil
                )
                guard let receipt = state.signedManifest,
                      let version = semanticVersionComponents(from: receipt.version) else {
                    continue
                }
                try validateVersionedToolchainRoot(entry, expectedVersion: receipt.version)
                compatible.append((entry, version))
            } catch {
                continue
            }
        }
        compatible.sort { compareSemanticVersions($0.version, $1.version) == .orderedDescending }
        for obsolete in compatible.dropFirst() {
            try? fileManager.removeItem(at: obsolete.url)
        }
    }
}
