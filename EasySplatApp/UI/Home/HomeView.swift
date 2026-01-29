import SwiftUI
import UniformTypeIdentifiers
import EasySplatCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showVideoImporter = false
    @State private var showFolderImporter = false

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
                        .buttonStyle(.bordered)
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

                ProjectListView(projects: model.projectSummaries)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(40)
        }
        .onAppear {
            model.refreshProjectSummaries()
        }
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
                    .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Start") {
                    model.startFromPendingSelection()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.pendingVideoURLs.isEmpty && model.pendingPhotosFolderURL == nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }

    private var settingsPanel: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Mode", selection: $model.captureMode) {
                    Text("Object").tag(CaptureMode.object)
                    Text("Room").tag(CaptureMode.room)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Quality")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Quality", selection: $model.qualityPreset) {
                    Text("Draft").tag(QualityPreset.draft)
                    Text("Standard").tag(QualityPreset.standard)
                    Text("Ultra").tag(QualityPreset.ultra)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
        }
        .padding(.top, 8)
    }
}
