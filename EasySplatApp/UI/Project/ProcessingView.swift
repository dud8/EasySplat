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

    /// Datasets bring their own camera poses, so reconstruction imports them
    /// rather than solving structure from scratch.
    func phrase(isDataset: Bool) -> String {
        if isDataset, self == .reconstruct { return "Importing camera poses" }
        return phrase
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

    /// Short label for the phase rail; the full phrase stays in the heading.
    var railLabel: String {
        switch self {
        case .prepare: return "Prepare"
        case .reconstruct: return "Reconstruct"
        case .train: return "Train"
        case .finish: return "Finish"
        }
    }

    static let allPhases: [ProcessingPhase] = [.prepare, .reconstruct, .train, .finish]

    /// Window subtitle shown while a run is active, so the current phase is
    /// visible from Mission Control and the Dock without raising the window.
    static func windowSubtitle(stage: PipelineStage?, isRunActive: Bool) -> String {
        guard isRunActive else { return "" }
        let phase = stage.map(ProcessingPhase.forStage) ?? .prepare
        return phase.heading
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

    private var isDatasetInput: Bool {
        model.currentInput?.isDataset == true
    }

    var body: some View {
        Group {
            if model.isTrainingPreviewVisible {
                previewWorkspace
            } else {
                documentWorkspace
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isTrainingStageActive {
                    Button {
                        model.setTrainingPreviewShown(!model.isTrainingPreviewShown)
                    } label: {
                        Label(
                            Self.previewToggleTitle(
                                isShown: model.isTrainingPreviewShown,
                                isAvailable: model.isTrainingPreviewAvailable
                            ),
                            systemImage: "cube.transparent"
                        )
                    }
                    .disabled(!model.isTrainingPreviewAvailable)
                    .help(Self.previewToggleHelp(isAvailable: model.isTrainingPreviewAvailable))
                    .accessibilityIdentifier("processing.previewToggle")
                }
            }
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

    /// The ordinary waiting screen: a reading column of status.
    private var documentWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading
                phaseRail

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
        .pageScrollEdgeEffect()
    }

    /// Once there is something to see, the splat takes the workspace and the status
    /// moves onto it. Same information, same order — it stops being a page and
    /// becomes a caption.
    private var previewWorkspace: some View {
        ZStack(alignment: .bottomLeading) {
            if let previewURL = model.trainingPreviewURL,
               let bounds = Self.viewerBounds(model.trainingPreviewSceneBounds) {
                SplatViewerView(
                    splatURL: previewURL,
                    reloadToken: model.trainingPreviewPublication,
                    sceneConfiguration: SplatViewerSceneConfiguration(bounds: bounds),
                    showsLoadErrors: false,
                    onLoadStateChanged: { state in
                        // The canvas has already taken the workspace by the time a
                        // decode can fail. Falling back is the difference between a
                        // brief empty frame and a run that looks broken for an hour.
                        if case .failed(let reason) = state {
                            model.releaseTrainingPreview(reason: reason)
                        }
                    },
                    presentation: .subordinate
                )
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                heading
                phaseRail
                progressContent
                Text(Self.previewCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("processing.previewCaption")
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: 480, alignment: .leading)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
            )
            .padding(Theme.Spacing.large)
        }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(phase.phrase(isDataset: isDatasetInput))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("processing.phase")

            if let context = contextLine {
                Text(context)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(context)
                    .accessibilityIdentifier("processing.context")
            }
        }
    }

    /// Names what the action does next. A run with no preview can only ever offer
    /// to show one, never to hide something that is not there.
    nonisolated static func previewToggleTitle(isShown: Bool, isAvailable: Bool) -> String {
        isShown && isAvailable ? "Hide Preview" : "Show Preview"
    }

    nonisolated static func previewToggleHelp(isAvailable: Bool) -> String {
        isAvailable
            ? "Show or hide the splat while it trains"
            : "No preview for this run — training is unaffected"
    }

    /// The viewer refuses a scene it cannot bound, so a preview without usable
    /// bounds is not mounted at all rather than mounted blank.
    nonisolated static func viewerBounds(_ bounds: SplatSceneBounds?) -> ViewerSceneBounds? {
        guard let bounds,
              bounds.radius.isFinite,
              bounds.radius > 0,
              bounds.center.x.isFinite,
              bounds.center.y.isFinite,
              bounds.center.z.isFinite else {
            return nil
        }
        return ViewerSceneBounds(
            center: SIMD3<Float>(
                Float(bounds.center.x),
                Float(bounds.center.y),
                Float(bounds.center.z)
            ),
            radius: Float(bounds.radius)
        )
    }

    /// The preview trails the model by design — republished every several seconds,
    /// thinned to stay cheap. Saying so is cheaper than being asked why it and the
    /// finished splat differ. Names no iteration: the guide keeps trainer counters
    /// out of product UI, and the number would only invite the wrong comparison.
    nonisolated static let previewCaption = "Preview · approximate, still training"

    enum PhaseRailState: Equatable {
        case completed
        case current
        case pending
    }

    nonisolated static func railState(
        of phase: ProcessingPhase,
        current: ProcessingPhase
    ) -> PhaseRailState {
        if phase.rawValue < current.rawValue { return .completed }
        if phase == current { return .current }
        return .pending
    }

    private var phaseRail: some View {
        HStack(spacing: Theme.Spacing.large) {
            ForEach(ProcessingPhase.allPhases, id: \.rawValue) { railPhase in
                railEntry(railPhase, state: Self.railState(of: railPhase, current: phase))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.heading)
        .accessibilityIdentifier("processing.phaseRail")
    }

    private func railEntry(_ railPhase: ProcessingPhase, state: PhaseRailState) -> some View {
        HStack(spacing: Theme.Spacing.small / 2) {
            Image(systemName: Self.railSymbolName(for: state))
                .font(.caption)
                .foregroundStyle(state == .current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            Text(railPhase.railLabel)
                .font(.subheadline.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }

    nonisolated static func railSymbolName(for state: PhaseRailState) -> String {
        switch state {
        case .completed: return "checkmark.circle.fill"
        case .current: return "circle.fill"
        case .pending: return "circle"
        }
    }

    private var contextLine: String? {
        Self.contextLine(
            projectTitle: projectTitle,
            inputSummary: model.currentInput?.displaySummary
        )
    }

    nonisolated static func contextLine(projectTitle: String?, inputSummary: String?) -> String? {
        switch (projectTitle, inputSummary) {
        case let (.some(title), .some(input)):
            return "\(title) — \(input)"
        case let (.some(title), nil):
            return title
        case let (nil, .some(input)):
            return input
        case (nil, nil):
            return nil
        }
    }

    private var projectTitle: String? {
        guard let projectURL = model.currentProjectURL else { return nil }
        if let summary = model.projectSummaries.first(where: {
            ProjectSummary.hasSameLocation($0.url, projectURL)
        }) {
            return summary.title
        }
        return projectURL.deletingPathExtension().lastPathComponent
    }

    private var durationExpectation: String? {
        // The predictor describes full create-to-viewer time; resumes and
        // retrains skip stages, so the estimate would mislead there.
        guard model.currentRunOrigin == .fresh, let input = model.currentInput else { return nil }
        let options = model.currentRunOptions ?? model.requestedRunOptions
        return RunDurationPredictor.predict(
            options: options,
            input: input,
            from: model.projectSummaries,
            excluding: model.currentProjectURL
        )?.displayText
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
                    .progressViewStyle(.linear)
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

            if let expectation = durationExpectation {
                Text(expectation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("processing.expectation")
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
                if model.hasValidatedPreviousResult {
                    Text(Self.previousResultAvailableMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "processing.previousResultAvailable"
                        )
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                if model.hasValidatedPreviousResult,
                   let projectURL = model.currentProjectURL {
                    Button("View Previous Result") {
                        _ = model.viewPreviousResult(at: projectURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isStopping || model.isRunActive)
                    .accessibilityIdentifier("processing.viewPreviousResult")
                }
                if model.failureRetryAllowed {
                    if model.hasValidatedPreviousResult {
                        failureRetryButton
                    } else {
                        failureRetryButton
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
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

    private var failureRetryButton: some View {
        Button(Self.failureActionTitle(recovery: model.validationRecovery)) {
            model.retryAfterFailure()
        }
        .disabled(!canTryAgain || model.isStopping || model.isRunActive)
        .accessibilityIdentifier("processing.tryAgain")
    }

    private var technicalDetails: some View {
        DisclosureSection(isExpanded: $isTechnicalDetailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Stage", value: model.stage?.displayName ?? "Preparing")
                    .font(.caption)

                if !model.statusTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model.statusTitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                AutoScrollingLog(text: technicalText)

                HStack {
                    Spacer()
                    Button("Copy Details") {
                        // Copies the full log, not just the rendered tail.
                        model.copyTechnicalDetails(model.errorDetailsText ?? technicalText)
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
            pendingInputExists: !model.pendingVideoURLs.isEmpty
                || !model.pendingPhotoURLs.isEmpty
                || model.pendingDataset != nil
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

    nonisolated static let previousResultAvailableMessage =
        "Your previous splat is still available."

    nonisolated static func phaseProgress(stage: PipelineStage?, progress: Double?) -> Double? {
        guard let progress, let stage else { return nil }
        switch stage {
        case .trainSplat, .exportSplat, .done:
            return progress
        case .importInput, .extractFrames, .selectFrames, .sfmFeatures, .sfmMatching, .sfmMapping:
            return nil
        }
    }

    nonisolated static func isPinnedToBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        // Content shorter than the viewport is always "at the bottom".
        let maxOffset = max(0, contentHeight - containerHeight)
        return contentOffsetY >= maxOffset - tolerance
    }

    /// The live pane renders a bounded tail; the full forensic dump only
    /// renders once a run has failed and the text has stopped growing.
    private var technicalText: String {
        let text = model.lastError != nil ? model.errorDetailsText : model.processingDetailsText
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

/// A scrolling log that follows the newest line, but releases and lets the user
/// read history the moment they scroll up — re-following once they return to the bottom.
private struct AutoScrollingLog: View {
    let text: String
    var maxHeight: CGFloat = 260

    @State private var isPinnedToBottom = true
    @State private var lastContentHeight: CGFloat = 0

    private static let bottomAnchorID = "technicalDetailsBottom"
    private static let bottomTolerance: CGFloat = 24   // ~1.5 caption lines of slack

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 0).id(Self.bottomAnchorID)
                }
            }
            .frame(maxHeight: maxHeight)
            .onScrollGeometryChange(for: Sample.self) { geometry in
                Sample(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            } action: { _, sample in
                if sample.contentHeight != lastContentHeight {
                    // The log grew or shrank — honor the existing pin; follow only if pinned.
                    if isPinnedToBottom {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                } else {
                    // A pure scroll — the user's position decides whether we keep following.
                    isPinnedToBottom = ProcessingView.isPinnedToBottom(
                        contentOffsetY: sample.offsetY,
                        contentHeight: sample.contentHeight,
                        containerHeight: sample.containerHeight,
                        tolerance: Self.bottomTolerance
                    )
                }
                lastContentHeight = sample.contentHeight
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
        }
    }

    private struct Sample: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }
}
