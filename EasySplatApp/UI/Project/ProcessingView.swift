import SwiftUI
import AppKit
import Foundation
import Combine

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showReturnConfirm = false
    @State private var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Building your 3D memory")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.statusTitle)
                        .font(.headline)
                    if let detail = model.statusDetail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let timingText {
                        Text(timingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ShimmeringProgressView(progress: model.progress)
                    if model.isStopping {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.stopAction == .deleteProject ? "Stopping and deleting… (up to 15 seconds)" : "Saving progress… (up to 15 seconds)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                    LogDrawerView(
                        lines: model.logLines,
                        detailsText: model.processingDetailsText,
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
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isStopping)
                }

                Button("Return") {
                    showReturnConfirm = true
                }
                .buttonStyle(SecondaryButtonStyle(variant: .subtleAccent))
                .disabled(model.isStopping)
            }
        }
        .padding(32)
        .confirmationDialog("Cancel this project?", isPresented: $showReturnConfirm, titleVisibility: .visible) {
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
    }

    private func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        return String(format: "%dm %02ds", minutes, seconds)
    }

    private var timingText: String? {
        guard let startedAt = model.stageStartedAt else { return nil }

        var parts = ["Elapsed \(formatElapsed(now.timeIntervalSince(startedAt)))"]
        if let lastUpdateAt = model.lastPipelineEventAt {
            let silence = now.timeIntervalSince(lastUpdateAt)
            if silence >= 1 {
                parts.append("Last update \(formatElapsed(silence)) ago")
            } else {
                parts.append("Last update now")
            }
        }
        return parts.joined(separator: " • ")
    }
}
