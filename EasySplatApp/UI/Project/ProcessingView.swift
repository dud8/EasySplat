import SwiftUI
import AppKit
import Foundation
import Combine

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showReturnConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Building your 3D memory")
                .font(.title2.weight(.semibold))

            GeometryReader { geometry in
                let availableHeight = geometry.size.height
                let previewHeight = min(420, max(260, availableHeight * 0.38))
                let detailsHeight = min(320, max(180, availableHeight * 0.26))

                HStack(alignment: .top, spacing: 24) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.statusTitle)
                                .font(.headline)
                            if let detail = model.statusDetail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(summaryDetail(detail))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                                if let timingText = timingText(now: context.date) {
                                    Text(timingText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if model.stage == .trainBrush {
                                Text("Training in progress. Closing now exports a snapshot only; resuming restarts from scratch.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ShimmeringProgressView(progress: model.progress)
                            if model.stage == .trainBrush {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle("Show live preview", isOn: $model.isLivePreviewEnabled)
                                        .toggleStyle(.checkbox)
                                        .disabled(model.isStopping)
                                    Text("May slow training. Updates every few minutes.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if model.isLivePreviewEnabled, let snapshotURL = model.trainingSnapshotURL {
                                        TrainingLivePreviewView(
                                            snapshotURL: snapshotURL,
                                            preferredHeight: previewHeight,
                                            trainingProgressFraction: model.progress
                                        )
                                    }
                                }
                            }
                            if model.isStopping {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(stoppingStatusText)
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
                                copyText: model.errorDetailsText,
                                maxExpandedHeight: detailsHeight
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    StepperProgressView(currentStage: model.stage)
                        .frame(width: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
        .sheet(isPresented: $model.isShowingTrainingConsent) {
            TrainingConsentSheet()
                .environmentObject(model)
        }
        .overlay {
            if model.isStopping {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(stoppingHeadlineText)
                            .font(.headline)
                        Text(stoppingDetailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .stroke(Theme.border)
                    )
                }
                .transition(.opacity)
            }
        }
        .confirmationDialog("Stop this project?", isPresented: $showReturnConfirm, titleVisibility: .visible) {
            Button(returnPrimaryActionLabel) {
                model.cancelCurrentProject(deleteProject: false)
            }
            Button("Delete Project", role: .destructive) {
                model.cancelCurrentProject(deleteProject: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(returnDialogMessage)
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

    private func timingText(now: Date) -> String? {
        guard let elapsed = model.elapsedSinceStageStart(now: now) else { return nil }

        var parts = ["Elapsed \(formatElapsed(elapsed))"]
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

    private func summaryDetail(_ detail: String) -> String {
        guard model.stage == .trainBrush else { return detail }
        guard let range = detail.range(of: " (running ") else { return detail }
        return String(detail[..<range.lowerBound])
    }

    private var returnPrimaryActionLabel: String {
        model.stage == .trainBrush ? "Export Snapshot" : "Save Project"
    }

    private var stoppingStatusText: String {
        if model.stopAction == .deleteProject {
            return "Stopping and deleting… (up to 15 seconds)"
        }
        if model.stage == .trainBrush {
            return "Exporting snapshot… (up to 15 seconds)"
        }
        return "Saving progress… (up to 15 seconds)"
    }

    private var stoppingHeadlineText: String {
        if model.stopAction == .deleteProject {
            return "Stopping and deleting…"
        }
        if model.stage == .trainBrush {
            return "Exporting snapshot…"
        }
        return "Saving progress…"
    }

    private var stoppingDetailText: String {
        if model.stopAction == .deleteProject {
            return "Stopping at the next safe point (up to 15 seconds)."
        }
        if model.stage == .trainBrush {
            return "Exporting the latest snapshot (training restarts from scratch on resume)."
        }
        return "Stopping at the next safe point (up to 15 seconds)."
    }

    private var returnDialogMessage: String {
        if model.stage == .trainBrush {
            return "Exporting keeps only a snapshot. If you resume, training starts over from scratch. Delete removes all project data."
        }
        return "You can save and resume later, or delete the project."
    }
}

private struct TrainingConsentSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var rememberChoice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Training will start")
                .font(.headline)
            Text("Training can only export snapshots. If you quit during training, resuming starts over from scratch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Toggle("Remember my choice", isOn: $rememberChoice)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.resolveTrainingConsent(accepted: false, remember: false)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Continue Training") {
                    let remember = rememberChoice
                    model.resolveTrainingConsent(accepted: true, remember: remember)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(true)
        .onAppear {
            rememberChoice = false
        }
    }
}
