import AppKit
import Foundation
import MetalKit
import MetalSplatter
import simd
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

final class ResultWorkspaceTests: XCTestCase {
    @MainActor
    func testViewerLoadRetryAdvancesOnlyAfterAFailure() {
        let controller = SplatViewerController()

        XCTAssertEqual(controller.loadAttemptRevision, 0)
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertFalse(controller.retryFailedLoad())
        XCTAssertEqual(controller.loadAttemptRevision, 0)

        controller.recordLoadFailure("Metal could not allocate the scene.")

        XCTAssertTrue(controller.canRetryLoad)
        XCTAssertEqual(controller.errorMessage, "Metal could not allocate the scene.")
        XCTAssertTrue(controller.retryFailedLoad())
        XCTAssertEqual(controller.loadAttemptRevision, 1)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.retryFailedLoad())
        XCTAssertEqual(controller.loadAttemptRevision, 1)
    }

    @MainActor
    func testStartingALoadClearsStaleFailureBeforePublishingProgress() {
        let controller = SplatViewerController()
        controller.recordLoadFailure("The previous file could not be read.", retryable: false)

        controller.beginLoadAttempt()

        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.isLoading)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertEqual(controller.loadErrorTitle, "Couldn’t load splat")

        controller.hasRenderedPreview = true
        controller.recordLoadFailure("The replacement was malformed.", retryable: false)

        controller.beginLoadAttempt()

        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.isUpdating)
        XCTAssertEqual(controller.loadErrorTitle, "Couldn’t update splat")
    }

    @MainActor
    func testPermanentViewerInitializationFailureCannotOfferADeadRetry() async {
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.controller = controller
        var observedStates: [SplatViewerLoadState] = []
        coordinator.onLoadStateChanged = { observedStates.append($0) }

        coordinator.scheduleInitializationFailure("Metal is not available on this Mac.")
        for _ in 0..<20 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertEqual(controller.errorMessage, "Metal is not available on this Mac.")
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertFalse(controller.retryFailedLoad())
        XCTAssertEqual(controller.loadAttemptRevision, 0)
        XCTAssertEqual(observedStates, [.failed("Metal is not available on this Mac.")])

        controller.recordLoadSuccess()
        observedStates.removeAll()
        coordinator.requestLoad(
            url: URL(fileURLWithPath: "/tmp/result.ply"),
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration()
        )
        coordinator.requestLoad(
            url: URL(fileURLWithPath: "/tmp/result.ply"),
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration()
        )

        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(observedStates.isEmpty)
        for _ in 0..<20 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertEqual(controller.errorMessage, "Metal is not available on this Mac.")
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertEqual(controller.loadAttemptRevision, 0)
        XCTAssertEqual(observedStates, [.failed("Metal is not available on this Mac.")])

        coordinator.requestLoad(
            url: URL(fileURLWithPath: "/tmp/result.ply"),
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration()
        )
        await Task.yield()
        XCTAssertEqual(observedStates, [.failed("Metal is not available on this Mac.")])
    }

    @MainActor
    func testMalformedPlyLoadFailureIsNotRetryable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("invalid.ply")
        try Data("not a ply".utf8).write(to: invalidURL)
        let device = try requireMetalDevice()
        let view = MTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))

        do {
            try await renderer.load(.gaussianSplat(invalidURL))
            XCTFail("Expected malformed PLY to fail")
        } catch {
            XCTAssertFalse(SplatRenderer.isRetryableLoadError(error))
        }
    }

    func testViewerRetryIdentityCannotCollideWithAnExternalReload() {
        let url = URL(fileURLWithPath: "/tmp/result.ply")

        XCTAssertNotEqual(
            PreviewLoadRequest(url: url, reloadToken: 1, loadAttemptRevision: 0),
            PreviewLoadRequest(url: url, reloadToken: 0, loadAttemptRevision: 1)
        )
    }

    func testFailedViewerRequestDoesNotRestartUntilItsRetryIdentityChanges() {
        let url = URL(fileURLWithPath: "/tmp/result.ply")
        let failed = PreviewLoadRequest(url: url, reloadToken: 0, loadAttemptRevision: 0)
        let retry = PreviewLoadRequest(url: url, reloadToken: 0, loadAttemptRevision: 1)
        var planner = PreviewReloadPlanner()
        planner.request(failed)

        XCTAssertEqual(
            planner.nextDecision(now: Date()),
            .start(request: failed, forceReload: false)
        )
        planner.completeInFlight()
        XCTAssertEqual(planner.nextDecision(now: Date()), .none)

        planner.request(failed)
        XCTAssertEqual(planner.nextDecision(now: Date()), .none)
        planner.request(retry)
        XCTAssertEqual(
            planner.nextDecision(now: Date()),
            .start(request: retry, forceReload: true)
        )
    }

    func testContinuousInteractionDefersViewerLoadsUntilReleasedPlusIdleDelay() {
        let url = URL(fileURLWithPath: "/tmp/result.ply")
        let request = PreviewLoadRequest(url: url, reloadToken: 0)
        var planner = PreviewReloadPlanner()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        planner.setContinuousInteraction(true, now: start)
        planner.request(request)
        XCTAssertEqual(
            planner.nextDecision(now: start.addingTimeInterval(10)),
            .deferLoad(PreviewReloadPlanner.interactionIdleDelay)
        )

        planner.setContinuousInteraction(false, now: start.addingTimeInterval(12))
        XCTAssertEqual(
            planner.nextDecision(now: start.addingTimeInterval(12.5)),
            .deferLoad(PreviewReloadPlanner.interactionIdleDelay - 0.5)
        )
        XCTAssertEqual(
            planner.nextDecision(
                now: start.addingTimeInterval(12 + PreviewReloadPlanner.interactionIdleDelay + 0.1)
            ),
            .start(request: request, forceReload: false)
        )
    }

    func testViewerMemoryBudgetScalesAcrossSupportedMacs() {
        let gibibyte = UInt64(1_073_741_824)

        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: 8 * gibibyte,
                recommendedMaxWorkingSetBytes: 6 * gibibyte,
                currentAllocatedBytes: 0
            ),
            Int(4.8 * Double(gibibyte))
        )
        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: 16 * gibibyte,
                recommendedMaxWorkingSetBytes: 12 * gibibyte,
                currentAllocatedBytes: 1 * gibibyte
            ),
            Int(8.6 * Double(gibibyte))
        )
        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: 48 * gibibyte,
                recommendedMaxWorkingSetBytes: 36 * gibibyte,
                currentAllocatedBytes: 4 * gibibyte
            ),
            Int(24.8 * Double(gibibyte))
        )
    }

    func testViewerMemoryBudgetFallsBackToPhysicalMemoryAndNeverUnderflows() {
        let gibibyte = UInt64(1_073_741_824)

        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: 8 * gibibyte,
                recommendedMaxWorkingSetBytes: 0,
                currentAllocatedBytes: 0
            ),
            Int(5.2 * Double(gibibyte))
        )
        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: 8 * gibibyte,
                recommendedMaxWorkingSetBytes: 6 * gibibyte,
                currentAllocatedBytes: 7 * gibibyte
            ),
            0
        )
        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveMaximumRecoverableBytes(
                physicalMemoryBytes: 8 * gibibyte,
                recommendedMaxWorkingSetBytes: 6 * gibibyte
            ),
            Int(4.8 * Double(gibibyte))
        )
    }

    func testViewerMemoryBudgetCapsNewSceneAtLiveHostCapacity() {
        let gibibyte = UInt64(1_073_741_824)
        let installedMemory = 16 * gibibyte
        let availableHostMemory = 3 * gibibyte
        let expectedHostCapacity = availableHostMemory - installedMemory / 20

        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: installedMemory,
                recommendedMaxWorkingSetBytes: 12 * gibibyte,
                currentAllocatedBytes: 1 * gibibyte,
                availableHostMemoryBytes: availableHostMemory,
                memoryPressure: .normal
            ),
            Int(expectedHostCapacity)
        )
    }

    func testViewerMemoryBudgetTightensUnderPressureWithResidentScene() {
        let gibibyte = UInt64(1_073_741_824)
        let installedMemory = 48 * gibibyte
        let availableHostMemory = 10 * gibibyte
        let unpressuredHostCapacity = availableHostMemory - installedMemory / 20
        let warningHostCapacity = (unpressuredHostCapacity / 5) * 3
            + (unpressuredHostCapacity % 5) * 3 / 5

        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: installedMemory,
                recommendedMaxWorkingSetBytes: 40 * gibibyte,
                currentAllocatedBytes: 24 * gibibyte,
                availableHostMemoryBytes: availableHostMemory,
                memoryPressure: .warning
            ),
            Int(warningHostCapacity)
        )
        XCTAssertEqual(
            ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
                physicalMemoryBytes: installedMemory,
                recommendedMaxWorkingSetBytes: 40 * gibibyte,
                currentAllocatedBytes: 24 * gibibyte,
                availableHostMemoryBytes: availableHostMemory,
                memoryPressure: .critical
            ),
            0
        )
    }

    @MainActor
    func testSortFailureRemainsVisibleUntilAConfirmedRecovery() {
        let controller = SplatViewerController()

        controller.recordSortFailure("Could not update transparency order.")

        XCTAssertEqual(
            controller.sortFailureMessage,
            "Could not update transparency order."
        )
        controller.recordSortSuccess()
        XCTAssertNil(controller.sortFailureMessage)
    }

    func testPhotoSelectionFactAppearsOnlyForInputsContainingPhotos() {
        XCTAssertFalse(ViewerView.inputContainsPhotos(.video(files: ["/tmp/a.mov"])))
        XCTAssertTrue(ViewerView.inputContainsPhotos(.photos(folder: "/tmp/photos")))
        XCTAssertTrue(ViewerView.inputContainsPhotos(.mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos")))
        XCTAssertFalse(ViewerView.inputContainsPhotos(nil))
    }

    func testUprightFlipIsHiddenWithoutAValidatedGeometryArtifact() {
        XCTAssertFalse(ViewerView.offersUprightFlip(for: nil))
    }

    func testViewerKeyboardCommandsMapWithoutHijackingSystemShortcuts() {
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 123, characters: nil, modifiers: []),
            .orbit(horizontal: -1, vertical: 0)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 126, characters: nil, modifiers: []),
            .orbit(horizontal: 0, vertical: 1)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 124, characters: nil, modifiers: [.option]),
            .pan(horizontal: 1, vertical: 0)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 125, characters: nil, modifiers: [.option]),
            .pan(horizontal: 0, vertical: -1)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 24, characters: "+", modifiers: [.shift]),
            .zoomIn
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 27, characters: "-", modifiers: []),
            .zoomOut
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 3, characters: "f", modifiers: []),
            .fit
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 15, characters: "R", modifiers: [.shift]),
            .reset
        )

        XCTAssertNil(ViewerKeyboardCommand.resolve(keyCode: 3, characters: "f", modifiers: [.command]))
        XCTAssertNil(ViewerKeyboardCommand.resolve(keyCode: 3, characters: "f", modifiers: [.option]))
        XCTAssertNil(ViewerKeyboardCommand.resolve(keyCode: 49, characters: " ", modifiers: []))
    }

    func testViewerMovementKeysMapPhysicalPositionsWithoutHijackingSystemShortcuts() {
        XCTAssertEqual(ViewerKeyboardCommand.resolveMovementKey(keyCode: 13), .forward)
        XCTAssertEqual(ViewerKeyboardCommand.resolveMovementKey(keyCode: 1), .backward)
        XCTAssertEqual(ViewerKeyboardCommand.resolveMovementKey(keyCode: 0), .strafeLeft)
        XCTAssertEqual(ViewerKeyboardCommand.resolveMovementKey(keyCode: 2), .strafeRight)
        XCTAssertEqual(ViewerKeyboardCommand.resolveMovementKey(keyCode: 14), .up)
        XCTAssertEqual(ViewerKeyboardCommand.resolveMovementKey(keyCode: 12), .down)
        XCTAssertNil(ViewerKeyboardCommand.resolveMovementKey(keyCode: 3))
        XCTAssertNil(ViewerKeyboardCommand.resolveMovementKey(keyCode: 126))

        XCTAssertFalse(ViewerKeyboardModifiers([]).blocksMovement)
        XCTAssertFalse(ViewerKeyboardModifiers([.shift]).blocksMovement)
        XCTAssertTrue(ViewerKeyboardModifiers([.command]).blocksMovement)
        XCTAssertTrue(ViewerKeyboardModifiers([.control]).blocksMovement)
        XCTAssertTrue(ViewerKeyboardModifiers([.option]).blocksMovement)
    }

    func testFlightAxisVectorSumsHeldKeysAndCancelsOpposedPairs() {
        XCTAssertEqual(Set<ViewerMovementKey>().flightAxisVector, SIMD3<Float>.zero)
        XCTAssertEqual(
            Set<ViewerMovementKey>([.forward, .backward]).flightAxisVector,
            SIMD3<Float>.zero
        )
        XCTAssertEqual(
            Set<ViewerMovementKey>([.forward, .strafeRight, .up]).flightAxisVector,
            SIMD3<Float>(1, 1, 1)
        )
    }

    func testViewerPointerCommandRoutesButtonsAndModifiersToDragModes() {
        XCTAssertEqual(ViewerPointerCommand.dragMode(forPrimaryButtonWith: []), .orbit)
        XCTAssertEqual(ViewerPointerCommand.dragMode(forPrimaryButtonWith: [.option]), .pan)
        XCTAssertEqual(ViewerPointerCommand.dragMode(forPrimaryButtonWith: [.control]), .freeLook)
        XCTAssertEqual(
            ViewerPointerCommand.dragMode(forPrimaryButtonWith: [.control, .option]),
            .freeLook
        )
        XCTAssertEqual(ViewerPointerCommand.secondaryButtonDragMode, .freeLook)
        XCTAssertEqual(ViewerPointerCommand.middleButtonDragMode, .pan)
    }

    @MainActor
    func testApplyingNewBoundsClearsPriorPan() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))

        renderer.pan(deltaX: 12, deltaY: -7)
        XCTAssertNotEqual(renderer.pan, .zero)

        renderer.applyBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)

        XCTAssertEqual(renderer.pan, .zero)
    }

    @MainActor
    func testRendererRejectsUnrepresentableBoundsWithoutPublishingInvalidMatrices() throws {
        let device = try requireMetalDevice()
        let view = MTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)
        let acceptedCamera = renderer.cameraState

        XCTAssertFalse(
            renderer.applyBounds(
                center: SIMD3<Float>(.greatestFiniteMagnitude, 0, 0),
                radius: .greatestFiniteMagnitude,
                openingDirection: nil,
                ifInteractionRevisionMatches: renderer.interactionRevision
            )
        )
        XCTAssertEqual(renderer.cameraState, acceptedCamera)

        let matrices = renderer.viewportCamera
        for column in [
            matrices.projection.columns.0,
            matrices.projection.columns.1,
            matrices.projection.columns.2,
            matrices.projection.columns.3,
            matrices.view.columns.0,
            matrices.view.columns.1,
            matrices.view.columns.2,
            matrices.view.columns.3,
        ] {
            XCTAssertTrue(column.x.isFinite)
            XCTAssertTrue(column.y.isFinite)
            XCTAssertTrue(column.z.isFinite)
            XCTAssertTrue(column.w.isFinite)
        }
    }

    @MainActor
    func testProjectionAndClippingRemainFiniteAcrossTheUsefulZoomRange() throws {
        let device = try requireMetalDevice()
        let view = MTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        XCTAssertTrue(
            renderer.applyBounds(
                center: SIMD3<Float>(12, -8, 30),
                radius: 5,
                openingDirection: SIMD3<Float>(0.3, -0.2, -1),
                ifInteractionRevisionMatches: renderer.interactionRevision
            )
        )

        for delta in [-4_000 as Float, 4_000] {
            renderer.zoomByScroll(
                delta: delta,
                anchoredAt: CGPoint(x: 935, y: 177)
            )
            let clip = renderer.cameraState.clipPlanes
            XCTAssertTrue(clip.near.isFinite)
            XCTAssertTrue(clip.far.isFinite)
            XCTAssertGreaterThan(clip.near, 0)
            XCTAssertGreaterThan(clip.far, clip.near)

            let matrices = renderer.viewportCamera
            for column in [
                matrices.projection.columns.0,
                matrices.projection.columns.1,
                matrices.projection.columns.2,
                matrices.projection.columns.3,
                matrices.view.columns.0,
                matrices.view.columns.1,
                matrices.view.columns.2,
                matrices.view.columns.3,
            ] {
                XCTAssertTrue(column.x.isFinite)
                XCTAssertTrue(column.y.isFinite)
                XCTAssertTrue(column.z.isFinite)
                XCTAssertTrue(column.w.isFinite)
            }
        }

        XCTAssertGreaterThanOrEqual(
            renderer.cameraState.distance / renderer.cameraState.sceneRadius,
            9_999
        )
    }

    @MainActor
    func testRendererKeepsCameraInteractionInLogicalPointsOnRetinaDisplays() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        view.drawableSize = CGSize(width: 2_400, height: 1_600)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))

        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)

        XCTAssertEqual(renderer.cameraState.viewportSize, CGSize(width: 1_200, height: 800))
        XCTAssertEqual(renderer.drawableSize, CGSize(width: 2_400, height: 1_600))
        XCTAssertEqual(renderer.viewportCamera.screenSize, SIMD2<Int>(2_400, 1_600))
    }

    @MainActor
    func testRendererKeyboardZoomOutUsesOneReciprocalStep() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: .zero, radius: 5)
        let startingDistance = renderer.cameraState.distance

        renderer.keyboardZoomOut()

        XCTAssertEqual(renderer.cameraState.distance, startingDistance / 0.85, accuracy: 1e-5)
    }

    @MainActor
    func testIntegrateFlightMovesAlongTheViewDirectionScaledBySceneRadiusAndTime() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: .zero, radius: 5)
        let start = renderer.cameraState
        renderer.setMovementInput([.forward], isSprinting: false)

        renderer.integrateFlight(now: 10)
        XCTAssertEqual(renderer.cameraState.target, start.target)

        renderer.integrateFlight(now: 10.08)
        let expected = start.target
            + start.forwardDirection * (5 * Constants.flightSpeedPerSecond * 0.08)
        XCTAssertLessThan(simd_distance(renderer.cameraState.target, expected), 1e-3)
        renderer.setMovementInput([], isSprinting: false)
    }

    @MainActor
    func testIntegrateFlightAppliesTheSprintMultiplierAlongWorldUp() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: .zero, radius: 5)
        renderer.orbit(deltaX: 0, deltaY: 100)
        let start = renderer.cameraState
        renderer.setMovementInput([.up], isSprinting: true)

        renderer.integrateFlight(now: 0)
        renderer.integrateFlight(now: 0.1)

        let climb = 5 * Constants.flightSpeedPerSecond * Constants.flightSprintMultiplier * 0.1
        let expected = start.target + SIMD3<Float>(0, climb, 0)
        XCTAssertLessThan(simd_distance(renderer.cameraState.target, expected), 1e-3)
        renderer.setMovementInput([], isSprinting: false)
    }

    @MainActor
    func testIntegrateFlightClampsLargeFrameGapsToAvoidTeleporting() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: .zero, radius: 5)
        let start = renderer.cameraState
        renderer.setMovementInput([.forward], isSprinting: false)

        renderer.integrateFlight(now: 0)
        renderer.integrateFlight(now: 60)

        let moved = simd_distance(renderer.cameraState.target, start.target)
        XCTAssertEqual(moved, 5 * Constants.flightSpeedPerSecond * 0.1, accuracy: 1e-3)
        renderer.setMovementInput([], isSprinting: false)
    }

    @MainActor
    func testIntegrateFlightKeepsNearCancellingInputsSlowInsteadOfNormalizing() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: .zero, radius: 5)
        renderer.orbit(deltaX: 0, deltaY: 2_000)
        let start = renderer.cameraState
        XCTAssertGreaterThan(start.pitch, 1.5)
        renderer.setMovementInput([.forward, .down], isSprinting: false)

        renderer.integrateFlight(now: 0)
        renderer.integrateFlight(now: 1)

        let moved = simd_distance(renderer.cameraState.target, start.target)
        XCTAssertGreaterThan(moved, 0)
        XCTAssertLessThan(moved, 0.05)
        renderer.setMovementInput([], isSprinting: false)
    }

    @MainActor
    func testMovementInputTogglesContinuousRenderingOnlyOnActivationEdges() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertEqual(view.preferredFramesPerSecond, Constants.idleFramesPerSecond)

        renderer.setMovementInput([.forward], isSprinting: false)
        XCTAssertFalse(view.isPaused)
        XCTAssertFalse(view.enableSetNeedsDisplay)
        XCTAssertEqual(view.preferredFramesPerSecond, Constants.flightFramesPerSecond)

        renderer.setMovementInput([.forward, .strafeLeft], isSprinting: true)
        XCTAssertFalse(view.isPaused)
        XCTAssertFalse(view.enableSetNeedsDisplay)

        renderer.setMovementInput([], isSprinting: false)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertEqual(view.preferredFramesPerSecond, Constants.idleFramesPerSecond)
    }

    @MainActor
    func testFlightSuppressesExplicitDrawsAndSettlesWithOneFinalFrame() throws {
        let device = try requireMetalDevice()
        let view = DrawRecordingMTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        var draws = 0
        view.onDraw = { draws += 1 }

        renderer.orbit(deltaX: 4, deltaY: 2)
        XCTAssertEqual(draws, 1)

        renderer.setMovementInput([.forward], isSprinting: false)
        renderer.orbit(deltaX: 4, deltaY: 2)
        XCTAssertEqual(draws, 1)

        renderer.setMovementInput([], isSprinting: false)
        XCTAssertEqual(draws, 2)
    }

    @MainActor
    func testRendererFreeLookRotatesInPlaceWithTheSameSensitivityAsOrbit() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: SIMD3<Float>(1, 2, 3), radius: 5)
        let start = renderer.cameraState

        renderer.freeLook(deltaX: 40, deltaY: -24)

        XCTAssertEqual(
            renderer.cameraState.yaw,
            start.yaw + 40 * Constants.orbitSpeed,
            accuracy: 1e-5
        )
        XCTAssertEqual(
            renderer.cameraState.pitch,
            start.pitch - 24 * Constants.orbitSpeed,
            accuracy: 1e-5
        )
        XCTAssertLessThan(
            simd_distance(renderer.cameraState.cameraPosition, start.cameraPosition),
            1e-3
        )
        XCTAssertGreaterThan(
            simd_distance(renderer.cameraState.target, start.target),
            0
        )
    }

    @MainActor
    func testFailedReplacementPreservesRenderedSceneAndCamera() async throws {
        let device = try requireMetalDevice()
        let view = MTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let validURL = directory.appendingPathComponent("valid.ply")
        let invalidURL = directory.appendingPathComponent("invalid.ply")
        try writeResultPly(to: validURL)
        try Data("not a ply".utf8).write(to: invalidURL)

        try await renderer.load(.gaussianSplat(validURL))
        renderer.applyBounds(center: SIMD3<Float>(2, 3, 4), radius: 8)
        renderer.orbit(deltaX: 30, deltaY: -20)
        renderer.pan(deltaX: 12, deltaY: -7)
        renderer.keyboardZoomIn()
        let successfulScene = try XCTUnwrap(renderer.modelRenderer as? SplatRenderer)
        let successfulCamera = renderer.cameraState

        do {
            try await renderer.load(.gaussianSplat(invalidURL))
            XCTFail("Expected malformed replacement PLY to fail")
        } catch {
            // The already-rendered scene remains usable after a replacement fails.
        }

        XCTAssertTrue((renderer.modelRenderer as? SplatRenderer) === successfulScene)
        XCTAssertEqual(renderer.model, .gaussianSplat(validURL))
        XCTAssertEqual(renderer.cameraState, successfulCamera)
    }

    @MainActor
    func testInteractiveViewerProvidesAVisibleKeyboardFocusMask() throws {
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            device: nil
        )

        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.canBecomeKeyView)
        XCTAssertEqual(view.focusRingType, .exterior)
        XCTAssertEqual(
            view.focusRingMaskBounds,
            view.bounds.insetBy(dx: 2, dy: 2)
        )
    }

    @MainActor
    func testInteractiveViewerIsOneNamedNativeAccessibilityElement() throws {
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            device: nil
        )

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.accessibilityIdentifier(), "result.viewer")
        XCTAssertEqual(view.accessibilityLabel(), "Interactive 3D splat viewer")
        XCTAssertEqual(view.accessibilityValue() as? String, "Loading")
        XCTAssertEqual(
            view.accessibilityHelp(),
            "Drag to orbit. Right-drag or Control-drag looks around. Option-drag pans. "
                + "Scroll or pinch zooms. Hold W, A, S, D to fly, E and Q to fly up and down, "
                + "and Shift to sprint. Press F to fit or R to reset."
        )
        XCTAssertTrue((view.accessibilityChildren() ?? []).isEmpty)
    }

    @MainActor
    func testInteractiveViewerPublishesExplicitAccessibilityLoadState() {
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            device: nil
        )

        view.setViewerLoadState(.ready)
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")

        view.setViewerLoadState(.failed)
        XCTAssertEqual(view.accessibilityValue() as? String, "Failed")

        view.setViewerLoadState(.loading)
        XCTAssertEqual(view.accessibilityValue() as? String, "Loading")
    }

    @MainActor
    func testInteractiveViewerNativeFocusUsesTheWindowFirstResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = InteractiveMTKView(frame: window.contentView?.bounds ?? .zero, device: nil)
        window.contentView?.addSubview(view)

        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(window.firstResponder === view)
    }

    @MainActor
    func testInteractiveViewerTabTraversalEntersAndLeavesWithoutFiringAViewerCommand() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = try XCTUnwrap(window.contentView)
        let before = ViewerFocusTestView(frame: .zero)
        let viewer = InteractiveMTKView(
            frame: NSRect(x: 100, y: 100, width: 600, height: 400),
            device: nil
        )
        let after = ViewerFocusTestView(frame: .zero)
        content.addSubview(before)
        content.addSubview(viewer)
        content.addSubview(after)
        before.nextKeyView = viewer
        viewer.nextKeyView = after
        after.nextKeyView = before
        var commandCount = 0
        viewer.onKeyboardCommand = { _ in commandCount += 1 }

        XCTAssertTrue(window.makeFirstResponder(before))
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === viewer)
        viewer.keyDown(with: try keyEvent(keyCode: 48))
        XCTAssertTrue(window.firstResponder === after)

        XCTAssertTrue(window.makeFirstResponder(viewer))
        viewer.keyDown(with: try keyEvent(keyCode: 48, modifiers: [.shift]))
        XCTAssertTrue(window.firstResponder === before)
        XCTAssertEqual(commandCount, 0)
    }

    @MainActor
    func testInteractiveViewerAggregatesHeldMovementKeysAndIgnoresAutoRepeats() throws {
        let viewer = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            device: nil
        )
        var reported: [Set<ViewerMovementKey>] = []
        viewer.onMovementInputChanged = { keys, _ in reported.append(keys) }

        viewer.keyDown(with: try keyEvent(keyCode: 13))
        viewer.keyDown(with: try keyEvent(keyCode: 13, isARepeat: true))
        viewer.keyDown(with: try keyEvent(keyCode: 2))
        viewer.keyUp(with: try keyEvent(keyCode: 13, type: .keyUp))
        viewer.keyUp(with: try keyEvent(keyCode: 2, type: .keyUp))

        XCTAssertEqual(reported, [
            [.forward],
            [.forward, .strafeRight],
            [.strafeRight],
            [],
        ])
    }

    @MainActor
    func testInteractiveViewerBlocksModifiedMovementKeysButAlwaysHonorsReleases() throws {
        let viewer = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            device: nil
        )
        var reported: [Set<ViewerMovementKey>] = []
        viewer.onMovementInputChanged = { keys, _ in reported.append(keys) }

        viewer.keyDown(with: try keyEvent(keyCode: 13, modifiers: [.command]))
        viewer.keyDown(with: try keyEvent(keyCode: 13, modifiers: [.option]))
        XCTAssertTrue(reported.isEmpty)

        viewer.keyDown(with: try keyEvent(keyCode: 13))
        viewer.keyUp(with: try keyEvent(keyCode: 13, modifiers: [.command], type: .keyUp))
        XCTAssertEqual(reported, [[.forward], []])
    }

    @MainActor
    func testInteractiveViewerTracksSprintThroughShiftFlagsChanges() throws {
        let viewer = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            device: nil
        )
        var reported: [(keys: Set<ViewerMovementKey>, isSprinting: Bool)] = []
        viewer.onMovementInputChanged = { reported.append(($0, $1)) }

        viewer.keyDown(with: try keyEvent(keyCode: 13))
        viewer.flagsChanged(
            with: try keyEvent(keyCode: 56, modifiers: [.shift], type: .flagsChanged)
        )
        viewer.flagsChanged(with: try keyEvent(keyCode: 56, type: .flagsChanged))
        viewer.keyUp(with: try keyEvent(keyCode: 13, type: .keyUp))

        XCTAssertEqual(reported.map(\.isSprinting), [false, true, false, false])
        XCTAssertEqual(reported[1].keys, [.forward])
    }

    @MainActor
    func testInteractiveViewerClearsHeldMovementKeysWhenFocusOrKeyWindowIsLost() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = try XCTUnwrap(window.contentView)
        let other = ViewerFocusTestView(frame: .zero)
        let viewer = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            device: nil
        )
        content.addSubview(viewer)
        content.addSubview(other)
        var reported: [Set<ViewerMovementKey>] = []
        viewer.onMovementInputChanged = { keys, _ in reported.append(keys) }

        XCTAssertTrue(window.makeFirstResponder(viewer))
        viewer.keyDown(with: try keyEvent(keyCode: 13))
        XCTAssertEqual(reported.last, [.forward])

        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertEqual(reported.last, [])

        XCTAssertTrue(window.makeFirstResponder(viewer))
        viewer.keyDown(with: try keyEvent(keyCode: 1))
        XCTAssertEqual(reported.last, [.backward])

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(reported.last, [])
    }

    @MainActor
    func testInteractiveViewerRoutesSecondaryControlAndMiddleDragsDistinctly() throws {
        let viewer = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            device: nil
        )
        var orbits = 0
        var looks = 0
        var pans = 0
        viewer.onOrbit = { _, _ in orbits += 1 }
        viewer.onFreeLook = { _, _ in looks += 1 }
        viewer.onPan = { _, _ in pans += 1 }

        viewer.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        viewer.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 20, y: 14)))
        XCTAssertEqual(orbits, 1)

        viewer.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: NSPoint(x: 10, y: 10)))
        viewer.rightMouseDragged(
            with: try mouseEvent(.rightMouseDragged, at: NSPoint(x: 30, y: 24))
        )
        XCTAssertEqual(looks, 1)

        viewer.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: .zero, modifiers: [.control])
        )
        viewer.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 6, y: 3)))
        XCTAssertEqual(looks, 2)

        viewer.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: .zero, modifiers: [.option])
        )
        viewer.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 6, y: 3)))
        XCTAssertEqual(pans, 1)

        viewer.otherMouseDown(with: try middleMouseEvent(.otherMouseDown, at: .zero))
        viewer.otherMouseDragged(
            with: try middleMouseEvent(.otherMouseDragged, at: CGPoint(x: 5, y: 5))
        )
        XCTAssertEqual(pans, 2)
        XCTAssertEqual(orbits, 1)
        XCTAssertEqual(looks, 2)
    }

    @MainActor
    func testDismantlingViewerClearsCallbacksAndReleasesRendererOwnership() throws {
        let device = try requireMetalDevice()
        weak var weakView: InteractiveMTKView?
        weak var weakRenderer: MetalKitSceneRenderer?

        try autoreleasepool {
            var view: InteractiveMTKView? = InteractiveMTKView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                device: device
            )
            var renderer: MetalKitSceneRenderer? = try XCTUnwrap(
                MetalKitSceneRenderer(try XCTUnwrap(view))
            )
            let controller = SplatViewerController()
            let coordinator = MetalKitSceneView.Coordinator()
            coordinator.renderer = renderer
            coordinator.controller = controller
            controller.renderer = renderer
            view?.delegate = renderer
            installStrongViewerCallbackCycle(
                view: try XCTUnwrap(view),
                renderer: try XCTUnwrap(renderer)
            )
            weakView = view
            weakRenderer = renderer

            MetalKitSceneView.dismantleNSView(try XCTUnwrap(view), coordinator: coordinator)

            XCTAssertNil(view?.onOrbit)
            XCTAssertNil(view?.onScrollZoom)
            XCTAssertNil(view?.onMagnify)
            XCTAssertNil(view?.onPan)
            XCTAssertNil(view?.onFreeLook)
            XCTAssertNil(view?.onKeyboardCommand)
            XCTAssertNil(view?.onMovementInputChanged)
            XCTAssertNil(view?.onInteractionActivity)
            XCTAssertNil(view?.delegate)
            XCTAssertNil(coordinator.renderer)
            XCTAssertNil(coordinator.controller)
            XCTAssertNil(controller.renderer)

            renderer = nil
            view = nil
            XCTAssertNil(weakRenderer)
        }

        XCTAssertNil(weakRenderer)
        XCTAssertNil(weakView)
    }

    @MainActor
    func testShareToolbarButtonUsesMouseDownAndProgrammaticActivationKeepsItsOwnAnchor() {
        let button = ShareToolbarNSButton()
        var activationSource: NSView?
        button.onActivate = { activationSource = $0 }

        XCTAssertEqual(
            button.sendAction(on: .leftMouseDown),
            Int(NSEvent.EventTypeMask.leftMouseDown.rawValue)
        )
        button.performClick(nil)

        XCTAssertTrue(activationSource === button)
        XCTAssertFalse(button.isEnabled)
        activationSource = nil
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertNil(activationSource)

        // SwiftUI reenables the native control after the picker session ends.
        button.isEnabled = true
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(activationSource === button)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.accessibilityIdentifier(), "result.share")
        XCTAssertEqual(button.accessibilityLabel(), "Share")
    }

    @MainActor
    func testShareSessionUsesTheButtonBoundsForBothPickerAndSharingServiceAnchors() {
        let model = AppModel(toolchainManager: ResultTestToolchainManager())
        let source = NSButton(frame: NSRect(x: 0, y: 0, width: 31, height: 27))
        var presentedRect: NSRect?
        weak var presentedView: NSView?
        var presentedEdge: NSRectEdge?
        let session = ShareSession(
            model: model,
            presenter: { _, rect, view, edge in
                presentedRect = rect
                presentedView = view
                presentedEdge = edge
            }
        )

        session.present(items: [URL(fileURLWithPath: "/tmp/result.ply")], from: source)

        XCTAssertEqual(presentedRect, source.bounds)
        XCTAssertTrue(presentedView === source)
        XCTAssertEqual(presentedEdge, .minY)

        let service = NSSharingService(
            title: "Test",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        var serviceRect = NSRect.zero
        var serviceEdge = NSRectEdge.maxX
        let serviceAnchor = session.anchoringView(
            for: service,
            showRelativeTo: &serviceRect,
            preferredEdge: &serviceEdge
        )

        XCTAssertTrue(serviceAnchor === source)
        XCTAssertEqual(serviceRect, source.bounds)
        XCTAssertEqual(serviceEdge, .minY)
        XCTAssertTrue(session.close())
        XCTAssertFalse(session.close())
    }

    @MainActor
    func testCancellingShareKeepsValidatedSnapshotReadyForAnotherAttempt() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        defer { model.cancelSharing() }
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        await model.prepareCurrentSplatForSharing()
        let preparedBefore = try XCTUnwrap(model.test_preparedShareItem())
        let session = ShareSession(
            model: model,
            preparedItem: preparedBefore,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = session
        model.isShareSheetActive = true

        session.sharingServicePicker(
            NSSharingServicePicker(items: [preparedBefore.shareURL]),
            didChoose: nil
        )

        XCTAssertNil(model.activeShareSession)
        XCTAssertFalse(model.isShareSheetActive)
        XCTAssertNil(model.shareStatusMessage)
        XCTAssertFalse(model.shareStatusIsError)
        XCTAssertTrue(model.isShareReady)
        XCTAssertEqual(model.test_preparedShareItem(), preparedBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedBefore.shareURL.path))
    }

    @MainActor
    func testTwoConsecutiveShareCancelsReuseOneValidatedSnapshot() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        var presentationCount = 0
        let presenter: ShareSession.Presenter = { _, _, _, _ in
            presentationCount += 1
        }

        model.requestCurrentSplatShare(from: NSButton(), presenter: presenter)
        for _ in 0..<300 where model.activeShareSession == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstSession = try XCTUnwrap(model.activeShareSession)
        let firstPrepared = try XCTUnwrap(model.test_preparedShareItem())
        firstSession.sharingServicePicker(
            NSSharingServicePicker(items: [firstPrepared.shareURL]),
            didChoose: nil
        )

        XCTAssertNil(model.activeShareSession)
        XCTAssertTrue(model.isShareReady)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPrepared.shareURL.path))

        model.requestCurrentSplatShare(from: NSButton(), presenter: presenter)
        for _ in 0..<300 where model.activeShareSession == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondSession = try XCTUnwrap(model.activeShareSession)
        let secondPrepared = try XCTUnwrap(model.test_preparedShareItem())
        XCTAssertEqual(secondPrepared, firstPrepared)
        XCTAssertEqual(presentationCount, 2)
        secondSession.sharingServicePicker(
            NSSharingServicePicker(items: [secondPrepared.shareURL]),
            didChoose: nil
        )

        XCTAssertNil(model.activeShareSession)
        XCTAssertTrue(model.isShareReady)
        XCTAssertEqual(model.test_preparedShareItem(), firstPrepared)

        model.cancelSharing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPrepared.shareDirectoryURL.path))
    }

    @MainActor
    func testSelectedShareSurvivesResetUntilTheServiceCompletes() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        await model.prepareCurrentSplatForSharing()
        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        defer {
            model.cancelSharing()
            ShareSnapshotStorage.remove(
                prepared.shareDirectory,
                expectedFileLeaf: prepared.shareURL.lastPathComponent
            )
        }
        let session = ShareSession(
            model: model,
            preparedItem: prepared,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = session
        model.isShareSheetActive = true
        let service = NSSharingService(
            title: "Test",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        session.sharingServicePicker(
            NSSharingServicePicker(items: [prepared.shareURL]),
            didChoose: service
        )

        model.reset()

        XCTAssertNil(model.activeShareSession)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 1)
        XCTAssertFalse(model.isShareSheetActive)
        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.shareURL.path))

        session.sharingService(service, didShareItems: [prepared.shareURL])

        XCTAssertNil(model.activeShareSession)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.shareDirectoryURL.path))
    }

    @MainActor
    func testSelectedShareSurvivesTerminationAndCleansOnFailureCallback() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        await model.prepareCurrentSplatForSharing()
        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        defer {
            model.cancelSharing()
            ShareSnapshotStorage.remove(
                prepared.shareDirectory,
                expectedFileLeaf: prepared.shareURL.lastPathComponent
            )
        }
        let session = ShareSession(
            model: model,
            preparedItem: prepared,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = session
        model.isShareSheetActive = true
        let service = NSSharingService(
            title: "Test",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        session.sharingServicePicker(
            NSSharingServicePicker(items: [prepared.shareURL]),
            didChoose: service
        )

        AppDelegate(model: model).applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertNil(model.activeShareSession)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.shareURL.path))

        session.sharingService(
            service,
            didFailToShareItems: [prepared.shareURL],
            error: CocoaError(.fileWriteUnknown)
        )

        XCTAssertNil(model.activeShareSession)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.shareDirectoryURL.path))
    }

    @MainActor
    func testNewAndBackNavigationDetachSelectedSharesWithoutDeletingTheirPayloads() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let outputURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )

        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL
        await model.prepareCurrentSplatForSharing()
        let newItem = try XCTUnwrap(model.test_preparedShareItem())
        let newSession = ShareSession(
            model: model,
            preparedItem: newItem,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = newSession
        model.isShareSheetActive = true
        let newService = NSSharingService(
            title: "New navigation",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        newSession.sharingServicePicker(
            NSSharingServicePicker(items: [newItem.shareURL]),
            didChoose: newService
        )
        var selectedProjectURL: URL? = projectURL

        RootView.prepareNewSplat(
            model: model,
            selectedProjectURL: &selectedProjectURL
        )

        XCTAssertNil(selectedProjectURL)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newItem.shareURL.path))

        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL
        await model.prepareCurrentSplatForSharing()
        let backItem = try XCTUnwrap(model.test_preparedShareItem())
        let backSession = ShareSession(
            model: model,
            preparedItem: backItem,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = backSession
        model.isShareSheetActive = true
        let backService = NSSharingService(
            title: "Back navigation",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        backSession.sharingServicePicker(
            NSSharingServicePicker(items: [backItem.shareURL]),
            didChoose: backService
        )
        selectedProjectURL = projectURL

        RootView.prepareProjectList(
            model: model,
            selectedProjectURL: &selectedProjectURL
        )

        XCTAssertNil(selectedProjectURL)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newItem.shareURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backItem.shareURL.path))

        newSession.sharingService(newService, didShareItems: [newItem.shareURL])
        backSession.sharingService(
            backService,
            didFailToShareItems: [backItem.shareURL],
            error: CocoaError(.fileWriteUnknown)
        )
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newItem.shareDirectoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backItem.shareDirectoryURL.path))
    }

    @MainActor
    func testOlderShareCompletionCannotDeleteANewerInFlightPayload() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")

        await model.prepareCurrentSplatForSharing()
        let olderItem = try XCTUnwrap(model.test_preparedShareItem())
        let olderSession = ShareSession(
            model: model,
            preparedItem: olderItem,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = olderSession
        model.isShareSheetActive = true
        let olderService = NSSharingService(
            title: "Older",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        olderSession.sharingServicePicker(
            NSSharingServicePicker(items: [olderItem.shareURL]),
            didChoose: olderService
        )

        await model.prepareCurrentSplatForSharing()
        let newerItem = try XCTUnwrap(model.test_preparedShareItem())
        let newerSession = ShareSession(
            model: model,
            preparedItem: newerItem,
            presenter: { _, _, _, _ in }
        )
        model.activeShareSession = newerSession
        model.isShareSheetActive = true
        let newerService = NSSharingService(
            title: "Newer",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        newerSession.sharingServicePicker(
            NSSharingServicePicker(items: [newerItem.shareURL]),
            didChoose: newerService
        )

        XCTAssertEqual(model.test_inFlightShareSessionCount(), 2)
        XCTAssertNotEqual(olderItem.shareDirectory, newerItem.shareDirectory)
        olderSession.sharingService(olderService, didShareItems: [olderItem.shareURL])

        XCTAssertEqual(model.test_inFlightShareSessionCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderItem.shareDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerItem.shareURL.path))

        newerSession.sharingService(
            newerService,
            didFailToShareItems: [newerItem.shareURL],
            error: CocoaError(.fileWriteUnknown)
        )
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newerItem.shareDirectoryURL.path))
    }

    @MainActor
    func testDuplicateOrConflictingServiceCallbacksReleaseTheSelectedSnapshotOnce() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        await model.prepareCurrentSplatForSharing()
        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        defer {
            ShareSnapshotStorage.remove(
                prepared.shareDirectory,
                expectedFileLeaf: prepared.shareURL.lastPathComponent
            )
        }
        var releaseCount = 0
        let session = ShareSession(
            model: model,
            preparedItem: prepared,
            presenter: { _, _, _, _ in },
            snapshotRemover: { _ in releaseCount += 1 }
        )
        model.activeShareSession = session
        model.isShareSheetActive = true
        let selectedService = NSSharingService(
            title: "Selected",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        let conflictingService = NSSharingService(
            title: "Conflicting",
            image: NSImage(size: NSSize(width: 16, height: 16)),
            alternateImage: nil,
            handler: {}
        )
        session.sharingServicePicker(
            NSSharingServicePicker(items: [prepared.shareURL]),
            didChoose: selectedService
        )

        session.sharingService(
            conflictingService,
            didFailToShareItems: [prepared.shareURL],
            error: CocoaError(.fileWriteUnknown)
        )
        session.sharingService(selectedService, didShareItems: [prepared.shareURL])
        session.sharingService(selectedService, didShareItems: [prepared.shareURL])
        session.sharingService(
            selectedService,
            didFailToShareItems: [prepared.shareURL],
            error: CocoaError(.fileWriteUnknown)
        )

        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(model.test_inFlightShareSessionCount(), 0)
    }

    @MainActor
    func testApplicationTerminationCleansPreparedShareSnapshot() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        await model.prepareCurrentSplatForSharing()
        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.shareURL.path))

        let delegate = AppDelegate(model: model)
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.activeShareSession)
        XCTAssertFalse(model.isShareSheetActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.shareDirectoryURL.path))
    }

    @MainActor
    func testSharePreparationCarriesPersistedDigestAndRejectsAChangedFileSnapshot() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let outputURL = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")
        let snapshot = try ProjectArtifactSnapshotStore.load(projectURL: projectURL)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL

        await model.prepareCurrentSplatForSharing()

        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        XCTAssertEqual(prepared.validatedSHA256, snapshot.trainingArtifact?.outputSHA256)
        XCTAssertEqual(prepared.byteCount, snapshot.trainingArtifact?.outputBytes)
        XCTAssertFalse(
            ProjectSummary.hasSameLocation(prepared.shareURL, outputURL),
            "Share must use an app-owned immutable snapshot, not the live project output."
        )
        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(at: prepared.shareURL),
            .valid
        )
        XCTAssertTrue(model.isShareReady)
        let shareDirectoryURL = prepared.shareDirectoryURL

        let handle = try FileHandle(forWritingTo: outputURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        await model.presentPreparedShare(from: NSButton())

        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.activeShareSession)
        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareDirectoryURL.path))
    }

    @MainActor
    func testPreparedShareRejectsSameSizeInPlaceMutationWithRestoredModificationDate() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        await model.prepareCurrentSplatForSharing()

        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        defer {
            try? FileManager.default.removeItem(at: prepared.shareDirectoryURL)
            _ = ShareSnapshotStorage.remove(
                prepared.shareDirectory,
                expectedFileLeaf: prepared.shareURL.lastPathComponent
            )
        }
        let originalBytes = try Data(contentsOf: prepared.shareURL)
        var replacementByte = try XCTUnwrap(originalBytes.last)
        replacementByte ^= 0xff
        let handle = try FileHandle(forWritingTo: prepared.shareURL)
        try handle.seek(toOffset: UInt64(originalBytes.count - 1))
        try handle.write(contentsOf: Data([replacementByte]))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: prepared.shareSnapshot.modificationDate],
            ofItemAtPath: prepared.shareURL.path
        )

        XCTAssertEqual(
            try XCTUnwrap(
                prepared.shareURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            ),
            originalBytes.count
        )
        let mutatedSnapshot = try XCTUnwrap(ShareFileSnapshot.capture(at: prepared.shareURL))
        XCTAssertEqual(mutatedSnapshot.deviceNumber, prepared.shareSnapshot.deviceNumber)
        XCTAssertEqual(mutatedSnapshot.fileNumber, prepared.shareSnapshot.fileNumber)
        XCTAssertEqual(mutatedSnapshot.byteCount, prepared.shareSnapshot.byteCount)
        XCTAssertEqual(
            mutatedSnapshot.modificationDate.timeIntervalSince1970,
            prepared.shareSnapshot.modificationDate.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertNotEqual(mutatedSnapshot.sha256, prepared.shareSnapshot.sha256)
        XCTAssertNotEqual(
            mutatedSnapshot,
            prepared.shareSnapshot,
            "Content changes must invalidate a snapshot even when size and mtime are restored."
        )
        let mutatedBytes = try Data(contentsOf: prepared.shareURL)

        let shareDirectoryURL = prepared.shareDirectoryURL
        await model.presentPreparedShare(from: NSButton())

        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.activeShareSession)
        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: shareDirectoryURL.path),
            "Cleanup must refuse a snapshot whose registered file identity changed."
        )
        XCTAssertEqual(try Data(contentsOf: prepared.shareURL), mutatedBytes)

        try FileManager.default.removeItem(at: prepared.shareDirectoryURL)
        XCTAssertEqual(
            ShareSnapshotStorage.remove(
                prepared.shareDirectory,
                expectedFileLeaf: prepared.shareURL.lastPathComponent
            ),
            .alreadyAbsent,
            "Once the deliberately corrupted test fixture is gone, its authenticated lease must be retired."
        )
    }

    func testShareIdentitySnapshotReusesOnlyAValidatedLowercaseDigest() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fileURL = base.appendingPathComponent("splat.ply", isDirectory: false)
        try Data("validated share fixture".utf8).write(to: fileURL, options: .atomic)

        let hashedSnapshot = try XCTUnwrap(ShareFileSnapshot.capture(at: fileURL))
        XCTAssertEqual(
            ShareFileSnapshot.captureIdentity(
                at: fileURL,
                verifiedSHA256: hashedSnapshot.sha256
            ),
            hashedSnapshot
        )
        XCTAssertNil(
            ShareFileSnapshot.captureIdentity(
                at: fileURL,
                verifiedSHA256: hashedSnapshot.sha256.uppercased()
            )
        )
        XCTAssertNil(
            ShareFileSnapshot.captureIdentity(
                at: fileURL,
                verifiedSHA256: String(repeating: "g", count: 64)
            )
        )

        let symbolicLink = base.appendingPathComponent("linked.ply", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: fileURL)
        XCTAssertNil(
            ShareFileSnapshot.captureIdentity(
                at: symbolicLink,
                verifiedSHA256: hashedSnapshot.sha256
            )
        )
    }

    func testShareFileSnapshotHashingCancelsBetweenBoundedReads() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fileURL = base.appendingPathComponent("share.bin", isDirectory: false)
        try Data(repeating: 0x5a, count: 512).write(to: fileURL)
        let probe = ShareHashCancellationProbe()

        XCTAssertThrowsError(
            try ShareFileSnapshot.capture(
                at: fileURL,
                shouldCancel: { probe.isCancelled },
                read: { descriptor, bytes, count in
                    let result = Darwin.read(descriptor, bytes, min(count, 64))
                    if result > 0 {
                        probe.recordRead()
                    }
                    return result
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(probe.readCount, 2)
    }

    func testShareSnapshotStorageIgnoresTheFormerPredictableSymlinkRoot() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let external = base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: external.path
        )
        let sentinel = external.appendingPathComponent("sentinel.txt", isDirectory: false)
        try Data("unchanged".utf8).write(to: sentinel)
        let formerRoot = base.appendingPathComponent(
            "EasySplatShareSnapshots",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: formerRoot, withDestinationURL: external)

        let registryURL = base
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("share-leases.json", isDirectory: false)
        let snapshotDirectory = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL
        )
        defer {
            ShareSnapshotStorage.remove(
                snapshotDirectory,
                expectedFileLeaf: "splat.ply"
            )
        }

        XCTAssertEqual(snapshotDirectory.url.deletingLastPathComponent(), base.standardizedFileURL)
        XCTAssertNotEqual(snapshotDirectory.url.lastPathComponent, formerRoot.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o755
        )
    }

    func testShareSnapshotStorageRejectsASymlinkOrFileTemporaryRootWithoutMutation() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let external = base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: external.path
        )
        let sentinel = external.appendingPathComponent("sentinel.txt", isDirectory: false)
        try Data("external bytes".utf8).write(to: sentinel)
        let linkedRoot = base.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: external)

        XCTAssertThrowsError(try ShareSnapshotStorage.create(in: linkedRoot))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("external bytes".utf8))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o755
        )

        let fileRoot = base.appendingPathComponent("file-root", isDirectory: false)
        try Data("root bytes".utf8).write(to: fileRoot)
        let fileMode = (try FileManager.default.attributesOfItem(atPath: fileRoot.path)[.posixPermissions]
            as? NSNumber)?.intValue
        XCTAssertThrowsError(try ShareSnapshotStorage.create(in: fileRoot))
        XCTAssertEqual(try Data(contentsOf: fileRoot), Data("root bytes".utf8))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: fileRoot.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            fileMode
        )
    }

    func testShareSnapshotReclamationRemovesOnlyExpiredRegisteredDeadLaunches() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryURL = base
            .appendingPathComponent("Registry", isDirectory: true)
            .appendingPathComponent("share-leases.json", isDirectory: false)
        let currentLaunchID = UUID()
        let previousLaunchID = UUID()
        let now = Date(timeIntervalSince1970: 50_000)

        let expired = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL,
            launchID: previousLaunchID,
            now: now.addingTimeInterval(-3_600)
        )
        let expiredURL = expired.url.appendingPathComponent("expired.ply")
        try ShareSnapshotStorage.prepareForPublication(
            expired,
            expectedFileLeaf: expiredURL.lastPathComponent,
            now: now.addingTimeInterval(-3_600)
        )
        try Data("expired share".utf8).write(to: expiredURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: expiredURL.path
        )
        try ShareSnapshotStorage.recordPublishedFile(
            expired,
            snapshot: try XCTUnwrap(ShareFileSnapshot.capture(at: expiredURL)),
            now: now.addingTimeInterval(-3_600)
        )

        let fresh = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL,
            launchID: previousLaunchID,
            now: now.addingTimeInterval(-10)
        )
        let current = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL,
            launchID: currentLaunchID,
            now: now.addingTimeInterval(-3_600)
        )
        let lookalike = base.appendingPathComponent(
            "EasySplatShare.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: lookalike,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: lookalike.path
        )
        let sentinel = lookalike.appendingPathComponent("sentinel.txt")
        try Data("not ours".utf8).write(to: sentinel)

        let report = ShareSnapshotStorage.reclaimStaleSnapshots(
            registryURL: registryURL,
            currentLaunchID: currentLaunchID,
            now: now,
            minimumAge: 60,
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.refused, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.url.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("not ours".utf8))

        let secondReport = ShareSnapshotStorage.reclaimStaleSnapshots(
            registryURL: registryURL,
            currentLaunchID: currentLaunchID,
            now: now,
            minimumAge: 60,
            isProcessAlive: { _ in false }
        )
        XCTAssertEqual(secondReport.removed, 0)

        ShareSnapshotStorage.remove(fresh, expectedFileLeaf: nil)
        ShareSnapshotStorage.remove(current, expectedFileLeaf: nil)
    }

    func testShareSnapshotReclamationRefusesAReplacedRegisteredDirectory() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryURL = base
            .appendingPathComponent("Registry", isDirectory: true)
            .appendingPathComponent("share-leases.json", isDirectory: false)
        let now = Date(timeIntervalSince1970: 60_000)
        let registered = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL,
            launchID: UUID(),
            now: now.addingTimeInterval(-3_600)
        )
        let shareURL = registered.url.appendingPathComponent("splat.ply")
        try ShareSnapshotStorage.prepareForPublication(
            registered,
            expectedFileLeaf: shareURL.lastPathComponent,
            now: now.addingTimeInterval(-3_600)
        )
        try Data("registered bytes".utf8).write(to: shareURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: shareURL.path
        )
        try ShareSnapshotStorage.recordPublishedFile(
            registered,
            snapshot: try XCTUnwrap(ShareFileSnapshot.capture(at: shareURL)),
            now: now.addingTimeInterval(-3_600)
        )

        let parked = base.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.moveItem(at: registered.url, to: parked)
        let external = base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let sentinel = external.appendingPathComponent("sentinel.txt")
        try Data("do not remove".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: registered.url,
            withDestinationURL: external
        )

        let report = ShareSnapshotStorage.reclaimStaleSnapshots(
            registryURL: registryURL,
            currentLaunchID: UUID(),
            now: now,
            minimumAge: 60,
            isProcessAlive: { _ in false }
        )

        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.refused, 1)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("do not remove".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))

        try FileManager.default.removeItem(at: registered.url)
        try FileManager.default.moveItem(at: parked, to: registered.url)
        XCTAssertEqual(
            ShareSnapshotStorage.remove(
                registered,
                expectedFileLeaf: shareURL.lastPathComponent
            ),
            .removed
        )
    }

    func testShareSnapshotRegistryRejectsAHardLinkWithoutChangingItsTarget() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryParent = base.appendingPathComponent("Registry", isDirectory: true)
        try FileManager.default.createDirectory(
            at: registryParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let victim = base.appendingPathComponent("victim.txt", isDirectory: false)
        let victimBytes = Data("must remain unchanged".utf8)
        try victimBytes.write(to: victim)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o640))],
            ofItemAtPath: victim.path
        )
        let victimMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: victim.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let registryURL = registryParent.appendingPathComponent("share-leases.json")
        XCTAssertEqual(Darwin.link(victim.path, registryURL.path), 0)

        XCTAssertThrowsError(
            try ShareSnapshotStorage.create(
                in: base,
                registryURL: registryURL
            )
        )

        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: victim.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            victimMode
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: base.path)
                .contains(where: { $0.hasPrefix("EasySplatShare.") })
        )
    }

    func testShareSnapshotRegistryRejectsLegacySchemaWithoutChangingItOrUntrackedData() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryParent = base.appendingPathComponent("Registry", isDirectory: true)
        try FileManager.default.createDirectory(
            at: registryParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let registryURL = registryParent.appendingPathComponent("share-leases.json")
        let untracked = base.appendingPathComponent(
            "EasySplatShare.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: untracked,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let sentinel = untracked.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("legacy lease must not authorize deletion".utf8)
        try sentinelBytes.write(to: sentinel)
        let legacyDocument = Data(
            """
            {"schemaVersion":1,"records":[{"publishedFile":{"byteCount":1}}]}
            """.utf8
        )
        try legacyDocument.write(to: registryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: registryURL.path
        )

        XCTAssertThrowsError(
            try ShareSnapshotStorage.create(
                in: base,
                registryURL: registryURL
            )
        )

        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: registryURL), legacyDocument)
        let remainingSnapshots = try FileManager.default.contentsOfDirectory(atPath: base.path)
            .filter { $0.hasPrefix("EasySplatShare.") }
        XCTAssertEqual(remainingSnapshots, [untracked.lastPathComponent])
    }

    func testShareSnapshotCleanupRefusesAnUnrecordedExpectedFile() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryURL = base
            .appendingPathComponent("Registry", isDirectory: true)
            .appendingPathComponent("share-leases.json", isDirectory: false)
        let snapshotDirectory = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL
        )
        let shareURL = snapshotDirectory.url.appendingPathComponent("splat.ply")
        try ShareSnapshotStorage.prepareForPublication(
            snapshotDirectory,
            expectedFileLeaf: shareURL.lastPathComponent
        )
        let foreignBytes = Data("not authenticated by the lease".utf8)
        try foreignBytes.write(to: shareURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: shareURL.path
        )

        XCTAssertEqual(
            ShareSnapshotStorage.remove(
                snapshotDirectory,
                expectedFileLeaf: shareURL.lastPathComponent
            ),
            .refused
        )
        XCTAssertEqual(try Data(contentsOf: shareURL), foreignBytes)
    }

    func testShareSnapshotRemovalPrunesItsLeaseImmediately() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryURL = base
            .appendingPathComponent("Registry", isDirectory: true)
            .appendingPathComponent("share-leases.json", isDirectory: false)
        let oldLaunchID = UUID()
        let currentLaunchID = UUID()
        let now = Date(timeIntervalSince1970: 70_000)
        let snapshotDirectory = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL,
            launchID: oldLaunchID,
            now: now.addingTimeInterval(-3_600)
        )

        XCTAssertEqual(
            ShareSnapshotStorage.remove(snapshotDirectory, expectedFileLeaf: nil),
            .removed
        )
        let registryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL))
                as? [String: Any]
        )
        XCTAssertEqual((registryObject["records"] as? [Any])?.count, 0)
        XCTAssertEqual(
            ShareSnapshotStorage.reclaimStaleSnapshots(
                registryURL: registryURL,
                currentLaunchID: currentLaunchID,
                now: now,
                minimumAge: 0,
                isProcessAlive: { _ in false }
            ),
            ShareSnapshotReclamationReport()
        )
    }

    func testShareSnapshotCleanupRefusesASwappedDirectory() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: base.path
        )
        let registryURL = base
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("share-leases.json", isDirectory: false)
        let snapshotDirectory = try ShareSnapshotStorage.create(
            in: base,
            registryURL: registryURL
        )
        try Data("share bytes".utf8).write(
            to: snapshotDirectory.url.appendingPathComponent("splat.ply", isDirectory: false)
        )
        let parked = base.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.moveItem(at: snapshotDirectory.url, to: parked)

        let external = base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: external.path
        )
        let sentinel = external.appendingPathComponent("sentinel.txt", isDirectory: false)
        try Data("do not remove".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: snapshotDirectory.url,
            withDestinationURL: external
        )

        ShareSnapshotStorage.remove(snapshotDirectory, expectedFileLeaf: "splat.ply")

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("do not remove".utf8))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: external.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o755
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
        var swappedStatus = stat()
        XCTAssertEqual(lstat(snapshotDirectory.url.path, &swappedStatus), 0)
        XCTAssertEqual(swappedStatus.st_mode & S_IFMT, S_IFLNK)
    }

    @MainActor
    func testSharePreparationIsDiscardedWhenTheProjectChangesDuringValidation() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstProject = try makeFinishedProject(in: base, validOutput: true)
        let secondProject = base.appendingPathComponent("Second.easysplatproj", isDirectory: true)
        let firstOutput = ProjectPaths(root: firstProject).outputURL.appendingPathComponent("splat.ply")
        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidationToFinish = DispatchSemaphore(value: 0)
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base,
            finishedOutputValidator: { _ in
                validationStarted.signal()
                _ = allowValidationToFinish.wait(timeout: .now() + 2)
                return firstOutput
            }
        )
        model.currentProjectURL = firstProject
        model.outputPlyURL = firstOutput

        let preparation = Task { await model.prepareCurrentSplatForSharing() }
        let validationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: validationStarted.wait(timeout: .now() + 1))
            }
        }
        XCTAssertEqual(validationStartResult, .success)
        model.currentProjectURL = secondProject
        model.outputPlyURL = nil
        allowValidationToFinish.signal()
        await preparation.value

        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
    }

    @MainActor
    func testLazyShareRequestRunsValidationOffMainActorAndCanBeCancelled() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let outputURL = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")
        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidationToFinish = DispatchSemaphore(value: 0)
        let validationThread = ThreadObservation()
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base,
            finishedOutputValidator: { _ in
                validationThread.record(isMainThread: Thread.isMainThread)
                validationStarted.signal()
                _ = allowValidationToFinish.wait(timeout: .now() + 2)
                return outputURL
            }
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL

        XCTAssertFalse(model.isPreparingShare)
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.test_preparedShareItem())

        model.requestCurrentSplatShare(from: NSButton())
        let requestTask = try XCTUnwrap(model.sharePreparationTask)
        XCTAssertTrue(model.isPreparingShare)
        XCTAssertNil(model.test_preparedShareItem())

        let validationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: validationStarted.wait(timeout: .now() + 1))
            }
        }
        XCTAssertEqual(validationStartResult, .success)
        XCTAssertEqual(validationThread.wasMainThread, false)

        model.cancelSharing()
        allowValidationToFinish.signal()
        await requestTask.value

        XCTAssertFalse(model.isPreparingShare)
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertNil(model.activeShareSession)
        XCTAssertFalse(model.isShareSheetActive)
    }

    @MainActor
    func testLazyShareRequestDiscardsWorkWhenTheProjectChanges() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstProject = try makeFinishedProject(in: base, validOutput: true)
        let secondProject = base.appendingPathComponent("Second.easysplatproj", isDirectory: true)
        let firstOutput = ProjectPaths(root: firstProject).outputURL.appendingPathComponent("splat.ply")
        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidationToFinish = DispatchSemaphore(value: 0)
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base,
            finishedOutputValidator: { _ in
                validationStarted.signal()
                _ = allowValidationToFinish.wait(timeout: .now() + 2)
                return firstOutput
            }
        )
        model.currentProjectURL = firstProject
        model.outputPlyURL = firstOutput

        model.requestCurrentSplatShare(from: NSButton())
        let requestTask = try XCTUnwrap(model.sharePreparationTask)
        let validationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: validationStarted.wait(timeout: .now() + 1))
            }
        }
        XCTAssertEqual(validationStartResult, .success)

        model.currentProjectURL = secondProject
        model.outputPlyURL = nil
        allowValidationToFinish.signal()
        await requestTask.value

        XCTAssertFalse(model.isPreparingShare)
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertNil(model.activeShareSession)
        XCTAssertFalse(model.isShareSheetActive)
    }

    @MainActor
    func testRendererUsesThePersistedOpeningDirectionWithoutBlanketCalibration() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let opening = simd_normalize(SIMD3<Float>(0.4, 0.2, -1))

        XCTAssertTrue(
            renderer.applyBounds(
                center: SIMD3<Float>(2, 3, 4),
                radius: 8,
                openingDirection: opening,
                ifInteractionRevisionMatches: renderer.interactionRevision
            )
        )

        XCTAssertEqual(renderer.cameraState.forwardDirection.x, opening.x, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.forwardDirection.y, opening.y, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.forwardDirection.z, opening.z, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.sceneRadius, 8)
        XCTAssertGreaterThan(renderer.cameraState.clipPlanes.far, renderer.cameraState.clipPlanes.near)
    }

    @MainActor
    func testViewOnlyUprightFlipIsProperAndReversible() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let opening = simd_normalize(SIMD3<Float>(0.4, 0.3, -1))
        renderer.applyBounds(center: .zero, radius: 5)
        _ = renderer.applyBounds(
            center: .zero,
            radius: 5,
            openingDirection: opening,
            ifInteractionRevisionMatches: renderer.interactionRevision
        )

        renderer.setViewOnlyFlipActive(true)

        XCTAssertTrue(renderer.isViewOnlyFlipActive)
        XCTAssertEqual(renderer.cameraState.forwardDirection.y, -opening.y, accuracy: 1e-5)
        XCTAssertEqual(
            simd_length(renderer.cameraState.forwardDirection),
            1,
            accuracy: 1e-5
        )

        renderer.setViewOnlyFlipActive(false)

        XCTAssertFalse(renderer.isViewOnlyFlipActive)
        XCTAssertEqual(renderer.cameraState.forwardDirection.x, opening.x, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.forwardDirection.y, opening.y, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.forwardDirection.z, opening.z, accuracy: 1e-5)
    }

    @MainActor
    func testViewOnlyUprightFlipPreservesAndRoundTripsNavigatedCamera() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let center = SIMD3<Float>(3, -2, 7)
        let opening = simd_normalize(SIMD3<Float>(0.4, 0.3, -1))
        XCTAssertTrue(
            renderer.applyBounds(
                center: center,
                radius: 5,
                openingDirection: opening,
                ifInteractionRevisionMatches: renderer.interactionRevision
            )
        )
        renderer.orbit(deltaX: 37, deltaY: -19)
        renderer.pan(deltaX: 41, deltaY: -23)
        renderer.keyboardZoomIn()
        renderer.keyboardZoomIn()
        let before = renderer.cameraState
        let horizontal = simd_normalize(SIMD3<Float>(opening.x, 0, opening.z))
        let halfTurn: (SIMD3<Float>) -> SIMD3<Float> = { vector in
            2 * horizontal * simd_dot(horizontal, vector) - vector
        }

        renderer.setViewOnlyFlipActive(true)

        let flipped = renderer.cameraState
        let expectedTarget = center + halfTurn(before.target - center)
        let expectedForward = halfTurn(before.forwardDirection)
        XCTAssertEqual(flipped.target.x, expectedTarget.x, accuracy: 1e-4)
        XCTAssertEqual(flipped.target.y, expectedTarget.y, accuracy: 1e-4)
        XCTAssertEqual(flipped.target.z, expectedTarget.z, accuracy: 1e-4)
        XCTAssertEqual(flipped.forwardDirection.x, expectedForward.x, accuracy: 1e-4)
        XCTAssertEqual(flipped.forwardDirection.y, expectedForward.y, accuracy: 1e-4)
        XCTAssertEqual(flipped.forwardDirection.z, expectedForward.z, accuracy: 1e-4)
        XCTAssertEqual(flipped.distance, before.distance, accuracy: 1e-6)
        XCTAssertNotEqual(flipped.target, center)

        renderer.setViewOnlyFlipActive(false)

        let restored = renderer.cameraState
        XCTAssertEqual(restored.target.x, before.target.x, accuracy: 2e-4)
        XCTAssertEqual(restored.target.y, before.target.y, accuracy: 2e-4)
        XCTAssertEqual(restored.target.z, before.target.z, accuracy: 2e-4)
        XCTAssertEqual(restored.forwardDirection.x, before.forwardDirection.x, accuracy: 2e-4)
        XCTAssertEqual(restored.forwardDirection.y, before.forwardDirection.y, accuracy: 2e-4)
        XCTAssertEqual(restored.forwardDirection.z, before.forwardDirection.z, accuracy: 2e-4)
        XCTAssertEqual(restored.distance, before.distance, accuracy: 1e-6)
    }

    @MainActor
    func testNadirUprightFlipProducesAVisibleHalfTurnWithoutChangingDepth() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let opening = SIMD3<Float>(0, -1, 0)
        XCTAssertTrue(
            renderer.applyBounds(
                center: .zero,
                radius: 5,
                openingDirection: opening,
                ifInteractionRevisionMatches: renderer.interactionRevision
            )
        )
        let points = [
            SIMD3<Float>(1.25, 0.5, -0.75),
            SIMD3<Float>(-0.4, -0.25, 1.6),
            SIMD3<Float>(0.8, 1.1, 1.2),
        ]
        let beforeCamera = renderer.viewportCamera
        let before = points.map { point -> SIMD3<Float> in
            let clip = beforeCamera.projection
                * beforeCamera.view
                * SIMD4<Float>(point.x, point.y, point.z, 1)
            return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        }

        renderer.setViewOnlyFlipActive(true)

        let afterCamera = renderer.viewportCamera
        let after = points.map { point -> SIMD3<Float> in
            let clip = afterCamera.projection
                * afterCamera.view
                * SIMD4<Float>(point.x, point.y, point.z, 1)
            return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        }
        for index in points.indices {
            XCTAssertEqual(after[index].x, -before[index].x, accuracy: 2e-4)
            XCTAssertEqual(after[index].y, -before[index].y, accuracy: 2e-4)
            XCTAssertEqual(after[index].z, before[index].z, accuracy: 2e-5)
        }
    }

    @MainActor
    func testNearNadirUprightFlipUsesTheCameraHeadingContinuously() throws {
        let device = try requireMetalDevice()
        let directions = [
            simd_normalize(SIMD3<Float>(5e-6, -1, 5e-6)),
            simd_normalize(SIMD3<Float>(2e-5, -1, 2e-5)),
            simd_normalize(SIMD3<Float>(5e-5, -1, 5e-5)),
            simd_normalize(SIMD3<Float>(2e-4, -1, 2e-4)),
        ]
        let points = [
            SIMD3<Float>(1.25, 0.5, -0.75),
            SIMD3<Float>(-0.4, -0.25, 1.6),
        ]

        for opening in directions {
            let view = MTKView(
                frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
                device: device
            )
            let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
            XCTAssertTrue(
                renderer.applyBounds(
                    center: .zero,
                    radius: 5,
                    openingDirection: opening,
                    ifInteractionRevisionMatches: renderer.interactionRevision
                )
            )
            let beforeCamera = renderer.viewportCamera
            let before = points.map { point -> SIMD3<Float> in
                let clip = beforeCamera.projection
                    * beforeCamera.view
                    * SIMD4<Float>(point.x, point.y, point.z, 1)
                return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            }

            renderer.setViewOnlyFlipActive(true)

            let afterCamera = renderer.viewportCamera
            let after = points.map { point -> SIMD3<Float> in
                let clip = afterCamera.projection
                    * afterCamera.view
                    * SIMD4<Float>(point.x, point.y, point.z, 1)
                return SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            }
            for index in points.indices {
                XCTAssertEqual(after[index].x, -before[index].x, accuracy: 3e-4)
                XCTAssertEqual(after[index].y, -before[index].y, accuracy: 3e-4)
                XCTAssertEqual(after[index].z, before[index].z, accuracy: 2e-5)
            }
        }
    }

    @MainActor
    func testPersistedFlipUsesTheIncomingOpeningDirectionOnFirstFit() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let opening = simd_normalize(SIMD3<Float>(0.7, 0.4, -0.2))
        renderer.setViewOnlyFlipActive(true)
        let revision = renderer.interactionRevision

        XCTAssertTrue(
            renderer.applyBounds(
                center: .zero,
                radius: 5,
                openingDirection: opening,
                ifInteractionRevisionMatches: revision
            )
        )

        XCTAssertEqual(renderer.cameraState.forwardDirection.x, opening.x, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.forwardDirection.y, -opening.y, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.forwardDirection.z, opening.z, accuracy: 1e-5)
    }

    @MainActor
    func testLateBoundsRebaseSceneScaleWithoutOverridingInteraction() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let expectedRevision = renderer.interactionRevision
        renderer.orbit(deltaX: 30, deltaY: -20)
        let interacted = renderer.cameraState
        let center = SIMD3<Float>(10, 20, 30)
        let radius: Float = 40
        let relativeTarget = (interacted.target - interacted.sceneCenter) / interacted.sceneRadius
        let relativeDistance = interacted.distance / interacted.sceneRadius

        XCTAssertFalse(
            renderer.applyBounds(
                center: center,
                radius: radius,
                openingDirection: SIMD3<Float>(0, 0, -1),
                ifInteractionRevisionMatches: expectedRevision
            )
        )

        XCTAssertEqual(renderer.cameraState.target, center + relativeTarget * radius)
        XCTAssertEqual(renderer.cameraState.yaw, interacted.yaw)
        XCTAssertEqual(renderer.cameraState.pitch, interacted.pitch)
        XCTAssertEqual(renderer.cameraState.distance, relativeDistance * radius, accuracy: 1e-5)
        XCTAssertEqual(renderer.cameraState.sceneRadius, radius)
        XCTAssertGreaterThan(renderer.cameraState.clipPlanes.far, renderer.cameraState.clipPlanes.near)
    }

    @MainActor
    func testPreparedSceneConfigurationDoesNotRedrawTheDisplayedSplatBeforeActivation() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        let oldBounds = ViewerSceneBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)
        let newBounds = ViewerSceneBounds(center: SIMD3<Float>(20, 30, 40), radius: 50)
        controller.prepareSceneConfiguration(
            SplatViewerSceneConfiguration(bounds: oldBounds)
        )
        let displayedCamera = renderer.cameraState

        controller.prepareSceneConfiguration(
            SplatViewerSceneConfiguration(
                bounds: newBounds,
                openingDirection: SIMD3<Float>(1, 0, 0),
                isViewOnlyFlipActive: true
            ),
            activate: false
        )

        XCTAssertEqual(renderer.cameraState, displayedCamera)
        XCTAssertFalse(renderer.isViewOnlyFlipActive)

        controller.activatePreparedSceneConfiguration()

        XCTAssertEqual(renderer.cameraState.target, newBounds.center)
        XCTAssertEqual(renderer.cameraState.sceneRadius, newBounds.radius)
        XCTAssertTrue(renderer.isViewOnlyFlipActive)
    }

    func testAuthenticatedBoundsOutsideTheCameraEnvelopeBecomeATypedConfigurationFailure() {
        let configuration = SplatViewerSceneConfiguration(
            bounds: ViewerSceneBounds(
                center: SIMD3<Float>(.greatestFiniteMagnitude, 0, 0),
                radius: .greatestFiniteMagnitude
            )
        )

        XCTAssertNil(configuration.bounds)
        XCTAssertEqual(
            configuration.validationError,
            .sceneBoundsOutsideSupportedRange
        )
    }

    @MainActor
    func testInvalidAuthenticatedBoundsCannotPublishAReadyPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let splatURL = directory.appendingPathComponent("result.ply")
        try writeResultPly(to: splatURL)
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer
        var observedStates: [SplatViewerLoadState] = []
        coordinator.onLoadStateChanged = { observedStates.append($0) }

        coordinator.requestLoad(
            url: splatURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(
                    center: SIMD3<Float>(.greatestFiniteMagnitude, 0, 0),
                    radius: .greatestFiniteMagnitude
                )
            )
        )

        await waitForViewerLoadState(.failed, on: view)
        XCTAssertEqual(
            controller.errorMessage,
            SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange.localizedDescription
        )
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertFalse(controller.hasRenderedPreview)
        XCTAssertNil(renderer.model)
        XCTAssertEqual(
            observedStates,
            [
                .loading,
                .failed(
                    SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange.localizedDescription
                ),
            ]
        )

        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testMissingAuthenticatedBoundsCannotReplaceAnExistingPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.ply")
        let replacementURL = directory.appendingPathComponent("replacement.ply")
        try writeResultPly(to: originalURL)
        try writeResultPly(to: replacementURL)
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer
        var observedStates: [SplatViewerLoadState] = []
        coordinator.onLoadStateChanged = { observedStates.append($0) }

        coordinator.requestLoad(
            url: originalURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: SIMD3<Float>(2, 3, 4), radius: 8)
            )
        )
        await waitForViewerLoadState(.ready, on: view)
        let originalRenderer = try XCTUnwrap(renderer.modelRenderer as? SplatRenderer)
        let originalCamera = renderer.cameraState
        observedStates.removeAll()

        coordinator.requestLoad(
            url: replacementURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration()
        )
        for _ in 0..<500 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            controller.errorMessage,
            SplatViewerConfigurationError.missingAuthenticatedSceneBounds.localizedDescription
        )
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertTrue(controller.hasRenderedPreview)
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        XCTAssertEqual(renderer.model, .gaussianSplat(originalURL))
        XCTAssertTrue((renderer.modelRenderer as? SplatRenderer) === originalRenderer)
        XCTAssertEqual(renderer.cameraState, originalCamera)
        XCTAssertEqual(
            observedStates,
            [
                .loading,
                .failed(
                    SplatViewerConfigurationError.missingAuthenticatedSceneBounds.localizedDescription
                ),
            ]
        )

        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testInvalidBoundsArrivingDuringDecodeCannotReplaceAnExistingPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.ply")
        let replacementURL = directory.appendingPathComponent("replacement.ply")
        try writeResultPly(to: originalURL)
        try writeResultPly(to: replacementURL)
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer
        var observedStates: [SplatViewerLoadState] = []
        coordinator.onLoadStateChanged = { observedStates.append($0) }

        coordinator.requestLoad(
            url: originalURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: SIMD3<Float>(2, 3, 4), radius: 8)
            )
        )
        await waitForViewerLoadState(.ready, on: view)
        let originalRenderer = try XCTUnwrap(renderer.modelRenderer as? SplatRenderer)
        let originalCamera = renderer.cameraState
        observedStates.removeAll()

        let candidatePrepared = AsyncSignal()
        let allowPublication = AsyncSignal()
        coordinator.modelLoadPreparer = { renderer, model, forceReload in
            let prepared = try await renderer.prepareModelLoad(
                model,
                forceReload: forceReload
            )
            candidatePrepared.signal()
            await allowPublication.wait()
            return prepared
        }
        let validReplacementConfiguration = SplatViewerSceneConfiguration(
            bounds: ViewerSceneBounds(center: SIMD3<Float>(20, 30, 40), radius: 50)
        )
        coordinator.requestLoad(
            url: replacementURL,
            reloadToken: 0,
            configuration: validReplacementConfiguration
        )
        await candidatePrepared.wait()

        coordinator.requestLoad(
            url: replacementURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(
                    center: SIMD3<Float>(.greatestFiniteMagnitude, 0, 0),
                    radius: .greatestFiniteMagnitude
                )
            )
        )
        allowPublication.signal()
        for _ in 0..<500 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            controller.errorMessage,
            SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange.localizedDescription
        )
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertTrue(controller.hasRenderedPreview)
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        XCTAssertEqual(renderer.model, .gaussianSplat(originalURL))
        XCTAssertTrue((renderer.modelRenderer as? SplatRenderer) === originalRenderer)
        XCTAssertEqual(renderer.cameraState, originalCamera)
        XCTAssertEqual(
            observedStates,
            [
                .loading,
                .failed(
                    SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange.localizedDescription
                ),
            ]
        )

        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testPreparedSceneActivationDrawsOnlyAfterTheEntireConfigurationIsInstalled() throws {
        let device = try requireMetalDevice()
        let view = DrawRecordingMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        controller.prepareSceneConfiguration(
            SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 2)
            )
        )

        var drawSnapshots: [(target: SIMD3<Float>, radius: Float, flipped: Bool)] = []
        view.onDraw = {
            drawSnapshots.append(
                (
                    target: renderer.cameraState.target,
                    radius: renderer.cameraState.sceneRadius,
                    flipped: renderer.isViewOnlyFlipActive
                )
            )
        }
        let newBounds = ViewerSceneBounds(
            center: SIMD3<Float>(20, 30, 40),
            radius: 50
        )
        controller.prepareSceneConfiguration(
            SplatViewerSceneConfiguration(
                bounds: newBounds,
                openingDirection: SIMD3<Float>(1, 0, 0),
                isViewOnlyFlipActive: true
            ),
            activate: false
        )

        controller.activatePreparedSceneConfiguration()

        XCTAssertEqual(drawSnapshots.count, 1)
        XCTAssertEqual(drawSnapshots.first?.target, newBounds.center)
        XCTAssertEqual(drawSnapshots.first?.radius, newBounds.radius)
        XCTAssertEqual(drawSnapshots.first?.flipped, true)
    }

    @MainActor
    func testPreparedSceneActivationPreservesInteractionThatOccurredWhileLoading() throws {
        let device = try requireMetalDevice()
        let view = MTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        let newBounds = ViewerSceneBounds(
            center: SIMD3<Float>(20, 30, 40),
            radius: 50
        )
        controller.prepareSceneConfiguration(
            SplatViewerSceneConfiguration(
                bounds: newBounds,
                openingDirection: SIMD3<Float>(1, 0, 0),
                isViewOnlyFlipActive: true
            ),
            activate: false
        )
        renderer.orbit(deltaX: 30, deltaY: -20)
        renderer.pan(deltaX: 12, deltaY: -7)
        renderer.keyboardZoomIn()
        let interactedCamera = renderer.cameraState
        let relativeTarget = (
            interactedCamera.target - interactedCamera.sceneCenter
        ) / interactedCamera.sceneRadius
        let relativeDistance = interactedCamera.distance / interactedCamera.sceneRadius

        controller.activatePreparedSceneConfiguration()

        XCTAssertEqual(
            renderer.cameraState.target,
            newBounds.center + relativeTarget * newBounds.radius
        )
        XCTAssertEqual(renderer.cameraState.yaw, interactedCamera.yaw)
        XCTAssertEqual(renderer.cameraState.pitch, interactedCamera.pitch)
        XCTAssertEqual(
            renderer.cameraState.distance,
            relativeDistance * newBounds.radius,
            accuracy: 1e-5
        )
        XCTAssertEqual(renderer.cameraState.sceneRadius, newBounds.radius)
        XCTAssertTrue(renderer.isViewOnlyFlipActive)
    }

    func testCancelledSerialModelLoadCannotBlockOrPublishStaleWork() async throws {
        let executor = SerialModelLoadExecutor(
            queue: DispatchQueue(label: "com.easysplat.tests.model-load")
        )
        let started = AsyncSignal()
        let release = DispatchSemaphore(value: 0)
        let staleWorkPublished = LockedBoolean()
        let abandonedLoad = Task {
            try await executor.perform { cancellation in
                started.signal()
                release.wait()
                try cancellation.checkCancellation()
                staleWorkPublished.setTrue()
                return 1
            }
        }
        await started.wait()

        abandonedLoad.cancel()
        release.signal()

        do {
            _ = try await abandonedLoad.value
            XCTFail("Expected the abandoned model load to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let nextResult = try await executor.perform { cancellation in
            try cancellation.checkCancellation()
            return 2
        }

        XCTAssertEqual(nextResult, 2)
        XCTAssertFalse(staleWorkPublished.value)
    }

    @MainActor
    func testSupersededPreparedModelNeverCommitsOrPublishesReady() async throws {
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer

        let firstURL = URL(fileURLWithPath: "/tmp/first.ply")
        let secondURL = URL(fileURLWithPath: "/tmp/second.ply")
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()
        coordinator.modelLoadPreparer = { _, model, _ in
            if model == .gaussianSplat(firstURL) {
                firstStarted.signal()
                await releaseFirst.wait()
            }
            return .replacement(model: model, renderer: nil)
        }
        var readyModels: [ModelIdentifier?] = []
        coordinator.onLoadStateChanged = { state in
            if state == .ready {
                readyModels.append(renderer.model)
            }
        }

        coordinator.requestLoad(
            url: firstURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 1)
            )
        )
        await firstStarted.wait()
        coordinator.requestLoad(
            url: secondURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: SIMD3<Float>(2, 3, 4), radius: 5)
            )
        )
        releaseFirst.signal()

        let secondRequest = PreviewLoadRequest(url: secondURL, reloadToken: 0)
        for _ in 0..<500 where coordinator.displayedRequest != secondRequest {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.displayedRequest, secondRequest)
        XCTAssertEqual(renderer.model, .gaussianSplat(secondURL))
        XCTAssertEqual(readyModels, [.gaussianSplat(secondURL)])
        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testSupersededPreparedModelFailureIsNotPublished() async throws {
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer

        let firstURL = URL(fileURLWithPath: "/tmp/failed-first.ply")
        let secondURL = URL(fileURLWithPath: "/tmp/replacement.ply")
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()
        coordinator.modelLoadPreparer = { _, model, _ in
            if model == .gaussianSplat(firstURL) {
                firstStarted.signal()
                await releaseFirst.wait()
                throw ViewerReplacementTestError.rejected
            }
            return .replacement(model: model, renderer: nil)
        }
        var observedStates: [SplatViewerLoadState] = []
        coordinator.onLoadStateChanged = { observedStates.append($0) }

        coordinator.requestLoad(
            url: firstURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 1)
            )
        )
        await firstStarted.wait()
        coordinator.requestLoad(
            url: secondURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: SIMD3<Float>(2, 3, 4), radius: 5)
            )
        )
        releaseFirst.signal()

        let secondRequest = PreviewLoadRequest(url: secondURL, reloadToken: 0)
        for _ in 0..<500 where coordinator.displayedRequest != secondRequest {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.displayedRequest, secondRequest)
        XCTAssertEqual(renderer.model, .gaussianSplat(secondURL))
        XCTAssertFalse(observedStates.contains(.failed(ViewerReplacementTestError.rejected.localizedDescription)))
        XCTAssertNil(controller.errorMessage)
        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testDeferredRequestKeepsItsConfigurationOffTheDisplayedSplat() throws {
        let device = try requireMetalDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        let oldBounds = ViewerSceneBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)
        controller.prepareSceneConfiguration(
            SplatViewerSceneConfiguration(bounds: oldBounds)
        )
        let displayedCamera = renderer.cameraState
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.recordInteraction()

        coordinator.requestLoad(
            url: URL(fileURLWithPath: "/tmp/b.ply"),
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: SIMD3<Float>(90, 80, 70), radius: 60),
                openingDirection: SIMD3<Float>(1, 0, 0),
                isViewOnlyFlipActive: true
            )
        )

        XCTAssertEqual(renderer.cameraState, displayedCamera)
        XCTAssertFalse(renderer.isViewOnlyFlipActive)
        XCTAssertEqual(controller.currentBounds, oldBounds)
    }

    @MainActor
    func testMissingAuthenticatedBoundsCannotPublishAReadyPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let splatURL = directory.appendingPathComponent("result.ply")
        try writeResultPly(to: splatURL)
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer
        view.setViewerLoadState(.ready)

        coordinator.requestLoad(
            url: splatURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration()
        )

        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(view.accessibilityValue() as? String, "Loading")

        await waitForViewerLoadState(.failed, on: view)
        XCTAssertEqual(
            controller.errorMessage,
            SplatViewerConfigurationError.missingAuthenticatedSceneBounds.localizedDescription
        )
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertFalse(controller.hasRenderedPreview)
        XCTAssertNil(renderer.model)

        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testCoordinatorKeepsRenderedPreviewReadyAcrossReplacementLoad() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let splatURL = directory.appendingPathComponent("result.ply")
        try writeResultPly(to: splatURL)
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer

        coordinator.requestLoad(
            url: splatURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 1)
            )
        )
        XCTAssertEqual(view.accessibilityValue() as? String, "Loading")
        XCTAssertFalse(controller.isLoading)

        await waitForViewerLoadState(.ready, on: view)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.hasRenderedPreview)

        coordinator.requestLoad(
            url: splatURL,
            reloadToken: 1,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 1)
            )
        )
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        XCTAssertFalse(controller.isUpdating)

        let replacement = PreviewLoadRequest(url: splatURL, reloadToken: 1)
        for _ in 0..<500 where coordinator.displayedRequest != replacement {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.displayedRequest, replacement)
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testMalformedReplacementKeepsPriorPreviewReadyWithoutOfferingRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validURL = directory.appendingPathComponent("valid.ply")
        let invalidURL = directory.appendingPathComponent("invalid.ply")
        try writeResultPly(to: validURL)
        try Data("not a ply".utf8).write(to: invalidURL)
        let device = try requireMetalDevice()
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        let coordinator = MetalKitSceneView.Coordinator()
        coordinator.renderer = renderer
        coordinator.controller = controller
        coordinator.interactiveView = view
        controller.renderer = renderer
        var observedStates: [SplatViewerLoadState] = []
        coordinator.onLoadStateChanged = { observedStates.append($0) }

        coordinator.requestLoad(
            url: validURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 1)
            )
        )
        await waitForViewerLoadState(.ready, on: view)
        XCTAssertTrue(controller.hasRenderedPreview)
        observedStates.removeAll()

        coordinator.requestLoad(
            url: invalidURL,
            reloadToken: 0,
            configuration: SplatViewerSceneConfiguration(
                bounds: ViewerSceneBounds(center: .zero, radius: 1)
            )
        )
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        for _ in 0..<500 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.loadErrorTitle, "Couldn’t update splat")
        XCTAssertFalse(controller.canRetryLoad)
        XCTAssertFalse(controller.isLoading)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertTrue(controller.hasRenderedPreview)
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        XCTAssertEqual(renderer.model, .gaussianSplat(validURL))
        XCTAssertEqual(
            observedStates,
            [.loading, .failed("Header start missing")]
        )

        MetalKitSceneView.dismantleNSView(view, coordinator: coordinator)
    }

    @MainActor
    func testExportCopiesOnlyAValidatedFinishedPly() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Exported.ply")
        try await model.exportCurrentSplat(to: destination)

        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(at: destination),
            .valid
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            try Data(contentsOf: ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply"))
        )
    }

    @MainActor
    func testCancellingExportCancelsDetachedPublicationAndPreservesDestination() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL
        let destination = base.appendingPathComponent("Keep Me.ply")
        let original = Data("existing destination".utf8)
        try original.write(to: destination)
        let publicationStarted = DispatchSemaphore(value: 0)
        let allowPublication = DispatchSemaphore(value: 0)

        let export = Task { @MainActor in
            do {
                try await model.exportCurrentSplat(
                    to: destination,
                    publisher: { _, destination, _ in
                        publicationStarted.signal()
                        _ = allowPublication.wait(timeout: .now() + 2)
                        try Task.checkCancellation()
                        try Data("stale publication".utf8).write(to: destination)
                    }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: publicationStarted.wait(timeout: .now() + 1)
                )
            }
        }
        XCTAssertEqual(didStart, .success)

        export.cancel()
        allowPublication.signal()

        let wasCancelled = await export.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    @MainActor
    func testCancellingSharePreparationCancelsPublicationAndRemovesItsOwnedSnapshot() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let outputURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        let outputBytes = try Data(contentsOf: outputURL)
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL
        let publicationStarted = AsyncSignal()
        let cancellationObserved = LockedBoolean()
        let publishedDestination = LockedURL()

        let preparation = Task {
            await model.prepareCurrentSplatForSharing(
                publisher: { _, destination, _ in
                    publishedDestination.set(destination)
                    publicationStarted.signal()
                    let deadline = Date().addingTimeInterval(2)
                    while !Task.isCancelled, Date() < deadline {
                        usleep(1_000)
                    }
                    if Task.isCancelled {
                        cancellationObserved.setTrue()
                        throw CancellationError()
                    }
                    throw CocoaError(.userCancelled)
                }
            )
        }
        await publicationStarted.wait()

        preparation.cancel()
        await preparation.value

        let destination = try XCTUnwrap(publishedDestination.value)
        XCTAssertTrue(cancellationObserved.value)
        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
        XCTAssertFalse(model.isPreparingShare)
        XCTAssertEqual(try Data(contentsOf: outputURL), outputBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.deletingLastPathComponent().path
            )
        )
    }

    @MainActor
    func testFinishedOutputValidationRunsOutsideTheMainThread() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let outputURL = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")
        let observation = ThreadObservation()
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base,
            finishedOutputValidator: { requestedProjectURL in
                observation.record(isMainThread: Thread.isMainThread)
                return requestedProjectURL.standardizedFileURL == projectURL.standardizedFileURL
                    ? outputURL
                    : nil
            }
        )
        model.currentProjectURL = projectURL

        let validatedURL = try await model.validatedCurrentSplatForExport()

        XCTAssertEqual(validatedURL.standardizedFileURL, outputURL.standardizedFileURL)
        XCTAssertEqual(observation.wasMainThread, false)
    }

    @MainActor
    func testInvalidExportNeverReplacesExistingDestination() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: false)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Keep Me.ply")
        let original = Data("existing destination".utf8)
        try original.write(to: destination)

        do {
            try await model.exportCurrentSplat(to: destination)
            XCTFail("Expected invalid output to be rejected")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    @MainActor
    func testValidPlyFromUnfinishedProjectIsNotExportable() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true, stage: .trainSplat)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Must Not Exist.ply")
        do {
            try await model.exportCurrentSplat(to: destination)
            XCTFail("Expected unfinished output to be rejected")
        } catch {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testBeginNewSplatClearsTheCurrentResultAndPendingInput() {
        let model = AppModel(toolchainManager: ResultTestToolchainManager())
        model.viewState = .viewer
        model.currentProjectURL = URL(fileURLWithPath: "/tmp/Old.easysplatproj")
        model.outputPlyURL = URL(fileURLWithPath: "/tmp/Old.easysplatproj/Output/splat.ply")
        model.pendingVideoURLs = [URL(fileURLWithPath: "/tmp/new.mov")]
        var selectedProjectURL: URL? = model.currentProjectURL

        RootView.prepareNewSplat(model: model, selectedProjectURL: &selectedProjectURL)

        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(model.outputPlyURL)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertNil(selectedProjectURL)
    }

    @MainActor
    func testBackToProjectsClearsTheCurrentProjectAndSelectionButKeepsPendingInput() {
        let model = AppModel(toolchainManager: ResultTestToolchainManager())
        let pendingInput = URL(fileURLWithPath: "/tmp/retry.mov")
        model.viewState = .processing
        model.currentProjectURL = URL(fileURLWithPath: "/tmp/Failed.easysplatproj")
        model.lastError = "Capture failed"
        model.pendingVideoURLs = [pendingInput]
        var selectedProjectURL: URL? = model.currentProjectURL

        RootView.prepareProjectList(model: model, selectedProjectURL: &selectedProjectURL)

        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.pendingVideoURLs, [pendingInput])
        XCTAssertNil(selectedProjectURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasySplat-result-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitForViewerLoadState(
        _ state: SplatViewerAccessibilityLoadState,
        on view: InteractiveMTKView
    ) async {
        for _ in 0..<200 {
            if view.accessibilityValue() as? String == state.rawValue {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for viewer load state \(state.rawValue)")
    }

    private func makeFinishedProject(
        in base: URL,
        validOutput: Bool,
        stage: PipelineStage = .done,
        includeTrainingArtifact: Bool = true
    ) throws -> URL {
        let projectURL = base.appendingPathComponent("Result.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let controlledVideoRelativePath = "Originals/video-0000.mov"
        let controlledVideoURL = paths.originalsURL.appendingPathComponent(
            "video-0000.mov",
            isDirectory: false
        )
        let controlledVideoBytes = Data("result-workspace-video-fixture".utf8)
        try controlledVideoBytes.write(to: controlledVideoURL, options: .atomic)
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: controlledVideoURL)
        let analysisPolicy = VideoFrameAnalysisPolicy(
            targetFrameCeiling: 250,
            targetFPS: 3
        )
        let analysisURL = paths.videoFrameAnalysisURL(index: 0)
        let analysisEvidence = try VideoFrameAnalysisArtifactStore.save(
            VideoFrameAnalysisArtifact(
                sourceIndex: 0,
                sourceProjectRelativePath: controlledVideoRelativePath,
                sourceByteCount: Int64(controlledVideoBytes.count),
                sourceSHA256: sourceSHA256,
                clipGroupID: "video_000",
                policy: analysisPolicy,
                trackID: 1,
                pixelWidth: 64,
                pixelHeight: 48,
                durationSeconds: 1,
                nominalFrameRate: 30,
                isHDR: false,
                decodedFrameCount: 3,
                hadRepairedTimestamps: false,
                transformA: 1,
                transformB: 0,
                transformC: 0,
                transformD: 1,
                transformTX: 0,
                transformTY: 0,
                candidates: [0, 1, 2].map { frameIndex in
                    VideoFrameAnalysisCandidate(
                        frameIndex: frameIndex,
                        timestampSeconds: Double(frameIndex) / 2,
                        presentationTimeValue: Int64(frameIndex * 15),
                        presentationTimeTimescale: 30,
                        sharpness: 1,
                        brightness: 0.5,
                        clippedFraction: 0,
                        motionScore: 0,
                        dHash: UInt64(frameIndex)
                    )
                }
            ),
            to: analysisURL,
            projectPaths: paths
        )
        let videoReceipt = VideoInputReceipt(
            projectRelativePath: controlledVideoRelativePath,
            safeDisplayName: "Capture.mov",
            byteCount: Int64(controlledVideoBytes.count),
            sha256: sourceSHA256,
            trackID: 1,
            pixelWidth: 64,
            pixelHeight: 48,
            durationSeconds: 1,
            nominalFrameRate: 30,
            isHDR: false,
            decodedFrameCount: 3,
            transformA: 1,
            transformB: 0,
            transformC: 0,
            transformD: 1,
            transformTX: 0,
            transformTY: 0,
            clipGroupID: "video_000",
            analysisPolicySHA256: analysisPolicy.sha256,
            analysisArtifactPath: try paths.projectRelativePath(for: analysisURL),
            analysisArtifactByteCount: analysisEvidence.byteCount,
            analysisArtifactSHA256: analysisEvidence.sha256
        )
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        if validOutput {
            try writeResultPly(to: outputURL)
        } else {
            try Data("not a ply".utf8).write(to: outputURL)
        }
        let trainingArtifact: TrainingArtifact?
        if validOutput, includeTrainingArtifact {
            let outputBytes = Int64(try XCTUnwrap(outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            let sceneBounds = try XCTUnwrap(SplatSceneBoundsCalculator.compute(
                at: outputURL,
                maximumSampleCount: RobustSplatBounds.maximumFallbackSampleCount
            ))
            trainingArtifact = TrainingArtifact(
                trainerVersion: "test",
                runtimeVersion: "native-metal-cli-v2",
                trainerBuildDigest: String(repeating: "a", count: 64),
                inputDigest: String(repeating: "b", count: 64),
                geometryDigest: String(repeating: "c", count: 64),
                datasetDerivation: makeAppTestMsplatDatasetDerivation(),
                detailProfile: .balanced,
                iterationLimit: 7_000,
                plateauWindow: 800,
                cameraOrderSeed: 42,
                completedIteration: 7_000,
                checkpointPath: nil,
                checkpointDigest: nil,
                outputPath: "Output/splat.ply",
                outputSHA256: try GeometryArtifactStore.sha256(of: outputURL),
                outputBytes: outputBytes,
                gaussianCount: 1,
                elapsedSeconds: 1,
                peakMemoryBytes: 1,
                memoryBudgetBytes: 1,
                resourceAdmission: makeAppTestTrainingResourceAdmission(),
                rasterFallbackCount: 0,
                rasterExactFallbackElapsedSeconds: 0,
                rasterExactBufferGrowthCount: 0,
                rasterExactBufferBytesAdded: 0,
                rasterReplayElapsedSeconds: 0,
                rasterPeakExactIntersectionCapacity: 0,
                droppedIntersectionCount: 0,
                sceneBounds: sceneBounds,
                completionStatus: .completed
            )
        } else {
            trainingArtifact = nil
        }
        var metadata = ProjectMetadata(
            title: "Result",
            input: .video(files: [controlledVideoRelativePath]),
            videoInputReceipts: [videoReceipt],
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
            state: PipelineState(stage: stage, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        if let trainingArtifact {
            try persistCompletedAppTestArtifacts(
                metadata: metadata,
                paths: paths,
                trainingArtifact: trainingArtifact
            )
        }
        return projectURL
    }

    private func writeResultPly(to url: URL) throws {
        let text = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func requireMetalDevice() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        return device
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown,
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: keyCode == 48 ? "\t" : "",
            charactersIgnoringModifiers: keyCode == 48 ? "\t" : "",
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    /// `NSEvent.mouseEvent` cannot set a button number, so middle-button events
    /// are built from a CGEvent that carries `.center` explicitly.
    private func middleMouseEvent(
        _ type: CGEventType,
        at location: CGPoint
    ) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    @MainActor
    private func installStrongViewerCallbackCycle(
        view: InteractiveMTKView,
        renderer: MetalKitSceneRenderer
    ) {
        view.onOrbit = { [renderer] _, _ in _ = renderer }
        view.onScrollZoom = { [renderer] _, _ in _ = renderer }
        view.onMagnify = { [renderer] _, _ in _ = renderer }
        view.onPan = { [renderer] _, _ in _ = renderer }
        view.onFreeLook = { [renderer] _, _ in _ = renderer }
        view.onKeyboardCommand = { [renderer] _ in _ = renderer }
        view.onMovementInputChanged = { [renderer] _, _ in _ = renderer }
        view.onInteractionActivity = { [renderer] in _ = renderer }
    }

    func testInspectorDefaultsClosedWhenTheCanvasWouldBeCrushed() {
        // The 920pt minimum window minus the 260pt sidebar leaves 660.
        XCTAssertFalse(ViewerView.initialInspectorPresentation(
            storedPreference: nil,
            workspaceWidth: 660
        ))
        // Sidebar collapsed at the minimum window: the full 920 has room.
        XCTAssertTrue(ViewerView.initialInspectorPresentation(
            storedPreference: nil,
            workspaceWidth: 920
        ))
        let threshold = ViewerView.inspectorIdealWidth + ViewerView.minimumComfortableCanvasWidth
        XCTAssertTrue(ViewerView.initialInspectorPresentation(
            storedPreference: nil,
            workspaceWidth: threshold
        ))
        XCTAssertFalse(ViewerView.initialInspectorPresentation(
            storedPreference: nil,
            workspaceWidth: threshold - 1
        ))
    }

    func testARememberedInspectorChoiceBeatsTheWidthRule() {
        XCTAssertTrue(ViewerView.initialInspectorPresentation(
            storedPreference: true,
            workspaceWidth: 400
        ))
        XCTAssertFalse(ViewerView.initialInspectorPresentation(
            storedPreference: false,
            workspaceWidth: 1400
        ))
    }
}

@MainActor
private final class DrawRecordingMTKView: MTKView {
    var onDraw: (() -> Void)?

    override func draw() {
        onDraw?()
    }
}

@MainActor
private final class ViewerFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasMainThread: Bool? {
        lock.withLock { value }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            value = isMainThread
        }
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            signaled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if signaled {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock {
            storage = true
        }
    }
}

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var value: URL? {
        lock.withLock { storage }
    }

    func set(_ value: URL) {
        lock.withLock {
            storage = value
        }
    }
}

private enum ViewerReplacementTestError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "The superseded preview failed."
    }
}

private final class ShareHashCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var isCancelled: Bool {
        lock.withLock { reads >= 2 }
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func recordRead() {
        lock.withLock {
            reads += 1
        }
    }
}

private struct ResultTestToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        fatalError("Result workspace tests do not install a toolchain")
    }
}
