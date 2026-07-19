import Foundation

public struct PhotoAnalysisEvidence: Codable, Equatable, Sendable {
    public static let spatialDescriptorLength = 64
    public static let currentRecipeVersion = 1
    public static let currentRecipeSHA256 =
        "b52a36798d3b36a5932e856b7a64df2521e27acb100f89b4f287cda84e8addb0"

    public let sourceSHA256: String
    public let spatialDescriptor: [UInt8]
    public let qualityBucket: UInt8
    public let dHash: UInt64
    public let proxyPixelWidth: Int
    public let proxyPixelHeight: Int
    public let proxyPixelSHA256: String
    public let analysisRecipeVersion: Int
    public let analysisRecipeSHA256: String

    public init(
        sourceSHA256: String,
        spatialDescriptor: [UInt8],
        qualityBucket: UInt8,
        dHash: UInt64,
        proxyPixelWidth: Int,
        proxyPixelHeight: Int,
        proxyPixelSHA256: String,
        analysisRecipeVersion: Int,
        analysisRecipeSHA256: String
    ) {
        self.sourceSHA256 = sourceSHA256
        self.spatialDescriptor = spatialDescriptor
        self.qualityBucket = qualityBucket
        self.dHash = dHash
        self.proxyPixelWidth = proxyPixelWidth
        self.proxyPixelHeight = proxyPixelHeight
        self.proxyPixelSHA256 = proxyPixelSHA256
        self.analysisRecipeVersion = analysisRecipeVersion
        self.analysisRecipeSHA256 = analysisRecipeSHA256
    }
}

public enum PhotoDiversitySelectorError: Error, Equatable, Sendable {
    case negativeTargetCount(Int)
    case invalidSourceSHA256(String)
    case duplicateSourceSHA256(String)
    case invalidSpatialDescriptorLength(sourceSHA256: String, actual: Int)
    case invalidProxyDimensions(sourceSHA256: String, width: Int, height: Int)
    case invalidProxyPixelSHA256(sourceSHA256: String)
    case invalidAnalysisRecipeVersion(sourceSHA256: String, actual: Int)
    case invalidAnalysisRecipeSHA256(sourceSHA256: String)
    case mixedAnalysisRecipeVersion(expected: Int, actual: Int, sourceSHA256: String)
    case mixedAnalysisRecipeSHA256(expected: String, actual: String, sourceSHA256: String)
}

public enum PhotoDiversitySelector {
    public static let selectorPolicyVersion = 1

    // SHA-256 of the domain-separated canonical policy string:
    // EasySplat.PhotoDiversitySelector/v1|descriptor=spatial-u8x64|distance=l1|
    // equivalence-width=64|quality=u8|seed=quality-sha256|
    // tie=distance-bin-quality-exact-distance-sha256
    public static let selectorPolicySHA256 =
        "946add648e84c7de840aa25ac94cb261366d67f599fb7aad245af92688754abf"

    private static let distanceEquivalenceWidth = PhotoAnalysisEvidence.spatialDescriptorLength

    public static func rank(
        _ evidence: [PhotoAnalysisEvidence],
        targetCount: Int,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [PhotoAnalysisEvidence] {
        guard targetCount >= 0 else {
            throw PhotoDiversitySelectorError.negativeTargetCount(targetCount)
        }

        try checkCancellation()
        let candidates = evidence
        try validate(candidates, checkCancellation: checkCancellation)
        guard targetCount > 0, !candidates.isEmpty else { return [] }

        let limit = min(targetCount, candidates.count)
        var ranked: [PhotoAnalysisEvidence] = []
        ranked.reserveCapacity(limit)
        var isSelected = [Bool](repeating: false, count: candidates.count)
        var minimumDistance = [Int](repeating: .max, count: candidates.count)

        var selectedIndex = try seedIndex(
            in: candidates,
            checkCancellation: checkCancellation
        )
        while true {
            isSelected[selectedIndex] = true
            ranked.append(candidates[selectedIndex])
            guard ranked.count < limit else { return ranked }

            let selectedDescriptor = candidates[selectedIndex].spatialDescriptor
            for candidateIndex in candidates.indices where !isSelected[candidateIndex] {
                try checkCancellation()
                minimumDistance[candidateIndex] = min(
                    minimumDistance[candidateIndex],
                    l1Distance(
                        selectedDescriptor,
                        candidates[candidateIndex].spatialDescriptor
                    )
                )
            }

            selectedIndex = try nextIndex(
                in: candidates,
                isSelected: isSelected,
                minimumDistance: minimumDistance,
                checkCancellation: checkCancellation
            )
        }
    }

    private static func validate(
        _ candidates: [PhotoAnalysisEvidence],
        checkCancellation: () throws -> Void
    ) throws {
        var sourceSHA256s = Set<String>()
        for candidate in candidates {
            try checkCancellation()
            guard isSHA256(candidate.sourceSHA256) else {
                throw PhotoDiversitySelectorError.invalidSourceSHA256(
                    candidate.sourceSHA256
                )
            }
            guard sourceSHA256s.insert(candidate.sourceSHA256).inserted else {
                throw PhotoDiversitySelectorError.duplicateSourceSHA256(
                    candidate.sourceSHA256
                )
            }
            guard candidate.spatialDescriptor.count
                    == PhotoAnalysisEvidence.spatialDescriptorLength else {
                throw PhotoDiversitySelectorError.invalidSpatialDescriptorLength(
                    sourceSHA256: candidate.sourceSHA256,
                    actual: candidate.spatialDescriptor.count
                )
            }
            guard candidate.proxyPixelWidth > 0, candidate.proxyPixelHeight > 0 else {
                throw PhotoDiversitySelectorError.invalidProxyDimensions(
                    sourceSHA256: candidate.sourceSHA256,
                    width: candidate.proxyPixelWidth,
                    height: candidate.proxyPixelHeight
                )
            }
            guard isSHA256(candidate.proxyPixelSHA256) else {
                throw PhotoDiversitySelectorError.invalidProxyPixelSHA256(
                    sourceSHA256: candidate.sourceSHA256
                )
            }
            guard candidate.analysisRecipeVersion > 0 else {
                throw PhotoDiversitySelectorError.invalidAnalysisRecipeVersion(
                    sourceSHA256: candidate.sourceSHA256,
                    actual: candidate.analysisRecipeVersion
                )
            }
            guard isSHA256(candidate.analysisRecipeSHA256) else {
                throw PhotoDiversitySelectorError.invalidAnalysisRecipeSHA256(
                    sourceSHA256: candidate.sourceSHA256
                )
            }
        }

        guard var reference = candidates.first else { return }
        for candidate in candidates.dropFirst() {
            try checkCancellation()
            if candidate.sourceSHA256 < reference.sourceSHA256 {
                reference = candidate
            }
        }
        var versionMismatch: PhotoAnalysisEvidence?
        var hashMismatch: PhotoAnalysisEvidence?
        for candidate in candidates {
            try checkCancellation()
            if candidate.analysisRecipeVersion != reference.analysisRecipeVersion,
               versionMismatch.map({ candidate.sourceSHA256 < $0.sourceSHA256 }) ?? true {
                versionMismatch = candidate
            }
            if candidate.analysisRecipeSHA256 != reference.analysisRecipeSHA256,
               hashMismatch.map({ candidate.sourceSHA256 < $0.sourceSHA256 }) ?? true {
                hashMismatch = candidate
            }
        }
        if let versionMismatch {
            throw PhotoDiversitySelectorError.mixedAnalysisRecipeVersion(
                expected: reference.analysisRecipeVersion,
                actual: versionMismatch.analysisRecipeVersion,
                sourceSHA256: versionMismatch.sourceSHA256
            )
        }
        if let hashMismatch {
            throw PhotoDiversitySelectorError.mixedAnalysisRecipeSHA256(
                expected: reference.analysisRecipeSHA256,
                actual: hashMismatch.analysisRecipeSHA256,
                sourceSHA256: hashMismatch.sourceSHA256
            )
        }
    }

    private static func seedIndex(
        in candidates: [PhotoAnalysisEvidence],
        checkCancellation: () throws -> Void
    ) throws -> Int {
        var best = candidates.startIndex
        for index in candidates.indices {
            try checkCancellation()
            if candidates[index].qualityBucket > candidates[best].qualityBucket
                || (candidates[index].qualityBucket == candidates[best].qualityBucket
                    && candidates[index].sourceSHA256 < candidates[best].sourceSHA256) {
                best = index
            }
        }
        return best
    }

    private static func nextIndex(
        in candidates: [PhotoAnalysisEvidence],
        isSelected: [Bool],
        minimumDistance: [Int],
        checkCancellation: () throws -> Void
    ) throws -> Int {
        var best: Int?
        for index in candidates.indices where !isSelected[index] {
            try checkCancellation()
            guard let currentBest = best else {
                best = index
                continue
            }
            if ranksBefore(
                candidates[index],
                distance: minimumDistance[index],
                candidates[currentBest],
                distance: minimumDistance[currentBest]
            ) {
                best = index
            }
        }
        precondition(best != nil)
        return best!
    }

    private static func ranksBefore(
        _ lhs: PhotoAnalysisEvidence,
        distance lhsDistance: Int,
        _ rhs: PhotoAnalysisEvidence,
        distance rhsDistance: Int
    ) -> Bool {
        let lhsDistanceBin = lhsDistance / distanceEquivalenceWidth
        let rhsDistanceBin = rhsDistance / distanceEquivalenceWidth
        if lhsDistanceBin != rhsDistanceBin {
            return lhsDistanceBin > rhsDistanceBin
        }
        if lhs.qualityBucket != rhs.qualityBucket {
            return lhs.qualityBucket > rhs.qualityBucket
        }
        if lhsDistance != rhsDistance {
            return lhsDistance > rhsDistance
        }
        return lhs.sourceSHA256 < rhs.sourceSHA256
    }

    private static func l1Distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        zip(lhs, rhs).reduce(into: 0) { total, values in
            total += abs(Int(values.0) - Int(values.1))
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
