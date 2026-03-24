import Foundation

public struct ReconstructionScore: Sendable {
    public var registeredImages: Int
    public var totalImages: Int
    public var meanReprojectionError: Double?
    public var pointCount: Int?
    public var observationCount: Int?
    public var meanTrackLength: Double?

    public init(
        registeredImages: Int,
        totalImages: Int,
        meanReprojectionError: Double?,
        pointCount: Int? = nil,
        observationCount: Int? = nil,
        meanTrackLength: Double? = nil
    ) {
        self.registeredImages = registeredImages
        self.totalImages = totalImages
        self.meanReprojectionError = meanReprojectionError
        self.pointCount = pointCount
        self.observationCount = observationCount
        self.meanTrackLength = meanTrackLength
    }
}

public enum ReconstructionScorer {
    public static func parseModelAnalyzerOutput(_ text: String) -> ReconstructionScore {
        var registered: Int?
        var total: Int?
        var reprojection: Double?
        var points: Int?
        var observations: Int?
        var meanTrackLength: Double?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineText = String(line)
            if let match = firstMatch(
                pattern: #"registered images\s*:\s*(\d+)\s*/\s*(\d+)"#,
                in: lineText,
                captureCount: 2
            ) {
                registered = Int(match[0])
                total = Int(match[1])
                continue
            }

            if let match = firstMatch(
                pattern: #"registered images\s*:\s*(\d+)\b"#,
                in: lineText,
                captureCount: 1
            ) {
                registered = Int(match[0])
            }

            if !lineText.lowercased().contains("registered images"),
               let match = firstMatch(
                   pattern: #"(?:^|\])\s*images\s*:\s*(\d+)\b"#,
                   in: lineText,
                   captureCount: 1
               ) {
                total = Int(match[0])
            }

            if let match = firstMatch(
                pattern: #"mean reprojection error\s*:\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)"#,
                in: lineText,
                captureCount: 1
            ) {
                reprojection = Double(match[0])
            }

            if let match = firstMatch(
                pattern: #"(?:^|\])\s*points\s*:\s*(\d+)\b"#,
                in: lineText,
                captureCount: 1
            ) {
                points = Int(match[0])
            }

            if let match = firstMatch(
                pattern: #"observations\s*:\s*(\d+)\b"#,
                in: lineText,
                captureCount: 1
            ) {
                observations = Int(match[0])
            }

            if let match = firstMatch(
                pattern: #"mean track length\s*:\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)"#,
                in: lineText,
                captureCount: 1
            ) {
                meanTrackLength = Double(match[0])
            }
        }

        let resolvedRegistered = registered ?? 0
        let resolvedTotal = total ?? resolvedRegistered
        return ReconstructionScore(
            registeredImages: resolvedRegistered,
            totalImages: resolvedTotal,
            meanReprojectionError: reprojection,
            pointCount: points,
            observationCount: observations,
            meanTrackLength: meanTrackLength
        )
    }

    public static func isAcceptable(_ score: ReconstructionScore, mode: CaptureMode) -> Bool {
        guard score.totalImages > 0 else { return false }
        let ratio = Double(score.registeredImages) / Double(score.totalImages)
        let threshold: Double = (mode == .room) ? 0.55 : 0.65
        if ratio < threshold { return false }
        if let reproj = score.meanReprojectionError, reproj > 2.5 { return false }
        if let points = score.pointCount, points <= 0 { return false }
        if let observations = score.observationCount, observations <= 0 { return false }
        if let meanTrackLength = score.meanTrackLength, meanTrackLength <= 0 { return false }
        return true
    }

    public static func summary(_ score: ReconstructionScore) -> String {
        let ratio = score.totalImages > 0 ? Double(score.registeredImages) / Double(score.totalImages) : 0.0
        let percent = ratio * 100.0
        let percentText = String(format: "%.1f", percent)
        let reprojText: String
        if let reproj = score.meanReprojectionError {
            reprojText = String(format: "%.2f", reproj)
        } else {
            reprojText = "n/a"
        }
        var summary = "registered \(score.registeredImages)/\(score.totalImages) (\(percentText)%), mean reprojection error \(reprojText)"
        if let points = score.pointCount, let observations = score.observationCount {
            summary += ", points \(points), observations \(observations)"
        }
        if let meanTrackLength = score.meanTrackLength {
            summary += ", mean track length \(String(format: "%.2f", meanTrackLength))"
        }
        return summary
    }

    private static func firstMatch(pattern: String, in text: String, captureCount: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        var captures: [String] = []
        captures.reserveCapacity(captureCount)
        for index in 1...captureCount {
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let swiftRange = Range(captureRange, in: text) else {
                return nil
            }
            captures.append(String(text[swiftRange]))
        }
        return captures
    }
}
