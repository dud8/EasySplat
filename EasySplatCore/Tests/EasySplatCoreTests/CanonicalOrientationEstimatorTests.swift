#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class CanonicalOrientationEstimatorTests: XCTestCase {
    func testOrbitFindsPhysicalUpAndResolvesItsSign() throws {
        let physicalUp = OrientationVector3(x: 0, y: 0, z: -1)
        let cameras = orbitCameras(up: physicalUp, count: 24)

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .verified)
        XCTAssertEqual(solution.artifact.method, .cameraRightNullspace)
        assertDirection(solution.sourceToCanonical.applied(to: physicalUp), equals: .unitY)
        XCTAssertEqual(solution.sourceToCanonical.determinant, 1, accuracy: 1e-12)
        XCTAssertEqual(solution.artifact.evidence?.supportCount, 24)
        XCTAssertEqual(try XCTUnwrap(solution.artifact.evidence?.signAgreement), 1, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(solution.artifact.evidence?.medianResidualDegrees), 1e-9)
        XCTAssertLessThanOrEqual(try XCTUnwrap(solution.artifact.evidence?.bootstrapP95VariationDegrees), 1e-7)
        XCTAssertNotNil(solution.artifact.canonicalOpeningViewDirection)
    }

    func testBalancedImageUpVotesAlignAxisWithoutGuessingSign() throws {
        let physicalUp = OrientationVector3.unitY
        var cameras = orbitCameras(up: physicalUp, count: 24)
        for index in cameras.indices where index.isMultiple(of: 2) {
            cameras[index] = camera(
                name: cameras[index].imageName,
                imageUp: -physicalUp,
                forward: -cameras[index].forwardInWorld,
                center: cameras[index].centerInWorld,
                observations: cameras[index].trackedObservationCount
            )
        }

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .axisAlignedSignUnverified)
        XCTAssertEqual(solution.artifact.method, .cameraRightNullspace)
        XCTAssertEqual(
            try XCTUnwrap(solution.artifact.evidence?.medianAbsoluteImageUpAgreement),
            1,
            accuracy: 1e-12
        )
        XCTAssertEqual(try XCTUnwrap(solution.artifact.evidence?.signAgreement), 0.5, accuracy: 1e-12)
        XCTAssertNotNil(solution.artifact.sourceToCanonicalQuaternionWXYZ)
    }

    func testResidualTailWithinFifteenDegreesYieldsSignUnverifiedAxis() throws {
        // The user-visible failure this covers: a minority of shaky frames pushes
        // p90 past the strict 8-degree gate while the axis and sign stay strong.
        let physicalUp = OrientationVector3(x: 0, y: -1, z: 0)
        var cameras = orbitCameras(up: physicalUp, count: 24)
        for index in 0..<4 {
            let original = cameras[index]
            let forward = original.forwardInWorld
            let sideways = physicalUp.cross(forward).normalized!
            let rollRadians = 12 * Double.pi / 180
            cameras[index] = camera(
                name: original.imageName,
                imageUp: physicalUp * cos(rollRadians) + sideways * sin(rollRadians),
                forward: forward,
                center: original.centerInWorld,
                observations: original.trackedObservationCount
            )
        }

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .axisAlignedSignUnverified)
        XCTAssertEqual(solution.artifact.method, .cameraRightNullspace)
        XCTAssertNotNil(solution.artifact.sourceToCanonicalQuaternionWXYZ)
        let p90 = try XCTUnwrap(solution.artifact.evidence?.p90ResidualDegrees)
        XCTAssertGreaterThan(p90, 8)
        XCTAssertLessThanOrEqual(p90, 15)
        XCTAssertLessThanOrEqual(try XCTUnwrap(solution.artifact.evidence?.medianResidualDegrees), 3)
        // Sign evidence is strong, so the best sign guess is applied: the
        // inverted scene comes out upright.
        let mappedUp = solution.sourceToCanonical.applied(to: physicalUp)
        XCTAssertGreaterThan(mappedUp.dot(.unitY), cos(5 * Double.pi / 180))
    }

    func testResidualTailBeyondFifteenDegreesStaysUnresolved() {
        let physicalUp = OrientationVector3(x: 0, y: -1, z: 0)
        var cameras = orbitCameras(up: physicalUp, count: 24)
        for index in 0..<4 {
            let original = cameras[index]
            let forward = original.forwardInWorld
            let sideways = physicalUp.cross(forward).normalized!
            let rollRadians = 25 * Double.pi / 180
            cameras[index] = camera(
                name: original.imageName,
                imageUp: physicalUp * cos(rollRadians) + sideways * sin(rollRadians),
                forward: forward,
                center: original.centerInWorld,
                observations: original.trackedObservationCount
            )
        }

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: false,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .unresolved)
        XCTAssertNil(solution.artifact.sourceToCanonicalQuaternionWXYZ)
        XCTAssertEqual(solution.sourceToCanonical, .identity)
    }

    func testDegenerateNonWalkthroughDoesNotInventAnAxis() {
        let cameras = (0..<12).map { index in
            camera(
                name: String(format: "frame_%03d.jpg", index),
                imageUp: .unitY,
                forward: .unitZ,
                center: OrientationVector3(x: Double(index), y: 0, z: 0),
                observations: 30
            )
        }

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .unresolved)
        XCTAssertEqual(solution.artifact.method, .cameraRightNullspace)
        XCTAssertNil(solution.artifact.sourceToCanonicalQuaternionWXYZ)
        XCTAssertEqual(solution.sourceToCanonical, .identity)
    }

    func testStraightWalkthroughUsesStrictCameraUpFallback() throws {
        let cameras = (0..<16).map { index in
            camera(
                name: String(format: "frame_%03d.jpg", index),
                imageUp: .unitY,
                forward: .unitZ,
                center: OrientationVector3(x: Double(index), y: 0, z: 0),
                observations: 30
            )
        }

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: true,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .verified)
        XCTAssertEqual(solution.artifact.method, .cameraUpConsensus)
        assertDirection(solution.sourceToCanonical.applied(to: .unitY), equals: .unitY)
        XCTAssertEqual(try XCTUnwrap(solution.artifact.evidence?.cameraUpConcentration), 1, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(solution.artifact.evidence?.cameraUpP90SpreadDegrees), 1e-9)
    }

    func testConflictingTrajectoryPlaneDowngradesOtherwiseStrongEstimate() {
        let physicalUp = OrientationVector3.unitY
        var cameras = orbitCameras(up: physicalUp, count: 24)
        for index in cameras.indices {
            let angle = 2 * Double.pi * Double(index) / Double(cameras.count)
            cameras[index] = camera(
                name: cameras[index].imageName,
                imageUp: physicalUp,
                forward: cameras[index].forwardInWorld,
                center: OrientationVector3(x: 0, y: 5 * cos(angle), z: 5 * sin(angle)),
                observations: 30
            )
        }

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .unresolved)
        XCTAssertGreaterThan(try XCTUnwrap(solution.artifact.evidence?.trajectoryPlaneAgreementDegrees), 15)
        XCTAssertNil(solution.artifact.sourceToCanonicalQuaternionWXYZ)
    }

    func testTrajectoryConflictDecisionIsInvariantToSceneScale() throws {
        for scale in [1e-12, 1.0, 1e12] {
            let physicalUp = OrientationVector3.unitY
            var cameras = orbitCameras(up: physicalUp, count: 24)
            for index in cameras.indices {
                let angle = 2 * Double.pi * Double(index) / Double(cameras.count)
                cameras[index] = camera(
                    name: cameras[index].imageName,
                    imageUp: physicalUp,
                    forward: cameras[index].forwardInWorld,
                    center: OrientationVector3(
                        x: 0,
                        y: 5 * scale * cos(angle),
                        z: 5 * scale * sin(angle)
                    ),
                    observations: 30
                )
            }

            let solution = CanonicalOrientationEstimator.estimate(
                cameras: cameras,
                orderedImageNames: cameras.map(\.imageName),
                orderedInput: true,
                allowCameraUpFallback: false,
                deterministicSeed: 42
            )

            XCTAssertEqual(solution.artifact.status, .unresolved, "scale \(scale)")
            XCTAssertGreaterThan(
                try XCTUnwrap(solution.artifact.evidence?.trajectoryPlaneAgreementDegrees),
                15,
                "scale \(scale)"
            )
        }
    }

    func testFewerThanEightSupportedCamerasRemainsUnresolved() {
        let cameras = orbitCameras(up: .unitY, count: 7)

        let solution = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        XCTAssertEqual(solution.artifact.status, .unresolved)
        XCTAssertNil(solution.artifact.sourceToCanonicalQuaternionWXYZ)
    }

    func testEstimateIsBitwiseRepeatableForFixedSeed() {
        let cameras = orbitCameras(
            up: OrientationVector3(x: 0.2, y: 0.95, z: -0.1).normalized!,
            count: 24
        )
        let arguments = cameras.map(\.imageName)

        let first = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: arguments,
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 9_991
        )
        let second = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: arguments,
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 9_991
        )

        XCTAssertEqual(first, second)
    }

    func testQuaternionCanonicalizationKeepsTinyPositiveScalarPositive() {
        let w = 5e-16
        let x = -sqrt(1 - w * w)
        let matrix = OrientationMatrix3(
            rows: OrientationVector3(x: 1, y: 0, z: 0),
            OrientationVector3(x: 0, y: 1 - 2 * x * x, z: -2 * x * w),
            OrientationVector3(x: 0, y: 2 * x * w, z: 1 - 2 * x * x)
        )

        let quaternion = matrix.canonicalQuaternion()

        XCTAssertGreaterThan(quaternion.w, 0)
        XCTAssertLessThan(quaternion.x, 0)
        XCTAssertEqual(quaternion.y, 0)
        XCTAssertEqual(quaternion.z, 0)
    }

    func testOpeningViewUsesTrackSupportAndInputTopology() throws {
        let physicalUp = OrientationVector3.unitY
        var cameras = orbitCameras(up: physicalUp, count: 12)
        cameras[0] = camera(
            name: cameras[0].imageName,
            imageUp: physicalUp,
            forward: cameras[0].forwardInWorld,
            center: cameras[0].centerInWorld,
            observations: 1
        )
        cameras[1] = camera(
            name: cameras[1].imageName,
            imageUp: physicalUp,
            forward: cameras[1].forwardInWorld,
            center: cameras[1].centerInWorld,
            observations: 80
        )
        cameras[2] = camera(
            name: cameras[2].imageName,
            imageUp: physicalUp,
            forward: cameras[2].forwardInWorld,
            center: cameras[2].centerInWorld,
            observations: 80
        )
        let ordered = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: true,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )
        let unordered = CanonicalOrientationEstimator.estimate(
            cameras: cameras,
            orderedImageNames: cameras.map(\.imageName),
            orderedInput: false,
            allowCameraUpFallback: false,
            deterministicSeed: 42
        )

        let orderedDirection = try XCTUnwrap(ordered.artifact.canonicalOpeningViewDirection)
        let unorderedDirection = try XCTUnwrap(unordered.artifact.canonicalOpeningViewDirection)
        assertDirection(
            OrientationVector3(orderedDirection),
            equals: ordered.sourceToCanonical.applied(to: cameras[1].forwardInWorld)
        )
        assertDirection(
            OrientationVector3(unorderedDirection),
            equals: unordered.sourceToCanonical.applied(to: cameras[1].forwardInWorld)
        )
    }

    private func orbitCameras(up: OrientationVector3, count: Int) -> [OrientationCameraSample] {
        (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            let horizontalA = abs(up.y) < 0.9 ? OrientationVector3.unitY : OrientationVector3.unitZ
            let basis0 = up.cross(horizontalA).normalized!
            let basis1 = up.cross(basis0).normalized!
            let forward = (basis0 * cos(angle) + basis1 * sin(angle)).normalized!
            return camera(
                name: String(format: "frame_%03d.jpg", index),
                imageUp: up,
                forward: forward,
                center: forward * -5,
                observations: 40
            )
        }
    }

    private func camera(
        name: String,
        imageUp: OrientationVector3,
        forward: OrientationVector3,
        center: OrientationVector3,
        observations: Int
    ) -> OrientationCameraSample {
        let normalizedUp = imageUp.normalized!
        let normalizedForward = forward.normalized!
        let down = -normalizedUp
        let right = down.cross(normalizedForward).normalized!
        let rotation = OrientationMatrix3(rows: right, down, normalizedForward)
        return OrientationCameraSample(
            imageName: name,
            rotationWorldToCamera: rotation,
            translation: -(rotation.applied(to: center)),
            trackedObservationCount: observations
        )
    }

    private func assertDirection(
        _ actual: OrientationVector3,
        equals expected: OrientationVector3,
        accuracy: Double = 1e-8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
#endif
