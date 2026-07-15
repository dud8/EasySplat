import AppKit
import EasySplatCore
import Foundation

struct ShareFileSnapshot: Equatable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let byteCount: Int64
    let modificationDate: Date

    static func capture(at url: URL) -> ShareFileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let deviceNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              byteCount > 0,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return ShareFileSnapshot(
            deviceNumber: deviceNumber,
            fileNumber: fileNumber,
            byteCount: byteCount,
            modificationDate: modificationDate
        )
    }
}

struct PreparedShareItem: Equatable {
    let projectURL: URL
    let outputURL: URL
    let validatedSHA256: String?
    let byteCount: Int64
    let fileSnapshot: ShareFileSnapshot
}

extension AppModel {
    func prepareCurrentSplatForSharing() async {
        let token = UUID()
        sharePreparationToken = token
        preparedShareItem = nil
        isShareReady = false

        guard let projectURL = currentProjectURL,
              let displayedOutputURL = outputPlyURL,
              let expectedOutputURL = metadataOutputURL(projectURL: projectURL),
              ProjectSummary.hasSameLocation(displayedOutputURL, expectedOutputURL) else {
            finishSharePreparationFailure(
                token: token,
                message: "Finish a project before sharing."
            )
            return
        }
        guard let snapshotBeforeValidation = ShareFileSnapshot.capture(at: expectedOutputURL) else {
            finishSharePreparationFailure(
                token: token,
                message: unavailableOutputMessage(for: expectedOutputURL)
            )
            return
        }

        let validatedOutputURL: URL?
        do {
            validatedOutputURL = try await validatedFinishedOutputURL(projectURL: projectURL)
        } catch is CancellationError {
            clearSharePreparation(token: token)
            return
        } catch {
            finishSharePreparationFailure(
                token: token,
                message: "Couldn’t check the splat. Try again."
            )
            return
        }

        guard sharePreparationToken == token,
              ProjectSummary.hasSameLocation(currentProjectURL, projectURL),
              ProjectSummary.hasSameLocation(outputPlyURL, displayedOutputURL) else {
            clearSharePreparation(token: token)
            return
        }
        guard let validatedOutputURL,
              ProjectSummary.hasSameLocation(validatedOutputURL, expectedOutputURL),
              let snapshotAfterValidation = ShareFileSnapshot.capture(at: validatedOutputURL),
              snapshotAfterValidation == snapshotBeforeValidation else {
            finishSharePreparationFailure(
                token: token,
                message: unavailableOutputMessage(for: expectedOutputURL)
            )
            return
        }

        let metadata = try? ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        let validatedSHA256 = metadata?.trainingArtifact?.outputSHA256
        if let recordedBytes = metadata?.trainingArtifact?.outputBytes,
           recordedBytes != snapshotAfterValidation.byteCount {
            finishSharePreparationFailure(
                token: token,
                message: "Could not open \(expectedOutputURL.lastPathComponent). Rebuild or reopen the project."
            )
            return
        }

        preparedShareItem = PreparedShareItem(
            projectURL: projectURL.standardizedFileURL,
            outputURL: validatedOutputURL.standardizedFileURL,
            validatedSHA256: validatedSHA256,
            byteCount: snapshotAfterValidation.byteCount,
            fileSnapshot: snapshotAfterValidation
        )
        sharePreparationToken = nil
        isShareReady = true
        shareStatusMessage = nil
        shareStatusIsError = false
    }

    func presentPreparedShare(from sourceView: NSView) {
        guard activeShareSession == nil else {
            shareStatusMessage = "Share is already open."
            shareStatusIsError = false
            return
        }
        guard !isShareSheetActive,
              let preparedShareItem,
              let projectURL = currentProjectURL,
              ProjectSummary.hasSameLocation(projectURL, preparedShareItem.projectURL),
              ProjectSummary.hasSameLocation(outputPlyURL, preparedShareItem.outputURL),
              let currentOutputURL = readyOutputURL(
                projectURL: projectURL,
                validationDepth: .quick
              ),
              ProjectSummary.hasSameLocation(currentOutputURL, preparedShareItem.outputURL),
              ShareFileSnapshot.capture(at: currentOutputURL) == preparedShareItem.fileSnapshot,
              currentShareArtifactStillMatches(preparedShareItem, projectURL: projectURL) else {
            invalidatePreparedShareItem(
                message: "Could not open the validated splat. Reopen the project and try again."
            )
            return
        }

        let session = ShareSession(model: self)
        activeShareSession = session
        isShareSheetActive = true
        shareStatusMessage = nil
        shareStatusIsError = false
        session.present(items: [preparedShareItem.outputURL], from: sourceView)
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
        session.finish()
        activeShareSession = nil
        isShareSheetActive = false
    }

    func cancelSharing() {
        sharePreparationToken = nil
        preparedShareItem = nil
        isShareReady = false
        _ = activeShareSession?.close()
        activeShareSession = nil
        isShareSheetActive = false
    }

    private func currentShareArtifactStillMatches(
        _ preparedItem: PreparedShareItem,
        projectURL: URL
    ) -> Bool {
        guard let metadata = try? ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        ) else {
            return false
        }
        guard let trainingArtifact = metadata.trainingArtifact else {
            return preparedItem.validatedSHA256 == nil
        }
        return trainingArtifact.outputSHA256 == preparedItem.validatedSHA256
            && trainingArtifact.outputBytes == preparedItem.byteCount
    }

    private func unavailableOutputMessage(for expectedURL: URL) -> String {
        let outputState = outputFileState(at: expectedURL)
        if outputState.exists {
            return "Could not open \(expectedURL.lastPathComponent). Rebuild or reopen the project."
        }
        return "Could not find \(expectedURL.lastPathComponent). Rebuild or reopen the project."
    }

    private func invalidatePreparedShareItem(message: String) {
        preparedShareItem = nil
        sharePreparationToken = nil
        isShareReady = false
        shareStatusMessage = message
        shareStatusIsError = true
    }

    private func finishSharePreparationFailure(token: UUID, message: String) {
        guard sharePreparationToken == token else { return }
        invalidatePreparedShareItem(message: message)
    }

    private func clearSharePreparation(token: UUID) {
        guard sharePreparationToken == token else { return }
        sharePreparationToken = nil
        preparedShareItem = nil
        isShareReady = false
    }
}

@MainActor
final class ShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    typealias Presenter = (
        NSSharingServicePicker,
        NSRect,
        NSView,
        NSRectEdge
    ) -> Void

    private weak var model: AppModel?
    private weak var anchorView: NSView?
    private var picker: NSSharingServicePicker?
    private var isClosed = false
    private let presenter: Presenter

    init(
        model: AppModel,
        presenter: @escaping Presenter = { picker, rect, view, edge in
            picker.show(relativeTo: rect, of: view, preferredEdge: edge)
        }
    ) {
        self.model = model
        self.presenter = presenter
    }

    func present(items: [Any], from sourceView: NSView) {
        guard !isClosed, picker == nil else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        anchorView = sourceView
        presenter(picker, sourceView.bounds, sourceView, .minY)
    }

    @discardableResult
    func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        picker?.delegate = nil
        picker?.close()
        picker = nil
        anchorView = nil
        return true
    }

    func finish() {
        isClosed = true
        picker?.delegate = nil
        picker = nil
        anchorView = nil
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
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

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        model?.shareDidFail(from: self)
        model?.clearShareSession(self)
    }

    func anchoringView(
        for sharingService: NSSharingService,
        showRelativeTo positioningRect: UnsafeMutablePointer<NSRect>,
        preferredEdge: UnsafeMutablePointer<NSRectEdge>
    ) -> NSView? {
        guard let anchorView else { return nil }
        positioningRect.pointee = anchorView.bounds
        preferredEdge.pointee = .minY
        return anchorView
    }
}
