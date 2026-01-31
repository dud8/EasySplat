import Foundation

public struct FrameGroup: Sendable {
    public let id: String
    public let fileNames: [String]
    public let isVideo: Bool

    public init(id: String, fileNames: [String], isVideo: Bool) {
        self.id = id
        self.fileNames = fileNames
        self.isVideo = isVideo
    }
}

public enum PairListBuilder {
    public static func buildPairs(
        groups: [FrameGroup],
        overlap: Int,
        stride: Int,
        bridgeCount: Int
    ) -> [(String, String)] {
        guard overlap > 0, stride > 0 else { return [] }
        var pairs: [(String, String)] = []
        var seen = Set<String>()

        func addPair(_ a: String, _ b: String) {
            guard a != b else { return }
            let key = a < b ? "\(a)|\(b)" : "\(b)|\(a)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            pairs.append((a, b))
        }

        for group in groups {
            let files = group.fileNames
            guard files.count > 1 else { continue }
            for i in 0..<files.count {
                for step in 1...overlap {
                    let j = i + step * stride
                    if j < files.count {
                        addPair(files[i], files[j])
                    }
                }
            }
        }

        if bridgeCount > 0, groups.count > 1 {
            for index in 0..<(groups.count - 1) {
                let left = groups[index]
                let right = groups[index + 1]
                guard left.isVideo, right.isVideo else { continue }
                let leftTail = left.fileNames.suffix(bridgeCount)
                let rightHead = right.fileNames.prefix(bridgeCount)
                for a in leftTail {
                    for b in rightHead {
                        addPair(a, b)
                    }
                }
            }
        }

        return pairs
    }

    public static func writePairs(_ pairs: [(String, String)], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = pairs.map { "\($0.0) \($0.1)" }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
