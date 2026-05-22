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
    static func parseSparseTextModel(at sparseModelURL: URL, expectedTotalImages: Int? = nil) -> ReconstructionScore? {
        let imagesTxt = sparseModelURL.appendingPathComponent("images.txt")
        let pointsTxt = sparseModelURL.appendingPathComponent("points3D.txt")

        var registeredImages: Int?
        if let text = try? String(contentsOf: imagesTxt, encoding: .utf8) {
            registeredImages = text
                .components(separatedBy: .newlines)
                .filter { isColmapImagePoseRow($0) }
                .count
        }

        var pointCount: Int?
        var observationCount = 0
        if let text = try? String(contentsOf: pointsTxt, encoding: .utf8) {
            var points = 0
            var observations = 0
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 8 else { continue }
                points += 1
                observations += max(0, (parts.count - 8) / 2)
            }
            pointCount = points
            observationCount = observations
        }

        let resolvedRegisteredImages = registeredImages ?? 0
        guard resolvedRegisteredImages > 0 || pointCount != nil else {
            return nil
        }

        let resolvedTotalImages = max(expectedTotalImages ?? resolvedRegisteredImages, resolvedRegisteredImages)
        let meanTrackLength: Double?
        let resolvedObservationCount: Int?
        if let pointCount, pointCount > 0, observationCount > 0 {
            resolvedObservationCount = observationCount
            meanTrackLength = Double(observationCount) / Double(pointCount)
        } else {
            resolvedObservationCount = nil
            meanTrackLength = nil
        }

        return ReconstructionScore(
            registeredImages: resolvedRegisteredImages,
            totalImages: resolvedTotalImages,
            meanReprojectionError: nil,
            pointCount: pointCount,
            observationCount: resolvedObservationCount,
            meanTrackLength: meanTrackLength
        )
    }

    private static let registeredImagesPairRegex = try! NSRegularExpression(
        pattern: #"registered images\s*:\s*(\d+)\s*/\s*(\d+)"#,
        options: [.caseInsensitive]
    )
    private static let registeredImagesSingleRegex = try! NSRegularExpression(
        pattern: #"registered images\s*:\s*(\d+)\b"#,
        options: [.caseInsensitive]
    )
    private static let imagesTotalRegex = try! NSRegularExpression(
        pattern: #"(?:^|\])\s*images\s*:\s*(\d+)\b"#,
        options: [.caseInsensitive]
    )
    private static let reprojectionRegex = try! NSRegularExpression(
        pattern: #"mean reprojection error\s*:\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)"#,
        options: [.caseInsensitive]
    )
    private static let pointsRegex = try! NSRegularExpression(
        pattern: #"(?:^|\])\s*points\s*:\s*(\d+)\b"#,
        options: [.caseInsensitive]
    )
    private static let observationsRegex = try! NSRegularExpression(
        pattern: #"observations\s*:\s*(\d+)\b"#,
        options: [.caseInsensitive]
    )
    private static let trackLengthRegex = try! NSRegularExpression(
        pattern: #"mean track length\s*:\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)"#,
        options: [.caseInsensitive]
    )

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
            if let match = firstMatch(regex: registeredImagesPairRegex, in: lineText, captureCount: 2) {
                registered = Int(match[0])
                total = Int(match[1])
                continue
            }

            if let match = firstMatch(regex: registeredImagesSingleRegex, in: lineText, captureCount: 1) {
                registered = Int(match[0])
            }

            if !lineText.lowercased().contains("registered images"),
               let match = firstMatch(regex: imagesTotalRegex, in: lineText, captureCount: 1) {
                total = Int(match[0])
            }

            if let match = firstMatch(regex: reprojectionRegex, in: lineText, captureCount: 1) {
                reprojection = Double(match[0])
            }

            if let match = firstMatch(regex: pointsRegex, in: lineText, captureCount: 1) {
                points = Int(match[0])
            }

            if let match = firstMatch(regex: observationsRegex, in: lineText, captureCount: 1) {
                observations = Int(match[0])
            }

            if let match = firstMatch(regex: trackLengthRegex, in: lineText, captureCount: 1) {
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

    public static func applyingExpectedTotalImages(
        _ score: ReconstructionScore,
        expectedTotalImages: Int
    ) -> ReconstructionScore {
        guard expectedTotalImages > 0 else { return score }
        return ReconstructionScore(
            registeredImages: score.registeredImages,
            totalImages: max(score.totalImages, expectedTotalImages),
            meanReprojectionError: score.meanReprojectionError,
            pointCount: score.pointCount,
            observationCount: score.observationCount,
            meanTrackLength: score.meanTrackLength
        )
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
        if let points = score.pointCount {
            summary += ", points \(points)"
            if let observations = score.observationCount {
                summary += ", observations \(observations)"
            }
        }
        if let meanTrackLength = score.meanTrackLength {
            summary += ", mean track length \(String(format: "%.2f", meanTrackLength))"
        }
        return summary
    }

    private static func firstMatch(regex: NSRegularExpression, in text: String, captureCount: Int) -> [String]? {
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

    private static func isColmapImagePoseRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        let parts = trimmed.split(maxSplits: 9, whereSeparator: \.isWhitespace)
        guard parts.count >= 10 else { return false }
        guard Int(parts[0]) != nil else { return false }
        guard parts[1..<9].allSatisfy({ Double(String($0)) != nil }) else { return false }
        guard Int(parts[8]) != nil else { return false }
        return String(parts[9]).rangeOfCharacter(from: .letters) != nil
    }
}
