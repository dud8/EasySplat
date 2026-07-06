import SwiftUI

@main
struct EasySplatApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear {
                    appDelegate.model = model
                    model.refreshFreeDiskSpace()
                }
                .frame(idealWidth: 1100, idealHeight: 760)
                .onChange(of: scenePhase) { _, newPhase in
                    // Refresh project summaries when the window regains focus so
                    // external changes (Finder deletes, files added by Finder copy,
                    // upgrades to project.json from a parallel CLI run) appear
                    // without forcing the user to switch screens manually.
                    if newPhase == .active && model.viewState == .home {
                        model.refreshProjectSummaries()
                        model.refreshFreeDiskSpace()
                    }
                    // When the app backgrounds or the scene goes inactive,
                    // flush any pending notes save so a half-typed note
                    // doesn't sit in the debounce queue while the user has
                    // switched away.
                    if newPhase != .active {
                        model.flushPendingNotesSave()
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                // No keyboard shortcut: Cmd+Opt+D is reserved by macOS for
                // Show/Hide Dock, and the diagnostics bundle isn't worth
                // overloading a system chord for.
                Button("Copy Diagnostics for Current Project") {
                    if let projectURL = model.currentProjectURL {
                        model.copyDiagnosticBundle(forProjectURL: projectURL)
                    }
                }
                .disabled(model.currentProjectURL == nil)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About EasySplat") {
                    let panel = NSAlert()
                    panel.messageText = "EasySplat"
                    var lines: [String] = [
                        "macOS-only Apple Silicon app for turning videos, photos, or mixed inputs into 3D Gaussian splats."
                    ]
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
                        let suffix = build.isEmpty ? "" : " (build \(build))"
                        lines.append("Version \(version)\(suffix).")
                    }
                    lines.append("Hardware: \(AppModel.hardwareSummaryLine())")
                    panel.informativeText = lines.joined(separator: "\n\n")
                    panel.addButton(withTitle: "OK")
                    panel.runModal()
                }
            }
        }
    }
}
