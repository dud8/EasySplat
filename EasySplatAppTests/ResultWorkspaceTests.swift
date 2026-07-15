import AppKit
import Foundation
import MetalKit
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

final class ResultWorkspaceTests: XCTestCase {
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

    @MainActor
    func testApplyingNewBoundsClearsPriorPan() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))

        renderer.pan(deltaX: 12, deltaY: -7)
        XCTAssertNotEqual(renderer.pan, .zero)

        renderer.applyBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)

        XCTAssertEqual(renderer.pan, .zero)
    }

    @MainActor
    func testRendererKeepsCameraInteractionInLogicalPointsOnRetinaDisplays() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        renderer.applyBounds(center: .zero, radius: 5)
        let startingDistance = renderer.cameraState.distance

        renderer.keyboardZoomOut()

        XCTAssertEqual(renderer.cameraState.distance, startingDistance / 0.85, accuracy: 1e-5)
    }

    @MainActor
    func testInteractiveViewerProvidesAVisibleKeyboardFocusMask() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = InteractiveMTKView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            device: device
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
        activationSource = nil
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(activationSource === button)
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
    func testSharePreparationCarriesPersistedDigestAndRejectsAChangedFileSnapshot() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(
            in: base,
            validOutput: true,
            includeTrainingArtifact: true
        )
        let outputURL = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL

        await model.prepareCurrentSplatForSharing()

        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        XCTAssertEqual(prepared.validatedSHA256, metadata.trainingArtifact?.outputSHA256)
        XCTAssertEqual(prepared.byteCount, metadata.trainingArtifact?.outputBytes)
        XCTAssertTrue(model.isShareReady)

        let handle = try FileHandle(forWritingTo: outputURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        model.presentPreparedShare(from: NSButton())

        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
        XCTAssertNil(model.activeShareSession)
        XCTAssertTrue(model.shareStatusIsError)
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
    func testRendererUsesThePersistedOpeningDirectionWithoutBlanketCalibration() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    func testPersistedFlipUsesTheIncomingOpeningDirectionOnFirstFit() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
    func testLateBoundsUpdateClippingWithoutOverridingInteraction() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let expectedRevision = renderer.interactionRevision
        renderer.orbit(deltaX: 30, deltaY: -20)
        let interacted = renderer.cameraState

        XCTAssertFalse(
            renderer.applyBounds(
                center: SIMD3<Float>(10, 20, 30),
                radius: 40,
                openingDirection: SIMD3<Float>(0, 0, -1),
                ifInteractionRevisionMatches: expectedRevision
            )
        )

        XCTAssertEqual(renderer.cameraState.target, interacted.target)
        XCTAssertEqual(renderer.cameraState.yaw, interacted.yaw)
        XCTAssertEqual(renderer.cameraState.pitch, interacted.pitch)
        XCTAssertEqual(renderer.cameraState.distance, interacted.distance)
        XCTAssertEqual(renderer.cameraState.sceneRadius, 40)
    }

    @MainActor
    func testPreparedSceneConfigurationDoesNotRedrawTheDisplayedSplatBeforeActivation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        let oldBounds = ViewerSceneBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)
        let newBounds = ViewerSceneBounds(center: SIMD3<Float>(20, 30, 40), radius: 50)
        let oldRequest = PreviewLoadRequest(url: URL(fileURLWithPath: "/tmp/a.ply"), reloadToken: 0)
        let newRequest = PreviewLoadRequest(url: URL(fileURLWithPath: "/tmp/b.ply"), reloadToken: 0)
        controller.prepareBounds(
            for: oldRequest,
            configuration: SplatViewerSceneConfiguration(bounds: oldBounds)
        )
        let displayedCamera = renderer.cameraState

        controller.prepareBounds(
            for: newRequest,
            configuration: SplatViewerSceneConfiguration(
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

    @MainActor
    func testPreparedSceneActivationDrawsOnlyAfterTheEntireConfigurationIsInstalled() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = DrawRecordingMTKView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            device: device
        )
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        let oldRequest = PreviewLoadRequest(
            url: URL(fileURLWithPath: "/tmp/atomic-old.ply"),
            reloadToken: 0
        )
        controller.prepareBounds(
            for: oldRequest,
            configuration: SplatViewerSceneConfiguration(
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
        controller.prepareBounds(
            for: PreviewLoadRequest(
                url: URL(fileURLWithPath: "/tmp/atomic-new.ply"),
                reloadToken: 0
            ),
            configuration: SplatViewerSceneConfiguration(
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
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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
        controller.prepareBounds(
            for: PreviewLoadRequest(
                url: URL(fileURLWithPath: "/tmp/interacted-new.ply"),
                reloadToken: 0
            ),
            configuration: SplatViewerSceneConfiguration(
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

        controller.activatePreparedSceneConfiguration()

        XCTAssertEqual(renderer.cameraState.target, interactedCamera.target)
        XCTAssertEqual(renderer.cameraState.yaw, interactedCamera.yaw)
        XCTAssertEqual(renderer.cameraState.pitch, interactedCamera.pitch)
        XCTAssertEqual(renderer.cameraState.distance, interactedCamera.distance)
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
    func testDeferredRequestKeepsItsConfigurationOffTheDisplayedSplat() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))
        let controller = SplatViewerController()
        controller.renderer = renderer
        let oldBounds = ViewerSceneBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)
        controller.prepareBounds(
            for: PreviewLoadRequest(url: URL(fileURLWithPath: "/tmp/a.ply"), reloadToken: 0),
            configuration: SplatViewerSceneConfiguration(bounds: oldBounds)
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
    func testViewerBoundsIgnoreAnOlderRequestThatFinishesLast() async {
        let loader = ControlledBoundsLoader()
        let controller = SplatViewerController(boundsLoader: { url in
            await loader.load(url)
        })
        let oldURL = URL(fileURLWithPath: "/tmp/old.ply")
        let newURL = URL(fileURLWithPath: "/tmp/new.ply")
        let firstRequest = PreviewLoadRequest(url: oldURL, reloadToken: 0)

        controller.prepareBounds(for: firstRequest)
        controller.startBoundsLoad(for: firstRequest)
        await loader.waitUntilRequested(oldURL)
        await loader.complete(
            oldURL,
            with: ViewerSceneBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)
        )
        await waitForBounds(on: controller, center: SIMD3<Float>(1, 2, 3))

        let staleRequest = PreviewLoadRequest(url: oldURL, reloadToken: 1)
        controller.prepareBounds(for: staleRequest)
        controller.startBoundsLoad(for: staleRequest)
        await loader.waitUntilRequested(oldURL)
        XCTAssertNil(controller.currentBounds)

        let currentRequest = PreviewLoadRequest(url: newURL, reloadToken: 0)
        controller.prepareBounds(for: currentRequest)
        controller.startBoundsLoad(for: currentRequest)
        await loader.waitUntilRequested(newURL)
        await loader.complete(
            newURL,
            with: ViewerSceneBounds(center: SIMD3<Float>(7, 8, 9), radius: 10)
        )
        await waitForBounds(on: controller, center: SIMD3<Float>(7, 8, 9))

        await loader.complete(
            oldURL,
            with: ViewerSceneBounds(center: SIMD3<Float>(40, 50, 60), radius: 70)
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.currentBounds?.center, SIMD3<Float>(7, 8, 9))
        XCTAssertEqual(controller.currentBounds?.radius, 10)
    }

    @MainActor
    func testPersistedBoundsWinIfTheyArriveDuringFallbackSampling() async {
        let loader = ControlledBoundsLoader()
        let controller = SplatViewerController(boundsLoader: { url in
            await loader.load(url)
        })
        let url = URL(fileURLWithPath: "/tmp/result.ply")
        let request = PreviewLoadRequest(url: url, reloadToken: 0)
        controller.prepareBounds(for: request)
        controller.startBoundsLoad(for: request)
        await loader.waitUntilRequested(url)
        let persisted = ViewerSceneBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)

        controller.updateSceneConfiguration(
            SplatViewerSceneConfiguration(bounds: persisted)
        )
        await loader.complete(
            url,
            with: ViewerSceneBounds(center: SIMD3<Float>(90, 90, 90), radius: 900)
        )
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(controller.currentBounds, persisted)
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
    private func waitForBounds(
        on controller: SplatViewerController,
        center: SIMD3<Float>
    ) async {
        for _ in 0..<100 {
            if controller.currentBounds?.center == center {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for viewer bounds")
    }

    private func makeFinishedProject(
        in base: URL,
        validOutput: Bool,
        stage: PipelineStage = .done,
        includeTrainingArtifact: Bool = false
    ) throws -> URL {
        let projectURL = base.appendingPathComponent("Result.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        if validOutput {
            try writeResultPly(to: outputURL)
        } else {
            try Data("not a ply".utf8).write(to: outputURL)
        }
        let trainingArtifact: TrainingArtifact?
        if validOutput, includeTrainingArtifact {
            let outputBytes = Int64(try XCTUnwrap(outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize))
            trainingArtifact = TrainingArtifact(
                trainerVersion: "test",
                runtimeVersion: "native-metal-cli-v2",
                trainerBuildDigest: String(repeating: "a", count: 64),
                inputDigest: String(repeating: "b", count: 64),
                geometryDigest: String(repeating: "c", count: 64),
                detailProfile: .balanced,
                iterationLimit: 7_000,
                plateauWindow: 800,
                deterministicSeed: 42,
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
                rasterFallbackCount: 0,
                rasterExactFallbackElapsedSeconds: 0,
                rasterExactBufferGrowthCount: 0,
                rasterExactBufferBytesAdded: 0,
                rasterReplayElapsedSeconds: 0,
                rasterPeakExactIntersectionCapacity: 0,
                droppedIntersectionCount: 0,
                sceneBounds: SplatSceneBounds(center: .init(x: 0, y: 0, z: 0), radius: 1),
                completionStatus: .completed
            )
        } else {
            trainingArtifact = nil
        }
        let metadata = ProjectMetadata(
            title: "Result",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
            trainingArtifact: trainingArtifact,
            state: PipelineState(stage: stage, lastError: nil),
            outputs: OutputSpec(
                splatPlyPath: "Output/splat.ply",
                colmapModelPath: "SfM/colmap/sparse/0"
            )
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
}

private actor ControlledBoundsLoader {
    typealias Bounds = SplatViewerController.Bounds

    private var continuations: [URL: CheckedContinuation<Bounds?, Never>] = [:]
    private var requestWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func load(_ url: URL) async -> Bounds? {
        await withCheckedContinuation { continuation in
            continuations[url] = continuation
            let waiters = requestWaiters.removeValue(forKey: url) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilRequested(_ url: URL) async {
        guard continuations[url] == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[url, default: []].append(continuation)
        }
    }

    func complete(_ url: URL, with bounds: Bounds?) {
        continuations.removeValue(forKey: url)?.resume(returning: bounds)
    }
}

@MainActor
private final class DrawRecordingMTKView: MTKView {
    var onDraw: (() -> Void)?

    override func draw() {
        onDraw?()
    }
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
