import AppKit
import EasySplatCore
import Foundation
import SwiftUI

enum ProcessingPhase: Int, Equatable {
    case prepare = 1
    case reconstruct
    case train
    case finish

    var phrase: String {
        switch self {
        case .prepare: return "Preparing input"
        case .reconstruct: return "Reconstructing scene"
        case .train: return "Training splat"
        case .finish: return "Finishing"
        }
    }

    var heading: String {
        "Step \(rawValue) of 4 · \(phrase)"
    }

    static func forStage(_ stage: PipelineStage) -> ProcessingPhase {
        switch stage {
        case .importInput, .extractFrames, .selectFrames:
            return .prepare
        case .sfmFeatures, .sfmMatching, .sfmMapping:
            return .reconstruct
        case .trainSplat:
            return .train
        case .exportSplat, .done:
            return .finish
        }
    }
}

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTechnicalDetailsExpanded = false
    @State private var showStopConfirmation = false

    private var phase: ProcessingPhase {
        model.stage.map(ProcessingPhase.forStage) ?? .prepare
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(phase.heading)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("processing.phase")

                if model.lastError != nil {
                    failureContent
                } else {
                    progressContent
                }

                technicalDetails
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.lastError == nil {
                    Button("Stop…") {
                        showStopConfirmation = true
                    }
                    .disabled(model.isStopping)
                    .accessibilityIdentifier("processing.stop")
                }
            }
        }
        .confirmationDialog(
            model.isTrainingStageActive ? "Stop training?" : "Stop this project?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop and Keep Project") {
                model.cancelCurrentProject(deleteProject: false)
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopDialogMessage)
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = model.progress {
                let clampedProgress = min(max(progress, 0), 1)
                ProgressView(value: clampedProgress)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int((clampedProgress * 100).rounded())) percent")
            } else {
                ProgressView()
                    .accessibilityLabel("In progress")
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let timingText = timingText(now: context.date) {
                    Text(timingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isStopping {
                Label(stoppingStatusText, systemImage: "stop.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failureContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn’t finish this splat", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Open Technical Details for the exact error and logs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                Button("Try Again") {
                    if let projectURL = model.currentProjectURL {
                        model.resumeProject(at: projectURL)
                    } else {
                        model.startFromPendingSelection()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canTryAgain || model.isStopping)
                .accessibilityIdentifier("processing.tryAgain")

                Button("Back to Projects") {
                    model.reset()
                    model.viewState = .home
                    model.refreshProjectSummaries()
                }
                .disabled(model.isStopping)
                .accessibilityIdentifier("processing.backToProjects")

                if let projectURL = model.currentProjectURL {
                    Menu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([projectURL])
                        }
                        Button("Copy Diagnostics") {
                            model.copyDiagnosticBundle(forProjectURL: projectURL)
                        }
                        Button("Save Diagnostics…") {
                            model.saveDiagnosticBundle(forProjectURL: projectURL)
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .disabled(model.isStopping)
                    .accessibilityIdentifier("processing.failureMore")
                }
            }
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $isTechnicalDetailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Stage", value: model.stage?.displayName ?? "Preparing")
                    .font(.caption)

                if !model.statusTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model.statusTitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(technicalText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)

                HStack {
                    Spacer()
                    Button("Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(technicalText, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Technical Details")
                .font(.headline)
        }
        .accessibilityIdentifier("processing.technicalDetails")
    }

    private var canTryAgain: Bool {
        Self.canTryAgain(
            projectExists: model.currentProjectURL != nil,
            pendingInputExists: !model.pendingVideoURLs.isEmpty || model.pendingPhotosFolderURL != nil
        )
    }

    nonisolated static func canTryAgain(projectExists: Bool, pendingInputExists: Bool) -> Bool {
        projectExists || pendingInputExists
    }

    private var technicalText: String {
        let text = model.errorDetailsText ?? model.processingDetailsText
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No technical details yet." : trimmed
    }

    private func timingText(now: Date) -> String? {
        Self.timingText(
            elapsed: model.elapsedSinceStageStart(now: now),
            silenceSeconds: model.lastPipelineEventAt.map { now.timeIntervalSince($0) }
        )
    }

    static func timingText(elapsed: TimeInterval?, silenceSeconds: TimeInterval?) -> String? {
        guard let elapsed else { return nil }
        var parts = ["Elapsed \(formatElapsed(elapsed))"]
        if let silenceSeconds {
            if silenceSeconds >= 1 {
                parts.append("Last update \(formatElapsed(silenceSeconds)) ago")
            } else {
                parts.append("Last update now")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        return String(format: "%dm %02ds", minutes, seconds)
    }

    private var stoppingStatusText: String {
        if model.stopAction == .deleteProject {
            return "Stopping and moving project to Trash…"
        }
        if model.isTrainingStageActive {
            return "Saving and validating the training checkpoint…"
        }
        return "Stopping at a safe point…"
    }

    private var stopDialogMessage: String {
        if model.isTrainingStageActive {
            return "EasySplat will stop at a safe point. It will resume from a validated optimizer checkpoint when one is available; otherwise training restarts from the reconstructed scene."
        }
        return "EasySplat will stop at a safe point and keep the last completed stage. You can resume this project later."
    }
}
