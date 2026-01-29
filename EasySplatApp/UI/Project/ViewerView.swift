import SwiftUI
import AppKit
import EasySplatCore

struct ViewerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Your splat is ready")
                .font(.title2.weight(.semibold))

            if let plyURL = model.outputPlyURL {
                Text(plyURL.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SplatViewerView(splatURL: plyURL)
                    .frame(height: 360)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([plyURL])
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    if let brush = model.toolchainPaths?.brush {
                        Button("Open in Brush") {
                            openInBrush(brushPath: brush, splatURL: plyURL)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            } else {
                Text("No output found yet.")
                    .foregroundStyle(.secondary)
            }

            Button("Start Another") {
                model.viewState = .home
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(32)
    }

    private func openInBrush(brushPath: URL, splatURL: URL) {
        let process = Process()
        process.executableURL = brushPath
        process.arguments = ["--with-viewer", splatURL.path]
        try? process.run()
    }
}
