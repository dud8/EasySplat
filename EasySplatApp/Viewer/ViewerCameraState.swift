import Foundation
import simd

struct ViewerClipPlanes: Equatable, Sendable {
    let near: Float
    let far: Float
}

struct ViewerCameraState: Equatable, Sendable {
    private static let defaultOpeningDirection = SIMD3<Float>(0, 0, -1)
    private static let defaultVerticalFOV = Float(65 * Double.pi / 180)
    private static let minimumPitchClearance: Float = 0.001
    private static let minimumRadius: Float = 1e-12
    private static let maximumRadius = Float.greatestFiniteMagnitude / 100_000
    private static let minimumFOV: Float = 0.001
    private static let maximumFOV = Float.pi - minimumFOV
    private static let maximumViewportDimension: CGFloat = 1_000_000
    private static let scrollZoomCoefficient: Float = 0.02
    private static let keyboardZoomFactor: Float = 0.85

    private(set) var target: SIMD3<Float>
    private(set) var yaw: Float
    private(set) var pitch: Float
    private(set) var distance: Float
    private(set) var sceneRadius: Float
    private(set) var openingDirection: SIMD3<Float>
    private(set) var viewportSize: CGSize
    private(set) var verticalFOV: Float
    private(set) var interactionRevision: UInt64

    private var homeTarget: SIMD3<Float>
    private var automaticFitRevision: UInt64?

    init(
        target: SIMD3<Float> = .zero,
        sceneRadius: Float = 1,
        openingDirection: SIMD3<Float> = SIMD3<Float>(0, 0, -1),
        viewportSize: CGSize = CGSize(width: 1, height: 1),
        verticalFOV: Float = Float(65 * Double.pi / 180),
        yaw: Float? = nil,
        pitch: Float? = nil,
        distance: Float? = nil,
        interactionRevision: UInt64 = 0
    ) {
        let safeTarget = Self.isFinite(target) ? target : .zero
        let safeRadius = Self.sanitizedRadius(sceneRadius)
        let safeViewport = Self.sanitizedViewport(viewportSize)
        let safeVerticalFOV = Self.sanitizedFOV(verticalFOV)
        let opening = Self.orientation(for: openingDirection)
        let safeYaw = yaw.flatMap(Self.sanitizedYaw) ?? opening.yaw
        let safePitch = pitch.flatMap(Self.sanitizedPitch) ?? opening.pitch

        self.target = safeTarget
        self.yaw = safeYaw
        self.pitch = safePitch
        self.sceneRadius = safeRadius
        self.openingDirection = opening.direction
        self.viewportSize = safeViewport
        self.verticalFOV = safeVerticalFOV
        self.interactionRevision = interactionRevision
        self.homeTarget = safeTarget
        self.automaticFitRevision = distance == nil ? interactionRevision : nil

        let fitted = Self.fittedDistance(
            radius: safeRadius,
            verticalFOV: safeVerticalFOV,
            viewportSize: safeViewport
        )
        self.distance = Self.clampedDistance(
            distance.flatMap { $0.isFinite ? $0 : nil } ?? fitted,
            radius: safeRadius
        )
    }

    var horizontalFOV: Float {
        Self.horizontalFOV(verticalFOV: verticalFOV, viewportSize: viewportSize)
    }

    var fittedDistance: Float {
        Self.fittedDistance(
            radius: sceneRadius,
            verticalFOV: verticalFOV,
            viewportSize: viewportSize
        )
    }

    var panWorldUnitsPerPixel: Float {
        2 * distance * tan(verticalFOV / 2) / Float(viewportSize.height)
    }

    var clipPlanes: ViewerClipPlanes {
        let near = max(sceneRadius * 1e-4, distance * 1e-3)
        let far = max(distance + 4 * sceneRadius, 8 * sceneRadius, near * 1_000)
        return ViewerClipPlanes(near: near, far: far)
    }

    var forwardDirection: SIMD3<Float> {
        let cosinePitch = cos(pitch)
        return SIMD3<Float>(
            sin(yaw) * cosinePitch,
            sin(pitch),
            -cos(yaw) * cosinePitch
        )
    }

    var rightDirection: SIMD3<Float> {
        SIMD3<Float>(cos(yaw), 0, sin(yaw))
    }

    var upDirection: SIMD3<Float> {
        simd_normalize(simd_cross(rightDirection, forwardDirection))
    }

    var cameraPosition: SIMD3<Float> {
        target - forwardDirection * distance
    }

    mutating func updateViewportSize(_ size: CGSize) {
        let safeSize = Self.sanitizedViewport(size)
        guard safeSize != viewportSize else { return }
        viewportSize = safeSize
        if automaticFitRevision == interactionRevision {
            distance = fittedDistance
        }
    }

    mutating func orbit(deltaYaw: Float, deltaPitch: Float) {
        guard deltaYaw.isFinite, deltaPitch.isFinite else { return }
        let nextYaw = Self.sanitizedYaw(yaw + deltaYaw) ?? yaw
        let nextPitch = Self.sanitizedPitch(pitch + deltaPitch) ?? pitch
        guard nextYaw != yaw || nextPitch != pitch else { return }
        yaw = nextYaw
        pitch = nextPitch
        recordInteraction()
    }

    /// Moves the scene with a drag expressed in screen pixels, where positive Y is down.
    mutating func pan(screenDelta: SIMD2<Float>) {
        guard screenDelta.x.isFinite, screenDelta.y.isFinite else { return }
        let scale = panWorldUnitsPerPixel
        let translation = rightDirection * (-screenDelta.x * scale)
            + upDirection * (screenDelta.y * scale)
        guard Self.isFinite(translation), translation != .zero else { return }
        target += translation
        recordInteraction()
    }

    mutating func zoomIn(anchoredAt pointer: CGPoint? = nil) {
        zoom(by: Self.keyboardZoomFactor, anchoredAt: pointer)
    }

    mutating func zoomOut(anchoredAt pointer: CGPoint? = nil) {
        zoom(by: 1 / Self.keyboardZoomFactor, anchoredAt: pointer)
    }

    /// Positive deltas move away from the scene; negative deltas move closer.
    mutating func zoomByScroll(delta: Float, anchoredAt pointer: CGPoint? = nil) {
        guard delta.isFinite else { return }
        zoom(byExponent: delta * Self.scrollZoomCoefficient, anchoredAt: pointer)
    }

    /// Positive magnification moves closer, matching the native trackpad gesture.
    mutating func zoomByPinch(magnification: Float, anchoredAt pointer: CGPoint? = nil) {
        guard magnification.isFinite else { return }
        zoom(byExponent: -magnification, anchoredAt: pointer)
    }

    mutating func fit() {
        let nextDistance = fittedDistance
        guard target != homeTarget || distance != nextDistance else { return }
        target = homeTarget
        distance = nextDistance
        recordInteraction()
    }

    mutating func reset() {
        let opening = Self.orientation(for: openingDirection)
        let nextDistance = fittedDistance
        guard target != homeTarget
            || yaw != opening.yaw
            || pitch != opening.pitch
            || distance != nextDistance
        else { return }
        target = homeTarget
        yaw = opening.yaw
        pitch = opening.pitch
        distance = nextDistance
        recordInteraction()
    }

    /// Applies asynchronously loaded scene bounds only if no input occurred since loading began.
    @discardableResult
    mutating func applyBounds(
        center: SIMD3<Float>,
        radius: Float,
        openingDirection: SIMD3<Float>?,
        ifInteractionRevisionMatches expectedRevision: UInt64
    ) -> Bool {
        guard interactionRevision == expectedRevision,
              Self.isFinite(center),
              radius.isFinite,
              radius > 0
        else { return false }

        let opening = Self.orientation(for: openingDirection ?? Self.defaultOpeningDirection)
        target = center
        homeTarget = center
        sceneRadius = Self.sanitizedRadius(radius)
        self.openingDirection = opening.direction
        yaw = opening.yaw
        pitch = opening.pitch
        distance = fittedDistance
        automaticFitRevision = interactionRevision
        return true
    }

    /// Updates scene-scale metadata after input without moving the current camera.
    @discardableResult
    mutating func adoptBoundsPreservingView(
        center: SIMD3<Float>,
        radius: Float,
        openingDirection: SIMD3<Float>?
    ) -> Bool {
        guard Self.isFinite(center), radius.isFinite, radius > 0 else { return false }
        let opening = Self.orientation(for: openingDirection ?? Self.defaultOpeningDirection)
        homeTarget = center
        sceneRadius = Self.sanitizedRadius(radius)
        self.openingDirection = opening.direction
        automaticFitRevision = nil
        return true
    }

    func targetPlanePoint(at viewportPoint: CGPoint) -> SIMD3<Float>? {
        guard viewportPoint.x.isFinite, viewportPoint.y.isFinite else { return nil }
        let width = Float(viewportSize.width)
        let height = Float(viewportSize.height)
        let normalizedX = 2 * Float(viewportPoint.x) / width - 1
        let normalizedY = 1 - 2 * Float(viewportPoint.y) / height
        guard normalizedX.isFinite, normalizedY.isFinite else { return nil }

        let direction = forwardDirection
            + rightDirection * (normalizedX * tan(horizontalFOV / 2))
            + upDirection * (normalizedY * tan(verticalFOV / 2))
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared.isFinite, lengthSquared > 1e-12 else { return nil }
        let ray = direction / sqrt(lengthSquared)
        let denominator = simd_dot(ray, forwardDirection)
        guard denominator.isFinite, abs(denominator) > 1e-6 else { return nil }
        let rayDistance = simd_dot(target - cameraPosition, forwardDirection) / denominator
        guard rayDistance.isFinite, rayDistance > 0 else { return nil }
        let point = cameraPosition + ray * rayDistance
        return Self.isFinite(point) ? point : nil
    }

    private mutating func zoom(byExponent exponent: Float, anchoredAt pointer: CGPoint?) {
        let boundedExponent = max(-80, min(80, exponent))
        zoom(by: exp(boundedExponent), anchoredAt: pointer)
    }

    private mutating func zoom(by factor: Float, anchoredAt pointer: CGPoint?) {
        guard factor.isFinite, factor > 0 else { return }
        let maximumDistance = sceneRadius * 10_000
        let requestedDistance = distance > maximumDistance / factor
            ? maximumDistance
            : distance * factor
        let nextDistance = Self.clampedDistance(requestedDistance, radius: sceneRadius)
        guard nextDistance != distance else { return }

        let anchorBefore = pointer.flatMap { targetPlanePoint(at: $0) }
        distance = nextDistance
        if let pointer,
           let anchorBefore,
           let anchorAfter = targetPlanePoint(at: pointer) {
            let correction = anchorBefore - anchorAfter
            if Self.isFinite(correction) {
                target += correction
            }
        }
        recordInteraction()
    }

    private mutating func recordInteraction() {
        interactionRevision &+= 1
    }

    private static func fittedDistance(
        radius: Float,
        verticalFOV: Float,
        viewportSize: CGSize
    ) -> Float {
        let horizontalFOV = horizontalFOV(
            verticalFOV: verticalFOV,
            viewportSize: viewportSize
        )
        let limitingHalfFOV = min(horizontalFOV, verticalFOV) / 2
        let distance = 1.1 * radius / sin(limitingHalfFOV)
        return clampedDistance(distance, radius: radius)
    }

    private static func horizontalFOV(verticalFOV: Float, viewportSize: CGSize) -> Float {
        let aspect = Float(viewportSize.width / viewportSize.height)
        return 2 * atan(tan(verticalFOV / 2) * aspect)
    }

    private static func clampedDistance(_ value: Float, radius: Float) -> Float {
        let minimum = radius * 0.001
        let maximum = radius * 10_000
        guard value.isFinite else { return maximum }
        return max(minimum, min(maximum, value))
    }

    private static func sanitizedRadius(_ radius: Float) -> Float {
        guard radius.isFinite, radius > 0 else { return 1 }
        return max(minimumRadius, min(maximumRadius, radius))
    }

    private static func sanitizedViewport(_ size: CGSize) -> CGSize {
        func sanitizedDimension(_ value: CGFloat) -> CGFloat {
            guard value.isFinite, value > 0 else { return 1 }
            return max(1, min(maximumViewportDimension, value))
        }
        return CGSize(
            width: sanitizedDimension(size.width),
            height: sanitizedDimension(size.height)
        )
    }

    private static func sanitizedFOV(_ value: Float) -> Float {
        guard value.isFinite, value > 0 else { return defaultVerticalFOV }
        return max(minimumFOV, min(maximumFOV, value))
    }

    private static func sanitizedYaw(_ value: Float) -> Float? {
        guard value.isFinite else { return nil }
        var wrapped = value.truncatingRemainder(dividingBy: 2 * .pi)
        if wrapped > .pi {
            wrapped -= 2 * .pi
        } else if wrapped < -.pi {
            wrapped += 2 * .pi
        }
        return wrapped == -0 ? 0 : wrapped
    }

    private static func sanitizedPitch(_ value: Float) -> Float? {
        guard value.isFinite else { return nil }
        let limit = Float.pi / 2 - minimumPitchClearance
        return max(-limit, min(limit, value))
    }

    private static func orientation(
        for rawDirection: SIMD3<Float>
    ) -> (direction: SIMD3<Float>, yaw: Float, pitch: Float) {
        let normalized: SIMD3<Float>
        let largestComponent = max(abs(rawDirection.x), abs(rawDirection.y), abs(rawDirection.z))
        if isFinite(rawDirection), largestComponent.isFinite, largestComponent > 0 {
            let scaled = rawDirection / largestComponent
            let scaledLengthSquared = simd_length_squared(scaled)
            normalized = scaled / sqrt(scaledLengthSquared)
        } else {
            normalized = defaultOpeningDirection
        }

        let horizontalLength = hypot(normalized.x, normalized.z)
        let yaw = horizontalLength > 1e-5
            ? atan2(normalized.x, -normalized.z)
            : 0
        let limit = Float.pi / 2 - minimumPitchClearance
        let pitch = max(-limit, min(limit, asin(max(-1, min(1, normalized.y)))))
        let cosinePitch = cos(pitch)
        let representableDirection = SIMD3<Float>(
            sin(yaw) * cosinePitch,
            sin(pitch),
            -cos(yaw) * cosinePitch
        )
        return (representableDirection, yaw, pitch)
    }

    private static func isFinite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
