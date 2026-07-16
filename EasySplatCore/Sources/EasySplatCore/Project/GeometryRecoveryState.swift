import Foundation

public enum GeometryRecoveryBackend: String, Codable, Sendable, Equatable {
    case da3
    case colmap
}

public enum GeometryRecoveryComputeMode: String, Codable, Sendable, Equatable {
    case gpu
    case cpu
}

public struct GeometryRecoveryState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 4
    public static let maximumMappingAttemptCount = 10_000

    public enum ValidationError: Swift.Error, LocalizedError, Equatable {
        case invalidSchema(Int)
        case invalidSelectedFramesDigest
        case invalidImageNames
        case invalidMappingAttemptCount
        case invalidFallbackReasons
        case invalidBackendFields
        case bindingMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidSchema(let schemaVersion):
                return "Unsupported geometry recovery schema: \(schemaVersion)."
            case .invalidSelectedFramesDigest:
                return "Geometry recovery has an invalid selected-frames digest."
            case .invalidImageNames:
                return "Geometry recovery has invalid selected image names."
            case .invalidMappingAttemptCount:
                return "Geometry recovery has an invalid mapping attempt count."
            case .invalidFallbackReasons:
                return "Geometry recovery has invalid mapping fallback reasons."
            case .invalidBackendFields:
                return "Geometry recovery has fields that do not match its active backend."
            case .bindingMismatch:
                return "Geometry recovery does not match the selected frames."
            }
        }
    }

    public var schemaVersion: Int
    public var selectedFramesDigest: String
    public var orderedImageNames: [String]
    public var activeBackend: GeometryRecoveryBackend
    public var mappingAttemptCount: Int
    public var mappingFallbackReasons: [String]
    public var pendingPairRecoveryLevel: PairGraphRecoveryLevel?
    public var da3DescriptorMatcher: DescriptorMatcher?
    public var colmapComputeMode: GeometryRecoveryComputeMode?
    public var plannedIncrementalCadence: IncrementalMappingCadenceArtifact?
    public var activeIncrementalCadence: IncrementalMappingCadenceArtifact?

    public init(
        selectedFramesDigest: String,
        orderedImageNames: [String],
        activeBackend: GeometryRecoveryBackend,
        mappingAttemptCount: Int,
        mappingFallbackReasons: [String],
        pendingPairRecoveryLevel: PairGraphRecoveryLevel? = nil,
        da3DescriptorMatcher: DescriptorMatcher? = nil,
        colmapComputeMode: GeometryRecoveryComputeMode? = nil,
        plannedIncrementalCadence: IncrementalMappingCadenceArtifact? = nil,
        activeIncrementalCadence: IncrementalMappingCadenceArtifact? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.orderedImageNames = orderedImageNames
        self.activeBackend = activeBackend
        self.mappingAttemptCount = mappingAttemptCount
        self.mappingFallbackReasons = mappingFallbackReasons
        self.pendingPairRecoveryLevel = pendingPairRecoveryLevel
        self.da3DescriptorMatcher = da3DescriptorMatcher
        self.colmapComputeMode = colmapComputeMode
        self.plannedIncrementalCadence = plannedIncrementalCadence
        self.activeIncrementalCadence = activeIncrementalCadence
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.invalidSchema(schemaVersion)
        }
        guard Self.isSHA256(selectedFramesDigest) else {
            throw ValidationError.invalidSelectedFramesDigest
        }
        guard orderedImageNames.count >= RunPlanResolver.minimumReconstructionImageCount,
              Set(orderedImageNames).count == orderedImageNames.count,
              orderedImageNames.allSatisfy(Self.isSafeImageName) else {
            throw ValidationError.invalidImageNames
        }
        guard mappingAttemptCount >= 0,
              mappingAttemptCount <= Self.maximumMappingAttemptCount else {
            throw ValidationError.invalidMappingAttemptCount
        }
        guard Set(mappingFallbackReasons).count == mappingFallbackReasons.count else {
            throw ValidationError.invalidFallbackReasons
        }
        var totalFallbackReasonBytes = 0
        for reason in mappingFallbackReasons {
            let byteCount = reason.utf8.count
            guard !reason.isEmpty,
                  reason == reason.trimmingCharacters(in: .whitespacesAndNewlines),
                  byteCount <= 4_096,
                  reason.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw ValidationError.invalidFallbackReasons
            }
            totalFallbackReasonBytes += byteCount
        }
        guard totalFallbackReasonBytes <= 64 * 1_024 else {
            throw ValidationError.invalidFallbackReasons
        }
        switch activeBackend {
        case .da3:
            guard pendingPairRecoveryLevel == nil,
                  da3DescriptorMatcher == nil || da3DescriptorMatcher == .exact,
                  colmapComputeMode == nil,
                  plannedIncrementalCadence == nil,
                  activeIncrementalCadence == nil else {
                throw ValidationError.invalidBackendFields
            }
        case .colmap:
            guard da3DescriptorMatcher == nil,
                  colmapComputeMode != nil,
                  let plannedIncrementalCadence,
                  let activeIncrementalCadence,
                  plannedIncrementalCadence.isValid,
                  activeIncrementalCadence.isValid,
                  activeIncrementalCadence == plannedIncrementalCadence
                    || (
                        plannedIncrementalCadence == .orderedFast
                            && activeIncrementalCadence == .conservative
                    ) else {
                throw ValidationError.invalidBackendFields
            }
        }
    }

    public func validateBinding(
        expectedImageNames: [String],
        expectedSelectedFramesDigest: String,
        expectedPlannedIncrementalCadence: IncrementalMappingCadenceArtifact?
    ) throws {
        try validate()
        guard orderedImageNames == expectedImageNames,
              selectedFramesDigest == expectedSelectedFramesDigest,
              plannedIncrementalCadence == expectedPlannedIncrementalCadence else {
            throw ValidationError.bindingMismatch
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func isSafeImageName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
