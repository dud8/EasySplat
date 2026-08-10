import SwiftUI

struct WorkspaceView: View {
    let onNewSplat: () -> Void
    let onBackToProjects: () -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animationDuration = Self.workspaceAnimationDuration(
            reduceMotion: reduceMotion
        )
        ZStack {
            // Non-result states reset the window title AppKit keeps from the
            // last-viewed splat.
            switch model.viewState {
            case .home:
                HomeView()
                    .navigationTitle("EasySplat")
                    .transition(.opacity)
            case .opening:
                OpeningSplatView()
                    .navigationTitle("EasySplat")
                    .transition(.opacity)
            case .processing:
                ProcessingView(onBackToProjects: onBackToProjects)
                    .navigationTitle("EasySplat")
                    .transition(.opacity)
            case .viewer:
                ViewerView(onNewSplat: onNewSplat)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            // Measured here: the viewer's own first layout reports transient
            // narrow widths.
            model.workspaceWidthHint = width
        }
        .animation(
            animationDuration.map { Theme.Motion.workspace(duration: $0) },
            value: model.viewState
        )
        .background(Theme.background)
    }

    nonisolated static func workspaceAnimationDuration(
        reduceMotion: Bool
    ) -> TimeInterval? {
        guard !reduceMotion else { return nil }
        return Theme.Motion.standardWorkspaceDuration
    }
}

private struct OpeningSplatView: View {
    var body: some View {
        ProgressView("Opening splat…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("workspace.opening")
    }
}
