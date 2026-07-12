import SwiftUI
import AppKit
import EasySplatCore

struct ViewerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Text("Your splat is ready")
                    .font(.title2.weight(.semibold))
                if let duration = totalRunDurationText {
                    Text(duration)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.success)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Theme.success.opacity(0.13))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Theme.success.opacity(0.35), lineWidth: 0.5)
                        )
                        .help("Total wall-clock time across all pipeline stages.")
                        .accessibilityLabel("Completed in \(duration)")
                }
            }

            if let plyURL = model.outputPlyURL {
                VStack(spacing: 4) {
                    Text(plyURL.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let info = model.currentOutputPlyInfo {
                        HStack(spacing: 8) {
                            Text(info.splatCountText)
                                .font(.caption.monospacedDigit())
                            if let size = info.sizeText {
                                Text("·").font(.caption)
                                Text(size).font(.caption.monospacedDigit())
                            }
                            if let format = info.formatLabel {
                                Text("·").font(.caption)
                                Text(format).font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                SplatViewerView(splatURL: plyURL)
                    .frame(height: 360)
                    .frame(maxWidth: .infinity)
                if let preset = model.currentPreset, let input = model.currentInput {
                    RunConfigSummaryView(preset: preset, input: input)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let reconstruction = model.currentReconstruction {
                    ReconstructionDetailPanel(
                        summary: reconstruction,
                        fleetMedianFraction: ProjectFleetStats.medianCoverage(
                            excluding: model.currentProjectURL,
                            from: model.projectSummaries
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.currentStageTimings.isEmpty {
                    StageTimingPanel(
                        timings: model.currentStageTimings,
                        comparisonMedianSeconds: medianTotalSecondsForCurrentPreset()
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let autoTune = model.currentAutoTune {
                    AutoTunePanel(snapshot: autoTune)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.currentProjectURL != nil {
                    ProjectNotesEditor()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button("Share…") {
                        model.shareCurrentSplat()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isShareSheetActive)

                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([plyURL])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if let shareStatus = model.shareStatusMessage {
                    Text(shareStatus)
                        .font(.caption)
                        .foregroundStyle(model.shareStatusIsError ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Share status")
                        .accessibilityValue(shareStatus)
                }
            } else {
                Text("No output found yet.")
                    .foregroundStyle(.secondary)
            }

            Button("Start Another") {
                // Flush any in-flight notes save so leaving the viewer
                // doesn't drop a half-typed annotation; harmless if nothing
                // is pending.
                model.flushPendingNotesSave()
                model.viewState = .home
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Return to the home screen to pick a new input (Esc).")
        }
        .padding(32)
    }

    private var totalRunDurationText: String? {
        guard let total = model.currentStageTimings.totalDurationSeconds, total > 0 else { return nil }
        return StageTimingDisplay.formatDuration(seconds: total)
    }

    /// Predictor median total duration for the current project's preset, excluding the
    /// project being viewed so the comparison badge never benchmarks a run against itself
    /// (post-completion the current project appears in `projectSummaries` with its own
    /// ready timings). Returns nil when there are not enough other samples.
    private func medianTotalSecondsForCurrentPreset() -> TimeInterval? {
        guard let preset = model.currentPreset else { return nil }
        // Exclude the project being viewed so the comparison badge never
        // benchmarks a run against itself (post-completion the current
        // project shows up in projectSummaries with its own ready timings).
        let prediction = RunDurationPredictor.predict(
            mode: preset.mode,
            quality: preset.quality,
            from: model.projectSummaries,
            excluding: model.currentProjectURL
        )
        return prediction?.seconds
    }

}
