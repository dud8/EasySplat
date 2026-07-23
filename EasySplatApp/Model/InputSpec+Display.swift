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
        }
    }
}
