import CryptoKit
import Foundation

enum ColmapPairPlanningError: Error, Equatable {
    case invalidPairPlan
    case pairLimitExceeded
    case disconnectedPairSchedule
    case disconnectedVerifiedGraph
    case repeatedAttempt
}

enum ColmapPairRole: String, Codable, Sendable, Equatable, Hashable {
    case local
    case retrieval
    case loopRevisit
}

struct ColmapScheduledPair: Codable, Sendable, Equatable, Hashable {
    let firstImageName: String
    let secondImageName: String
    let role: ColmapPairRole

    init(_ firstImageName: String, _ secondImageName: String, role: ColmapPairRole) {
        self.firstImageName = firstImageName
        self.secondImageName = secondImageName
        self.role = role
    }

    var line: String {
        "\(firstImageName) \(secondImageName)"
    }
}

struct ColmapPairGroup: Sendable, Equatable {
    let imageNames: [String]
    let isVideo: Bool
}

struct ColmapPairPlan: Sendable, Equatable {
    let imageNames: [String]
    let pairs: [ColmapScheduledPair]
    let sha256: String

    private init(imageNames: [String], pairs: [ColmapScheduledPair], sha256: String) {
        self.imageNames = imageNames
        self.pairs = pairs
        self.sha256 = sha256
    }

    var pairLines: [String] { pairs.map(\.line) }
    var localPairCount: Int { pairs.count { $0.role == .local } }
    var retrievalPairCount: Int { pairs.count { $0.role == .retrieval } }
    var loopRevisitPairCount: Int { pairs.count { $0.role == .loopRevisit } }

    var isConnected: Bool {
        guard !imageNames.isEmpty else { return false }
        let indexByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map {
            ($0.element, $0.offset)
        })
        var adjacency = Array(repeating: [Int](), count: imageNames.count)
        for pair in pairs {
            guard let first = indexByName[pair.firstImageName],
                  let second = indexByName[pair.secondImageName] else {
                return false
            }
            adjacency[first].append(second)
            adjacency[second].append(first)
        }
        var visited: Set<Int> = [0]
        var frontier = [0]
        while let current = frontier.popLast() {
            for neighbor in adjacency[current] where visited.insert(neighbor).inserted {
                frontier.append(neighbor)
            }
        }
        return visited.count == imageNames.count
    }

    var serializedData: Data {
        guard !pairs.isEmpty else { return Data() }
        return Data((pairLines.joined(separator: "\n") + "\n").utf8)
    }

    static func empty(imageNames: [String]) throws -> ColmapPairPlan {
        guard validImageNames(imageNames) else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        return try make(imageNames: imageNames, proposedPairs: [])
    }

    static func persisted(
        imageNames: [String],
        scheduledPairs: [ColmapScheduledPair]
    ) throws -> ColmapPairPlan {
        try Task.checkCancellation()
        guard validImageNames(imageNames) else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        let plan = try make(imageNames: imageNames, proposedPairs: scheduledPairs)
        guard plan.pairs == scheduledPairs else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        return plan
    }

    static func temporal(groups: [ColmapPairGroup], offsets: [Int]) throws -> ColmapPairPlan {
        try Task.checkCancellation()
        let imageNames = groups.flatMap(\.imageNames)
        guard validImageNames(imageNames), validOffsets(offsets) else {
            throw ColmapPairPlanningError.invalidPairPlan
        }

        var proposed: [ColmapScheduledPair] = []
        for group in groups where group.isVideo {
            for offset in offsets where offset < group.imageNames.count {
                for firstIndex in 0..<(group.imageNames.count - offset) {
                    try Task.checkCancellation()
                    proposed.append(ColmapScheduledPair(
                        group.imageNames[firstIndex],
                        group.imageNames[firstIndex + offset],
                        role: .local
                    ))
                }
            }
        }
        return try make(imageNames: imageNames, proposedPairs: proposed)
    }

    static func exhaustive(imageNames: [String]) throws -> ColmapPairPlan {
        try Task.checkCancellation()
        guard validImageNames(imageNames) else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        var proposed: [ColmapScheduledPair] = []
        if imageNames.count > 1 {
            proposed.reserveCapacity(imageNames.count * (imageNames.count - 1) / 2)
            for firstIndex in 0..<(imageNames.count - 1) {
                for secondIndex in (firstIndex + 1)..<imageNames.count {
                    try Task.checkCancellation()
                    proposed.append(ColmapScheduledPair(
                        imageNames[firstIndex],
                        imageNames[secondIndex],
                        role: .retrieval
                    ))
                }
            }
        }
        return try make(imageNames: imageNames, proposedPairs: proposed)
    }

    func addingRetrievalPairLines(
        _ lines: [String],
        pairingPolicy: ResolvedPairingPolicy
    ) throws -> ColmapPairPlan {
        try Task.checkCancellation()
        let indexByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map {
            ($0.element, $0.offset)
        })
        let isOrdered: Bool
        switch pairingPolicy {
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
            isOrdered = true
        case .unorderedRetrieval, .segmentedMixed:
            isOrdered = false
        }
        let minimumSeparation = max(12, imageNames.count / 10)
        let role: ColmapPairRole = isOrdered ? .loopRevisit : .retrieval
        var proposed = pairs
        proposed.reserveCapacity(pairs.count + lines.count)

        for line in lines {
            try Task.checkCancellation()
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let firstIndex = indexByName[String(fields[0])],
                  let secondIndex = indexByName[String(fields[1])],
                  firstIndex != secondIndex else {
                throw ColmapPairPlanningError.invalidPairPlan
            }
            if isOrdered, abs(firstIndex - secondIndex) < minimumSeparation {
                continue
            }
            proposed.append(ColmapScheduledPair(
                imageNames[min(firstIndex, secondIndex)],
                imageNames[max(firstIndex, secondIndex)],
                role: role
            ))
        }
        return try Self.make(imageNames: imageNames, proposedPairs: proposed)
    }

    func validates(_ data: Data) -> Bool {
        data == serializedData && Self.digest(data) == sha256
    }

    private static func make(
        imageNames: [String],
        proposedPairs: [ColmapScheduledPair]
    ) throws -> ColmapPairPlan {
        let indexByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map {
            ($0.element, $0.offset)
        })
        var byEdge: [Edge: ColmapScheduledPair] = [:]
        for pair in proposedPairs {
            try Task.checkCancellation()
            guard let firstIndex = indexByName[pair.firstImageName],
                  let secondIndex = indexByName[pair.secondImageName],
                  firstIndex != secondIndex else {
                throw ColmapPairPlanningError.invalidPairPlan
            }
            let edge = Edge(first: min(firstIndex, secondIndex), second: max(firstIndex, secondIndex))
            if byEdge[edge] != nil {
                continue
            }
            byEdge[edge] = ColmapScheduledPair(
                imageNames[edge.first],
                imageNames[edge.second],
                role: pair.role
            )
        }
        let pairs = byEdge.sorted { lhs, rhs in
            lhs.key.first == rhs.key.first
                ? lhs.key.second < rhs.key.second
                : lhs.key.first < rhs.key.first
        }.map(\.value)
        let data = pairs.isEmpty
            ? Data()
            : Data((pairs.map(\.line).joined(separator: "\n") + "\n").utf8)
        return ColmapPairPlan(
            imageNames: imageNames,
            pairs: pairs,
            sha256: digest(data)
        )
    }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validImageNames(_ imageNames: [String]) -> Bool {
        imageNames.count >= 2
            && Set(imageNames).count == imageNames.count
            && imageNames.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
    }

    private static func validOffsets(_ offsets: [Int]) -> Bool {
        !offsets.isEmpty
            && offsets.allSatisfy { $0 > 0 }
            && offsets == offsets.sorted()
            && Set(offsets).count == offsets.count
    }

    private struct Edge: Hashable {
        let first: Int
        let second: Int
    }
}

struct Da3RefinementPairPlan: Equatable, Sendable {
    let pairs: [String]
    let localPairCount: Int
    let loopPairCount: Int
    let sha256: String

    var serializedData: Data {
        Data((pairs.joined(separator: "\n") + "\n").utf8)
    }

    func validates(_ data: Data) -> Bool {
        data == serializedData && ColmapPairPlan.digest(data) == sha256
    }
}

struct ColmapPairEstimator {
    static func da3RefinementPairPlan(
        imageNames: [String],
        localPairs: [String],
        loopPairs: [String],
        maxPairCount: Int
    ) throws -> Da3RefinementPairPlan {
        try Task.checkCancellation()
        guard imageNames.count >= 2,
              Set(imageNames).count == imageNames.count,
              imageNames.allSatisfy({ !$0.contains(where: \.isWhitespace) }),
              maxPairCount > 0 else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        let indexByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map {
            ($0.element, $0.offset)
        })

        func normalizedEdges(_ lines: [String]) throws -> [String: (Int, Int)] {
            var edges: [String: (Int, Int)] = [:]
            for line in lines {
                try Task.checkCancellation()
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2,
                      let first = indexByName[String(fields[0])],
                      let second = indexByName[String(fields[1])],
                      first != second else {
                    throw ColmapPairPlanningError.invalidPairPlan
                }
                let lower = min(first, second)
                let upper = max(first, second)
                edges["\(imageNames[lower]) \(imageNames[upper])"] = (lower, upper)
            }
            return edges
        }

        let localEdges = try normalizedEdges(localPairs)
        let proposedLoopEdges = try normalizedEdges(loopPairs)
        var allEdges = localEdges
        for (line, edge) in proposedLoopEdges {
            allEdges[line] = edge
        }
        guard allEdges.count <= maxPairCount else {
            throw ColmapPairPlanningError.pairLimitExceeded
        }

        var adjacency = Array(repeating: Set<Int>(), count: imageNames.count)
        for edge in allEdges.values {
            try Task.checkCancellation()
            adjacency[edge.0].insert(edge.1)
            adjacency[edge.1].insert(edge.0)
        }
        var visited: Set<Int> = [0]
        var frontier = [0]
        while let current = frontier.popLast() {
            try Task.checkCancellation()
            for neighbor in adjacency[current] where visited.insert(neighbor).inserted {
                frontier.append(neighbor)
            }
        }
        guard visited.count == imageNames.count else {
            throw ColmapPairPlanningError.disconnectedPairSchedule
        }

        let pairs = allEdges.keys.sorted()
        let data = Data((pairs.joined(separator: "\n") + "\n").utf8)
        return Da3RefinementPairPlan(
            pairs: pairs,
            localPairCount: localEdges.count,
            loopPairCount: pairs.count - localEdges.count,
            sha256: ColmapPairPlan.digest(data)
        )
    }
}
