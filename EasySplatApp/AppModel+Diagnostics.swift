import AppKit
import EasySplatCore
import Foundation

extension AppModel {
    func copyTechnicalDetails(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        confirmation: @MainActor (String) -> Bool = AppModel.confirmTechnicalDetailsCopy
    ) {
        let sanitized = ProjectDiagnosticBundle.sanitizeForSharing(
            text,
            projectURL: currentProjectURL
        )
        guard confirmation(sanitized) else { return }
        pasteboard.clearContents()
        pasteboard.setString(sanitized, forType: .string)
    }

    /// Build a paste-ready diagnostic summary for the named project and copy it
    /// to the system clipboard. The bundle build (which reads multiple log
    /// files) is dispatched off the main actor so large logs cannot freeze the
    /// UI; the pasteboard write happens back on the main actor.
    func copyDiagnosticBundle(forProjectURL projectURL: URL) {
        actionFailure = nil
        shareStatusMessage = "Preparing diagnostic info…"
        shareStatusIsError = false
        let hardwareLine = AppModel.hardwareSummaryLine()
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) { [projectURL, hardwareLine] in
                ProjectDiagnosticBundle.build(
                    projectURL: projectURL,
                    hardwareLine: hardwareLine
                )
            }.value
            guard let self else { return }
            guard let text else {
                self.shareStatusMessage = "Could not build diagnostic bundle for this project."
                self.shareStatusIsError = true
                self.actionFailure = ActionFailurePresentation(
                    title: "Couldn’t prepare diagnostics",
                    message: "Check the project files and try again."
                )
                return
            }
            guard AppModel.confirmDiagnosticCopy(text) else {
                self.shareStatusMessage = nil
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.shareStatusMessage = "Diagnostic info copied to clipboard."
            self.shareStatusIsError = false
        }
    }

    /// Build the diagnostic bundle and present an NSSavePanel so the user can
    /// drop it into a GitHub issue, Slack thread, etc. as a real file rather
    /// than pasting from the clipboard. Honors `includeNotes` so the
    /// notes-privacy default mirrors the Copy Diagnostics flow. The save
    /// panel exposes an "Include private notes" accessory checkbox so the
    /// user can opt in for a trusted destination without needing a separate
    /// menu item.
    func saveDiagnosticBundle(forProjectURL projectURL: URL, includeNotes: Bool = false) {
        actionFailure = nil
        shareStatusMessage = "Preparing diagnostic file…"
        shareStatusIsError = false
        let hardwareLine = AppModel.hardwareSummaryLine()
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) { [projectURL, hardwareLine, includeNotes] in
                ProjectDiagnosticBundle.build(
                    projectURL: projectURL,
                    hardwareLine: hardwareLine,
                    includeNotes: includeNotes
                )
            }.value
            guard let self else { return }
            guard let text else {
                self.shareStatusMessage = "Could not build diagnostic bundle for this project."
                self.shareStatusIsError = true
                self.actionFailure = ActionFailurePresentation(
                    title: "Couldn’t prepare diagnostics",
                    message: "Check the project files and try again."
                )
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = AppModel.diagnosticBundleFileName(for: projectURL)
            panel.canCreateDirectories = true

            let includeNotesCheckbox = NSButton(checkboxWithTitle: "Include private notes (off by default)", target: nil, action: nil)
            includeNotesCheckbox.state = includeNotes ? .on : .off
            let accessory = NSStackView(views: [includeNotesCheckbox])
            accessory.orientation = .horizontal
            accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            accessory.translatesAutoresizingMaskIntoConstraints = false
            panel.accessoryView = accessory

            let response = panel.runModal()
            guard response == .OK, let destination = panel.url else {
                self.shareStatusMessage = "Diagnostic save canceled."
                self.shareStatusIsError = false
                return
            }
            let finalText: String
            if includeNotesCheckbox.state == .on, !includeNotes {
                // User opted in via the accessory; rebuild with notes off the main actor.
                finalText = await Task.detached(priority: .userInitiated) { [projectURL, hardwareLine] in
                    ProjectDiagnosticBundle.build(
                        projectURL: projectURL,
                        hardwareLine: hardwareLine,
                        includeNotes: true
                    )
                }.value ?? text
            } else {
                finalText = text
            }
            guard AppModel.confirmDiagnosticSave(finalText) else {
                self.shareStatusMessage = nil
                return
            }
            do {
                // The panel closed several awaits ago; its grant on the chosen file
                // has to be open again for the atomic write to land.
                let destinationAccess = SecurityScopedAccess()
                destinationAccess.claim([destination])
                defer { destinationAccess.releaseAll() }
                try finalText.data(using: .utf8)?.write(to: destination, options: [.atomic])
                self.shareStatusMessage = "Diagnostics saved to \(destination.lastPathComponent)."
                self.shareStatusIsError = false
            } catch {
                self.shareStatusMessage = "Failed to save diagnostics: \(error.localizedDescription)"
                self.shareStatusIsError = true
                self.actionFailure = ActionFailurePresentation(
                    title: "Couldn’t save diagnostics",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Timestamped default filename used in the Save Diagnostics panel.
    static func diagnosticBundleFileName(for projectURL: URL) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "easysplat-diagnostic-\(formatter.string(from: Date())).md"
    }

    static func confirmDiagnosticCopy(_ text: String) -> Bool {
        confirmDiagnosticPayload(
            text,
            message: "Review Diagnostics",
            actionTitle: "Copy"
        )
    }

    static func confirmDiagnosticSave(_ text: String) -> Bool {
        confirmDiagnosticPayload(
            text,
            message: "Review Diagnostics",
            actionTitle: "Save"
        )
    }

    static func confirmTechnicalDetailsCopy(_ text: String) -> Bool {
        confirmDiagnosticPayload(
            text,
            message: "Review Details",
            actionTitle: "Copy",
            informativeText: "Local identity, removable-volume names, and URL credentials have been removed."
        )
    }

    private static func confirmDiagnosticPayload(
        _ text: String,
        message: String,
        actionTitle: String,
        informativeText: String = "Check the details before continuing. Notes are excluded unless you add them explicitly."
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 280))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.setAccessibilityLabel("Diagnostic preview")

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        alert.accessoryView = scrollView

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// One-line hardware description suitable for embedding in diagnostic dumps.
    /// Captures macOS version + architecture without leaking the username.
    static func hardwareSummaryLine() -> String {
        let process = ProcessInfo.processInfo
        let memoryGB = Double(process.physicalMemory) / 1_073_741_824.0
        let cpu = process.activeProcessorCount
        let version = process.operatingSystemVersionString
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #else
        arch = "unknown"
        #endif
        return String(format: "%@ on %@ (%d cores, %.1f GB RAM)", version, arch, cpu, memoryGB)
    }
}
