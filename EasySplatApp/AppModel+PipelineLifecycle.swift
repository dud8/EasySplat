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

        guard currentTask != nil else {
            if deleteProject, let projectURL = currentProjectURL {
                if moveProjectToTrash(at: projectURL) {
                    finalizeExitIfNeeded()
                } else {
                    abortPendingExitAfterStopFailure()
                }
                return
            }
            currentTaskToken = nil
            isRunActive = false
            reset()
            viewState = .home
            refreshProjectSummaries()
            finalizeExitIfNeeded()
            return
        }

        let isSetup = currentProjectURL == nil
        stopAction = isSetup ? .keepProject : (deleteProject ? .deleteProject : .keepProject)
        lastError = nil
        errorDetails = nil
        if isSetup {
            statusTitle = "Stopping setup…"
            statusDetail = "No project has been created."
        } else if deleteProject {
            statusTitle = "Stopping and moving to Trash…"
            statusDetail = "Waiting for the current step to stop safely…"
        } else if isTrainingStageActive {
            statusTitle = "Saving training checkpoint…"
            statusDetail = "Saving and validating the latest training checkpoint. Recent iterations may repeat on resume."
        } else {
            statusTitle = "Saving progress…"
            statusDetail = "Keeping completed work and stopping at a safe point…"
        }
        progress = nil
        currentTask?.cancel()
        scheduleForcedExitIfNeeded()
    }

    @discardableResult
    func moveProjectToTrash(at projectURL: URL) -> Bool {
        actionFailure = nil
        if ProjectSummary.hasSameLocation(currentProjectURL, projectURL) {
            guard flushPendingNotesSave() else { return false }
        }
        do {
            try projectTrashHandler(projectURL)
        } catch {
            statusTitle = "Couldn’t move project to Trash"
            statusDetail = "The project stayed in place. Check Finder permissions and try again."
            lastError = statusTitle
            errorDetails = String(reflecting: error)
            progress = nil
            actionFailure = ActionFailurePresentation(
                title: "Couldn’t move project to Trash",
                message: "The project stayed in place. Check Finder permissions and try again."
            )
            refreshProjectSummaries()
            return false
        }
        if ProjectSummary.hasSameLocation(currentProjectURL, projectURL) {
            reset()
            viewState = .home
        }
        refreshProjectSummaries()
        return true
    }

    func elapsedSinceStageStart(now: Date) -> TimeInterval? {
        guard let startedAt = stageStartedAt else { return nil }
        return max(0, now.timeIntervalSince(startedAt))
    }

    func elapsedSincePhaseStart(now: Date) -> TimeInterval? {
        guard let startedAt = phaseStartedAt else { return nil }
        return max(0, now.timeIntervalSince(startedAt))
    }

    var exitConfirmationPresentation: ExitConfirmationPresentation {
        if currentProjectURL == nil {
            return ExitConfirmationPresentation(
                title: "Stop setup?",
                message: "EasySplat will stop preparing tools. No project has been created.",
                primaryActionTitle: "Stop Setup",
                destructiveActionTitle: nil
            )
        }
        if isTrainingStageActive {
            return ExitConfirmationPresentation(
                title: "Training in progress",
                message: "EasySplat will save and validate a training checkpoint. Recent iterations may repeat when you resume.",
                primaryActionTitle: "Save Project",
                destructiveActionTitle: "Move to Trash"
            )
        }
        return ExitConfirmationPresentation(
            title: "Stop this project?",
            message: "You can save and resume later, or move the project to Trash.",
            primaryActionTitle: "Save Project",
            destructiveActionTitle: "Move to Trash"
        )
    }

    func presentExitConfirmation() -> ExitDecision {
        let presentation = exitConfirmationPresentation
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        let saveButton = alert.addButton(withTitle: presentation.primaryActionTitle)
        saveButton.keyEquivalent = "\r"
        if let destructiveActionTitle = presentation.destructiveActionTitle {
            let deleteButton = alert.addButton(withTitle: destructiveActionTitle)
            deleteButton.hasDestructiveAction = true
        }
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        if presentation.destructiveActionTitle == nil {
            return response == .alertFirstButtonReturn ? .save : .cancel
        }
        switch response {
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

    func abortPendingExitAfterStopFailure() {
        cancelForcedExitIfNeeded()
        let rejectedQuit = exitIntent == .quit
        exitIntent = .none
        pendingCloseWindow = nil
        allowNextWindowClose = false
        if rejectedQuit {
            replyToTerminationRequest(false)
        }
    }

    func forceFinalizeExit(intent: ExitIntent, window: NSWindow?) {
        switch intent {
        case .none:
            return
        case .quit:
            exitIntent = .none
            pendingCloseWindow = nil
            replyToTerminationRequest(true)
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
            replyToTerminationRequest(true)
            NSApp.terminate(nil)
        case .closeWindow:
            if let window = pendingCloseWindow {
                allowNextWindowClose = true
                window.performClose(nil)
            }
        }
    }

    func startProject(input: InputSpec, title: String, taskToken: UUID? = nil) async {
        guard isCurrentTaskToken(taskToken) else { return }
        defer { finishRun(taskToken: taskToken) }
        reset()
        viewState = .processing
        phaseStartedAt = Date()
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil

        do {
            let requestedOptions = requestedRunOptions
            try RunPlanResolver.validate(
                requestedOptions: requestedOptions,
                input: input,
                hardware: hardwareProfile
            )
            let developmentOverrides = DevelopmentOverrides.fromProcessEnvironment()
            let resolvedRunPlan = RunPlanResolver.resolve(
                requestedOptions: requestedOptions,
                input: input,
                hardware: hardwareProfile,
                developmentOverrides: developmentOverrides
            )
            try await validatePhotoSelection(input: input, resolvedRunPlan: resolvedRunPlan)
            guard isCurrentTaskToken(taskToken) else { return }
            let capabilityRequest = try resolvedRunPlan.toolchainCapabilityRequest()

            // Keep the Mac awake for the whole flow, including the first-run toolchain
            // download, which happens before the runner (and its own assertion) exists.
            let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is preparing and processing a project")
            defer { idleSleepAssertion.release() }

            statusTitle = "Preparing tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self, taskToken: taskToken)
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                request: capabilityRequest
            ) { fraction, message in
                progressForwarder.update(fraction: fraction, message: message)
            }
            guard isCurrentTaskToken(taskToken) else { return }

            try Task.checkCancellation()
            let projectURL = try createProjectDirectory(title: title)
            let metadata = ProjectMetadata(
                title: projectURL.deletingPathExtension().lastPathComponent,
                input: input,
                requestedRunOptions: requestedOptions,
                resolvedRunPlan: resolvedRunPlan
            )
            let paths = ProjectPaths(root: projectURL)
            do {
                try paths.ensureDirectories()
                try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
            } catch {
                try? FileManager.default.removeItem(at: projectURL)
                throw error
            }
            currentProjectURL = projectURL
            currentRunOptions = requestedOptions
            currentInput = input
            clearPendingInputs()
            refreshProjectSummaries()

            let runner = pipelineRunnerFactory(
                projectURL,
                pipelineConfig(
                    toolchain: toolchain,
                    resolvedRunPlan: resolvedRunPlan,
                    developmentOverrides: developmentOverrides
                )
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            try await runner.run(resumeFrom: Optional<PipelineStage>.none) { event in
                forwarder.handle(event)
            }
            guard isCurrentTaskToken(taskToken) else { return }

            guard let outputURL = try await validatedFinishedOutputURL(projectURL: projectURL) else {
                presentOutputMissingFailure(projectURL: projectURL)
                return
            }
            outputPlyURL = outputURL
            currentReconstruction = loadReconstructionSummary(projectURL: projectURL)
            currentStageTimings = loadStageTimings(projectURL: projectURL)
            currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
            if let config = loadProjectConfig(projectURL: projectURL) {
                currentRunOptions = config.options
                currentInput = config.input
            } else {
                currentRunOptions = nil
                currentInput = nil
            }
            currentProjectNotes = loadProjectNotes(projectURL: projectURL)
            markProjectOpened(at: projectURL)
            viewState = .viewer
            refreshProjectSummaries()
            refreshFreeDiskSpace()
        } catch is CancellationError {
            return
        } catch let error as RunPlanResolver.ValidationError {
            guard isCurrentTaskToken(taskToken) else { return }
            let message = error.localizedDescription
            validationRecovery = Self.validationRecovery(for: error)
            lastError = message
            statusTitle = message
            statusDetail = nil
            errorDetails = "Preflight stopped before downloading tools or creating a project."
            progress = nil
            viewState = .processing
        } catch {
            guard isCurrentTaskToken(taskToken) else { return }
            let stopFailureCopy = stopAction.map {
                stopFailurePresentation(for: $0)
            }
            if stopFailureCopy != nil {
                stopAction = nil
                abortPendingExitAfterStopFailure()
            }
            let fallbackMessage: String
            if statusTitle == "Preparing tools" {
                fallbackMessage = "Couldn’t prepare the required tools. Check your connection and try again."
            } else if currentProjectURL == nil {
                fallbackMessage = "Couldn’t create the project. Check free space and folder permissions."
            } else {
                fallbackMessage = "Processing stopped. Try again."
            }
            let failureMessage = lastError ?? stopFailureCopy?.detail ?? fallbackMessage
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
            if let stopFailureCopy {
                statusTitle = stopFailureCopy.title
                statusDetail = stopFailureCopy.detail
                progress = nil
            } else if statusTitle == "Preparing project" || statusTitle == "Preparing tools" || statusTitle == "Something went wrong" {
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
        defer { finishRun(taskToken: taskToken) }
        reset()
        viewState = .processing
        phaseStartedAt = Date()
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil
        var runnerStarted = false

        do {
            let paths = ProjectPaths(root: url)
            let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
            currentProjectURL = url
            currentRunOptions = metadata.requestedRunOptions
            currentInput = metadata.input
            if let outputURL = try await validatedFinishedOutputURL(projectURL: url) {
                guard isCurrentTaskToken(taskToken) else { return }
                outputPlyURL = outputURL
                currentReconstruction = metadata.reconstruction
                currentStageTimings = metadata.stageTimings ?? []
                currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
                currentProjectNotes = metadata.notes ?? ""
                markProjectOpened(at: url)
                viewState = .viewer
                refreshProjectSummaries()
                return
            }
            refreshProjectSummaries()
            let developmentOverrides = DevelopmentOverrides.fromProcessEnvironment()
            let requestedOptions = metadata.requestedRunOptions
            try RunPlanResolver.validate(
                requestedOptions: requestedOptions,
                input: metadata.input,
                hardware: hardwareProfile
            )
            let resolvedRunPlan = RunPlanResolver.resolve(
                requestedOptions: requestedOptions,
                input: metadata.input,
                hardware: hardwareProfile,
                developmentOverrides: developmentOverrides
            )
            if metadata.input.photosFolder != nil {
                let importedPhotos = paths.importedPhotosURL
                if FileManager.default.fileExists(atPath: importedPhotos.path) {
                    try await validatePhotoSelection(
                        input: metadata.input,
                        resolvedRunPlan: resolvedRunPlan,
                        folder: importedPhotos
                    )
                } else if metadata.state.stage == .importInput {
                    try await validatePhotoSelection(
                        input: metadata.input,
                        resolvedRunPlan: resolvedRunPlan
                    )
                }
            }
            guard isCurrentTaskToken(taskToken) else { return }
            let capabilityRequest = try resolvedRunPlan.toolchainCapabilityRequest()
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

            // A resume that must re-run holds the awake assertion across the toolchain
            // download and the run; a resume that just opens a ready project (returned
            // above) never reaches here, so it does not hold one.
            let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is preparing and resuming a project")
            defer { idleSleepAssertion.release() }

            statusTitle = "Preparing tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self, taskToken: taskToken)
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                request: capabilityRequest
            ) { fraction, message in
                progressForwarder.update(fraction: fraction, message: message)
            }
            guard isCurrentTaskToken(taskToken) else { return }

            let runner = pipelineRunnerFactory(
                url,
                pipelineConfig(
                    toolchain: toolchain,
                    resolvedRunPlan: resolvedRunPlan,
                    developmentOverrides: developmentOverrides
                )
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            let stageToResume = RunPlanResolver.safeResumeStage(
                resumeStage(from: metadata),
                input: metadata.input,
                previousPlan: metadata.resolvedRunPlan,
                currentPlan: resolvedRunPlan
            )
            runnerStarted = true
            try await runner.run(resumeFrom: stageToResume) { event in
                forwarder.handle(event)
            }
            guard isCurrentTaskToken(taskToken) else { return }

            guard let outputURL = try await validatedFinishedOutputURL(projectURL: url) else {
                presentOutputMissingFailure(projectURL: url)
                return
            }
            outputPlyURL = outputURL
            currentReconstruction = loadReconstructionSummary(projectURL: url)
            currentStageTimings = loadStageTimings(projectURL: url)
            currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
            if let config = loadProjectConfig(projectURL: url) {
                currentRunOptions = config.options
                currentInput = config.input
            } else {
                currentRunOptions = nil
                currentInput = nil
            }
            currentProjectNotes = loadProjectNotes(projectURL: url)
            markProjectOpened(at: url)
            refreshFreeDiskSpace()
            viewState = .viewer
            refreshProjectSummaries()
        } catch is CancellationError {
            return
        } catch let error as RunPlanResolver.ValidationError {
            guard isCurrentTaskToken(taskToken) else { return }
            let message = error.localizedDescription
            validationRecovery = Self.validationRecovery(for: error)
            lastError = message
            statusTitle = message
            statusDetail = "The saved project and its checkpoint are unchanged."
            errorDetails = "Resume preflight stopped before downloading tools or changing project files."
            progress = nil
            viewState = .processing
            refreshProjectSummaries()
        } catch {
            guard isCurrentTaskToken(taskToken) else { return }
            let stopFailureCopy = stopAction.map {
                stopFailurePresentation(for: $0)
            }
            if stopFailureCopy != nil {
                stopAction = nil
                abortPendingExitAfterStopFailure()
            }
            let fallbackMessage: String
            if statusTitle == "Preparing tools" {
                fallbackMessage = "Couldn’t prepare the required tools. Check your connection and try again."
            } else if runnerStarted {
                fallbackMessage = "Processing stopped. Try again."
            } else {
                fallbackMessage = "Couldn’t open this project. It was not changed."
            }
            let failureMessage = lastError ?? stopFailureCopy?.detail ?? fallbackMessage
            if lastError == nil {
                lastError = failureMessage
            }
            if runnerStarted {
                persistProjectFailure(failureMessage, at: currentProjectURL)
            }
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
            if let stopFailureCopy {
                statusTitle = stopFailureCopy.title
                statusDetail = stopFailureCopy.detail
                progress = nil
            } else if statusTitle == "Preparing project" || statusTitle == "Preparing tools" || statusTitle == "Something went wrong" {
                statusTitle = lastError ?? "Something went wrong"
                statusDetail = runnerStarted
                    ? nil
                    : "The saved project and its checkpoint are unchanged."
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
        phaseStartedAt = nil
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
        validationRecovery = nil
        // Flush any pending notes save before tearing down so the user's last
        // edit isn't lost when they start or resume a different project (or
        // when reset() runs as part of app teardown).
        let notesSaved = flushPendingNotesSave()
        outputPlyURL = nil
        currentReconstruction = nil
        currentStageTimings = []
        currentOutputPlyInfo = nil
        currentRunOptions = nil
        currentInput = nil
        currentProjectNotes = ""
        currentProjectURL = nil
        stopAction = nil
        shareStatusMessage = nil
        shareStatusIsError = false
        isShareSheetActive = false
        activeShareSession = nil
        shareValidationToken = nil
        if notesSaved {
            notesSaveState = .idle
            actionFailure = nil
        }
    }

    private func validatePhotoSelection(
        input: InputSpec,
        resolvedRunPlan: ResolvedRunPlan,
        folder overrideFolder: URL? = nil
    ) async throws {
        guard let folderPath = input.photosFolder else {
            return
        }
        statusTitle = "Checking photos"
        statusDetail = nil
        progress = nil
        let folder = overrideFolder ?? URL(fileURLWithPath: folderPath, isDirectory: true)
        let inspectionTask = Task.detached(priority: .userInitiated) {
            try PhotoInputPreflight.inspect(folder: folder)
        }
        let summary = try await withTaskCancellationHandler {
            try await inspectionTask.value
        } onCancel: {
            inspectionTask.cancel()
        }
        try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: summary.validPhotoCount,
            resolvedPlan: resolvedRunPlan,
            input: input
        )
    }

    private func finishRun(taskToken: UUID?) {
        guard currentTaskToken == taskToken else { return }
        currentTask = nil
        currentTaskToken = nil
        isRunActive = false
        if stopAction != nil {
            completeStop()
        } else {
            refreshProjectSummaries()
        }
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
        currentRunOptions = nil
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
                lastError: message
            )
            metadata.checkpoint = nil
            metadata.lastRunStartedAt = nil
            metadata.lastFailureAt = Date()
        }
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
        guard (try? ProjectMetadataStore.save(metadata, to: metadataURL)) != nil else {
            return nil
        }
        return metadata
    }

    func pipelineConfig(
        toolchain: ToolchainPaths,
        resolvedRunPlan: ResolvedRunPlan? = nil,
        developmentOverrides: DevelopmentOverrides = .fromProcessEnvironment()
    ) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: developmentOverrides,
            hardwareProfile: hardwareProfile,
            resolvedRunPlan: resolvedRunPlan
        )
    }

    func completeStop() {
        let action = stopAction
        stopAction = nil

        let projectURL = currentProjectURL
        if action == .deleteProject, let projectURL {
            if moveProjectToTrash(at: projectURL) {
                finalizeExitIfNeeded()
            } else {
                abortPendingExitAfterStopFailure()
            }
            return
        }
        reset()
        viewState = .home
        refreshProjectSummaries()
        finalizeExitIfNeeded()
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
