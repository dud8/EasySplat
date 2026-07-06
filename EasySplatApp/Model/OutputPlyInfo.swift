import EasySplatCore
import Foundation

/// Lightweight readout of the final exported splat: vertex count + file size +
/// PLY format. Used by the viewer to show "12,453 splats · 4.2 MB" without
/// re-reading the file on every redraw.
struct OutputPlyInfo: Equatable {
    var vertexCount: Int
    var sizeBytes: Int64
    var format: String

    static func load(from url: URL) -> OutputPlyInfo? {
        guard let header = ProjectArtifactValidator.readPlyHeader(at: url) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return OutputPlyInfo(vertexCount: header.vertexCount, sizeBytes: size, format: header.format)
    }

    var splatCountText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        let count = formatter.string(from: NSNumber(value: vertexCount)) ?? "\(vertexCount)"
        return "\(count) splats"
    }

    var sizeText: String? {
        guard sizeBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: sizeBytes)
    }

    var formatLabel: String? {
        switch format {
        case "ascii":
            return "ASCII PLY"
        case "binary_little_endian":
            return "binary PLY"
        case "binary_big_endian":
            return "binary PLY (BE)"
        case "":
            return nil
        default:
            return format
        }
    }
}
