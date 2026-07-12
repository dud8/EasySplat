import SwiftUI
import MetalKit
import AppKit
import SplatIO

struct PreviewLoadRequest: Equatable {
    let url: URL?
    let reloadToken: Int
}

enum PreviewLoadDecision: Equatable {
    case none
    case deferLoad(TimeInterval)
    case start(request: PreviewLoadRequest, forceReload: Bool)
}

struct PreviewReloadPlanner {
    static let interactionIdleDelay: TimeInterval = 1.2

    private(set) var latestRequested: PreviewLoadRequest?
    private(set) var pendingRequest: PreviewLoadRequest?
    private(set) var inFlightRequest: PreviewLoadRequest?
    private(set) var lastHandledRequest: PreviewLoadRequest?
    private(set) var lastInteractionAt: Date?

    mutating func request(_ request: PreviewLoadRequest) {
        latestRequested = request
        if inFlightRequest != nil {
            pendingRequest = request
            return
        }
        pendingRequest = request
    }

    mutating func recordInteraction(now: Date) {
        lastInteractionAt = now
    }

    mutating func nextDecision(now: Date, idleDelay: TimeInterval = interactionIdleDelay) -> PreviewLoadDecision {
        guard inFlightRequest == nil else {
            return .none
        }

        guard let target = pendingRequest ?? latestRequested else {
            return .none
        }

        if lastHandledRequest == target {
            pendingRequest = nil
            return .none
        }

        if let lastInteractionAt {
            let elapsed = now.timeIntervalSince(lastInteractionAt)
            if elapsed < idleDelay {
                return .deferLoad(max(0, idleDelay - elapsed))
            }
        }

        inFlightRequest = target
        pendingRequest = nil
        let forceReload = lastHandledRequest?.url == target.url
        return .start(request: target, forceReload: forceReload)
    }

    mutating func completeInFlight() {
        guard let inFlightRequest else { return }
        lastHandledRequest = inFlightRequest
        self.inFlightRequest = nil

        if let latestRequested, latestRequested != inFlightRequest {
            pendingRequest = latestRequested
        } else if pendingRequest == inFlightRequest {
            pendingRequest = nil
        }
    }
}

@MainActor
final class SplatViewerController: ObservableObject {
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var isUpdating: Bool = false
    @Published var hasRenderedPreview: Bool = false
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
    var reloadToken: Int = 0
    var controller: SplatViewerController
    var onLoadStateChanged: ((SplatViewerLoadState) -> Void)?

    @MainActor
    final class Coordinator {
        var renderer: MetalKitSceneRenderer?
        weak var controller: SplatViewerController?
        var onLoadStateChanged: ((SplatViewerLoadState) -> Void)?
        var loadTask: Task<Void, Never>?
        var deferredLoadTask: Task<Void, Never>?
        var planner = PreviewReloadPlanner()

        deinit {
            loadTask?.cancel()
            deferredLoadTask?.cancel()
        }

        func requestLoad(url: URL?, reloadToken: Int) {
            planner.request(PreviewLoadRequest(url: url, reloadToken: reloadToken))
            evaluateAndStartLoad()
        }

        func recordInteraction() {
            planner.recordInteraction(now: Date())
            evaluateAndStartLoad()
        }

        private func evaluateAndStartLoad() {
            guard let renderer, let controller else { return }
            switch planner.nextDecision(now: Date()) {
            case .none:
                return
            case .deferLoad(let delay):
                scheduleDeferredLoad(after: delay)
            case .start(let request, let forceReload):
                deferredLoadTask?.cancel()
                deferredLoadTask = nil
                startLoad(
                    request: request,
                    forceReload: forceReload,
                    renderer: renderer,
                    controller: controller
                )
            }
        }

        private func scheduleDeferredLoad(after delay: TimeInterval) {
            deferredLoadTask?.cancel()
            deferredLoadTask = Task { [weak self] in
                guard let self else { return }
                let nanos = UInt64(max(0, delay) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                self.deferredLoadTask = nil
                self.evaluateAndStartLoad()
            }
        }

        private func startLoad(
            request: PreviewLoadRequest,
            forceReload: Bool,
            renderer: MetalKitSceneRenderer,
            controller: SplatViewerController
        ) {
            if controller.hasRenderedPreview {
                controller.isLoading = false
                controller.isUpdating = true
            } else {
                controller.isLoading = true
                controller.isUpdating = false
            }
            onLoadStateChanged?(.loading)

            loadTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.loadTask = nil
                    self.planner.completeInFlight()
                    self.evaluateAndStartLoad()
                }
                do {
                    try await renderer.load(
                        request.url.map { ModelIdentifier.gaussianSplat($0) },
                        forceReload: forceReload
                    )
                guard !Task.isCancelled else { return }
                    controller.errorMessage = nil
                    controller.isLoading = false
                    controller.isUpdating = false
                    controller.hasRenderedPreview = request.url != nil
                self.onLoadStateChanged?(.ready)
                    if let url = request.url {
                        Task {
                            do {
                                try await controller.computeBounds(for: url)
                            } catch {
                                // Bounds are optional for rendering; keep the preview interactive.
                            }
                        }
                    }
            } catch {
                guard !Task.isCancelled else { return }
                controller.isLoading = false
                controller.isUpdating = false
                controller.errorMessage = error.localizedDescription
                    self.onLoadStateChanged?(.failed(error.localizedDescription))
                    print("Error loading model: \(error.localizedDescription)")
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        let metalKitView = InteractiveMTKView()
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            controller.errorMessage = "Metal is not available on this Mac."
            controller.isLoading = false
            controller.isUpdating = false
            return metalKitView
        }
        metalKitView.device = metalDevice

        guard let renderer = MetalKitSceneRenderer(metalKitView) else {
            controller.errorMessage = "Failed to initialize Metal renderer."
            controller.isLoading = false
            controller.isUpdating = false
            return metalKitView
        }
        context.coordinator.renderer = renderer
        context.coordinator.controller = controller
        context.coordinator.onLoadStateChanged = onLoadStateChanged
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
        metalKitView.onKeyboardCommand = { [weak renderer, weak controller] command in
            let orbitStep: Float = 16
            let panStep: Float = 12
            switch command {
            case .orbit(let horizontal, let vertical):
                renderer?.orbit(
                    deltaX: Float(horizontal) * orbitStep,
                    deltaY: Float(vertical) * orbitStep
                )
            case .pan(let horizontal, let vertical):
                renderer?.pan(
                    deltaX: Float(horizontal) * panStep,
                    deltaY: Float(vertical) * panStep
                )
            case .zoomIn:
                renderer?.zoom(delta: -12)
            case .zoomOut:
                renderer?.zoom(delta: 12)
            case .fit:
                controller?.fitToView()
            case .reset:
                controller?.resetCamera()
            }
        }
        metalKitView.onInteractionActivity = { [weak coordinator = context.coordinator] in
            coordinator?.recordInteraction()
        }

        loadIfNeeded(context: context)
        return metalKitView
    }

    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        context.coordinator.controller = controller
        context.coordinator.onLoadStateChanged = onLoadStateChanged
        loadIfNeeded(context: context)
    }

    private func loadIfNeeded(context: NSViewRepresentableContext<MetalKitSceneView>) {
        context.coordinator.requestLoad(url: splatURL, reloadToken: reloadToken)
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
    var onKeyboardCommand: ((ViewerKeyboardCommand) -> Void)?
    var onInteractionActivity: (() -> Void)?

    private var lastLocation: NSPoint?
    private var isPanning = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focusRingType = .exterior
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onInteractionActivity?()
        lastLocation = event.locationInWindow
        isPanning = event.modifierFlags.contains(.option)
    }

    override func mouseDragged(with event: NSEvent) {
        onInteractionActivity?()
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
        onInteractionActivity?()
        onZoom?(event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        onInteractionActivity?()
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let command = ViewerKeyboardCommand.resolve(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifiers: ViewerKeyboardModifiers(event.modifierFlags)
        ) else {
            super.keyDown(with: event)
            return
        }
        onInteractionActivity?()
        onKeyboardCommand?(command)
    }
}
