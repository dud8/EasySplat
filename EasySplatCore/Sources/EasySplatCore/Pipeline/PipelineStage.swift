import Foundation

public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case importInput
    case extractFrames
    case selectFrames
    case sfmFeatures
    case sfmMatching
    case sfmMapping
    case trainBrush
    case exportSplat
    case done

    public var displayName: String {
        switch self {
        case .importInput: return "Import"
        case .extractFrames: return "Preparing Frames"
        case .selectFrames: return "Choosing Frames"
        case .sfmFeatures: return "Finding Features"
        case .sfmMatching: return "Matching Views"
        case .sfmMapping: return "Solving Cameras"
        case .trainBrush: return "Training Model"
        case .exportSplat: return "Exporting"
        case .done: return "Done"
        }
    }
}
