import AppKit
import EasySplatCore
import Foundation

extension AppModel {
    func shareCurrentSplat() {
        guard activeShareSession == nil else {
            shareStatusMessage = "Share is already open."
            shareStatusIsError = false
            return
        }
        guard let items = validatedShareItems() else { return }

        let shareWindow = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        guard let contentView = shareWindow?.contentView else {
            shareStatusMessage = "Couldn’t open share options right now. Try again."
            shareStatusIsError = true
            return
        }

        let picker = NSSharingServicePicker(items: items)
        let session = ShareSession(model: self)
        activeShareSession = session
        isShareSheetActive = true
        shareStatusMessage = nil
        shareStatusIsError = false
        session.present(picker: picker, in: contentView)
    }

    func validatedShareItems() -> [Any]? {
        guard let projectURL = currentProjectURL else {
            shareStatusMessage = "Finish a project before sharing."
            shareStatusIsError = true
            return nil
        }
        guard let expectedURL = metadataOutputURL(projectURL: projectURL) else {
            shareStatusMessage = "Finish a project before sharing."
            shareStatusIsError = true
            return nil
        }
        guard let validatedURL = readyOutputURL(projectURL: projectURL) else {
            let outputState = outputFileState(at: expectedURL)
            if outputState.exists {
                shareStatusMessage = "Could not open \(expectedURL.lastPathComponent). Rebuild or reopen the project."
            } else {
                shareStatusMessage = "Could not find \(expectedURL.lastPathComponent). Rebuild or reopen the project."
            }
            shareStatusIsError = true
            return nil
        }
        return [validatedURL]
    }

    func shareDidStart(from session: ShareSession) {
        guard activeShareSession === session else { return }
        shareStatusMessage = "Sharing…"
        shareStatusIsError = false
    }

    func shareDidComplete(from session: ShareSession) {
        guard activeShareSession === session else { return }
        shareStatusMessage = "Shared."
        shareStatusIsError = false
    }

    func shareDidFail(from session: ShareSession) {
        guard activeShareSession === session else { return }
        shareStatusMessage = "Couldn’t share the file. Try again."
        shareStatusIsError = true
    }

    func shareDidCancel(from session: ShareSession) {
        guard activeShareSession === session else { return }
        shareStatusMessage = nil
        shareStatusIsError = false
    }

    func clearShareSession(_ session: ShareSession) {
        guard activeShareSession === session else { return }
        activeShareSession = nil
        isShareSheetActive = false
    }
}

@MainActor
final class ShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private weak var model: AppModel?
    // The session owns the picker until AppKit reports completion or cancellation.
    private var picker: NSSharingServicePicker?

    init(model: AppModel) {
        self.model = model
    }

    func present(picker: NSSharingServicePicker, in sourceView: NSView) {
        picker.delegate = self
        self.picker = picker
        let anchor = NSRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: sourceView, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else {
            model?.shareDidCancel(from: self)
            model?.clearShareSession(self)
            return
        }
        service.delegate = self
        model?.shareDidStart(from: self)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        model?.shareDidComplete(from: self)
        model?.clearShareSession(self)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        model?.shareDidFail(from: self)
        model?.clearShareSession(self)
    }
}
