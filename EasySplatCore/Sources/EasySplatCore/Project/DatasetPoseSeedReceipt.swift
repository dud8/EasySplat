import Foundation

/// One persisted geometry file bound by a dataset import: either a converted
/// COLMAP seed text file under `Import/seed` or an original metadata file kept
/// verbatim under `Import/source`. Paths are project-root-relative.
public struct DatasetReceiptFile: Codable, Sendable, Equatable {
    public let projectRelativePath: String
    public let byteCount: Int
    public let sha256: String

    public init(projectRelativePath: String, byteCount: Int, sha256: String) {
        self.projectRelativePath = projectRelativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Binds one dataset-declared posed image to the file adopted through the photo
/// machinery. `entryID` is the stable declared identity; the content digest is
/// carried alongside it because admission may legitimately reject duplicate
/// content, so digests alone cannot key the mapping.
public struct DatasetReceiptEntry: Codable, Sendable, Equatable {
    public let entryID: String
    public let declaredPath: String
    public let adoptedFileName: String
    public let sourceSHA256: String

    public init(
        entryID: String,
        declaredPath: String,
        adoptedFileName: String,
        sourceSHA256: String
    ) {
        self.entryID = entryID
        self.declaredPath = declaredPath
        self.adoptedFileName = adoptedFileName
        self.sourceSHA256 = sourceSHA256
    }
}

/// The single receipt binding a pre-processed dataset import: the converted
/// COLMAP seed persisted under `Import/seed`, the original geometry metadata kept
/// under `Import/source`, and the mapping from declared images to the files
/// adopted through the photo machinery.
public struct DatasetPoseSeedReceipt: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public static let seedDirectoryRelativePath = "Import/seed"
    public static let sourceDirectoryRelativePath = "Import/source"
    public static let seedFileNames = ["cameras.txt", "images.txt", "points3D.txt"]

    /// The three converted seed files, in canonical order, as project-relative paths.
    public static var seedFileRelativePaths: [String] {
        seedFileNames.map { "\(seedDirectoryRelativePath)/\($0)" }
    }

    public let schemaVersion: Int
    public let kind: DatasetKind
    public let route: DatasetGeometryRoute
    public let seedFiles: [DatasetReceiptFile]
    public let sourceFiles: [DatasetReceiptFile]
    public let entries: [DatasetReceiptEntry]
    public let imageCount: Int

    public init(
        schemaVersion: Int = DatasetPoseSeedReceipt.currentSchemaVersion,
        kind: DatasetKind,
        route: DatasetGeometryRoute,
        seedFiles: [DatasetReceiptFile],
        sourceFiles: [DatasetReceiptFile],
        entries: [DatasetReceiptEntry],
        imageCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.route = route
        self.seedFiles = seedFiles
        self.sourceFiles = sourceFiles
        self.entries = entries
        self.imageCount = imageCount
    }
}

extension DatasetPoseSeedReceipt {
    /// Builds a receipt by measuring the on-disk seed and source files. Seed paths
    /// are fixed (`cameras.txt`, `images.txt`, `points3D.txt` under `Import/seed`);
    /// source paths are supplied by the caller after copying the originals under
    /// `Import/source`. Each file is digested with the module's descriptor-bound,
    /// streaming SHA-256 helper.
    public static func build(
        kind: DatasetKind,
        route: DatasetGeometryRoute,
        entries: [DatasetReceiptEntry],
        sourceRelativePaths: [String],
        projectRoot: URL
    ) throws -> DatasetPoseSeedReceipt {
        let paths = ProjectPaths(root: projectRoot)
        let seedFiles = try seedFileRelativePaths.map {
            try measuredFile(relativePath: $0, paths: paths)
        }
        let sourceFiles = try sourceRelativePaths.map {
            try measuredFile(relativePath: $0, paths: paths)
        }
        return DatasetPoseSeedReceipt(
            kind: kind,
            route: route,
            seedFiles: seedFiles,
            sourceFiles: sourceFiles,
            entries: entries,
            imageCount: entries.count
        )
    }

    private static func measuredFile(
        relativePath: String,
        paths: ProjectPaths
    ) throws -> DatasetReceiptFile {
        let url = try paths.resolveProjectRelativePath(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let sha256 = try GeometryArtifactStore.sha256(of: url)
        return DatasetReceiptFile(
            projectRelativePath: relativePath,
            byteCount: byteCount,
            sha256: sha256
        )
    }
}
