import EasySplatCore
import Foundation

/// A pre-processed dataset the user selected but has not yet imported. A
/// dataset is exclusive with photo and video selection, so at most one is
/// pending at a time. `imageCount` stays nil until preflight reconciles the
/// posed images against the files on disk; the UI shows the count only once
/// it is known.
struct PendingDataset: Equatable {
    let kind: DatasetKind
    let sourceURL: URL
    let isZip: Bool
    var imageCount: Int?
}
