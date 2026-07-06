import SwiftUI
import UniformTypeIdentifiers
import EasySplatCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showVideoImporter = false
    @State private var showFolderImporter = false
    @State private var showLowDiskWarning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("EasySplat")
                        .font(.largeTitle.weight(.bold))
                    Text("Drop a video or photos folder to build a 3D memory.")
                        .foregroundStyle(.secondary)
                }

                DropZoneView(
                    title: "Drop a video or photos folder",
                    subtitle: "MP4/MOV or a folder of images",
                    onDropURLs: { model.addInputs(urls: $0) }
                )
                .frame(height: 220)

                HStack(spacing: 12) {
                    Button("Choose Video…") { showVideoImporter = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut("o", modifiers: .command)
                        .help("Pick one or more video files (⌘O).")
                        .accessibilityIdentifier("home.chooseVideo")
                        .fileImporter(
                            isPresented: $showVideoImporter,
                            allowedContentTypes: [UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie],
                            allowsMultipleSelection: true
                        ) { result in
                            if case let .success(urls) = result {
                                model.addInputs(urls: urls)
                            }
                        }
                    Button("Choose Photos Folder…") { showFolderImporter = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .help("Pick a folder of images (⇧⌘O).")
                        .accessibilityIdentifier("home.choosePhotosFolder")
                        .fileImporter(
                            isPresented: $showFolderImporter,
                            allowedContentTypes: [UTType.folder],
                            allowsMultipleSelection: false
                        ) { result in
                            if case let .success(urls) = result, let url = urls.first {
                                model.addInputs(urls: [url])
                            }
                        }
                }

                selectedInputsPanel

                settingsPanel

                ProjectFleetStatsView(
                    stats: ProjectFleetStats.aggregate(model.projectSummaries),
                    freeDiskBytes: model.cachedFreeDiskBytes
                )

                ProjectListView(projects: model.projectSummaries)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(40)
        }
        .onAppear {
            model.refreshProjectSummaries()
        }
        .alert(
            "Resume interrupted project?",
            isPresented: Binding(
                get: { model.recoveryPromptProject != nil },
                set: { isPresented in
                    if !isPresented, let project = model.recoveryPromptProject {
                        model.keepInterruptedProjectForLater(project)
                    }
                }
            ),
            presenting: model.recoveryPromptProject
        ) { project in
            Button("Resume") {
                model.resumeInterruptedProject(project)
            }
            Button("Keep for later", role: .cancel) {
                model.keepInterruptedProjectForLater(project)
            }
            Button("Delete", role: .destructive) {
                model.deleteInterruptedProject(project)
            }
        } message: { project in
            if let updatedAt = project.checkpointUpdatedAt {
                Text("Found unfinished progress for \"\(project.title)\" (last checkpoint: \(updatedAt.formatted(date: .abbreviated, time: .shortened))).")
            } else {
                Text("Found unfinished progress for \"\(project.title)\".")
            }
        }
        .alert("Low disk space", isPresented: $showLowDiskWarning) {
            Button("Start Anyway") {
                model.startFromPendingSelection()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(lowDiskWarningMessage)
        }
    }

    private var lowDiskWarningMessage: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let recommended = formatter.string(fromByteCount: AppModel.recommendedFreeSpaceBytes)
        let freeText = model.cachedFreeDiskBytes.map { formatter.string(fromByteCount: $0) } ?? "unknown"
        return "Only \(freeText) free on the EasySplat Projects volume. A run typically needs \(recommended) of working space for frames, COLMAP intermediates, and the trained splat. You can continue, but the run may fail partway."
    }

    private var selectedInputsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Inputs")
                    .font(.headline)
                Spacer()
                if !model.pendingVideoURLs.isEmpty || model.pendingPhotosFolderURL != nil {
                    Button("Clear All") {
                        model.clearPendingInputs()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                }
            }

            if let warning = model.selectionWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.pendingVideoURLs.isEmpty && model.pendingPhotosFolderURL == nil {
                Text("No inputs selected yet.")
                    .foregroundStyle(.secondary)
            }

            if let folder = model.pendingPhotosFolderURL {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folder.lastPathComponent)
                    Spacer()
                    Button("Remove") {
                        model.pendingPhotosFolderURL = nil
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                }
            }

            if !model.pendingVideoURLs.isEmpty {
                ForEach(Array(model.pendingVideoURLs.enumerated()), id: \.element) { index, url in
                    HStack {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                        Spacer()
                        Button("Remove") {
                            model.pendingVideoURLs.remove(at: index)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                if let prediction = RunDurationPredictor.predict(
                    mode: model.captureMode,
                    quality: model.qualityPreset,
                    from: model.projectSummaries
                ) {
                    Label(prediction.displayText, systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start") {
                    // Re-probe right before Start so the warning reflects the
                    // current free-space state instead of a stale cached value.
                    let freshFree = model.freeDiskSpaceBytes()
                    model.cachedFreeDiskBytes = freshFree
                    if let free = freshFree, free < AppModel.recommendedFreeSpaceBytes {
                        showLowDiskWarning = true
                    } else {
                        model.startFromPendingSelection()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start the pipeline with the selected input and preset (⌘↩).")
                .accessibilityIdentifier("home.start")
                .disabled(model.pendingVideoURLs.isEmpty && model.pendingPhotosFolderURL == nil)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.border)
        )
    }

    private var settingsPanel: some View {
        ViewThatFits(in: .horizontal) {
            settingsPanelHorizontal
            settingsPanelVertical
        }
    }

    private var settingsPanelHorizontal: some View {
        HStack(spacing: 20) {
            modePicker
                .frame(minWidth: 180, maxWidth: 240, alignment: .leading)
                .layoutPriority(1)
            qualityPicker
                .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
                .layoutPriority(1)
        }
    }

    private var settingsPanelVertical: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker
            qualityPicker
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Mode", selection: $model.captureMode) {
                Text("Object").tag(CaptureMode.object)
                Text("Room").tag(CaptureMode.room)
            }
            .pickerStyle(.segmented)
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profile")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Profile", selection: $model.qualityPreset) {
                Text("Fast").tag(QualityPreset.draft)
                Text("Balanced").tag(QualityPreset.standard)
                Text("Ultra").tag(QualityPreset.ultra)
            }
            .pickerStyle(.segmented)
        }
    }
}
