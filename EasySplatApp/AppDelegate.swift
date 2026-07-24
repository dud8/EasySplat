import AppKit
import Combine
import Darwin
import EasySplatCore
import EasySplatReleaseVerifierCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model: AppModel
    private var mainWindow: NSWindow?
    private var windowSubtitleCancellable: AnyCancellable?
    private var runStatusPresenter: RunStatusPresenter?
    private let releaseVerificationConfiguration: AppConfig.ReleaseVerificationConfiguration?

    override init() {
        model = AppModel()
        releaseVerificationConfiguration = AppConfig.releaseVerificationConfiguration
        super.init()
    }

    init(
        model: AppModel,
        releaseVerificationConfiguration: AppConfig.ReleaseVerificationConfiguration? = nil
    ) {
        self.model = model
        self.releaseVerificationConfiguration = releaseVerificationConfiguration
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        guard let application = notification.object as? NSApplication else { return }
        application.mainMenu = makeMainMenu(for: application)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached(priority: .utility) {
            _ = ShareSnapshotStorage.reclaimStaleSnapshots()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let configuration = releaseVerificationConfiguration {
                Task { @MainActor in
                    do {
                        guard let executableURL = Bundle.main.executableURL else {
                            throw ReleaseVerificationRunError.invalidExecutable
                        }
                        try await model.runBundledPipelineForReleaseVerification(
                            inputManifestURL: configuration.inputManifestURL,
                            inputRootURL: configuration.inputRootURL,
                            successMarkerURL: configuration.successMarkerURL,
                            verificationToken: configuration.verificationToken,
                            appVersion: EasySplatReleaseIdentity.version(),
                            executableURL: executableURL
                        )
                    } catch {
                        FileHandle.standardError.write(
                            Data("Release verification failed: \(error.localizedDescription)\n".utf8)
                        )
                        Darwin.exit(EXIT_FAILURE)
                    }
                    NSApp.terminate(nil)
                }
                return
            }
            showMainWindow()
        }
    }

    func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeMainWindow()
        mainWindow = window
        runStatusPresenter = RunStatusPresenter(model: model) { [weak window] in
            NSApp.isActive && (window?.occlusionState.contains(.visible) ?? false)
        }
        windowSubtitleCancellable = model.$stage
            .combineLatest(model.$isRunActive)
            .map(ProcessingPhase.windowSubtitle(stage:isRunActive:))
            .removeDuplicates()
            .sink { [weak window] subtitle in
                window?.subtitle = subtitle
            }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The sidebar search field would otherwise grab key focus at launch and
        // show a focus ring before the user has touched anything. Tab order and
        // click-to-focus are unaffected.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.firstResponder is NSTextView else { return }
            window.makeFirstResponder(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard model.viewState == .home else { return }
        model.refreshProjectSummariesInBackground()
        model.refreshFreeDiskSpace()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.flushPendingNotesSave()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelSubjectIsolation()
        model.cancelSharing()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func makeMainWindow() -> NSWindow {
        let controller = NSHostingController(rootView: AppRootView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EasySplat"
        window.minSize = NSSize(width: 920, height: 640)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("EasySplatMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("EasySplatMainWindow")
        return window
    }

    func makeMainMenu(for application: NSApplication) -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenu = NSMenu(title: "EasySplat")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let aboutItem = NSMenuItem(title: "About EasySplat", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        applicationMenu.addItem(aboutItem)
        let releasesItem = NSMenuItem(
            title: "View Releases…",
            action: #selector(viewReleases(_:)),
            keyEquivalent: ""
        )
        releasesItem.target = self
        applicationMenu.addItem(releasesItem)
        applicationMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        application.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: "Hide EasySplat", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = application
        applicationMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = application
        applicationMenu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = application
        applicationMenu.addItem(showAllItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit EasySplat",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = application
        applicationMenu.addItem(quitItem)

        let fileMenu = NSMenu(title: "File")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let newSplatItem = NSMenuItem(
            title: "New Splat",
            action: #selector(newSplat(_:)),
            keyEquivalent: "n"
        )
        newSplatItem.target = self
        fileMenu.addItem(newSplatItem)
        let exportItem = NSMenuItem(
            title: "Export…",
            action: #selector(exportSplat(_:)),
            keyEquivalent: "e"
        )
        exportItem.target = self
        fileMenu.addItem(exportItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        )

        let editMenu = NSMenu(title: "Edit")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let viewMenu = NSMenu(title: "View")
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let sidebarItem = NSMenuItem(
            title: "Show or Hide Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(sidebarItem)
        let inspectorItem = NSMenuItem(
            title: "Show Inspector",
            action: #selector(toggleInspector(_:)),
            keyEquivalent: "i"
        )
        inspectorItem.keyEquivalentModifierMask = [.command, .control]
        inspectorItem.target = self
        viewMenu.addItem(inspectorItem)
        viewMenu.addItem(.separator())
        let showOriginalItem = NSMenuItem(
            title: "Show Original",
            action: #selector(showOriginal(_:)),
            keyEquivalent: ""
        )
        showOriginalItem.target = self
        viewMenu.addItem(showOriginalItem)
        let showSubjectItem = NSMenuItem(
            title: "Show Subject",
            action: #selector(showSubject(_:)),
            keyEquivalent: ""
        )
        showSubjectItem.target = self
        viewMenu.addItem(showSubjectItem)
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        let windowMenu = NSMenu(title: "Window")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        application.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        let helpItem = NSMenuItem()
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        application.helpMenu = helpMenu
        let helpPageItem = NSMenuItem(
            title: "EasySplat Help",
            action: #selector(openHelpPage(_:)),
            keyEquivalent: "?"
        )
        helpPageItem.target = self
        helpMenu.addItem(helpPageItem)
        helpMenu.addItem(.separator())
        let diagnosticsItem = NSMenuItem(
            title: "Copy Diagnostics for Current Project",
            action: #selector(copyDiagnostics(_:)),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        helpMenu.addItem(diagnosticsItem)

        return mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyDiagnostics(_:)) {
            return model.currentProjectURL != nil
        }
        if menuItem.action == #selector(newSplat(_:)) {
            return !model.hasActiveWork
        }
        if menuItem.action == #selector(exportSplat(_:)) {
            return model.viewState == .viewer
                && model.displayedOutputURL != nil
        }
        if menuItem.action == #selector(toggleInspector(_:)) {
            menuItem.title = model.isResultInspectorPresented ? "Hide Inspector" : "Show Inspector"
            return model.viewState == .viewer
        }
        if menuItem.action == #selector(showOriginal(_:)) {
            menuItem.state = model.selectedSplatOutputVariant == .original
                ? .on
                : .off
            return model.viewState == .viewer && model.outputPlyURL != nil
        }
        if menuItem.action == #selector(showSubject(_:)) {
            menuItem.state = model.selectedSplatOutputVariant == .subject
                ? .on
                : .off
            return model.viewState == .viewer && model.subjectOutput != nil
        }
        return true
    }

    @objc private func newSplat(_ sender: Any?) {
        model.beginNewSplat()
    }

    @objc private func exportSplat(_ sender: Any?) {
        model.requestExportFromMenu()
    }

    @objc private func toggleInspector(_ sender: Any?) {
        guard model.viewState == .viewer else { return }
        model.isResultInspectorPresented.toggle()
        UserDefaults.standard.set(
            model.isResultInspectorPresented,
            forKey: ViewerView.inspectorPreferenceKey
        )
    }

    @objc private func showOriginal(_ sender: Any?) {
        guard model.viewState == .viewer else { return }
        _ = model.setSelectedSplatOutputVariant(.original)
    }

    @objc private func showSubject(_ sender: Any?) {
        guard model.viewState == .viewer else { return }
        _ = model.setSelectedSplatOutputVariant(.subject)
    }

    @objc private func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "Turns videos and photos into 3D Gaussian splats, entirely on this Mac.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "EasySplat",
            .applicationVersion: EasySplatReleaseIdentity.version(),
            .credits: credits
        ]
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty {
            options[.version] = build
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func viewReleases(_ sender: Any?) {
        let releases = AppConfig.projectHomeURL
            .appendingPathComponent("releases", isDirectory: true)
        NSWorkspace.shared.open(releases)
    }

    @objc private func openHelpPage(_ sender: Any?) {
        NSWorkspace.shared.open(AppConfig.projectHomeURL)
    }

    @objc private func copyDiagnostics(_ sender: Any?) {
        guard let projectURL = model.currentProjectURL else { return }
        model.copyDiagnosticBundle(forProjectURL: projectURL)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush any pending notes-save before we hand control to the
        // termination flow so the user's last edit isn't dropped by the
        // debounce timer being cancelled mid-write.
        guard model.flushPendingNotesSave() else {
            return .terminateCancel
        }

        if model.isStopping {
            model.registerExitIntent(.quit)
            return .terminateLater
        }

        guard model.hasActiveWork else {
            return .terminateNow
        }

        let decision = model.presentExitConfirmation()
        switch decision {
        case .save:
            model.cancelCurrentProject(deleteProject: false, exitIntent: .quit)
            return .terminateLater
        case .delete:
            model.cancelCurrentProject(deleteProject: true, exitIntent: .quit)
            return .terminateLater
        case .cancel:
            return .terminateCancel
        }
    }
}
