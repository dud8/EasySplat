import Foundation

public enum CapturePath: String, Codable, Sendable, Equatable {
    case automatic
    case orbit
    case walkthrough
    case largeArea
}

public enum DetailProfile: String, Codable, Sendable, Equatable {
    case fast
    case balanced
    case highDetail
}

public enum CameraGrouping: String, Codable, Sendable, Equatable {
    case automatic
    case sameCameraAndLens
    case mixedCamerasOrLenses
}

public enum LensProjection: String, Codable, Sendable, Equatable {
    case automatic
    case perspective
    case fisheye
}

public enum InputOrdering: String, Codable, Sendable, Equatable {
    case automatic
    case continuous
    case unordered
}

public enum ResourcePolicy: String, Codable, Sendable, Equatable {
    case automatic
    case conserveMemory
    case maximumPerformance
}

public enum PhotoSelection: String, Codable, Sendable, Equatable {
    case automatic
    case useAllValidPhotos
}

public struct RequestedRunOptions: Codable, Sendable, Equatable {
    public var capturePath: CapturePath
    public var detailProfile: DetailProfile
    public var cameraGrouping: CameraGrouping
    public var lensProjection: LensProjection
    public var inputOrdering: InputOrdering
    public var resourcePolicy: ResourcePolicy
    public var photoSelection: PhotoSelection

    public init(
        capturePath: CapturePath = .automatic,
        detailProfile: DetailProfile = .balanced,
        cameraGrouping: CameraGrouping = .automatic,
        lensProjection: LensProjection = .automatic,
        inputOrdering: InputOrdering = .automatic,
        resourcePolicy: ResourcePolicy = .automatic,
        photoSelection: PhotoSelection = .automatic
    ) {
        self.capturePath = capturePath
        self.detailProfile = detailProfile
        self.cameraGrouping = cameraGrouping
        self.lensProjection = lensProjection
        self.inputOrdering = inputOrdering
        self.resourcePolicy = resourcePolicy
        self.photoSelection = photoSelection
    }
}
