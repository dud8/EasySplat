import Foundation

public enum SfmBackend: String, Sendable {
    case vggt

    @available(*, deprecated, message: "learned_sfm / MASt3R is deprecated; use vggt-mps instead.")
    case learned
    case colmap
}
