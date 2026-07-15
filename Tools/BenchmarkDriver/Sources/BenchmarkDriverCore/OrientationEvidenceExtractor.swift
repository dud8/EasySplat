import CryptoKit
import Darwin
import Foundation

public enum OrientationBenchmarkStatus: String, Codable, Sendable {
    case verified
    case axisAlignedSignUnverified = "axis_aligned_sign_unverified"
    case unresolved
}

public struct OrientationBenchmarkEvidence: Codable, Equatable, Sendable {
    public let orientationStatus: OrientationBenchmarkStatus
    public let alignmentSupportCount: Int
    public let candidateSourceToGroundTruthWXYZ: [Double]
    public let alignmentMedianResidualDegrees: Double
    public let alignmentP90ResidualDegrees: Double
    public let orientationPhysicalUpErrorDegrees: Double?
    public let orientationSignCorrect: Bool?

    enum CodingKeys: String, CodingKey {
        case orientationStatus = "orientation_status"
        case alignmentSupportCount = "alignment_support_count"
        case candidateSourceToGroundTruthWXYZ = "candidate_source_to_ground_truth_wxyz"
        case alignmentMedianResidualDegrees = "alignment_median_residual_degrees"
        case alignmentP90ResidualDegrees = "alignment_p90_residual_degrees"
        case orientationPhysicalUpErrorDegrees = "orientation_physical_up_error_degrees"
        case orientationSignCorrect = "orientation_sign_correct"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orientationStatus, forKey: .orientationStatus)
        try container.encode(alignmentSupportCount, forKey: .alignmentSupportCount)
        try container.encode(
            candidateSourceToGroundTruthWXYZ,
            forKey: .candidateSourceToGroundTruthWXYZ
        )
        try container.encode(
            alignmentMedianResidualDegrees,
            forKey: .alignmentMedianResidualDegrees
        )
        try container.encode(
            alignmentP90ResidualDegrees,
            forKey: .alignmentP90ResidualDegrees
        )
        try encodeNullable(
            orientationPhysicalUpErrorDegrees,
            in: &container,
            forKey: .orientationPhysicalUpErrorDegrees
        )
        try encodeNullable(orientationSignCorrect, in: &container, forKey: .orientationSignCorrect)
    }

    private func encodeNullable<Value: Encodable>(
        _ value: Value?,
        in container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public enum OrientationEvidenceExtractor {
    private static let maximumManifestBytes = 16 * 1_024 * 1_024
    private static let maximumLabelBytes = 1 * 1_024 * 1_024
    private static let maximumGroundTruthBytes = 64 * 1_024 * 1_024
    private static let maximumCandidateImagesBytes = 2 * 1_024 * 1_024 * 1_024
    private static let maximumCandidateLineBytes = 64 * 1_024 * 1_024
    private static let huberCutoffDegrees = 3.0
    private static let maximumMedianAlignmentResidualDegrees = 1.0
    private static let maximumP90AlignmentResidualDegrees = 3.0

    public static func extract(
        geometryManifestURL: URL,
        candidateImagesURL: URL,
        groundTruthPosesURL: URL,
        expectedGroundTruthPosesSHA256: String,
        orientationLabelURL: URL,
        expectedOrientationLabelSHA256: String
    ) throws -> OrientationBenchmarkEvidence {
        let manifestData = try readRegularFile(
            geometryManifestURL,
            label: "geometry manifest",
            maximumBytes: maximumManifestBytes
        )
        let labelData = try readRegularFile(
            orientationLabelURL,
            label: "orientation label",
            maximumBytes: maximumLabelBytes
        )
        let groundTruthData = try readRegularFile(
            groundTruthPosesURL,
            label: "ground-truth poses",
            maximumBytes: maximumGroundTruthBytes
        )
        guard expectedOrientationLabelSHA256 == sha256(labelData) else {
            throw invalid("The orientation-label digest does not match its pinned reference.")
        }
        guard expectedGroundTruthPosesSHA256 == sha256(groundTruthData) else {
            throw invalid("The ground-truth pose digest does not match its pinned reference.")
        }
        try validateLabelObject(labelData)
        try validateGroundTruthPoseObject(groundTruthData)

        let decoder = JSONDecoder()
        let manifest: GeometryManifest
        let label: PhysicalUpLabel
        let groundTruth: GroundTruthPoseFile
        do {
            manifest = try decoder.decode(GeometryManifest.self, from: manifestData)
            label = try decoder.decode(PhysicalUpLabel.self, from: labelData)
            groundTruth = try decoder.decode(GroundTruthPoseFile.self, from: groundTruthData)
        } catch {
            throw invalid("The orientation benchmark input is not valid JSON: \(error.localizedDescription)")
        }
        try validateManifestContract(manifest)
        try validateGroundTruthContract(groundTruth)
        guard label.schemaVersion == 1, label.coordinateSpace == "ground_truth_world" else {
            throw invalid("The orientation label must use schema 1 ground-truth-world coordinates.")
        }
        let physicalUpInGroundTruth = try Vector(
            label.physicalUp,
            label: "physical-up label"
        ).normalized(label: "physical-up label")

        let candidate = try scanCandidateImages(candidateImagesURL)
        guard candidate.digest == manifest.modelHashes["images.txt"] else {
            throw invalid("The candidate images.txt digest does not match the geometry manifest.")
        }
        let groundTruthRotations = try groundTruthRotationMap(groundTruth.poses)
        let sharedNames = Set(candidate.rotations.keys)
            .intersection(groundTruthRotations.keys)
            .sorted()
        guard sharedNames.count >= 8 else {
            throw invalid("The orientation benchmark requires at least eight shared camera poses.")
        }
        var alignmentSamples = try sharedNames.map { name in
            try groundTruthRotations[name]!.inverse.composed(with: candidate.rotations[name]!)
        }
        alignmentSamples.sort(by: Quaternion.lexicographicallyPrecedes)
        let alignment = try robustAlignment(alignmentSamples)

        let status = try benchmarkStatus(manifest.canonicalOrientation.status)
        if status == .unresolved {
            guard manifest.canonicalOrientation.sourceToCanonicalQuaternionWXYZ == nil else {
                throw invalid("An unresolved orientation cannot publish a canonical quaternion.")
            }
            return makeEvidence(
                status: status,
                alignment: alignment,
                physicalError: nil,
                signCorrect: nil
            )
        }

        guard let rawCanonical = manifest.canonicalOrientation.sourceToCanonicalQuaternionWXYZ else {
            throw invalid("A resolved orientation must publish a source-to-canonical quaternion.")
        }
        let sourceToCanonical = try Quaternion(
            rawCanonical,
            label: "source-to-canonical quaternion",
            requireUnit: true,
            requireCanonicalSign: true
        )
        let physicalUpInCandidateSource = alignment.rotation.inverse.rotated(
            physicalUpInGroundTruth
        )
        let canonicalPhysicalUp = try sourceToCanonical
            .rotated(physicalUpInCandidateSource)
            .normalized(label: "canonical physical-up direction")
        let directedCosine = min(1, max(-1, canonicalPhysicalUp.y))
        let directedError = acos(directedCosine) * 180 / .pi
        let error = status == .verified
            ? directedError
            : acos(abs(directedCosine)) * 180 / .pi

        return makeEvidence(
            status: status,
            alignment: alignment,
            physicalError: error,
            signCorrect: status == .verified ? directedCosine > 1e-12 : nil
        )
    }

    private static func makeEvidence(
        status: OrientationBenchmarkStatus,
        alignment: RotationAlignment,
        physicalError: Double?,
        signCorrect: Bool?
    ) -> OrientationBenchmarkEvidence {
        OrientationBenchmarkEvidence(
            orientationStatus: status,
            alignmentSupportCount: alignment.supportCount,
            candidateSourceToGroundTruthWXYZ: alignment.rotation.array,
            alignmentMedianResidualDegrees: alignment.medianResidualDegrees,
            alignmentP90ResidualDegrees: alignment.p90ResidualDegrees,
            orientationPhysicalUpErrorDegrees: physicalError,
            orientationSignCorrect: signCorrect
        )
    }

    private static func validateManifestContract(_ manifest: GeometryManifest) throws {
        guard manifest.schemaVersion == 4 else {
            throw invalid("The geometry manifest uses an unsupported schema.")
        }
        guard manifest.poseConvention == "world-to-camera",
              manifest.quaternionOrder == "wxyz",
              manifest.handedness == "right-handed" else {
            throw invalid(
                "The geometry manifest must use right-handed world-to-camera wxyz poses."
            )
        }
        guard Set(manifest.modelHashes.keys) == ["cameras.txt", "images.txt", "points3D.txt"],
              manifest.modelHashes.values.allSatisfy(isSHA256) else {
            throw invalid("The geometry manifest model hashes are invalid.")
        }
    }

    private static func validateGroundTruthContract(_ file: GroundTruthPoseFile) throws {
        guard file.schemaVersion == 1,
              file.poseConvention == "world_to_camera",
              file.quaternionOrder == "wxyz",
              file.handedness == "right_handed",
              file.coordinateSpace == "ground_truth_world",
              file.imageCoordinates == "normalized_display_pixels" else {
            throw invalid(
                "Ground-truth poses must use schema 1 world_to_camera wxyz right_handed "
                    + "ground_truth_world poses in normalized_display_pixels."
            )
        }
    }

    private static func groundTruthRotationMap(
        _ records: [GroundTruthPoseRecord]
    ) throws -> [String: Quaternion] {
        var rotations: [String: Quaternion] = [:]
        rotations.reserveCapacity(records.count)
        for record in records {
            try validateImageName(record.imageName, label: "ground-truth pose")
            guard rotations[record.imageName] == nil else {
                throw invalid("The ground-truth poses contain a duplicate image name.")
            }
            rotations[record.imageName] = try Quaternion(
                record.rcwWXYZ,
                label: "ground-truth Rcw quaternion",
                requireUnit: true,
                requireCanonicalSign: false
            )
        }
        return rotations
    }

    private static func robustAlignment(_ rotations: [Quaternion]) throws -> RotationAlignment {
        var weights = [Double](repeating: 1, count: rotations.count)
        var estimate = try dominantQuaternion(rotations, weights: weights).rotation
        for _ in 0..<3 {
            weights = rotations.map { rotation in
                let residual = estimate.angularDistanceDegrees(to: rotation)
                return residual <= huberCutoffDegrees
                    ? 1
                    : huberCutoffDegrees / max(residual, 1e-12)
            }
            estimate = try dominantQuaternion(rotations, weights: weights).rotation
        }
        let spectrum = try dominantQuaternion(rotations, weights: weights)
        estimate = spectrum.rotation
        let residuals = rotations.map { estimate.angularDistanceDegrees(to: $0) }.sorted()
        let median = percentile(residuals, fraction: 0.5)
        let p90 = percentile(residuals, fraction: 0.9)
        guard spectrum.dominantFraction >= 0.75,
              spectrum.normalizedEigengap >= 0.5,
              median <= maximumMedianAlignmentResidualDegrees,
              p90 <= maximumP90AlignmentResidualDegrees else {
            throw invalid(
                "The candidate-to-ground-truth pose alignment is not trustworthy "
                    + "(median \(format(median))°, p90 \(format(p90))°)."
            )
        }
        return RotationAlignment(
            rotation: estimate,
            supportCount: rotations.count,
            medianResidualDegrees: median,
            p90ResidualDegrees: p90
        )
    }

    private static func dominantQuaternion(
        _ rotations: [Quaternion],
        weights: [Double]
    ) throws -> RotationSpectrum {
        var scatter = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        var totalWeight = 0.0
        for (rotation, weight) in zip(rotations, weights) {
            guard weight.isFinite, weight > 0 else { continue }
            let q = rotation.array
            totalWeight += weight
            for row in 0..<4 {
                for column in row..<4 {
                    let value = weight * q[row] * q[column]
                    scatter[row][column] += value
                    if row != column { scatter[column][row] += value }
                }
            }
        }
        guard totalWeight.isFinite, totalWeight > 0 else {
            throw invalid("The pose alignment has no usable rotation weight.")
        }

        var eigenvectors = Array(repeating: Array(repeating: 0.0, count: 4), count: 4)
        for index in 0..<4 { eigenvectors[index][index] = 1 }
        for _ in 0..<64 {
            var pivotRow = 0
            var pivotColumn = 1
            var largest = abs(scatter[0][1])
            for row in 0..<4 {
                for column in (row + 1)..<4 where abs(scatter[row][column]) > largest {
                    pivotRow = row
                    pivotColumn = column
                    largest = abs(scatter[row][column])
                }
            }
            if largest <= 1e-14 * max(1, totalWeight) { break }
            let app = scatter[pivotRow][pivotRow]
            let aqq = scatter[pivotColumn][pivotColumn]
            let apq = scatter[pivotRow][pivotColumn]
            let angle = 0.5 * atan2(2 * apq, aqq - app)
            let cosine = cos(angle)
            let sine = sin(angle)
            for index in 0..<4 where index != pivotRow && index != pivotColumn {
                let aip = scatter[index][pivotRow]
                let aiq = scatter[index][pivotColumn]
                scatter[index][pivotRow] = cosine * aip - sine * aiq
                scatter[pivotRow][index] = scatter[index][pivotRow]
                scatter[index][pivotColumn] = sine * aip + cosine * aiq
                scatter[pivotColumn][index] = scatter[index][pivotColumn]
            }
            scatter[pivotRow][pivotRow] =
                cosine * cosine * app - 2 * sine * cosine * apq + sine * sine * aqq
            scatter[pivotColumn][pivotColumn] =
                sine * sine * app + 2 * sine * cosine * apq + cosine * cosine * aqq
            scatter[pivotRow][pivotColumn] = 0
            scatter[pivotColumn][pivotRow] = 0
            for row in 0..<4 {
                let vip = eigenvectors[row][pivotRow]
                let viq = eigenvectors[row][pivotColumn]
                eigenvectors[row][pivotRow] = cosine * vip - sine * viq
                eigenvectors[row][pivotColumn] = sine * vip + cosine * viq
            }
        }
        let order = (0..<4).sorted {
            if scatter[$0][$0] == scatter[$1][$1] { return $0 < $1 }
            return scatter[$0][$0] > scatter[$1][$1]
        }
        let first = order[0]
        let second = order[1]
        let rotation = try Quaternion(
            w: eigenvectors[0][first],
            x: eigenvectors[1][first],
            y: eigenvectors[2][first],
            z: eigenvectors[3][first],
            label: "candidate-to-ground-truth rotation",
            requireUnit: false,
            requireCanonicalSign: false
        )
        let dominant = max(0, scatter[first][first])
        let runnerUp = max(0, scatter[second][second])
        return RotationSpectrum(
            rotation: rotation,
            dominantFraction: dominant / totalWeight,
            normalizedEigengap: (dominant - runnerUp) / totalWeight
        )
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        if fraction == 0.5, values.count.isMultiple(of: 2) {
            let upper = values.count / 2
            return (values[upper - 1] + values[upper]) / 2
        }
        let rank = max(1, Int(ceil(fraction * Double(values.count))))
        return values[min(values.count - 1, rank - 1)]
    }

    private static func scanCandidateImages(_ url: URL) throws -> CandidateImageScan {
        let reader = try StableUTF8LineReader(
            url: url,
            label: "candidate images.txt",
            maximumBytes: maximumCandidateImagesBytes,
            maximumLineBytes: maximumCandidateLineBytes
        )
        var rotations: [String: Quaternion] = [:]
        var identifiers = Set<Int64>()
        var pendingPose = false
        while let line = try reader.nextLine() {
            if pendingPose {
                guard !line.text.hasPrefix("#") else {
                    throw invalid(
                        "The candidate images.txt must place one observation line after every pose."
                    )
                }
                try validateObservationLine(line.text, lineNumber: line.number)
                pendingPose = false
                continue
            }
            if line.text.isEmpty || line.text.hasPrefix("#") { continue }
            let pose = try parseCandidatePose(line.text, lineNumber: line.number)
            guard identifiers.insert(pose.identifier).inserted else {
                throw invalid("The candidate images.txt contains a duplicate image ID.")
            }
            guard rotations[pose.name] == nil else {
                throw invalid("The candidate images.txt contains a duplicate image name.")
            }
            rotations[pose.name] = pose.rotation
            pendingPose = true
        }
        guard !pendingPose else {
            throw invalid(
                "The candidate images.txt is missing the observation line after its final pose."
            )
        }
        guard !rotations.isEmpty else {
            throw invalid("The candidate images.txt contains no camera poses.")
        }
        return CandidateImageScan(rotations: rotations, digest: try reader.finalDigest())
    }

    private static func parseCandidatePose(
        _ line: String,
        lineNumber: Int
    ) throws -> (identifier: Int64, name: String, rotation: Quaternion) {
        var cursor = line.startIndex
        var fields: [Substring] = []
        fields.reserveCapacity(9)
        for _ in 0..<9 {
            while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else {
                throw invalid("Malformed candidate pose at images.txt line \(lineNumber).")
            }
            let start = cursor
            while cursor < line.endIndex, line[cursor] != " " && line[cursor] != "\t" {
                cursor = line.index(after: cursor)
            }
            fields.append(line[start..<cursor])
        }
        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex else {
            throw invalid("Malformed candidate pose at images.txt line \(lineNumber).")
        }
        let name = String(line[cursor...])
        try validateImageName(name, label: "candidate pose")
        guard let identifier = Int64(fields[0]), identifier > 0,
              let cameraIdentifier = Int64(fields[8]), cameraIdentifier > 0,
              let tx = Double(fields[5]), tx.isFinite,
              let ty = Double(fields[6]), ty.isFinite,
              let tz = Double(fields[7]), tz.isFinite else {
            throw invalid("Malformed candidate pose at images.txt line \(lineNumber).")
        }
        let components = try quaternionComponents(fields[1...4], lineNumber: lineNumber)
        return (
            identifier,
            name,
            try Quaternion(
                components,
                label: "candidate Rcw quaternion",
                requireUnit: false,
                requireCanonicalSign: false
            )
        )
    }

    private static func quaternionComponents(
        _ fields: ArraySlice<Substring>,
        lineNumber: Int
    ) throws -> QuaternionComponents {
        let values = fields.compactMap(Double.init)
        guard values.count == 4, values.allSatisfy(\.isFinite) else {
            throw invalid("Malformed candidate quaternion at images.txt line \(lineNumber).")
        }
        return QuaternionComponents(w: values[0], x: values[1], y: values[2], z: values[3])
    }

    private static func validateObservationLine(_ line: String, lineNumber: Int) throws {
        if line.isEmpty { return }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count.isMultiple(of: 3) else {
            throw invalid("Malformed candidate observation line at images.txt line \(lineNumber).")
        }
        for index in stride(from: 0, to: fields.count, by: 3) {
            guard let x = Double(fields[index]), x.isFinite,
                  let y = Double(fields[index + 1]), y.isFinite,
                  let pointIdentifier = Int64(fields[index + 2]), pointIdentifier >= -1 else {
                throw invalid(
                    "Malformed candidate observation line at images.txt line \(lineNumber)."
                )
            }
        }
    }

    private static func validateImageName(_ name: String, label: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= 16 * 1_024,
              !name.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw invalid("The \(label) contains an invalid image name.")
        }
    }

    private static func benchmarkStatus(_ raw: String) throws -> OrientationBenchmarkStatus {
        switch raw {
        case "verified": return .verified
        case "axisAlignedSignUnverified": return .axisAlignedSignUnverified
        case "unresolved": return .unresolved
        default:
            throw invalid("The geometry manifest contains an unsupported orientation status.")
        }
    }

    private static func validateLabelObject(_ data: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw invalid("The orientation label is not valid JSON.")
        }
        guard let root = value as? [String: Any],
              Set(root.keys) == ["schema_version", "coordinate_space", "physical_up"],
              let vector = root["physical_up"] as? [String: Any],
              Set(vector.keys) == ["x", "y", "z"] else {
            throw invalid("The orientation label does not match the closed physical-up schema.")
        }
    }

    private static func validateGroundTruthPoseObject(_ data: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw invalid("The ground-truth poses are not valid JSON.")
        }
        let keys: Set<String> = [
            "schema_version",
            "pose_convention",
            "quaternion_order",
            "handedness",
            "coordinate_space",
            "image_coordinates",
            "poses",
        ]
        guard let root = value as? [String: Any],
              Set(root.keys) == keys,
              let poses = root["poses"] as? [[String: Any]],
              poses.allSatisfy({ pose in
                  Set(pose.keys) == ["image_name", "rcw_wxyz"]
                      && (pose["image_name"] as? String) != nil
                      && (pose["rcw_wxyz"] as? [String: Any]).map {
                          Set($0.keys) == ["w", "x", "y", "z"]
                      } == true
              }) else {
            throw invalid("The input does not match the closed ground-truth pose schema.")
        }
    }

    private static func readRegularFile(
        _ url: URL,
        label: String,
        maximumBytes: Int
    ) throws -> Data {
        let reader = try StableByteReader(url: url, label: label, maximumBytes: maximumBytes)
        return try reader.readAll()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    fileprivate static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    fileprivate static func invalid(_ message: String) -> BenchmarkDriverError {
        .invalidJob(message)
    }
}

private struct GeometryManifest: Decodable {
    let schemaVersion: Int
    let poseConvention: String
    let quaternionOrder: String
    let handedness: String
    let modelHashes: [String: String]
    let canonicalOrientation: GeometryOrientation
}

private struct GeometryOrientation: Decodable {
    let status: String
    let sourceToCanonicalQuaternionWXYZ: QuaternionComponents?
}

private struct QuaternionComponents: Decodable {
    let w: Double
    let x: Double
    let y: Double
    let z: Double
}

private struct PhysicalUpLabel: Decodable {
    let schemaVersion: Int
    let coordinateSpace: String
    let physicalUp: VectorComponents

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case coordinateSpace = "coordinate_space"
        case physicalUp = "physical_up"
    }
}

private struct GroundTruthPoseFile: Decodable {
    let schemaVersion: Int
    let poseConvention: String
    let quaternionOrder: String
    let handedness: String
    let coordinateSpace: String
    let imageCoordinates: String
    let poses: [GroundTruthPoseRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case poseConvention = "pose_convention"
        case quaternionOrder = "quaternion_order"
        case handedness
        case coordinateSpace = "coordinate_space"
        case imageCoordinates = "image_coordinates"
        case poses
    }
}

private struct GroundTruthPoseRecord: Decodable {
    let imageName: String
    let rcwWXYZ: QuaternionComponents

    enum CodingKeys: String, CodingKey {
        case imageName = "image_name"
        case rcwWXYZ = "rcw_wxyz"
    }
}

private struct VectorComponents: Decodable {
    let x: Double
    let y: Double
    let z: Double
}

private struct Vector {
    let x: Double
    let y: Double
    let z: Double

    init(_ components: VectorComponents, label: String) throws {
        guard components.x.isFinite, components.y.isFinite, components.z.isFinite else {
            throw OrientationEvidenceExtractor.invalid("The \(label) must be finite.")
        }
        x = components.x
        y = components.y
        z = components.z
    }

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    func normalized(label: String) throws -> Vector {
        let length = sqrt(x * x + y * y + z * z)
        guard length.isFinite, length > 1e-12 else {
            throw OrientationEvidenceExtractor.invalid("The \(label) must contain a nonzero direction.")
        }
        return Vector(x: x / length, y: y / length, z: z / length)
    }
}

private struct Quaternion {
    let w: Double
    let x: Double
    let y: Double
    let z: Double

    init(
        _ components: QuaternionComponents,
        label: String,
        requireUnit: Bool,
        requireCanonicalSign: Bool
    ) throws {
        try self.init(
            w: components.w,
            x: components.x,
            y: components.y,
            z: components.z,
            label: label,
            requireUnit: requireUnit,
            requireCanonicalSign: requireCanonicalSign
        )
    }

    init(
        w: Double,
        x: Double,
        y: Double,
        z: Double,
        label: String,
        requireUnit: Bool,
        requireCanonicalSign: Bool
    ) throws {
        let values = [w, x, y, z]
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard values.allSatisfy(\.isFinite), norm.isFinite, norm > 1e-12 else {
            throw OrientationEvidenceExtractor.invalid("The \(label) must be finite and nonzero.")
        }
        if requireUnit, abs(norm - 1) > 1e-6 {
            throw OrientationEvidenceExtractor.invalid("The \(label) must be unit length.")
        }
        if requireCanonicalSign, !Self.hasCanonicalSign(w: w, x: x, y: y, z: z) {
            throw OrientationEvidenceExtractor.invalid("The \(label) sign is not canonical.")
        }
        var normalized = [w / norm, x / norm, y / norm, z / norm]
        if !Self.hasCanonicalSign(
            w: normalized[0],
            x: normalized[1],
            y: normalized[2],
            z: normalized[3]
        ) {
            normalized = normalized.map { -$0 }
        }
        self.w = normalized[0] == 0 ? 0 : normalized[0]
        self.x = normalized[1] == 0 ? 0 : normalized[1]
        self.y = normalized[2] == 0 ? 0 : normalized[2]
        self.z = normalized[3] == 0 ? 0 : normalized[3]
    }

    func composed(with rhs: Quaternion) throws -> Quaternion {
        try Quaternion(
            w: w * rhs.w - x * rhs.x - y * rhs.y - z * rhs.z,
            x: w * rhs.x + x * rhs.w + y * rhs.z - z * rhs.y,
            y: w * rhs.y - x * rhs.z + y * rhs.w + z * rhs.x,
            z: w * rhs.z + x * rhs.y - y * rhs.x + z * rhs.w,
            label: "composed rotation",
            requireUnit: false,
            requireCanonicalSign: false
        )
    }

    var inverse: Quaternion {
        Quaternion(unitW: w, unitX: -x, unitY: -y, unitZ: -z)
    }

    var array: [Double] { [w, x, y, z] }

    func rotated(_ vector: Vector) -> Vector {
        let tx = 2 * (y * vector.z - z * vector.y)
        let ty = 2 * (z * vector.x - x * vector.z)
        let tz = 2 * (x * vector.y - y * vector.x)
        return Vector(
            x: vector.x + w * tx + y * tz - z * ty,
            y: vector.y + w * ty + z * tx - x * tz,
            z: vector.z + w * tz + x * ty - y * tx
        )
    }

    func angularDistanceDegrees(to other: Quaternion) -> Double {
        let cosine = min(1, max(-1, abs(w * other.w + x * other.x + y * other.y + z * other.z)))
        return 2 * acos(cosine) * 180 / .pi
    }

    static func lexicographicallyPrecedes(_ lhs: Quaternion, _ rhs: Quaternion) -> Bool {
        for (left, right) in zip(lhs.array, rhs.array) where left != right { return left < right }
        return false
    }

    private static func hasCanonicalSign(w: Double, x: Double, y: Double, z: Double) -> Bool {
        if w > 0 { return true }
        if w < 0 { return false }
        return [x, y, z].first(where: { $0 != 0 }).map { $0 > 0 } ?? false
    }

    private init(unitW: Double, unitX: Double, unitY: Double, unitZ: Double) {
        w = unitW
        x = unitX
        y = unitY
        z = unitZ
    }
}

private struct CandidateImageScan {
    let rotations: [String: Quaternion]
    let digest: String
}

private struct RotationAlignment {
    let rotation: Quaternion
    let supportCount: Int
    let medianResidualDegrees: Double
    let p90ResidualDegrees: Double
}

private struct RotationSpectrum {
    let rotation: Quaternion
    let dominantFraction: Double
    let normalizedEigengap: Double
}

private struct OrientationFileSnapshot: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let linkCount: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        mode = metadata.st_mode
        linkCount = metadata.st_nlink
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }

    var isSingleLinkedRegularFile: Bool {
        (mode & S_IFMT) == S_IFREG && linkCount == 1 && size >= 0
    }

    func identifiesSameFile(as other: OrientationFileSnapshot) -> Bool {
        device == other.device && inode == other.inode
    }
}

private final class StableByteReader {
    private let url: URL
    private let label: String
    private let descriptor: Int32
    private let initial: OrientationFileSnapshot

    init(url: URL, label: String, maximumBytes: Int) throws {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw OrientationEvidenceExtractor.invalid("The \(label) path is invalid.")
        }
        self.url = url
        self.label = label
        descriptor = try Self.open(url, label: label)
        do {
            initial = try Self.validateInitial(
                descriptor: descriptor,
                url: url,
                label: label,
                maximumBytes: maximumBytes
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func readAll() throws -> Data {
        var data = Data(count: Int(initial.size))
        var consumed = 0
        try data.withUnsafeMutableBytes { bytes in
            while consumed < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: consumed),
                    bytes.count - consumed
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw OrientationEvidenceExtractor.invalid("The \(label) changed while being read.")
                }
                consumed += count
            }
        }
        guard off_t(consumed) == initial.size else {
            throw OrientationEvidenceExtractor.invalid("The \(label) changed while being read.")
        }
        try Self.validateFinal(descriptor: descriptor, url: url, label: label, initial: initial)
        return data
    }

    fileprivate static func open(_ url: URL, label: String) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            throw OrientationEvidenceExtractor.invalid("The \(label) must be a bounded ordinary file.")
        }
    }

    fileprivate static func validateInitial(
        descriptor: Int32,
        url: URL,
        label: String,
        maximumBytes: Int
    ) throws -> OrientationFileSnapshot {
        let descriptorSnapshot = OrientationFileSnapshot(try descriptorMetadata(descriptor, label: label))
        let pathSnapshot = OrientationFileSnapshot(try pathMetadata(url, label: label))
        guard descriptorSnapshot.isSingleLinkedRegularFile,
              pathSnapshot.isSingleLinkedRegularFile,
              descriptorSnapshot.identifiesSameFile(as: pathSnapshot),
              descriptorSnapshot == pathSnapshot,
              descriptorSnapshot.size <= off_t(maximumBytes) else {
            throw OrientationEvidenceExtractor.invalid("The \(label) must be a bounded ordinary file.")
        }
        return descriptorSnapshot
    }

    fileprivate static func validateFinal(
        descriptor: Int32,
        url: URL,
        label: String,
        initial: OrientationFileSnapshot
    ) throws {
        let descriptorSnapshot = OrientationFileSnapshot(try descriptorMetadata(descriptor, label: label))
        let pathSnapshot = OrientationFileSnapshot(try pathMetadata(url, label: label))
        guard descriptorSnapshot == initial, pathSnapshot == initial else {
            throw OrientationEvidenceExtractor.invalid("The \(label) changed while being read.")
        }
    }

    private static func descriptorMetadata(_ descriptor: Int32, label: String) throws -> stat {
        while true {
            var metadata = stat()
            if Darwin.fstat(descriptor, &metadata) == 0 { return metadata }
            if errno == EINTR { continue }
            throw OrientationEvidenceExtractor.invalid("The \(label) could not be inspected.")
        }
    }

    private static func pathMetadata(_ url: URL, label: String) throws -> stat {
        while true {
            var metadata = stat()
            if Darwin.lstat(url.path, &metadata) == 0 { return metadata }
            if errno == EINTR { continue }
            throw OrientationEvidenceExtractor.invalid("The \(label) changed while being read.")
        }
    }
}

private final class StableUTF8LineReader {
    struct Line {
        let number: Int
        let text: String
    }

    private let url: URL
    private let label: String
    private let descriptor: Int32
    private let initial: OrientationFileSnapshot
    private let maximumLineBytes: Int
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var readBufferCount = 0
    private var readBufferIndex = 0
    private var lineBuffer: [UInt8] = []
    private var totalBytesRead: off_t = 0
    private var lineNumber = 0
    private var reachedEnd = false
    private var digest: String?
    private var hasher = SHA256()

    init(url: URL, label: String, maximumBytes: Int, maximumLineBytes: Int) throws {
        guard maximumLineBytes >= 0 else {
            throw OrientationEvidenceExtractor.invalid("The \(label) line bound is invalid.")
        }
        self.url = url
        self.label = label
        self.maximumLineBytes = maximumLineBytes
        descriptor = try StableByteReader.open(url, label: label)
        do {
            initial = try StableByteReader.validateInitial(
                descriptor: descriptor,
                url: url,
                label: label,
                maximumBytes: maximumBytes
            )
            lineBuffer.reserveCapacity(min(64 * 1_024, maximumLineBytes, Int(initial.size)))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func nextLine() throws -> Line? {
        guard !reachedEnd else { return nil }
        while true {
            if readBufferIndex < readBufferCount {
                let newline = readBuffer[readBufferIndex..<readBufferCount].firstIndex(of: 0x0A)
                let end = newline ?? readBufferCount
                try append(readBuffer[readBufferIndex..<end])
                readBufferIndex = end
                if newline != nil {
                    readBufferIndex += 1
                    return try finishLine()
                }
                continue
            }
            let count = try refill()
            if count > 0 { continue }
            reachedEnd = true
            guard totalBytesRead == initial.size else {
                throw OrientationEvidenceExtractor.invalid("The \(label) changed while being read.")
            }
            try StableByteReader.validateFinal(
                descriptor: descriptor,
                url: url,
                label: label,
                initial: initial
            )
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard !lineBuffer.isEmpty else { return nil }
            return try finishLine()
        }
    }

    func finalDigest() throws -> String {
        guard reachedEnd, let digest else {
            throw OrientationEvidenceExtractor.invalid("The \(label) was not read to completion.")
        }
        return digest
    }

    private func refill() throws -> Int {
        while true {
            let count = readBuffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw OrientationEvidenceExtractor.invalid("The \(label) could not be read.")
            }
            readBufferCount = count
            readBufferIndex = 0
            if count > 0 {
                totalBytesRead += off_t(count)
                guard totalBytesRead <= initial.size else {
                    throw OrientationEvidenceExtractor.invalid("The \(label) changed while being read.")
                }
                hasher.update(data: Data(readBuffer[0..<count]))
            }
            return count
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>) throws {
        guard bytes.count <= maximumLineBytes - lineBuffer.count else {
            throw OrientationEvidenceExtractor.invalid("The \(label) contains a line over 64 MiB.")
        }
        lineBuffer.append(contentsOf: bytes)
    }

    private func finishLine() throws -> Line {
        lineNumber += 1
        if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
        guard let text = String(bytes: lineBuffer, encoding: .utf8) else {
            throw OrientationEvidenceExtractor.invalid("The \(label) contains invalid UTF-8.")
        }
        lineBuffer.removeAll(keepingCapacity: true)
        return Line(number: lineNumber, text: text)
    }
}
