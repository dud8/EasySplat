import SwiftUI

struct SplatViewerView: View {
    let splatURL: URL
    @StateObject private var controller = SplatViewerController()
    @State private var showHelp = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalKitSceneView(splatURL: splatURL, controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 8) {
                Button("Reset") { controller.resetCamera() }
                Button("Fit") { controller.fitToView() }
                Button("Controls") { showHelp.toggle() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .popover(isPresented: $showHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Controls").font(.headline)
                    Text("Orbit: Drag")
                    Text("Pan: Option + Drag")
                    Text("Zoom: Scroll")
                }
                .padding(12)
            }

            if controller.isLoading {
                ProgressView("Loading splat…")
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            if let error = controller.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn’t load splat")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
    }
}
