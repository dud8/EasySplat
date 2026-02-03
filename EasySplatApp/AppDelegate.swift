import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        if model.isStopping {
            model.registerExitIntent(.quit)
            return .terminateLater
        }

        guard model.viewState == .processing else {
            return .terminateNow
        }

        let decision = model.presentExitConfirmation(for: model.stage)
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
