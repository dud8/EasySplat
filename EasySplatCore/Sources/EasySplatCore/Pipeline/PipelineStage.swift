import Foundation

/// Ordered pipeline stages used for status, logging, and resume decisions.
public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case importInput
    case extractFrames
    case selectFrames
    case sfmFeatures
    case sfmMatching
    case sfmMapping
    case trainSplat
    case exportSplat
    case done

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let stage = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown pipeline stage: \(value)"
            )
        }
        self = stage
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String {
        switch self {
        case .importInput: return "Import"
        case .extractFrames: return "Preparing Frames"
        case .selectFrames: return "Choosing Frames"
        case .sfmFeatures: return "Finding Features"
        case .sfmMatching: return "Matching Views"
        case .sfmMapping: return "Solving Cameras"
        case .trainSplat: return "Training Model"
        case .exportSplat: return "Exporting"
        case .done: return "Done"
        }
    }
}
