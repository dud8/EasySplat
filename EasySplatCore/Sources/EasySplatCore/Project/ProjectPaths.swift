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
    public var framesRawURL: URL { root.appendingPathComponent("Frames/raw", isDirectory: true) }
    public var framesSelectedURL: URL { root.appendingPathComponent("Frames/selected", isDirectory: true) }
    public var framesSelectedManifestURL: URL { root.appendingPathComponent("Frames/selected_manifest.json") }
    public var colmapDatabaseURL: URL { root.appendingPathComponent("SfM/colmap/database.db") }
    public var colmapSeedURL: URL { root.appendingPathComponent("SfM/colmap/seed", isDirectory: true) }
    public var colmapSeedModelURL: URL { colmapSeedURL.appendingPathComponent("0", isDirectory: true) }
    public var colmapSparseURL: URL { root.appendingPathComponent("SfM/colmap/sparse", isDirectory: true) }
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
    public var appEventsLogURL: URL { logsURL.appendingPathComponent("app_events.jsonl") }
    public var colmapLogURL: URL { logsURL.appendingPathComponent("colmap.log") }
    public var glomapLogURL: URL { logsURL.appendingPathComponent("glomap.log") }
    public var da3LogURL: URL { logsURL.appendingPathComponent("da3.log") }
    public var da3CoverageManifestURL: URL { logsURL.appendingPathComponent("da3_coverage_manifest.json") }
    public var mapanythingLogURL: URL { logsURL.appendingPathComponent("mapanything.log") }
    public var mapanythingCoverageManifestURL: URL { logsURL.appendingPathComponent("mapanything_coverage_manifest.json") }
    public var vggtLogURL: URL { logsURL.appendingPathComponent("vggt.log") }
    public var fastvggtLogURL: URL { logsURL.appendingPathComponent("fastvggt.log") }
    public var fastvggtCoverageManifestURL: URL { logsURL.appendingPathComponent("fastvggt_coverage_manifest.json") }
    public var brushLogURL: URL { logsURL.appendingPathComponent("brush.log") }
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
            "Training/checkpoints",
            "Output",
            "Logs",
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

        let resolved = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        let rootPath = standardizedRoot.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw ProjectPathError.escapesProjectRoot(trimmed)
        }
        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath()
        let canonicalResolved = resolved.resolvingSymlinksInPath()
        let canonicalRootPath = canonicalRoot.path
        guard canonicalResolved.path == canonicalRootPath || canonicalResolved.path.hasPrefix(canonicalRootPath + "/") else {
            throw ProjectPathError.escapesProjectRoot(trimmed)
        }
        return resolved
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
