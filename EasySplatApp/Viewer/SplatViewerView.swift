import SwiftUI

enum SplatViewerLoadState: Equatable {
    case loading
    case ready
    case failed(String)
}

enum SplatViewerOverlayDensity {
    case regular
    case compact
}

struct SplatViewerView: View {
    let splatURL: URL
    var reloadToken: Int = 0
    var resetCameraToken: Int = 0
    var showsLoadErrors: Bool = true
    var onLoadStateChanged: ((SplatViewerLoadState) -> Void)? = nil
    var overlayDensity: SplatViewerOverlayDensity = .regular
    @StateObject private var controller = SplatViewerController()
    @State private var showHelp = false

    var body: some View {
        let isCompactOverlay = overlayDensity == .compact
        let toolbarSpacing: CGFloat = isCompactOverlay ? 6 : 8
        let toolbarPadding: CGFloat = isCompactOverlay ? 8 : 12
        let toolbarControlSize: ControlSize = isCompactOverlay ? .small : .regular

        ZStack(alignment: .topLeading) {
            MetalKitSceneView(
                splatURL: splatURL,
                reloadToken: reloadToken,
                controller: controller,
                onLoadStateChanged: onLoadStateChanged
            )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.canvas, style: .continuous))

            HStack(spacing: toolbarSpacing) {
                Button("Fit") { controller.fitToView() }
                Button("Controls") { showHelp.toggle() }
            }
            .controlSize(toolbarControlSize)
            .buttonStyle(.bordered)
            .padding(toolbarPadding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .popover(isPresented: $showHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Controls").font(.headline)
                    Text("Orbit: Drag")
                    Text("Pan: Option + Drag")
                    Text("Zoom: Scroll")
                    Divider()
                    Text("Keyboard: arrows orbit")
                    Text("Option + arrows pan")
                    Text("+ / − zoom · F fit · R reset")
                }
                .padding(12)
            }

            if controller.isLoading {
                ProgressView("Loading splat…")
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            if controller.isUpdating && !controller.isLoading {
                Text("Updating preview…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if showsLoadErrors, let error = controller.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn’t load splat")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .onChange(of: resetCameraToken) { _, _ in
            controller.resetCamera()
        }
    }
}
