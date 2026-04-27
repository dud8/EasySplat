import EasySplatCore
import Foundation

extension AppModel {
    func startFromPendingSelection() {
        guard let inputSpec = buildInputSpec() else { return }
        let title = projectTitle(for: inputSpec)
        clearPendingInputs()
        currentTask?.cancel()
        currentTask = Task { await startProject(input: inputSpec, title: title) }
    }

    func resumeProject(at url: URL) {
        clearRecoveryPromptSuppression(for: url)
        currentTask?.cancel()
        currentTask = Task { await resumeProjectTask(at: url) }
    }

    func resumeInterruptedProject(_ project: ProjectSummary) {
        recoveryPromptProject = nil
        clearRecoveryPromptSuppression(for: project.url)
        currentTask?.cancel()
        currentTask = Task { await resumeProjectTask(at: project.url) }
    }

    func keepInterruptedProjectForLater(_ project: ProjectSummary) {
        suppressRecoveryPrompt(for: project.url)
        if recoveryPromptProject?.id == project.id {
            recoveryPromptProject = nil
        }
    }

    func deleteInterruptedProject(_ project: ProjectSummary) {
        ignoredRecoveryProjectIDs.insert(project.id)
        if recoveryPromptProject?.id == project.id {
            recoveryPromptProject = nil
        }
        if currentProjectURL == project.url {
            cancelCurrentProject(deleteProject: true)
            return
        }
        try? FileManager.default.removeItem(at: project.url)
        refreshProjectSummaries()
    }

    func refreshProjectSummaries() {
        let base = projectBaseDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            projectSummaries = []
            return
        }

        var summaries: [ProjectSummary] = []
        for url in contents where url.pathExtension == "easysplatproj" {
            let metadataURL = url.appendingPathComponent("project.json")
            let metadata: ProjectMetadata
            do {
                metadata = try ProjectMetadataStore.load(from: metadataURL)
            } catch ProjectMetadataStore.LoadError.unsupportedFormatVersion {
                // Surface future-version projects in the listing with a clear hint instead
                // of silently dropping them — otherwise the user sees their project disappear.
                summaries.append(makeNeedsAppUpdateSummary(at: url, metadataURL: metadataURL))
                continue
            } catch {
                continue
            }
            let outputURL = metadata.outputs.map { url.appendingPathComponent($0.splatPlyPath) }
            let outputExists = outputURL.map { regularOutputFileExists(at: $0) } ?? false
            let isActive = currentProjectURL == url && viewState == .processing
            let isRetrying = isActive && metadata.state.lastError != nil
            let hasInterruptionEvidence = metadata.checkpoint != nil || metadata.lastRunStartedAt != nil
            let isInterrupted = !isActive
                && !outputExists
                && metadata.state.lastError == nil
                && metadata.state.stage != .done
                && hasInterruptionEvidence
                && metadata.recoveryPromptSuppressed != true
            let status: ProjectStatus
            if isActive {
                status = .inProgress
            } else if outputExists {
                status = .ready
            } else if metadata.state.lastError != nil {
                status = .failed
            } else {
                status = .inProgress
            }
            summaries.append(ProjectSummary(
                id: metadata.id,
                title: metadata.title,
                url: url,
                createdAt: metadata.createdAt,
                status: status,
                isActive: isActive,
                isRetrying: isRetrying,
                isInterrupted: isInterrupted,
                checkpointUpdatedAt: metadata.checkpoint?.updatedAt,
                lastError: metadata.state.lastError,
                outputPlyURL: outputURL
            ))
        }

        projectSummaries = summaries.sorted { $0.createdAt > $1.createdAt }
        maybePresentInterruptedProjectPrompt()
    }

    func createProjectDirectory(title: String) throws -> URL {
        let fm = FileManager.default
        let base = projectBaseDirectory()
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTitle = title.isEmpty ? "Project" : title
        var projectURL = base.appendingPathComponent("\(safeTitle).easysplatproj", isDirectory: true)
        if fm.fileExists(atPath: projectURL.path) {
            projectURL = base.appendingPathComponent("\(safeTitle)-\(UUID().uuidString.prefix(6)).easysplatproj", isDirectory: true)
        }
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    func projectBaseDirectory() -> URL {
        let fm = FileManager.default
        if let projectBaseURL {
            return projectBaseURL
        }
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return fm.temporaryDirectory.appendingPathComponent("EasySplat Projects", isDirectory: true)
        }
        return docs.appendingPathComponent("EasySplat Projects", isDirectory: true)
    }

    func resumeStage(from metadata: ProjectMetadata) -> PipelineStage? {
        guard metadata.state.lastError == nil else {
            let stages = PipelineStage.allCases
            guard let index = stages.firstIndex(of: metadata.state.stage), index > 0 else {
                return nil
            }
            return stages[index - 1]
        }
        return metadata.state.stage
    }

    func outputFileState(at url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    func regularOutputFileExists(at url: URL) -> Bool {
        let state = outputFileState(at: url)
        return state.exists && !state.isDirectory
    }

    /// Build a minimal summary for a project whose metadata is unreadable due to a
    /// formatVersion mismatch. We pull `title` from a raw JSON peek if possible so the
    /// listing still shows the user's chosen name; otherwise fall back to the directory.
    private func makeNeedsAppUpdateSummary(at url: URL, metadataURL: URL) -> ProjectSummary {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        var title = fallbackTitle
        if let data = try? Data(contentsOf: metadataURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["title"] as? String,
           !raw.isEmpty {
            title = raw
        }
        let createdAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
        return ProjectSummary(
            id: UUID(),
            title: title,
            url: url,
            createdAt: createdAt,
            status: .needsAppUpdate,
            isActive: false,
            isRetrying: false,
            isInterrupted: false,
            checkpointUpdatedAt: nil,
            lastError: nil,
            outputPlyURL: nil
        )
    }
}
