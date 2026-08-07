import EasySplatCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showInputImporter = false
    @State private var showFolderImporter = false
    @State private var replaceInputOnImport = false
    @State private var showLowDiskWarning = false
    @State private var optionsExpanded = false
    @FocusState private var isDropZoneFocused: Bool

    private var hasInput: Bool {
        Self.hasSelectableInput(
            hasMedia: !model.pendingVideoURLs.isEmpty || !model.pendingPhotoURLs.isEmpty,
            hasDataset: model.pendingDataset != nil
        )
    }

    /// Gates the Create Splat button: media and datasets are both valid
    /// starting points.
    nonisolated static func hasSelectableInput(hasMedia: Bool, hasDataset: Bool) -> Bool {
        hasMedia || hasDataset
    }

    private var hasPhotos: Bool {
        !model.pendingPhotoURLs.isEmpty
    }

    private var isDataset: Bool {
        model.pendingDataset != nil
    }

    private var visibleOptionSections: VisibleOptionSections {
        Self.visibleOptionSections(forDataset: isDataset)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text("Create a 3D splat")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                DropZoneView(
                    title: "Choose Input…",
                    subtitle: "or drop videos, photos, folders, or a dataset here",
                    onChoose: { presentInputImporter(replacing: false) },
                    onDropURLs: { model.addInputs(urls: $0) }
                )
                .frame(height: 180)
                .focused($isDropZoneFocused)
                .accessibilityIdentifier("home.chooseInput")

                // A panel that offers files opens a folder rather than choosing
                // it, so picking a whole capture folder needs a panel of its own.
                // It hangs off this row rather than the view the file panel uses:
                // two importers on one view leave only the last one working.
                HStack {
                    Spacer()
                    Button("Choose Folder…") {
                        replaceInputOnImport = false
                        showFolderImporter = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("home.chooseFolder")
                }
                .fileImporter(
                    isPresented: $showFolderImporter,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: true
                ) { result in
                    handleImport(result)
                }

                if hasInput {
                    selectedInputs
                }

                DisclosureSection(isExpanded: $optionsExpanded) {
                    optionControls
                        .padding(.top, Theme.Spacing.medium)
                } label: {
                    HStack(spacing: Theme.Spacing.medium) {
                        Text("Options")
                        Spacer()
                        if !optionsExpanded {
                            Text(optionsSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(optionsSummary)
                        }
                    }
                }
                .font(.headline)
                .accessibilityIdentifier("home.options")

                if let warning = model.selectionWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isDataset,
                   let input = model.buildInputSpec(),
                   let prediction = RunDurationPredictor.predict(
                       options: model.requestedRunOptions,
                       input: input,
                       from: model.projectSummaries
                   ) {
                    Label(prediction.displayText, systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Create Splat") {
                        start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!hasInput)
                    .accessibilityIdentifier("home.start")
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .focusSection()
            .padding(Theme.Spacing.extraLarge)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .pageScrollEdgeEffect()
        .defaultFocus($isDropZoneFocused, true)
        .fileImporter(
            isPresented: $showInputImporter,
            allowedContentTypes: [
                .folder,
                .image,
                .movie,
                .video,
                .mpeg4Movie,
                .quickTimeMovie,
                .zip
            ],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert("Low disk space", isPresented: $showLowDiskWarning) {
            Button("Create Anyway") {
                model.startFromPendingSelection()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(lowDiskWarningMessage)
        }
    }

    private var selectedInputs: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                Text("Input")
                    .font(.headline)
                Spacer()
                Button("Replace Input…") {
                    presentInputImporter(replacing: true)
                }
                .buttonStyle(.borderless)
                Button("Replace with Folder…") {
                    replaceInputOnImport = true
                    showFolderImporter = true
                }
                .buttonStyle(.borderless)
            }

            if let dataset = model.pendingDataset {
                inputRow(name: datasetRowName(dataset), systemImage: "cube.transparent") {
                    model.removeDataset()
                }
            } else {
                if !model.pendingPhotoURLs.isEmpty {
                    let count = model.pendingPhotoURLs.count
                    inputRow(name: "\(count) \(count == 1 ? "photo" : "photos")", systemImage: "photo") {
                        model.removeAllPhotos()
                    }
                }

                ForEach(Array(model.pendingVideoURLs.enumerated()), id: \.element) { index, url in
                    inputRow(name: url.lastPathComponent, systemImage: "film") {
                        model.removeVideo(at: IndexSet(integer: index))
                    }
                }
            }
        }
    }

    private func datasetRowName(_ dataset: PendingDataset) -> String {
        guard let imageCount = dataset.imageCount else {
            return dataset.kind.displayName
        }
        return "\(dataset.kind.displayName) · \(imageCount) images"
    }

    private func inputRow(name: String, systemImage: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
            Spacer(minLength: Theme.Spacing.medium)
            Button(action: remove) {
                Label("Remove \(name)", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(name)")
        }
    }

    private var optionControls: some View {
        let sections = visibleOptionSections
        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if sections.capturePath {
                optionRow("Capture Path") {
                    Picker("Capture Path", selection: $model.requestedRunOptions.capturePath) {
                        Text("Automatic").tag(CapturePath.automatic)
                        Text("Around a subject").tag(CapturePath.orbit)
                        Text("Through a space").tag(CapturePath.walkthrough)
                        Text("Across a large area").tag(CapturePath.largeArea)
                    }
                    .accessibilityIdentifier("home.capturePath")
                }
            }

            optionRow("Detail") {
                Picker("Detail", selection: $model.requestedRunOptions.detailProfile) {
                    Text("Fast").tag(DetailProfile.fast)
                    Text("Balanced")
                        .tag(DetailProfile.balanced)
                        .disabled(!RunPlanResolver.supports(detail: .balanced, memoryGB: memoryGB))
                    Text("High Detail")
                        .tag(DetailProfile.highDetail)
                        .disabled(!RunPlanResolver.supports(detail: .highDetail, memoryGB: memoryGB))
                }
                .accessibilityIdentifier("home.detail")
            }
            if let explanation = Self.detailAvailabilityHelp(memoryGB: memoryGB) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 260, alignment: .leading)
                }
            }

            if sections.cameraGrouping {
                optionRow("Camera Source") {
                    Picker("Camera Source", selection: $model.requestedRunOptions.cameraGrouping) {
                        Text("Automatic").tag(CameraGrouping.automatic)
                        Text("Same camera and lens").tag(CameraGrouping.sameCameraAndLens)
                        Text("Mixed cameras or lenses").tag(CameraGrouping.mixedCamerasOrLenses)
                    }
                    .accessibilityIdentifier("home.cameraSource")
                }
            }

            if sections.lensProjection {
                optionRow("Lens") {
                    Picker("Lens", selection: $model.requestedRunOptions.lensProjection) {
                        Text("Automatic").tag(LensProjection.automatic)
                        Text("Perspective").tag(LensProjection.perspective)
                        Text("Fisheye").tag(LensProjection.fisheye)
                    }
                    .accessibilityIdentifier("home.lens")
                }
            }

            if sections.inputOrdering {
                optionRow("Input Order") {
                    Picker("Input Order", selection: $model.requestedRunOptions.inputOrdering) {
                        Text("Automatic").tag(InputOrdering.automatic)
                        Text("Continuous sequence")
                            .tag(InputOrdering.continuous)
                            .disabled(!continuousOrderingIsAvailable)
                            .help(continuousOrderingHelp)
                        Text("Unordered").tag(InputOrdering.unordered)
                    }
                    .accessibilityIdentifier("home.inputOrder")
                }
            }

            optionRow("Resource Use") {
                Picker("Resource Use", selection: $model.requestedRunOptions.resourcePolicy) {
                    Text("Automatic").tag(ResourcePolicy.automatic)
                    Text("Conserve Memory").tag(ResourcePolicy.conserveMemory)
                    Text("Maximum Performance")
                        .tag(ResourcePolicy.maximumPerformance)
                        .disabled(!Self.maximumPerformanceIsAvailable(memoryGB: memoryGB))
                        .help(
                            Self.resourceUseHelp(memoryGB: memoryGB)
                                ?? "Use more of this Mac for the fastest run."
                        )
                }
                .accessibilityIdentifier("home.resourceUse")
            }

            if hasPhotos {
                optionRow("Photo Use") {
                    Picker("Photo Use", selection: $model.requestedRunOptions.photoSelection) {
                        Text("Automatic selection").tag(PhotoSelection.automatic)
                        Text("Use all valid photos").tag(PhotoSelection.useAllValidPhotos)
                    }
                    .accessibilityIdentifier("home.photoUse")
                }
            }
        }
        .font(.body)
    }

    private var memoryGB: Double {
        model.hardwareProfile.memoryGB
    }

    private var continuousOrderingIsAvailable: Bool {
        // Ordering is inert for datasets, and their input spec should never be
        // read as media here; the row itself is hidden in that case.
        guard !isDataset, let input = model.buildInputSpec() else { return true }
        return RunPlanResolver.supports(inputOrdering: .continuous, input: input)
    }

    private var continuousOrderingHelp: String {
        continuousOrderingIsAvailable
            ? "Treat the input as one ordered capture."
            : "Continuous sequence can't combine videos and photos."
    }

    nonisolated static func maximumPerformanceIsAvailable(memoryGB: Double) -> Bool {
        RunPlanResolver.supports(resourcePolicy: .maximumPerformance, memoryGB: memoryGB)
    }

    nonisolated static func resourceUseHelp(memoryGB: Double) -> String? {
        guard !maximumPerformanceIsAvailable(memoryGB: memoryGB) else { return nil }
        return "Maximum Performance is unavailable on Macs with 16 GB of unified memory or less."
    }

    nonisolated static func detailAvailabilityHelp(memoryGB: Double) -> String? {
        if !RunPlanResolver.supports(detail: .balanced, memoryGB: memoryGB) {
            return "Balanced and High Detail need more than 8 GB of unified memory."
        }
        if !RunPlanResolver.supports(detail: .highDetail, memoryGB: memoryGB) {
            return "High Detail needs at least 24 GB of unified memory."
        }
        return nil
    }

    private func optionRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent(title) {
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(Text(title))
                .frame(width: 260, alignment: .leading)
        }
    }

    private var optionsSummary: String {
        let options = model.requestedRunOptions
        let sections = visibleOptionSections
        var parts = [Self.detailLabel(options.detailProfile)]
        if sections.capturePath, options.capturePath != .automatic {
            parts.append(Self.captureLabel(options.capturePath))
        }
        if sections.cameraGrouping, options.cameraGrouping != .automatic {
            parts.append(Self.cameraLabel(options.cameraGrouping))
        }
        if sections.lensProjection, options.lensProjection != .automatic {
            parts.append(Self.lensLabel(options.lensProjection))
        }
        if sections.inputOrdering, options.inputOrdering != .automatic {
            parts.append(Self.orderLabel(options.inputOrdering))
        }
        if options.resourcePolicy != .automatic {
            parts.append(Self.resourceLabel(options.resourcePolicy))
        }
        if !isDataset, hasPhotos, options.photoSelection == .useAllValidPhotos {
            parts.append("All valid photos")
        }
        if parts.count == 1 {
            parts.append("Automatic")
        }
        return parts.joined(separator: " · ")
    }

    /// Which option sections a given input surfaces. Datasets fixed their
    /// capture, ordering, and camera decisions upstream, so only Detail and
    /// Resource Use remain meaningful; media inputs show the full set.
    struct VisibleOptionSections: Equatable {
        var capturePath: Bool
        var detail: Bool
        var cameraGrouping: Bool
        var lensProjection: Bool
        var inputOrdering: Bool
        var resourceUse: Bool
    }

    nonisolated static func visibleOptionSections(forDataset: Bool) -> VisibleOptionSections {
        VisibleOptionSections(
            capturePath: !forDataset,
            detail: true,
            cameraGrouping: !forDataset,
            lensProjection: !forDataset,
            inputOrdering: !forDataset,
            resourceUse: true
        )
    }

    nonisolated static func detailLabel(_ value: DetailProfile) -> String {
        switch value {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .highDetail: "High Detail"
        }
    }

    nonisolated static func captureLabel(_ value: CapturePath) -> String {
        switch value {
        case .automatic: "Automatic"
        case .orbit: "Around a subject"
        case .walkthrough: "Through a space"
        case .largeArea: "Across a large area"
        }
    }

    nonisolated static func cameraLabel(_ value: CameraGrouping) -> String {
        switch value {
        case .automatic: "Automatic"
        case .sameCameraAndLens: "Same camera"
        case .mixedCamerasOrLenses: "Mixed cameras"
        }
    }

    nonisolated static func lensLabel(_ value: LensProjection) -> String {
        switch value {
        case .automatic: "Automatic"
        case .perspective: "Perspective"
        case .fisheye: "Fisheye"
        }
    }

    nonisolated static func orderLabel(_ value: InputOrdering) -> String {
        switch value {
        case .automatic: "Automatic"
        case .continuous: "Continuous"
        case .unordered: "Unordered"
        }
    }

    nonisolated static func resourceLabel(_ value: ResourcePolicy) -> String {
        switch value {
        case .automatic: "Automatic"
        case .conserveMemory: "Conserve Memory"
        case .maximumPerformance: "Maximum Performance"
        }
    }

    private func presentInputImporter(replacing: Bool) {
        replaceInputOnImport = replacing
        showInputImporter = true
    }

    /// Both panels end the same way, and the file panel and the folder panel are
    /// attached to different views because only one importer per view works.
    private func handleImport(_ result: Result<[URL], any Error>) {
        defer { replaceInputOnImport = false }
        guard case let .success(urls) = result else { return }
        if replaceInputOnImport {
            model.clearPendingInputs()
        }
        model.addInputs(urls: urls)
    }

    private func start() {
        let timingBoundary = RunTimingBoundary.capture()
        let freeBytes = model.freeDiskSpaceBytes()
        model.cachedFreeDiskBytes = freeBytes
        if let freeBytes, freeBytes < AppModel.recommendedFreeSpaceBytes {
            showLowDiskWarning = true
        } else {
            model.startFromPendingSelection(timingBoundary: timingBoundary)
        }
    }

    private var lowDiskWarningMessage: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let recommended = formatter.string(fromByteCount: AppModel.recommendedFreeSpaceBytes)
        let free = model.cachedFreeDiskBytes.map(formatter.string(fromByteCount:)) ?? "an unknown amount of space"
        return "This Mac has \(free) free. EasySplat recommends \(recommended) for working files and the finished splat."
    }
}
