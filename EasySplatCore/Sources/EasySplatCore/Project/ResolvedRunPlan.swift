import Foundation

public enum ResolvedPairingPolicy: String, Codable, Sendable, Equatable {
    case unorderedRetrieval
    case orderedContinuous
    case orderedOrbit
    case orderedWalkthrough
    case orderedLargeArea
}

public enum ResolvedRunPlanValidationError: Error, LocalizedError, Equatable {
    case emptyToolchainCapabilities
    case unknownToolchainCapability(String)
    case unknownRouteIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .emptyToolchainCapabilities:
            return "Run plan does not request any tool capabilities."
        case .unknownToolchainCapability(let capability):
            return "Run plan requires an unsupported tool capability: \(capability)."
        case .unknownRouteIdentifier(let identifier):
            return "Run plan contains an unsupported geometry route: \(identifier)."
        }
    }
}

public struct ResolvedRunPlan: Codable, Sendable, Equatable {
    public var routeIdentifier: String
    public var modelIdentifier: String
    public var memoryTier: String
    public var chunkSize: Int
    public var keyframeBudget: Int
    public var maximumImageDimension: Int
    public var cameraGrouping: CameraGrouping
    public var lensProjection: LensProjection
    public var refinementIterationLimit: Int
    public var trainerIterationLimit: Int
    public var plateauWindow: Int
    public var requiredToolchainCapabilities: [String]
    public var fallbackRouteIdentifiers: [String]
    public var capturePath: CapturePath
    public var inputOrdering: InputOrdering
    public var photoSelection: PhotoSelection
    public var pairingPolicy: ResolvedPairingPolicy
    public var sequentialOverlap: Int
    public var deterministicSeed: UInt64

    public init(
        routeIdentifier: String,
        modelIdentifier: String,
        memoryTier: String,
        chunkSize: Int,
        keyframeBudget: Int,
        maximumImageDimension: Int,
        cameraGrouping: CameraGrouping,
        lensProjection: LensProjection,
        refinementIterationLimit: Int,
        trainerIterationLimit: Int,
        plateauWindow: Int,
        requiredToolchainCapabilities: [String],
        fallbackRouteIdentifiers: [String],
        capturePath: CapturePath = .automatic,
        inputOrdering: InputOrdering = .automatic,
        photoSelection: PhotoSelection = .automatic,
        pairingPolicy: ResolvedPairingPolicy = .unorderedRetrieval,
        sequentialOverlap: Int = 10,
        deterministicSeed: UInt64 = 42
    ) {
        self.routeIdentifier = routeIdentifier
        self.modelIdentifier = modelIdentifier
        self.memoryTier = memoryTier
        self.chunkSize = chunkSize
        self.keyframeBudget = keyframeBudget
        self.maximumImageDimension = maximumImageDimension
        self.cameraGrouping = cameraGrouping
        self.lensProjection = lensProjection
        self.refinementIterationLimit = refinementIterationLimit
        self.trainerIterationLimit = trainerIterationLimit
        self.plateauWindow = plateauWindow
        self.requiredToolchainCapabilities = requiredToolchainCapabilities
        self.fallbackRouteIdentifiers = fallbackRouteIdentifiers
        self.capturePath = capturePath
        self.inputOrdering = inputOrdering
        self.photoSelection = photoSelection
        self.pairingPolicy = pairingPolicy
        self.sequentialOverlap = sequentialOverlap
        self.deterministicSeed = deterministicSeed
    }

    private enum CodingKeys: String, CodingKey {
        case routeIdentifier
        case modelIdentifier
        case memoryTier
        case chunkSize
        case keyframeBudget
        case maximumImageDimension
        case cameraGrouping
        case lensProjection
        case refinementIterationLimit
        case trainerIterationLimit
        case plateauWindow
        case requiredToolchainCapabilities
        case fallbackRouteIdentifiers
        case capturePath
        case inputOrdering
        case photoSelection
        case pairingPolicy
        case sequentialOverlap
        case deterministicSeed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        routeIdentifier = try values.decode(String.self, forKey: .routeIdentifier)
        modelIdentifier = try values.decode(String.self, forKey: .modelIdentifier)
        memoryTier = try values.decode(String.self, forKey: .memoryTier)
        chunkSize = try values.decode(Int.self, forKey: .chunkSize)
        keyframeBudget = try values.decode(Int.self, forKey: .keyframeBudget)
        maximumImageDimension = try values.decode(Int.self, forKey: .maximumImageDimension)
        cameraGrouping = try values.decode(CameraGrouping.self, forKey: .cameraGrouping)
        lensProjection = try values.decode(LensProjection.self, forKey: .lensProjection)
        refinementIterationLimit = try values.decode(Int.self, forKey: .refinementIterationLimit)
        trainerIterationLimit = try values.decode(Int.self, forKey: .trainerIterationLimit)
        plateauWindow = try values.decode(Int.self, forKey: .plateauWindow)
        requiredToolchainCapabilities = try values.decode([String].self, forKey: .requiredToolchainCapabilities)
        fallbackRouteIdentifiers = try values.decode([String].self, forKey: .fallbackRouteIdentifiers)
        capturePath = try values.decodeIfPresent(CapturePath.self, forKey: .capturePath) ?? .automatic
        inputOrdering = try values.decodeIfPresent(InputOrdering.self, forKey: .inputOrdering) ?? .automatic
        photoSelection = try values.decodeIfPresent(PhotoSelection.self, forKey: .photoSelection) ?? .automatic
        pairingPolicy = try values.decodeIfPresent(ResolvedPairingPolicy.self, forKey: .pairingPolicy)
            ?? .unorderedRetrieval
        sequentialOverlap = try values.decodeIfPresent(Int.self, forKey: .sequentialOverlap) ?? 10
        deterministicSeed = try values.decodeIfPresent(UInt64.self, forKey: .deterministicSeed) ?? 42
    }

    public func toolchainCapabilityRequest() throws -> ToolchainCapabilityRequest {
        _ = try validatedBackendOrder()
        var capabilities = Set<ToolchainCapability>()
        for rawValue in requiredToolchainCapabilities {
            guard let capability = ToolchainCapability(rawValue: rawValue) else {
                throw ResolvedRunPlanValidationError.unknownToolchainCapability(rawValue)
            }
            capabilities.insert(capability)
        }
        guard !capabilities.isEmpty else {
            throw ResolvedRunPlanValidationError.emptyToolchainCapabilities
        }
        return ToolchainCapabilityRequest(capabilities: capabilities)
    }

    public func validatedBackendOrder() throws -> [SfmBackend] {
        let identifiers = [routeIdentifier] + fallbackRouteIdentifiers
        guard !identifiers.isEmpty else {
            throw ResolvedRunPlanValidationError.unknownRouteIdentifier("")
        }
        return try identifiers.map { identifier in
            guard let backend = SfmBackend(rawValue: identifier) else {
                throw ResolvedRunPlanValidationError.unknownRouteIdentifier(identifier)
            }
            return backend
        }
    }
}
