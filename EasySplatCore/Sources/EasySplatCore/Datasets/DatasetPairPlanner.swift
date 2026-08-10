import Foundation

/// Builds a matching pair list from imported camera poses. Poses carry
/// stronger connectivity signal than appearance retrieval: two cameras that
/// are close together and look in compatible directions almost certainly
/// share features, regardless of capture order. The planner selects, for
/// each image, its most plausible co-visible neighbors, and the resulting
/// pair list feeds `matches_importer` exactly like the retrieval-derived
/// plans do.
public enum DatasetPairPlanner {
    public struct Camera: Sendable, Equatable {
        public var name: String
        public var pose: DatasetPoseConvention.ColmapPose

        public init(name: String, pose: DatasetPoseConvention.ColmapPose) {
            self.name = name
            self.pose = pose
        }
    }

    /// Neighbor count matching the retrieval path's default so imported
    /// datasets produce comparably dense match graphs.
    public static let defaultNeighborCount = 8

    /// Below this many images, every pair is cheap enough to match
    /// exhaustively and graph connectivity is too precious to prune.
    public static let exhaustiveThreshold = 60

    /// Pairs for the given cameras, sorted and deduplicated, each pair's
    /// names in lexicographic order. Deterministic for a given input.
    public static func pairs(
        for cameras: [Camera],
        neighborCount: Int = defaultNeighborCount
    ) -> [(String, String)] {
        guard cameras.count > 1 else { return [] }

        if cameras.count <= exhaustiveThreshold {
            var result: [(String, String)] = []
            let names = cameras.map(\.name).sorted()
            for i in 0..<names.count {
                for j in (i + 1)..<names.count {
                    result.append((names[i], names[j]))
                }
            }
            return result
        }

        struct Placement {
            let name: String
            let center: SIMD3<Double>
            let forward: SIMD3<Double>
        }
        let placements = cameras.map { camera in
            Placement(
                name: camera.name,
                center: cameraCenter(of: camera.pose),
                forward: viewDirection(of: camera.pose)
            )
        }

        // Scale-free distance normalization: score distances relative to the
        // scene's typical nearest-neighbor spacing so the planner behaves
        // identically for millimeter- and kilometer-scale reconstructions.
        let typicalSpacing = medianNearestNeighborDistance(of: placements.map(\.center))

        var pairSet = Set<PairKey>()
        for (index, placement) in placements.enumerated() {
            var scored: [(score: Double, name: String)] = []
            scored.reserveCapacity(placements.count - 1)
            for (otherIndex, other) in placements.enumerated() where otherIndex != index {
                let distance = length(other.center - placement.center)
                let alignment = dot(placement.forward, other.forward)
                // Distance dominates; opposing view directions (alignment
                // near -1) are penalized because two cameras looking at each
                // other's backs rarely share features. The blend keeps
                // orbit-style captures (nearby, converging views) connected.
                let normalized = typicalSpacing > 0 ? distance / typicalSpacing : distance
                let score = normalized * (1.5 - 0.5 * alignment)
                scored.append((score, other.name))
            }
            scored.sort { ($0.score, $0.name) < ($1.score, $1.name) }
            for neighbor in scored.prefix(max(1, neighborCount)) {
                pairSet.insert(PairKey(placement.name, neighbor.name))
            }
        }

        return pairSet
            .map { ($0.first, $0.second) }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    /// Renders pairs in the `matches_importer --match_list_path` format:
    /// one pair per line, names separated by a single space.
    public static func matchListText(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0) \($0.1)" }.joined(separator: "\n") + (pairs.isEmpty ? "" : "\n")
    }

    private struct PairKey: Hashable {
        let first: String
        let second: String

        init(_ a: String, _ b: String) {
            if a <= b {
                first = a
                second = b
            } else {
                first = b
                second = a
            }
        }
    }

    /// Camera center C = -R^T * t for a world-to-camera pose.
    static func cameraCenter(of pose: DatasetPoseConvention.ColmapPose) -> SIMD3<Double> {
        let r = rotationMatrix(of: pose)
        let t = SIMD3(pose.tx, pose.ty, pose.tz)
        return SIMD3(
            -(r[0].x * t.x + r[1].x * t.y + r[2].x * t.z),
            -(r[0].y * t.x + r[1].y * t.y + r[2].y * t.z),
            -(r[0].z * t.x + r[1].z * t.y + r[2].z * t.z)
        )
    }

    /// The camera's +Z axis (COLMAP forward) expressed in world coordinates:
    /// the third row of R transposed.
    static func viewDirection(of pose: DatasetPoseConvention.ColmapPose) -> SIMD3<Double> {
        let r = rotationMatrix(of: pose)
        return SIMD3(r[2].x, r[2].y, r[2].z)
    }

    private static func rotationMatrix(of pose: DatasetPoseConvention.ColmapPose) -> [SIMD3<Double>] {
        let (w, x, y, z) = (pose.qw, pose.qx, pose.qy, pose.qz)
        return [
            SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
            SIMD3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
            SIMD3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)),
        ]
    }

    private static func medianNearestNeighborDistance(of centers: [SIMD3<Double>]) -> Double {
        guard centers.count > 1 else { return 0 }
        var nearest = [Double](repeating: .greatestFiniteMagnitude, count: centers.count)
        for i in 0..<centers.count {
            for j in (i + 1)..<centers.count {
                let distance = length(centers[j] - centers[i])
                if distance < nearest[i] { nearest[i] = distance }
                if distance < nearest[j] { nearest[j] = distance }
            }
        }
        let sorted = nearest.sorted()
        return sorted[sorted.count / 2]
    }

    private static func length(_ v: SIMD3<Double>) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
