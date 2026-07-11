import AppKit
import EasySplatCore
import Foundation

extension AppModel {
    func isCurrentTaskToken(_ taskToken: UUID?) -> Bool {
        currentTaskToken == taskToken
    }

    func cancelCurrentProject(deleteProject: Bool, exitIntent: ExitIntent = .none, window: NSWindow? = nil) {
        if exitIntent != .none {
            self.exitIntent = exitIntent
            self.pendingCloseWindow = window
        }

        if !deleteProject,
           exitIntent != .none,
           isBrushSnapshotTrainingActive,
           let projectURL = currentProjectURL {
            let snapshotURL = ProjectPaths(root: projectURL)
                .trainingURL
                .appendingPathComponent("latest_snapshot.ply")
            pendingSnapshotRevealURL = snapshotURL
            pendingSnapshotRevealRequiresExit = true
        }

        guard currentTask != nil else {
            let projectURL = currentProjectURL
            if !deleteProject, let projectURL {
                suppressRecoveryPrompt(for: projectURL, clearLastRunStartedAt: true)
            }
            currentTaskToken = nil
            reset()
            viewState = .home
            if deleteProject, let projectURL {
                try? FileManager.default.removeItem(at: projectURL)
            }
            refreshProjectSummaries()
            finalizeExitIfNeeded()
            return
        }

        stopAction = deleteProject ? .deleteProject : .keepProject
        lastError = nil
        errorDetails = nil
        if deleteProject {
            statusTitle = "Stopping and deleting…"
            statusDetail = "Stopping at the next safe point (up to 15 seconds)…"
        } else if isBrushSnapshotTrainingActive {
            statusTitle = "Exporting snapshot…"
            statusDetail = "Exporting the latest snapshot (training restarts from scratch on resume)."
        } else if isTrainingStageActive {
            statusTitle = "Saving project…"
            statusDetail = "Stopping training at the next safe point (resume starts training over)."
        } else {
            statusTitle = "Saving progress…"
            statusDetail = "Stopping at the next safe point (up to 15 seconds)…"
        }
        progress = nil
        currentTask?.cancel()
        scheduleForcedExitIfNeeded()
    }

    func awaitTrainingConsent() async -> Bool {
        if UserDefaults.standard.bool(forKey: Self.trainingConsentRememberedKey) {
            return true
        }
        if trainingConsentContinuation != nil || Task.isCancelled {
            return false
        }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                trainingConsentContinuation = continuation
                isShowingTrainingConsent = true
                if stage == .trainBrush, trainingConsentPauseStartedAt == nil {
                    trainingConsentPauseStartedAt = Date()
                }
            }
        }, onCancel: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.resolveTrainingConsent(accepted: false, remember: false)
            }
        })
    }

    func resolveTrainingConsent(accepted: Bool, remember: Bool) {
        guard let continuation = trainingConsentContinuation else { return }
        trainingConsentContinuation = nil
        isShowingTrainingConsent = false
        if let pauseStartedAt = trainingConsentPauseStartedAt {
            trainingConsentPausedDuration += Date().timeIntervalSince(pauseStartedAt)
            trainingConsentPauseStartedAt = nil
        }
        if remember && accepted {
            UserDefaults.standard.set(true, forKey: Self.trainingConsentRememberedKey)
        }
        continuation.resume(returning: accepted)
    }

    func elapsedSinceStageStart(now: Date) -> TimeInterval? {
        guard let startedAt = stageStartedAt else { return nil }
        var pausedDuration = trainingConsentPausedDuration
        if let pauseStartedAt = trainingConsentPauseStartedAt {
            pausedDuration += now.timeIntervalSince(pauseStartedAt)
        }
        let elapsed = now.timeIntervalSince(startedAt) - pausedDuration
        return max(0, elapsed)
    }

    func presentExitConfirmation() -> ExitDecision {
        let isTraining = isTrainingStageActive
        let canExportSnapshot = isBrushSnapshotTrainingActive
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isTraining ? "Training in progress" : "Stop this project?"
        if canExportSnapshot {
            alert.informativeText = "Exporting keeps only a snapshot. If you resume, training starts over from scratch."
        } else if isTraining {
            alert.informativeText = "You can save progress, but training starts over if you resume later."
        } else {
            alert.informativeText = "You can save and resume later, or delete the project."
        }
        let saveButton = alert.addButton(withTitle: canExportSnapshot ? "Export Snapshot" : "Save Project")
        saveButton.keyEquivalent = "\r"
        let deleteButton = alert.addButton(withTitle: "Delete Project")
        deleteButton.hasDestructiveAction = true
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .delete
        default:
            return .cancel
        }
    }

    func registerExitIntent(_ intent: ExitIntent, window: NSWindow? = nil) {
        exitIntent = intent
        pendingCloseWindow = window
        if isStopping {
            scheduleForcedExitIfNeeded()
        }
    }

    func consumeWindowCloseBypass(for window: NSWindow) -> Bool {
        guard allowNextWindowClose, pendingCloseWindow === window else { return false }
        allowNextWindowClose = false
        pendingCloseWindow = nil
        exitIntent = .none
        return true
    }

    func makeTrainingGate() -> (@Sendable () async throws -> Void) {
        let modelBox = WeakAppModelBox(self)
        return {
            guard let model = modelBox.value else { return }
            let allowed = await model.awaitTrainingConsent()
            if !allowed {
                await model.cancelCurrentProject(deleteProject: false)
                throw CancellationError()
            }
        }
    }

    func scheduleForcedExitIfNeeded() {
        guard exitIntent != .none else { return }
        forcedExitTask?.cancel()
        let intent = exitIntent
        forcedExitTask = Task { [weak self, weak window = pendingCloseWindow] in
            try? await Task.sleep(nanoseconds: Self.forcedExitTimeoutNanoseconds)
            await MainActor.run {
                guard let self else { return }
                guard self.stopAction != nil else { return }
                self.forceFinalizeExit(intent: intent, window: window)
            }
        }
    }

    func cancelForcedExitIfNeeded() {
        forcedExitTask?.cancel()
        forcedExitTask = nil
    }

    func forceFinalizeExit(intent: ExitIntent, window: NSWindow?) {
        switch intent {
        case .none:
            return
        case .quit:
            exitIntent = .none
            pendingCloseWindow = nil
            NSApp.reply(toApplicationShouldTerminate: true)
            NSApp.terminate(nil)
        case .closeWindow:
            if let window {
                allowNextWindowClose = true
                window.performClose(nil)
            } else {
                exitIntent = .none
                pendingCloseWindow = nil
            }
        }
    }

    func finalizeExitIfNeeded() {
        cancelForcedExitIfNeeded()
        switch exitIntent {
        case .none:
            break
        case .quit:
            exitIntent = .none
            pendingCloseWindow = nil
            NSApp.reply(toApplicationShouldTerminate: true)
            NSApp.terminate(nil)
        case .closeWindow:
            if let window = pendingCloseWindow {
                allowNextWindowClose = true
                window.performClose(nil)
            }
        }
    }

    func presentSnapshotRevealIfAvailable(_ snapshotURL: URL) {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Snapshot exported"
        alert.informativeText = "You can open the snapshot in Finder before exiting."
        alert.addButton(withTitle: "Open in Finder")
        alert.addButton(withTitle: "Continue")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([snapshotURL])
        }
    }

    func startProject(input: InputSpec, title: String, taskToken: UUID? = nil) async {
        guard isCurrentTaskToken(taskToken) else { return }
        defer {
            if currentTaskToken == taskToken {
                currentTask = nil
                currentTaskToken = nil
                if stopAction != nil {
                    completeStop()
                }
            }
        }
        reset()
        viewState = .processing
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil

        do {
            let projectURL = try createProjectDirectory(title: title)
            currentProjectURL = projectURL
            let metadata = ProjectMetadata(
                title: projectURL.deletingPathExtension().lastPathComponent,
                input: input,
                preset: PresetSpec(mode: captureMode, quality: qualityPreset)
            )
            let paths = ProjectPaths(root: projectURL)
            try paths.ensureDirectories()
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
            currentPreset = metadata.preset
            currentInput = input
            syncShareMetrics(for: projectURL)

            // Keep the Mac awake for the whole flow, including the first-run toolchain
            // download, which happens before the runner (and its own assertion) exists.
            let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is preparing and processing a project")
            defer { idleSleepAssertion.release() }

            statusTitle = "Downloading tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self, taskToken: taskToken)
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                targetName: "macos-arm64"
            ) { fraction, message in
                progressForwarder.update(fraction: fraction, message: message)
            }
            guard isCurrentTaskToken(taskToken) else { return }
            toolchainPaths = toolchain

            let runner = pipelineRunnerFactory(
                projectURL,
                pipelineConfig(toolchain: toolchain, preset: metadata.preset)
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            try await runner.run(resumeFrom: Optional<PipelineStage>.none) { event in
                forwarder.handle(event)
            }
            guard isCurrentTaskToken(taskToken) else { return }

            guard let outputURL = readyOutputURL(projectURL: projectURL) else {
                presentOutputMissingFailure(projectURL: projectURL)
                return
            }
            outputPlyURL = outputURL
            currentReconstruction = loadReconstructionSummary(projectURL: projectURL)
            currentStageTimings = loadStageTimings(projectURL: projectURL)
            currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
            currentAutoTune = loadAutoTuneSnapshot(projectURL: projectURL)
            if let config = loadProjectConfig(projectURL: projectURL) {
                currentPreset = config.preset
                currentInput = config.input
            } else {
                currentPreset = nil
                currentInput = nil
            }
            currentProjectNotes = loadProjectNotes(projectURL: projectURL)
            markProjectOpened(at: projectURL)
            syncShareMetrics(for: projectURL)
            viewState = .viewer
            refreshProjectSummaries()
            refreshFreeDiskSpace()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTaskToken(taskToken) else { return }
            if stopAction != nil {
                return
            }
            let failureMessage = lastError ?? error.localizedDescription
            if lastError == nil {
                lastError = failureMessage
            }
            persistProjectFailure(failureMessage, at: currentProjectURL)
            let envDetails = """
            Underlying error: \(String(reflecting: error))
            Manifest URL: \(AppConfig.toolchainManifestURL.absoluteString)
            Public key present: \(!AppConfig.toolchainPublicKeyBase64.isEmpty)
            """
            if let existing = errorDetails, !existing.isEmpty {
                errorDetails = existing + "\n\n" + envDetails
            } else {
                errorDetails = envDetails
            }
            if statusTitle == "Preparing project" || statusTitle == "Downloading tools" || statusTitle == "Something went wrong" {
                statusTitle = lastError ?? "Something went wrong"
                statusDetail = nil
                progress = nil
            }
            viewState = .processing
            refreshProjectSummaries()
        }
    }

    func resumeProjectTask(at url: URL, taskToken: UUID? = nil) async {
        guard isCurrentTaskToken(taskToken) else { return }
        defer {
            if currentTaskToken == taskToken {
                currentTask = nil
                currentTaskToken = nil
                if stopAction != nil {
                    completeStop()
                }
            }
        }
        reset()
        viewState = .processing
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil

        do {
            let paths = ProjectPaths(root: url)
            let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
            currentProjectURL = url
            currentPreset = metadata.preset
            currentInput = metadata.input
            syncShareMetrics(for: url)
            logLines = []
            errorLogLines = []
            let previousLines = loadPipelineLogTail(projectURL: url)
            if !previousLines.isEmpty {
                appendLogLine("========== PREVIOUS LOG (from Logs/pipeline.log) ==========")
                for line in previousLines {
                    appendLogLine("[previous] \(line)")
                }
            }
            appendLogLine("========== NEW LOG START (current run) ==========")
            appendLogLine("Resumed project")

            if let outputURL = readyOutputURL(projectURL: url, metadata: metadata) {
                guard isCurrentTaskToken(taskToken) else { return }
                outputPlyURL = outputURL
                currentReconstruction = metadata.reconstruction
                currentStageTimings = metadata.stageTimings ?? []
                currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
                currentAutoTune = metadata.autoTune
                currentPreset = metadata.preset
                currentInput = metadata.input
                currentProjectNotes = metadata.notes ?? ""
                markProjectOpened(at: url)
                syncShareMetrics(for: url)
                viewState = .viewer
                return
            }

            // A resume that must re-run holds the awake assertion across the toolchain
            // download and the run; a resume that just opens a ready project (returned
            // above) never reaches here, so it does not hold one.
            let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is preparing and resuming a project")
            defer { idleSleepAssertion.release() }

            statusTitle = "Downloading tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self, taskToken: taskToken)
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                targetName: "macos-arm64"
            ) { fraction, message in
                progressForwarder.update(fraction: fraction, message: message)
            }
            guard isCurrentTaskToken(taskToken) else { return }
            toolchainPaths = toolchain

            let runner = pipelineRunnerFactory(
                url,
                pipelineConfig(toolchain: toolchain, preset: metadata.preset)
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            let stageToResume = resumeStage(from: metadata)
            try await runner.run(resumeFrom: stageToResume) { event in
                forwarder.handle(event)
            }
            guard isCurrentTaskToken(taskToken) else { return }

            guard let outputURL = readyOutputURL(projectURL: url) else {
                presentOutputMissingFailure(projectURL: url)
                return
            }
            outputPlyURL = outputURL
            currentReconstruction = loadReconstructionSummary(projectURL: url)
            currentStageTimings = loadStageTimings(projectURL: url)
            currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
            currentAutoTune = loadAutoTuneSnapshot(projectURL: url)
            if let config = loadProjectConfig(projectURL: url) {
                currentPreset = config.preset
                currentInput = config.input
            } else {
                currentPreset = nil
                currentInput = nil
            }
            currentProjectNotes = loadProjectNotes(projectURL: url)
            markProjectOpened(at: url)
            syncShareMetrics(for: url)
            refreshFreeDiskSpace()
            viewState = .viewer
            refreshProjectSummaries()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTaskToken(taskToken) else { return }
            if stopAction != nil {
                return
            }
            let failureMessage = lastError ?? error.localizedDescription
            if lastError == nil {
                lastError = failureMessage
            }
            persistProjectFailure(failureMessage, at: currentProjectURL)
            let envDetails = """
            Underlying error: \(String(reflecting: error))
            Manifest URL: \(AppConfig.toolchainManifestURL.absoluteString)
            Public key present: \(!AppConfig.toolchainPublicKeyBase64.isEmpty)
            """
            if let existing = errorDetails, !existing.isEmpty {
                errorDetails = existing + "\n\n" + envDetails
            } else {
                errorDetails = envDetails
            }
            if statusTitle == "Preparing project" || statusTitle == "Downloading tools" || statusTitle == "Something went wrong" {
                statusTitle = lastError ?? "Something went wrong"
                statusDetail = nil
                progress = nil
            }
            viewState = .processing
            refreshProjectSummaries()
        }
    }

    func reset() {
        cancelForcedExitIfNeeded()
        stage = nil
        progress = nil
        statusTitle = "Ready"
        statusDetail = nil
        stageStartedAt = nil
        lastPipelineEventAt = nil
        logLines = []
        errorLogLines = []
        lastProgressLogAt = .distantPast
        lastProgressLogMessage = ""
        lastProgressLogStage = nil
        lastTrainingImagesBucket = -1
        lastTrainingSparseBucket = -1
        lastTrainingStepsBucket = -1
        lastStageLogAt = .distantPast
        lastStageLogMessage = ""
        lastStageLogStage = nil
        lastToolchainMilestoneMessage = ""
        toolchainDownloadBucketByLabel = [:]
        lastError = nil
        errorDetails = nil
        // Flush any pending notes save before tearing down so the user's last
        // edit isn't lost when they start or resume a different project (or
        // when reset() runs as part of app teardown).
        flushPendingNotesSave()
        outputPlyURL = nil
        currentReconstruction = nil
        currentStageTimings = []
        currentOutputPlyInfo = nil
        currentAutoTune = nil
        currentPreset = nil
        currentInput = nil
        currentProjectNotes = ""
        toolchainPaths = nil
        currentProjectURL = nil
        stopAction = nil
        isShowingTrainingConsent = false
        isLivePreviewEnabled = false
        activeTrainingBackend = nil
        trainingConsentContinuation = nil
        trainingConsentPauseStartedAt = nil
        trainingConsentPausedDuration = 0
        pendingSnapshotRevealURL = nil
        pendingSnapshotRevealRequiresExit = false
        recoveryPromptProject = nil
        shareStatusMessage = nil
        shareStatusIsError = false
        shareMetrics = .init()
        isShareSheetActive = false
        activeShareSession = nil
    }

    func presentOutputMissingFailure(projectURL: URL) {
        let message = "Processing failed. Expected outputs were missing."
        lastError = message
        statusTitle = message
        statusDetail = nil
        progress = nil
        errorDetails = "The run finished, but EasySplat could not find a valid output PLY file."
        outputPlyURL = nil
        currentReconstruction = nil
        currentOutputPlyInfo = nil
        currentAutoTune = nil
        currentPreset = nil
        currentInput = nil
        persistProjectFailure(message, at: projectURL)
        appendLogLine("[err] \(message)", isError: true)
        viewState = .processing
        refreshProjectSummaries()
    }

    private func persistProjectFailure(_ message: String, at projectURL: URL?) {
        guard let projectURL else { return }
        mutateProjectMetadata(at: projectURL) { metadata in
            metadata.state = PipelineState(
                stage: metadata.state.stage,
                attempt: metadata.state.attempt,
                lastError: message,
                resumeToken: nil
            )
            metadata.checkpoint = nil
            metadata.lastRunStartedAt = nil
            metadata.lastFailureAt = Date()
        }
    }

    func pipelineConfig(toolchain: ToolchainPaths, preset: PresetSpec) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            preset: preset,
            speedProfile: speedProfile(for: preset),
            trainingGate: makeTrainingGate()
        )
    }

    func speedProfile(for preset: PresetSpec) -> PipelineRunner.SpeedProfile {
        preset.quality == .draft ? .fast : .standard
    }

    func completeStop() {
        let action = stopAction
        stopAction = nil

        let projectURL = currentProjectURL
        if action == .keepProject, let projectURL {
            suppressRecoveryPrompt(for: projectURL, clearLastRunStartedAt: true)
        }
        let snapshotURL = pendingSnapshotRevealURL
        let shouldOfferSnapshot = pendingSnapshotRevealRequiresExit
        reset()
        viewState = .home
        if action == .deleteProject, let projectURL {
            try? FileManager.default.removeItem(at: projectURL)
        }
        refreshProjectSummaries()
        if shouldOfferSnapshot, let snapshotURL {
            presentSnapshotRevealIfAvailable(snapshotURL)
        }
        finalizeExitIfNeeded()
    }
}

private final class WeakAppModelBox: @unchecked Sendable {
    weak var value: AppModel?

    init(_ value: AppModel) {
        self.value = value
    }
}

private final class EventForwarder: @unchecked Sendable {
    private weak var model: AppModel?
    private let taskToken: UUID?

    init(model: AppModel, taskToken: UUID?) {
        self.model = model
        self.taskToken = taskToken
    }

    func handle(_ event: PipelineEvent) {
        Task { @MainActor in
            guard let model = self.model, model.isCurrentTaskToken(self.taskToken) else { return }
            model.handle(event: event)
        }
    }
}

private final class ProgressForwarder: @unchecked Sendable {
    private weak var model: AppModel?
    private let taskToken: UUID?

    init(model: AppModel, taskToken: UUID?) {
        self.model = model
        self.taskToken = taskToken
    }

    func update(fraction: Double, message: String) {
        Task { @MainActor in
            guard let model = self.model, model.isCurrentTaskToken(self.taskToken) else { return }
            model.handleToolchainProgress(fraction: fraction, message: message)
        }
    }
}

protocol PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws
}

extension PipelineRunner: PipelineRunning {}
