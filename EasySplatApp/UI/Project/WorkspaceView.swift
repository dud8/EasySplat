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
            switch model.viewState {
            case .home:
                HomeView()
                    .transition(.opacity)
            case .processing:
                ProcessingView(onBackToProjects: onBackToProjects)
                    .transition(.opacity)
            case .viewer:
                ViewerView(onNewSplat: onNewSplat)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
