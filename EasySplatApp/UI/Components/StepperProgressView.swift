import Foundation
import SwiftUI
import EasySplatCore

struct StepperProgressView: View {
    let currentStage: PipelineStage?

    private let displayStages: [PipelineStage] = [
        .importInput,
        .extractFrames,
        .selectFrames,
        .sfmFeatures,
        .sfmMatching,
        .sfmMapping,
        .trainBrush,
        .exportSplat,
        .done
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(displayStages, id: \.self) { stage in
                let isCurrent = stage == currentStage
                HStack(spacing: 10) {
                    Circle()
                        .fill(color(for: stage))
                        .frame(width: 10, height: 10)
                    Text(stage.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color(for: stage))
                }
                .modifier(BreathingOpacity(isActive: isCurrent))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.border)
        )
    }

    private func color(for stage: PipelineStage) -> Color {
        guard let currentStage else { return Theme.subtle }
        if stage == currentStage { return Theme.accent }
        if let currentIndex = displayStages.firstIndex(of: currentStage),
           let stageIndex = displayStages.firstIndex(of: stage),
           stageIndex < currentIndex {
            return Theme.success
        }
        return Theme.subtle
    }
}

private struct BreathingOpacity: ViewModifier {
    let isActive: Bool
    private let minOpacity: Double = 0.78
    private let maxOpacity: Double = 1.0
    private let period: Double = 2.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if isActive && !reduceMotion {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let phase = (elapsed.truncatingRemainder(dividingBy: period)) / period
                    let pulse = 0.5 - 0.5 * cos(2 * .pi * phase)
                    let opacity = minOpacity + (maxOpacity - minOpacity) * pulse
                    content.opacity(opacity)
                }
            } else {
                content.opacity(1.0)
            }
        }
    }
}
