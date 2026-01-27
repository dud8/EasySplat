import SwiftUI
import UniformTypeIdentifiers
import EasySplatCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showVideoImporter = false
    @State private var showFolderImporter = false

    var body: some View {
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
                onDropURL: { handleDrop(url: $0) }
            )
            .frame(height: 220)

            HStack(spacing: 12) {
                Button("Choose Video…") { showVideoImporter = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Choose Photos Folder…") { showFolderImporter = true }
                    .buttonStyle(.bordered)
            }

            settingsPanel
        }
        .padding(40)
        .fileImporter(
            isPresented: $showVideoImporter,
            allowedContentTypes: [UTType.movie],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.startWithVideo(url: url)
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [UTType.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.startWithPhotoFolder(url: url)
            }
        }
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

    private func handleDrop(url: URL) {
        if url.hasDirectoryPath {
            model.startWithPhotoFolder(url: url)
        } else {
            model.startWithVideo(url: url)
        }
    }
}
