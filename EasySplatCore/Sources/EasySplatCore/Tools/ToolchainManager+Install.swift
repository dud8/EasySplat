import Foundation

extension ToolchainManager {
    func shouldAttemptOfflineFallback(forManifestError error: Error) -> Bool {
        if let toolchainError = error as? ToolchainError {
            switch toolchainError {
            case .downloadFailed:
                return true
            default:
                return false
            }
        }
        if error is URLError {
            return true
        }
        return false
    }

    func loadBestCachedToolchain(
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest
    ) throws -> ToolchainPaths? {
        let root = try toolchainRootURL()
        guard fileManager.fileExists(atPath: root.path) else {
            return nil
        }
        try recoverInterruptedInstalls(at: root, publicKeyBase64: publicKeyBase64)

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

        for candidate in candidates {
            do {
                _ = try validateSignedReceipt(
                    root: candidate.url,
                    publicKeyBase64: publicKeyBase64,
                    request: request
                )
                let toolchain = try validateToolchain(
                    root: candidate.url,
                    requiredCapabilities: request.capabilities
                )
                return toolchain
            } catch {
                continue
            }
        }
        return nil
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
        seedFromExistingRoot: URL? = nil,
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
        var movedExistingToBackup = false

        if fileManager.fileExists(atPath: stagingRoot.path) {
            try? fileManager.removeItem(at: stagingRoot)
        }
        if fileManager.fileExists(atPath: backupRoot.path) {
            try? fileManager.removeItem(at: backupRoot)
        }

        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            if let seedFromExistingRoot {
                try copyInstallTree(from: seedFromExistingRoot, to: stagingRoot)
            }
            try await stagingInstall(stagingRoot)

            if fileManager.fileExists(atPath: versionedRoot.path) {
                _ = try fileManager.replaceItemAt(
                    versionedRoot,
                    withItemAt: stagingRoot,
                    backupItemName: backupRoot.lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
                movedExistingToBackup = fileManager.fileExists(atPath: backupRoot.path)
            } else {
                try fileManager.moveItem(at: stagingRoot, to: versionedRoot)
            }

            onProgress(-1.0, "Validating tools")
            do {
                let toolchain = try validateToolchain(
                    root: versionedRoot,
                    requiredCapabilities: requiredCapabilities
                )
                if movedExistingToBackup, fileManager.fileExists(atPath: backupRoot.path) {
                    try? fileManager.removeItem(at: backupRoot)
                }
                return toolchain
            } catch {
                if fileManager.fileExists(atPath: versionedRoot.path) {
                    try? fileManager.removeItem(at: versionedRoot)
                }
                if movedExistingToBackup,
                   fileManager.fileExists(atPath: backupRoot.path),
                   !fileManager.fileExists(atPath: versionedRoot.path) {
                    try? fileManager.moveItem(at: backupRoot, to: versionedRoot)
                }
                throw error
            }
        } catch {
            if fileManager.fileExists(atPath: stagingRoot.path) {
                try? fileManager.removeItem(at: stagingRoot)
            }
            if movedExistingToBackup,
               fileManager.fileExists(atPath: backupRoot.path),
               !fileManager.fileExists(atPath: versionedRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: versionedRoot)
            }
            throw error
        }
    }

    func copyInstallTree(from source: URL, to destination: URL) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            try fileManager.copyItem(
                at: entry,
                to: destination.appendingPathComponent(entry.lastPathComponent)
            )
        }
    }

    func recoverInterruptedInstalls(at root: URL, publicKeyBase64: String) throws {
        try validateToolchainContainerRoot(root)
        guard fileManager.fileExists(atPath: root.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var candidatesByVersion: [String: [URL]] = [:]
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  let version = interruptedInstallVersion(from: entry.lastPathComponent) else {
                continue
            }
            candidatesByVersion[version, default: []].append(entry)
        }

        for (version, candidates) in candidatesByVersion {
            let canonical = root.appendingPathComponent(version, isDirectory: true)
            let canonicalState = validRecoveryState(
                at: canonical,
                expectedVersion: version,
                publicKeyBase64: publicKeyBase64
            )
            let validCandidates = candidates.compactMap { candidate -> (URL, ToolchainInstallState, Date)? in
                guard let state = validRecoveryState(
                    at: candidate,
                    expectedVersion: version,
                    publicKeyBase64: publicKeyBase64
                ) else {
                    return nil
                }
                let modified = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (candidate, state, modified)
            }.sorted { lhs, rhs in
                if lhs.1.installedArtifacts.count != rhs.1.installedArtifacts.count {
                    return lhs.1.installedArtifacts.count > rhs.1.installedArtifacts.count
                }
                let lhsIsStaging = lhs.0.lastPathComponent.contains(".staging-")
                let rhsIsStaging = rhs.0.lastPathComponent.contains(".staging-")
                if lhsIsStaging != rhsIsStaging { return lhsIsStaging }
                return lhs.2 > rhs.2
            }
            if let canonicalState,
               validCandidates.first?.1.installedArtifacts.count ?? 0 <= canonicalState.installedArtifacts.count {
                try? saveInstallState(canonicalState, root: canonical)
                for candidate in validCandidates {
                    try? fileManager.removeItem(at: candidate.0)
                }
                continue
            }
            guard let winner = validCandidates.first else { continue }

            let discarded = root.appendingPathComponent("\(version).invalid-\(UUID().uuidString)", isDirectory: true)
            let hadCanonical = fileManager.fileExists(atPath: canonical.path)
            if hadCanonical {
                guard loadInstallState(root: canonical).signedManifest != nil else { continue }
                try fileManager.moveItem(at: canonical, to: discarded)
            }
            do {
                try fileManager.moveItem(at: winner.0, to: canonical)
                try? saveInstallState(winner.1, root: canonical)
                if hadCanonical { try? fileManager.removeItem(at: discarded) }
                for candidate in candidates where candidate != winner.0 {
                    try? fileManager.removeItem(at: candidate)
                }
            } catch {
                if hadCanonical,
                   !fileManager.fileExists(atPath: canonical.path),
                   fileManager.fileExists(atPath: discarded.path) {
                    try? fileManager.moveItem(at: discarded, to: canonical)
                }
                throw error
            }
        }
    }

    private func validRecoveryState(
        at root: URL,
        expectedVersion: String,
        publicKeyBase64: String
    ) -> ToolchainInstallState? {
        guard fileManager.fileExists(atPath: root.path),
              let state = try? validatedReusableInstallState(
                root: root,
                publicKeyBase64: publicKeyBase64,
                matching: nil
              ),
              state.signedManifest?.version == expectedVersion else {
            return nil
        }
        return state
    }

    private func interruptedInstallVersion(from name: String) -> String? {
        for marker in [".backup-", ".staging-"] {
            if let range = name.range(of: marker, options: .backwards), range.lowerBound != name.startIndex {
                let version = String(name[..<range.lowerBound])
                return semanticVersionComponents(from: version) == nil ? nil : version
            }
        }
        return nil
    }

    func versionedToolchainRoot(for version: String) throws -> URL {
        guard semanticVersionComponents(from: version) != nil else {
            throw ToolchainError.invalidManifest
        }
        let container = try toolchainRootURL().standardizedFileURL
        let candidate = container
            .appendingPathComponent(version, isDirectory: true)
            .standardizedFileURL
        guard candidate.lastPathComponent == version,
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

    private func validateVersionedToolchainRoot(_ root: URL) throws {
        let version = root.lastPathComponent
        let expected = try versionedToolchainRoot(for: version)
        guard root.standardizedFileURL.path == expected.path else {
            throw ToolchainError.invalidManifest
        }
    }

    func pruneSchema2Toolchains(
        keeping currentVersion: String,
        publicKeyBase64: String
    ) {
        guard semanticVersionComponents(from: currentVersion) != nil,
              let root = try? toolchainRootURL(),
              let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        var compatible: [(url: URL, version: SemanticVersion)] = []
        for entry in entries {
            guard entry.lastPathComponent != currentVersion,
                  !entry.lastPathComponent.contains(".staging-"),
                  !entry.lastPathComponent.contains(".backup-") else { continue }
            let state = loadInstallState(root: entry)
            guard state.schemaVersion == ToolchainManifest.currentSchemaVersion,
                  let receipt = state.signedManifest,
                  receipt.verifying(publicKeyBase64: publicKeyBase64),
                  receipt.hasMatchingKeyID(publicKeyBase64: publicKeyBase64),
                  receipt.schemaVersion == ToolchainManifest.currentSchemaVersion,
                  receipt.toolchainAPI == ToolchainManifest.currentToolchainAPI,
                  isAppVersionCompatible(with: receipt),
                  let version = semanticVersionComponents(from: receipt.version) else { continue }
            compatible.append((entry, version))
        }
        compatible.sort { compareSemanticVersions($0.version, $1.version) == .orderedDescending }
        for obsolete in compatible.dropFirst() {
            try? fileManager.removeItem(at: obsolete.url)
        }
    }
}
