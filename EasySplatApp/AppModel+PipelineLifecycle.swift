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

    @discardableResult
    func startProject(
        input: InputSpec,
        title: String,
        taskToken: UUID? = nil,
        timingBoundary: RunTimingBoundary? = nil
    ) async -> ToolchainPaths? {
        guard isCurrentTaskToken(taskToken) else { return nil }
        let timingBoundary = timingBoundary ?? .capture()
        defer { finishRun(taskToken: taskToken) }
        reset()
        viewState = .processing
        phaseStartedAt = Date()
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil
        var preparedVideoInput: PreparedVideoInput?
        var preparedPhotoInput: PreparedPhotoInput?
        var projectPublication: ProjectPublicationTransaction?
        var emptyMixedPhotoInput = false
        defer { preparedVideoInput?.discard() }
        defer { preparedPhotoInput?.discard() }
        defer { try? projectPublication?.abort() }

        do {
            let requestedOptions = requestedRunOptions
            try RunPlanResolver.validate(
                requestedOptions: requestedOptions,
                input: input,
                hardware: hardwareProfile
            )
            let developmentOverrides = AppConfig.currentDevelopmentOverrides
            let resolvedRunPlan = RunPlanResolver.resolve(
                requestedOptions: requestedOptions,
                input: input,
                hardware: hardwareProfile,
                developmentOverrides: developmentOverrides
            )

            // Preflight authenticates and stages the complete source capture. Keep the Mac
            // awake from that first durable read through tool preparation and processing.
            let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(
                reason: "EasySplat is preparing and processing a project"
            )
            defer { idleSleepAssertion.release() }

            if let photosFolder = input.photosFolder {
                statusTitle = "Checking photos"
                statusDetail = nil
                progress = nil
                let reservedVideoFrames = RunPlanResolver.minimumReservedVideoFrameCount(
                    keyframeBudget: resolvedRunPlan.keyframeBudget,
                    videoCount: input.videoFiles.count
                )
                let photoBudget = resolvedRunPlan.photoSelection == .automatic
                    ? resolvedRunPlan.keyframeBudget
                    : max(1, resolvedRunPlan.keyframeBudget - reservedVideoFrames)
                do {
                    preparedPhotoInput = try await PhotoInputPreflight.prepare(
                        folder: URL(fileURLWithPath: photosFolder, isDirectory: true),
                        stagingParent: projectBaseDirectory(),
                        photoSelection: resolvedRunPlan.photoSelection,
                        inputOrdering: resolvedRunPlan.inputOrdering,
                        keyframeBudget: photoBudget,
                        requiredAtomicWorkspaceReserveBytes: VideoInputPreflight
                            .requiredAtomicWorkspaceReserveBytes(
                                keyframeBudget: resolvedRunPlan.keyframeBudget,
                                maximumImageDimension: resolvedRunPlan.maximumImageDimension,
                                maximumFeatureCount: resolvedRunPlan.colmapMaximumFeatureCount,
                                maximumMatchCount: resolvedRunPlan.colmapMaximumMatchCount,
                                retrievalCandidateCount: resolvedRunPlan.retrievalCandidateCount
                            ),
                        limits: .init(
                            maximumDecodedDimension: min(4_096, resolvedRunPlan.maximumImageDimension)
                        )
                    ) { [weak self] fraction, message in
                        Task { @MainActor [weak self] in
                            guard let self, self.isCurrentTaskToken(taskToken) else { return }
                            self.progress = fraction
                            self.statusTitle = "Checking photos"
                            self.statusDetail = message
                        }
                    }
                } catch let failure as PhotoInputPreflightFailure
                    where input.hasVideos && failure.issue == .noValidPhotos {
                    emptyMixedPhotoInput = true
                    preparedPhotoInput = nil
                }
                if let preparedPhotoInput {
                    try RunPlanResolver.validatePhotoSelection(
                        validPhotoCount: preparedPhotoInput.summary.validPhotoCount,
                        resolvedPlan: resolvedRunPlan,
                        input: input
                    )
                } else if emptyMixedPhotoInput {
                    try RunPlanResolver.validatePhotoSelection(
                        validPhotoCount: 0,
                        resolvedPlan: resolvedRunPlan,
                        input: input
                    )
                }
            }
            guard isCurrentTaskToken(taskToken) else { return nil }
            if input.hasVideos {
                statusTitle = "Checking videos"
                statusDetail = nil
                progress = nil
                preparedVideoInput = try await videoInputPreflight.prepare(
                    videoURLs: input.videoFiles.map(URL.init(fileURLWithPath:)),
                    stagingParent: projectBaseDirectory(),
                    requiredAtomicWorkspaceReserveBytes: VideoInputPreflight
                        .requiredAtomicWorkspaceReserveBytes(
                            keyframeBudget: resolvedRunPlan.keyframeBudget,
                            maximumImageDimension: resolvedRunPlan.maximumImageDimension,
                            maximumFeatureCount: resolvedRunPlan.colmapMaximumFeatureCount,
                            maximumMatchCount: resolvedRunPlan.colmapMaximumMatchCount,
                            retrievalCandidateCount: resolvedRunPlan.retrievalCandidateCount
                        ),
                    analysisPolicy: VideoFrameAnalysisPolicy(
                        resolvedRunPlan: resolvedRunPlan
                    ),
                    pairingPolicy: resolvedRunPlan.pairingPolicy
                ) { [weak self] fraction, message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentTaskToken(taskToken) else { return }
                        self.progress = fraction
                        self.statusTitle = "Checking videos"
                        self.statusDetail = message
                    }
                }
            }
            guard isCurrentTaskToken(taskToken) else { return nil }
            let capabilityRequest = try resolvedRunPlan.toolchainCapabilityRequest()

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
            guard isCurrentTaskToken(taskToken) else { return nil }

            try Task.checkCancellation()
            let projectID = UUID()
            let publication = try ProjectPublicationTransaction.begin(
                in: projectBaseDirectory(),
                title: title,
                projectID: projectID,
                checkpointHandler: { [projectPublicationCheckpointHook] checkpoint in
                    try projectPublicationCheckpointHook.handle(checkpoint)
                }
            )
            projectPublication = publication
            let paths = ProjectPaths(root: publication.bundleURL)
            var inputAdoption = ProjectInputAdoption(requestedInput: input)
            defer { inputAdoption.videoInputIntegrityHandoff?.discard() }
            if let preparedVideoInput {
                try inputAdoption.adoptVideos(preparedVideoInput, into: paths)
                try publication.reached(.videoAdopted)
            }
            try Task.checkCancellation()
            if let preparedPhotoInput {
                try inputAdoption.adoptPhotos(preparedPhotoInput, into: paths)
                try publication.reached(.photosAdopted)
            } else if emptyMixedPhotoInput {
                try inputAdoption.adoptEmptyMixedPhotoFolder(into: paths)
                try publication.reached(.photosAdopted)
            }
            try Task.checkCancellation()
            try paths.ensureDirectories()
            let metadata = ProjectMetadata(
                id: projectID,
                title: title,
                input: inputAdoption.input,
                videoInputReceipts: inputAdoption.videoInputReceipts,
                photoInputReceipts: inputAdoption.photoInputReceipts,
                photoSelectionReceipt: inputAdoption.photoSelectionReceipt,
                requestedRunOptions: requestedOptions,
                resolvedRunPlan: resolvedRunPlan,
                lastRunStartedAt: Date()
            )
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
            try publication.validateAndSeal(expectedMetadata: metadata)
            try Task.checkCancellation()
            let freshPublication: FreshProjectPublication
            if inputAdoption.input.hasVideos {
                guard let videoInputIntegrityHandoff = inputAdoption.videoInputIntegrityHandoff else {
                    throw VideoInputIntegrityHandoffError.unavailable
                }
                freshPublication = try publication.publishWithFreshAttestation(
                    videoInputIntegrityHandoff: videoInputIntegrityHandoff
                )
            } else {
                freshPublication = try publication
                    .publishWithFreshAttestationForProjectWithoutVideos()
            }
            defer { freshPublication.attestation.discard() }
            let projectURL = freshPublication.projectURL
            projectPublication = nil
            currentProjectURL = projectURL
            currentRunOptions = requestedOptions
            currentInput = inputAdoption.input
            clearPendingInputs()
            refreshProjectSummaries()

            try Task.checkCancellation()
            guard isCurrentTaskToken(taskToken) else {
                freshPublication.attestation.discard()
                return nil
            }

            let runner = pipelineRunnerFactory(
                projectURL,
                pipelineConfig(
                    toolchain: toolchain,
                    resolvedRunPlan: resolvedRunPlan,
                    developmentOverrides: developmentOverrides,
                    prePipelineDurationSeconds: timingBoundary.elapsedSeconds(),
                    prePipelineStartedAt: timingBoundary.startedAt
                )
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            try await runner.run(
                resumeFrom: Optional<PipelineStage>.none,
                freshPublicationAttestation: freshPublication.attestation
            ) { event in
                forwarder.handle(event)
            }
            guard isCurrentTaskToken(taskToken) else { return nil }

            guard let outputURL = try await validatedFinishedOutputURL(projectURL: projectURL) else {
                presentOutputMissingFailure(projectURL: projectURL)
                return nil
            }
            outputPlyURL = outputURL
            currentStageTimings = loadStageTimings(projectURL: projectURL)
            currentCreateToViewerReadySeconds = loadCreateToViewerReadySeconds(
                projectURL: projectURL
            )
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
            prepareResultViewerTiming(
                projectID: projectID,
                projectURL: projectURL,
                outputURL: outputURL,
                boundary: timingBoundary
            )
            viewState = .viewer
            refreshProjectSummaries()
            refreshFreeDiskSpace()
            return toolchain
        } catch is CancellationError {
            return nil
        } catch let error as RunPlanResolver.ValidationError {
            guard isCurrentTaskToken(taskToken) else { return nil }
            let message = error.localizedDescription
            validationRecovery = Self.validationRecovery(for: error)
            lastError = message
            statusTitle = message
            statusDetail = nil
            errorDetails = "Preflight stopped before downloading tools or creating a project."
            progress = nil
            viewState = .processing
        } catch let failure as PhotoInputPreflightFailure {
            guard isCurrentTaskToken(taskToken) else { return nil }
            if case .unsupportedSpherical(let issue) = failure.issue {
                let presentation = Self.unsupportedSphericalMediaPresentation(issue)
                lastError = presentation.title
                statusTitle = presentation.title
                statusDetail = nil
                errorDetails = presentation.details
                progress = nil
                failureRetryAllowed = false
                viewState = .processing
                return nil
            }
            let validationError: RunPlanResolver.ValidationError?
            switch failure.issue {
            case .noValidPhotos:
                validationError = .noValidPhotos
            case .useAllExceedsBudget(let selected, let maximum):
                validationError = .photoSelectionExceedsSafeLimit(
                    selected: selected,
                    maximum: maximum
                )
            default:
                validationError = nil
            }
            if let validationError {
                let message = validationError.localizedDescription
                validationRecovery = Self.validationRecovery(for: validationError)
                lastError = message
                statusTitle = message
                errorDetails = "Preflight stopped before downloading tools or creating a project."
            } else {
                lastError = "Photos couldn’t be prepared"
                statusTitle = "Photos couldn’t be prepared"
                errorDetails = String(describing: failure.issue)
                validationRecovery = nil
            }
            statusDetail = nil
            progress = nil
            failureRetryAllowed = validationRecovery != nil
            viewState = .processing
        } catch let failure as VideoInputPreflightFailure {
            guard isCurrentTaskToken(taskToken) else { return nil }
            let presentation = Self.videoPreflightFailurePresentation(failure)
            lastError = presentation.title
            statusTitle = presentation.title
            statusDetail = nil
            errorDetails = presentation.details
            progress = nil
            failureRetryAllowed = false
            viewState = .processing
        } catch {
            guard isCurrentTaskToken(taskToken) else { return nil }
            configureRuntimeRecovery(for: error)
            let stopFailureCopy = stopAction.map {
                stopFailurePresentation(for: $0)
            }
            if stopFailureCopy != nil {
                stopAction = nil
                abortPendingExitAfterStopFailure()
            }
            let fallbackMessage: String
            if statusTitle == "Preparing tools" {
                fallbackMessage = toolchainPreparationFailureMessage(for: error)
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
            let envDetails = failureTechnicalDetails(for: error)
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
        return nil
    }

    private static func videoPreflightFailurePresentation(
        _ failure: VideoInputPreflightFailure
    ) -> (title: String, details: String) {
        if let issue = failure.rejectedVideos.lazy.compactMap({ rejection -> UnsupportedSphericalMediaIssue? in
            guard case .unsupportedSpherical(let issue) = rejection.issue else { return nil }
            return issue
        }).first {
            return unsupportedSphericalMediaPresentation(issue)
        }
        let count = failure.rejectedVideos.count
        let issues = failure.rejectedVideos.map(\.issue)
        let title: String
        if issues.contains(where: {
            if case .insufficientSpace = $0 { return true }
            return false
        }) {
            title = "Not enough free space"
        } else if issues.contains(where: Self.isVideoSelectionIssue) {
            title = "Check your video selection"
        } else if issues.allSatisfy(Self.isUnreadableVideoIssue) {
            title = count == 1
                ? "This video couldn’t be read"
                : "Some videos couldn’t be read"
        } else {
            title = "Videos couldn’t be prepared"
        }
        let details = failure.rejectedVideos.map { rejection in
            "Video \(rejection.index + 1) (\(rejection.safeDisplayName)): \(videoPreflightIssueDescription(rejection.issue))."
        }.joined(separator: "\n")
        return (title, details)
    }

    private static func isVideoSelectionIssue(_ issue: VideoInputPreflightIssue) -> Bool {
        switch issue {
        case .noVideosSelected, .sourceUnavailable, .symbolicLink, .notRegularFile,
             .emptyFile, .duplicateSource, .sourceChanged, .tooManyVideos,
             .totalBytesExceeded, .invalidLimits:
            return true
        case .unreadableMedia, .noUsableVideoTrack, .decodeFailed,
             .insufficientSpace, .stagingUnavailable, .capacityUnavailable,
             .copyFailed, .unsupportedSpherical:
            return false
        }
    }

    private static func isUnreadableVideoIssue(_ issue: VideoInputPreflightIssue) -> Bool {
        switch issue {
        case .unreadableMedia, .noUsableVideoTrack, .decodeFailed:
            return true
        default:
            return false
        }
    }

    private static func videoPreflightIssueDescription(
        _ issue: VideoInputPreflightIssue
    ) -> String {
        switch issue {
        case .noVideosSelected:
            return "no videos were selected"
        case .sourceUnavailable:
            return "the selected file is no longer available"
        case .symbolicLink:
            return "choose the original file instead of an alias"
        case .notRegularFile:
            return "the selection is not a supported file"
        case .emptyFile:
            return "file is empty"
        case .duplicateSource(let firstIndex):
            return "duplicates video \(firstIndex + 1)"
        case .sourceChanged:
            return "the file changed while it was being copied"
        case .unreadableMedia:
            return "media could not be read"
        case .noUsableVideoTrack:
            return "no usable video track"
        case .decodeFailed:
            return "decode failed"
        case .tooManyVideos(let maximum):
            return "select no more than \(maximum) videos"
        case .totalBytesExceeded:
            return "selection exceeds the video size limit"
        case .insufficientSpace:
            return "not enough free space to prepare the videos"
        case .invalidLimits:
            return "the video limits are unavailable"
        case .stagingUnavailable:
            return "a secure temporary copy could not be prepared"
        case .capacityUnavailable:
            return "free space could not be checked"
        case .copyFailed:
            return "the file could not be copied safely"
        case .unsupportedSpherical(let issue):
            return "unsupported standardized projection tag \(issue.tag.rawValue)"
        }
    }

    static func unsupportedSphericalMediaPresentation(
        _ issue: UnsupportedSphericalMediaIssue
    ) -> (title: String, details: String) {
        (
            title: "This appears to be 180°/360° panoramic media. EasySplat does not yet unwrap spherical captures. Export ordinary perspective views and try again.",
            details: "Detected standardized projection tag: \(issue.tag.rawValue)."
        )
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
            if metadata.input.hasVideos {
                statusDetail = "Checking saved videos"
                try await Task.detached(priority: .userInitiated) {
                    try VideoInputReceiptValidator.validateFiles(
                        metadata: metadata,
                        paths: paths
                    )
                }.value
            }
            currentProjectURL = url
            currentRunOptions = metadata.requestedRunOptions
            currentInput = metadata.input
            if let outputURL = try await validatedFinishedOutputURL(projectURL: url) {
                guard isCurrentTaskToken(taskToken) else { return }
                outputPlyURL = outputURL
                currentStageTimings = metadata.stageTimings ?? []
                currentCreateToViewerReadySeconds = metadata.createToViewerReadySeconds
                currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
                currentProjectNotes = metadata.notes ?? ""
                markProjectOpened(at: url)
                viewState = .viewer
                refreshProjectSummaries()
                return
            }
            refreshProjectSummaries()
            let developmentOverrides = AppConfig.currentDevelopmentOverrides
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
                developmentOverrides: developmentOverrides,
                trainingMemoryRetryBudgetBytes: metadata.trainingMemoryRetryBudgetBytes
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
            currentStageTimings = loadStageTimings(projectURL: url)
            currentCreateToViewerReadySeconds = loadCreateToViewerReadySeconds(projectURL: url)
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
        } catch let error as VideoInputReceiptValidationError {
            guard isCurrentTaskToken(taskToken) else { return }
            lastError = "A saved video changed"
            statusTitle = "A saved video changed"
            statusDetail = "Choose the original video again and start a new project."
            errorDetails = error.localizedDescription
            progress = nil
            failureRetryAllowed = false
            viewState = .processing
            refreshProjectSummaries()
        } catch {
            guard isCurrentTaskToken(taskToken) else { return }
            configureRuntimeRecovery(for: error)
            let stopFailureCopy = stopAction.map {
                stopFailurePresentation(for: $0)
            }
            if stopFailureCopy != nil {
                stopAction = nil
                abortPendingExitAfterStopFailure()
            }
            let fallbackMessage: String
            if statusTitle == "Preparing tools" {
                fallbackMessage = toolchainPreparationFailureMessage(for: error)
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
            let envDetails = failureTechnicalDetails(for: error)
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

    private func toolchainPreparationFailureMessage(for error: Error) -> String {
        if let toolchainError = error as? ToolchainManager.ToolchainError,
           case .manifestHTTPFailure(let statusCode, _) = toolchainError,
           statusCode == 404 || statusCode == 410 {
            return "The tools for this EasySplat build aren’t available. Download the latest EasySplat release or try again later."
        }
        return "Couldn’t prepare the required tools. Check your connection and try again."
    }

    private func failureTechnicalDetails(for error: Error) -> String {
        var lines: [String]
        if let toolchainError = error as? ToolchainManager.ToolchainError,
           case .manifestHTTPFailure(let statusCode, let resourceURL) = toolchainError {
            lines = ["Underlying error: EasySplatCore.ToolchainManager.ToolchainError.manifestHTTPFailure"]
            lines.append("HTTP status: \(statusCode)")
            lines.append("HTTP resource: \(redactedDiagnosticURL(resourceURL))")
        } else {
            lines = ["Underlying error: \(String(reflecting: error))"]
        }
        lines.append("Manifest URL: \(redactedDiagnosticURL(AppConfig.toolchainManifestURL))")
        lines.append("Public key present: \(!AppConfig.toolchainPublicKeyBase64.isEmpty)")
        return lines.joined(separator: "\n")
    }

    private func redactedDiagnosticURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid URL>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid URL>"
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
        failureRetryAllowed = true
        // Flush any pending notes save before tearing down so the user's last
        // edit isn't lost when they start or resume a different project (or
        // when reset() runs as part of app teardown).
        let notesSaved = flushPendingNotesSave()
        outputPlyURL = nil
        currentStageTimings = []
        currentCreateToViewerReadySeconds = nil
        currentOutputPlyInfo = nil
        currentRunOptions = nil
        currentInput = nil
        currentProjectNotes = ""
        currentProjectURL = nil
        pendingResultViewerTiming = nil
        stopAction = nil
        cancelSharing()
        shareStatusMessage = nil
        shareStatusIsError = false
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
        developmentOverrides: DevelopmentOverrides = AppConfig.currentDevelopmentOverrides,
        prePipelineDurationSeconds: TimeInterval = 0,
        prePipelineStartedAt: Date? = nil
    ) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: developmentOverrides,
            hardwareProfile: hardwareProfile,
            resolvedRunPlan: resolvedRunPlan,
            prePipelineDurationSeconds: prePipelineDurationSeconds,
            prePipelineStartedAt: prePipelineStartedAt
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
    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        freshPublicationAttestation: FreshProjectPublicationAttestation,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws
}

extension PipelineRunning {
    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        freshPublicationAttestation: FreshProjectPublicationAttestation,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        freshPublicationAttestation.discard()
        try await run(resumeFrom: lastCompletedStage, events: events)
    }
}

extension PipelineRunner: PipelineRunning {}
