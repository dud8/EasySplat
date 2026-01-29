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
                HStack(spacing: 10) {
                    Circle()
                        .fill(color(for: stage))
                        .frame(width: 10, height: 10)
                    Text(stage.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color(for: stage))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
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
