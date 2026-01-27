import SwiftUI
import AppKit

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Building your 3D memory")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.statusText)
                        .font(.headline)
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                    if let error = model.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                    LogDrawerView(lines: model.logLines)
                }
                Spacer()
                StepperProgressView(currentStage: model.stage)
                    .frame(width: 220)
            }

            if let projectURL = model.currentProjectURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([projectURL])
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }
}
