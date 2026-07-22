import Foundation

struct OrientationVector3: Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = OrientationVector3(x: 0, y: 0, z: 0)
    static let unitX = OrientationVector3(x: 1, y: 0, z: 0)
    static let unitY = OrientationVector3(x: 0, y: 1, z: 0)
    static let unitZ = OrientationVector3(x: 0, y: 0, z: 1)

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ direction: CanonicalDirection) {
        self.init(x: direction.x, y: direction.y, z: direction.z)
    }

    var squaredLength: Double { dot(self) }
    var length: Double { sqrt(squaredLength) }

    var normalized: OrientationVector3? {
        let magnitude = length
        guard magnitude.isFinite, magnitude > 1e-15 else { return nil }
        return self / magnitude
    }

    func dot(_ other: OrientationVector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: OrientationVector3) -> OrientationVector3 {
        OrientationVector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    static prefix func - (value: OrientationVector3) -> OrientationVector3 {
        OrientationVector3(x: -value.x, y: -value.y, z: -value.z)
    }

    static func + (lhs: OrientationVector3, rhs: OrientationVector3) -> OrientationVector3 {
        OrientationVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: OrientationVector3, rhs: OrientationVector3) -> OrientationVector3 {
        OrientationVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func * (lhs: OrientationVector3, rhs: Double) -> OrientationVector3 {
        OrientationVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func * (lhs: Double, rhs: OrientationVector3) -> OrientationVector3 { rhs * lhs }

    static func / (lhs: OrientationVector3, rhs: Double) -> OrientationVector3 {
        OrientationVector3(x: lhs.x / rhs, y: lhs.y / rhs, z: lhs.z / rhs)
    }
}

struct OrientationMatrix3: Sendable, Equatable {
    private var values: [Double]

    static let identity = OrientationMatrix3(
        rows: .unitX,
        .unitY,
        .unitZ
    )

    init(rows row0: OrientationVector3, _ row1: OrientationVector3, _ row2: OrientationVector3) {
        values = [
            row0.x, row0.y, row0.z,
            row1.x, row1.y, row1.z,
            row2.x, row2.y, row2.z,
        ]
    }

    init(repeating value: Double) {
        values = Array(repeating: value, count: 9)
    }

    subscript(row: Int, column: Int) -> Double {
        get { values[row * 3 + column] }
        set { values[row * 3 + column] = newValue }
    }

    var transposed: OrientationMatrix3 {
        OrientationMatrix3(
            rows: OrientationVector3(x: self[0, 0], y: self[1, 0], z: self[2, 0]),
            OrientationVector3(x: self[0, 1], y: self[1, 1], z: self[2, 1]),
            OrientationVector3(x: self[0, 2], y: self[1, 2], z: self[2, 2])
        )
    }

    var determinant: Double {
        self[0, 0] * (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
            - self[0, 1] * (self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
            + self[0, 2] * (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0])
    }

    func row(_ index: Int) -> OrientationVector3 {
        OrientationVector3(x: self[index, 0], y: self[index, 1], z: self[index, 2])
    }

    func column(_ index: Int) -> OrientationVector3 {
        OrientationVector3(x: self[0, index], y: self[1, index], z: self[2, index])
    }

    func applied(to vector: OrientationVector3) -> OrientationVector3 {
        OrientationVector3(
            x: row(0).dot(vector),
            y: row(1).dot(vector),
            z: row(2).dot(vector)
        )
    }

    func multiplied(by other: OrientationMatrix3) -> OrientationMatrix3 {
        var result = OrientationMatrix3(repeating: 0)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row, column] = (0..<3).reduce(0) {
                    $0 + self[row, $1] * other[$1, column]
                }
            }
        }
        return result
    }

    func canonicalQuaternion() -> CanonicalQuaternionWXYZ {
        let trace = self[0, 0] + self[1, 1] + self[2, 2]
        var w: Double
        var x: Double
        var y: Double
        var z: Double
        if trace > 0 {
            let scale = sqrt(trace + 1) * 2
            w = 0.25 * scale
            x = (self[2, 1] - self[1, 2]) / scale
            y = (self[0, 2] - self[2, 0]) / scale
            z = (self[1, 0] - self[0, 1]) / scale
        } else if self[0, 0] > self[1, 1], self[0, 0] > self[2, 2] {
            let scale = sqrt(1 + self[0, 0] - self[1, 1] - self[2, 2]) * 2
            w = (self[2, 1] - self[1, 2]) / scale
            x = 0.25 * scale
            y = (self[0, 1] + self[1, 0]) / scale
            z = (self[0, 2] + self[2, 0]) / scale
        } else if self[1, 1] > self[2, 2] {
            let scale = sqrt(1 + self[1, 1] - self[0, 0] - self[2, 2]) * 2
            w = (self[0, 2] - self[2, 0]) / scale
            x = (self[0, 1] + self[1, 0]) / scale
            y = 0.25 * scale
            z = (self[1, 2] + self[2, 1]) / scale
        } else {
            let scale = sqrt(1 + self[2, 2] - self[0, 0] - self[1, 1]) * 2
            w = (self[1, 0] - self[0, 1]) / scale
            x = (self[0, 2] + self[2, 0]) / scale
            y = (self[1, 2] + self[2, 1]) / scale
            z = 0.25 * scale
        }
        let norm = sqrt(w * w + x * x + y * y + z * z)
        w /= norm
        x /= norm
        y /= norm
        z /= norm
        if w < 0 || (w == 0 && firstNonzeroIsNegative([x, y, z])) {
            w = -w
            x = -x
            y = -y
            z = -z
        }
        if w == 0 { w = 0 }
        if x == 0 { x = 0 }
        if y == 0 { y = 0 }
        if z == 0 { z = 0 }
        return CanonicalQuaternionWXYZ(w: w, x: x, y: y, z: z)
    }

    private func firstNonzeroIsNegative(_ components: [Double]) -> Bool {
        for component in components where component != 0 {
            return component < 0
        }
        return false
    }
}

struct OrientationCameraSample: Sendable, Equatable {
    let imageName: String
    let rotationWorldToCamera: OrientationMatrix3
    let translation: OrientationVector3
    let trackedObservationCount: Int

    var rightInWorld: OrientationVector3 { rotationWorldToCamera.row(0) }
    var imageUpInWorld: OrientationVector3 { -rotationWorldToCamera.row(1) }
    var forwardInWorld: OrientationVector3 { rotationWorldToCamera.row(2) }
    var centerInWorld: OrientationVector3 {
        -(rotationWorldToCamera.transposed.applied(to: translation))
    }
}

struct CanonicalOrientationSolution: Sendable, Equatable {
    let artifact: CanonicalOrientationArtifact
    let sourceToCanonical: OrientationMatrix3
}

enum CanonicalOrientationEstimator {
    private static let minimumSupport = 8
    private static let minimumObservations = 20
    private static let huberCutoffRadians = 8 * Double.pi / 180
    private static let bootstrapCount = 32

    static func estimate(
        cameras: [OrientationCameraSample],
        orderedImageNames: [String],
        orderedInput: Bool,
        allowCameraUpFallback: Bool,
        deterministicSeed: UInt64
    ) -> CanonicalOrientationSolution {
        let stableCameras = cameras.sorted {
            if $0.imageName == $1.imageName {
                return $0.trackedObservationCount < $1.trackedObservationCount
            }
            return $0.imageName < $1.imageName
        }
        let eligible = stableCameras.filter {
            $0.trackedObservationCount >= minimumObservations
                && $0.rightInWorld.normalized != nil
                && $0.imageUpInWorld.normalized != nil
        }
        let openingCamera = selectOpeningCamera(
            cameras: cameras,
            orderedImageNames: orderedImageNames,
            orderedInput: orderedInput
        )

        guard !eligible.isEmpty,
              let rightEstimate = robustAxis(
                  vectors: eligible.compactMap(\.rightInWorld.normalized),
                  baseWeights: Array(repeating: 1, count: eligible.count)
              ) else {
            return unresolved(
                method: nil,
                evidence: nil,
                openingCamera: openingCamera
            )
        }

        let bootstrapVariation = bootstrapAxisVariation(
            vectors: eligible.compactMap(\.rightInWorld.normalized),
            reference: rightEstimate.axis,
            seed: deterministicSeed &+ 0x7A5B_68E9_34C1_D20F
        )
        let rightResiduals = eligible.map {
            rightAxisResidual(vector: $0.rightInWorld.normalized!, axis: rightEstimate.axis)
                * 180 / Double.pi
        }
        let trajectory = trajectoryEvidence(cameras: eligible)
        let axisGatePasses = eligible.count >= minimumSupport
            && rightEstimate.eigenvalues[1] >= 0.03
            && rightEstimate.eigengap >= 25
            && percentile(rightResiduals, fraction: 0.5) <= 3
            && percentile(rightResiduals, fraction: 0.9) <= 8
            && bootstrapVariation <= 5
        let trajectoryConflicts = trajectory.planeAgreement(with: rightEstimate.axis).map { $0 > 15 } ?? false

        let signed = signedAxis(
            undirectedAxis: rightEstimate.axis,
            imageUps: eligible.compactMap(\.imageUpInWorld.normalized)
        )
        var evidence = CanonicalOrientationEvidence(
            supportCount: eligible.count,
            eigenvalue0: rightEstimate.eigenvalues[0],
            eigenvalue1: rightEstimate.eigenvalues[1],
            eigenvalue2: rightEstimate.eigenvalues[2],
            eigengap: rightEstimate.eigengap,
            medianResidualDegrees: percentile(rightResiduals, fraction: 0.5),
            p90ResidualDegrees: percentile(rightResiduals, fraction: 0.9),
            medianAbsoluteImageUpAgreement: signed.medianAbsoluteAgreement,
            signAgreement: signed.signAgreement,
            bootstrapP95VariationDegrees: bootstrapVariation,
            trajectoryPlaneAgreementDegrees: trajectory.planeAgreement(with: rightEstimate.axis),
            trajectoryLineConcentration: trajectory.lineConcentration
        )

        if axisGatePasses, !trajectoryConflicts {
            let signVerified = signed.medianAbsoluteAgreement >= 0.20 && signed.signAgreement >= 0.75
            let vertical = signVerified ? signed.axis : canonicalizedUndirected(rightEstimate.axis)
            let transform = rotationMapping(vertical, to: .unitY)
            return solution(
                status: signVerified ? .verified : .axisAlignedSignUnverified,
                method: .cameraRightNullspace,
                evidence: evidence,
                transform: transform,
                openingCamera: openingCamera
            )
        }

        // A residual tail (blurred or shaky frames) can push p90 past the strict
        // gate while the axis itself is well determined. Accept up to 15 degrees
        // as sign-unverified so the scene still trains upright and the viewer
        // offers the flip as a fallback. Never .verified from this tier.
        let relaxedResidualTailPasses = eligible.count >= minimumSupport
            && rightEstimate.eigenvalues[1] >= 0.03
            && rightEstimate.eigengap >= 25
            && percentile(rightResiduals, fraction: 0.5) <= 3
            && percentile(rightResiduals, fraction: 0.9) <= 15
            && bootstrapVariation <= 5
        if relaxedResidualTailPasses, !trajectoryConflicts {
            let signVerified = signed.medianAbsoluteAgreement >= 0.20 && signed.signAgreement >= 0.75
            let vertical = signVerified ? signed.axis : canonicalizedUndirected(rightEstimate.axis)
            return solution(
                status: .axisAlignedSignUnverified,
                method: .cameraRightNullspace,
                evidence: evidence,
                transform: rotationMapping(vertical, to: .unitY),
                openingCamera: openingCamera
            )
        }

        let failedOnlyForEigenspace = eligible.count >= minimumSupport
            && (rightEstimate.eigenvalues[1] < 0.03 || rightEstimate.eigengap < 25)
            && !trajectoryConflicts
        if allowCameraUpFallback,
           failedOnlyForEigenspace,
           trajectory.lineConcentration.map({ $0 >= 0.90 }) == true,
           let upEstimate = directedUpConsensus(
               vectors: eligible.compactMap(\.imageUpInWorld.normalized),
               seed: deterministicSeed &+ 0x0D31_2F8A_71C6_49B5
           ),
           upEstimate.concentration >= 0.90,
           upEstimate.medianSpreadDegrees <= 10,
           upEstimate.p90SpreadDegrees <= 20,
           upEstimate.bootstrapP95VariationDegrees <= 5 {
            evidence.cameraUpConcentration = upEstimate.concentration
            evidence.cameraUpMedianSpreadDegrees = upEstimate.medianSpreadDegrees
            evidence.cameraUpP90SpreadDegrees = upEstimate.p90SpreadDegrees
            evidence.bootstrapP95VariationDegrees = upEstimate.bootstrapP95VariationDegrees
            let transform = rotationMapping(upEstimate.axis, to: .unitY)
            return solution(
                status: .verified,
                method: .cameraUpConsensus,
                evidence: evidence,
                transform: transform,
                openingCamera: openingCamera
            )
        }

        return unresolved(
            method: .cameraRightNullspace,
            evidence: evidence,
            openingCamera: openingCamera
        )
    }

    private struct AxisEstimate {
        let axis: OrientationVector3
        let eigenvalues: [Double]
        var eigengap: Double { eigenvalues[1] / max(eigenvalues[0], 1e-9) }
    }

    private static func robustAxis(
        vectors: [OrientationVector3],
        baseWeights: [Double]
    ) -> AxisEstimate? {
        guard vectors.count == baseWeights.count, !vectors.isEmpty else { return nil }
        var weights = baseWeights
        guard var estimate = smallestEigenvector(vectors: vectors, weights: weights) else { return nil }
        for _ in 0..<3 {
            for index in vectors.indices {
                let residual = rightAxisResidual(vector: vectors[index], axis: estimate.axis)
                let huberWeight = residual <= huberCutoffRadians
                    ? 1
                    : huberCutoffRadians / max(residual, 1e-15)
                weights[index] = baseWeights[index] * huberWeight
            }
            guard let next = smallestEigenvector(vectors: vectors, weights: weights) else { return nil }
            estimate = next
        }
        return estimate
    }

    private static func smallestEigenvector(
        vectors: [OrientationVector3],
        weights: [Double]
    ) -> AxisEstimate? {
        var scatter = OrientationMatrix3(repeating: 0)
        var totalWeight = 0.0
        for index in vectors.indices where weights[index] > 0 {
            let vector = vectors[index]
            let weight = weights[index]
            totalWeight += weight
            let components = [vector.x, vector.y, vector.z]
            for row in 0..<3 {
                for column in row..<3 {
                    let value = weight * components[row] * components[column]
                    scatter[row, column] += value
                    if row != column { scatter[column, row] += value }
                }
            }
        }
        guard totalWeight.isFinite, totalWeight > 0 else { return nil }
        for row in 0..<3 {
            for column in 0..<3 {
                scatter[row, column] /= totalWeight
            }
        }
        guard let decomposition = symmetricEigenDecomposition(scatter) else { return nil }
        return AxisEstimate(
            axis: canonicalizedUndirected(decomposition.vectors[0]),
            eigenvalues: decomposition.values
        )
    }

    private static func symmetricEigenDecomposition(
        _ input: OrientationMatrix3
    ) -> (values: [Double], vectors: [OrientationVector3])? {
        var matrix = input
        var eigenvectors = OrientationMatrix3.identity
        let pairs = [(0, 1), (0, 2), (1, 2)]
        var converged = false
        for _ in 0..<32 {
            for (p, q) in pairs {
                let offDiagonal = matrix[p, q]
                if abs(offDiagonal) <= 1e-18 { continue }
                let tau = (matrix[q, q] - matrix[p, p]) / (2 * offDiagonal)
                let tangent: Double
                if tau == 0 {
                    tangent = 1
                } else {
                    tangent = copysign(1, tau) / (abs(tau) + hypot(1, tau))
                }
                let cosine = 1 / hypot(1, tangent)
                let sine = tangent * cosine
                let app = matrix[p, p]
                let aqq = matrix[q, q]
                matrix[p, p] = cosine * cosine * app
                    - 2 * sine * cosine * offDiagonal
                    + sine * sine * aqq
                matrix[q, q] = sine * sine * app
                    + 2 * sine * cosine * offDiagonal
                    + cosine * cosine * aqq
                matrix[p, q] = 0
                matrix[q, p] = 0
                for index in 0..<3 where index != p && index != q {
                    let aip = matrix[index, p]
                    let aiq = matrix[index, q]
                    let nextP = cosine * aip - sine * aiq
                    let nextQ = sine * aip + cosine * aiq
                    matrix[index, p] = nextP
                    matrix[p, index] = nextP
                    matrix[index, q] = nextQ
                    matrix[q, index] = nextQ
                }
                for index in 0..<3 {
                    let vip = eigenvectors[index, p]
                    let viq = eigenvectors[index, q]
                    eigenvectors[index, p] = cosine * vip - sine * viq
                    eigenvectors[index, q] = sine * vip + cosine * viq
                }
            }
            let maximumDiagonal = max(abs(matrix[0, 0]), abs(matrix[1, 1]), abs(matrix[2, 2]), 1)
            let maximumOffDiagonal = max(abs(matrix[0, 1]), abs(matrix[0, 2]), abs(matrix[1, 2]))
            if maximumOffDiagonal <= 64 * Double.ulpOfOne * maximumDiagonal {
                converged = true
                break
            }
        }
        guard converged else { return nil }
        var pairsWithVectors: [(Double, OrientationVector3)] = (0..<3).compactMap { index in
            let value = matrix[index, index]
            guard value >= -1e-12, let vector = eigenvectors.column(index).normalized else { return nil }
            return (max(0, value), vector)
        }
        pairsWithVectors.sort { lhs, rhs in
            if lhs.0 == rhs.0 {
                let left = canonicalizedUndirected(lhs.1)
                let right = canonicalizedUndirected(rhs.1)
                if left.x != right.x { return left.x < right.x }
                if left.y != right.y { return left.y < right.y }
                return left.z < right.z
            }
            return lhs.0 < rhs.0
        }
        let trace = pairsWithVectors.reduce(0) { $0 + $1.0 }
        guard trace.isFinite, trace > 1e-15 else { return nil }
        return (
            pairsWithVectors.map { $0.0 / trace },
            pairsWithVectors.map { canonicalizedUndirected($0.1) }
        )
    }

    private static func bootstrapAxisVariation(
        vectors: [OrientationVector3],
        reference: OrientationVector3,
        seed: UInt64
    ) -> Double {
        guard !vectors.isEmpty else { return 90 }
        var random = SplitMix64(state: seed)
        let sampleCount = max(1, Int(ceil(0.8 * Double(vectors.count))))
        var variations: [Double] = []
        variations.reserveCapacity(bootstrapCount)
        for _ in 0..<bootstrapCount {
            var multiplicities = Array(repeating: 0.0, count: vectors.count)
            for _ in 0..<sampleCount {
                multiplicities[Int(random.next() % UInt64(vectors.count))] += 1
            }
            guard let sample = robustAxis(vectors: vectors, baseWeights: multiplicities) else {
                variations.append(90)
                continue
            }
            variations.append(acuteAngleDegrees(sample.axis, reference))
        }
        return percentile(variations, fraction: 0.95)
    }

    private static func signedAxis(
        undirectedAxis: OrientationVector3,
        imageUps: [OrientationVector3]
    ) -> (axis: OrientationVector3, medianAbsoluteAgreement: Double, signAgreement: Double) {
        let canonicalAxis = canonicalizedUndirected(undirectedAxis)
        let agreements = imageUps.map { $0.dot(canonicalAxis) }
        let positives = agreements.filter { $0 > 0 }.count
        let negatives = agreements.filter { $0 < 0 }.count
        let agreement = Double(max(positives, negatives)) / Double(max(1, agreements.count))
        let axis = negatives > positives ? -canonicalAxis : canonicalAxis
        return (
            axis,
            percentile(agreements.map(abs), fraction: 0.5),
            agreement
        )
    }

    private struct TrajectoryEvidence {
        let planeNormal: OrientationVector3?
        let lineConcentration: Double?

        func planeAgreement(with axis: OrientationVector3) -> Double? {
            planeNormal.map { CanonicalOrientationEstimator.acuteAngleDegrees($0, axis) }
        }
    }

    private static func trajectoryEvidence(cameras: [OrientationCameraSample]) -> TrajectoryEvidence {
        let centers = cameras.map(\.centerInWorld)
        guard centers.count >= minimumSupport else {
            return TrajectoryEvidence(planeNormal: nil, lineConcentration: nil)
        }
        let mean = centers.reduce(.zero, +) / Double(centers.count)
        let centered = centers.map { $0 - mean }
        let extent = centered.map(\.length).max() ?? 0
        guard extent.isFinite, extent > 0 else {
            return TrajectoryEvidence(planeNormal: nil, lineConcentration: nil)
        }
        let scaleNormalized = centered.map { $0 / extent }
        var distinctCenters: [OrientationVector3] = []
        for center in scaleNormalized where !distinctCenters.contains(where: {
            ($0 - center).length <= 1e-9
        }) {
            distinctCenters.append(center)
        }
        guard distinctCenters.count >= minimumSupport else {
            return TrajectoryEvidence(planeNormal: nil, lineConcentration: nil)
        }
        guard let estimate = smallestEigenvector(
            vectors: scaleNormalized,
            weights: Array(repeating: 1, count: scaleNormalized.count)
        ) else {
            return TrajectoryEvidence(planeNormal: nil, lineConcentration: nil)
        }
        let hasPlane = estimate.eigenvalues[1] >= 0.03 && estimate.eigengap >= 25
        return TrajectoryEvidence(
            planeNormal: hasPlane ? estimate.axis : nil,
            lineConcentration: estimate.eigenvalues[2]
        )
    }

    private struct UpEstimate {
        let axis: OrientationVector3
        let concentration: Double
        let medianSpreadDegrees: Double
        let p90SpreadDegrees: Double
        let bootstrapP95VariationDegrees: Double
    }

    private static func directedUpConsensus(
        vectors: [OrientationVector3],
        seed: UInt64
    ) -> UpEstimate? {
        guard !vectors.isEmpty else { return nil }
        let mean = vectors.reduce(.zero, +) / Double(vectors.count)
        guard let axis = mean.normalized else { return nil }
        let spreads = vectors.map { directedAngleDegrees($0, axis) }
        var random = SplitMix64(state: seed)
        let sampleCount = max(1, Int(ceil(0.8 * Double(vectors.count))))
        var variations: [Double] = []
        variations.reserveCapacity(bootstrapCount)
        for _ in 0..<bootstrapCount {
            var sampleMean = OrientationVector3.zero
            for _ in 0..<sampleCount {
                sampleMean = sampleMean + vectors[Int(random.next() % UInt64(vectors.count))]
            }
            guard let sampleAxis = sampleMean.normalized else {
                variations.append(180)
                continue
            }
            variations.append(directedAngleDegrees(sampleAxis, axis))
        }
        return UpEstimate(
            axis: axis,
            concentration: mean.length,
            medianSpreadDegrees: percentile(spreads, fraction: 0.5),
            p90SpreadDegrees: percentile(spreads, fraction: 0.9),
            bootstrapP95VariationDegrees: percentile(variations, fraction: 0.95)
        )
    }

    private static func rotationMapping(
        _ source: OrientationVector3,
        to target: OrientationVector3
    ) -> OrientationMatrix3 {
        let source = source.normalized ?? .unitY
        let target = target.normalized ?? .unitY
        let cosine = clamped(source.dot(target))
        if cosine >= 1 - 1e-14 { return .identity }
        if cosine <= -1 + 1e-14 {
            let candidate: OrientationVector3 = abs(source.x) <= abs(source.y) && abs(source.x) <= abs(source.z)
                ? .unitX
                : (abs(source.y) <= abs(source.z) ? .unitY : .unitZ)
            let axis = source.cross(candidate).normalized ?? .unitX
            return rotation(axis: axis, cosine: -1, sine: 0)
        }
        let cross = source.cross(target)
        let sine = cross.length
        return rotation(axis: cross / sine, cosine: cosine, sine: sine)
    }

    private static func rotation(
        axis: OrientationVector3,
        cosine: Double,
        sine: Double
    ) -> OrientationMatrix3 {
        let x = axis.x
        let y = axis.y
        let z = axis.z
        let oneMinusCosine = 1 - cosine
        return OrientationMatrix3(
            rows: OrientationVector3(
                x: cosine + x * x * oneMinusCosine,
                y: x * y * oneMinusCosine - z * sine,
                z: x * z * oneMinusCosine + y * sine
            ),
            OrientationVector3(
                x: y * x * oneMinusCosine + z * sine,
                y: cosine + y * y * oneMinusCosine,
                z: y * z * oneMinusCosine - x * sine
            ),
            OrientationVector3(
                x: z * x * oneMinusCosine - y * sine,
                y: z * y * oneMinusCosine + x * sine,
                z: cosine + z * z * oneMinusCosine
            )
        )
    }

    private static func solution(
        status: CanonicalOrientationStatus,
        method: CanonicalOrientationMethod,
        evidence: CanonicalOrientationEvidence,
        transform: OrientationMatrix3,
        openingCamera: OrientationCameraSample?
    ) -> CanonicalOrientationSolution {
        let direction = openingCamera?.forwardInWorld.normalized.map { transform.applied(to: $0) }
        return CanonicalOrientationSolution(
            artifact: CanonicalOrientationArtifact(
                status: status,
                method: method,
                sourceToCanonicalQuaternionWXYZ: transform.canonicalQuaternion(),
                evidence: evidence,
                canonicalOpeningViewDirection: direction.map(CanonicalDirection.init)
            ),
            sourceToCanonical: transform
        )
    }

    private static func unresolved(
        method: CanonicalOrientationMethod?,
        evidence: CanonicalOrientationEvidence?,
        openingCamera: OrientationCameraSample?
    ) -> CanonicalOrientationSolution {
        CanonicalOrientationSolution(
            artifact: CanonicalOrientationArtifact(
                status: .unresolved,
                method: method,
                sourceToCanonicalQuaternionWXYZ: nil,
                evidence: evidence,
                canonicalOpeningViewDirection: openingCamera?.forwardInWorld.normalized.map(CanonicalDirection.init)
            ),
            sourceToCanonical: .identity
        )
    }

    private static func selectOpeningCamera(
        cameras: [OrientationCameraSample],
        orderedImageNames: [String],
        orderedInput: Bool
    ) -> OrientationCameraSample? {
        guard !cameras.isEmpty else { return nil }
        if orderedInput {
            let counts = cameras.map(\.trackedObservationCount).sorted()
            let median: Double
            if counts.count.isMultiple(of: 2) {
                median = Double(counts[counts.count / 2 - 1] + counts[counts.count / 2]) / 2
            } else {
                median = Double(counts[counts.count / 2])
            }
            let byName = Dictionary(grouping: cameras, by: \.imageName)
            for name in orderedImageNames {
                if let camera = byName[name]?.first,
                   Double(camera.trackedObservationCount) >= median {
                    return camera
                }
            }
        }
        return cameras.sorted {
            if $0.trackedObservationCount != $1.trackedObservationCount {
                return $0.trackedObservationCount > $1.trackedObservationCount
            }
            return $0.imageName < $1.imageName
        }.first
    }

    private static func rightAxisResidual(
        vector: OrientationVector3,
        axis: OrientationVector3
    ) -> Double {
        asin(min(1, abs(vector.dot(axis))))
    }

    private static func acuteAngleDegrees(
        _ lhs: OrientationVector3,
        _ rhs: OrientationVector3
    ) -> Double {
        acos(min(1, abs(lhs.dot(rhs)))) * 180 / Double.pi
    }

    private static func directedAngleDegrees(
        _ lhs: OrientationVector3,
        _ rhs: OrientationVector3
    ) -> Double {
        acos(clamped(lhs.dot(rhs))) * 180 / Double.pi
    }

    private static func canonicalizedUndirected(_ vector: OrientationVector3) -> OrientationVector3 {
        let vector = vector.normalized ?? .unitY
        let components = [abs(vector.x), abs(vector.y), abs(vector.z)]
        let largest = components.enumerated().max { lhs, rhs in
            lhs.element == rhs.element ? lhs.offset > rhs.offset : lhs.element < rhs.element
        }?.offset ?? 0
        let signedComponent = [vector.x, vector.y, vector.z][largest]
        return signedComponent < 0 ? -vector : vector
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(-1, value))
    }

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
}

private extension CanonicalDirection {
    init(_ vector: OrientationVector3) {
        self.init(x: vector.x, y: vector.y, z: vector.z)
    }
}
