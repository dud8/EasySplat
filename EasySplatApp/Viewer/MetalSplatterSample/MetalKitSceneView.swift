import SwiftUI
import MetalKit
import AppKit
import MetalSplatter

struct PreviewLoadRequest: Hashable {
    let url: URL?
    let reloadToken: Int
    let loadAttemptRevision: Int

    init(url: URL?, reloadToken: Int, loadAttemptRevision: Int = 0) {
        self.url = url
        self.reloadToken = reloadToken
        self.loadAttemptRevision = loadAttemptRevision
    }
}

enum SplatViewerConfigurationError: Error, Equatable, LocalizedError {
    case missingAuthenticatedSceneBounds
    case sceneBoundsOutsideSupportedRange

    var errorDescription: String? {
        switch self {
        case .missingAuthenticatedSceneBounds:
            "This splat is missing authenticated scene bounds."
        case .sceneBoundsOutsideSupportedRange:
            "This splat’s scene bounds are outside the viewer’s supported range."
        }
    }
}

struct SplatViewerSceneConfiguration: Equatable {
    let bounds: ViewerSceneBounds?
    let openingDirection: SIMD3<Float>?
    let isViewOnlyFlipActive: Bool
    let validationError: SplatViewerConfigurationError?

    init(
        bounds: ViewerSceneBounds? = nil,
        openingDirection: SIMD3<Float>? = nil,
        isViewOnlyFlipActive: Bool = false
    ) {
        let boundsError = bounds.flatMap { bounds in
            ViewerCameraState.canRepresentSceneBounds(
                center: bounds.center,
                radius: bounds.radius
            ) ? nil : SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange
        }
        self.validationError = boundsError
        self.bounds = self.validationError == nil ? bounds : nil
        self.openingDirection = openingDirection
        self.isViewOnlyFlipActive = isViewOnlyFlipActive
    }

    func validate() throws {
        if let validationError {
            throw validationError
        }
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
    private(set) var isContinuouslyInteracting = false

    /// Held-key flight produces no per-event timestamps, so it declares itself
    /// explicitly; deactivation counts as one interaction so loads still wait
    /// out the idle delay afterwards.
    mutating func setContinuousInteraction(_ active: Bool, now: Date) {
        guard active != isContinuouslyInteracting else { return }
        isContinuouslyInteracting = active
        if !active {
            lastInteractionAt = now
        }
    }

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

        if isContinuouslyInteracting {
            return .deferLoad(idleDelay)
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
    @Published private(set) var loadAttemptRevision = 0
    @Published private(set) var sortFailureMessage: String?
    @Published private(set) var isLoadFailureRetryable = false
    private(set) var currentBounds: ViewerSceneBounds?
    var renderer: MetalKitSceneRenderer?
    private var boundsInteractionRevision: UInt64 = 0
    private var sceneConfiguration = SplatViewerSceneConfiguration()
    private var isSceneConfigurationActive = false

    func resetCamera() {
        renderer?.resetCamera()
    }

    func fitToView() {
        renderer?.fitToView()
    }

    var canRetryLoad: Bool {
        errorMessage != nil && isLoadFailureRetryable && !isLoading && !isUpdating
    }

    var loadErrorTitle: String {
        hasRenderedPreview ? "Couldn’t update splat" : "Couldn’t load splat"
    }

    func beginLoadAttempt() {
        recordLoadSuccess()
        if hasRenderedPreview {
            isLoading = false
            isUpdating = true
        } else {
            isLoading = true
            isUpdating = false
        }
    }

    func recordLoadFailure(_ message: String, retryable: Bool = true) {
        errorMessage = message
        isLoadFailureRetryable = retryable
    }

    func recordLoadSuccess() {
        errorMessage = nil
        isLoadFailureRetryable = false
    }

    @discardableResult
    func retryFailedLoad() -> Bool {
        guard canRetryLoad else { return false }
        errorMessage = nil
        loadAttemptRevision &+= 1
        return true
    }

    func recordSortFailure(_ message: String) {
        sortFailureMessage = message
    }

    func recordSortSuccess() {
        sortFailureMessage = nil
    }

    func retrySortOrdering() {
        renderer?.retrySortOrdering()
    }

    func prepareSceneConfiguration(
        _ configuration: SplatViewerSceneConfiguration,
        activate: Bool = true
    ) {
        sceneConfiguration = configuration
        currentBounds = configuration.bounds
        boundsInteractionRevision = renderer?.interactionRevision ?? 0
        isSceneConfigurationActive = false
        if activate {
            _ = activatePreparedSceneConfiguration()
        }
    }

    func updateSceneConfiguration(_ configuration: SplatViewerSceneConfiguration) {
        let previous = sceneConfiguration
        guard previous != configuration else { return }
        if let validationError = configuration.validationError {
            sceneConfiguration = configuration
            currentBounds = nil
            recordLoadFailure(validationError.localizedDescription, retryable: false)
            return
        }
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

    func validatePreparedSceneConfiguration(for request: PreviewLoadRequest) throws {
        try sceneConfiguration.validate()
        if request.url != nil, currentBounds == nil {
            throw SplatViewerConfigurationError.missingAuthenticatedSceneBounds
        }
    }

    @discardableResult
    func activatePreparedSceneConfiguration(requestDraw: Bool = true) -> Bool {
        guard !isSceneConfigurationActive else { return true }
        do {
            try sceneConfiguration.validate()
        } catch {
            recordLoadFailure(error.localizedDescription, retryable: false)
            return false
        }
        guard let renderer else {
            isSceneConfigurationActive = true
            return true
        }
        let accepted = renderer.activateSceneConfiguration(
            bounds: currentBounds,
            openingDirection: sceneConfiguration.openingDirection,
            isViewOnlyFlipActive: sceneConfiguration.isViewOnlyFlipActive,
            ifInteractionRevisionMatches: boundsInteractionRevision,
            requestDraw: requestDraw
        )
        guard accepted else {
            let error = SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange
            recordLoadFailure(error.localizedDescription, retryable: false)
            return false
        }
        isSceneConfigurationActive = true
        return true
    }

    func resetSceneConfiguration() {
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
    var loadAttemptRevision: Int = 0
    var controller: SplatViewerController
    var sceneConfiguration = SplatViewerSceneConfiguration()
    var onLoadStateChanged: ((SplatViewerLoadState) -> Void)?

    @MainActor
    final class Coordinator {
        var renderer: MetalKitSceneRenderer?
        weak var controller: SplatViewerController?
        weak var interactiveView: InteractiveMTKView?
        var onLoadStateChanged: ((SplatViewerLoadState) -> Void)?
        var loadTask: Task<Void, Never>?
        var deferredLoadTask: Task<Void, Never>?
        var scheduledEvaluationTask: Task<Void, Never>?
        var initializationFailureTask: Task<Void, Never>?
        private var initializationFailureMessage: String?
        private var initializationFailurePublicationControllerID: ObjectIdentifier?
        var modelLoadPreparer: (@MainActor (
            MetalKitSceneRenderer,
            ModelIdentifier?,
            Bool
        ) async throws -> PreparedViewerModelLoad)?
        var planner = PreviewReloadPlanner()
        private var sceneConfigurations: [PreviewLoadRequest: SplatViewerSceneConfiguration] = [:]
        private(set) var displayedRequest: PreviewLoadRequest?

        deinit {
            loadTask?.cancel()
            deferredLoadTask?.cancel()
            scheduledEvaluationTask?.cancel()
            initializationFailureTask?.cancel()
        }

        func requestLoad(
            url: URL?,
            reloadToken: Int,
            loadAttemptRevision: Int = 0,
            configuration: SplatViewerSceneConfiguration
        ) {
            if let initializationFailureMessage {
                interactiveView?.setViewerLoadState(.failed)
                scheduleInitializationFailurePublication(initializationFailureMessage)
                return
            }
            let request = PreviewLoadRequest(
                url: url,
                reloadToken: reloadToken,
                loadAttemptRevision: loadAttemptRevision
            )
            sceneConfigurations[request] = configuration
            if displayedRequest != request,
               planner.lastHandledRequest != request,
               planner.inFlightRequest != request {
                interactiveView?.setViewerLoadState(
                    controller?.hasRenderedPreview == true ? .ready : .loading
                )
            }
            if displayedRequest == request, planner.inFlightRequest == nil {
                controller?.updateSceneConfiguration(configuration)
            }
            planner.request(request)
            scheduleLoadEvaluation()
        }

        func recordInteraction() {
            planner.recordInteraction(now: Date())
            scheduleLoadEvaluation()
        }

        func setContinuousInteraction(_ active: Bool) {
            let wasActive = planner.isContinuouslyInteracting
            planner.setContinuousInteraction(active, now: Date())
            if wasActive, !active {
                scheduleLoadEvaluation()
            }
        }

        func scheduleInitializationFailure(_ message: String) {
            if initializationFailureMessage != message {
                initializationFailurePublicationControllerID = nil
                initializationFailureTask?.cancel()
                initializationFailureTask = nil
            }
            initializationFailureMessage = message
            interactiveView?.setViewerLoadState(.failed)
            scheduleInitializationFailurePublication(message)
        }

        private func scheduleInitializationFailurePublication(_ message: String) {
            guard initializationFailureTask == nil, let controller else { return }
            let controllerID = ObjectIdentifier(controller)
            if initializationFailurePublicationControllerID == controllerID,
               controller.errorMessage == message {
                return
            }
            initializationFailureTask = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                self.initializationFailureTask = nil
                guard !Task.isCancelled,
                      self.initializationFailureMessage == message,
                      let controller = self.controller else {
                    return
                }
                let controllerID = ObjectIdentifier(controller)
                if self.initializationFailurePublicationControllerID == controllerID,
                   controller.errorMessage == message {
                    return
                }
                controller.recordLoadFailure(message, retryable: false)
                controller.isLoading = false
                controller.isUpdating = false
                self.initializationFailurePublicationControllerID = controllerID
                self.onLoadStateChanged?(.failed(message))
            }
        }

        private func scheduleLoadEvaluation() {
            guard scheduledEvaluationTask == nil else { return }
            scheduledEvaluationTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.scheduledEvaluationTask = nil
                self.evaluateAndStartLoad()
            }
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
            controller.prepareSceneConfiguration(
                configuration,
                activate: false
            )
            let keepsRenderedPreview = controller.hasRenderedPreview
            controller.beginLoadAttempt()
            interactiveView?.setViewerLoadState(keepsRenderedPreview ? .ready : .loading)
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
                    try controller.validatePreparedSceneConfiguration(for: request)
                    guard !Task.isCancelled else { return }
                    if let latestConfiguration = self.sceneConfigurations[request] {
                        controller.updateSceneConfiguration(latestConfiguration)
                    }
                    try controller.validatePreparedSceneConfiguration(for: request)
                    let requestedModel = request.url.map { ModelIdentifier.gaussianSplat($0) }
                    let preparedModel: PreparedViewerModelLoad
                    if let modelLoadPreparer = self.modelLoadPreparer {
                        preparedModel = try await modelLoadPreparer(
                            renderer,
                            requestedModel,
                            forceReload
                        )
                    } else {
                        preparedModel = try await renderer.prepareModelLoad(
                            requestedModel,
                            forceReload: forceReload
                        )
                    }
                    guard !Task.isCancelled,
                          self.planner.latestRequested == request else {
                        return
                    }
                    if let latestConfiguration = self.sceneConfigurations[request] {
                        controller.updateSceneConfiguration(latestConfiguration)
                    }
                    try controller.validatePreparedSceneConfiguration(for: request)
                    guard controller.activatePreparedSceneConfiguration(requestDraw: false) else {
                        throw SplatViewerConfigurationError.sceneBoundsOutsideSupportedRange
                    }
                    renderer.commitPreparedModelLoad(preparedModel)
                    self.displayedRequest = request
                    controller.recordLoadSuccess()
                    controller.isLoading = false
                    controller.isUpdating = false
                    controller.hasRenderedPreview = request.url != nil
                    self.interactiveView?.setViewerLoadState(.ready)
                    self.onLoadStateChanged?(.ready)
                } catch {
                    guard !Task.isCancelled,
                          self.planner.latestRequested == request else {
                        return
                    }
                    controller.isLoading = false
                    controller.isUpdating = false
                    controller.recordLoadFailure(
                        error.localizedDescription,
                        retryable: !(error is SplatViewerConfigurationError)
                            && SplatRenderer.isRetryableLoadError(error)
                    )
                    if controller.hasRenderedPreview {
                        self.interactiveView?.setViewerLoadState(.ready)
                    } else {
                        self.interactiveView?.setViewerLoadState(.failed)
                    }
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
        coordinator.controller?.resetSceneConfiguration()
        coordinator.loadTask?.cancel()
        coordinator.deferredLoadTask?.cancel()
        coordinator.scheduledEvaluationTask?.cancel()
        coordinator.initializationFailureTask?.cancel()
        coordinator.modelLoadPreparer = nil
        if let interactiveView = nsView as? InteractiveMTKView {
            interactiveView.onOrbit = nil
            interactiveView.onScrollZoom = nil
            interactiveView.onMagnify = nil
            interactiveView.onPan = nil
            interactiveView.onFreeLook = nil
            interactiveView.onKeyboardCommand = nil
            interactiveView.onMovementInputChanged = nil
            interactiveView.onInteractionActivity = nil
        }
        if coordinator.controller?.renderer === coordinator.renderer {
            coordinator.controller?.renderer = nil
        }
        coordinator.renderer?.onSortFailure = nil
        coordinator.renderer?.onSortSuccess = nil
        nsView.delegate = nil
        coordinator.renderer = nil
        coordinator.interactiveView = nil
        coordinator.controller = nil
    }

    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        let metalKitView = InteractiveMTKView(frame: .zero, device: nil)
        context.coordinator.interactiveView = metalKitView
        context.coordinator.controller = controller
        context.coordinator.onLoadStateChanged = onLoadStateChanged
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            context.coordinator.scheduleInitializationFailure(
                "Metal is not available on this Mac."
            )
            return metalKitView
        }
        metalKitView.device = metalDevice

        guard let renderer = MetalKitSceneRenderer(metalKitView) else {
            context.coordinator.scheduleInitializationFailure(
                "Failed to initialize Metal renderer."
            )
            return metalKitView
        }
        context.coordinator.renderer = renderer
        controller.renderer = renderer
        renderer.onSortFailure = { [weak controller] message in
            controller?.recordSortFailure(message)
        }
        renderer.onSortSuccess = { [weak controller] in
            controller?.recordSortSuccess()
        }
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
        metalKitView.onFreeLook = { [weak renderer] deltaX, deltaY in
            renderer?.freeLook(deltaX: Float(deltaX), deltaY: Float(deltaY))
        }
        metalKitView.onMovementInputChanged = { [
            weak renderer,
            weak coordinator = context.coordinator
        ] keys, isSprinting in
            renderer?.setMovementInput(keys, isSprinting: isSprinting)
            coordinator?.setContinuousInteraction(!keys.isEmpty)
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
            loadAttemptRevision: loadAttemptRevision,
            configuration: sceneConfiguration
        )
    }
}

enum SplatViewerAccessibilityLoadState: String {
    case loading = "Loading"
    case ready = "Ready"
    case failed = "Failed"
}

final class InteractiveMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onScrollZoom: ((CGFloat, CGPoint) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onFreeLook: ((CGFloat, CGFloat) -> Void)?
    var onKeyboardCommand: ((ViewerKeyboardCommand) -> Void)?
    var onMovementInputChanged: ((Set<ViewerMovementKey>, Bool) -> Void)?
    var onInteractionActivity: (() -> Void)?

    private var lastLocation: NSPoint?
    private var activeDragMode: ViewerDragMode?
    private var heldMovementKeys: Set<ViewerMovementKey> = []
    private var isSprintKeyHeld = false

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

    func setViewerLoadState(_ state: SplatViewerAccessibilityLoadState) {
        setAccessibilityValue(state.rawValue)
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
            clearHeldMovementInput()
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        beginDrag(
            with: event,
            mode: ViewerPointerCommand.dragMode(
                forPrimaryButtonWith: ViewerKeyboardModifiers(event.modifierFlags)
            )
        )
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        beginDrag(with: event, mode: ViewerPointerCommand.secondaryButtonDragMode)
    }

    override func rightMouseDragged(with event: NSEvent) {
        continueDrag(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        onInteractionActivity?()
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        beginDrag(with: event, mode: ViewerPointerCommand.middleButtonDragMode)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        continueDrag(with: event)
    }

    private func beginDrag(with event: NSEvent, mode: ViewerDragMode) {
        window?.makeFirstResponder(self)
        onInteractionActivity?()
        lastLocation = event.locationInWindow
        activeDragMode = mode
    }

    private func continueDrag(with event: NSEvent) {
        onInteractionActivity?()
        guard let last = lastLocation else { return }
        let current = event.locationInWindow
        let deltaX = current.x - last.x
        let deltaY = current.y - last.y
        lastLocation = current

        switch activeDragMode {
        case .pan:
            onPan?(deltaX, deltaY)
        case .freeLook:
            onFreeLook?(deltaX, deltaY)
        case .orbit, nil:
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

        if let movementKey = ViewerKeyboardCommand.resolveMovementKey(keyCode: event.keyCode),
           !ViewerKeyboardModifiers(event.modifierFlags).blocksMovement {
            // Auto-repeats are consumed too; letting them fall through to
            // super would beep on every repeat while flying.
            guard !event.isARepeat else { return }
            onInteractionActivity?()
            if heldMovementKeys.insert(movementKey).inserted {
                isSprintKeyHeld = event.modifierFlags.contains(.shift)
                onMovementInputChanged?(heldMovementKeys, isSprintKeyHeld)
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

    override func keyUp(with event: NSEvent) {
        // Releases are never modifier-gated: a key pressed bare and released
        // while a modifier is down must still stop the flight.
        guard let movementKey = ViewerKeyboardCommand.resolveMovementKey(
            keyCode: event.keyCode
        ) else {
            super.keyUp(with: event)
            return
        }
        if heldMovementKeys.remove(movementKey) != nil {
            onMovementInputChanged?(heldMovementKeys, isSprintKeyHeld)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let isShiftHeld = event.modifierFlags.contains(.shift)
        if isShiftHeld != isSprintKeyHeld {
            isSprintKeyHeld = isShiftHeld
            onMovementInputChanged?(heldMovementKeys, isSprintKeyHeld)
        }
        super.flagsChanged(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        clearHeldMovementInput()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        clearHeldMovementInput()
    }

    private func clearHeldMovementInput() {
        guard !heldMovementKeys.isEmpty || isSprintKeyHeld else { return }
        heldMovementKeys.removeAll()
        isSprintKeyHeld = false
        onMovementInputChanged?(heldMovementKeys, isSprintKeyHeld)
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
        setViewerLoadState(.loading)
        setAccessibilityHelp(
            "Drag to orbit. Right-drag or Control-drag looks around. Option-drag pans. "
                + "Scroll or pinch zooms. Hold W, A, S, D to fly, E and Q to fly up and down, "
                + "and Shift to sprint. Press F to fit or R to reset."
        )
        setAccessibilityChildren([])
    }
}
