#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import simd
import SwiftUI

private struct SendableMetalDevice: @unchecked Sendable {
    let value: any MTLDevice
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

    private var yaw: Float = 0
    private var pitch: Float = 0
    private var distance: Float = Constants.defaultDistance
    private var pan: SIMD2<Float> = .zero
    private var center: SIMD3<Float> = .zero
    private let defaultYaw: Float = 0
    private let defaultPitch: Float = 0
    private let defaultDistance: Float = Constants.defaultDistance
    private let defaultPan: SIMD2<Float> = .zero

    var drawableSize: CGSize = .zero
    private static let modelLoadQueue = DispatchQueue(label: "com.easysplat.model-load", qos: .userInitiated)

    init?(_ metalKitView: MTKView) {
        guard let device = metalKitView.device else { return nil }
        self.device = device
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
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
                modelRenderer = splat
                requestDraw()
            case .none:
                requestDraw()
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

        return try await withCheckedThrowingContinuation { continuation in
            Self.modelLoadQueue.async {
                do {
                    let splat = try SplatRenderer(
                        device: device.value,
                        colorFormat: colorFormat,
                        depthFormat: depthFormat,
                        stencilFormat: depthFormat,
                        sampleCount: sampleCount,
                        maxViewCount: 1,
                        maxSimultaneousRenders: Constants.maxSimultaneousRenders
                    )
                    try splat.readPLY(from: url)
                    continuation.resume(returning: splat)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requestDraw() {
        metalKitView.draw()
    }

    private var viewportCamera: ModelRenderer.CameraMatrices {
        let aspect = max(drawableSize.width / max(drawableSize.height, 1), 0.1)
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(Constants.fovy.radians),
                                                             aspectRatio: Float(aspect),
                                                             nearZ: 0.1,
                                                             farZ: 100.0)

        let yawMatrix = matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
        let pitchMatrix = matrix4x4_rotation(radians: pitch, axis: SIMD3<Float>(1, 0, 0))
        let translationMatrix = matrix4x4_translation(pan.x, pan.y, -distance)
        let centerTranslation = matrix4x4_translation(-center.x, -center.y, -center.z)
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        return (projection: projectionMatrix,
                view: translationMatrix * pitchMatrix * yawMatrix * commonUpCalibration * centerTranslation,
                screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
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
        requestDraw()
    }

    func orbit(deltaX: Float, deltaY: Float) {
        yaw += deltaX * Constants.orbitSpeed
        pitch = max(min(pitch + deltaY * Constants.orbitSpeed, .pi / 2 - 0.01), -.pi / 2 + 0.01)
        requestDraw()
    }

    func zoom(delta: Float) {
        distance = max(Constants.minDistance, min(Constants.maxDistance, distance + delta * Constants.zoomSpeed))
        requestDraw()
    }

    func pan(deltaX: Float, deltaY: Float) {
        pan += SIMD2<Float>(deltaX * Constants.panSpeed, -deltaY * Constants.panSpeed)
        requestDraw()
    }

    func resetCamera() {
        yaw = defaultYaw
        pitch = defaultPitch
        distance = defaultDistance
        pan = defaultPan
        requestDraw()
    }

    func fitToView() {
        distance = defaultDistance
        yaw = 0
        pitch = 0
        pan = .zero
        requestDraw()
    }

    func applyBounds(center: SIMD3<Float>, radius: Float) {
        self.center = center
        let fov = Float(Constants.fovy.radians)
        let paddedRadius = max(radius, 0.01) * 1.2
        let targetDistance = paddedRadius / tanf(fov * 0.5)
        distance = max(Constants.minDistance, min(Constants.maxDistance, targetDistance))
        requestDraw()
    }
}

#endif // os(iOS) || os(macOS)
