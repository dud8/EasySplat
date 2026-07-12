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

                DisclosureGroup("Options", isExpanded: $optionsExpanded) {
                    optionControls
                        .padding(.top, Theme.Spacing.medium)
                }
                .font(.headline)

                if let warning = model.selectionWarning {
                    Text(warning)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.large) {
                capturePicker
                    .frame(maxWidth: 260)
                detailPicker
                    .frame(maxWidth: 360)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                capturePicker
                detailPicker
            }
        }
        .font(.body)
    }

    private var capturePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Capture")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Capture", selection: $model.captureMode) {
                Text("Object").tag(CaptureMode.object)
                Text("Room").tag(CaptureMode.room)
            }
            .pickerStyle(.segmented)
        }
    }

    private var detailPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Detail")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Detail", selection: $model.qualityPreset) {
                Text("Fast").tag(QualityPreset.draft)
                Text("Balanced").tag(QualityPreset.standard)
                Text("High Detail").tag(QualityPreset.ultra)
            }
            .pickerStyle(.segmented)
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
