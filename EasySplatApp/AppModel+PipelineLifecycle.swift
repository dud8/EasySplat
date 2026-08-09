import AppKit
import Darwin
import EasySplatCore
import Foundation

private struct BoundResultViewerTimingAuthority: Sendable {
    let publicationID: UUID
    let generation: PublishedResultGeneration
    let projectRootIdentity: AppProjectRootIdentity
    let elapsedSeconds: TimeInterval?
}

private enum ProjectTrashDisposition {
    case completed
    case scheduled
    case failed
}

private enum ProjectTrashLeafState {
    case absent
    case directory(AppProjectRootIdentity)
    case other

    func matches(_ identity: AppProjectRootIdentity) -> Bool {
        guard case .directory(let candidate) = self else { return false }
        return candidate == identity
    }
}

private enum ProjectTrashQuarantineError: LocalizedError {
    case invalidProjectPath
    case system(operation: String, code: Int32)
    case handlerFailure(Error)
    case handlerDidNotMove
    case identityConflict(String)

    var isIdentityConflict: Bool {
        if case .identityConflict = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidProjectPath:
            "The project path is not safe to move."
        case .system(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        case .handlerFailure(let error):
            error.localizedDescription
        case .handlerDidNotMove:
            "Finder did not move the project."
        case .identityConflict(let details):
            details
        }
    }
}

private enum ProjectTrashHandlerOutcome {
    case completed
    case restored
    case conflict
}

extension AppModel {
    func isCurrentTaskToken(_ taskToken: UUID?) -> Bool {
        currentTaskToken == taskToken
    }

    func cancelCurrentProject(deleteProject: Bool, exitIntent: ExitIntent = .none, window: NSWindow? = nil) {
        if exitIntent != .none {
            self.exitIntent = exitIntent
            self.pendingCloseWindow = window
        }

        if isSubjectIsolationActive {
            stopAction = deleteProject ? .deleteProject : .keepProject
            subjectIsolationStatusMessage = deleteProject
                ? "Cancelling isolation before moving to Trash…"
                : "Cancelling subject isolation…"
            cancelSubjectIsolation()
            return
        }

        if isSubjectVersionRemovalActive {
            stopAction = deleteProject ? .deleteProject : .keepProject
            subjectIsolationStatusMessage = deleteProject
                ? "Finishing Subject removal before moving to Trash…"
                : "Finishing Subject removal…"
            subjectIsolationStatusIsError = false
            return
        }

        guard currentTask != nil else {
            if deleteProject, let projectURL = currentProjectURL {
                switch requestProjectTrashMove(at: projectURL) {
                case .completed:
                    finalizeExitIfNeeded()
                case .scheduled:
                    break
                case .failed:
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
        switch requestProjectTrashMove(at: projectURL) {
        case .completed, .scheduled:
            true
        case .failed:
            false
        }
    }

    private func requestProjectTrashMove(
        at projectURL: URL,
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) -> ProjectTrashDisposition {
        guard !hasActiveWork else { return .failed }
        if let timingTask = cancelResultViewerTiming() {
            // A detached timing worker may be inside the publication lock or
            // the post-commit metadata retry. Let it release the exact root
            // lease before Finder can move that root. A supplied long-run
            // owner belongs to the finishing run task and must not escape it;
            // the deferred move acquires its own short owner after the wait.
            deferredProjectMutationTask = Task { [weak self, timingTask] in
                await timingTask.value
                guard let self else { return }
                self.deferredProjectMutationTask = nil
                let moved = self.moveProjectToTrashNow(
                    at: projectURL,
                    projectRunLeaseOwner: nil
                )
                guard self.exitIntent != .none else { return }
                if moved {
                    self.finalizeExitIfNeeded()
                } else {
                    self.abortPendingExitAfterStopFailure()
                }
            }
            return .scheduled
        }
        return moveProjectToTrashNow(
            at: projectURL,
            projectRunLeaseOwner: projectRunLeaseOwner
        ) ? .completed : .failed
    }

    @discardableResult
    private func moveProjectToTrashNow(
        at projectURL: URL,
        projectRunLeaseOwner suppliedProjectRunLeaseOwner:
            AppProjectRunLeaseOwner?
    ) -> Bool {
        actionFailure = nil
        let acquiredProjectRunLeaseOwner: AppProjectRunLeaseOwner?
        do {
            if suppliedProjectRunLeaseOwner == nil {
                acquiredProjectRunLeaseOwner = try acquireAppProjectRunLeaseOwner(
                    at: projectURL
                )
            } else {
                acquiredProjectRunLeaseOwner = nil
            }
        } catch {
            statusTitle = error.localizedDescription
            statusDetail = "The project stayed in place. Try again when processing finishes."
            lastError = statusTitle
            errorDetails = String(reflecting: error)
            progress = nil
            presentPendingNotesSaveFailureIfNeeded(at: projectURL)
            return false
        }
        defer { acquiredProjectRunLeaseOwner?.release() }
        let projectRunLeaseOwner = suppliedProjectRunLeaseOwner
            ?? acquiredProjectRunLeaseOwner
        let leasedProjectRootIdentity: AppProjectRootIdentity
        do {
            guard let projectRunLeaseOwner else {
                throw ProjectRunLeaseError.unsafeProject
            }
            leasedProjectRootIdentity = try projectRunLeaseOwner
                .lockedProjectRootIdentity()
        } catch {
            statusTitle = error.localizedDescription
            statusDetail = "The project stayed in place. Try again when processing finishes."
            lastError = statusTitle
            errorDetails = String(reflecting: error)
            progress = nil
            presentPendingNotesSaveFailureIfNeeded(at: projectURL)
            return false
        }
        if ProjectSummary.hasSameLocation(currentProjectURL, projectURL) {
            guard flushPendingNotesSave(
                projectRunLeaseOwner: projectRunLeaseOwner
            ) else { return false }
        }
        do {
            try moveIdentityBoundProjectToTrash(
                at: projectURL,
                leasedProjectRootIdentity: leasedProjectRootIdentity
            )
        } catch {
            let quarantineError = error as? ProjectTrashQuarantineError
            let message: String
            if quarantineError?.isIdentityConflict == true {
                message = "The project folder changed while it was being moved. Every item was preserved. Check Finder and try again."
            } else {
                message = "The project stayed in place. Check Finder permissions and try again."
            }
            statusTitle = "Couldn’t move project to Trash"
            statusDetail = message
            lastError = statusTitle
            errorDetails = String(reflecting: error)
            progress = nil
            actionFailure = ActionFailurePresentation(
                title: "Couldn’t move project to Trash",
                message: message
            )
            refreshProjectSummaries()
            return false
        }
        if ProjectSummary.hasSameLocation(currentProjectURL, projectURL) {
            reset(projectRunLeaseOwner: projectRunLeaseOwner)
            viewState = .home
        }
        refreshProjectSummaries()
        return true
    }

    private func moveIdentityBoundProjectToTrash(
        at requestedProjectURL: URL,
        leasedProjectRootIdentity: AppProjectRootIdentity
    ) throws {
        let projectURL = requestedProjectURL.standardizedFileURL
        let parentURL = projectURL.deletingLastPathComponent()
            .standardizedFileURL
        let projectLeaf = projectURL.lastPathComponent
        guard Self.isSafeTrashLeaf(projectLeaf),
              parentURL.appendingPathComponent(
                projectLeaf,
                isDirectory: true
              ).standardizedFileURL.path == projectURL.path else {
            throw ProjectTrashQuarantineError.invalidProjectPath
        }

        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ProjectTrashQuarantineError.system(
                operation: "Opening the project folder",
                code: errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        let parentIdentity = try AppProjectRootIdentity.capture(
            descriptor: parentDescriptor
        )
        guard try AppProjectRootIdentity.capture(at: parentURL)
                == parentIdentity,
              try Self.trashLeafState(
                parentDescriptor: parentDescriptor,
                leaf: projectLeaf
              ).matches(leasedProjectRootIdentity) else {
            throw ProjectTrashQuarantineError.identityConflict(
                "The selected project path no longer names the leased project."
            )
        }

        try projectTrashQuarantineCheckpointHook.handle(
            .canonicalIdentityValidated
        )

        let quarantineLeaf = ".easysplat-trash-\(UUID().uuidString.lowercased())"
        try Self.renameTrashLeaf(
            parentDescriptor: parentDescriptor,
            sourceLeaf: projectLeaf,
            destinationLeaf: quarantineLeaf
        )
        do {
            try Self.syncTrashParent(parentDescriptor)
        } catch {
            _ = try? Self.restoreTrashLeafIfCanonicalAbsent(
                parentDescriptor: parentDescriptor,
                quarantineLeaf: quarantineLeaf,
                canonicalLeaf: projectLeaf
            )
            throw error
        }

        let quarantineState = try Self.trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: quarantineLeaf
        )
        guard quarantineState.matches(leasedProjectRootIdentity) else {
            _ = try? Self.restoreTrashLeafIfCanonicalAbsent(
                parentDescriptor: parentDescriptor,
                quarantineLeaf: quarantineLeaf,
                canonicalLeaf: projectLeaf
            )
            throw ProjectTrashQuarantineError.identityConflict(
                "The project leaf changed before it could be quarantined."
            )
        }

        let quarantineDescriptor = quarantineLeaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard quarantineDescriptor >= 0 else {
            _ = try? Self.restoreTrashLeafIfCanonicalAbsent(
                parentDescriptor: parentDescriptor,
                quarantineLeaf: quarantineLeaf,
                canonicalLeaf: projectLeaf
            )
            throw ProjectTrashQuarantineError.identityConflict(
                "The quarantined project could not be reopened safely."
            )
        }
        defer { Darwin.close(quarantineDescriptor) }

        guard try AppProjectRootIdentity.capture(
            descriptor: quarantineDescriptor
        ) == leasedProjectRootIdentity,
        try AppProjectRootIdentity.capture(at: parentURL) == parentIdentity,
        case .absent = try Self.trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: projectLeaf
        ) else {
            _ = try? Self.restoreTrashLeafIfCanonicalAbsent(
                parentDescriptor: parentDescriptor,
                quarantineLeaf: quarantineLeaf,
                canonicalLeaf: projectLeaf
            )
            throw ProjectTrashQuarantineError.identityConflict(
                "The project namespace changed before the Trash operation."
            )
        }

        let quarantineURL = parentURL.appendingPathComponent(
            quarantineLeaf,
            isDirectory: true
        )
        do {
            try projectTrashHandler(quarantineURL)
        } catch {
            try Self.syncTrashParent(parentDescriptor)
            let outcome = try Self.reconcileTrashHandlerFailure(
                parentDescriptor: parentDescriptor,
                canonicalLeaf: projectLeaf,
                quarantineLeaf: quarantineLeaf,
                expectedIdentity: leasedProjectRootIdentity
            )
            switch outcome {
            case .completed:
                return
            case .restored:
                throw ProjectTrashQuarantineError.handlerFailure(error)
            case .conflict:
                throw ProjectTrashQuarantineError.identityConflict(
                    "The Trash handler failed after the project namespace changed."
                )
            }
        }
        try Self.syncTrashParent(parentDescriptor)

        let outcome = try Self.reconcileSuccessfulTrashHandler(
            parentDescriptor: parentDescriptor,
            canonicalLeaf: projectLeaf,
            quarantineLeaf: quarantineLeaf,
            expectedIdentity: leasedProjectRootIdentity
        )
        switch outcome {
        case .completed:
            return
        case .restored:
            throw ProjectTrashQuarantineError.handlerDidNotMove
        case .conflict:
            throw ProjectTrashQuarantineError.identityConflict(
                "The Trash handler returned after the project namespace changed."
            )
        }
    }

    private static func reconcileTrashHandlerFailure(
        parentDescriptor: Int32,
        canonicalLeaf: String,
        quarantineLeaf: String,
        expectedIdentity: AppProjectRootIdentity
    ) throws -> ProjectTrashHandlerOutcome {
        let canonicalState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: canonicalLeaf
        )
        let quarantineState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: quarantineLeaf
        )
        if case .absent = quarantineState {
            if canonicalState.matches(expectedIdentity) {
                return .restored
            }
            if case .absent = canonicalState {
                return .completed
            }
            return .conflict
        }
        guard quarantineState.matches(expectedIdentity) else {
            return .conflict
        }
        if canonicalState.matches(expectedIdentity) {
            return .restored
        }
        guard case .absent = canonicalState else {
            return .conflict
        }
        guard try restoreTrashLeafIfCanonicalAbsent(
            parentDescriptor: parentDescriptor,
            quarantineLeaf: quarantineLeaf,
            canonicalLeaf: canonicalLeaf
        ) else {
            return .conflict
        }
        let restoredCanonicalState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: canonicalLeaf
        )
        let restoredQuarantineState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: quarantineLeaf
        )
        guard restoredCanonicalState.matches(expectedIdentity),
              case .absent = restoredQuarantineState else {
            return .conflict
        }
        return .restored
    }

    private static func reconcileSuccessfulTrashHandler(
        parentDescriptor: Int32,
        canonicalLeaf: String,
        quarantineLeaf: String,
        expectedIdentity: AppProjectRootIdentity
    ) throws -> ProjectTrashHandlerOutcome {
        let canonicalState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: canonicalLeaf
        )
        let quarantineState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: quarantineLeaf
        )
        if case .absent = quarantineState {
            return canonicalState.matches(expectedIdentity)
                ? .restored
                : .completed
        }
        guard quarantineState.matches(expectedIdentity) else {
            return .conflict
        }
        guard case .absent = canonicalState else {
            return .conflict
        }
        guard try restoreTrashLeafIfCanonicalAbsent(
            parentDescriptor: parentDescriptor,
            quarantineLeaf: quarantineLeaf,
            canonicalLeaf: canonicalLeaf
        ) else {
            return .conflict
        }
        let restoredCanonicalState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: canonicalLeaf
        )
        let restoredQuarantineState = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: quarantineLeaf
        )
        guard restoredCanonicalState.matches(expectedIdentity),
              case .absent = restoredQuarantineState else {
            return .conflict
        }
        return .restored
    }

    private static func restoreTrashLeafIfCanonicalAbsent(
        parentDescriptor: Int32,
        quarantineLeaf: String,
        canonicalLeaf: String
    ) throws -> Bool {
        guard case .absent = try trashLeafState(
            parentDescriptor: parentDescriptor,
            leaf: canonicalLeaf
        ) else {
            return false
        }
        do {
            try renameTrashLeaf(
                parentDescriptor: parentDescriptor,
                sourceLeaf: quarantineLeaf,
                destinationLeaf: canonicalLeaf
            )
        } catch let error as ProjectTrashQuarantineError {
            if case .system(_, let code) = error,
               code == EEXIST || code == ENOTEMPTY {
                return false
            }
            throw error
        }
        try syncTrashParent(parentDescriptor)
        return true
    }

    private static func trashLeafState(
        parentDescriptor: Int32,
        leaf: String
    ) throws -> ProjectTrashLeafState {
        var status = stat()
        let statusResult = leaf.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if statusResult != 0 {
            let code = errno
            if code == ENOENT { return .absent }
            throw ProjectTrashQuarantineError.system(
                operation: "Inspecting the project namespace",
                code: code
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return .other }
        let descriptor = leaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return .other }
        defer { Darwin.close(descriptor) }
        return .directory(
            try AppProjectRootIdentity.capture(descriptor: descriptor)
        )
    }

    private static func renameTrashLeaf(
        parentDescriptor: Int32,
        sourceLeaf: String,
        destinationLeaf: String
    ) throws {
        let result = sourceLeaf.withCString { sourcePointer in
            destinationLeaf.withCString { destinationPointer in
                Darwin.renameatx_np(
                    parentDescriptor,
                    sourcePointer,
                    parentDescriptor,
                    destinationPointer,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard result == 0 else {
            throw ProjectTrashQuarantineError.system(
                operation: "Renaming the project",
                code: errno
            )
        }
    }

    private static func syncTrashParent(_ descriptor: Int32) throws {
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code != EINVAL && code != ENOTSUP {
                throw ProjectTrashQuarantineError.system(
                    operation: "Saving the project folder change",
                    code: code
                )
            }
            break
        }
        while Darwin.fsync(descriptor) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw ProjectTrashQuarantineError.system(
                operation: "Saving the project folder change",
                code: code
            )
        }
    }

    private static func isSafeTrashLeaf(_ leaf: String) -> Bool {
        !leaf.isEmpty
            && leaf != "."
            && leaf != ".."
            && !leaf.contains("/")
            && !leaf.contains("\\")
            && !leaf.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
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
        if let exitDecisionOverride {
            return exitDecisionOverride()
        }
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
        photoURLs: [URL]? = nil,
        datasetInputSource: DatasetInputSource? = nil,
        title: String,
        taskToken: UUID? = nil,
        timingBoundary: RunTimingBoundary? = nil
    ) async -> ToolchainPaths? {
        guard isCurrentTaskToken(taskToken) else { return nil }
        let timingBoundary = timingBoundary ?? .capture()
        var projectRunLeaseOwner: AppProjectRunLeaseOwner?
        defer { projectRunLeaseOwner?.release() }
        defer {
            finishRun(
                taskToken: taskToken,
                projectRunLeaseOwner: projectRunLeaseOwner
            )
        }
        reset(projectRunLeaseOwner: projectRunLeaseOwner)
        viewState = .processing
        phaseStartedAt = Date()
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil
        var preparedVideoInput: PreparedVideoInput?
        var preparedPhotoInput: PreparedPhotoInput?
        var preparedDatasetInput: PreparedDatasetInput?
        var projectPublication: ProjectPublicationTransaction?
        var emptyMixedPhotoInput = false
        var runnerStarted = false
        defer { preparedVideoInput?.discard() }
        defer { preparedPhotoInput?.discard() }
        defer { preparedDatasetInput?.discard() }
        defer { try? projectPublication?.abort() }

        do {
            let requestedOptions = requestedRunOptions
            try RunPlanResolver.validate(
                requestedOptions: requestedOptions,
                input: input,
                hardware: hardwareProfile
            )
            let developmentOverrides = AppConfig.currentDevelopmentOverrides
            var resolvedRunPlan = RunPlanResolver.resolve(
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

            if input.isDataset {
                statusTitle = "Checking dataset"
                statusDetail = nil
                progress = nil
                guard let datasetKind = input.datasetKind, let datasetInputSource else {
                    throw DatasetInputError.unreadableDataset
                }
                let prepared = try await datasetInputPreflight(
                    datasetInputSource,
                    datasetKind,
                    projectBaseDirectory()
                )
                preparedDatasetInput = prepared
                // The imported poses fix the geometry route and image count, so
                // re-resolve the plan with that context before the images ride
                // the photo admission machinery.
                resolvedRunPlan = RunPlanResolver.resolve(
                    requestedOptions: requestedOptions,
                    input: input,
                    hardware: hardwareProfile,
                    developmentOverrides: developmentOverrides,
                    datasetImport: RunPlanResolver.DatasetImportContext(
                        route: prepared.plan.route,
                        imageCount: prepared.imageCount,
                        maximumImagePixelDimension: prepared.maximumImagePixelDimension
                    )
                )
                guard isCurrentTaskToken(taskToken) else { return nil }
                let datasetReserveBytes = VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
                    keyframeBudget: resolvedRunPlan.keyframeBudget,
                    maximumImageDimension: resolvedRunPlan.maximumImageDimension,
                    maximumFeatureCount: resolvedRunPlan.colmapMaximumFeatureCount,
                    maximumMatchCount: resolvedRunPlan.colmapMaximumMatchCount,
                    retrievalCandidateCount: resolvedRunPlan.retrievalCandidateCount
                )
                let datasetPhotoLimits = PhotoInputPreflightLimits(
                    maximumDecodedDimension: min(4_096, resolvedRunPlan.maximumImageDimension)
                )
                let onDatasetProgress: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentTaskToken(taskToken) else { return }
                        self.progress = fraction
                        self.statusTitle = "Checking dataset"
                        self.statusDetail = message
                    }
                }
                let datasetPhotoInput = try await PhotoInputPreflight.prepare(
                    photos: prepared.stagedImages.map(\.url),
                    stagingParent: projectBaseDirectory(),
                    photoSelection: resolvedRunPlan.photoSelection,
                    inputOrdering: resolvedRunPlan.inputOrdering,
                    keyframeBudget: resolvedRunPlan.keyframeBudget,
                    requiredAtomicWorkspaceReserveBytes: datasetReserveBytes,
                    limits: datasetPhotoLimits,
                    progress: onDatasetProgress
                )
                preparedPhotoInput = datasetPhotoInput
                try RunPlanResolver.validatePhotoSelection(
                    validPhotoCount: datasetPhotoInput.summary.validPhotoCount,
                    resolvedPlan: resolvedRunPlan,
                    input: input
                )
            } else if input.hasPhotos {
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
                let photoReserveBytes = VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
                    keyframeBudget: resolvedRunPlan.keyframeBudget,
                    maximumImageDimension: resolvedRunPlan.maximumImageDimension,
                    maximumFeatureCount: resolvedRunPlan.colmapMaximumFeatureCount,
                    maximumMatchCount: resolvedRunPlan.colmapMaximumMatchCount,
                    retrievalCandidateCount: resolvedRunPlan.retrievalCandidateCount
                )
                let photoLimits = PhotoInputPreflightLimits(
                    maximumDecodedDimension: min(4_096, resolvedRunPlan.maximumImageDimension)
                )
                let onPhotoProgress: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentTaskToken(taskToken) else { return }
                        self.progress = fraction
                        self.statusTitle = "Checking photos"
                        self.statusDetail = message
                    }
                }
                do {
                    // Selection supplies an explicit file list (which may span
                    // several folders); callers that still name a single folder
                    // fall back to the hardened folder walk.
                    if let photoURLs {
                        preparedPhotoInput = try await PhotoInputPreflight.prepare(
                            photos: photoURLs,
                            stagingParent: projectBaseDirectory(),
                            photoSelection: resolvedRunPlan.photoSelection,
                            inputOrdering: resolvedRunPlan.inputOrdering,
                            keyframeBudget: photoBudget,
                            requiredAtomicWorkspaceReserveBytes: photoReserveBytes,
                            limits: photoLimits,
                            progress: onPhotoProgress
                        )
                    } else if let photosFolder = input.photosFolder {
                        preparedPhotoInput = try await PhotoInputPreflight.prepare(
                            folder: URL(fileURLWithPath: photosFolder, isDirectory: true),
                            stagingParent: projectBaseDirectory(),
                            photoSelection: resolvedRunPlan.photoSelection,
                            inputOrdering: resolvedRunPlan.inputOrdering,
                            keyframeBudget: photoBudget,
                            requiredAtomicWorkspaceReserveBytes: photoReserveBytes,
                            limits: photoLimits,
                            progress: onPhotoProgress
                        )
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
            let toolchain = try await toolchainManager.resolveToolchain(
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
            if let preparedDatasetInput, let preparedPhotoInput {
                // Dataset images are photo-carried; adoption admits them and
                // binds the pose seed, so this reuses the photosAdopted gate.
                try inputAdoption.adoptDataset(
                    preparedDatasetInput,
                    into: paths,
                    photoInput: preparedPhotoInput
                )
                try publication.reached(.photosAdopted)
            } else if let preparedPhotoInput {
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
                datasetPoseSeed: inputAdoption.datasetPoseSeed,
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
            projectRunLeaseOwner = try acquireAppProjectRunLeaseOwner(
                at: projectURL
            )
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
                    prePipelineStartedAt: timingBoundary.startedAt,
                    projectRunLeaseOwner: projectRunLeaseOwner
                )
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            runnerStarted = true
            try await runner.run(
                resumeFrom: Optional<PipelineStage>.none,
                freshPublicationAttestation: freshPublication.attestation
            ) { event in
                forwarder.handle(event)
            }
            guard isCurrentTaskToken(taskToken) else { return nil }

            guard let outputURL = try await validatedFinishedOutputURL(projectURL: projectURL) else {
                presentOutputMissingFailure(
                    projectURL: projectURL,
                    projectRunLeaseOwner: projectRunLeaseOwner
                )
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
            let viewerTimingAuthority: BoundResultViewerTimingAuthority?
            do {
                viewerTimingAuthority = try await resolveBoundViewerTimingAuthority(
                    projectID: projectID,
                    projectURL: projectURL,
                    outputURL: outputURL,
                    projectRunLeaseOwner: projectRunLeaseOwner
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                viewerTimingAuthority = nil
            }
            guard isCurrentTaskToken(taskToken) else { return nil }
            if let viewerTimingAuthority {
                prepareResultViewerTiming(
                    projectID: projectID,
                    projectURL: projectURL,
                    outputURL: outputURL,
                    expectedPublicationID:
                        viewerTimingAuthority.publicationID,
                    expectedGeneration: viewerTimingAuthority.generation,
                    projectRootIdentity:
                        viewerTimingAuthority.projectRootIdentity,
                    boundary: timingBoundary
                )
            } else {
                // A validated legacy output may still open, but without a
                // receipt UUID there is no authority to update. Keep the
                // healthy viewer available and skip this optional timing.
                cancelResultViewerTiming()
            }
            await reloadSubjectIsolationArtifact(for: projectURL)
            guard isCurrentTaskToken(taskToken) else { return nil }
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
            errorDetails = "Preflight stopped before preparing tools or creating a project."
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
            if case .accessDenied(let relativePath) = failure.issue {
                let presentation = Self.accessDeniedPresentation(name: relativePath)
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
                errorDetails = "Preflight stopped before preparing tools or creating a project."
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
        } catch let error as DatasetInputError {
            guard isCurrentTaskToken(taskToken) else { return nil }
            lastError = "Dataset couldn’t be imported"
            statusTitle = "Dataset couldn’t be imported"
            statusDetail = nil
            errorDetails = error.localizedDescription
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
            let metadataFailure = error as? PipelineMetadataPersistenceFailure
            let failureMessage = metadataFailure?.originalProcessingFailure?.userMessage
                ?? lastError
                ?? stopFailureCopy?.detail
                ?? fallbackMessage
            if lastError == nil {
                lastError = failureMessage
            }
            if let metadataFailure {
                if !metadataFailure.terminalFailureWasPersisted,
                   let projectURL = currentProjectURL {
                    do {
                        try persistProjectFailureChecked(
                            failureMessage,
                            stage: metadataFailure.stage,
                            at: projectURL,
                            projectRunLeaseOwner: projectRunLeaseOwner
                        )
                    } catch {
                        presentUnsavedProjectState(
                            pipelineFailure: metadataFailure,
                            fallbackError: error
                        )
                        return nil
                    }
                }
            } else if !runnerStarted,
                      let projectURL = currentProjectURL,
                      !persistProjectFailureOrPresentUnsaved(
                        failureMessage,
                        stage: nil,
                        at: projectURL,
                        projectRunLeaseOwner: projectRunLeaseOwner,
                        primaryFailureDescription: String(reflecting: error)
                      ) {
                return nil
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
        if let denied = failure.rejectedVideos.first(where: { $0.issue == .accessDenied }) {
            return accessDeniedPresentation(name: denied.safeDisplayName)
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
        case .noVideosSelected, .sourceUnavailable, .accessDenied, .symbolicLink,
             .notRegularFile, .emptyFile, .duplicateSource, .sourceChanged,
             .tooManyVideos, .totalBytesExceeded, .invalidLimits:
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
        case .accessDenied:
            return "macOS did not let EasySplat read the file — choose it again"
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

    /// macOS refused the read. The file is where the user left it, so the answer
    /// is to grant access again rather than to look for a damaged photo.
    static func accessDeniedPresentation(name: String) -> (title: String, details: String) {
        (
            title: "EasySplat can’t read your files",
            details: """
            macOS did not let EasySplat read “\(name)”.
            Choose your photos or video again, then start the splat.
            """
        )
    }

    static func unsupportedSphericalMediaPresentation(
        _ issue: UnsupportedSphericalMediaIssue
    ) -> (title: String, details: String) {
        (
            title: "This appears to be 180°/360° panoramic media. EasySplat does not yet unwrap spherical captures. Export ordinary perspective views and try again.",
            details: "Detected standardized projection tag: \(issue.tag.rawValue)."
        )
    }

    func resumeProjectTask(
        at url: URL,
        taskToken: UUID? = nil,
        bypassFinishedOutput: Bool = false,
        projectRunLeaseOwner suppliedProjectRunLeaseOwner:
            AppProjectRunLeaseOwner? = nil,
        timingBoundary: RunTimingBoundary? = nil
    ) async {
        var projectRunLeaseOwner = suppliedProjectRunLeaseOwner
        // Registered before finishRun so the app's terminal handling, fallback
        // persistence, and optional Trash move all execute while ownership is
        // still held. Swift runs defers in reverse order.
        defer { projectRunLeaseOwner?.release() }
        guard isCurrentTaskToken(taskToken) else { return }
        defer {
            finishRun(
                taskToken: taskToken,
                projectRunLeaseOwner: projectRunLeaseOwner
            )
        }
        reset(projectRunLeaseOwner: projectRunLeaseOwner)
        // Immediately after reset, before any suspension: the opened project
        // must stay current across the whole task so selection and the
        // sidebar's lock never see a run with no project.
        currentProjectURL = url
        viewState = .opening
        phaseStartedAt = Date()
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil
        var runnerStarted = false

        do {
            let paths = ProjectPaths(root: url)
            let openedProjectRootIdentity = try AppProjectRootIdentity.capture(
                at: url
            )
            var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
            if metadata.input.hasVideos {
                statusDetail = "Checking saved videos"
                let metadataSnapshot = metadata
                try await Task.detached(priority: .userInitiated) {
                    try VideoInputReceiptValidator.validateFiles(
                        metadata: metadataSnapshot,
                        paths: paths
                    )
                }.value
            }
            if metadata.input.isDataset, let datasetPoseSeed = metadata.datasetPoseSeed {
                // Datasets ride the photo machinery, but their pose seed and
                // source images have their own receipt; re-verify it on resume
                // exactly as videos re-verify their staged copies.
                statusDetail = "Checking saved dataset"
                try await Task.detached(priority: .userInitiated) {
                    try DatasetPoseSeedReceiptValidator.validateFiles(
                        receipt: datasetPoseSeed,
                        projectRoot: url
                    )
                }.value
            }
            var resumeTimingAuthority: BoundResultViewerTimingAuthority?
            if !bypassFinishedOutput,
               metadata.createToViewerReadySeconds == nil {
                do {
                    resumeTimingAuthority = try await
                        resolveResumeViewerTimingAuthority(
                            projectID: metadata.id,
                            projectURL: url,
                            outputURL: paths.outputSplatURL,
                            openedProjectRootIdentity:
                                openedProjectRootIdentity,
                            projectRunLeaseOwner: projectRunLeaseOwner
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Healing is optional. A concurrent processor owns the
                    // right to mutate this project, while the validated
                    // result remains safe to open read-only.
                    resumeTimingAuthority = nil
                }
                guard isCurrentTaskToken(taskToken) else { return }
            }
            let finishedOutputURL: URL?
            if bypassFinishedOutput {
                finishedOutputURL = nil
            } else if resumeTimingAuthority != nil {
                // The authority resolver has already descriptor-validated the
                // exact canonical PLY/receipt pair. Do not hash it again in a
                // second pathname-based result decision.
                finishedOutputURL = paths.outputSplatURL
            } else {
                finishedOutputURL = try await validatedFinishedOutputURL(
                    projectURL: url
                )
            }
            currentRunOptions = metadata.requestedRunOptions
            currentInput = metadata.input
            if !bypassFinishedOutput,
               let outputURL = finishedOutputURL {
                guard isCurrentTaskToken(taskToken) else { return }
                outputPlyURL = outputURL
                currentStageTimings = metadata.stageTimings ?? []
                currentCreateToViewerReadySeconds = metadata.createToViewerReadySeconds
                currentOutputPlyInfo = OutputPlyInfo.load(from: outputURL)
                currentProjectNotes = metadata.notes ?? ""
                markProjectOpened(at: url)
                if let authority = resumeTimingAuthority,
                   let elapsedSeconds = authority.elapsedSeconds {
                    prepareResultViewerTimingMetadataHealing(
                        projectID: metadata.id,
                        projectURL: url,
                        outputURL: outputURL,
                        expectedPublicationID: authority.publicationID,
                        expectedGeneration: authority.generation,
                        elapsedSeconds: elapsedSeconds,
                        projectRootIdentity:
                            authority.projectRootIdentity
                    )
                }
                await reloadSubjectIsolationArtifact(for: url)
                guard isCurrentTaskToken(taskToken) else { return }
                viewState = .viewer
                refreshProjectSummaries()
                return
            }
            // No validated finished output, so this resume re-runs the pipeline.
            if projectRunLeaseOwner == nil {
                projectRunLeaseOwner = try acquireAppProjectRunLeaseOwner(at: url)
            }
            guard let projectRunLeaseOwner else {
                throw ProjectRunLeaseBorrowError.released
            }
            metadata = try projectRunLeaseOwner
                .withLockedProjectRootDescriptor {
                    try ProjectMetadataStore.load(
                        fromProjectRootDescriptor: $0
                    )
                }
            if metadata.input.hasVideos {
                let metadataSnapshot = metadata
                try await Task.detached(priority: .userInitiated) {
                    try VideoInputReceiptValidator.validateFiles(
                        metadata: metadataSnapshot,
                        paths: paths
                    )
                }.value
            }
            if metadata.input.isDataset,
               let datasetPoseSeed = metadata.datasetPoseSeed {
                try await Task.detached(priority: .userInitiated) {
                    try DatasetPoseSeedReceiptValidator.validateFiles(
                        receipt: datasetPoseSeed,
                        projectRoot: url
                    )
                }.value
            }
            currentRunOptions = metadata.requestedRunOptions
            currentInput = metadata.input
            viewState = .processing
            refreshProjectSummaries()
            let developmentOverrides = AppConfig.currentDevelopmentOverrides
            let requestedOptions = metadata.requestedRunOptions
            try RunPlanResolver.validate(
                requestedOptions: requestedOptions,
                input: metadata.input,
                hardware: hardwareProfile
            )
            let datasetImport = metadata.datasetPoseSeed.map { seed in
                // Dataset images are adopted unscaled, so the photo receipts
                // reproduce preflight's measured pixel ceiling; feeding it back
                // keeps the resumed plan identical to the fresh run's.
                RunPlanResolver.DatasetImportContext(
                    route: seed.route,
                    imageCount: seed.imageCount,
                    maximumImagePixelDimension: metadata.photoInputReceipts?
                        .map { max($0.pixelWidth, $0.pixelHeight) }
                        .max()
                )
            }
            let resolvedRunPlan = RunPlanResolver.resolve(
                requestedOptions: requestedOptions,
                input: metadata.input,
                hardware: hardwareProfile,
                developmentOverrides: developmentOverrides,
                trainingMemoryRetryBudgetBytes: metadata.trainingMemoryRetryBudgetBytes,
                datasetImport: datasetImport
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

            // A resume that must re-run holds the awake assertion across toolchain
            // validation and the run; a resume that just opens a ready project
            // (returned above) never reaches here, so it does not hold one.
            let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(reason: "EasySplat is preparing and resuming a project")
            defer { idleSleepAssertion.release() }

            statusTitle = "Preparing tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self, taskToken: taskToken)
            let toolchain = try await toolchainManager.resolveToolchain(
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
                    developmentOverrides: developmentOverrides,
                    runIntent: bypassFinishedOutput ? .retrain : .resume,
                    projectRunLeaseOwner: projectRunLeaseOwner
                )
            )
            let forwarder = EventForwarder(model: self, taskToken: taskToken)
            let requestedResumeBoundary: PipelineStage? = bypassFinishedOutput
                ? .sfmMapping
                : resumeStage(from: metadata)
            let stageToResume = RunPlanResolver.safeResumeStage(
                requestedResumeBoundary,
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
                presentOutputMissingFailure(
                    projectURL: url,
                    projectRunLeaseOwner: projectRunLeaseOwner
                )
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
            if let timingBoundary {
                let viewerTimingAuthority: BoundResultViewerTimingAuthority?
                do {
                    viewerTimingAuthority = try await
                        resolveBoundViewerTimingAuthority(
                            projectID: metadata.id,
                            projectURL: url,
                            outputURL: outputURL,
                            projectRunLeaseOwner: projectRunLeaseOwner
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    viewerTimingAuthority = nil
                }
                guard isCurrentTaskToken(taskToken) else { return }
                if let viewerTimingAuthority {
                    prepareResultViewerTiming(
                        projectID: metadata.id,
                        projectURL: url,
                        outputURL: outputURL,
                        expectedPublicationID:
                            viewerTimingAuthority.publicationID,
                        expectedGeneration: viewerTimingAuthority.generation,
                        projectRootIdentity:
                            viewerTimingAuthority.projectRootIdentity,
                        boundary: timingBoundary
                    )
                }
            }
            refreshFreeDiskSpace()
            await reloadSubjectIsolationArtifact(for: url)
            guard isCurrentTaskToken(taskToken) else { return }
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
            errorDetails = "Resume preflight stopped before preparing tools or changing project files."
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
        } catch let error as ProjectRunLeaseError {
            guard isCurrentTaskToken(taskToken) else { return }
            presentProjectMutationFailure(
                error,
                fallbackTitle: "Couldn’t resume this project"
            )
            errorDetails = String(reflecting: error)
            progress = nil
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
            let metadataFailure = error as? PipelineMetadataPersistenceFailure
            let failureMessage = metadataFailure?.originalProcessingFailure?.userMessage
                ?? lastError
                ?? stopFailureCopy?.detail
                ?? fallbackMessage
            if lastError == nil {
                lastError = failureMessage
            }
            if runnerStarted {
                if let metadataFailure {
                    if !metadataFailure.terminalFailureWasPersisted {
                        do {
                            try persistProjectFailureChecked(
                                failureMessage,
                                stage: metadataFailure.stage,
                                at: url,
                                projectRunLeaseOwner: projectRunLeaseOwner
                            )
                        } catch {
                            presentUnsavedProjectState(
                                pipelineFailure: metadataFailure,
                                fallbackError: error
                            )
                            return
                        }
                    }
                }
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
        guard error is ToolchainManager.ToolchainError else {
            return "Couldn’t prepare the required tools."
        }
        return "EasySplat’s built-in tools are missing or damaged. Reinstall EasySplat."
    }

    private func failureTechnicalDetails(for error: Error) -> String {
        var lines = ["Underlying error: \(String(reflecting: error))"]
        if AppConfig.allowsDevelopmentOverrides {
            lines.append(
                "Development builds resolve tools from EASYSPLAT_LOCAL_TOOLCHAIN_ROOT."
            )
        }
        return lines.joined(separator: "\n")
    }

    func reset(
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) {
        cancelForcedExitIfNeeded()
        cancelResultViewerTiming()
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
        let notesSaved = flushPendingNotesSave(
            projectRunLeaseOwner: projectRunLeaseOwner
        )
        outputPlyURL = nil
        clearTrainingPreview()
        currentStageTimings = []
        currentCreateToViewerReadySeconds = nil
        currentOutputPlyInfo = nil
        currentRunOptions = nil
        currentInput = nil
        currentProjectNotes = ""
        currentProjectURL = nil
        stopAction = nil
        cancelSharing()
        clearSubjectIsolationSession()
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

    func finishRun(
        taskToken: UUID?,
        projectRunLeaseOwner: AppProjectRunLeaseOwner?
    ) {
        guard currentTaskToken == taskToken else { return }
        currentTask = nil
        currentTaskToken = nil
        isRunActive = false
        if stopAction != nil {
            completeStop(projectRunLeaseOwner: projectRunLeaseOwner)
        } else {
            refreshProjectSummaries()
        }
    }

    func presentOutputMissingFailure(
        projectURL: URL,
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) {
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
        guard persistProjectFailureOrPresentUnsaved(
            message,
            stage: nil,
            at: projectURL,
            projectRunLeaseOwner: projectRunLeaseOwner,
            primaryFailureDescription: errorDetails ?? message
        ) else {
            return
        }
        appendLogLine("[err] \(message)", isError: true)
        viewState = .processing
        refreshProjectSummaries()
    }

    @discardableResult
    private func persistProjectFailureChecked(
        _ message: String,
        stage: PipelineStage?,
        at projectURL: URL,
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) throws -> ProjectMetadata {
        try updateProjectMetadata(
            at: projectURL,
            leaseOwner: projectRunLeaseOwner
        ) { metadata in
            metadata.state = PipelineState(
                stage: stage ?? metadata.state.stage,
                lastError: message
            )
            metadata.checkpoint = nil
            metadata.lastRunStartedAt = nil
            metadata.lastFailureAt = Date()
        }
    }

    private func persistProjectFailureOrPresentUnsaved(
        _ message: String,
        stage: PipelineStage?,
        at projectURL: URL,
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil,
        primaryFailureDescription: String
    ) -> Bool {
        do {
            try persistProjectFailureChecked(
                message,
                stage: stage,
                at: projectURL,
                projectRunLeaseOwner: projectRunLeaseOwner
            )
            return true
        } catch {
            presentUnsavedProjectState(
                primaryFailureDescription: primaryFailureDescription,
                fallbackError: error
            )
            return false
        }
    }

    private func presentUnsavedProjectState(
        pipelineFailure: PipelineMetadataPersistenceFailure,
        fallbackError: Error
    ) {
        var details = [
            "Pipeline metadata failure: \(pipelineFailure.localizedDescription)",
            "Fallback metadata failure: \(String(reflecting: fallbackError))",
        ]
        if let original = pipelineFailure.originalProcessingFailure {
            details.append("Original processing message: \(original.userMessage)")
            details.append("Original technical details: \(original.technicalMessage)")
        }
        presentUnsavedProjectState(details: details)
    }

    private func presentUnsavedProjectState(
        primaryFailureDescription: String,
        fallbackError: Error
    ) {
        presentUnsavedProjectState(details: [
            "Processing failure: \(primaryFailureDescription)",
            "Fallback metadata failure: \(String(reflecting: fallbackError))",
        ])
    }

    private func presentUnsavedProjectState(details: [String]) {
        let message = "Project state wasn’t saved. Free up disk space or restore write access, then try again. Work after the last saved stage may repeat."
        cancelForcedExitIfNeeded()
        stopAction = nil
        abortPendingExitAfterStopFailure()
        lastError = message
        statusTitle = message
        statusDetail = nil
        progress = nil
        failureRetryAllowed = true
        errorDetails = details.joined(separator: "\n")
        viewState = .processing
    }

    func acquireAppProjectRunLeaseOwner(
        at projectURL: URL
    ) throws -> AppProjectRunLeaseOwner {
        try AppProjectRunLeaseOwner(
            projectURL: projectURL,
            acquire: projectRunLeaseOwnerAcquirer
        )
    }

    @discardableResult
    func updateProjectMetadata(
        at projectURL: URL,
        leaseOwner suppliedLeaseOwner: AppProjectRunLeaseOwner? = nil,
        mutation: @escaping ProjectMetadataMutation
    ) throws -> ProjectMetadata {
        let acquiredLeaseOwner: AppProjectRunLeaseOwner?
        if suppliedLeaseOwner == nil {
            acquiredLeaseOwner = try acquireAppProjectRunLeaseOwner(
                at: projectURL
            )
        } else {
            acquiredLeaseOwner = nil
        }
        defer { acquiredLeaseOwner?.release() }
        let leaseOwner = suppliedLeaseOwner ?? acquiredLeaseOwner
        guard let leaseOwner else {
            throw ProjectRunLeaseBorrowError.released
        }
        return try leaseOwner.withLockedProjectRootDescriptor {
            projectRootDescriptor in
            try projectMetadataUpdater(projectRootDescriptor, mutation)
        }
    }

    func presentProjectMutationFailure(
        _ error: Error?,
        fallbackTitle: String
    ) {
        if let leaseError = error as? ProjectRunLeaseError {
            statusTitle = leaseError.localizedDescription
            statusDetail = "The project was not changed. Try again when processing finishes."
        } else {
            statusTitle = fallbackTitle
            statusDetail = "The project was not changed. Check folder permissions and try again."
        }
        lastError = statusTitle
    }

    func pipelineConfig(
        toolchain: ToolchainPaths,
        resolvedRunPlan: ResolvedRunPlan? = nil,
        developmentOverrides: DevelopmentOverrides = AppConfig.currentDevelopmentOverrides,
        prePipelineDurationSeconds: TimeInterval = 0,
        prePipelineStartedAt: Date? = nil,
        runIntent: PipelineRunner.RunIntent = .resume,
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) -> PipelineRunner.PipelineConfig {
        let config = PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: developmentOverrides,
            hardwareProfile: hardwareProfile,
            resolvedRunPlan: resolvedRunPlan,
            prePipelineDurationSeconds: prePipelineDurationSeconds,
            prePipelineStartedAt: prePipelineStartedAt,
            // Deliberately not tied to the display preference. Publication is what
            // the run can afford; showing is what the user wants to look at. Binding
            // them made Show Preview inert for any run started while hidden, and the
            // publication itself is the cheap half. Admission still decides whether
            // any preview is produced at all.
            trainingPreviewPolicy: .enabled,
            runIntent: runIntent
        )
        guard let projectRunLeaseOwner else { return config }
        return projectRunLeaseOwner.borrowingLease(in: config)
    }

    private func resolveBoundViewerTimingAuthority(
        projectID: UUID,
        projectURL: URL,
        outputURL: URL,
        projectRunLeaseOwner: AppProjectRunLeaseOwner?
    ) async throws -> BoundResultViewerTimingAuthority? {
        guard let projectRunLeaseOwner else { return nil }
        let pairOperations = resultViewerTimingPairOperations
        let worker = Task.detached(priority: .utility) {
            try Self.resolveBoundViewerTimingAuthority(
                projectID: projectID,
                projectURL: projectURL,
                outputURL: outputURL,
                projectRunLeaseOwner: projectRunLeaseOwner,
                pairOperations: pairOperations
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func resolveResumeViewerTimingAuthority(
        projectID: UUID,
        projectURL: URL,
        outputURL: URL,
        openedProjectRootIdentity: AppProjectRootIdentity,
        projectRunLeaseOwner suppliedProjectRunLeaseOwner:
            AppProjectRunLeaseOwner?
    ) async throws -> BoundResultViewerTimingAuthority? {
        try Task.checkCancellation()
        let acquiredProjectRunLeaseOwner: AppProjectRunLeaseOwner?
        do {
            if suppliedProjectRunLeaseOwner == nil {
                acquiredProjectRunLeaseOwner = try acquireAppProjectRunLeaseOwner(
                    at: projectURL
                )
            } else {
                acquiredProjectRunLeaseOwner = nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
        defer { acquiredProjectRunLeaseOwner?.release() }
        guard let projectRunLeaseOwner = suppliedProjectRunLeaseOwner
                ?? acquiredProjectRunLeaseOwner,
              try projectRunLeaseOwner.lockedProjectRootIdentity()
                == openedProjectRootIdentity else {
            return nil
        }
        let authority = try await resolveBoundViewerTimingAuthority(
            projectID: projectID,
            projectURL: projectURL,
            outputURL: outputURL,
            projectRunLeaseOwner: projectRunLeaseOwner
        )
        try Task.checkCancellation()
        return authority
    }

    nonisolated private static func resolveBoundViewerTimingAuthority(
        projectID: UUID,
        projectURL: URL,
        outputURL: URL,
        projectRunLeaseOwner: AppProjectRunLeaseOwner,
        pairOperations: PublishedResultPairOperations
    ) throws -> BoundResultViewerTimingAuthority? {
        let paths = ProjectPaths(root: projectURL)
        guard outputURL.standardizedFileURL.path
                == paths.outputSplatURL.standardizedFileURL.path else {
            return nil
        }
        return try projectRunLeaseOwner.withValidatedProjectRootDescriptor {
            projectRootDescriptor in
            try Task.checkCancellation()
            let projectRootIdentity = try AppProjectRootIdentity.capture(
                descriptor: projectRootDescriptor
            )
            let metadata = try ProjectMetadataStore.load(
                fromProjectRootDescriptor: projectRootDescriptor
            )
            guard metadata.id == projectID,
                  metadata.state.stage == .done,
                  metadata.state.lastError == nil,
                  metadata.checkpoint == nil,
                  metadata.lastRunStartedAt == nil,
                  metadata.pendingPublicationID == nil,
                  let resolvedRunPlan = metadata.resolvedRunPlan,
                  let result = try PublishedResultPublisher
                    .resolveCompletedTraining(
                        metadata: metadata,
                        resolvedRunPlan: resolvedRunPlan,
                        paths: paths,
                        projectRootDescriptor: projectRootDescriptor,
                        pairOperations: pairOperations,
                        shouldCancel: { Task.isCancelled }
                    ),
                  result.receipt.projectID == projectID,
                  let generation = result.generation,
                  result.outputURL.standardizedFileURL.path
                    == outputURL.standardizedFileURL.path else {
                return nil
            }
            try Task.checkCancellation()
            return BoundResultViewerTimingAuthority(
                publicationID: result.receipt.publicationID,
                generation: generation,
                projectRootIdentity: projectRootIdentity,
                elapsedSeconds: result.receipt.presentation
                    .createToViewerReadySeconds
            )
        }
    }

    func completeStop(
        projectRunLeaseOwner: AppProjectRunLeaseOwner? = nil
    ) {
        let action = stopAction
        stopAction = nil

        let projectURL = currentProjectURL
        if action == .deleteProject, let projectURL {
            switch requestProjectTrashMove(
                at: projectURL,
                projectRunLeaseOwner: projectRunLeaseOwner
            ) {
            case .completed:
                finalizeExitIfNeeded()
            case .scheduled:
                break
            case .failed:
                abortPendingExitAfterStopFailure()
            }
            return
        }
        reset(projectRunLeaseOwner: projectRunLeaseOwner)
        viewState = .home
        refreshProjectSummaries()
        finalizeExitIfNeeded()
    }
}

/// Forwards pipeline events to the model on the main actor, coalescing
/// bursts: events buffer under a lock and a single scheduled drain delivers
/// everything pending in one main-actor turn. When the main thread is busy
/// the batch grows instead of the task queue, so a chatty trainer (many
/// events per second) costs one SwiftUI invalidation per drain rather than
/// one per event. Ordering is preserved by the single buffer.
private final class EventForwarder: @unchecked Sendable {
    private weak var model: AppModel?
    private let taskToken: UUID?
    private let lock = NSLock()
    private var pending: [PipelineEvent] = []
    private var drainScheduled = false

    init(model: AppModel, taskToken: UUID?) {
        self.model = model
        self.taskToken = taskToken
    }

    func handle(_ event: PipelineEvent) {
        lock.lock()
        pending.append(event)
        let shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        lock.unlock()
        guard shouldSchedule else { return }
        Task { @MainActor in
            for event in self.takePendingBatch() {
                guard let model = self.model, model.isCurrentTaskToken(self.taskToken) else { return }
                model.handle(event: event)
            }
        }
    }

    private func takePendingBatch() -> [PipelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        drainScheduled = false
        return batch
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
