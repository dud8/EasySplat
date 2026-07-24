import AppKit
import EasySplatCore
import SwiftUI
import UniformTypeIdentifiers

struct ViewerView: View {
    let onNewSplat: () -> Void

    @EnvironmentObject private var model: AppModel
    @StateObject private var artifactLoader = ViewerArtifactLoader<ProjectArtifactSnapshot>()
    @AppStorage(ViewerView.inspectorPreferenceKey) private var storedInspectorPreference: Bool?
    @State private var hasResolvedInitialInspector = false
    @State private var isTechnicalExpanded = false
    @State private var resetCameraToken = 0
    @State private var artifactSnapshot: ProjectArtifactSnapshot?
    @State private var loadedMetadataProjectURL: URL?
    @State private var artifactLoadError: String?
    @State private var viewerAlert: ViewerAlert?
    @State private var isExporting = false
    @State private var isUprightHintDismissed = false
    @State private var isPartialCoverageHintDismissed = false
    @State private var isRetrainSheetPresented = false
    @State private var isRemoveSubjectConfirmationPresented = false
    @State private var retrainProfile: DetailProfile = .balanced

    var body: some View {
        Group {
            if let plyURL = model.displayedOutputURL,
               let projectURL = model.currentProjectURL {
                if let artifactLoadError {
                    ContentUnavailableView(
                        "Splat unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(artifactLoadError)
                    )
                } else if loadedMetadataProjectURL == model.currentProjectURL?.standardizedFileURL,
                          artifactSnapshot != nil {
                    SplatViewerView(
                        splatURL: plyURL,
                        resetCameraToken: resetCameraToken,
                        sceneConfiguration: viewerSceneConfiguration,
                        onLoadStateChanged: { state in
                            guard state == .ready,
                                  model.selectedSplatOutputVariant == .original else {
                                return
                            }
                            model.resultViewerDidBecomeReady(
                                projectURL: projectURL,
                                outputURL: plyURL
                            )
                        },
                        overlayDensity: .compact
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: Theme.Spacing.small) {
                            partialCoverageHint
                            uprightHint
                            subjectIsolationStatusRow
                        }
                        .padding(.bottom, Theme.Spacing.extraLarge)
                    }
                } else {
                    ProgressView("Opening splat…")
                }
            } else {
                ContentUnavailableView(
                    "Splat unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The finished output could not be opened.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(projectTitle)
        .toolbar { resultToolbar }
        .inspector(isPresented: inspectorPresentation) {
            resultInspector
                .inspectorColumnWidth(min: 240, ideal: Self.inspectorIdealWidth, max: 360)
        }
        .alert(item: $viewerAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $isRetrainSheetPresented) { retrainSheet }
        .sheet(isPresented: subjectChoicePresentation) {
            if let request = model.subjectChoiceRequest {
                SubjectChoiceSheet(
                    request: request,
                    onCancel: dismissSubjectChoice,
                    onIsolate: { anchor in
                        _ = model.retrySubjectIsolation(anchor: anchor)
                    }
                )
            }
        }
        .confirmationDialog(
            "Remove Subject Version?",
            isPresented: $isRemoveSubjectConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Subject Version", role: .destructive) {
                Task {
                    _ = await model.removeSubjectVersion()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the isolated version. The original remains unchanged.")
        }
        .onAppear {
            resolveInitialInspectorIfNeeded(workspaceWidth: model.workspaceWidthHint)
            requestArtifactLoad()
        }
        .onChange(of: model.currentProjectURL) { _, _ in
            isUprightHintDismissed = false
            isPartialCoverageHintDismissed = false
            requestArtifactLoad()
        }
        .onChange(of: model.outputPlyURL) { _, _ in requestArtifactLoad() }
        .onChange(of: model.exportMenuRequestCount) { _, _ in presentExportPanel() }
        .onDisappear { artifactLoader.cancel() }
    }

    @ToolbarContentBuilder
    private var resultToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if Self.availableOutputVariants(
                hasSubjectOutput: model.subjectOutput != nil
            ).count > 1 {
                Picker(
                    "Splat version",
                    selection: Binding(
                        get: { model.selectedSplatOutputVariant },
                        set: { _ = model.setSelectedSplatOutputVariant($0) }
                    )
                ) {
                    Text("Original").tag(SplatOutputVariant.original)
                    Text("Subject").tag(SplatOutputVariant.subject)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Splat version")
                .accessibilityIdentifier("result.outputVariant")
            }

            Button(action: presentExportPanel) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Exporting splat")
                } else {
                    Label("Export…", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(model.displayedOutputURL == nil || isExporting)
            .help("Save a copy of the validated PLY")
            .accessibilityIdentifier("result.export")

            ShareToolbarButton(
                isEnabled: model.displayedOutputURL != nil
                    && !model.isPreparingShare
                    && !model.isShareSheetActive
            ) { sourceView in
                model.requestCurrentSplatShare(from: sourceView)
            }

            if model.isPreparingShare {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing splat for sharing")
                    .accessibilityIdentifier("result.shareProgress")
            }

            Button {
                inspectorPresentation.wrappedValue.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(model.isResultInspectorPresented ? "Hide Inspector" : "Show Inspector")
            .accessibilityIdentifier("result.inspector")

            Menu {
                Button("Show in Finder", systemImage: "folder") {
                    revealOutputInFinder()
                }
                .disabled(model.displayedOutputURL == nil)

                Button("Reset View", systemImage: "arrow.counterclockwise") {
                    resetCameraToken &+= 1
                }
                .disabled(model.displayedOutputURL == nil)

                if Self.offersUprightFlip(for: artifactSnapshot?.geometryArtifact) {
                    Toggle(
                        "Flip Upright",
                        isOn: Binding(
                            get: { artifactSnapshot?.viewerPreferences.isUprightFlipActive == true },
                            set: { isActive in updateUprightFlip(isActive) }
                        )
                    )
                    .help("Changes only this view; the exported PLY stays unchanged")
                    .accessibilityHint("Changes only the viewer. The exported PLY is unchanged.")
                }

                Divider()

                Button(
                    model.subjectOutput == nil
                        ? "Isolate Subject"
                        : "Isolate Again",
                    systemImage: "person.crop.rectangle"
                ) {
                    _ = model.startSubjectIsolation()
                }
                .disabled(model.hasActiveWork)
                .accessibilityIdentifier("result.isolateSubject")

                if model.subjectOutput != nil {
                    Button(
                        "Remove Subject Version…",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        isRemoveSubjectConfirmationPresented = true
                    }
                    .disabled(model.hasActiveWork)
                    .accessibilityIdentifier("result.removeSubject")
                }

                Button("Re-train…", systemImage: "arrow.clockwise.square") {
                    retrainProfile = artifactSnapshot?.metadata.requestedRunOptions
                        .detailProfile ?? .balanced
                    isRetrainSheetPresented = true
                }
                .disabled(model.currentProjectURL == nil || model.hasActiveWork)
                .accessibilityIdentifier("result.retrain")

                Divider()

                Button("New Splat", systemImage: "plus") {
                    onNewSplat()
                }
                .accessibilityIdentifier("result.newSplat")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More result actions")
        }
    }

    private var retrainSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Re-train")
                .font(.headline)
            Picker("Detail", selection: $retrainProfile) {
                Text("Fast").tag(DetailProfile.fast)
                Text("Balanced")
                    .tag(DetailProfile.balanced)
                    .disabled(!RunPlanResolver.supports(
                        detail: .balanced,
                        memoryGB: model.hardwareProfile.memoryGB
                    ))
                Text("High Detail")
                    .tag(DetailProfile.highDetail)
                    .disabled(!RunPlanResolver.supports(
                        detail: .highDetail,
                        memoryGB: model.hardwareProfile.memoryGB
                    ))
            }
            .accessibilityIdentifier("result.retrainDetail")
            Text("The current splat is replaced when the new one finishes. Processing re-runs as needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    isRetrainSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Re-train") {
                    isRetrainSheetPresented = false
                    if let projectURL = model.currentProjectURL {
                        model.retrainProject(at: projectURL, profile: retrainProfile)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("result.retrainConfirm")
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 320)
    }

    @ViewBuilder
    private var uprightHint: some View {
        if !isUprightHintDismissed,
           artifactSnapshot?.geometryArtifact?.canonicalOrientation.status == .unresolved {
            HStack(spacing: Theme.Spacing.small) {
                Text("If this splat looks upside down, use Flip Upright in the More menu.")
                    .font(.caption)
                Button {
                    isUprightHintDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss orientation hint")
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
            .accessibilityIdentifier("result.uprightHint")
        }
    }

    private var partialCoverage: (registered: Int, total: Int, separateGroupViewCount: Int)? {
        guard let geometry = artifactSnapshot?.geometryArtifact else { return nil }
        return Self.partialCoverageSummary(
            registeredViewCount: geometry.registeredViewCount,
            totalViewCount: geometry.totalViewCount,
            builtFromPartialAcceptance: geometry.usedPartialCoverageAcceptance,
            componentViewCounts: geometry.pairGraph.measurement?.componentViewCounts
        )
    }

    @ViewBuilder
    private var partialCoverageHint: some View {
        if !isPartialCoverageHintDismissed, let coverage = partialCoverage {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                Text(Self.partialCoverageMessage(coverage))
                    .font(.caption)
                Button {
                    isPartialCoverageHintDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss coverage warning")
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
            .accessibilityIdentifier("result.partialCoverageHint")
        }
    }

    @ViewBuilder
    private var subjectIsolationStatusRow: some View {
        if model.isSubjectIsolationActive {
            HStack(spacing: Theme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Isolating subject…")
                    .font(.caption)
                Button("Cancel") {
                    model.cancelSubjectIsolation()
                }
                .controlSize(.small)
                .accessibilityLabel("Cancel subject isolation")
            }
            .shadow(color: .black.opacity(0.6), radius: 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("result.subjectIsolationProgress")
        } else if let message = model.subjectIsolationStatusMessage,
                  message == "No clear subject to isolate. The original is unchanged."
                    || model.subjectIsolationStatusIsError {
            HStack(spacing: Theme.Spacing.small) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        model.subjectIsolationStatusIsError
                            ? Color.red
                            : Color.primary
                    )
                Button {
                    model.subjectIsolationStatusMessage = nil
                    model.subjectIsolationStatusIsError = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss subject isolation status")
            }
            .shadow(color: .black.opacity(0.6), radius: 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("result.subjectIsolationStatus")
        }
    }

    /// Present only when the splat was built from part of the capture, keyed
    /// off the persisted acceptance state (dominant-group continuation or a
    /// partial camera solve) rather than a registration fraction so
    /// near-threshold continuations still warn.
    static func partialCoverageSummary(
        registeredViewCount: Int,
        totalViewCount: Int,
        builtFromPartialAcceptance: Bool,
        componentViewCounts: [Int]?
    ) -> (registered: Int, total: Int, separateGroupViewCount: Int)? {
        guard builtFromPartialAcceptance,
              totalViewCount > 0,
              registeredViewCount > 0,
              registeredViewCount <= totalViewCount else {
            return nil
        }
        let separateGroup = componentViewCounts?.dropFirst().first ?? 0
        return (registeredViewCount, totalViewCount, separateGroup > 1 ? separateGroup : 0)
    }

    static func partialCoverageMessage(
        _ coverage: (registered: Int, total: Int, separateGroupViewCount: Int)
    ) -> String {
        if coverage.separateGroupViewCount > 1 {
            return "This splat covers \(coverage.registered) of \(coverage.total) photos. A separate group of \(coverage.separateGroupViewCount) photos couldn't be connected to it. Add photos that bridge the two areas, then use Re-train in the More menu."
        }
        return "This splat covers \(coverage.registered) of \(coverage.total) photos. To include the rest, add photos that overlap the missing areas, then use Re-train in the More menu."
    }

    private var resultInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                outputSection
                Divider()
                captureSection
                Divider()
                reconstructionSection
                Divider()
                timingSection
                Divider()
                notesSection
                Divider()
                technicalSection
            }
            .padding(Theme.Spacing.large)
        }
        .accessibilityIdentifier("result.inspectorContent")
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Output")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let outputURL = model.displayedOutputURL {
                LabeledContent("File") {
                    Text(outputURL.lastPathComponent)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(outputURL.lastPathComponent)
                }
            }
            if let info = model.displayedOutputPlyInfo {
                LabeledContent(
                    "Contents",
                    value: info.vertexCount == 1 ? "1 splat" : info.splatCountText
                )
                if let size = info.sizeText {
                    LabeledContent("Size", value: size)
                }
            }
            if let bounds = displayedSceneBounds {
                LabeledContent("Center") {
                    Text(
                        "\(bounds.center.x.formatted(.number.precision(.fractionLength(0...3)))), "
                            + "\(bounds.center.y.formatted(.number.precision(.fractionLength(0...3)))), "
                            + "\(bounds.center.z.formatted(.number.precision(.fractionLength(0...3))))"
                    )
                }
                LabeledContent(
                    "Radius",
                    value: bounds.radius.formatted(
                        .number.precision(.fractionLength(0...3))
                    )
                )
            }
            if let status = model.shareStatusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.shareStatusIsError ? Color.red : Color.secondary)
                    .accessibilityLabel("Share status: \(status)")
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Capture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let input = model.currentInput {
                LabeledContent("Input", value: input.displaySummary)
            }
            let options = displayedRunOptions
            LabeledContent("Path", value: capturePathLabel(options.capturePath))
            LabeledContent("Detail", value: detailLabel(options.detailProfile))
            if options.cameraGrouping != .automatic {
                LabeledContent("Camera", value: cameraLabel(options.cameraGrouping))
            }
            if options.lensProjection != .automatic {
                LabeledContent("Lens", value: lensLabel(options.lensProjection))
            }
            if options.inputOrdering != .automatic {
                LabeledContent("Order", value: orderLabel(options.inputOrdering))
            }
            if options.resourcePolicy != .automatic {
                LabeledContent("Resources", value: resourceLabel(options.resourcePolicy))
            }
            if Self.inputContainsPhotos(model.currentInput), options.photoSelection == .useAllValidPhotos {
                LabeledContent("Photos", value: "All valid photos")
            }
        }
    }

    @ViewBuilder
    private var reconstructionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Reconstruction")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let geometry = artifactSnapshot?.geometryArtifact {
                LabeledContent("Registered") {
                    HStack(spacing: Theme.Spacing.small) {
                        if partialCoverage != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Built from part of the capture")
                        }
                        Text("\(geometry.registeredViewCount) of \(geometry.totalViewCount)")
                    }
                }
                LabeledContent("Points", value: geometry.pointCount.formatted())
                LabeledContent("Observations", value: geometry.observationCount.formatted())
                LabeledContent(
                    "Median residual",
                    value: geometry.medianPixelResidual.formatted(.number.precision(.fractionLength(2))) + " px"
                )
                LabeledContent(
                    "P90 residual",
                    value: geometry.p90PixelResidual.formatted(.number.precision(.fractionLength(2))) + " px"
                )
            } else {
                Text("No reconstruction measurements were recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Timing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let total = Self.totalDurationSeconds(
                createToViewerReadySeconds: model.currentCreateToViewerReadySeconds,
                stageTimings: model.currentStageTimings
            ) {
                LabeledContent("Total", value: StageTimingDisplay.formatDuration(seconds: total))
            }
            timingRow("Prepare", stages: [.importInput, .extractFrames, .selectFrames])
            timingRow("Reconstruct", stages: [.sfmFeatures, .sfmMatching, .sfmMapping])
            timingRow("Train", stages: [.trainSplat])
            timingRow("Finish", stages: [.exportSplat, .done])
            if Self.totalDurationSeconds(
                createToViewerReadySeconds: model.currentCreateToViewerReadySeconds,
                stageTimings: model.currentStageTimings
            ) == nil {
                Text("No timing measurements were recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Notes")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextEditor(text: Binding(
                get: { model.currentProjectNotes },
                set: { newValue in
                    model.currentProjectNotes = newValue
                    if let projectURL = model.currentProjectURL {
                        model.scheduleNotesSave(at: projectURL, to: newValue)
                    }
                }
            ))
            .font(.body)
            .textEditorStyle(.plain)
            .frame(minHeight: 90)
            .padding(Theme.Spacing.small)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                    .stroke(Theme.border)
            }
            .accessibilityLabel("Project notes")
            .accessibilityIdentifier("result.notes")
            notesSaveStatus
        }
    }

    @ViewBuilder
    private var notesSaveStatus: some View {
        switch model.notesSaveState {
        case .idle:
            EmptyView()
        case .saving:
            Text("Saving…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Notes status: Saving")
        case .saved:
            Text("Saved")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Notes status: Saved")
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Notes status: \(message)")
        }
    }

    private var technicalSection: some View {
        DisclosureGroup(isExpanded: $isTechnicalExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if let geometry = artifactSnapshot?.geometryArtifact {
                    LabeledContent("Solver", value: geometry.solverVersion)
                    LabeledContent("Model", value: geometry.modelVersion)
                    LabeledContent("Camera", value: geometry.cameraModel)
                    LabeledContent("Residuals", value: geometry.residualProvenance)
                    if geometry.canonicalOrientation.status == .unresolved {
                        LabeledContent("Upright", value: "Not determined")
                    }
                }
                if let trainer = artifactSnapshot?.trainingArtifact {
                    LabeledContent("Trainer", value: trainer.trainerVersion)
                    LabeledContent("Iterations", value: trainer.completedIteration.formatted())
                }
                if let format = model.displayedOutputPlyInfo?.formatLabel {
                    LabeledContent("Format", value: format)
                }
                if let relativePath = displayedProjectRelativePath {
                    LabeledContent("Project path") {
                        Text(relativePath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(relativePath)
                    }
                }
            }
            .padding(.top, Theme.Spacing.small)
        } label: {
            Text("Technical")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func timingRow(_ label: String, stages: [PipelineStage]) -> some View {
        if let duration = duration(for: stages) {
            LabeledContent(label, value: StageTimingDisplay.formatDuration(seconds: duration))
        }
    }

    private func duration(for stages: [PipelineStage]) -> TimeInterval? {
        let matching = model.currentStageTimings.filter { stages.contains($0.stage) }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.durationSeconds }
    }

    nonisolated static func totalDurationSeconds(
        createToViewerReadySeconds: TimeInterval?,
        stageTimings: [StageTimingRecord]
    ) -> TimeInterval? {
        createToViewerReadySeconds ?? stageTimings.totalDurationSeconds
    }

    private var displayedRunOptions: RequestedRunOptions {
        artifactSnapshot?.metadata.requestedRunOptions
            ?? model.currentRunOptions
            ?? RequestedRunOptions()
    }

    private var projectTitle: String {
        if let projectURL = model.currentProjectURL,
           let summary = model.projectSummaries.first(where: {
               ProjectSummary.hasSameLocation($0.url, projectURL)
           }) {
            return summary.title
        }
        if let title = artifactSnapshot?.metadata.title, !title.isEmpty { return title }
        guard let projectURL = model.currentProjectURL else { return "Result" }
        return projectURL.deletingPathExtension().lastPathComponent
    }

    private func requestArtifactLoad(
        preservingCurrentSnapshot: Bool = false,
        failurePresentation: ArtifactLoadFailurePresentation = .workspace
    ) {
        guard let projectURL = model.currentProjectURL,
              let outputURL = model.outputPlyURL else {
            artifactLoader.cancel()
            artifactSnapshot = nil
            loadedMetadataProjectURL = nil
            artifactLoadError = nil
            return
        }

        if !preservingCurrentSnapshot {
            artifactSnapshot = nil
            loadedMetadataProjectURL = nil
            artifactLoadError = nil
            viewerAlert = nil
        }

        let request = ViewerArtifactLoadRequest(
            projectURL: projectURL,
            outputURL: outputURL
        )
        artifactLoader.load(
            request,
            operation: { projectURL in
                try ProjectArtifactSnapshotStore.load(projectURL: projectURL)
            }
        ) { request, outcome in
            guard ProjectSummary.hasSameLocation(model.currentProjectURL, request.projectURL),
                  ProjectSummary.hasSameLocation(model.outputPlyURL, request.outputURL) else {
                return
            }

            switch outcome {
            case .success(let snapshot):
                artifactSnapshot = snapshot
                loadedMetadataProjectURL = request.projectURL
                artifactLoadError = nil
            case .failure(let message):
                if failurePresentation == .alert {
                    viewerAlert = ViewerAlert(
                        title: "Couldn’t update view",
                        message: message
                    )
                } else {
                    artifactSnapshot = nil
                    loadedMetadataProjectURL = nil
                    artifactLoadError = "The project artifacts could not be verified."
                }
            }
        }
    }

    private func presentExportPanel() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            let source: AppModel.CurrentSplatPublicationSource
            do {
                source = try await model.validatedCurrentSplatForPublication()
            } catch is CancellationError {
                isExporting = false
                return
            } catch {
                isExporting = false
                viewerAlert = ViewerAlert(
                    title: "Couldn’t export splat",
                    message: error.localizedDescription
                )
                return
            }

            guard let plyType = UTType(filenameExtension: "ply") else {
                isExporting = false
                viewerAlert = ViewerAlert(
                    title: "Couldn’t export splat",
                    message: "PLY export is unavailable on this Mac."
                )
                return
            }

            let panel = NSSavePanel()
            panel.title = "Export Splat"
            panel.prompt = "Export"
            panel.nameFieldStringValue = source.defaultFilename
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.allowsOtherFileTypes = false
            panel.allowedContentTypes = [plyType]
            panel.begin { response in
                guard response == .OK, let destination = panel.url else {
                    isExporting = false
                    return
                }
                Task { @MainActor in
                    defer { isExporting = false }
                    do {
                        try await model.exportCurrentSplat(
                            source,
                            to: destination
                        )
                    } catch {
                        viewerAlert = ViewerAlert(
                            title: "Couldn’t export splat",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func revealOutputInFinder() {
        Task { @MainActor in
            guard let source = try? await model
                .validatedCurrentSplatForPublication() else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([source.outputURL])
        }
    }

    private var viewerSceneConfiguration: SplatViewerSceneConfiguration {
        let storedBounds = displayedSceneBounds
        let bounds = storedBounds.map { stored in
            let center = SIMD3<Float>(
                Float(stored.center.x),
                Float(stored.center.y),
                Float(stored.center.z)
            )
            let radius = Float(stored.radius)
            return ViewerSceneBounds(center: center, radius: radius)
        }
        let storedDirection = artifactSnapshot?.geometryArtifact?
            .canonicalOrientation.canonicalOpeningViewDirection
        let openingDirection = storedDirection.map {
            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
        }
        let canFlip = artifactSnapshot?.geometryArtifact?.allowsViewOnlyUprightFlip == true
        return SplatViewerSceneConfiguration(
            bounds: bounds,
            openingDirection: openingDirection,
            isViewOnlyFlipActive: canFlip
                && artifactSnapshot?.viewerPreferences.isUprightFlipActive == true
        )
    }

    private var displayedSceneBounds: SplatSceneBounds? {
        model.displayedOutputSceneBounds
            ?? artifactSnapshot?.trainingArtifact?.sceneBounds
    }

    private var displayedProjectRelativePath: String? {
        if model.selectedSplatOutputVariant == .subject,
           let output = model.subjectOutput?.url {
            return "Output/\(output.lastPathComponent)"
        }
        return artifactSnapshot?.trainingArtifact?.outputPath
    }

    private var subjectChoicePresentation: Binding<Bool> {
        Binding(
            get: { model.subjectChoiceRequest != nil },
            set: { isPresented in
                if !isPresented {
                    dismissSubjectChoice()
                }
            }
        )
    }

    private func dismissSubjectChoice() {
        model.subjectChoiceRequest = nil
        model.subjectIsolationStatusMessage = nil
        model.subjectIsolationStatusIsError = false
    }

    private func updateUprightFlip(_ isActive: Bool) {
        guard let projectURL = model.currentProjectURL else { return }
        do {
            _ = try ProjectMetadataStore.update(
                at: ProjectPaths(root: projectURL).metadataURL
            ) { metadata in
                metadata.viewerPreferences.isUprightFlipActive = isActive
            }
            requestArtifactLoad(
                preservingCurrentSnapshot: true,
                failurePresentation: .alert
            )
        } catch {
            viewerAlert = ViewerAlert(
                title: "Couldn’t update view",
                message: error.localizedDescription
            )
        }
    }

    /// Closed until the seed has run so the panel never flashes. Changes made
    /// while the result is on screen are the user's and are remembered;
    /// pre-seed and teardown writes are not.
    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { hasResolvedInitialInspector && model.isResultInspectorPresented },
            set: { newValue in
                model.isResultInspectorPresented = newValue
                if hasResolvedInitialInspector, model.viewState == .viewer {
                    storedInspectorPreference = newValue
                }
            }
        )
    }

    private func resolveInitialInspectorIfNeeded(workspaceWidth: CGFloat) {
        guard !hasResolvedInitialInspector else { return }
        model.isResultInspectorPresented = Self.initialInspectorPresentation(
            storedPreference: storedInspectorPreference,
            workspaceWidth: workspaceWidth
        )
        hasResolvedInitialInspector = true
    }

    nonisolated static let inspectorPreferenceKey = "EasySplatResultInspectorShown"
    nonisolated static let inspectorIdealWidth: CGFloat = 280
    nonisolated static let minimumComfortableCanvasWidth: CGFloat = 440

    nonisolated static func availableOutputVariants(
        hasSubjectOutput: Bool
    ) -> [SplatOutputVariant] {
        hasSubjectOutput ? [.original, .subject] : [.original]
    }

    /// The inspector opens by default only when it leaves the canvas a useful
    /// share of the workspace. A remembered explicit choice always wins.
    nonisolated static func initialInspectorPresentation(
        storedPreference: Bool?,
        workspaceWidth: CGFloat
    ) -> Bool {
        if let storedPreference { return storedPreference }
        return workspaceWidth - inspectorIdealWidth >= minimumComfortableCanvasWidth
    }

    nonisolated static func inputContainsPhotos(_ input: InputSpec?) -> Bool {
        switch input {
        case .photos, .mixed:
            return true
        case .video, nil:
            return false
        }
    }

    nonisolated static func offersUprightFlip(
        for artifact: GeometryArtifact?
    ) -> Bool {
        artifact?.allowsViewOnlyUprightFlip == true
    }

    private func capturePathLabel(_ path: CapturePath) -> String {
        switch path {
        case .automatic: "Automatic"
        case .orbit: "Around a subject"
        case .walkthrough: "Through a space"
        case .largeArea: "Across a large area"
        }
    }

    private func detailLabel(_ detail: DetailProfile) -> String {
        switch detail {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .highDetail: "High Detail"
        }
    }

    private func cameraLabel(_ camera: CameraGrouping) -> String {
        switch camera {
        case .automatic: "Automatic"
        case .sameCameraAndLens: "Same camera and lens"
        case .mixedCamerasOrLenses: "Mixed cameras or lenses"
        }
    }

    private func lensLabel(_ lens: LensProjection) -> String {
        switch lens {
        case .automatic: "Automatic"
        case .perspective: "Perspective"
        case .fisheye: "Fisheye"
        }
    }

    private func orderLabel(_ order: InputOrdering) -> String {
        switch order {
        case .automatic: "Automatic"
        case .continuous: "Continuous sequence"
        case .unordered: "Unordered"
        }
    }

    private func resourceLabel(_ resource: ResourcePolicy) -> String {
        switch resource {
        case .automatic: "Automatic"
        case .conserveMemory: "Conserve Memory"
        case .maximumPerformance: "Maximum Performance"
        }
    }
}

private struct ViewerAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum ArtifactLoadFailurePresentation {
    case workspace
    case alert
}
