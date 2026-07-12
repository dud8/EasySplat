import SwiftUI

struct WorkspaceView: View {
    let onNewSplat: () -> Void
    let onBackToProjects: () -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        .animation(reduceMotion ? nil : Theme.Motion.workspace, value: model.viewState)
        .background(Theme.background)
    }
}
