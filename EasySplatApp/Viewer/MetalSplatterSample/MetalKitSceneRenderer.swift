#if os(iOS) || os(macOS)

import Foundation
import EasySplatCore
import Metal
import MetalKit
import MetalSplatter
import os
import QuartzCore
import simd
import SwiftUI

private struct SendableMetalDevice: @unchecked Sendable {
    let value: any MTLDevice
}

private struct SendableSplatRenderer: @unchecked Sendable {
    let value: SplatRenderer
}

private enum SceneBoundsApplicationResult: Equatable {
    case fitted
    case preservedView
    case rejected
}

enum PreparedViewerModelLoad {
    case unchanged
    case replacement(model: ModelIdentifier?, renderer: SplatRenderer?)
}

enum ViewerMemoryAdmissionPolicy {
    private static let mebibyte: UInt64 = 1_048_576
    private static let physicalMemoryUsePercent: UInt64 = 65
    private static let recommendedWorkingSetUsePercent: UInt64 = 80

    private static func scaled(_ value: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64 {
        let whole = (value / denominator) * numerator
        let remainder = ((value % denominator) * numerator) / denominator
        return whole.addingReportingOverflow(remainder).overflow ? UInt64.max : whole + remainder
    }

    static func resolveBudgetBytes(
        physicalMemoryBytes: UInt64,
        recommendedMaxWorkingSetBytes: UInt64,
        currentAllocatedBytes: UInt64,
        availableHostMemoryBytes: UInt64? = nil,
        memoryPressure: MemoryPressureState = .normal
    ) -> Int {
        let maximumRecoverableBytes = UInt64(
            resolveMaximumRecoverableBytes(
                physicalMemoryBytes: physicalMemoryBytes,
                recommendedMaxWorkingSetBytes: recommendedMaxWorkingSetBytes
            )
        )
        guard maximumRecoverableBytes > currentAllocatedBytes else { return 0 }
        let metalCapacity = maximumRecoverableBytes - currentAllocatedBytes

        let availableHostMemory = min(
            availableHostMemoryBytes ?? physicalMemoryBytes,
            physicalMemoryBytes
        )
        let hostReserve = min(
            availableHostMemory,
            max(512 * mebibyte, physicalMemoryBytes / 20)
        )
        let unpressuredHostCapacity = availableHostMemory - hostReserve
        let hostCapacity: UInt64 = switch memoryPressure {
        case .normal:
            unpressuredHostCapacity
        case .warning:
            scaled(unpressuredHostCapacity, numerator: 3, denominator: 5)
        case .critical:
            UInt64.zero
        case .unknown:
            scaled(unpressuredHostCapacity, numerator: 4, denominator: 5)
        }

        return Int(clamping: min(min(metalCapacity, hostCapacity), UInt64(Int.max)))
    }

    static func resolveMaximumRecoverableBytes(
        physicalMemoryBytes: UInt64,
        recommendedMaxWorkingSetBytes: UInt64
    ) -> Int {
        let physicalLimit = scaled(
            physicalMemoryBytes,
            numerator: physicalMemoryUsePercent,
            denominator: 100
        )
        let deviceLimit = recommendedMaxWorkingSetBytes > 0
            ? scaled(
                recommendedMaxWorkingSetBytes,
                numerator: recommendedWorkingSetUsePercent,
                denominator: 100
            )
            : UInt64.max
        return Int(clamping: min(physicalLimit, deviceLimit))
    }
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
    var onSortFailure: ((String) -> Void)?
    var onSortSuccess: (() -> Void)?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    private(set) var cameraState: ViewerCameraState
    private var sceneCenter: SIMD3<Float> = .zero
    private var sourceOpeningDirection = SIMD3<Float>(0, 0, -1)
    private(set) var isViewOnlyFlipActive = false

    private var heldMovementKeys: Set<ViewerMovementKey> = []
    private var isSprintKeyHeld = false
    private var lastFlightFrameTime: TimeInterval?
    private static let maximumFlightFrameDelta: TimeInterval = 0.1

    var pan: SIMD2<Float> {
        let displacement = cameraState.target - sceneCenter
        return SIMD2<Float>(
            simd_dot(displacement, cameraState.rightDirection),
            simd_dot(displacement, cameraState.upDirection)
        )
    }

    var interactionRevision: UInt64 { cameraState.interactionRevision }

    private(set) var drawableSize: CGSize = .zero
    /// Subordinate mode: the scene is a live training preview sharing the GPU with
    /// the trainer that produced it, so this view yields rather than competes.
    var isTrainingPreview = false
    private var lastPreviewDrawTime: CFTimeInterval?
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
        // Splat colours are sRGB code values and the trainer composites them in that
        // space, so the attachment must not linearise for blending. Colour management
        // moves to the layer instead: without an explicit colour space no matching
        // happens at all and the bytes land unconverted on a wide-gamut display.
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm
        metalKitView.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float_stencil8
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalKitView.enableSetNeedsDisplay = true
        metalKitView.isPaused = true
        metalKitView.preferredFramesPerSecond = Constants.idleFramesPerSecond
    }

    func load(_ model: ModelIdentifier?, forceReload: Bool = false) async throws {
        let prepared = try await prepareModelLoad(model, forceReload: forceReload)
        commitPreparedModelLoad(prepared)
    }

    func prepareModelLoad(
        _ model: ModelIdentifier?,
        forceReload: Bool = false
    ) async throws -> PreparedViewerModelLoad {
        if !forceReload, model == self.model {
            return .unchanged
        }
        lastLoadError = nil
        do {
            switch model {
            case .gaussianSplat(let url):
                let splat = try await loadSplatRenderer(from: url)
                return .replacement(model: model, renderer: splat)
            case .none:
                return .replacement(model: nil, renderer: nil)
            }
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    func commitPreparedModelLoad(_ prepared: PreparedViewerModelLoad) {
        guard case .replacement(let model, let renderer) = prepared else {
            requestDraw()
            return
        }

        if let renderer {
            installSortCallbacks(on: renderer)
        }
        detachSortCallbacks(from: modelRenderer)
        modelRenderer = renderer
        self.model = model
        requestDraw()
    }

    private func loadSplatRenderer(from url: URL) async throws -> SplatRenderer {
        let device = SendableMetalDevice(value: self.device)
        let colorFormat = metalKitView.colorPixelFormat
        let depthFormat = metalKitView.depthStencilPixelFormat
        let sampleCount = metalKitView.sampleCount
        let hostObservation = try? LiveTrainingResourceObserver().observe()
        let installedMemoryBytes = hostObservation?.installedMemoryBytes
            ?? ProcessInfo.processInfo.physicalMemory
        // A training preview shares the machine with the trainer that produced it,
        // so a failed observation must not be read as calm here: assuming normal
        // would let the preview allocate into headroom training is about to need.
        // The result viewer keeps its existing optimistic default — nothing is
        // competing with it.
        let observedPressure = hostObservation?.memoryPressure
            ?? (isTrainingPreview ? .unknown : .normal)
        let maximumWorkingSetBytes = ViewerMemoryAdmissionPolicy.resolveBudgetBytes(
            physicalMemoryBytes: installedMemoryBytes,
            recommendedMaxWorkingSetBytes: device.value.recommendedMaxWorkingSetSize,
            currentAllocatedBytes: UInt64(max(0, device.value.currentAllocatedSize)),
            availableHostMemoryBytes: hostObservation?.availableHostMemoryBytes,
            memoryPressure: observedPressure
        )
        let maximumRecoverableWorkingSetBytes =
            ViewerMemoryAdmissionPolicy.resolveMaximumRecoverableBytes(
                physicalMemoryBytes: installedMemoryBytes,
                recommendedMaxWorkingSetBytes: device.value.recommendedMaxWorkingSetSize
            )

        let loaded = try await Self.modelLoadExecutor.perform { cancellation in
            let splat = try SplatRenderer(
                device: device.value,
                colorFormat: colorFormat,
                depthFormat: depthFormat,
                stencilFormat: depthFormat,
                sampleCount: sampleCount,
                maxViewCount: 1,
                maxSimultaneousRenders: Constants.maxSimultaneousRenders,
                maximumWorkingSetBytes: maximumWorkingSetBytes,
                maximumRecoverableWorkingSetBytes: maximumRecoverableWorkingSetBytes
            )
            try splat.readPLY(
                from: url,
                shouldCancel: { cancellation.isCancelled }
            )
            return SendableSplatRenderer(value: splat)
        }
        return loaded.value
    }

    private func reportSortFailure(_ message: String) {
        onSortFailure?(message)
    }

    private func reportSortSuccess() {
        onSortSuccess?()
    }

    private func installSortCallbacks(on renderer: SplatRenderer) {
        renderer.onSortComplete = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestDraw()
            }
        }
        renderer.onSortFailure = { [weak self] failure in
            let message = failure.localizedDescription
            Task { @MainActor [weak self] in
                self?.reportSortFailure(message)
            }
        }
        renderer.onSortSuccess = { [weak self] in
            Task { @MainActor [weak self] in
                self?.reportSortSuccess()
            }
        }
    }

    private func detachSortCallbacks(from renderer: (any ModelRenderer)?) {
        guard let renderer = renderer as? SplatRenderer else { return }
        renderer.onSortComplete = nil
        renderer.onSortFailure = nil
        renderer.onSortSuccess = nil
    }

    func retrySortOrdering() {
        (modelRenderer as? SplatRenderer)?.resortIndices()
    }

    private func requestDraw() {
        // In continuous flight mode the view's own timer drives frames;
        // explicit draws on top would double-schedule.
        guard metalKitView.isPaused else { return }
        if isTrainingPreview {
            // Every draw resorts the scene on the CPU and submits Metal work. While
            // training holds the GPU, a dropped intermediate frame costs the user
            // nothing; stealing the cycle from the trainer costs them the run.
            let now = CACurrentMediaTime()
            let minimumInterval = 1.0 / Double(Constants.trainingPreviewFramesPerSecond)
            if let lastPreviewDrawTime, now - lastPreviewDrawTime < minimumInterval {
                return
            }
            lastPreviewDrawTime = now
        }
        metalKitView.draw()
    }

    /// While any movement key is held the view runs its own frame timer;
    /// on release it returns to on-demand drawing with one final frame so the
    /// splat sort settles on the resting camera.
    func setMovementInput(_ keys: Set<ViewerMovementKey>, isSprinting: Bool) {
        // Sustained 60 fps flight is the single most expensive thing this view can
        // do. A preview is for looking, not travelling, so it never enters flight.
        guard !isTrainingPreview else { return }
        let wasFlying = !heldMovementKeys.isEmpty
        heldMovementKeys = keys
        isSprintKeyHeld = isSprinting
        let isFlying = !heldMovementKeys.isEmpty
        guard isFlying != wasFlying else { return }
        if isFlying {
            lastFlightFrameTime = nil
            metalKitView.enableSetNeedsDisplay = false
            metalKitView.preferredFramesPerSecond = Constants.flightFramesPerSecond
            metalKitView.isPaused = false
        } else {
            metalKitView.isPaused = true
            metalKitView.enableSetNeedsDisplay = true
            metalKitView.preferredFramesPerSecond = Constants.idleFramesPerSecond
            requestDraw()
        }
    }

    /// The first tick after activation only establishes the clock baseline, and
    /// oversized gaps (stalls, wake from sleep) are clamped so the camera never
    /// teleports.
    func integrateFlight(now: TimeInterval) {
        guard !heldMovementKeys.isEmpty else { return }
        defer { lastFlightFrameTime = now }
        guard let lastFlightFrameTime else { return }
        let dt = Float(min(now - lastFlightFrameTime, Self.maximumFlightFrameDelta))
        guard dt > 0 else { return }

        let axes = heldMovementKeys.flightAxisVector
        guard axes != .zero else { return }
        let worldDirection = cameraState.rightDirection * axes.x
            + SIMD3<Float>(0, 1, 0) * axes.y
            + cameraState.forwardDirection * axes.z
        let lengthSquared = simd_length_squared(worldDirection)
        guard lengthSquared.isFinite, lengthSquared > 0 else { return }
        // Cap combined input at unit speed without normalizing: near-cancelling
        // combinations (forward plus up at a steep pitch) must stay slow.
        let direction = lengthSquared > 1
            ? worldDirection / sqrt(lengthSquared)
            : worldDirection
        let speed = cameraState.sceneRadius * Constants.flightSpeedPerSecond
            * (isSprintKeyHeld ? Constants.flightSprintMultiplier : 1)
        cameraState.flyTranslate(direction * speed * dt)
    }

    func freeLook(deltaX: Float, deltaY: Float) {
        cameraState.freeLook(
            deltaYaw: deltaX * Constants.orbitSpeed,
            deltaPitch: deltaY * Constants.orbitSpeed
        )
        requestDraw()
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
        let axis = ViewerCameraState.stableHorizontalHeading(for: openingDirection)
        let doubled = 2 * axis
        return matrix_float4x4(columns: (
            SIMD4<Float>(doubled.x * axis.x - 1, doubled.x * axis.y, doubled.x * axis.z, 0),
            SIMD4<Float>(doubled.y * axis.x, doubled.y * axis.y - 1, doubled.y * axis.z, 0),
            SIMD4<Float>(doubled.z * axis.x, doubled.z * axis.y, doubled.z * axis.z - 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
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
        integrateFlight(now: CACurrentMediaTime())
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
        let result = applyBoundsWithoutDrawing(
            center: center,
            radius: radius,
            openingDirection: openingDirection,
            ifInteractionRevisionMatches: expectedRevision
        )
        requestDraw()
        return result == .fitted
    }

    @discardableResult
    func activateSceneConfiguration(
        bounds: ViewerSceneBounds?,
        openingDirection: SIMD3<Float>?,
        isViewOnlyFlipActive: Bool,
        ifInteractionRevisionMatches expectedRevision: UInt64,
        requestDraw shouldRequestDraw: Bool = true
    ) -> Bool {
        let previousFlipState = self.isViewOnlyFlipActive
        self.isViewOnlyFlipActive = isViewOnlyFlipActive
        let result: SceneBoundsApplicationResult
        if let bounds {
            result = applyBoundsWithoutDrawing(
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
            result = .preservedView
        }
        guard result != .rejected else {
            self.isViewOnlyFlipActive = previousFlipState
            return false
        }
        if shouldRequestDraw {
            requestDraw()
        }
        return true
    }

    private func applyBoundsWithoutDrawing(
        center: SIMD3<Float>,
        radius: Float,
        openingDirection: SIMD3<Float>?,
        ifInteractionRevisionMatches expectedRevision: UInt64
    ) -> SceneBoundsApplicationResult {
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
                return .rejected
            }
        }
        sceneCenter = center
        sourceOpeningDirection = sourceDirection
        return didFit ? .fitted : .preservedView
    }

    @discardableResult
    func setViewOnlyFlipActive(_ active: Bool) -> Bool {
        guard active != isViewOnlyFlipActive else { return true }
        let rotation = flipRotationMatrix
        let current = cameraState
        let transformedOffset = transformedVector(
            current.target - sceneCenter,
            by: rotation
        )
        let transformedTarget = sceneCenter + transformedOffset
        let transformedForward = transformedDirection(
            current.forwardDirection,
            by: rotation
        )
        let effectiveDirection = active
            ? transformedDirection(sourceOpeningDirection, by: rotation)
            : sourceOpeningDirection

        guard cameraState.applyViewOnlyPose(
            target: transformedTarget,
            forwardDirection: transformedForward,
            openingDirection: effectiveDirection
        ) else { return false }

        isViewOnlyFlipActive = active
        requestDraw()
        return true
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

    private func transformedVector(
        _ vector: SIMD3<Float>,
        by matrix: matrix_float4x4
    ) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

#endif // os(iOS) || os(macOS)
