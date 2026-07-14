import Foundation

/// Canonical on-disk layout for a single EasySplat project bundle.
public struct ProjectPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var metadataURL: URL { root.appendingPathComponent("project.json") }
    /// Sidecar file holding the user's last-opened timestamp. Lives outside
    /// project.json so the home-list stamp cannot clobber concurrent pipeline
    /// metadata writes. Format is a small ISO-8601 JSON envelope.
    public var lastOpenedSidecarURL: URL { root.appendingPathComponent("last_opened.json") }
    public var originalsURL: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    public var importedPhotosURL: URL { originalsURL.appendingPathComponent("Photos", isDirectory: true) }
    public var framesRawURL: URL { root.appendingPathComponent("Frames/raw", isDirectory: true) }
    public var framesRawManifestURL: URL { root.appendingPathComponent("Frames/raw_manifest.json") }
    public var framesSelectedURL: URL { root.appendingPathComponent("Frames/selected", isDirectory: true) }
    public var framesSelectedManifestURL: URL { root.appendingPathComponent("Frames/selected_manifest.json") }
    public var colmapDatabaseURL: URL { root.appendingPathComponent("SfM/colmap/database.db") }
    public var colmapFeatureEvidenceURL: URL {
        root.appendingPathComponent("SfM/colmap/feature_evidence.json")
    }
    public var colmapSeedURL: URL { root.appendingPathComponent("SfM/colmap/seed", isDirectory: true) }
    public var colmapSeedModelURL: URL { colmapSeedURL.appendingPathComponent("0", isDirectory: true) }
    public var colmapSparseURL: URL { root.appendingPathComponent("SfM/colmap/sparse", isDirectory: true) }
    public var pairGraphEvidenceURL: URL { root.appendingPathComponent("SfM/pair_graph_evidence.json") }
    public var geometryManifestURL: URL { root.appendingPathComponent("SfM/geometry_manifest.json") }
    public var trainingURL: URL { root.appendingPathComponent("Training", isDirectory: true) }
    public var trainingManifestURL: URL { trainingURL.appendingPathComponent("training_manifest.json") }
    public var msplatCheckpointURL: URL {
        trainingURL.appendingPathComponent("checkpoints/msplat", isDirectory: true)
    }
    public var msplatOutputURL: URL { trainingURL.appendingPathComponent("msplat/splat.ply") }
    public var outputURL: URL { root.appendingPathComponent("Output", isDirectory: true) }
    public var logsURL: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var pipelineLogURL: URL { logsURL.appendingPathComponent("pipeline.log") }
    public var eventsLogURL: URL { logsURL.appendingPathComponent("events.jsonl") }
    public var colmapLogURL: URL { logsURL.appendingPathComponent("colmap.log") }
    public var globalMapperLogURL: URL { logsURL.appendingPathComponent("global_mapper.log") }
    public var da3LogURL: URL { logsURL.appendingPathComponent("da3.log") }
    public var da3CoverageManifestURL: URL { logsURL.appendingPathComponent("da3_coverage_manifest.json") }
    public var msplatLogURL: URL { logsURL.appendingPathComponent("msplat.log") }

    public func ensureDirectories() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try validateRootDirectory()
        for relativePath in [
            "Originals",
            "Frames/raw",
            "Frames/selected",
            "SfM/colmap/seed",
            "SfM/colmap/sparse",
            "Output",
            "Logs",
        ] {
            try ensurePlainDirectory(relativePath)
        }
        try ensureMutableTrainingDirectories()
    }

    /// Revalidates each directory that the native trainer can mutate. Call this again
    /// immediately before launch so an interrupted or copied project cannot redirect
    /// dataset, checkpoint, or output writes through an in-bundle symlink.
    func ensureMutableTrainingDirectories() throws {
        try validateRootDirectory()
        for relativePath in [
            "Training",
            "Training/checkpoints",
            "Training/checkpoints/msplat",
            "Training/msplat",
            "Training/msplat_dataset",
            "Training/msplat_dataset/images",
            "Training/msplat_dataset/sparse",
            "Training/msplat_dataset/sparse/0",
        ] {
            try ensurePlainDirectory(relativePath)
        }
    }

    public func validateRootDirectory() throws {
        try requirePlainDirectory(root, relativePath: ".")
    }

    public func resolveProjectRelativePath(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectPathError.emptyPath
        }
        guard !(trimmed as NSString).isAbsolutePath else {
            throw ProjectPathError.absolutePath(trimmed)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectPathError.unsafeComponent(trimmed)
        }

        let standardizedRoot = root.standardizedFileURL
        let resolved = components.reduce(standardizedRoot) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
        let rootPath = standardizedRoot.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw ProjectPathError.escapesProjectRoot(trimmed)
        }

        // Foundation can use different spellings for the same temporary-volume path
        // (`/var` and `/private/var`). Canonicalizing a path whose final component does
        // not exist is not stable across those spellings, so prove containment through
        // the longest existing ancestor instead. Once a component is missing, no deeper
        // component can be a symlink yet and the lexical checks above are sufficient.
        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath()
        var existingAncestor = standardizedRoot
        for (index, component) in components.enumerated() {
            let candidate = existingAncestor.appendingPathComponent(component)
            do {
                let values = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw ProjectPathError.escapesProjectRoot(trimmed)
                }
                if index < components.count - 1, values.isDirectory != true {
                    throw ProjectPathError.unsafeDirectory(trimmed)
                }
                existingAncestor = candidate
            } catch let error as ProjectPathError {
                throw error
            } catch {
                // A dangling symlink is not reported as an existing filesystem item.
                // Reject it rather than treating its target as a safe future path.
                if (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: candidate.path
                )) != nil {
                    throw ProjectPathError.escapesProjectRoot(trimmed)
                }
                break
            }
        }
        let canonicalResolved = existingAncestor.resolvingSymlinksInPath()
        let canonicalRootPath = canonicalRoot.path
        guard canonicalResolved.path == canonicalRootPath || canonicalResolved.path.hasPrefix(canonicalRootPath + "/") else {
            throw ProjectPathError.escapesProjectRoot(trimmed)
        }
        return resolved
    }

    public func projectRelativePath(for url: URL) throws -> String {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let rootPrefix = standardizedRoot.path + "/"
        let relativePath: String
        if standardizedURL.path.hasPrefix(rootPrefix) {
            relativePath = String(standardizedURL.path.dropFirst(rootPrefix.count))
        } else {
            // File APIs may return the alternate `/var` spelling
            // and then be opened through `/private/var` (or vice versa). Derive the path
            // from canonical existing URLs before rejecting a genuinely external file.
            let canonicalRoot = standardizedRoot.resolvingSymlinksInPath()
            let canonicalURL = standardizedURL.resolvingSymlinksInPath()
            let canonicalPrefix = canonicalRoot.path + "/"
            guard canonicalURL.path.hasPrefix(canonicalPrefix) else {
                throw ProjectPathError.escapesProjectRoot(url.path)
            }
            relativePath = String(canonicalURL.path.dropFirst(canonicalPrefix.count))
        }
        _ = try resolveProjectRelativePath(relativePath)
        return relativePath
    }

    private func ensurePlainDirectory(_ relativePath: String) throws {
        var current = root
        for component in relativePath.split(separator: "/").map(String.init) {
            current.appendPathComponent(component, isDirectory: true)
            let fileManager = FileManager.default
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil
            if fileManager.fileExists(atPath: current.path) || isSymlink {
                try requirePlainDirectory(current, relativePath: relativePath)
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        _ = try resolveProjectRelativePath(relativePath)
    }

    private func requirePlainDirectory(_ url: URL, relativePath: String) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProjectPathError.unsafeDirectory(relativePath)
        }
    }
}

public enum ProjectPathError: Error, LocalizedError, Equatable {
    case emptyPath
    case absolutePath(String)
    case unsafeComponent(String)
    case escapesProjectRoot(String)
    case unsafeDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Project-relative path is empty"
        case .absolutePath(let path):
            return "Project-relative path must not be absolute: \(path)"
        case .unsafeComponent(let path):
            return "Project-relative path contains an unsafe component: \(path)"
        case .escapesProjectRoot(let path):
            return "Project-relative path escapes the project root: \(path)"
        case .unsafeDirectory(let path):
            return "Project directory is not a plain in-bundle directory: \(path)"
        }
    }
}
