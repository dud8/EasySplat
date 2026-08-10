import EasySplatCore
import Foundation

/// A pre-processed dataset the user selected but has not yet imported. A
/// dataset is exclusive with photo and video selection, so at most one is
/// pending at a time. `imageCount` stays nil until preflight reconciles the
/// posed images against the files on disk; the UI shows the count only once
/// it is known.
struct PendingDataset: Equatable {
    let kind: DatasetKind
    /// Exact URL supplied by the picker or drop target. This is the URL whose
    /// security-scoped grant must remain alive.
    let selectedURL: URL
    /// Dataset root detected at the selected directory itself or one real,
    /// non-symlink direct child. ZIPs retain their selected archive URL here.
    let resolvedRoot: URL
    let isZip: Bool
    var imageCount: Int?

    /// Compatibility name for picker/admission code that still keys grants by
    /// the selected URL.
    var sourceURL: URL { selectedURL }

    var inputSource: DatasetInputSource {
        isZip
            ? .zip(selectedURL)
            : .directory(selectedURL: selectedURL, resolvedRoot: resolvedRoot)
    }

    init(
        kind: DatasetKind,
        selectedURL: URL,
        resolvedRoot: URL,
        isZip: Bool,
        imageCount: Int?
    ) {
        self.kind = kind
        self.selectedURL = selectedURL
        self.resolvedRoot = resolvedRoot
        self.isZip = isZip
        self.imageCount = imageCount
    }

    /// Compatibility initializer for the existing selection lane. Folder
    /// detection is repeated so the pending value does not discard the root
    /// already discovered beneath a selected wrapper.
    init(kind: DatasetKind, sourceURL: URL, isZip: Bool, imageCount: Int?) {
        let resolvedRoot: URL
        if isZip {
            resolvedRoot = sourceURL
        } else if let detection = DatasetSniffer.detect(at: sourceURL), detection.kind == kind {
            resolvedRoot = detection.root
        } else {
            resolvedRoot = sourceURL
        }
        self.init(
            kind: kind,
            selectedURL: sourceURL,
            resolvedRoot: resolvedRoot,
            isZip: isZip,
            imageCount: imageCount
        )
    }
}
