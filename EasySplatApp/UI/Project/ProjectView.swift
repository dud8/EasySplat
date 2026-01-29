import SwiftUI

struct RootView: View {
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
        .animation(reduceMotion ? nil : Theme.Motion.reveal, value: model.viewState)
        .tint(Theme.accent)
        .background(Theme.background)
    }
}
