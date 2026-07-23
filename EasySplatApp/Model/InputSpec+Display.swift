import EasySplatCore

extension InputSpec {
    /// One-line user-facing summary of the capture input, shared by the
    /// processing header and the result inspector.
    var displaySummary: String {
        switch self {
        case .video(let files):
            return files.count == 1 ? "1 video" : "\(files.count) videos"
        case .photos:
            return "Photo folder"
        case .mixed(let videos, _):
            return "\(videos.count) video\(videos.count == 1 ? "" : "s") and photos"
        case .dataset(let kind, _):
            return kind.displayName
        }
    }
}

extension DatasetKind {
    /// User-facing format names; these terms are the vocabulary this
    /// audience already uses for their exports.
    var displayName: String {
        switch self {
        case .colmap:
            return "COLMAP project"
        case .nerfstudio:
            return "Nerfstudio dataset"
        case .polycam:
            return "Polycam export"
        }
    }
}
