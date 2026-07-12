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
        .trainSplat,
        .exportSplat,
        .done
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(displayStages, id: \.self) { stage in
                let status = status(for: stage)
                let color = statusColor(for: status)
                HStack(spacing: 10) {
                    StageIndicator(status: status, color: color)
                    Text(stage.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color)
                }
                .modifier(BreathingOpacity(isActive: status == .current))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(stage.displayName))
                .accessibilityValue(Text(accessibilityValue(for: status)))
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

    private func status(for stage: PipelineStage) -> StageStatus {
        guard let currentStage else { return .upcoming }
        if stage == currentStage { return .current }
        if let currentIndex = displayStages.firstIndex(of: currentStage),
           let stageIndex = displayStages.firstIndex(of: stage),
           stageIndex < currentIndex {
            return .completed
        }
        return .upcoming
    }

    private func statusColor(for status: StageStatus) -> Color {
        switch status {
        case .completed:
            return Theme.success
        case .current:
            return Theme.accent
        case .upcoming:
            return Theme.subtle
        }
    }

    private func accessibilityValue(for status: StageStatus) -> String {
        switch status {
        case .completed:
            return "Completed"
        case .current:
            return "In progress"
        case .upcoming:
            return "Upcoming"
        }
    }
}

private enum StageStatus {
    case completed
    case current
    case upcoming
}

private struct StageIndicator: View {
    let status: StageStatus
    let color: Color

    var body: some View {
        ZStack {
            switch status {
            case .completed:
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            case .current:
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
            case .upcoming:
                Circle()
                    .strokeBorder(color.opacity(0.7), lineWidth: 2)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
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
