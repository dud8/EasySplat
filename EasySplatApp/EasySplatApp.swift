import AppKit
import SwiftUI

@main
enum EasySplatApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

struct AppRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        RootView()
            .environmentObject(model)
            .onAppear {
                if let projectURL = AppConfig.uiVerificationProcessingProjectURL {
                    model.applyUIVerificationProcessingFixture(projectURL: projectURL)
                }
            }
    }
}
