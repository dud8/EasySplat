import AppKit
import EasySplatCore
import SwiftUI
import UniformTypeIdentifiers

struct ViewerView: View {
    let onNewSplat: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var isInspectorPresented = true
    @State private var isTechnicalExpanded = false
    @State private var resetCameraToken = 0
    @State private var metadata: ProjectMetadata?
    @State private var loadedMetadataProjectURL: URL?
    @State private var viewerAlert: ViewerAlert?
    @State private var isExporting = false

    var body: some View {
        Group {
            if let plyURL = model.outputPlyURL {
                if loadedMetadataProjectURL == model.currentProjectURL?.standardizedFileURL {
                    SplatViewerView(
                        splatURL: plyURL,
                        resetCameraToken: resetCameraToken,
                        sceneConfiguration: viewerSceneConfiguration,
                        overlayDensity: .compact
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Theme.Spacing.large)
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
        .inspector(isPresented: $isInspectorPresented) {
            resultInspector
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .alert(item: $viewerAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear(perform: loadMetadata)
        .onChange(of: model.currentProjectURL) { _, _ in loadMetadata() }
        .task(id: model.outputPlyURL) {
            guard model.outputPlyURL != nil else { return }
            await model.prepareCurrentSplatForSharing()
        }
    }

    @ToolbarContentBuilder
    private var resultToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: presentExportPanel) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Exporting splat")
                } else {
                    Label("Export…", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(model.outputPlyURL == nil || isExporting)
            .help("Save a copy of the validated PLY")
            .accessibilityIdentifier("result.export")

            ShareToolbarButton(
                isEnabled: model.outputPlyURL != nil
                    && model.isShareReady
                    && !model.isShareSheetActive
            ) { sourceView in
                model.presentPreparedShare(from: sourceView)
            }

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            .accessibilityIdentifier("result.inspector")

            Menu {
                Button("Show in Finder", systemImage: "folder") {
                    revealOutputInFinder()
                }
                .disabled(model.outputPlyURL == nil)

                Button("Reset View", systemImage: "arrow.counterclockwise") {
                    resetCameraToken &+= 1
                }
                .disabled(model.outputPlyURL == nil)

                if Self.offersUprightFlip(for: metadata?.geometryArtifact) {
                    Toggle(
                        "Flip Upright",
                        isOn: Binding(
                            get: { metadata?.viewerPreferences.isUprightFlipActive == true },
                            set: { isActive in updateUprightFlip(isActive) }
                        )
                    )
                    .help("Changes only this view; the exported PLY stays unchanged")
                    .accessibilityHint("Changes only the viewer. The exported PLY is unchanged.")
                }

                Button("View Releases…", systemImage: "arrow.triangle.2.circlepath") {
                    let releases = AppConfig.projectHomeURL
                        .appendingPathComponent("releases", isDirectory: true)
                    NSWorkspace.shared.open(releases)
                }

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
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Output")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let outputURL = model.outputPlyURL {
                LabeledContent("File") {
                    Text(outputURL.lastPathComponent)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(outputURL.lastPathComponent)
                }
            }
            if let info = model.currentOutputPlyInfo {
                LabeledContent(
                    "Contents",
                    value: info.vertexCount == 1 ? "1 splat" : info.splatCountText
                )
                if let size = info.sizeText {
                    LabeledContent("Size", value: size)
                }
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
                LabeledContent("Input", value: inputDescription(input))
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
            if let geometry = metadata?.geometryArtifact {
                LabeledContent(
                    "Registered",
                    value: "\(geometry.registeredViewCount) of \(geometry.totalViewCount)"
                )
                LabeledContent("Points", value: geometry.pointCount.formatted())
                LabeledContent("Observations", value: geometry.trackCount.formatted())
                LabeledContent(
                    "Median residual",
                    value: geometry.medianPixelResidual.formatted(.number.precision(.fractionLength(2))) + " px"
                )
                LabeledContent(
                    "P90 residual",
                    value: geometry.p90PixelResidual.formatted(.number.precision(.fractionLength(2))) + " px"
                )
            } else if let summary = model.currentReconstruction {
                LabeledContent(
                    "Registered",
                    value: "\(summary.registeredImages) of \(summary.totalImages)"
                )
                if let points = summary.pointCountText {
                    LabeledContent("Points", value: points)
                }
                if let observations = summary.observationCountText {
                    LabeledContent("Observations", value: observations)
                }
                if let trackLength = summary.meanTrackLengthText {
                    LabeledContent("Track length", value: trackLength)
                }
                if let residual = summary.meanReprojectionErrorText {
                    LabeledContent("Mean residual", value: residual)
                }
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
            if let total = model.currentStageTimings.totalDurationSeconds {
                LabeledContent("Total", value: StageTimingDisplay.formatDuration(seconds: total))
            }
            timingRow("Prepare", stages: [.importInput, .extractFrames, .selectFrames])
            timingRow("Reconstruct", stages: [.sfmFeatures, .sfmMatching, .sfmMapping])
            timingRow("Train", stages: [.trainSplat])
            timingRow("Finish", stages: [.exportSplat, .done])
            if model.currentStageTimings.isEmpty {
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
                if let geometry = metadata?.geometryArtifact {
                    LabeledContent("Solver", value: geometry.solverVersion)
                    LabeledContent("Model", value: geometry.modelVersion)
                    LabeledContent("Camera", value: geometry.cameraModel)
                    LabeledContent("Residuals", value: geometry.residualProvenance)
                    if geometry.canonicalOrientation.status == .unresolved {
                        LabeledContent("Upright", value: "Not determined")
                    }
                } else if let reconstruction = model.currentReconstruction {
                    LabeledContent("Solver", value: reconstruction.displayMapper)
                }
                if let trainer = metadata?.trainingArtifact {
                    LabeledContent("Trainer", value: trainer.trainerVersion)
                    LabeledContent("Iterations", value: trainer.completedIteration.formatted())
                }
                if let format = model.currentOutputPlyInfo?.formatLabel {
                    LabeledContent("Format", value: format)
                }
                if let relativePath = metadata?.outputs?.splatPlyPath {
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

    private var displayedRunOptions: RequestedRunOptions {
        metadata?.requestedRunOptions
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
        if let title = metadata?.title, !title.isEmpty { return title }
        guard let projectURL = model.currentProjectURL else { return "Result" }
        return projectURL.deletingPathExtension().lastPathComponent
    }

    private func loadMetadata() {
        guard let projectURL = model.currentProjectURL else {
            metadata = nil
            loadedMetadataProjectURL = nil
            return
        }
        metadata = try? ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        loadedMetadataProjectURL = projectURL.standardizedFileURL
    }

    private func presentExportPanel() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            let source: URL
            do {
                source = try await model.validatedCurrentSplatForExport()
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
            panel.nameFieldStringValue = source.lastPathComponent
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
                        try await Task.detached(priority: .userInitiated) {
                            try AppModel.exportValidatedSplat(from: source, to: destination)
                        }.value
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
            guard let output = try? await model.validatedCurrentSplatForExport() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }

    private var viewerSceneConfiguration: SplatViewerSceneConfiguration {
        let storedBounds = metadata?.trainingArtifact?.sceneBounds
        let bounds = storedBounds.flatMap { stored -> ViewerSceneBounds? in
            let center = SIMD3<Float>(
                Float(stored.center.x),
                Float(stored.center.y),
                Float(stored.center.z)
            )
            let radius = Float(stored.radius)
            guard center.x.isFinite,
                  center.y.isFinite,
                  center.z.isFinite,
                  radius.isFinite,
                  radius > 0 else { return nil }
            return ViewerSceneBounds(center: center, radius: radius)
        }
        let storedDirection = metadata?.geometryArtifact?
            .canonicalOrientation.canonicalOpeningViewDirection
        let openingDirection = storedDirection.map {
            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
        }
        let canFlip = metadata?.geometryArtifact?.allowsViewOnlyUprightFlip == true
        return SplatViewerSceneConfiguration(
            bounds: bounds,
            openingDirection: openingDirection,
            isViewOnlyFlipActive: canFlip
                && metadata?.viewerPreferences.isUprightFlipActive == true
        )
    }

    private func updateUprightFlip(_ isActive: Bool) {
        guard let projectURL = model.currentProjectURL else { return }
        do {
            metadata = try ProjectMetadataStore.update(
                at: ProjectPaths(root: projectURL).metadataURL
            ) { metadata in
                metadata.viewerPreferences.isUprightFlipActive = isActive
            }
        } catch {
            viewerAlert = ViewerAlert(
                title: "Couldn’t update view",
                message: error.localizedDescription
            )
        }
    }

    private func inputDescription(_ input: InputSpec) -> String {
        switch input {
        case .video(let files):
            return files.count == 1 ? "1 video" : "\(files.count) videos"
        case .photos:
            return "Photo folder"
        case .mixed(let videos, _):
            return "\(videos.count) video\(videos.count == 1 ? "" : "s") and photos"
        }
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
