import Foundation

public enum SfmBackend: String, Codable, Sendable, Equatable {
    case da3
    case colmap
    /// Camera poses supplied by an imported dataset. Features and matching
    /// still run through the COLMAP toolchain when the run plan's
    /// `datasetGeometryRoute` is `seedTriangulate`; `adoptDirect` skips them.
    case importedPoses
}
