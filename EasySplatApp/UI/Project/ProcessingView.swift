import SwiftUI
import AppKit

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCancelConfirm = false

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
                    LogDrawerView(
                        lines: model.logLines,
                        detailsText: model.errorDetails,
                        copyText: model.errorDetailsText
                    )
                }
                Spacer()
                StepperProgressView(currentStage: model.stage)
                    .frame(width: 220)
            }

            HStack(spacing: 12) {
                if let projectURL = model.currentProjectURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([projectURL])
                    }
                    .buttonStyle(.bordered)
                }

                Button("Cancel") {
                    showCancelConfirm = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .confirmationDialog("Cancel this project?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Keep Project") {
                model.cancelCurrentProject(deleteProject: false)
            }
            Button("Delete Project", role: .destructive) {
                model.cancelCurrentProject(deleteProject: true)
            }
            Button("Continue", role: .cancel) {}
        } message: {
            Text("You can keep the project folder to resume later, or delete it to start fresh.")
        }
    }
}
