import EasySplatCore
import Foundation

extension AppModel {
    func startFromPendingSelection() {
        guard let inputSpec = buildInputSpec() else { return }
        let title = projectTitle(for: inputSpec)
        clearPendingInputs()
        currentTask?.cancel()
        let token = UUID()
        currentTaskToken = token
        currentTask = Task { await startProject(input: inputSpec, title: title, taskToken: token) }
    }

    func resumeProject(at url: URL) {
        clearRecoveryPromptSuppression(for: url)
        currentTask?.cancel()
        let token = UUID()
        currentTaskToken = token
        currentTask = Task { await resumeProjectTask(at: url, taskToken: token) }
    }

    func resumeInterruptedProject(_ project: ProjectSummary) {
        recoveryPromptProject = nil
        clearRecoveryPromptSuppression(for: project.url)
        currentTask?.cancel()
        let token = UUID()
        currentTaskToken = token
        currentTask = Task { await resumeProjectTask(at: project.url, taskToken: token) }
    }

    func keepInterruptedProjectForLater(_ project: ProjectSummary) {
        suppressRecoveryPrompt(for: project.url)
        if recoveryPromptProject?.id == project.id {
            recoveryPromptProject = nil
        }
    }

    func deleteInterruptedProject(_ project: ProjectSummary) {
        if currentProjectURL == project.url {
            markInterruptedProjectDeleted(project)
            cancelCurrentProject(deleteProject: true)
            return
        }
        do {
            try FileManager.default.removeItem(at: project.url)
            markInterruptedProjectDeleted(project)
        } catch {
            if isMissingFileError(error) {
                markInterruptedProjectDeleted(project)
            } else {
                recoveryPromptProject = project
            }
        }
        refreshProjectSummaries()
    }

    private func markInterruptedProjectDeleted(_ project: ProjectSummary) {
        ignoredRecoveryProjectIDs.insert(project.id)
        if recoveryPromptProject?.id == project.id {
            recoveryPromptProject = nil
        }
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
    }

    func refreshProjectSummaries() {
        let base = projectBaseDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            projectSummaries = []
            return
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
            } catch ProjectMetadataStore.LoadError.unsupportedFormatVersion {
                // Surface future-version projects in the listing with a clear hint instead
                // of silently dropping them — otherwise the user sees their project disappear.
                summaries.append(makeNeedsAppUpdateSummary(at: url, metadataURL: metadataURL))
                continue
            } catch {
                continue
            }
            // Project list refresh runs on the main actor; avoid scanning large ASCII PLY bodies here.
            let outputURL = readyOutputURL(projectURL: url, metadata: metadata, validationDepth: .quick)
            let outputExists = outputURL != nil
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
            let outputSize: Int64? = outputURL.flatMap { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            }
            let errorCount = cachedRecentPipelineErrorCount(at: ProjectPaths(root: url).pipelineLogURL)
            // Prefer the sidecar value (cannot be clobbered by pipeline writes)
            // and fall back to the legacy metadata.lastOpenedAt field for projects
            // that were stamped before the sidecar split.
            let sidecarOpened = LastOpenedSidecar.load(from: ProjectPaths(root: url).lastOpenedSidecarURL)
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
                outputPlyURL: outputURL,
                outputPlySizeBytes: outputSize,
                reconstruction: metadata.reconstruction,
                stageTimings: metadata.stageTimings ?? [],
                preset: metadata.preset,
                lastOpenedAt: sidecarOpened ?? metadata.lastOpenedAt,
                lastFailureAt: metadata.lastFailureAt,
                recentErrorCount: errorCount
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
        ProjectArtifactValidator.validatePlyFile(at: url) == .valid
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
        validationDepth: ProjectArtifactValidationDepth = .full
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
              let outputURL = metadataOutputURL(
                projectURL: projectURL,
                metadata: persistedMetadata
              ) else {
            return nil
        }
        return ProjectArtifactValidator.validatePlyFile(at: outputURL, depth: validationDepth) == .valid ? outputURL : nil
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

    /// Reload the persisted AutoTune snapshot. Returns nil for runs that
    /// pre-date the snapshot feature or that disabled AutoTune.
    func loadAutoTuneSnapshot(projectURL: URL) -> AutoTuneSnapshot? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        return (try? ProjectMetadataStore.load(from: metadataURL))?.autoTune
    }

    /// Reload the persisted preset + input pair for a project. Used by the
    /// viewer to render a "Run configuration" badge alongside the result.
    func loadProjectConfig(projectURL: URL) -> (preset: PresetSpec, input: InputSpec)? {
        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        guard let metadata = try? ProjectMetadataStore.load(from: metadataURL) else { return nil }
        return (metadata.preset, metadata.input)
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

    /// Recommended minimum free space for a single run. The pipeline produces
    /// frame extracts, COLMAP intermediate database, sparse model, and the
    /// trained PLY; on a 30-frame Fast run this stays under 1 GB but Ultra
    /// runs with longer videos can blow past 5 GB. 8 GB is a conservative
    /// cushion that catches "almost full" situations without false alarms.
    static let recommendedFreeSpaceBytes: Int64 = 8 * 1024 * 1024 * 1024

    /// Debounce window for notes auto-save. Tuned so a typing pause of half
    /// a second commits without thrashing disk on every keystroke.
    static let notesAutoSaveDelay: TimeInterval = 0.5

    /// Schedule a debounced save of the project's notes. Cancels any prior
    /// pending save so only the final value in the typing burst lands.
    /// Also remembers the pending (url, text) so a teardown path can flush
    /// the last edit synchronously instead of dropping it.
    func scheduleNotesSave(at url: URL, to text: String) {
        notesSaveTask?.cancel()
        pendingNotesSave = (url: url, text: text)
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
                self.pendingNotesSave = nil
                self.notesSaveTask = nil
                guard self.currentProjectURL == token else { return }
                self.updateProjectNotes(at: token, to: value)
            }
        }
    }

    /// Synchronously write the last pending notes value, cancelling the
    /// debounce timer. Safe to call when no save is pending. Use before
    /// reset(), project switch, or app termination so a half-typed note
    /// doesn't silently disappear.
    func flushPendingNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard let pending = pendingNotesSave else { return }
        pendingNotesSave = nil
        updateProjectNotes(at: pending.url, to: pending.text)
    }

    /// mtime+size-keyed cache wrapper around `countRecentPipelineErrors`.
    /// With 50+ projects the unconditional disk read on every refresh adds
    /// up; log files rarely change between refreshes, so a stat + compare
    /// hits the fast path most of the time. Size is included alongside
    /// mtime because some filesystems only report second-level mtime
    /// resolution; two writes inside the same second would otherwise be
    /// mistaken for a cache hit.
    func cachedRecentPipelineErrorCount(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            // Log absent — drop any stale cache entry and return nil.
            pipelineErrorCountCache[url] = nil
            return nil
        }
        if let cached = pipelineErrorCountCache[url], cached.mtime == mtime, cached.size == size {
            return cached.count
        }
        guard let fresh = AppModel.countRecentPipelineErrors(at: url) else {
            pipelineErrorCountCache[url] = nil
            return nil
        }
        pipelineErrorCountCache[url] = (mtime: mtime, size: size, count: fresh)
        return fresh
    }

    /// Count `[err]` prefixed lines in the tail of a pipeline.log. Uses a
    /// bounded read (default 16 KB) so a multi-megabyte log doesn't stall
    /// the main-actor refresh loop. Returns nil when the log doesn't exist.
    static func countRecentPipelineErrors(at url: URL, byteLimit: Int = 16 * 1024) -> Int? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let readLength = Int(min(Int64(byteLimit), size))
        let offset = UInt64(size) - UInt64(readLength)
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        guard let data = try? handle.read(upToCount: readLength), !data.isEmpty else { return nil }
        // If the seek landed mid-UTF-8 codepoint, drop bytes until we're at a
        // valid leading byte; otherwise decoding fails and we drop the count.
        var trimmed = data
        if offset > 0 {
            while let first = trimmed.first, first & 0b1100_0000 == 0b1000_0000 {
                trimmed.removeFirst()
            }
        }
        guard let text = String(data: trimmed, encoding: .utf8) else { return nil }
        // Also drop the first partial line, since we likely sliced into the
        // middle of one when seeking; otherwise an unrelated "[err]"-containing
        // payload upstream of the cut could double-count.
        var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines.reduce(into: 0) { partial, line in
            if line.hasPrefix("[err]") { partial += 1 }
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
        let metadataURL = ProjectPaths(root: url).metadataURL
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes: String? = trimmed.isEmpty ? nil : trimmed
        // Deliberately do not assign `currentProjectNotes` here. The binding
        // owner (notes editor) drives that property; reassigning the trimmed
        // value back into the binding mid-typing would yank cursor position
        // and drop in-progress whitespace from the user.
        do {
            var didChange = false
            _ = try ProjectMetadataStore.update(at: metadataURL) { metadata in
                guard metadata.notes != newNotes else { return }
                metadata.notes = newNotes
                didChange = true
            }
            return didChange
        } catch {
            // Surface the failure as a non-fatal status so the user knows
            // their typed note didn't make it to disk (typical cause: the
            // project volume filled up mid-run).
            if currentProjectURL == url {
                shareStatusMessage = "Could not save notes: \(error.localizedDescription)"
                shareStatusIsError = true
            }
            return false
        }
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
            return false
        }
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
            outputPlyURL: nil,
            outputPlySizeBytes: nil,
            reconstruction: nil,
            stageTimings: [],
            preset: nil,
            lastOpenedAt: nil,
            lastFailureAt: nil,
            recentErrorCount: nil
        )
    }
}
