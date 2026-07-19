import AppKit
import Darwin
import SwiftUI

@main
enum EasySplatApplication {
    @MainActor
    static func main() {
        let releaseVerificationStartup = AppConfig.releaseVerificationStartup
        guard !releaseVerificationStartup.requiresImmediateExit else {
            FileHandle.standardError.write(
                Data("Release verification startup was rejected.\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
        let releaseVerificationConfiguration = releaseVerificationStartup.configuration
        let application = NSApplication.shared
        let delegate = AppDelegate(
            model: AppModel(),
            releaseVerificationConfiguration: releaseVerificationConfiguration
        )
        application.delegate = delegate
        application.setActivationPolicy(
            activationPolicy(for: releaseVerificationStartup)
        )
        application.finishLaunching()
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    static func activationPolicy(
        for releaseVerificationStartup: AppConfig.ReleaseVerificationStartup
    ) -> NSApplication.ActivationPolicy {
        releaseVerificationStartup == .ordinary ? .regular : .prohibited
    }
}

struct AppRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        RootView()
            .environmentObject(model)
    }
}
