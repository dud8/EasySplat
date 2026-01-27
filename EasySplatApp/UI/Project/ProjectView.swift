import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.viewState {
            case .home:
                HomeView()
            case .processing:
                ProcessingView()
            case .viewer:
                ViewerView()
            }
        }
        .background(Theme.background)
    }
}
