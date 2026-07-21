import Foundation
import XCTest
@testable import EasySplatCore

final class GeometryConditioningAnalyzerTests: XCTestCase {
    private struct Pose {
        let center: OrientationVector3
        let rotation: OrientationMatrix3
    }

    private enum Stop: Error { case now }

    func testAcceptsPlanarFacadeWithStraightCameraPath() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let points = grid(z: 12)
        let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: points)
        )
        let result = analysis.measurement

        XCTAssertEqual(analysis.residuals.observationCount, result.observationCount)
        XCTAssertEqual(result.positiveDepthObservationCount, result.observationCount)
        XCTAssertEqual(result.stronglyMeasuredViewCount, poses.count)
        XCTAssertEqual(result.perViewObservationMinimum, points.count)
        XCTAssertEqual(result.perViewObservationP10, points.count)
        XCTAssertEqual(result.perViewObservationMedian, Double(points.count))
        XCTAssertEqual(result.perViewObservationP90, points.count)
        XCTAssertEqual(result.distinctTrackLengthMinimum, poses.count)
        XCTAssertEqual(result.distinctTrackLengthP10, poses.count)
        XCTAssertEqual(result.distinctTrackLengthMedian, Double(poses.count))
        XCTAssertEqual(result.distinctTrackLengthP90, poses.count)
        XCTAssertEqual(result.pointsAtLeast1Point5Degrees, points.count)
        XCTAssertEqual(result.pointsAtLeast2Degrees, points.count)
        XCTAssertEqual(result.pointsAtLeast3Degrees, points.count)
        XCTAssertEqual(result.observationsAtLeast1Point5Degrees, points.count * poses.count)
        XCTAssertEqual(result.observationsAtLeast2Degrees, points.count * poses.count)
        XCTAssertEqual(result.observationsAtLeast3Degrees, points.count * poses.count)
        XCTAssertEqual(result.cameraPairEvaluationCount, 28)
        XCTAssertLessThan(result.cameraCenterEigenvalues[1], 1e-12)
        XCTAssertLessThan(result.pointEigenvalues[0], 1e-12)
        XCTAssertGreaterThan(result.pointEigenvalues[1], 1e-8)
        XCTAssertEqual(
            Set(analysis.modelSnapshot.modelHashes.keys),
            Set(["cameras.txt", "images.txt", "points3D.txt"])
        )
    }

    func testMeasurementRoundTripsWithoutDroppingConditioningEvidence() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let measurement = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: grid(z: 12))
        ).measurement

        let encoded = try JSONEncoder().encode(measurement)

        XCTAssertEqual(
            try JSONDecoder().decode(GeometryConditioningMeasurement.self, from: encoded),
            measurement
        )
    }

    func testAcceptsObjectOrbitAndNadirObliqueGeometry() throws {
        let orbit = (0..<8).map { index -> Pose in
            let angle = Double(index) * 2 * .pi / 8
            let center = OrientationVector3(x: 7 * cos(angle), y: 2, z: 7 * sin(angle))
            return Pose(center: center, rotation: lookAt(center: center, target: .zero))
        }
        let orbitPoints = grid(z: 0).map { OrientationVector3(x: $0.x, y: $0.y, z: $0.z) }
        XCTAssertNoThrow(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: orbit, points: orbitPoints)
        ))

        let aerial = (0..<8).map { index -> Pose in
            let center = OrientationVector3(
                x: Double(index % 4) * 2 - 3,
                y: Double(index / 4) * 2 - 1,
                z: 10
            )
            return Pose(
                center: center,
                rotation: lookAt(center: center, target: .init(x: 1, y: 0, z: 0))
            )
        }
        let ground = grid(z: 0)
        XCTAssertNoThrow(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: aerial, points: ground)
        ))
    }

    func testAcceptsDistantFacadeAndHighAltitudeAerialGeometry() throws {
        let facadePoses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let distantFacade = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: facadePoses, points: grid(z: 300))
        )
        XCTAssertEqual(distantFacade.measurement.pointsAtLeast1Point5Degrees, 0)
        XCTAssertEqual(
            distantFacade.measurement.numericallyConditionedPointCount,
            distantFacade.measurement.pointCount
        )

        let aerialPoses = (0..<8).map { index -> Pose in
            let center = OrientationVector3(
                x: Double(index % 4) * 2 - 3,
                y: Double(index / 4) * 2 - 1,
                z: 300
            )
            return Pose(
                center: center,
                rotation: lookAt(center: center, target: .zero)
            )
        }
        XCTAssertNoThrow(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: aerialPoses, points: grid(z: 0))
        ))
    }

    func testRejectsPureForwardMotionTowardOneDistantPlane() throws {
        let poses = (0..<8).map {
            Pose(center: .init(x: 0, y: 0, z: Double($0)), rotation: .identity)
        }

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: grid(z: 500))
        )) { error in
            guard case .insufficientParallax(let measurement) =
                    error as? GeometryConditioningFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(measurement.effectiveCameraCenterCount, poses.count)
            XCTAssertEqual(measurement.numericallyConditionedPointCount, 0)
        }
    }

    func testRejectsPureRotationAsCollapsedCameraTrajectory() throws {
        let poses = (0..<8).map { _ in Pose(center: .zero, rotation: .identity) }
        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: grid(z: 12))
        )) { error in
            guard case .collapsedCameraTrajectory(let measurement) =
                    error as? GeometryConditioningFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(measurement.cameraBaselineToMedianDepthRatio, 0)
        }
    }

    func testRejectsCoincidentCameraMajorityDespiteOneTranslatedOutlier() throws {
        let poses = (0..<7).map { _ in
            Pose(center: .zero, rotation: .identity)
        } + [Pose(center: .init(x: 2, y: 0, z: 0), rotation: .identity)]

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: grid(z: 12))
        )) { error in
            guard case .collapsedCameraTrajectory(let measurement) =
                    error as? GeometryConditioningFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(measurement.effectiveCameraCenterCount, 2)
            XCTAssertEqual(measurement.largestCameraCenterClusterSize, 7)
            XCTAssertEqual(
                measurement.numericallyConditionedPointCount,
                measurement.pointCount,
                "The trajectory gate, not one outlier ray pair, must reject this solve."
            )
        }
    }

    func testAcceptsBracketedViewpointsAndDenselySampledValidMotion() throws {
        let bracketedPoses = (0..<40).flatMap { viewpoint -> [Pose] in
            let center = OrientationVector3(
                x: Double(viewpoint) - 19.5,
                y: 0,
                z: 0
            )
            return Array(repeating: Pose(center: center, rotation: .identity), count: 5)
        }
        let bracketed = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: bracketedPoses, points: grid(z: 100))
        )
        XCTAssertEqual(bracketed.measurement.effectiveCameraCenterCount, 40)
        XCTAssertEqual(bracketed.measurement.largestCameraCenterClusterSize, 5)

        let densePath = (0..<80).map {
            Pose(
                center: .init(x: Double($0) * 0.02, y: 0, z: 0),
                rotation: .identity
            )
        }
        let dense = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: densePath, points: grid(z: 20))
        )
        XCTAssertEqual(dense.measurement.effectiveCameraCenterCount, densePath.count)
        XCTAssertEqual(dense.measurement.largestCameraCenterClusterSize, 1)
    }

    func testRejectsWhenTenPercentOrMoreRegisteredViewsHaveFewerThanTwentyObservations() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let points = Array(grid(z: 12).prefix(19))
        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: points)
        )) { error in
            guard case .insufficientViewSupport(let measurement) =
                    error as? GeometryConditioningFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(measurement.stronglyMeasuredViewCount, 0)
            XCTAssertEqual(measurement.registeredViewCount, poses.count)
        }
    }

    func testRejectsNumericallyStationaryTinyBaselineAsCollapsedTrajectory() throws {
        let poses = (0..<8).map {
            Pose(center: .init(x: Double($0) * 0.01, y: 0, z: 0), rotation: .identity)
        }
        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: grid(z: 10_000))
        )) { error in
            guard case .collapsedCameraTrajectory(let measurement) =
                    error as? GeometryConditioningFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(measurement.effectiveCameraCenterCount, 1)
            XCTAssertEqual(measurement.largestCameraCenterClusterSize, poses.count)
        }
    }

    func testRejectsPointsWithoutTwoDistinctRegisteredViews() throws {
        let model = try makeModel(
            poses: [Pose(center: .zero, rotation: .identity)],
            points: [.init(x: 0, y: 0, z: 10)]
        )
        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(modelDirectory: model)) {
            XCTAssertEqual(
                $0 as? GeometryConditioningFailure,
                .insufficientDistinctTrackViews(pointID: 1, distinctViewCount: 1)
            )
        }
    }

    func testRejectsCollinearPointSupportWithoutRejectingPlanarSupport() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let line = (0..<25).map { OrientationVector3(x: Double($0) * 0.1, y: 0, z: 12) }
        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: line)
        )) { error in
            guard case .degeneratePointDistribution(let measurement) =
                    error as? GeometryConditioningFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertLessThan(measurement.pointEigenvalues[1], 1e-8)
        }
    }

    func testMeasurementIsInvariantUnderSim3() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let points = grid(z: 12)
        let baseline = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: poses, points: points)
        ).measurement
        let transformedPoses = poses.map {
            Pose(center: transform($0.center), rotation: rotatedWorldFrame($0.rotation))
        }
        let transformedPoints = points.map(transform)
        let transformed = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: makeModel(poses: transformedPoses, points: transformedPoints)
        ).measurement

        XCTAssertEqual(transformed.pointCount, baseline.pointCount)
        XCTAssertEqual(transformed.pointsAtLeast1Point5Degrees, baseline.pointsAtLeast1Point5Degrees)
        XCTAssertEqual(transformed.pointsAtLeast2Degrees, baseline.pointsAtLeast2Degrees)
        XCTAssertEqual(transformed.pointsAtLeast3Degrees, baseline.pointsAtLeast3Degrees)
        XCTAssertEqual(
            transformed.cameraBaselineToMedianDepthRatio,
            baseline.cameraBaselineToMedianDepthRatio,
            accuracy: 1e-10
        )
        for index in 0..<3 {
            XCTAssertEqual(
                transformed.cameraCenterEigenvalues[index],
                baseline.cameraCenterEigenvalues[index],
                accuracy: 1e-10
            )
            XCTAssertEqual(
                transformed.pointEigenvalues[index],
                baseline.pointEigenvalues[index],
                accuracy: 1e-10
            )
        }
    }

    func testConditioningAnalysisIsCancellableAndPairWorkIsBounded() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let model = try makeModel(poses: poses, points: grid(z: 12))
        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: { throw Stop.now }
        )) { XCTAssertTrue($0 is Stop) }

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            maximumRayPairEvaluations: 1
        )) { error in
            XCTAssertEqual(
                error as? GeometryConditioningFailure,
                .rayPairWorkLimitExceeded(maximum: 1)
            )
        }
    }

    func testConditioningChecksCancellationInsideOneAdversarialLongTrack() throws {
        let poses = (0..<130).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let model = try makeModel(
            poses: poses,
            points: [.init(x: 0, y: 0, z: 1_000)]
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            maximumRayPairEvaluations: 20_000,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 271 { throw Stop.now }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(
            cancellationChecks,
            271,
            "Cancellation must be polled during the long ray-pair loop."
        )
    }

    func testConditioningChecksCancellationInsideOneLargePointLine() throws {
        let model = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: model) }
        try "1 PINHOLE 640 480 500 500 320 240\n".write(
            to: model.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "malformed image header\n".write(
            to: model.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let comment = "#" + String(repeating: "x", count: 3 * 64 * 1_024)
        try (comment + "\nmalformed point row\n").write(
            to: model.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 6 { throw Stop.now }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(
            cancellationChecks,
            6,
            "Cancellation must be polled while one large point line is still being read."
        )
    }

    func testConditioningChecksCancellationInsideOneLargeCameraLine() throws {
        let model = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: model) }
        let comment = "#" + String(repeating: "x", count: 3 * 64 * 1_024)
        try (comment + "\nmalformed camera row\n").write(
            to: model.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "malformed image header\n".write(
            to: model.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 10 255 255 255 0 1 0\n".write(
            to: model.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 3 { throw Stop.now }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(
            cancellationChecks,
            3,
            "Cancellation must be polled while one large line is still being read."
        )
    }

    func testConditioningChecksCancellationInsideOneLargePointTrack() throws {
        let model = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: model) }
        try "1 PINHOLE 640 480 500 500 320 240\n".write(
            to: model.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "malformed image header\n".write(
            to: model.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let track = (1...4_097).map { "\($0) 0" }.joined(separator: " ")
        try "1 0 0 10 255 255 255 0 \(track)\n".write(
            to: model.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 7 { throw Stop.now }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(
            cancellationChecks,
            7,
            "Cancellation must be polled while tokenizing one large point track."
        )
    }

    func testConditioningChecksCancellationInsideOneLargeImageLine() throws {
        let model = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: model) }
        try "1 PINHOLE 640 480 500 500 320 240\n".write(
            to: model.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let comment = "#" + String(repeating: "x", count: 3 * 64 * 1_024)
        try (comment + "\nmalformed image header\n").write(
            to: model.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 10 255 255 255 0 1 0\n".write(
            to: model.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 9 { throw Stop.now }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(
            cancellationChecks,
            9,
            "Cancellation must be polled while one large image line is still being read."
        )
    }

    func testConditioningChecksCancellationWhileScanningUntrackedObservations() throws {
        let model = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: model) }
        try "1 PINHOLE 640 480 500 500 320 240\n".write(
            to: model.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let untracked = Array(repeating: "320 240 -1", count: 4_097)
            .joined(separator: " ")
        try ("1 1 0 0 0 0 0 0 1 frame.jpg\n" + untracked + "\n").write(
            to: model.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 10 255 255 255 0 1 0\n".write(
            to: model.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks == 11 { throw Stop.now }
            }
        )) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(
            cancellationChecks,
            11,
            "Cancellation must be polled while tokenizing untracked observations."
        )
    }

    func testRejectsModelMutationBetweenMeasurementAndSnapshotValidation() throws {
        let poses = (-4...3).map {
            Pose(center: .init(x: Double($0), y: 0, z: 0), rotation: .identity)
        }
        let model = try makeModel(poses: poses, points: grid(z: 12))
        let pointsURL = model.appendingPathComponent("points3D.txt")
        var successfulChecks = 0
        _ = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: { successfulChecks += 1 }
        )
        XCTAssertEqual(
            successfulChecks,
            52,
            "The final cancellation poll must occur after conditioning measurement."
        )
        var mutationChecks = 0

        XCTAssertThrowsError(try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            checkCancellation: {
                mutationChecks += 1
                guard mutationChecks == successfulChecks else { return }
                let current = try String(contentsOf: pointsURL, encoding: .utf8)
                try (current + "# changed after parse\n").write(
                    to: pointsURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
        )) { error in
            XCTAssertEqual(error as? GeometryModelSnapshot.Error, .modelChanged)
        }
        XCTAssertEqual(mutationChecks, successfulChecks)
    }

    private func grid(z: Double) -> [OrientationVector3] {
        (-2...2).flatMap { y in
            (-2...2).map { x in
                OrientationVector3(x: Double(x), y: Double(y), z: z)
            }
        }
    }

    private func makeModel(poses: [Pose], points: [OrientationVector3]) throws -> URL {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "1 PINHOLE 640 480 500 500 320 240\n".write(
            to: root.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        var imageRows: [String] = []
        var pointTracks = Array(repeating: [String](), count: points.count)
        for (poseIndex, pose) in poses.enumerated() {
            let imageID = poseIndex + 1
            let translation = -(pose.rotation.applied(to: pose.center))
            let quaternion = pose.rotation.canonicalQuaternion()
            imageRows.append(
                "\(imageID) \(quaternion.w) \(quaternion.x) \(quaternion.y) "
                    + "\(quaternion.z) \(translation.x) \(translation.y) \(translation.z) "
                    + "1 frame_\(String(format: "%06d", imageID)).jpg"
            )
            var observations: [String] = []
            for (pointIndex, point) in points.enumerated() {
                let cameraPoint = pose.rotation.applied(to: point) + translation
                precondition(cameraPoint.z > 0)
                let x = 500 * cameraPoint.x / cameraPoint.z + 320
                let y = 500 * cameraPoint.y / cameraPoint.z + 240
                observations.append("\(x) \(y) \(pointIndex + 1)")
                pointTracks[pointIndex].append("\(imageID) \(pointIndex)")
            }
            imageRows.append(observations.joined(separator: " "))
        }
        try (imageRows.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let pointRows = points.enumerated().map { index, point in
            "\(index + 1) \(point.x) \(point.y) \(point.z) 255 255 255 0 "
                + pointTracks[index].joined(separator: " ")
        }
        try (pointRows.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func lookAt(
        center: OrientationVector3,
        target: OrientationVector3
    ) -> OrientationMatrix3 {
        let forward = (target - center).normalized!
        let referenceUp = abs(forward.dot(.unitY)) > 0.95 ? OrientationVector3.unitX : .unitY
        let right = referenceUp.cross(forward).normalized!
        let down = forward.cross(right).normalized!
        return OrientationMatrix3(rows: right, down, forward)
    }

    private func transform(_ value: OrientationVector3) -> OrientationVector3 {
        similarityRotation.applied(to: value) * 3.5
            + OrientationVector3(x: 10, y: -4, z: 7)
    }

    private func rotatedWorldFrame(_ rotation: OrientationMatrix3) -> OrientationMatrix3 {
        rotation.multiplied(by: similarityRotation.transposed)
    }

    private var similarityRotation: OrientationMatrix3 {
        let yaw = 0.37
        let pitch = -0.61
        let roll = 0.29
        let rotateZ = OrientationMatrix3(
            rows: .init(x: cos(yaw), y: -sin(yaw), z: 0),
            .init(x: sin(yaw), y: cos(yaw), z: 0),
            .unitZ
        )
        let rotateY = OrientationMatrix3(
            rows: .init(x: cos(pitch), y: 0, z: sin(pitch)),
            .unitY,
            .init(x: -sin(pitch), y: 0, z: cos(pitch))
        )
        let rotateX = OrientationMatrix3(
            rows: .unitX,
            .init(x: 0, y: cos(roll), z: -sin(roll)),
            .init(x: 0, y: sin(roll), z: cos(roll))
        )
        return rotateZ.multiplied(by: rotateY).multiplied(by: rotateX)
    }
}
