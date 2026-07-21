import Foundation

enum VideoClipIdentityError: Error, Equatable, Sendable {
    case invalidSourceSHA256(index: Int)
    case duplicateSourceSHA256(String)
}

struct VideoClipIdentity: Equatable, Sendable {
    let sourceIndex: Int
    let sourceSHA256: String
    let groupID: String
}

enum VideoClipIdentityResolver {
    static func resolve(
        sourceSHA256s: [String],
        pairingPolicy: ResolvedPairingPolicy
    ) throws -> [VideoClipIdentity] {
        var seen = Set<String>()
        var identities: [VideoClipIdentity] = []
        identities.reserveCapacity(sourceSHA256s.count)
        for (index, digest) in sourceSHA256s.enumerated() {
            guard isSHA256(digest) else {
                throw VideoClipIdentityError.invalidSourceSHA256(index: index)
            }
            guard seen.insert(digest).inserted else {
                throw VideoClipIdentityError.duplicateSourceSHA256(digest)
            }
            identities.append(VideoClipIdentity(
                sourceIndex: index,
                sourceSHA256: digest,
                groupID: groupID(
                    sourceSHA256: digest,
                    sourceIndex: index,
                    pairingPolicy: pairingPolicy
                )
            ))
        }
        if pairingPolicy.canonicalizesVideoClipOrder {
            identities.sort { $0.sourceSHA256 < $1.sourceSHA256 }
        }
        return identities
    }

    private static func groupID(
        sourceSHA256: String,
        sourceIndex: Int,
        pairingPolicy: ResolvedPairingPolicy
    ) -> String {
        if pairingPolicy.canonicalizesVideoClipOrder {
            return "video_sha256_\(sourceSHA256)"
        }
        return String(format: "video_%03d", sourceIndex)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 97 && scalar.value <= 102)
            }
    }
}

extension ResolvedPairingPolicy {
    var canonicalizesVideoClipOrder: Bool {
        switch self {
        case .unorderedRetrieval, .segmentedMixed:
            true
        case .orderedContinuous,
             .orderedOrbit,
             .orderedWalkthrough,
             .orderedLargeArea:
            false
        }
    }
}
