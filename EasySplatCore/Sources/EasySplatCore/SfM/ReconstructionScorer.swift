import Foundation

public struct ReconstructionScore: Sendable {
    public var registeredImages: Int
    public var totalImages: Int
    public var meanReprojectionError: Double?
}

public enum ReconstructionScorer {
    public static func parseModelAnalyzerOutput(_ text: String) -> ReconstructionScore {
        var registered = 0
        var total = 0
        var reprojection: Double?

        let lines = text.split(separator: "\n")
        for line in lines {
            if line.contains("Registered images") {
                let numbers = line.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
                if numbers.count >= 2 {
                    registered = numbers[0]
                    total = numbers[1]
                }
            }
            if line.lowercased().contains("mean reprojection error") {
                let parts = line.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                if let value = parts.compactMap(Double.init).first {
                    reprojection = value
                }
            }
        }

        return ReconstructionScore(registeredImages: registered, totalImages: total, meanReprojectionError: reprojection)
    }

    public static func isAcceptable(_ score: ReconstructionScore, mode: CaptureMode) -> Bool {
        guard score.totalImages > 0 else { return false }
        let ratio = Double(score.registeredImages) / Double(score.totalImages)
        let threshold: Double = (mode == .room) ? 0.55 : 0.65
        if ratio < threshold { return false }
        if let reproj = score.meanReprojectionError, reproj > 2.5 { return false }
        return true
    }
}
