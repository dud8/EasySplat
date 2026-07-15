import EasySplatCore
import Foundation
import OSLog

private let projectLibraryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.easysplat.app",
    category: "ProjectLibrary"
)

extension AppModel {
    func startFromPendingSelection() {
        guard !isRunActive else { return }
        guard let inputSpec = buildInputSpec() else { return }
        photoFolderCountTask?.cancel()
        photoFolderCountTask = nil
        let title = projectTitle(for: inputSpec)
        let token = UUID()
        currentTaskToken = token
        isRunActive = true
        currentTask = Task { await startProject(input: inputSpec, title: title, taskToken: token) }
    }

    @discardableResult
    func resumeProject(at url: URL) -> Bool {
        guard !isRunActive else { return false }
        guard flushPendingNotesSave() else { return false }
        let token = UUID()
        currentTaskToken = token
        isRunActive = true
        currentTask = Task { await resumeProjectTask(at: url, taskToken: token) }
        return true
    }

    static func validationRecovery(for error: RunPlanResolver.ValidationError) -> RunValidationRecovery? {
        switch error {
        case .continuousMultipleClipsUnsupported:
            return .useUnordered
        case .fastDetailRequired:
            return .useFast
        case .highDetailRequiresMoreMemory:
            return .useBalanced
        case .noValidPhotos:
            return nil
        case .photoSelectionExceedsSafeLimit:
            return .useAutomaticPhotoSelection
        }
    }

    static func rasterMemoryRecovery(
        requestedOptions: RequestedRunOptions,
        currentBudgetBytes: Int64,
        hardware: HardwareProfile
    ) -> RunValidationRecovery? {
        let largerBudgets = [
            TrainingMemoryBudget.resolve(hardware: hardware, resourcePolicy: .automatic),
            TrainingMemoryBudget.resolve(hardware: hardware, resourcePolicy: .maximumPerformance),
        ]
            .filter { $0 > currentBudgetBytes }
            .sorted()
        if let nextBudget = largerBudgets.first {
            return .useMoreTrainingMemory(nextBudget)
        }
        if requestedOptions.detailProfile == .highDetail {
            return .useBalanced
        }
        if requestedOptions.detailProfile != .fast {
            return .useFastForMemory
        }
        return nil
    }

    static func rasterResourceRecovery(
        requestedOptions: RequestedRunOptions
    ) -> RunValidationRecovery? {
        switch requestedOptions.detailProfile {
        case .highDetail:
            return .useBalanced
        case .balanced:
            return .useFastForMemory
        case .fast:
            return nil
        }
    }

    func configureRuntimeRecovery(for error: Error) {
        let options = currentRunOptions ?? requestedRunOptions
        if error is MsplatRasterResourceLimitExceeded {
            let recovery = Self.rasterResourceRecovery(requestedOptions: options)
            validationRecovery = recovery
            failureRetryAllowed = recovery != nil
            let message: String = switch recovery {
            case .useBalanced:
                "This scene exceeded Metal's buffer limit. Use Balanced detail."
            case .useFastForMemory:
                "This scene exceeded Metal's buffer limit. Use Fast detail."
            case nil:
                "This scene exceeded Metal's buffer limit even at Fast detail."
            case .useMoreTrainingMemory, .useUnordered, .useFast, .useAutomaticPhotoSelection:
                preconditionFailure("Unexpected recovery for a raster resource limit")
            }
            lastError = message
            statusTitle = message
            statusDetail = nil
            return
        }
        guard error is MsplatRasterMemoryBudgetExceeded else { return }
        let currentBudget = currentProjectURL
            .flatMap { try? ProjectMetadataStore.load(from: ProjectPaths(root: $0).metadataURL) }
            .flatMap(\.resolvedRunPlan)
            .map(\.trainerMemoryBudgetBytes)
            ?? TrainingMemoryBudget.resolve(
                hardware: hardwareProfile,
                resourcePolicy: options.resourcePolicy
            )
        let recovery = Self.rasterMemoryRecovery(
            requestedOptions: options,
            currentBudgetBytes: currentBudget,
            hardware: hardwareProfile
        )
        validationRecovery = recovery
        failureRetryAllowed = recovery != nil
        let message: String = switch recovery {
        case .useMoreTrainingMemory:
            "Training needs more memory than this run allows. Use more unified memory."
        case .useFastForMemory:
            "Training needs more memory than this run allows. Use Fast detail."
        case nil:
            "Training needs more memory than this Mac can safely use for this scene."
        case .useBalanced:
            "Training needs more memory than this run allows. Use Balanced detail."
        case .useUnordered, .useFast, .useAutomaticPhotoSelection:
            preconditionFailure("Unexpected recovery for a raster memory failure")
        }
        lastError = message
        statusTitle = message
        statusDetail = nil
    }

    @discardableResult
    func applyValidationRecovery(
        _ recovery: RunValidationRecovery,
        projectURL: URL?
    ) -> Bool {
        if case .useMoreTrainingMemory(let budgetBytes) = recovery {
            guard let projectURL,
                  budgetBytes > 0,
                  mutateProjectMetadata(at: projectURL, mutation: { metadata in
                      metadata.trainingMemoryRetryBudgetBytes = budgetBytes
                  }) != nil else {
                statusTitle = "Couldn’t update the training plan"
                statusDetail = "The project was not changed. Check folder permissions and try again."
                lastError = statusTitle
                return false
            }
            return true
        }
        if let projectURL {
            let updated = mutateProjectMetadata(at: projectURL) { metadata in
                var options = metadata.requestedRunOptions
                recovery.apply(to: &options)
                if !RunPlanResolver.supports(
                    resourcePolicy: options.resourcePolicy,
                    memoryGB: hardwareProfile.memoryGB
                ) {
                    options.resourcePolicy = .automatic
                }
                metadata.requestedRunOptions = options
            }
            guard updated != nil else {
                statusTitle = "Couldn’t update project options"
                statusDetail = "The project was not changed. Check folder permissions and try again."
                lastError = statusTitle
                return false
            }
            return true
        }

        recovery.apply(to: &requestedRunOptions)
        if !RunPlanResolver.supports(
            resourcePolicy: requestedRunOptions.resourcePolicy,
            memoryGB: hardwareProfile.memoryGB
        ) {
            requestedRunOptions.resourcePolicy = .automatic
        }
        return true
    }

    func retryAfterFailure() {
        guard failureRetryAllowed else { return }
        let projectURL = currentProjectURL
        if let recovery = validationRecovery {
            guard applyValidationRecovery(recovery, projectURL: projectURL) else { return }
            validationRecovery = nil
        }
        if let projectURL {
            resumeProject(at: projectURL)
        } else {
            startFromPendingSelection()
        }
    }

    func refreshProjectSummaries() {
        projectSummaryRefreshTask?.cancel()
        projectSummaryRefreshTask = nil
        projectSummaries = Self.loadProjectSummaries(
            from: projectBaseDirectory(),
            currentProjectURL: currentProjectURL,
            isRunActive: isRunActive
        )
    }

    func refreshProjectSummariesInBackground() {
        projectSummaryRefreshTask?.cancel()
        let base = projectBaseDirectory()
        let activeProjectURL = currentProjectURL
        let runIsActive = isRunActive
        projectSummaryRefreshTask = Task { [weak self] in
            let summaries = await Task.detached(priority: .utility) {
                Self.loadProjectSummaries(
                    from: base,
                    currentProjectURL: activeProjectURL,
                    isRunActive: runIsActive
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.projectSummaries = summaries
            self?.projectSummaryRefreshTask = nil
        }
    }

    nonisolated private static func loadProjectSummaries(
        from base: URL,
        currentProjectURL: URL?,
        isRunActive: Bool
    ) -> [ProjectSummary] {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var summaries: [ProjectSummary] = []
        for url in contents where url.pathExtension == "easysplatproj" {
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            let metadataURL = url.appendingPathComponent("project.json")
            let metadata: ProjectMetadata
            do {
                metadata = try ProjectMetadataStore.load(from: metadataURL)
            } catch {
                projectLibraryLogger.notice(
                    "Skipping unreadable project at \(url.path, privacy: .private): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            let outputURL = readyOutputURLOnDisk(
                projectURL: url,
                metadata: metadata,
                validationDepth: .quick
            )
            let outputExists = outputURL != nil
            let isActive = ProjectSummary.hasSameLocation(currentProjectURL, url)
                && isRunActive
            let hasInterruptionEvidence = metadata.checkpoint != nil || metadata.lastRunStartedAt != nil
            let isInterrupted = !isActive
                && !outputExists
                && metadata.state.lastError == nil
                && metadata.state.stage != .done
                && hasInterruptionEvidence
            let status: ProjectStatus
            if isActive {
                status = .inProgress
            } else if outputExists {
                status = .ready
            } else if metadata.state.lastError != nil {
                status = .failed
            } else if metadata.state.stage == .done {
                status = .failed
            } else {
                status = .inProgress
            }
            let sidecarOpened = LastOpenedSidecar.load(from: ProjectPaths(root: url).lastOpenedSidecarURL)
            summaries.append(ProjectSummary(
                id: metadata.id,
                title: metadata.title,
                url: url,
                createdAt: metadata.createdAt,
                status: status,
                isActive: isActive,
                isInterrupted: isInterrupted,
                checkpointUpdatedAt: metadata.checkpoint?.updatedAt,
                stageTimings: metadata.stageTimings ?? [],
                input: metadata.input,
                requestedRunOptions: metadata.requestedRunOptions,
                lastOpenedAt: sidecarOpened,
                lastRunStartedAt: metadata.lastRunStartedAt,
                lastFailureAt: metadata.lastFailureAt
            ))
        }

        return summaries.sorted { $0.createdAt > $1.createdAt }
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

    func metadataOutputURL(projectURL: URL, metadata: ProjectMetadata? = nil) -> URL? {
        let loadedMetadata: ProjectMetadata
        if let metadata {
            loadedMetadata = metadata
        } else {
            guard let metadata = try? ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL) else {
                return nil
            }
            loadedMetadata = metadata
        }
        guard let relativePath = loadedMetadata.outputs?.splatPlyPath else { return nil }
        let paths = ProjectPaths(root: projectURL)
        guard let outputURL = try? paths.resolveProjectRelativePath(relativePath) else { return nil }
        return outputURL
    }

    func readyOutputURL(
        projectURL: URL,
        metadata: ProjectMetadata? = nil,
        validationDepth: ProjectArtifactValidationDepth
    ) -> URL? {
        Self.readyOutputURLOnDisk(
            projectURL: projectURL,
            metadata: metadata,
            validationDepth: validationDepth
        )
    }

    nonisolated static func readyOutputURLOnDisk(
        projectURL: URL,
        metadata: ProjectMetadata? = nil,
        validationDepth: ProjectArtifactValidationDepth
    ) -> URL? {
        let persistedMetadata: ProjectMetadata
        if let metadata {
            persistedMetadata = metadata
        } else {
            guard let loaded = try? ProjectMetadataStore.load(
                from: ProjectPaths(root: projectURL).metadataURL
            ) else { return nil }
            persistedMetadata = loaded
        }
        guard persistedMetadata.state.stage == .done,
              persistedMetadata.state.lastError == nil,
              let relativePath = persistedMetadata.outputs?.splatPlyPath,
              let outputURL = try? ProjectPaths(root: projectURL)
                .resolveProjectRelativePath(relativePath) else {
            return nil
        }
        switch validationDepth {
        case .quick:
            guard ProjectArtifactValidator.validatePlyFile(at: outputURL, depth: .quick) == .valid else {
                return nil
            }
        case .full:
            if let trainingArtifact = persistedMetadata.trainingArtifact {
                do {
                    try TrainingArtifactStore.validateCompletedOutput(
                        trainingArtifact,
                        at: outputURL
                    )
                } catch {
                    return nil
                }
            } else if ProjectArtifactValidator.validatePlyFile(at: outputURL) != .valid {
                return nil
            }
        }
        return outputURL
    }

    func validatedFinishedOutputURL(projectURL: URL) async throws -> URL? {
        let validator = finishedOutputValidator
        let validationTask = Task.detached(priority: .userInitiated) {
            validator(projectURL)
        }
        return try await withTaskCancellationHandler {
            let outputURL = await validationTask.value
            try Task.checkCancellation()
            return outputURL
        } onCancel: {
            validationTask.cancel()
        }
    }

    /// Reload the persisted reconstruction summary for a project from disk. The pipeline
    /// writes the summary as part of `metadata.reconstruction`, so we just decode the
    /// current project.json.
    func loadReconstructionSummary(projectURL: URL) -> ReconstructionSummary? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.reconstruction
    }

    /// Reload the persisted per-stage timings. Returns an empty array when no timings
    /// have been recorded yet so callers can drive UI state with a single property.
    func loadStageTimings(projectURL: URL) -> [StageTimingRecord] {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.stageTimings ?? []
    }

    func loadProjectConfig(projectURL: URL) -> (options: RequestedRunOptions, input: InputSpec)? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        guard let metadata = try? ProjectMetadataStore.load(from: metadataURL) else { return nil }
        return (metadata.requestedRunOptions, metadata.input)
    }

    /// Free disk space on the volume that hosts the project base directory.
    /// Returns nil when the system cannot report capacity (e.g., a read-only
    /// mount or a permission error). Callers should treat nil as "don't warn".
    /// This is a fresh stat call; the cheap path for SwiftUI consumers is
    /// `cachedFreeDiskBytes` which is refreshed by `refreshFreeDiskSpace`.
    func freeDiskSpaceBytes() -> Int64? {
        let baseURL = projectBaseDirectory()
        let fm = FileManager.default
        try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        do {
            let attrs = try fm.attributesOfFileSystem(forPath: baseURL.path)
            return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        } catch {
            return nil
        }
    }

    /// Probe the project volume on a background task and update the cached
    /// value so SwiftUI render bodies never call into `attributesOfFileSystem`
    /// directly. Safe to call from the main actor.
    func refreshFreeDiskSpace() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let base = await self.projectBaseDirectory()
            let fm = FileManager.default
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let bytes: Int64? = {
                guard let attrs = try? fm.attributesOfFileSystem(forPath: base.path) else { return nil }
                return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            }()
            await MainActor.run {
                self.cachedFreeDiskBytes = bytes
            }
        }
    }

    /// Leaves room for selected frames, accepted geometry, checkpoints, and output.
    static let recommendedFreeSpaceBytes: Int64 = 8 * 1024 * 1024 * 1024

    static let notesAutoSaveDelay: TimeInterval = 0.5

    /// Schedule a debounced save of the project's notes. Cancels any prior
    /// pending save so only the final value in the typing burst lands.
    /// Also remembers the pending (url, text) so a teardown path can flush
    /// the last edit synchronously instead of dropping it.
    func scheduleNotesSave(at url: URL, to text: String) {
        notesSaveTask?.cancel()
        pendingNotesSave = (url: url, text: text)
        notesSaveState = .saving
        let token = url
        let value = text
        notesSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(AppModel.notesAutoSaveDelay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard ProjectSummary.hasSameLocation(self.currentProjectURL, token) else { return }
                guard let pending = self.pendingNotesSave,
                      ProjectSummary.hasSameLocation(pending.url, token),
                      pending.text == value else {
                    return
                }
                self.notesSaveTask = nil
                do {
                    _ = try self.persistProjectNotes(at: token, text: value)
                    self.pendingNotesSave = nil
                    self.notesSaveState = .saved
                } catch {
                    self.presentNotesSaveFailure(projectURL: token)
                }
            }
        }
    }

    /// Synchronously write the last pending notes value, cancelling the
    /// debounce timer. Safe to call when no save is pending. Use before
    /// reset(), project switch, or app termination so a half-typed note
    /// doesn't silently disappear.
    @discardableResult
    func flushPendingNotesSave() -> Bool {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard let pending = pendingNotesSave else { return true }
        do {
            _ = try persistProjectNotes(at: pending.url, text: pending.text)
            pendingNotesSave = nil
            notesSaveState = .saved
            return true
        } catch {
            presentNotesSaveFailure(projectURL: pending.url)
            return false
        }
    }

    /// Stamp the project as opened-by-the-user at this moment so the home
    /// list can sort by real interaction instead of pipeline-derived signals.
    /// Writes to a sidecar file so it cannot clobber concurrent pipeline
    /// writes to project.json. Silent no-op on file errors.
    func markProjectOpened(at url: URL, at moment: Date = Date()) {
        let sidecar = ProjectPaths(root: url).lastOpenedSidecarURL
        try? LastOpenedSidecar.save(moment, to: sidecar)
    }

    /// Persist a free-text note on the named project. Trims whitespace and
    /// treats empty input as "clear the note" (writes nil) so the UI does
    /// not have to special-case it. Returns false when the project metadata
    /// can't be loaded or when the new note matches the existing one.
    @discardableResult
    func updateProjectNotes(at url: URL, to text: String) -> Bool {
        do {
            let didChange = try persistProjectNotes(at: url, text: text)
            if ProjectSummary.hasSameLocation(currentProjectURL, url) {
                notesSaveState = .saved
            }
            return didChange
        } catch {
            presentNotesSaveFailure(projectURL: url)
            return false
        }
    }

    private func persistProjectNotes(at url: URL, text: String) throws -> Bool {
        let metadataURL = ProjectPaths(root: url).metadataURL
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes: String? = trimmed.isEmpty ? nil : trimmed
        // Deliberately do not assign `currentProjectNotes` here. The binding
        // owner (notes editor) drives that property; reassigning the trimmed
        // value back into the binding mid-typing would yank cursor position
        // and drop in-progress whitespace from the user.
        var didChange = false
        _ = try ProjectMetadataStore.update(at: metadataURL) { metadata in
            guard metadata.notes != newNotes else { return }
            metadata.notes = newNotes
            didChange = true
        }
        return didChange
    }

    private func presentNotesSaveFailure(projectURL: URL) {
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL)
                || pendingNotesSave.map({ ProjectSummary.hasSameLocation($0.url, projectURL) }) == true else {
            return
        }
        let message = "The last edit is still waiting to be saved. Check free space and folder permissions, then try again."
        notesSaveState = .failed(message)
        actionFailure = ActionFailurePresentation(
            title: "Couldn’t save notes",
            message: message
        )
    }

    func loadProjectNotes(projectURL: URL) -> String {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.notes ?? ""
    }

    /// Rename a project in place. Updates the persisted `title` field in
    /// project.json but does NOT rename the on-disk bundle directory so
    /// project URLs stay stable for live runs and other tooling. Returns
    /// false if the rename was a no-op (empty new title, identical title,
    /// or metadata unreadable).
    @discardableResult
    func renameProject(at url: URL, to newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        actionFailure = nil
        let metadataURL = ProjectPaths(root: url).metadataURL
        do {
            var didChange = false
            _ = try ProjectMetadataStore.update(at: metadataURL) { metadata in
                guard metadata.title != trimmed else { return }
                metadata.title = trimmed
                didChange = true
            }
            guard didChange else { return false }
            refreshProjectSummaries()
            return true
        } catch {
            actionFailure = ActionFailurePresentation(
                title: "Couldn’t rename project",
                message: "The project name wasn’t changed. Check folder permissions and try again."
            )
            return false
        }
    }

}
