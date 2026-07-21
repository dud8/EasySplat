import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            context.coordinator.attach(to: nsView.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var model: AppModel?
        private weak var window: NSWindow?

        init(model: AppModel) {
            self.model = model
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            guard self.window !== window else { return }
            self.window?.delegate = nil
            self.window = window
            window.delegate = self
            window.minSize = NSSize(width: 920, height: 640)
            // Persist window size + position across launches. SwiftUI's
            // automatic restoration can drop state across launches; an explicit
            // autosave name keeps the frame under a stable user-defaults key.
            if window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName("EasySplatMainWindow")
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let model else { return true }

            if model.consumeWindowCloseBypass(for: sender) {
                return true
            }

            if model.isStopping {
                model.registerExitIntent(.closeWindow, window: sender)
                return false
            }

            // Flush any pending notes save so closing the window with a
            // half-typed annotation doesn't drop it on the floor.
            guard model.flushPendingNotesSave() else { return false }

            guard model.currentTask != nil else { return true }

            let decision = model.presentExitConfirmation()
            switch decision {
            case .save:
                model.cancelCurrentProject(deleteProject: false, exitIntent: .closeWindow, window: sender)
            case .delete:
                model.cancelCurrentProject(deleteProject: true, exitIntent: .closeWindow, window: sender)
            case .cancel:
                break
            }
            return false
        }
    }
}
