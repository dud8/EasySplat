import Foundation
import simd
import XCTest
@testable import EasySplatApp

final class ViewerCameraStateTests: XCTestCase {
    private let fov65 = Float(65 * Double.pi / 180)

    func testFitUsesTheNarrowerViewportFieldOfView() {
        let wide = makeState(viewport: CGSize(width: 1_600, height: 900), radius: 5)
        let tall = makeState(viewport: CGSize(width: 700, height: 1_000), radius: 5)

        XCTAssertEqual(
            wide.distance,
            1.1 * 5 / sin(fov65 / 2),
            accuracy: 1e-5
        )
        XCTAssertEqual(
            tall.distance,
            1.1 * 5 / sin(tall.horizontalFOV / 2),
            accuracy: 1e-5
        )

        let wideOccupancy = projectedDiameterFraction(of: wide)
        let tallOccupancy = projectedDiameterFraction(of: tall)
        XCTAssertTrue((0.60...0.85).contains(wideOccupancy))
        XCTAssertTrue((0.60...0.85).contains(tallOccupancy))
    }

    func testPanUsesSceneScaleAndViewportHeight() {
        var state = makeState(viewport: CGSize(width: 1_000, height: 500), radius: 2)
        let originalTarget = state.target
        let scale = 2 * state.distance * tan(state.verticalFOV / 2) / 500

        state.pan(screenDelta: SIMD2<Float>(10, 5))

        assertVector(
            state.target,
            originalTarget + SIMD3<Float>(-10 * scale, 5 * scale, 0),
            accuracy: 1e-5
        )
        XCTAssertEqual(state.interactionRevision, 1)
    }

    func testKeyboardZoomUsesFixedMultiplicativeSteps() {
        var state = makeState(radius: 10)
        let fitted = state.distance

        state.zoomIn()
        XCTAssertEqual(state.distance, fitted * 0.85, accuracy: 1e-5)

        state.zoomOut()
        XCTAssertEqual(state.distance, fitted, accuracy: 1e-4)
        XCTAssertEqual(state.interactionRevision, 2)
    }

    func testPreciseScrollUsesScaleIndependentCoefficient() {
        var state = makeState(radius: 10)
        let fitted = state.distance

        state.zoomByScroll(delta: 2)

        XCTAssertEqual(state.distance, fitted * exp(0.04), accuracy: 1e-5)
        XCTAssertEqual(state.interactionRevision, 1)
    }

    func testPositivePinchMagnificationZoomsIn() {
        var state = makeState(radius: 10)
        let fitted = state.distance

        state.zoomByPinch(magnification: 0.4)

        XCTAssertEqual(state.distance, fitted * exp(-0.4), accuracy: 1e-5)
        XCTAssertEqual(state.interactionRevision, 1)
    }

    func testPointerAnchoredZoomPreservesTargetPlanePoint() throws {
        var state = makeState(
            target: SIMD3<Float>(3, -2, 7),
            viewport: CGSize(width: 1_000, height: 600),
            radius: 4
        )
        state.orbit(deltaYaw: 0.35, deltaPitch: -0.2)
        let pointer = CGPoint(x: 780, y: 155)
        let before = try XCTUnwrap(state.targetPlanePoint(at: pointer))

        state.zoomByScroll(delta: -8, anchoredAt: pointer)

        let after = try XCTUnwrap(state.targetPlanePoint(at: pointer))
        assertVector(after, before, accuracy: 2e-5)
    }

    func testDistanceClampsAcrossSevenOrdersOfMagnitude() {
        var state = makeState(radius: 7)

        state.zoomByScroll(delta: -Float.greatestFiniteMagnitude)
        XCTAssertEqual(state.distance, 0.001 * 7, accuracy: 1e-6)

        state.zoomByScroll(delta: Float.greatestFiniteMagnitude)
        XCTAssertEqual(state.distance, 10_000 * 7, accuracy: 1)
        XCTAssertGreaterThanOrEqual((10_000 * 7) / (0.001 * 7), 1_000)
    }

    func testAdaptiveClippingTracksSceneAndCameraScale() {
        var state = makeState(radius: 20)
        let fitted = state.clipPlanes
        XCTAssertEqual(fitted.near, max(20e-4, state.distance * 1e-3), accuracy: 1e-6)
        XCTAssertEqual(
            fitted.far,
            max(state.distance + 80, 160, fitted.near * 1_000),
            accuracy: 1e-5
        )

        state.zoomByScroll(delta: 400)
        let distant = state.clipPlanes
        XCTAssertEqual(distant.near, state.distance * 1e-3, accuracy: 1e-3)
        XCTAssertEqual(distant.far, state.distance + 80, accuracy: 2)
        XCTAssertGreaterThan(distant.far, distant.near)
    }

    func testFitAndResetAreDeterministic() {
        let center = SIMD3<Float>(2, 3, 4)
        let opening = simd_normalize(SIMD3<Float>(1, -0.25, -2))
        var state = makeState(target: center, radius: 6, opening: opening)
        let initialYaw = state.yaw
        let initialPitch = state.pitch
        let initialDistance = state.distance

        state.pan(screenDelta: SIMD2<Float>(120, -80))
        state.orbit(deltaYaw: 0.7, deltaPitch: 0.3)
        state.zoomIn()
        state.fit()

        assertVector(state.target, center, accuracy: 1e-6)
        XCTAssertEqual(state.distance, initialDistance, accuracy: 1e-5)
        XCTAssertNotEqual(state.yaw, initialYaw)

        state.reset()
        assertVector(state.target, center, accuracy: 1e-6)
        assertVector(state.forwardDirection, opening, accuracy: 1e-5)
        XCTAssertEqual(state.yaw, initialYaw, accuracy: 1e-6)
        XCTAssertEqual(state.pitch, initialPitch, accuracy: 1e-6)
        XCTAssertEqual(state.distance, initialDistance, accuracy: 1e-5)

        let revision = state.interactionRevision
        state.reset()
        XCTAssertEqual(state.interactionRevision, revision)
    }

    func testInitializationSanitizesInvalidValuesAndVerticalOpeningDirection() {
        let invalid = ViewerCameraState(
            target: SIMD3<Float>(.nan, .infinity, -.infinity),
            sceneRadius: -.infinity,
            openingDirection: SIMD3<Float>(.nan, 0, 0),
            viewportSize: CGSize(width: -.infinity, height: .nan),
            verticalFOV: .infinity,
            yaw: .nan,
            pitch: .infinity,
            distance: -.infinity,
            interactionRevision: 12
        )

        assertVector(invalid.target, .zero)
        assertVector(invalid.openingDirection, SIMD3<Float>(0, 0, -1))
        XCTAssertTrue(invalid.yaw.isFinite)
        XCTAssertTrue(invalid.pitch.isFinite)
        XCTAssertTrue(invalid.distance.isFinite)
        XCTAssertGreaterThan(invalid.sceneRadius, 0)
        XCTAssertGreaterThan(invalid.viewportSize.width, 0)
        XCTAssertGreaterThan(invalid.viewportSize.height, 0)
        XCTAssertGreaterThan(invalid.verticalFOV, 0)
        XCTAssertEqual(invalid.interactionRevision, 12)

        let vertical = makeState(opening: SIMD3<Float>(0, 1, 0))
        XCTAssertTrue(vertical.openingDirection.x.isFinite)
        XCTAssertTrue(vertical.openingDirection.y.isFinite)
        XCTAssertTrue(vertical.openingDirection.z.isFinite)
        XCTAssertEqual(simd_length(vertical.openingDirection), 1, accuracy: 1e-6)
        XCTAssertEqual(vertical.yaw, 0, accuracy: 1e-6)
        XCTAssertLessThan(vertical.pitch, .pi / 2)
    }

    func testExtremeFiniteInputsRemainUsable() throws {
        let hugeDirection = SIMD3<Float>(
            .greatestFiniteMagnitude,
            .greatestFiniteMagnitude / 2,
            -.greatestFiniteMagnitude
        )
        let expectedDirection = simd_normalize(SIMD3<Float>(1, 0.5, -1))
        let state = ViewerCameraState(
            sceneRadius: .greatestFiniteMagnitude,
            openingDirection: hugeDirection,
            viewportSize: CGSize(
                width: Double.leastNormalMagnitude,
                height: Double.greatestFiniteMagnitude
            ),
            verticalFOV: fov65
        )

        assertVector(state.openingDirection, expectedDirection, accuracy: 1e-5)
        XCTAssertTrue(state.horizontalFOV.isFinite)
        XCTAssertGreaterThan(state.horizontalFOV, 0)
        XCTAssertTrue(state.fittedDistance.isFinite)
        XCTAssertTrue(state.panWorldUnitsPerPixel.isFinite)
        XCTAssertNotNil(
            state.targetPlanePoint(
                at: CGPoint(x: state.viewportSize.width / 2, y: state.viewportSize.height / 2)
            )
        )
    }

    func testLateBoundsDoNotOverrideUserInteraction() {
        var state = makeState(target: .zero, radius: 1)
        let revisionAtRequest = state.interactionRevision
        state.orbit(deltaYaw: 0.2, deltaPitch: 0)
        let interactedState = state

        XCTAssertFalse(
            state.applyBounds(
                center: SIMD3<Float>(9, 8, 7),
                radius: 20,
                openingDirection: SIMD3<Float>(1, 0, 0),
                ifInteractionRevisionMatches: revisionAtRequest
            )
        )
        XCTAssertEqual(state, interactedState)
    }

    func testViewportChangesRefitOnlyBeforeUserInteraction() {
        var state = makeState(viewport: CGSize(width: 400, height: 800), radius: 5)
        let narrowDistance = state.distance

        state.updateViewportSize(CGSize(width: 1_200, height: 800))

        XCTAssertLessThan(state.distance, narrowDistance)
        XCTAssertEqual(state.distance, state.fittedDistance, accuracy: 1e-5)
        XCTAssertEqual(state.interactionRevision, 0)

        state.pan(screenDelta: SIMD2<Float>(20, -10))
        state.zoomIn()
        let userTarget = state.target
        let userDistance = state.distance

        state.updateViewportSize(CGSize(width: 500, height: 1_000))

        assertVector(state.target, userTarget)
        XCTAssertEqual(state.distance, userDistance, accuracy: 1e-6)
        XCTAssertNotEqual(state.distance, state.fittedDistance)
    }

    func testBoundsAutoFitWhenNoInteractionOccurred() {
        var state = makeState(target: .zero, radius: 1)
        let revisionAtRequest = state.interactionRevision
        let center = SIMD3<Float>(9, 8, 7)
        let opening = simd_normalize(SIMD3<Float>(1, -0.5, -2))

        XCTAssertTrue(
            state.applyBounds(
                center: center,
                radius: 20,
                openingDirection: opening,
                ifInteractionRevisionMatches: revisionAtRequest
            )
        )

        assertVector(state.target, center)
        assertVector(state.forwardDirection, opening, accuracy: 1e-5)
        XCTAssertEqual(state.distance, state.fittedDistance, accuracy: 1e-5)
        XCTAssertEqual(state.interactionRevision, revisionAtRequest)
    }

    func testInvalidBoundsAreRejectedWithoutMutation() {
        var state = makeState()
        let original = state

        XCTAssertFalse(
            state.applyBounds(
                center: SIMD3<Float>(.nan, 0, 0),
                radius: 3,
                openingDirection: nil,
                ifInteractionRevisionMatches: state.interactionRevision
            )
        )
        XCTAssertFalse(
            state.applyBounds(
                center: .zero,
                radius: 0,
                openingDirection: nil,
                ifInteractionRevisionMatches: state.interactionRevision
            )
        )
        XCTAssertEqual(state, original)
    }

    func testLateBoundsCanUpdateScaleWithoutMovingAnInteractedCamera() {
        var state = makeState(target: .zero, radius: 1)
        state.orbit(deltaYaw: 0.4, deltaPitch: -0.2)
        state.pan(screenDelta: SIMD2<Float>(25, -10))
        let target = state.target
        let yaw = state.yaw
        let pitch = state.pitch
        let distance = state.distance
        let revision = state.interactionRevision
        let center = SIMD3<Float>(8, 9, 10)
        let opening = simd_normalize(SIMD3<Float>(1, 0.2, -3))

        XCTAssertTrue(
            state.adoptBoundsPreservingView(
                center: center,
                radius: 40,
                openingDirection: opening
            )
        )

        assertVector(state.target, target)
        XCTAssertEqual(state.yaw, yaw)
        XCTAssertEqual(state.pitch, pitch)
        XCTAssertEqual(state.distance, distance)
        XCTAssertEqual(state.interactionRevision, revision)
        XCTAssertEqual(state.sceneRadius, 40)
        assertVector(state.openingDirection, opening, accuracy: 1e-5)

        state.fit()
        assertVector(state.target, center)
        XCTAssertEqual(state.distance, state.fittedDistance, accuracy: 1e-5)
    }

    func testLateExtremeBoundsPreserveInteractedCameraDistanceExactly() {
        for radius: Float in [1e-6, 1e6] {
            var state = makeState(target: .zero, radius: 1)
            state.zoomIn()
            state.orbit(deltaYaw: 0.4, deltaPitch: -0.2)
            state.pan(screenDelta: SIMD2<Float>(25, -10))
            let interacted = state

            XCTAssertTrue(
                state.adoptBoundsPreservingView(
                    center: SIMD3<Float>(8, 9, 10),
                    radius: radius,
                    openingDirection: SIMD3<Float>(0, 0, -1)
                )
            )

            assertVector(state.target, interacted.target)
            XCTAssertEqual(state.yaw, interacted.yaw)
            XCTAssertEqual(state.pitch, interacted.pitch)
            XCTAssertEqual(state.distance, interacted.distance)
            XCTAssertEqual(state.interactionRevision, interacted.interactionRevision)
            XCTAssertEqual(state.sceneRadius, radius)
        }
    }

    private func makeState(
        target: SIMD3<Float> = .zero,
        viewport: CGSize = CGSize(width: 1_200, height: 800),
        radius: Float = 3,
        opening: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    ) -> ViewerCameraState {
        ViewerCameraState(
            target: target,
            sceneRadius: radius,
            openingDirection: opening,
            viewportSize: viewport,
            verticalFOV: fov65
        )
    }

    private func projectedDiameterFraction(of state: ViewerCameraState) -> Float {
        let limitingHalfFOV = min(state.horizontalFOV, state.verticalFOV) / 2
        return state.sceneRadius / (state.distance * tan(limitingHalfFOV))
    }

    private func assertVector(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        accuracy: Float = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
