import SwiftUI
import MetalKit
import AppKit
import SplatIO

final class SplatViewerController: ObservableObject {
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    private(set) var currentBounds: (center: SIMD3<Float>, radius: Float)?
    fileprivate var renderer: MetalKitSceneRenderer?

    func resetCamera() {
        renderer?.resetCamera()
    }

    func fitToView() {
        if let bounds = currentBounds {
            renderer?.applyBounds(center: bounds.center, radius: bounds.radius)
        } else {
            renderer?.fitToView()
        }
    }

    func computeBounds(for url: URL) async throws {
        var buffer = SplatMemoryBuffer()
        let reader = AutodetectSceneReader(url)
        try await buffer.read(from: reader)
        guard !buffer.points.isEmpty else {
            currentBounds = nil
            return
        }
        var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in buffer.points {
            let pos = SIMD3<Float>(point.position.x, point.position.y, point.position.z)
            minPoint = simd.min(minPoint, pos)
            maxPoint = simd.max(maxPoint, pos)
        }
        let center = (minPoint + maxPoint) * 0.5
        let radius = simd_length(maxPoint - minPoint) * 0.5
        if radius.isFinite {
            currentBounds = (center: center, radius: radius)
        } else {
            currentBounds = nil
        }
    }
}

struct MetalKitSceneView: NSViewRepresentable {
    var splatURL: URL?
    var controller: SplatViewerController

    class Coordinator {
        var renderer: MetalKitSceneRenderer?
        var currentURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        let metalKitView = InteractiveMTKView()
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            metalKitView.device = metalDevice
        }

        guard let renderer = MetalKitSceneRenderer(metalKitView) else {
            return metalKitView
        }
        context.coordinator.renderer = renderer
        controller.renderer = renderer
        metalKitView.delegate = renderer

        metalKitView.onOrbit = { deltaX, deltaY in
            renderer.orbit(deltaX: Float(deltaX), deltaY: Float(deltaY))
        }
        metalKitView.onZoom = { delta in
            renderer.zoom(delta: Float(delta))
        }
        metalKitView.onPan = { deltaX, deltaY in
            renderer.pan(deltaX: Float(deltaX), deltaY: Float(deltaY))
        }

        loadIfNeeded(context: context)
        return metalKitView
    }

    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        loadIfNeeded(context: context)
    }

    private func loadIfNeeded(context: NSViewRepresentableContext<MetalKitSceneView>) {
        guard let renderer = context.coordinator.renderer else { return }
        guard context.coordinator.currentURL != splatURL else { return }
        context.coordinator.currentURL = splatURL
        Task {
            do {
                controller.isLoading = true
                try await renderer.load(splatURL.map { ModelIdentifier.gaussianSplat($0) })
                if let url = splatURL {
                    try await controller.computeBounds(for: url)
                }
                controller.errorMessage = nil
                controller.isLoading = false
            } catch {
                controller.isLoading = false
                controller.errorMessage = error.localizedDescription
                print("Error loading model: \(error.localizedDescription)")
            }
        }
    }
}

final class InteractiveMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?

    private var lastLocation: NSPoint?
    private var isPanning = false

    override func mouseDown(with event: NSEvent) {
        lastLocation = event.locationInWindow
        isPanning = event.modifierFlags.contains(.option)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastLocation else { return }
        let current = event.locationInWindow
        let deltaX = current.x - last.x
        let deltaY = current.y - last.y
        lastLocation = current

        if isPanning {
            onPan?(deltaX, deltaY)
        } else {
            onOrbit?(deltaX, deltaY)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(event.deltaY)
    }
}
