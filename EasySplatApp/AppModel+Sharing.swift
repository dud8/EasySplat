import AppKit
import EasySplatCore
import Foundation

extension AppModel {
    func shareCurrentSplat() {
        guard activeShareSession == nil else {
            shareStatusMessage = "Finish the current share first."
            shareStatusIsError = false
            if let projectURL = currentProjectURL {
                appendShareEvent(
                    name: "share_ignored",
                    projectURL: projectURL,
                    properties: ["reason": "active_session"]
                )
            }
            return
        }
        guard let projectURL = currentProjectURL, let splatURL = outputPlyURL else {
            shareStatusMessage = "Finish a project first, then share from this screen."
            shareStatusIsError = true
            return
        }
        let outputState = outputFileState(at: splatURL)
        guard outputState.exists, !outputState.isDirectory else {
            let reason = outputState.isDirectory ? "output_is_directory" : "missing_output_file"
            shareStatusMessage = "Could not find \(splatURL.lastPathComponent). Rebuild or reopen the project."
            shareStatusIsError = true
            appendShareEvent(
                name: "share_unavailable",
                projectURL: projectURL,
                properties: [
                    "reason": reason,
                    "output_file": splatURL.lastPathComponent
                ]
            )
            return
        }

        let metrics = recordShareClicked(projectURL: projectURL)
        let caption = shareCaptionText(for: splatURL)
        let items: [Any] = [caption as NSString, splatURL]

        let shareWindow = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        guard let contentView = shareWindow?.contentView else {
            if copyToPasteboard(caption) {
                shareStatusMessage = "Copied a share caption. Attach \(splatURL.lastPathComponent) to send it."
                shareStatusIsError = false
                appendShareEvent(
                    name: "share_caption_copied",
                    projectURL: projectURL,
                    properties: [
                        "reason": "missing_window",
                        "share_clicked_count": String(metrics.shareClickedCount)
                    ]
                )
            } else {
                shareStatusMessage = "Couldn’t open share options right now. Please try again."
                shareStatusIsError = true
                appendShareEvent(
                    name: "share_unavailable",
                    projectURL: projectURL,
                    properties: [
                        "reason": "pasteboard_write_failed",
                        "share_clicked_count": String(metrics.shareClickedCount)
                    ]
                )
            }
            return
        }

        let picker = NSSharingServicePicker(items: items)
        let session = ShareSession(model: self, projectURL: projectURL)
        activeShareSession = session
        isShareSheetActive = true
        session.present(picker: picker, in: contentView)
        shareStatusMessage = "Share sheet opened. Send your splat to a friend."
        shareStatusIsError = false
        appendShareEvent(
            name: "share_sheet_opened",
            projectURL: projectURL,
            properties: [
                "share_clicked_count": String(metrics.shareClickedCount)
            ]
        )
    }

    func shareServiceSelected(from session: ShareSession, serviceName: String, projectURL: URL) {
        guard activeShareSession === session else { return }
        let normalized = normalizedShareServiceName(serviceName)
        shareStatusMessage = "Sharing via \(normalized)…"
        shareStatusIsError = false
        appendShareEvent(
            name: "share_service_selected",
            projectURL: projectURL,
            properties: ["service": normalized]
        )
    }

    func shareDidComplete(from session: ShareSession, serviceName: String, projectURL: URL) {
        guard activeShareSession === session else { return }
        let normalized = normalizedShareServiceName(serviceName)
        let metrics = mutateShareMetrics(projectURL: projectURL) { metrics in
            metrics.shareCompletedCount += 1
            metrics.lastShareService = normalized
            metrics.lastSharedAt = Date()
        }
        shareStatusMessage = "Shared via \(normalized)."
        shareStatusIsError = false
        appendShareEvent(
            name: "share_completed",
            projectURL: projectURL,
            properties: [
                "service": normalized,
                "share_completed_count": String(metrics.shareCompletedCount)
            ]
        )
    }

    func shareDidFail(from session: ShareSession, serviceName: String, projectURL: URL, error: Error) {
        guard activeShareSession === session else { return }
        let normalized = normalizedShareServiceName(serviceName)
        shareStatusMessage = "Share failed for \(normalized). Try another service."
        shareStatusIsError = true
        appendShareEvent(
            name: "share_failed",
            projectURL: projectURL,
            properties: [
                "service": normalized,
                "error": error.localizedDescription
            ]
        )
    }

    func shareDidCancel(from session: ShareSession, projectURL: URL) {
        guard activeShareSession === session else { return }
        shareStatusMessage = "Share canceled."
        shareStatusIsError = false
        appendShareEvent(name: "share_canceled", projectURL: projectURL)
    }

    func clearShareSession(_ session: ShareSession) {
        if activeShareSession === session {
            activeShareSession = nil
            isShareSheetActive = false
        }
    }

    func syncShareMetrics(for projectURL: URL?) {
        guard let projectURL else {
            shareMetrics = .init()
            return
        }
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        if let metadata = try? ProjectMetadataStore.load(from: metadataURL),
           let persisted = metadata.shareMetrics {
            shareMetrics = persisted
        } else {
            shareMetrics = .init()
        }
    }

    @discardableResult
    func mutateShareMetrics(projectURL: URL, mutation: (inout ShareMetrics) -> Void) -> ShareMetrics {
        if let metadata = mutateProjectMetadata(at: projectURL, mutation: { metadata in
            var metrics = metadata.shareMetrics ?? ShareMetrics()
            mutation(&metrics)
            metadata.shareMetrics = metrics
        }), let persisted = metadata.shareMetrics {
            shareMetrics = persisted
            return persisted
        }

        var fallback = shareMetrics
        mutation(&fallback)
        shareMetrics = fallback
        return fallback
    }

    @discardableResult
    func recordShareClicked(projectURL: URL) -> ShareMetrics {
        let metrics = mutateShareMetrics(projectURL: projectURL) { metrics in
            metrics.shareClickedCount += 1
        }
        appendShareEvent(
            name: "share_clicked",
            projectURL: projectURL,
            properties: ["share_clicked_count": String(metrics.shareClickedCount)]
        )
        return metrics
    }

    func shareCaptionText(for splatURL: URL) -> String {
        let projectLabel = currentProjectURL?.deletingPathExtension().lastPathComponent ?? "my project"
        return """
        I made a 3D memory with EasySplat (\(projectLabel)).
        File: \(splatURL.lastPathComponent)

        Build your own: \(AppConfig.projectHomeURL.absoluteString)
        """
    }

    func normalizedShareServiceName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Share Service" : trimmed
    }

    @discardableResult
    func copyToPasteboard(_ value: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    func appendShareEvent(name: String, projectURL: URL, properties: [String: String] = [:]) {
        let logURL = ProjectPaths(root: projectURL).appEventsLogURL
        let parent = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let event = ShareEventRecord(
            timestamp: Date(),
            event: name,
            properties: properties
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var payload = try? encoder.encode(event) else { return }
        payload.append(0x0A)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: logURL)
        } catch {
            // Surface a single breadcrumb so a user reporting "no share events" can find a clue.
            FileHandle.standardError.write(Data("AppModel+Sharing: failed to open \(logURL.path): \(error.localizedDescription)\n".utf8))
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            FileHandle.standardError.write(Data("AppModel+Sharing: failed to append \(name): \(error.localizedDescription)\n".utf8))
            return
        }
    }
}

private struct ShareEventRecord: Codable {
    let timestamp: Date
    let event: String
    let properties: [String: String]
}

@MainActor
final class ShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private weak var model: AppModel?
    private let projectURL: URL
    /// Keep the picker alive for the duration of the share. NSSharingServicePicker uses a
    /// transient system menu that holds the picker while shown, but retaining it on the
    /// session removes any ambiguity around ARC freeing the local before the user dismisses.
    private var picker: NSSharingServicePicker?

    init(model: AppModel, projectURL: URL) {
        self.model = model
        self.projectURL = projectURL
    }

    func present(picker: NSSharingServicePicker, in sourceView: NSView) {
        picker.delegate = self
        self.picker = picker
        let anchor = NSRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: sourceView, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else {
            model?.shareDidCancel(from: self, projectURL: projectURL)
            model?.clearShareSession(self)
            return
        }
        service.delegate = self
        model?.shareServiceSelected(from: self, serviceName: service.title, projectURL: projectURL)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        model?.shareDidComplete(from: self, serviceName: sharingService.title, projectURL: projectURL)
        model?.clearShareSession(self)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        model?.shareDidFail(from: self, serviceName: sharingService.title, projectURL: projectURL, error: error)
        model?.clearShareSession(self)
    }
}
