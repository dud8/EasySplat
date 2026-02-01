import SwiftUI

struct ShimmeringProgressView: View {
    let progress: Double?
    var height: CGFloat = 8
    var trackColor: Color = Theme.border
    var fillColor: Color = Theme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = progress.map { min(max($0, 0), 1) }
            let cornerRadius = height / 2
            let shouldShimmer = !reduceMotion && (clampedProgress == nil || (clampedProgress ?? 1) < 1)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(trackColor)

                if let clampedProgress {
                    let fillWidth = proxy.size.width * clampedProgress
                    if fillWidth > 0 {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(fillColor)
                            .frame(width: fillWidth)
                            .overlay {
                                if shouldShimmer {
                                    ShimmerOverlay(
                                        isActive: shouldShimmer,
                                        passDuration: 1.2,
                                        gapDuration: 0.9,
                                        intensity: .subtle
                                    )
                                        .frame(width: fillWidth, height: proxy.size.height)
                                        .mask(
                                            RoundedRectangle(cornerRadius: cornerRadius)
                                                .frame(width: fillWidth, height: proxy.size.height)
                                        )
                                }
                            }
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress ?? -1)
                    }
                } else {
                    IndeterminateBar(fillColor: fillColor, cornerRadius: cornerRadius, shouldShimmer: shouldShimmer)
                        .frame(height: proxy.size.height)
                        .mask(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(progress == nil ? "In progress" : "\(Int((min(max(progress ?? 0, 0), 1) * 100).rounded())) percent"))
    }
}

private struct IndeterminateBar: View {
    let fillColor: Color
    let cornerRadius: CGFloat
    let shouldShimmer: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startTime = Date().timeIntervalSinceReferenceDate

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let segmentWidth = min(max(56, width * 0.25), 180)
            let travel = width + segmentWidth
            let startX = -segmentWidth

            if reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fillColor)
                    .frame(width: segmentWidth, height: proxy.size.height)
                    .offset(x: (width - segmentWidth) / 2)
            } else {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate - startTime
                    let duration = 1.35
                    let phase = CGFloat((elapsed / duration).truncatingRemainder(dividingBy: 1.0))
                    let x = startX + travel * phase

                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fillColor)
                        .frame(width: segmentWidth, height: proxy.size.height)
                        .offset(x: x)
                        .overlay {
                            if shouldShimmer {
                                ShimmerOverlay(
                                    isActive: shouldShimmer,
                                    passDuration: 0.9,
                                    gapDuration: 0.0,
                                    intensity: .subtle
                                )
                                    .frame(width: segmentWidth, height: proxy.size.height)
                                    .mask(
                                        RoundedRectangle(cornerRadius: cornerRadius)
                                            .frame(width: segmentWidth, height: proxy.size.height)
                                    )
                            }
                        }
                }
            }
        }
    }
}

private struct ShimmerOverlay: View {
    let isActive: Bool
    let passDuration: Double
    let gapDuration: Double
    let intensity: ShimmerIntensity

    @State private var startTime = Date().timeIntervalSinceReferenceDate

    var body: some View {
        if !isActive {
            Color.clear
        } else {
            TimelineView(.animation) { context in
                GeometryReader { proxy in
                    let size = proxy.size
                    let elapsed = context.date.timeIntervalSinceReferenceDate - startTime
                    let cycleDuration = passDuration + gapDuration
                    let cycleTime = elapsed.truncatingRemainder(dividingBy: cycleDuration)

                    if cycleTime <= passDuration {
                        let phase = CGFloat(cycleTime / passDuration)
                        let width = size.width
                        let height = size.height

                        let angle = Angle(degrees: 16)
                        let bandHeight = height * 6
                        let sheenWidth = min(max(80, width * 0.55), 220)
                        let specularWidth = min(max(22, width * 0.16), 64)

                        let travel = width + sheenWidth
                        let centerX = (-sheenWidth / 2) + travel * phase
                        let centerY = height / 2
                        let lead = min(18, sheenWidth * 0.07)

                        let sheenGradient = LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.white.opacity(0.0), location: 0.0),
                                .init(color: Color.white.opacity(0.0), location: 0.35),
                                .init(color: Color.white.opacity(intensity.sheenOpacity), location: 0.5),
                                .init(color: Color.white.opacity(0.0), location: 0.65),
                                .init(color: Color.white.opacity(0.0), location: 1.0)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )

                        let specularGradient = LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.white.opacity(0.0), location: 0.0),
                                .init(color: Color.white.opacity(0.0), location: 0.46),
                                .init(color: Color.white.opacity(intensity.specularOpacity), location: 0.5),
                                .init(color: Color.white.opacity(0.0), location: 0.54),
                                .init(color: Color.white.opacity(0.0), location: 1.0)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )

                        ZStack {
                            Rectangle()
                                .fill(sheenGradient)
                                .frame(width: sheenWidth, height: bandHeight)
                                .rotationEffect(angle)
                                .position(x: centerX, y: centerY)
                                .blur(radius: 3.0)
                                .blendMode(.screen)

                            Rectangle()
                                .fill(specularGradient)
                                .frame(width: specularWidth, height: bandHeight)
                                .rotationEffect(angle)
                                .position(x: centerX + lead, y: centerY)
                                .blur(radius: 1.0)
                                .blendMode(.screen)
                        }
                        .compositingGroup()
                    } else {
                        Color.clear
                    }
                }
            }
            .clipped()
        }
    }
}

private enum ShimmerIntensity {
    case subtle
    case medium
    case bright

    var peakOpacity: Double {
        switch self {
        case .subtle:
            return 0.28
        case .medium:
            return 0.4
        case .bright:
            return 0.55
        }
    }

    var sheenOpacity: Double {
        peakOpacity * 0.35
    }

    var specularOpacity: Double {
        peakOpacity * 0.95
    }
}
