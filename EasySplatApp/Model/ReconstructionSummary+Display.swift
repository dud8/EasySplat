import EasySplatCore
import Foundation

extension ReconstructionSummary {
    var displayMapper: String {
        switch mapper {
        case "da3-refined":
            return "Depth Anything 3 + refinement"
        case "point_triangulator+bundle_adjuster":
            return "Point triangulator + BA"
        case "point_triangulator":
            return "Point triangulator"
        case "colmap":
            return "COLMAP mapper"
        default:
            return mapper
        }
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
        guard let reproj = meanReprojectionError else { return nil }
        return String(format: "%.2f px", reproj)
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
