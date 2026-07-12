import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

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

        guard model.currentTask != nil else {
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
