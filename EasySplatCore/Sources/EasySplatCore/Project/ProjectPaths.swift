import Foundation

/// Canonical on-disk layout for a single EasySplat project bundle.
public struct ProjectPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var metadataURL: URL { root.appendingPathComponent("project.json") }
    public var originalsURL: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    public var framesRawURL: URL { root.appendingPathComponent("Frames/raw", isDirectory: true) }
    public var framesSelectedURL: URL { root.appendingPathComponent("Frames/selected", isDirectory: true) }
    public var framesSelectedManifestURL: URL { root.appendingPathComponent("Frames/selected_manifest.json") }
    public var colmapDatabaseURL: URL { root.appendingPathComponent("SfM/colmap/database.db") }
    public var colmapSeedURL: URL { root.appendingPathComponent("SfM/colmap/seed", isDirectory: true) }
    public var colmapSeedModelURL: URL { colmapSeedURL.appendingPathComponent("0", isDirectory: true) }
    public var colmapSparseURL: URL { root.appendingPathComponent("SfM/colmap/sparse", isDirectory: true) }
    public var trainingURL: URL { root.appendingPathComponent("Training", isDirectory: true) }
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

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: framesRawURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: framesSelectedURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: colmapSeedURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: colmapSparseURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: trainingURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsURL, withIntermediateDirectories: true)
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
}

public enum ProjectPathError: Error, LocalizedError, Equatable {
    case emptyPath
    case absolutePath(String)
    case unsafeComponent(String)
    case escapesProjectRoot(String)

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
        }
    }
}
