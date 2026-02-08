import Foundation

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
    public var colmapLogURL: URL { logsURL.appendingPathComponent("colmap.log") }
    public var glomapLogURL: URL { logsURL.appendingPathComponent("glomap.log") }
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
}
