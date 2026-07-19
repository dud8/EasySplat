import Foundation

public enum GeometryRecoveryComputeMode: String, Codable, Sendable, Equatable {
    case gpu
    case cpu
}

public struct GeometryRecoveryState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 8
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
    public var activeBackend: SfmBackend
    public var mappingAttemptCount: Int
    public var mappingFallbackReasons: [String]
    public var pendingPairRecoveryLevel: PairGraphRecoveryLevel?
    public var colmapComputeMode: GeometryRecoveryComputeMode?
    public var plannedIncrementalCadence: IncrementalMappingCadenceArtifact?
    public var activeIncrementalCadence: IncrementalMappingCadenceArtifact?
    public var cadenceFallbackTrigger: MappingCadenceFallbackTrigger?
    public var acceptedPairAttemptOrdinal: Int?
    public var pairListDigest: String?
    public var matchingDatabaseDigest: String?

    public init(
        selectedFramesDigest: String,
        orderedImageNames: [String],
        activeBackend: SfmBackend,
        mappingAttemptCount: Int,
        mappingFallbackReasons: [String],
        pendingPairRecoveryLevel: PairGraphRecoveryLevel? = nil,
        colmapComputeMode: GeometryRecoveryComputeMode? = nil,
        plannedIncrementalCadence: IncrementalMappingCadenceArtifact? = nil,
        activeIncrementalCadence: IncrementalMappingCadenceArtifact? = nil,
        cadenceFallbackTrigger: MappingCadenceFallbackTrigger? = nil,
        acceptedPairAttemptOrdinal: Int? = nil,
        pairListDigest: String? = nil,
        matchingDatabaseDigest: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.orderedImageNames = orderedImageNames
        self.activeBackend = activeBackend
        self.mappingAttemptCount = mappingAttemptCount
        self.mappingFallbackReasons = mappingFallbackReasons
        self.pendingPairRecoveryLevel = pendingPairRecoveryLevel
        self.colmapComputeMode = colmapComputeMode
        self.plannedIncrementalCadence = plannedIncrementalCadence
        self.activeIncrementalCadence = activeIncrementalCadence
        self.cadenceFallbackTrigger = cadenceFallbackTrigger
        self.acceptedPairAttemptOrdinal = acceptedPairAttemptOrdinal
        self.pairListDigest = pairListDigest
        self.matchingDatabaseDigest = matchingDatabaseDigest
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
                  colmapComputeMode == nil,
                  plannedIncrementalCadence == nil,
                  activeIncrementalCadence == nil,
                  cadenceFallbackTrigger == nil,
                  acceptedPairAttemptOrdinal == nil,
                  pairListDigest == nil,
                  matchingDatabaseDigest == nil else {
                throw ValidationError.invalidBackendFields
            }
        case .colmap:
            guard colmapComputeMode != nil,
                  let plannedIncrementalCadence,
                  let activeIncrementalCadence,
                  plannedIncrementalCadence.isValid,
                  activeIncrementalCadence.isValid,
                  IncrementalMappingCadencePolicy.validates(
                    planned: plannedIncrementalCadence,
                    accepted: activeIncrementalCadence,
                    trigger: cadenceFallbackTrigger
                  ) else {
                throw ValidationError.invalidBackendFields
            }
            let graphFields = [
                acceptedPairAttemptOrdinal != nil,
                pairListDigest != nil,
                matchingDatabaseDigest != nil,
            ]
            guard graphFields.allSatisfy({ $0 }) || graphFields.allSatisfy({ !$0 }) else {
                throw ValidationError.invalidBackendFields
            }
            if let acceptedPairAttemptOrdinal,
               let pairListDigest,
               let matchingDatabaseDigest {
                guard acceptedPairAttemptOrdinal > 0,
                      Self.isSHA256(pairListDigest),
                      Self.isSHA256(matchingDatabaseDigest) else {
                    throw ValidationError.invalidBackendFields
                }
            } else if cadenceFallbackTrigger != nil {
                throw ValidationError.invalidBackendFields
            }
        }
    }

    public func validatePairGraphBinding(
        acceptedPairAttemptOrdinal expectedOrdinal: Int,
        pairListDigest expectedPairListDigest: String,
        matchingDatabaseDigest expectedMatchingDatabaseDigest: String
    ) throws {
        try validate()
        guard acceptedPairAttemptOrdinal == expectedOrdinal,
              pairListDigest == expectedPairListDigest,
              matchingDatabaseDigest == expectedMatchingDatabaseDigest else {
            throw ValidationError.bindingMismatch
        }
    }

    public func validateBinding(
        expectedImageNames: [String],
        expectedSelectedFramesDigest: String,
        expectedGeometryBackend: SfmBackend,
        expectedPlannedIncrementalCadence: IncrementalMappingCadenceArtifact?
    ) throws {
        try validate()
        guard orderedImageNames == expectedImageNames,
              selectedFramesDigest == expectedSelectedFramesDigest,
              isBound(to: expectedGeometryBackend),
              plannedIncrementalCadence == expectedPlannedIncrementalCadence else {
            throw ValidationError.bindingMismatch
        }
    }

    func isBound(to geometryBackend: SfmBackend) -> Bool {
        switch (activeBackend, geometryBackend) {
        case (.da3, .da3), (.colmap, .colmap):
            return true
        case (.da3, .colmap), (.colmap, .da3):
            return false
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
