import Foundation

/// The kind of pre-processed dataset a user imported. Raw values are
/// persisted in project metadata; do not rename cases.
public enum DatasetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case colmap
    case nerfstudio
    case polycam
}

/// How imported geometry reaches training.
/// - `adoptDirect`: the import carries a complete sparse model (poses and
///   triangulated points with observations); it is validated and adopted
///   without SfM compute.
/// - `seedTriangulate`: the import carries poses only; features and matches
///   are computed by the toolchain and points are re-triangulated against the
///   imported poses.
public enum DatasetGeometryRoute: String, Codable, Sendable, Equatable {
    case adoptDirect
    case seedTriangulate
}

/// One posed image declared by an imported dataset. `entryID` is the stable
/// declared identity (the dataset-relative path) used to key mappings; file
/// content digests are added at adoption and never replace this key, because
/// admission may legitimately reject duplicate-content files.
public struct DatasetImageRef: Sendable, Equatable {
    public var entryID: String
    public var declaredPath: String

    public init(entryID: String, declaredPath: String) {
        self.entryID = entryID
        self.declaredPath = declaredPath
    }
}

/// The pure output of a dataset importer: exactly the posed images to adopt,
/// the converted COLMAP model whose image NAMEs equal the declared paths, the
/// route the geometry should take, and non-fatal notes for the user. File
/// resolution, digesting, and receipts happen in the I/O shell, not here.
public struct DatasetImportPlan: Sendable, Equatable {
    public var kind: DatasetKind
    public var route: DatasetGeometryRoute
    public var images: [DatasetImageRef]
    public var model: ColmapTextModel
    public var notes: [String]

    public init(
        kind: DatasetKind,
        route: DatasetGeometryRoute,
        images: [DatasetImageRef],
        model: ColmapTextModel,
        notes: [String] = []
    ) {
        self.kind = kind
        self.route = route
        self.images = images
        self.model = model
        self.notes = notes
    }
}

/// Path rules shared by all importers for the image paths a dataset declares.
enum DatasetDeclaredPath {
    /// Normalizes a declared relative path (strips a leading `./`) and rejects
    /// anything that could escape the dataset root once resolved.
    static func normalized(_ path: String) -> String? {
        var candidate = path
        while candidate.hasPrefix("./") {
            candidate = String(candidate.dropFirst(2))
        }
        guard !candidate.isEmpty,
              !candidate.hasPrefix("/"),
              !candidate.contains("\\"),
              !candidate.contains("\n"),
              !candidate.contains("\r") else {
            return nil
        }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else {
            return nil
        }
        return candidate
    }
}
