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
    let onBackToProjects: () -> Void

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
                if model.isRunActive {
                    Button(Self.stopToolbarTitle(projectExists: model.currentProjectURL != nil)) {
                        showStopConfirmation = true
                    }
                    .disabled(model.isStopping)
                    .accessibilityIdentifier("processing.stop")
                }
            }
        }
        .confirmationDialog(
            Self.stopDialogTitle(
                projectExists: model.currentProjectURL != nil,
                isTraining: model.isTrainingStageActive
            ),
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(Self.stopActionTitle(projectExists: model.currentProjectURL != nil)) {
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
            if let progress = Self.phaseProgress(stage: model.stage, progress: model.progress) {
                let clampedProgress = min(max(progress, 0), 1)
                ProgressView(value: clampedProgress)
                    .accessibilityLabel("Phase progress")
                    .accessibilityValue("\(Int((clampedProgress * 100).rounded())) percent")
                    .accessibilityIdentifier("processing.progress")
            } else {
                ProgressView()
                    .accessibilityLabel("In progress")
                    .accessibilityIdentifier("processing.progress")
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let timingText = timingText(now: context.date) {
                    Text(timingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("processing.timing")
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
                Text(Self.failureMessage(model.lastError))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                if model.failureRetryAllowed {
                    Button(Self.failureActionTitle(recovery: model.validationRecovery)) {
                        model.retryAfterFailure()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canTryAgain || model.isStopping || model.isRunActive)
                    .accessibilityIdentifier("processing.tryAgain")
                }

                Button("Back to Projects") {
                    onBackToProjects()
                }
                .disabled(model.isStopping || model.isRunActive)
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
                    .disabled(model.isStopping || model.isRunActive)
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
                        model.copyTechnicalDetails(technicalText)
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

    nonisolated static func failureActionTitle(recovery: RunValidationRecovery?) -> String {
        switch recovery {
        case .useUnordered: return "Use Unordered"
        case .useFast, .useFastForMemory: return "Use Fast"
        case .useBalanced: return "Use Balanced"
        case .useAutomaticPhotoSelection: return "Use Automatic Selection"
        case .useMoreTrainingMemory: return "Use More Memory"
        case nil: return "Try Again"
        }
    }

    nonisolated static func failureMessage(_ message: String?) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No error details were reported." : trimmed
    }

    nonisolated static func phaseProgress(stage: PipelineStage?, progress: Double?) -> Double? {
        guard let progress, let stage else { return nil }
        switch stage {
        case .trainSplat, .exportSplat, .done:
            return progress
        case .importInput, .extractFrames, .selectFrames, .sfmFeatures, .sfmMatching, .sfmMapping:
            return nil
        }
    }

    private var technicalText: String {
        let text = model.errorDetailsText ?? model.processingDetailsText
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No technical details yet." : trimmed
    }

    private func timingText(now: Date) -> String? {
        Self.timingText(
            elapsed: model.elapsedSincePhaseStart(now: now),
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
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }

    private var stoppingStatusText: String {
        if model.currentProjectURL == nil {
            return "Stopping setup…"
        }
        if model.stopAction == .deleteProject {
            return "Stopping and moving project to Trash…"
        }
        if model.isTrainingStageActive {
            return "Saving and validating the training checkpoint…"
        }
        return "Stopping at a safe point…"
    }

    private var stopDialogMessage: String {
        Self.stopDialogMessage(
            projectExists: model.currentProjectURL != nil,
            isTraining: model.isTrainingStageActive
        )
    }

    nonisolated static func stopToolbarTitle(projectExists: Bool) -> String {
        projectExists ? "Stop Run…" : "Stop Setup…"
    }

    nonisolated static func stopDialogTitle(projectExists: Bool, isTraining: Bool) -> String {
        guard projectExists else { return "Stop setup?" }
        return isTraining ? "Stop training?" : "Stop this project?"
    }

    nonisolated static func stopActionTitle(projectExists: Bool) -> String {
        projectExists ? "Stop and Keep Project" : "Stop Setup"
    }

    nonisolated static func stopDialogMessage(projectExists: Bool, isTraining: Bool) -> String {
        guard projectExists else {
            return "EasySplat will stop preparing tools. No project has been created."
        }
        if isTraining {
            return "EasySplat will stop at a safe point. It will resume from a validated optimizer checkpoint when one is available; otherwise training restarts from the reconstructed scene."
        }
        return "EasySplat will stop at a safe point and keep the last completed stage. You can resume this project later."
    }
}
