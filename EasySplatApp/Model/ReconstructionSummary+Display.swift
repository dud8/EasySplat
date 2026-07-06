import EasySplatCore
import Foundation

enum ReconstructionQuality: String {
    case strong
    case fair
    case low
}

extension ReconstructionSummary {
    /// Coarse three-bucket judgment used by the project list chip and viewer badge.
    /// Tuned to match the acceptance bar in `ReconstructionScorer.isAcceptable` so the
    /// chip never reads "strong" for a reconstruction the pipeline barely accepted —
    /// and never reads "strong" for a coverage-only summary with no quality evidence.
    var quality: ReconstructionQuality {
        let fraction = registeredFraction

        // "strong" demands proof in every measured metric. Missing reprojection error,
        // track length, or point count blocks the rating because we cannot vouch for
        // quality we did not measure.
        if fraction >= 0.9,
           let reproj = meanReprojectionError, reproj <= 1.2,
           let tracks = meanTrackLength, tracks >= 4.0,
           let points = pointCount, points > 0 {
            return .strong
        }

        // "fair" tolerates missing metrics as long as the metrics we do have are not bad.
        let reprojWithinFair = meanReprojectionError.map { $0 <= 2.5 } ?? true
        let tracksWithinFair = meanTrackLength.map { $0 >= 2.5 } ?? true
        let pointsWithinFair = pointCount.map { $0 > 0 } ?? true
        if fraction >= 0.65, reprojWithinFair, tracksWithinFair, pointsWithinFair {
            return .fair
        }
        return .low
    }

    /// True when the summary lacks measured metrics beyond raw coverage. The UI uses
    /// this to add a "metrics unavailable" hint instead of letting a green dot imply
    /// quality we did not measure.
    var hasOnlyCoverage: Bool {
        return meanReprojectionError == nil
            && pointCount == nil
            && observationCount == nil
            && meanTrackLength == nil
    }

    /// Friendly mapper label for UI; falls back to the raw identifier so a future
    /// backend can ship without an app update.
    var displayMapper: String {
        switch mapper {
        case "da3-direct":
            return "Depth Anything 3"
        case "mapanything-direct":
            return "MapAnything (direct)"
        case "mapanything-refinement":
            return "MapAnything (seed+refine)"
        case "point_triangulator+bundle_adjuster":
            return "Point triangulator + BA"
        case "point_triangulator":
            return "Point triangulator"
        case "fastvggt-refinement":
            return "FastVGGT (refined)"
        case "fastvggt-seed":
            return "FastVGGT (seed only)"
        case "vggt":
            return "VGGT"
        case "global_mapper", "global_mapper-gpu":
            return "GLOMAP (global mapper, GPU)"
        case "global_mapper-cpu":
            return "GLOMAP (global mapper, CPU)"
        case "colmap":
            return "COLMAP (mapper)"
        default:
            return mapper
        }
    }

    /// A compact, dense one-liner suitable for the project list.
    /// Example: "27/30 frames · 14k pts · 0.85 px".
    var compactSummary: String {
        var parts: [String] = []
        parts.append("\(registeredImages)/\(totalImages) frames")
        if let pointCount {
            parts.append("\(Self.compactCount(pointCount)) pts")
        }
        if let reproj = meanReprojectionError {
            parts.append(String(format: "%.2f px", reproj))
        }
        return parts.joined(separator: " · ")
    }

    /// Percent of requested frames the mapper registered, formatted for the UI.
    var registeredPercentText: String {
        let percent = registeredFraction * 100
        if percent >= 99.95 {
            return "100%"
        }
        return String(format: "%.0f%%", percent)
    }

    var pointCountText: String? {
        guard let pointCount else { return nil }
        return Self.fullCount(pointCount)
    }

    var observationCountText: String? {
        guard let observationCount else { return nil }
        return Self.fullCount(observationCount)
    }

    var meanTrackLengthText: String? {
        guard let meanTrackLength else { return nil }
        return String(format: "%.1f", meanTrackLength)
    }

    var meanReprojectionErrorText: String? {
        guard let meanReprojectionError else { return nil }
        return String(format: "%.2f px", meanReprojectionError)
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func fullCount(_ value: Int) -> String {
        return Self.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter
    }()
}
