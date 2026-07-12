import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch model.viewState {
            case .home:
                HomeView()
                    .transition(.opacity)
            case .processing:
                ProcessingView()
                    .transition(.opacity)
            case .viewer:
                ViewerView()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : Theme.Motion.workspace, value: model.viewState)
        .background(Theme.background)
    }
}
