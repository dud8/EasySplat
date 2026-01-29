import SwiftUI

struct ShimmeringProgressView: View {
    let progress: Double
    var height: CGFloat = 8
    var trackColor: Color = Theme.border
    var fillColor: Color = Theme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(max(progress, 0), 1)
            let fillWidth = proxy.size.width * clampedProgress
            let cornerRadius = height / 2
            let shouldShimmer = !reduceMotion && clampedProgress < 1

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(trackColor)
                if fillWidth > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fillColor)
                        .frame(width: fillWidth)
                        .overlay {
                            if shouldShimmer {
                                ShimmerOverlay(
                                    isActive: shouldShimmer,
                                    duration: 1.6,
                                    intensity: .subtle
                                )
                                    .frame(width: fillWidth, height: proxy.size.height)
                                    .mask(
                                        RoundedRectangle(cornerRadius: cornerRadius)
                                            .frame(width: fillWidth, height: proxy.size.height)
                                    )
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Progress")
        .accessibilityValue(Text("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent"))
    }
}

private struct ShimmerOverlay: View {
    let isActive: Bool
    let duration: Double
    let intensity: ShimmerIntensity

    var body: some View {
        if !isActive {
            Color.clear
        } else {
            TimelineView(.animation) { context in
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let shimmerWidth = max(18, width * 0.35)
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat((t.truncatingRemainder(dividingBy: duration)) / duration)
                    let offset = (width + shimmerWidth) * phase - shimmerWidth

                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.0), location: 0.0),
                            .init(color: Color.white.opacity(0.0), location: 0.45),
                            .init(color: Color.white.opacity(intensity.peakOpacity), location: 0.5),
                            .init(color: Color.white.opacity(0.0), location: 0.55),
                            .init(color: Color.white.opacity(0.0), location: 1.0)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: shimmerWidth, height: proxy.size.height)
                    .rotationEffect(.degrees(12))
                    .offset(x: offset)
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
}
