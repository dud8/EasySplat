import Foundation

extension ToolchainManager {
    func shouldAttemptOfflineFallback(forManifestError error: Error) -> Bool {
        if let toolchainError = error as? ToolchainError {
            switch toolchainError {
            case .downloadFailed, .invalidManifest:
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

    func loadBestCachedToolchain() throws -> ToolchainPaths? {
        let root = try toolchainRootURL()
        guard fileManager.fileExists(atPath: root.path) else {
            return nil
        }

        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        struct Candidate {
            var url: URL
            var semanticVersion: [Int]?
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
            if let toolchain = try? validateToolchain(root: candidate.url) {
                return toolchain
            }
        }
        return nil
    }

    func semanticVersionComponents(from value: String) -> [Int]? {
        let core = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(value)
        let withoutPrerelease = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? core
        let parts = withoutPrerelease.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var numbers: [Int] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, let number = Int(part), number >= 0 else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }

    func compareSemanticVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }

    func installToolchainAtomically(
        versionedRoot: URL,
        onProgress: @escaping @Sendable (Double, String) -> Void,
        installInto stagingInstall: (_ stagingRoot: URL) async throws -> Void
    ) async throws -> ToolchainPaths {
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
            try await stagingInstall(stagingRoot)

            if fileManager.fileExists(atPath: versionedRoot.path) {
                try fileManager.moveItem(at: versionedRoot, to: backupRoot)
                movedExistingToBackup = true
            }

            do {
                try fileManager.moveItem(at: stagingRoot, to: versionedRoot)
            } catch {
                if movedExistingToBackup,
                   !fileManager.fileExists(atPath: versionedRoot.path),
                   fileManager.fileExists(atPath: backupRoot.path) {
                    try? fileManager.moveItem(at: backupRoot, to: versionedRoot)
                }
                throw error
            }

            onProgress(-1.0, "Validating tools")
            do {
                let toolchain = try validateToolchain(root: versionedRoot)
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
}
