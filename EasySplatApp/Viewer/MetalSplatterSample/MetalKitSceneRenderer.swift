#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import simd
import SwiftUI

@MainActor
class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?
    @MainActor private(set) var lastLoadError: String? = nil

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

    init?(_ metalKitView: MTKView) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        lastLoadError = nil
        do {
            switch model {
            case .gaussianSplat(let url):
                let splat = try SplatRenderer(device: device,
                                              colorFormat: metalKitView.colorPixelFormat,
                                              depthFormat: metalKitView.depthStencilPixelFormat,
                                              sampleCount: metalKitView.sampleCount,
                                              maxViewCount: 1,
                                              maxSimultaneousRenders: Constants.maxSimultaneousRenders)
                try await splat.read(from: url)
                modelRenderer = splat
            case .none:
                break
            }
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    private var viewport: ModelRendererViewportDescriptor {
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

        let viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: translationMatrix * pitchMatrix * yawMatrix * commonUpCalibration * centerTranslation,
                                               screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }

    func draw(in view: MTKView) {
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        let didRender: Bool
        do {
            didRender = try modelRenderer.render(viewports: [viewport],
                                                 colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                                 colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                                 depthTexture: view.depthStencilTexture,
                                                 rasterizationRateMap: nil,
                                                 renderTargetArrayLength: 0,
                                                 to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
            didRender = false
        }

        // Only present if rendering occurred; otherwise drop the frame
        if didRender {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func orbit(deltaX: Float, deltaY: Float) {
        yaw += deltaX * Constants.orbitSpeed
        pitch = max(min(pitch + deltaY * Constants.orbitSpeed, .pi / 2 - 0.01), -.pi / 2 + 0.01)
    }

    func zoom(delta: Float) {
        distance = max(Constants.minDistance, min(Constants.maxDistance, distance + delta * Constants.zoomSpeed))
    }

    func pan(deltaX: Float, deltaY: Float) {
        pan += SIMD2<Float>(deltaX * Constants.panSpeed, -deltaY * Constants.panSpeed)
    }

    func resetCamera() {
        yaw = defaultYaw
        pitch = defaultPitch
        distance = defaultDistance
        pan = defaultPan
    }

    func fitToView() {
        distance = defaultDistance
        yaw = 0
        pitch = 0
        pan = .zero
    }

    func applyBounds(center: SIMD3<Float>, radius: Float) {
        self.center = center
        let fov = Float(Constants.fovy.radians)
        let paddedRadius = max(radius, 0.01) * 1.2
        let targetDistance = paddedRadius / tanf(fov * 0.5)
        distance = max(Constants.minDistance, min(Constants.maxDistance, targetDistance))
    }
}

#endif // os(iOS) || os(macOS)
