import Foundation

/// Dataset format names shared across the package so detection and import can
/// never disagree about which manifest is authoritative.
package enum DatasetContract {
    package static let nerfstudioManifestName = "transforms.json"
    package static let maximumEntryCount = 50_000
    package static let maximumRelativePathComponents = 64
    package static let maximumArchiveListingBytes = 128 * 1024 * 1024

    /// Selection-time ZIP sniffing is deliberately non-authoritative, but it
    /// still has to be bounded before the central directory is materialized.
    /// Preflight opens a new snapshot and validates it again before extraction.
    package static func archiveEntryNames(at url: URL) throws -> [String] {
        try ZipArchiveReader.boundedEntryNames(
            inArchiveAt: url,
            maximumEntryCount: maximumEntryCount,
            maximumListingBytes: maximumArchiveListingBytes,
            maximumPathComponents: maximumRelativePathComponents
        )
    }

    package static func archivePathIsWithinDepthLimit(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var completedComponents = 0
        var currentComponentBytes = 0

        for byte in path.utf8 {
            if byte == UInt8(ascii: "/") {
                guard currentComponentBytes > 0 else { return false }
                completedComponents += 1
                guard completedComponents <= maximumRelativePathComponents else {
                    return false
                }
                currentComponentBytes = 0
            } else {
                currentComponentBytes += 1
            }
        }

        if currentComponentBytes > 0 {
            completedComponents += 1
        }
        return completedComponents > 0
            && completedComponents <= maximumRelativePathComponents
    }
}

/// The picker-owned source grant and the dataset root discovered beneath it.
/// Folder roots are intentionally limited to the selected directory itself or
/// one direct child; ZIP roots are resolved only after private extraction.
package enum DatasetInputSource: Sendable, Equatable {
    case directory(selectedURL: URL, resolvedRoot: URL)
    case zip(URL)
}

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
        guard !path.isEmpty else { return nil }

        // A single conventional `./` prefix is harmless. Do not repeatedly
        // slice it away: a hostile model can otherwise force quadratic copies
        // before the component ceiling is even considered.
        let candidateStart: String.Index
        if path.hasPrefix("./") {
            candidateStart = path.index(path.startIndex, offsetBy: 2)
        } else {
            candidateStart = path.startIndex
        }
        let rawCandidate = path[candidateStart...]
        guard rawPathIsStructurallySafe(rawCandidate.utf8) else { return nil }

        let candidate = String(rawCandidate).precomposedStringWithCanonicalMapping
        guard !candidate.isEmpty,
              !candidate.hasPrefix("/"),
              !candidate.contains("\\"),
              !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return candidate
    }

    /// Scans the original UTF-8 storage once and rejects the 65th component,
    /// empty components, dot traversal, backslashes, and ASCII controls before
    /// allocating a normalized String or a component array. Canonical Unicode
    /// controls are checked after normalization above.
    private static func rawPathIsStructurallySafe<Bytes: Collection>(
        _ bytes: Bytes
    ) -> Bool where Bytes.Element == UInt8 {
        guard !bytes.isEmpty else { return false }

        var completedComponents = 0
        var currentComponentBytes = 0
        var currentComponentContainsOnlyDots = true

        func componentIsUnsafe() -> Bool {
            currentComponentBytes == 0
                || (currentComponentContainsOnlyDots && currentComponentBytes <= 2)
        }

        for byte in bytes {
            guard byte != UInt8(ascii: "\\"),
                  byte >= 0x20,
                  byte != 0x7F else {
                return false
            }
            if byte == UInt8(ascii: "/") {
                guard !componentIsUnsafe() else { return false }
                completedComponents += 1
                guard completedComponents < DatasetContract.maximumRelativePathComponents else {
                    return false
                }
                currentComponentBytes = 0
                currentComponentContainsOnlyDots = true
            } else {
                currentComponentBytes += 1
                if byte != UInt8(ascii: ".") {
                    currentComponentContainsOnlyDots = false
                }
            }
        }

        guard !componentIsUnsafe() else { return false }
        return completedComponents + 1 <= DatasetContract.maximumRelativePathComponents
    }

    static func collisionKey(_ normalizedPath: String) -> String {
        normalizedPath.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
