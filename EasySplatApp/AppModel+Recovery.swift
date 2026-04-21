import EasySplatCore
import Foundation

extension AppModel {
    func maybePresentInterruptedProjectPrompt() {
        guard viewState == .home else { return }
        if let current = recoveryPromptProject,
           let matching = projectSummaries.first(where: { $0.id == current.id }),
           isRecoveryPromptCandidate(matching) {
            recoveryPromptProject = matching
            return
        }
        let next = projectSummaries.first(where: { isRecoveryPromptCandidate($0) })
        recoveryPromptProject = next
    }

    private func isRecoveryPromptCandidate(_ summary: ProjectSummary) -> Bool {
        summary.isInterrupted && !summary.isActive && !ignoredRecoveryProjectIDs.contains(summary.id)
    }

    @discardableResult
    func mutateProjectMetadata(
        at projectURL: URL,
        mutation: (inout ProjectMetadata) -> Void
    ) -> ProjectMetadata? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        guard var metadata = try? ProjectMetadataStore.load(from: metadataURL) else {
            return nil
        }
        mutation(&metadata)
        do {
            try ProjectMetadataStore.save(metadata, to: metadataURL)
            return metadata
        } catch {
            return nil
        }
    }

    func metadataID(for projectURL: URL) -> UUID? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.id
    }

    func suppressRecoveryPrompt(for projectURL: URL, clearLastRunStartedAt: Bool = false) {
        let id: UUID?
        if let metadata = mutateProjectMetadata(at: projectURL, mutation: { metadata in
            metadata.recoveryPromptSuppressed = true
            if clearLastRunStartedAt {
                metadata.lastRunStartedAt = nil
            }
        }) {
            id = metadata.id
        } else {
            id = metadataID(for: projectURL)
        }
        guard let id else { return }
        ignoredRecoveryProjectIDs.insert(id)
        if recoveryPromptProject?.id == id {
            recoveryPromptProject = nil
        }
    }

    func clearRecoveryPromptSuppression(for projectURL: URL) {
        let id: UUID?
        if let metadata = mutateProjectMetadata(at: projectURL, mutation: { metadata in
            metadata.recoveryPromptSuppressed = false
        }) {
            id = metadata.id
        } else {
            id = metadataID(for: projectURL)
        }
        guard let id else { return }
        ignoredRecoveryProjectIDs.remove(id)
    }
}
