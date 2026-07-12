import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum ColmapPairPlanningError: Error, Equatable {
    case invalidDescriptors
    case invalidPairPlan
    case pairLimitExceeded
    case disconnectedGraph
    case unreadableImage(String)
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
        data == serializedData && Self.digest(data) == sha256
    }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ColmapPairEstimator {
    static func expectedExhaustivePairs(imageCount: Int) -> Int {
        guard imageCount > 1 else { return 0 }
        return imageCount * (imageCount - 1) / 2
    }

    static func expectedSequentialPairs(imageCount: Int, overlap: Int) -> Int {
        guard imageCount > 1 else { return 0 }
        let k = max(1, overlap)
        return (0..<imageCount).reduce(0) { acc, i in
            acc + max(0, min(k, imageCount - 1 - i))
        }
    }

    static func imageDescriptors(for imageURLs: [URL]) throws -> [[Double]] {
        try imageURLs.map { url in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 32,
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary) else {
                throw ColmapPairPlanningError.unreadableImage(url.lastPathComponent)
            }

            let width = 16
            let height = 16
            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: &pixels,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                throw ColmapPairPlanningError.unreadableImage(url.lastPathComponent)
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            try Task.checkCancellation()

            var luminance = [Double](repeating: 0, count: width * height)
            var histograms = [Double](repeating: 0, count: 24)
            for pixelIndex in 0..<(width * height) {
                if pixelIndex.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let offset = pixelIndex * bytesPerPixel
                let red = Double(pixels[offset]) / 255.0
                let green = Double(pixels[offset + 1]) / 255.0
                let blue = Double(pixels[offset + 2]) / 255.0
                luminance[pixelIndex] = red * 0.2126 + green * 0.7152 + blue * 0.0722
                for (channel, value) in [red, green, blue].enumerated() {
                    let bin = min(7, Int(value * 8.0))
                    histograms[channel * 8 + bin] += 1.0 / Double(width * height)
                }
            }

            let mean = luminance.reduce(0, +) / Double(luminance.count)
            let variance = luminance.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luminance.count)
            let deviation = max(sqrt(variance), 0.05)
            var descriptor = luminance.map { (($0 - mean) / deviation) * 0.5 }
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let right = y * width + min(width - 1, x + 1)
                    descriptor.append((luminance[right] - luminance[index]) * 0.25)
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let below = min(height - 1, y + 1) * width + x
                    descriptor.append((luminance[below] - luminance[index]) * 0.25)
                }
            }
            descriptor.append(contentsOf: histograms)
            let norm = sqrt(descriptor.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, norm > Double.ulpOfOne else {
                throw ColmapPairPlanningError.unreadableImage(url.lastPathComponent)
            }
            return descriptor.map { $0 / norm }
        }
    }

    static func boundedRetrievalPairs(
        imageNames: [String],
        descriptors: [[Double]],
        maxNeighbors: Int = 8,
        minimumSimilarity: Double = 0.40
    ) throws -> [String] {
        try Task.checkCancellation()
        let normalized = try validatedDescriptors(
            imageNames: imageNames,
            descriptors: descriptors,
            maxNeighbors: maxNeighbors,
            minimumSimilarity: minimumSimilarity
        )
        var adjacency = Array(repeating: Set<Int>(), count: imageNames.count)
        var pairs = Set<String>()
        for index in imageNames.indices {
            try Task.checkCancellation()
            var candidates: [(index: Int, similarity: Double)] = []
            for candidate in imageNames.indices where candidate != index {
                if candidate.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let score = similarity(normalized[index], normalized[candidate])
                if score >= minimumSimilarity {
                    candidates.append((candidate, score))
                }
            }
            candidates.sort {
                $0.similarity == $1.similarity
                    ? $0.index < $1.index
                    : $0.similarity > $1.similarity
            }
            for candidate in candidates.prefix(maxNeighbors).map(\.index) {
                adjacency[index].insert(candidate)
                adjacency[candidate].insert(index)
                pairs.insert(pairLine(first: index, second: candidate, names: imageNames))
            }
        }

        var visited: Set<Int> = imageNames.isEmpty ? [] : [0]
        var frontier = imageNames.isEmpty ? [] : [0]
        var frontierIndex = 0
        while frontierIndex < frontier.count {
            try Task.checkCancellation()
            let current = frontier[frontierIndex]
            frontierIndex += 1
            for neighbor in adjacency[current].sorted() where visited.insert(neighbor).inserted {
                frontier.append(neighbor)
            }
        }
        guard visited.count == imageNames.count else {
            throw ColmapPairPlanningError.disconnectedGraph
        }
        return pairs.sorted()
    }

    static func orderedLoopPairs(
        imageNames: [String],
        descriptors: [[Double]],
        minimumSeparation: Int,
        maxNeighbors: Int = 2,
        minimumSimilarity: Double = 0.82
    ) throws -> [String] {
        try Task.checkCancellation()
        let normalized = try validatedDescriptors(
            imageNames: imageNames,
            descriptors: descriptors,
            maxNeighbors: maxNeighbors,
            minimumSimilarity: minimumSimilarity
        )
        let separation = max(2, minimumSeparation)
        var pairs = Set<String>()
        for index in imageNames.indices {
            try Task.checkCancellation()
            var candidates: [(index: Int, similarity: Double)] = []
            for candidate in imageNames.indices where abs(candidate - index) >= separation {
                if candidate.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let score = similarity(normalized[index], normalized[candidate])
                if score >= minimumSimilarity {
                    candidates.append((candidate, score))
                }
            }
            candidates.sort {
                $0.similarity == $1.similarity
                    ? $0.index < $1.index
                    : $0.similarity > $1.similarity
            }
            for candidate in candidates.prefix(maxNeighbors).map(\.index) {
                pairs.insert(pairLine(first: index, second: candidate, names: imageNames))
            }
        }

        if imageNames.count > separation,
           similarity(normalized[0], normalized[imageNames.count - 1]) >= minimumSimilarity {
            pairs.insert(pairLine(first: 0, second: imageNames.count - 1, names: imageNames))
        }
        return pairs.sorted()
    }

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
        let indexByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map { ($0.element, $0.offset) })

        func normalizedEdges(_ lines: [String]) throws -> [String: (Int, Int)] {
            var edges: [String: (Int, Int)] = [:]
            for line in lines {
                try Task.checkCancellation()
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count == 2,
                      let first = indexByName[String(fields[0])],
                      let second = indexByName[String(fields[1])],
                      first != second else {
                    throw ColmapPairPlanningError.invalidPairPlan
                }
                let normalized = pairLine(first: first, second: second, names: imageNames)
                edges[normalized] = (min(first, second), max(first, second))
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
        for (_, edge) in allEdges {
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
            throw ColmapPairPlanningError.disconnectedGraph
        }

        let pairs = allEdges.keys.sorted()
        let data = Data((pairs.joined(separator: "\n") + "\n").utf8)
        return Da3RefinementPairPlan(
            pairs: pairs,
            localPairCount: localEdges.count,
            loopPairCount: allEdges.keys.filter { localEdges[$0] == nil }.count,
            sha256: Da3RefinementPairPlan.digest(data)
        )
    }

    private static func validatedDescriptors(
        imageNames: [String],
        descriptors: [[Double]],
        maxNeighbors: Int,
        minimumSimilarity: Double
    ) throws -> [[Double]] {
        guard imageNames.count == descriptors.count,
              !imageNames.isEmpty,
              Set(imageNames).count == imageNames.count,
              maxNeighbors > 0,
              minimumSimilarity.isFinite,
              (-1.0...1.0).contains(minimumSimilarity),
              let dimension = descriptors.first?.count,
              dimension > 0,
              descriptors.allSatisfy({ $0.count == dimension && $0.allSatisfy(\.isFinite) }) else {
            throw ColmapPairPlanningError.invalidDescriptors
        }
        return try descriptors.map { descriptor in
            try Task.checkCancellation()
            let norm = sqrt(descriptor.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, norm > Double.ulpOfOne else {
                throw ColmapPairPlanningError.invalidDescriptors
            }
            return descriptor.map { $0 / norm }
        }
    }

    private static func similarity(_ first: [Double], _ second: [Double]) -> Double {
        var result = 0.0
        vDSP_dotprD(first, 1, second, 1, &result, vDSP_Length(first.count))
        return result
    }

    private static func pairLine(first: Int, second: Int, names: [String]) -> String {
        let lower = min(first, second)
        let upper = max(first, second)
        return "\(names[lower]) \(names[upper])"
    }
}
