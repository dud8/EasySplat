import EasySplatCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showInputImporter = false
    @State private var replaceInputOnImport = false
    @State private var showLowDiskWarning = false
    @State private var optionsExpanded = false

    private var hasInput: Bool {
        !model.pendingVideoURLs.isEmpty || model.pendingPhotosFolderURL != nil
    }

    private var hasPhotos: Bool {
        model.pendingPhotosFolderURL != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text("Create a 3D splat")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose a video or a folder of photos.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                DropZoneView(
                    title: "Choose Input…",
                    subtitle: "or drop a video or photos folder here",
                    onChoose: { presentInputImporter(replacing: false) },
                    onDropURLs: { model.addInputs(urls: $0) }
                )
                .frame(height: 180)
                .accessibilityIdentifier("home.chooseInput")

                if hasInput {
                    selectedInputs
                }

                DisclosureGroup(isExpanded: $optionsExpanded) {
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
                        }
                    }
                }
                .font(.headline)

                if let warning = model.selectionWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let input = model.buildInputSpec(),
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
            .padding(Theme.Spacing.extraLarge)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .fileImporter(
            isPresented: $showInputImporter,
            allowedContentTypes: [
                .folder,
                .movie,
                .video,
                .mpeg4Movie,
                .quickTimeMovie
            ],
            allowsMultipleSelection: true
        ) { result in
            defer { replaceInputOnImport = false }
            guard case let .success(urls) = result else { return }
            if replaceInputOnImport {
                model.clearPendingInputs()
            }
            model.addInputs(urls: urls)
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
            }

            if let folder = model.pendingPhotosFolderURL {
                inputRow(name: folder.lastPathComponent, systemImage: "folder") {
                    model.pendingPhotosFolderURL = nil
                }
            }

            ForEach(Array(model.pendingVideoURLs.enumerated()), id: \.element) { index, url in
                inputRow(name: url.lastPathComponent, systemImage: "film") {
                    model.pendingVideoURLs.remove(at: index)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            optionRow("Capture Path") {
                Picker("Capture Path", selection: $model.requestedRunOptions.capturePath) {
                    Text("Automatic").tag(CapturePath.automatic)
                    Text("Around a subject").tag(CapturePath.orbit)
                    Text("Through a space").tag(CapturePath.walkthrough)
                    Text("Across a large area").tag(CapturePath.largeArea)
                }
            }

            optionRow("Detail") {
                Picker("Detail", selection: $model.requestedRunOptions.detailProfile) {
                    Text("Fast").tag(DetailProfile.fast)
                    Text("Balanced").tag(DetailProfile.balanced)
                    Text("High Detail").tag(DetailProfile.highDetail)
                }
            }

            optionRow("Camera Source") {
                Picker("Camera Source", selection: $model.requestedRunOptions.cameraGrouping) {
                    Text("Automatic").tag(CameraGrouping.automatic)
                    Text("Same camera and lens").tag(CameraGrouping.sameCameraAndLens)
                    Text("Mixed cameras or lenses").tag(CameraGrouping.mixedCamerasOrLenses)
                }
            }

            optionRow("Lens") {
                Picker("Lens", selection: $model.requestedRunOptions.lensProjection) {
                    Text("Automatic").tag(LensProjection.automatic)
                    Text("Perspective").tag(LensProjection.perspective)
                    Text("Fisheye").tag(LensProjection.fisheye)
                }
            }

            optionRow("Input Order") {
                Picker("Input Order", selection: $model.requestedRunOptions.inputOrdering) {
                    Text("Automatic").tag(InputOrdering.automatic)
                    Text("Continuous sequence").tag(InputOrdering.continuous)
                    Text("Unordered").tag(InputOrdering.unordered)
                }
            }

            optionRow("Resource Use") {
                Picker("Resource Use", selection: $model.requestedRunOptions.resourcePolicy) {
                    Text("Automatic").tag(ResourcePolicy.automatic)
                    Text("Conserve Memory").tag(ResourcePolicy.conserveMemory)
                    Text("Maximum Performance").tag(ResourcePolicy.maximumPerformance)
                }
            }

            if hasPhotos {
                optionRow("Photo Use") {
                    Picker("Photo Use", selection: $model.requestedRunOptions.photoSelection) {
                        Text("Automatic selection").tag(PhotoSelection.automatic)
                        Text("Use all valid photos").tag(PhotoSelection.useAllValidPhotos)
                    }
                }
            }
        }
        .font(.body)
    }

    private func optionRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent(title) {
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .trailing)
        }
    }

    private var optionsSummary: String {
        let options = model.requestedRunOptions
        var parts = [Self.detailLabel(options.detailProfile)]
        if options.capturePath != .automatic {
            parts.append(Self.captureLabel(options.capturePath))
        }
        if options.cameraGrouping != .automatic {
            parts.append(Self.cameraLabel(options.cameraGrouping))
        }
        if options.lensProjection != .automatic {
            parts.append(Self.lensLabel(options.lensProjection))
        }
        if options.inputOrdering != .automatic {
            parts.append(Self.orderLabel(options.inputOrdering))
        }
        if options.resourcePolicy != .automatic {
            parts.append(Self.resourceLabel(options.resourcePolicy))
        }
        if hasPhotos, options.photoSelection == .useAllValidPhotos {
            parts.append("All valid photos")
        }
        if parts.count == 1 {
            parts.append("Automatic")
        }
        return parts.joined(separator: " · ")
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

    private func start() {
        let freeBytes = model.freeDiskSpaceBytes()
        model.cachedFreeDiskBytes = freeBytes
        if let freeBytes, freeBytes < AppModel.recommendedFreeSpaceBytes {
            showLowDiskWarning = true
        } else {
            model.startFromPendingSelection()
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
