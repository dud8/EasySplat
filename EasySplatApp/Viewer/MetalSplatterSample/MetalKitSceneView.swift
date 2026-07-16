import SwiftUI
import MetalKit
import AppKit
import SplatIO

struct PreviewLoadRequest: Hashable {
    let url: URL?
    let reloadToken: Int
}

struct SplatViewerSceneConfiguration: Equatable {
    var bounds: ViewerSceneBounds?
    var openingDirection: SIMD3<Float>?
    var isViewOnlyFlipActive: Bool

    init(
        bounds: ViewerSceneBounds? = nil,
        openingDirection: SIMD3<Float>? = nil,
        isViewOnlyFlipActive: Bool = false
    ) {
        self.bounds = bounds
        self.openingDirection = openingDirection
        self.isViewOnlyFlipActive = isViewOnlyFlipActive
    }
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
    typealias Bounds = ViewerSceneBounds
    typealias BoundsLoader = @Sendable (URL) async throws -> Bounds?

    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var isUpdating: Bool = false
    @Published var hasRenderedPreview: Bool = false
    private(set) var currentBounds: Bounds?
    var renderer: MetalKitSceneRenderer?
    private let boundsLoader: BoundsLoader
    private var boundsTask: Task<Void, Never>?
    private var boundsRequest: PreviewLoadRequest?
    private var boundsGeneration: UInt64 = 0
    private var boundsInteractionRevision: UInt64 = 0
    private var sceneConfiguration = SplatViewerSceneConfiguration()
    private var isSceneConfigurationActive = false

    init(boundsLoader: @escaping BoundsLoader = { url in
        let worker = Task.detached {
            try BoundsCalculator.computeBounds(
                for: url,
                shouldCancel: { Task.isCancelled }
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }) {
        self.boundsLoader = boundsLoader
    }

    deinit {
        boundsTask?.cancel()
    }

    func resetCamera() {
        renderer?.resetCamera()
    }

    func fitToView() {
        renderer?.fitToView()
    }

    func prepareBounds(
        for request: PreviewLoadRequest,
        configuration: SplatViewerSceneConfiguration,
        activate: Bool = true
    ) {
        boundsTask?.cancel()
        boundsTask = nil
        boundsGeneration &+= 1
        boundsRequest = request
        sceneConfiguration = configuration
        currentBounds = configuration.bounds
        boundsInteractionRevision = renderer?.interactionRevision ?? 0
        isSceneConfigurationActive = false
        if activate {
            activatePreparedSceneConfiguration()
        }
    }

    func prepareBounds(for request: PreviewLoadRequest) {
        prepareBounds(for: request, configuration: sceneConfiguration)
    }

    func updateSceneConfiguration(_ configuration: SplatViewerSceneConfiguration) {
        let previous = sceneConfiguration
        guard previous != configuration else { return }
        sceneConfiguration = configuration
        if let bounds = configuration.bounds {
            currentBounds = bounds
        } else if previous.bounds != nil {
            currentBounds = nil
        }
        guard isSceneConfigurationActive else { return }
        if previous.isViewOnlyFlipActive != configuration.isViewOnlyFlipActive {
            renderer?.setViewOnlyFlipActive(configuration.isViewOnlyFlipActive)
            boundsInteractionRevision = renderer?.interactionRevision ?? boundsInteractionRevision
        }
        if currentBounds != nil,
           previous.bounds != configuration.bounds
            || previous.openingDirection != configuration.openingDirection {
            applyCurrentBoundsIfPossible()
        }
    }

    func activatePreparedSceneConfiguration() {
        guard !isSceneConfigurationActive else { return }
        isSceneConfigurationActive = true
        _ = renderer?.activateSceneConfiguration(
            bounds: currentBounds,
            openingDirection: sceneConfiguration.openingDirection,
            isViewOnlyFlipActive: sceneConfiguration.isViewOnlyFlipActive,
            ifInteractionRevisionMatches: boundsInteractionRevision
        )
    }

    func startBoundsLoad(for request: PreviewLoadRequest) {
        boundsTask = Task { [weak self] in
            await self?.loadBoundsAndApply(for: request)
        }
    }

    func loadBoundsAndApply(for request: PreviewLoadRequest) async {
        guard currentBounds == nil,
              let url = request.url,
              boundsRequest == request else { return }
        let generation = boundsGeneration
        let loader = boundsLoader
        do {
            let bounds = try await loader(url)
            guard !Task.isCancelled,
                  boundsGeneration == generation,
                  boundsRequest == request,
                  sceneConfiguration.bounds == nil else {
                return
            }
            currentBounds = bounds
            applyCurrentBoundsIfPossible()
        } catch {
            // Development PLY bounds are optional; keep the preview interactive.
        }
    }

    func cancelBoundsLoad() {
        boundsTask?.cancel()
        boundsTask = nil
        boundsGeneration &+= 1
        boundsRequest = nil
        currentBounds = nil
        isSceneConfigurationActive = false
    }

    private func applyCurrentBoundsIfPossible() {
        guard isSceneConfigurationActive, let bounds = currentBounds else { return }
        _ = renderer?.applyBounds(
            center: bounds.center,
            radius: bounds.radius,
            openingDirection: sceneConfiguration.openingDirection,
            ifInteractionRevisionMatches: boundsInteractionRevision
        )
    }
}

@MainActor
struct MetalKitSceneView: NSViewRepresentable {
    var splatURL: URL?
    var reloadToken: Int = 0
    var controller: SplatViewerController
    var sceneConfiguration = SplatViewerSceneConfiguration()
    var onLoadStateChanged: ((SplatViewerLoadState) -> Void)?

    @MainActor
    final class Coordinator {
        var renderer: MetalKitSceneRenderer?
        weak var controller: SplatViewerController?
        var onLoadStateChanged: ((SplatViewerLoadState) -> Void)?
        var loadTask: Task<Void, Never>?
        var deferredLoadTask: Task<Void, Never>?
        var planner = PreviewReloadPlanner()
        private var sceneConfigurations: [PreviewLoadRequest: SplatViewerSceneConfiguration] = [:]
        private(set) var displayedRequest: PreviewLoadRequest?

        deinit {
            loadTask?.cancel()
            deferredLoadTask?.cancel()
        }

        func requestLoad(
            url: URL?,
            reloadToken: Int,
            configuration: SplatViewerSceneConfiguration
        ) {
            let request = PreviewLoadRequest(url: url, reloadToken: reloadToken)
            sceneConfigurations[request] = configuration
            if displayedRequest == request, planner.inFlightRequest == nil {
                controller?.updateSceneConfiguration(configuration)
            }
            planner.request(request)
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
            let configuration = sceneConfigurations[request] ?? SplatViewerSceneConfiguration()
            controller.prepareBounds(
                for: request,
                configuration: configuration,
                activate: false
            )
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
                    let retainedRequests = Set([
                        self.displayedRequest,
                        self.planner.latestRequested,
                        self.planner.pendingRequest,
                        self.planner.inFlightRequest,
                    ].compactMap { $0 })
                    self.sceneConfigurations = self.sceneConfigurations.filter {
                        retainedRequests.contains($0.key)
                    }
                    self.evaluateAndStartLoad()
                }
                do {
                    async let boundsPreparation: Void = controller.loadBoundsAndApply(
                        for: request
                    )
                    try await renderer.load(
                        request.url.map { ModelIdentifier.gaussianSplat($0) },
                        forceReload: forceReload
                    )
                    await boundsPreparation
                    guard !Task.isCancelled else { return }
                    if let latestConfiguration = self.sceneConfigurations[request] {
                        controller.updateSceneConfiguration(latestConfiguration)
                    }
                    controller.activatePreparedSceneConfiguration()
                    self.displayedRequest = request
                    controller.errorMessage = nil
                    controller.isLoading = false
                    controller.isUpdating = false
                    controller.hasRenderedPreview = request.url != nil
                    self.onLoadStateChanged?(.ready)
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

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.controller?.cancelBoundsLoad()
        coordinator.loadTask?.cancel()
        coordinator.deferredLoadTask?.cancel()
        if let interactiveView = nsView as? InteractiveMTKView {
            interactiveView.onOrbit = nil
            interactiveView.onScrollZoom = nil
            interactiveView.onMagnify = nil
            interactiveView.onPan = nil
            interactiveView.onKeyboardCommand = nil
            interactiveView.onInteractionActivity = nil
        }
        if coordinator.controller?.renderer === coordinator.renderer {
            coordinator.controller?.renderer = nil
        }
        nsView.delegate = nil
        coordinator.renderer = nil
        coordinator.controller = nil
    }

    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        let metalKitView = InteractiveMTKView(frame: .zero, device: nil)
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

        metalKitView.onOrbit = { [weak renderer] deltaX, deltaY in
            renderer?.orbit(deltaX: Float(deltaX), deltaY: Float(deltaY))
        }
        metalKitView.onScrollZoom = { [weak renderer] delta, point in
            renderer?.zoomByScroll(delta: Float(delta), anchoredAt: point)
        }
        metalKitView.onMagnify = { [weak renderer] magnification, point in
            renderer?.zoomByPinch(magnification: Float(magnification), anchoredAt: point)
        }
        metalKitView.onPan = { [weak renderer] deltaX, deltaY in
            renderer?.pan(deltaX: Float(deltaX), deltaY: Float(deltaY))
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
                renderer?.keyboardZoomIn()
            case .zoomOut:
                renderer?.keyboardZoomOut()
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
        context.coordinator.requestLoad(
            url: splatURL,
            reloadToken: reloadToken,
            configuration: sceneConfiguration
        )
    }
}

enum BoundsCalculator {
    static func computeBounds(
        for url: URL,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ViewerSceneBounds? {
        let collector = BoundsCollector()
        let reader = SplatPLYSceneReader(url)
        reader.read(to: collector, shouldCancel: shouldCancel)

        if let error = collector.error {
            throw error
        }
        return RobustSplatBounds.compute(samples: collector.samples)
    }

    private final class BoundsCollector: NSObject, SplatSceneReaderDelegate {
        fileprivate var samples: [SplatBoundsSample] = []
        fileprivate var error: Error?
        private var pointCount = 0
        private var pointIndex = 0
        private var sampleSlot = 0
        private var nextSampleIndex: Int?

        func didStartReading(withPointCount pointCount: UInt32) {
            self.pointCount = Int(pointCount)
            let capacity = min(self.pointCount, RobustSplatBounds.maximumFallbackSampleCount)
            samples.reserveCapacity(capacity)
            nextSampleIndex = RobustSplatBounds.sampleIndex(
                slot: sampleSlot,
                pointCount: self.pointCount
            )
        }

        func didRead(points: [SplatScenePoint]) {
            for point in points {
                if let scheduledIndex = nextSampleIndex, pointIndex == scheduledIndex {
                    samples.append(
                        SplatBoundsSample(
                            position: point.position,
                            logScale: point.scale,
                            opacityLogit: point.opacity
                        )
                    )
                    sampleSlot += 1
                    nextSampleIndex = RobustSplatBounds.sampleIndex(
                        slot: sampleSlot,
                        pointCount: pointCount
                    )
                }
                pointIndex += 1
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
    var onScrollZoom: ((CGFloat, CGPoint) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onKeyboardCommand: ((ViewerKeyboardCommand) -> Void)?
    var onInteractionActivity: (() -> Void)?

    private var lastLocation: NSPoint?
    private var isPanning = false

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        configureInteractionSurface()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureInteractionSurface()
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 2, dy: 2)
    }

    override func drawFocusRingMask() {
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: focusRingMaskBounds,
            xRadius: Theme.Radius.standard - 2,
            yRadius: Theme.Radius.standard - 2
        ).fill()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            noteFocusRingMaskChanged()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            noteFocusRingMaskChanged()
        }
        return resigned
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
        onScrollZoom?(event.scrollingDeltaY, viewerPoint(for: event))
    }

    override func magnify(with event: NSEvent) {
        onInteractionActivity?()
        onMagnify?(event.magnification, viewerPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        onInteractionActivity?()
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let nonTraversalModifiers = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 48, nonTraversalModifiers.isEmpty {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(nil)
            } else {
                window?.selectNextKeyView(nil)
            }
            return
        }

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

    private func viewerPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func configureInteractionSurface() {
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("result.viewer")
        setAccessibilityLabel("Interactive 3D splat viewer")
        setAccessibilityHelp(
            "Drag to orbit. Option-drag pans. Scroll or pinch zooms. Press F to fit or R to reset."
        )
        setAccessibilityChildren([])
    }
}
