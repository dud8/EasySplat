import SwiftUI

@main
struct EasySplatApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear {
                    appDelegate.model = model
                }
        }
    }
}
