import SwiftUI
import MetalKit
import AppKit
import SplatIO

@MainActor
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
        let bounds = try await Task.detached {
            try BoundsCalculator.computeBounds(for: url)
        }.value
        currentBounds = bounds
    }
}

@MainActor
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
                try renderer.load(splatURL.map { ModelIdentifier.gaussianSplat($0) })
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

private enum BoundsCalculator {
    static func computeBounds(for url: URL) throws -> (center: SIMD3<Float>, radius: Float)? {
        let collector = BoundsCollector()
        let reader = SplatPLYSceneReader(url)
        reader.read(to: collector)

        if let error = collector.error {
            throw error
        }
        guard collector.hasPoints else { return nil }
        let minPoint = collector.minPoint
        let maxPoint = collector.maxPoint
        let center = (minPoint + maxPoint) * 0.5
        let radius = simd_length(maxPoint - minPoint) * 0.5
        return radius.isFinite ? (center: center, radius: radius) : nil
    }

    private final class BoundsCollector: NSObject, SplatSceneReaderDelegate {
        fileprivate var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        fileprivate var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        fileprivate var hasPoints = false
        fileprivate var error: Error?

        func didStartReading(withPointCount pointCount: UInt32) {}

        func didRead(points: [SplatScenePoint]) {
            for point in points {
                let pos = point.position
                minPoint = simd.min(minPoint, pos)
                maxPoint = simd.max(maxPoint, pos)
            }
            if !points.isEmpty {
                hasPoints = true
            }
        }

        func didFinishReading() {}

        func didFailReading(withError error: Error?) {
            self.error = error
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
