#if os(iOS) || os(macOS)

import Foundation
import Metal
import MetalKit
import MetalSplatter
import os
import simd
import SwiftUI

private struct SendableMetalDevice: @unchecked Sendable {
    let value: any MTLDevice
}

private struct SendableSplatRenderer: @unchecked Sendable {
    let value: SplatRenderer
}

final class ModelLoadCancellationToken: @unchecked Sendable {
    private enum State {
        case active
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state = State.active

    var isCancelled: Bool {
        lock.withLock { state == .cancelled }
    }

    func cancel() {
        lock.withLock {
            if state == .active {
                state = .cancelled
            }
        }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    fileprivate func complete() throws {
        try lock.withLock {
            guard state == .active else {
                throw CancellationError()
            }
            state = .completed
        }
    }
}

struct SerialModelLoadExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (ModelLoadCancellationToken) throws -> Value
    ) async throws -> Value {
        let cancellation = ModelLoadCancellationToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.checkCancellation()
                        let value = try operation(cancellation)
                        try cancellation.complete()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

@MainActor
class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "EasySplat",
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?
    private(set) var lastLoadError: String? = nil

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    private(set) var cameraState: ViewerCameraState
    private var sceneCenter: SIMD3<Float> = .zero
    private var sourceOpeningDirection = SIMD3<Float>(0, 0, -1)
    private(set) var isViewOnlyFlipActive = false

    var pan: SIMD2<Float> {
        let displacement = cameraState.target - sceneCenter
        return SIMD2<Float>(
            simd_dot(displacement, cameraState.rightDirection),
            simd_dot(displacement, cameraState.upDirection)
        )
    }

    var interactionRevision: UInt64 { cameraState.interactionRevision }

    private(set) var drawableSize: CGSize = .zero
    private static let modelLoadExecutor = SerialModelLoadExecutor(
        queue: DispatchQueue(label: "com.easysplat.model-load", qos: .userInitiated)
    )

    init?(_ metalKitView: MTKView) {
        guard let device = metalKitView.device else { return nil }
        self.device = device
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        self.drawableSize = metalKitView.drawableSize
        self.cameraState = ViewerCameraState(
            viewportSize: metalKitView.bounds.size,
            verticalFOV: Float(Constants.fovy.radians)
        )
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float_stencil8
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalKitView.enableSetNeedsDisplay = true
        metalKitView.isPaused = true
        metalKitView.preferredFramesPerSecond = 24
    }

    func load(_ model: ModelIdentifier?, forceReload: Bool = false) async throws {
        if !forceReload, model == self.model {
            return
        }
        self.model = model

        modelRenderer = nil
        lastLoadError = nil
        do {
            switch model {
            case .gaussianSplat(let url):
                let splat = try await loadSplatRenderer(from: url)
                splat.onSortComplete = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.requestDraw()
                    }
                }
                modelRenderer = splat
            case .none:
                break
            }
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    private func loadSplatRenderer(from url: URL) async throws -> SplatRenderer {
        let device = SendableMetalDevice(value: self.device)
        let colorFormat = metalKitView.colorPixelFormat
        let depthFormat = metalKitView.depthStencilPixelFormat
        let sampleCount = metalKitView.sampleCount

        let loaded = try await Self.modelLoadExecutor.perform { cancellation in
            let splat = try SplatRenderer(
                device: device.value,
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                stencilFormat: depthFormat,
                sampleCount: sampleCount,
                maxViewCount: 1,
                maxSimultaneousRenders: Constants.maxSimultaneousRenders
            )
            try splat.readPLY(
                from: url,
                shouldCancel: { cancellation.isCancelled }
            )
            return SendableSplatRenderer(value: splat)
        }
        return loaded.value
    }

    private func requestDraw() {
        metalKitView.draw()
    }

    var viewportCamera: ModelRenderer.CameraMatrices {
        let aspect = max(cameraState.viewportSize.width / cameraState.viewportSize.height, 0.001)
        let clip = cameraState.clipPlanes
        let projectionMatrix = matrix_perspective_right_hand(
            fovyRadians: cameraState.verticalFOV,
            aspectRatio: Float(aspect),
            nearZ: clip.near,
            farZ: clip.far
        )
        let viewMatrix = lookAtMatrix(
            eye: cameraState.cameraPosition,
            right: cameraState.rightDirection,
            up: cameraState.upDirection,
            forward: cameraState.forwardDirection
        )
        let modelMatrix = viewOnlyModelMatrix

        return (projection: projectionMatrix,
                view: viewMatrix * modelMatrix,
                screenSize: SIMD2(
                    x: max(1, Int(drawableSize.width)),
                    y: max(1, Int(drawableSize.height))
                ))
    }

    private var viewOnlyModelMatrix: matrix_float4x4 {
        guard isViewOnlyFlipActive else { return matrix_identity_float4x4 }
        let rotation = flipRotationMatrix
        return matrix4x4_translation(sceneCenter.x, sceneCenter.y, sceneCenter.z)
            * rotation
            * matrix4x4_translation(-sceneCenter.x, -sceneCenter.y, -sceneCenter.z)
    }

    private var flipRotationMatrix: matrix_float4x4 {
        flipRotationMatrix(for: sourceOpeningDirection)
    }

    private func flipRotationMatrix(for openingDirection: SIMD3<Float>) -> matrix_float4x4 {
        let horizontal = SIMD3<Float>(openingDirection.x, 0, openingDirection.z)
        let axis: SIMD3<Float>
        let lengthSquared = simd_length_squared(horizontal)
        if lengthSquared.isFinite, lengthSquared > 1e-8 {
            axis = horizontal / sqrt(lengthSquared)
        } else {
            axis = SIMD3<Float>(1, 0, 0)
        }
        return matrix4x4_rotation(radians: .pi, axis: axis)
    }

    private func lookAtMatrix(
        eye: SIMD3<Float>,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        forward: SIMD3<Float>
    ) -> matrix_float4x4 {
        let backward = -forward
        return matrix_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, backward.x, 0),
            SIMD4<Float>(right.y, up.y, backward.y, 0),
            SIMD4<Float>(right.z, up.z, backward.z, 0),
            SIMD4<Float>(
                -simd_dot(right, eye),
                -simd_dot(up, eye),
                -simd_dot(backward, eye),
                1
            )
        ))
    }

    func draw(in view: MTKView) {
        guard let modelRenderer else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }
        modelRenderer.willRender(viewportCameras: [viewportCamera])

        if let renderPassDescriptor = view.currentRenderPassDescriptor,
           let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            modelRenderer.render(viewportCameras: [viewportCamera], to: renderEncoder)
            renderEncoder.endEncoding()
            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
        }

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        cameraState.updateViewportSize(view.bounds.size)
        requestDraw()
    }

    func orbit(deltaX: Float, deltaY: Float) {
        cameraState.orbit(
            deltaYaw: deltaX * Constants.orbitSpeed,
            deltaPitch: deltaY * Constants.orbitSpeed
        )
        requestDraw()
    }

    func zoom(delta: Float) {
        zoomByScroll(delta: delta, anchoredAt: nil)
    }

    func zoomByScroll(delta: Float, anchoredAt pointer: CGPoint?) {
        cameraState.zoomByScroll(delta: delta, anchoredAt: pointer)
        requestDraw()
    }

    func zoomByPinch(magnification: Float, anchoredAt pointer: CGPoint?) {
        cameraState.zoomByPinch(magnification: magnification, anchoredAt: pointer)
        requestDraw()
    }

    func keyboardZoomIn() {
        cameraState.zoomIn()
        requestDraw()
    }

    func keyboardZoomOut() {
        cameraState.zoomOut()
        requestDraw()
    }

    func pan(deltaX: Float, deltaY: Float) {
        cameraState.pan(screenDelta: SIMD2<Float>(deltaX, -deltaY))
        requestDraw()
    }

    func resetCamera() {
        cameraState.reset()
        requestDraw()
    }

    func fitToView() {
        cameraState.fit()
        requestDraw()
    }

    func applyBounds(center: SIMD3<Float>, radius: Float) {
        _ = applyBounds(
            center: center,
            radius: radius,
            openingDirection: nil,
            ifInteractionRevisionMatches: interactionRevision
        )
    }

    @discardableResult
    func applyBounds(
        center: SIMD3<Float>,
        radius: Float,
        openingDirection: SIMD3<Float>?,
        ifInteractionRevisionMatches expectedRevision: UInt64
    ) -> Bool {
        let didFit = applyBoundsWithoutDrawing(
            center: center,
            radius: radius,
            openingDirection: openingDirection,
            ifInteractionRevisionMatches: expectedRevision
        )
        requestDraw()
        return didFit
    }

    @discardableResult
    func activateSceneConfiguration(
        bounds: ViewerSceneBounds?,
        openingDirection: SIMD3<Float>?,
        isViewOnlyFlipActive: Bool,
        ifInteractionRevisionMatches expectedRevision: UInt64
    ) -> Bool {
        self.isViewOnlyFlipActive = isViewOnlyFlipActive
        let didFit: Bool
        if let bounds {
            didFit = applyBoundsWithoutDrawing(
                center: bounds.center,
                radius: bounds.radius,
                openingDirection: openingDirection,
                ifInteractionRevisionMatches: expectedRevision
            )
        } else {
            let sourceDirection = sanitizedDirection(openingDirection)
            let effectiveDirection = isViewOnlyFlipActive
                ? transformedDirection(
                    sourceDirection,
                    by: flipRotationMatrix(for: sourceDirection)
                )
                : sourceDirection
            let current = cameraState
            cameraState = ViewerCameraState(
                target: current.target,
                sceneRadius: current.sceneRadius,
                openingDirection: effectiveDirection,
                viewportSize: current.viewportSize,
                verticalFOV: current.verticalFOV,
                yaw: current.yaw,
                pitch: current.pitch,
                distance: current.distance,
                interactionRevision: current.interactionRevision
            )
            sourceOpeningDirection = sourceDirection
            didFit = false
        }
        requestDraw()
        return didFit
    }

    private func applyBoundsWithoutDrawing(
        center: SIMD3<Float>,
        radius: Float,
        openingDirection: SIMD3<Float>?,
        ifInteractionRevisionMatches expectedRevision: UInt64
    ) -> Bool {
        let sourceDirection = sanitizedDirection(openingDirection)
        let effectiveDirection = isViewOnlyFlipActive
            ? transformedDirection(
                sourceDirection,
                by: flipRotationMatrix(for: sourceDirection)
            )
            : sourceDirection
        let didFit = cameraState.applyBounds(
            center: center,
            radius: radius,
            openingDirection: effectiveDirection,
            ifInteractionRevisionMatches: expectedRevision
        )
        if !didFit {
            guard cameraState.adoptBoundsPreservingView(
                center: center,
                radius: radius,
                openingDirection: effectiveDirection
            ) else {
                return false
            }
        }
        sceneCenter = center
        sourceOpeningDirection = sourceDirection
        return didFit
    }

    func setViewOnlyFlipActive(_ active: Bool) {
        guard active != isViewOnlyFlipActive else { return }
        isViewOnlyFlipActive = active
        let effectiveDirection = active
            ? transformedDirection(sourceOpeningDirection, by: flipRotationMatrix)
            : sourceOpeningDirection
        cameraState = ViewerCameraState(
            target: sceneCenter,
            sceneRadius: cameraState.sceneRadius,
            openingDirection: effectiveDirection,
            viewportSize: cameraState.viewportSize,
            verticalFOV: cameraState.verticalFOV,
            interactionRevision: cameraState.interactionRevision &+ 1
        )
        requestDraw()
    }

    private func sanitizedDirection(_ direction: SIMD3<Float>?) -> SIMD3<Float> {
        let candidate = direction ?? SIMD3<Float>(0, 0, -1)
        let largest = max(abs(candidate.x), abs(candidate.y), abs(candidate.z))
        guard candidate.x.isFinite,
              candidate.y.isFinite,
              candidate.z.isFinite,
              largest.isFinite,
              largest > 0 else {
            return SIMD3<Float>(0, 0, -1)
        }
        let scaled = candidate / largest
        return scaled / sqrt(simd_length_squared(scaled))
    }

    private func transformedDirection(
        _ direction: SIMD3<Float>,
        by matrix: matrix_float4x4
    ) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(direction.x, direction.y, direction.z, 0)
        return sanitizedDirection(SIMD3<Float>(transformed.x, transformed.y, transformed.z))
    }
}

#endif // os(iOS) || os(macOS)
