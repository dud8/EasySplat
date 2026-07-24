import EasySplatCore
import Foundation

extension AppModel {
    private static let subjectIsolationMemoryCapBytes: Int64 =
        8 * 1_073_741_824

    @discardableResult
    func startSubjectIsolation() -> Bool {
        startSubjectIsolation(anchor: nil)
    }

    @discardableResult
    func retrySubjectIsolation(anchor: SubjectAnchor) -> Bool {
        startSubjectIsolation(anchor: anchor)
    }

    @discardableResult
    private func startSubjectIsolation(anchor: SubjectAnchor?) -> Bool {
        guard !hasActiveWork,
              viewState == .viewer,
              let projectURL = currentProjectURL,
              let outputPlyURL,
              ProjectSummary.hasSameLocation(
                  outputPlyURL,
                  ProjectPaths(root: projectURL).outputSplatURL
              ) else {
            return false
        }

        let token = UUID()
        subjectIsolationTaskToken = token
        subjectIsolationCancellationRequested = false
        subjectChoiceRequest = nil
        subjectIsolationProgress = SubjectIsolationProgress(
            phase: .preparing,
            completedUnitCount: 0,
            totalUnitCount: 1
        )
        subjectIsolationStatusMessage = "Preparing subject isolation…"
        subjectIsolationStatusIsError = false
        isSubjectIsolationActive = true
        subjectIsolationTask = Task { [weak self] in
            await self?.runSubjectIsolation(
                projectURL: projectURL,
                anchor: anchor,
                token: token
            )
        }
        return true
    }

    func cancelSubjectIsolation() {
        guard isSubjectIsolationActive else { return }
        subjectIsolationCancellationRequested = true
        subjectIsolationStatusMessage = "Cancelling subject isolation…"
        subjectIsolationStatusIsError = false
        subjectIsolationTask?.cancel()
    }

    @discardableResult
    func setSelectedSplatOutputVariant(_ variant: SplatOutputVariant) -> Bool {
        guard variant != .subject || subjectOutput != nil else {
            return false
        }
        guard selectedSplatOutputVariant != variant else {
            return true
        }
        cancelSharing()
        selectedSplatOutputVariant = variant
        return true
    }

    func reloadSubjectIsolationArtifact(for projectURL: URL) async {
        clearSubjectIsolationSession()
        let loader = subjectIsolationArtifactLoader
        let paths = ProjectPaths(root: projectURL)
        let result = await Task.detached(priority: .userInitiated) {
            loader(paths)
        }.value
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL),
              ProjectSummary.hasSameLocation(
                  outputPlyURL,
                  paths.outputSplatURL
              ) else {
            return
        }
        guard case .valid(_, let output) = result,
              output.variant == .subject,
              ProjectSummary.hasSameLocation(
                  output.url,
                  paths.isolatedOutputURL
              ) else {
            return
        }
        subjectOutput = output
    }

    @discardableResult
    func removeSubjectVersion() -> Bool {
        guard !hasActiveWork,
              let projectURL = currentProjectURL,
              subjectOutput != nil else {
            return false
        }
        do {
            guard try subjectIsolationArtifactRemover(
                ProjectPaths(root: projectURL)
            ) else {
                subjectIsolationStatusMessage =
                    "Couldn’t remove the Subject version. Try again."
                subjectIsolationStatusIsError = true
                return false
            }
            clearSubjectIsolationSession()
            subjectIsolationStatusMessage = "Subject version removed."
            return true
        } catch {
            subjectIsolationStatusMessage =
                "Couldn’t remove the Subject version. Try again."
            subjectIsolationStatusIsError = true
            return false
        }
    }

    func clearSubjectIsolationSession() {
        subjectIsolationProgress = nil
        subjectChoiceRequest = nil
        subjectOutput = nil
        selectedSplatOutputVariant = .original
        subjectIsolationStatusMessage = nil
        subjectIsolationStatusIsError = false
    }

    private func runSubjectIsolation(
        projectURL: URL,
        anchor: SubjectAnchor?,
        token: UUID
    ) async {
        defer {
            finishSubjectIsolation(token: token)
        }

        let paths = ProjectPaths(root: projectURL)
        let logWriter = SubjectIsolationLogWriter(url: paths.isolationLogURL)
        let idleSleepAssertion = powerAssertion.beginPreventingIdleSleep(
            reason: "EasySplat is isolating a subject"
        )
        defer {
            idleSleepAssertion.release()
        }

        do {
            let progressForwarder = SubjectIsolationProgressForwarder(
                model: self,
                token: token
            )
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                request: ToolchainCapabilityRequest(capabilities: [.msplat])
            ) { fraction, message in
                progressForwarder.updateToolPreparation(
                    fraction: fraction,
                    message: message
                )
            }
            try Task.checkCancellation()
            guard isCurrentSubjectIsolationToken(token) else { return }

            let automaticBudget = TrainingMemoryBudget.resolve(
                hardware: hardwareProfile,
                resourcePolicy: .automatic
            )
            let request = SubjectIsolationRequest(
                projectPaths: paths,
                nativeExecutableURL: toolchain.msplat,
                toolchainBuildIdentity: subjectIsolationToolchainIdentity(toolchain),
                memoryBudgetBytes: min(
                    Self.subjectIsolationMemoryCapBytes,
                    automaticBudget
                ),
                anchor: anchor
            )
            let coordinator = subjectIsolationCoordinatorFactory()
            let outcome = try await coordinator.isolate(
                request: request,
                onProgress: { progress in
                    progressForwarder.update(progress)
                },
                onLog: { line, isError in
                    logWriter.append(line, isError: isError)
                }
            )
            try Task.checkCancellation()
            guard isCurrentSubjectIsolationToken(token) else { return }
            handleSubjectIsolationOutcome(outcome)
        } catch is CancellationError {
            guard isCurrentSubjectIsolationToken(token) else { return }
            subjectIsolationStatusMessage = nil
            subjectIsolationStatusIsError = false
        } catch {
            guard isCurrentSubjectIsolationToken(token) else { return }
            subjectChoiceRequest = nil
            subjectIsolationStatusMessage =
                "Couldn’t isolate the subject. The original is unchanged."
            subjectIsolationStatusIsError = true
            logWriter.append(String(reflecting: error), isError: true)
        }
    }

    private func subjectIsolationToolchainIdentity(
        _ toolchain: ToolchainPaths
    ) -> String {
        let authenticated = toolchain.authenticatedVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let authenticated, !authenticated.isEmpty {
            return authenticated
        }
        let localIdentity = toolchain.root.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return localIdentity.isEmpty ? "local-toolchain" : localIdentity
    }

    private func handleSubjectIsolationOutcome(
        _ outcome: SubjectIsolationOutcome
    ) {
        switch outcome {
        case .progress(let progress):
            subjectIsolationProgress = progress
        case .ambiguity(let request):
            subjectChoiceRequest = request
            subjectIsolationStatusMessage = "Choose the subject to keep."
            subjectIsolationStatusIsError = false
        case .noSubject:
            subjectChoiceRequest = nil
            subjectIsolationStatusMessage =
                "No clear subject to isolate. The original is unchanged."
            subjectIsolationStatusIsError = false
        case .cancelled:
            subjectIsolationStatusMessage = nil
            subjectIsolationStatusIsError = false
        case .completed(let output):
            guard output.variant == .subject else {
                subjectIsolationStatusMessage =
                    "Couldn’t isolate the subject. The original is unchanged."
                subjectIsolationStatusIsError = true
                return
            }
            cancelSharing()
            subjectChoiceRequest = nil
            subjectOutput = output
            _ = setSelectedSplatOutputVariant(.subject)
            subjectIsolationStatusMessage = "Subject version ready."
            subjectIsolationStatusIsError = false
        }
    }

    private func isCurrentSubjectIsolationToken(_ token: UUID) -> Bool {
        subjectIsolationTaskToken == token
            && !subjectIsolationCancellationRequested
    }

    private func finishSubjectIsolation(token: UUID) {
        guard subjectIsolationTaskToken == token else { return }
        let wasCancelled = subjectIsolationCancellationRequested
        subjectIsolationTask = nil
        subjectIsolationTaskToken = nil
        subjectIsolationCancellationRequested = false
        isSubjectIsolationActive = false
        if wasCancelled, stopAction == nil {
            subjectIsolationStatusMessage = nil
            subjectIsolationStatusIsError = false
        }
        if stopAction != nil {
            completeStop()
        }
    }
}

private final class SubjectIsolationProgressForwarder: @unchecked Sendable {
    private weak var model: AppModel?
    private let token: UUID

    init(model: AppModel, token: UUID) {
        self.model = model
        self.token = token
    }

    func update(_ progress: SubjectIsolationProgress) {
        Task { @MainActor [weak model] in
            guard let model,
                  model.subjectIsolationTaskToken == token,
                  !model.subjectIsolationCancellationRequested else {
                return
            }
            model.subjectIsolationProgress = progress
        }
    }

    func updateToolPreparation(fraction: Double, message: String) {
        let clamped = min(1, max(0, fraction))
        let units = Int((clamped * 1_000).rounded())
        Task { @MainActor [weak model] in
            guard let model,
                  model.subjectIsolationTaskToken == token,
                  !model.subjectIsolationCancellationRequested else {
                return
            }
            model.subjectIsolationProgress = SubjectIsolationProgress(
                phase: .preparing,
                completedUnitCount: units,
                totalUnitCount: 1_000
            )
            if !message.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                model.subjectIsolationStatusMessage = message
            }
        }
    }
}

private final class SubjectIsolationLogWriter: @unchecked Sendable {
    private static let maximumLineBytes = 16 * 1_024
    private static let maximumRunBytes = 8 * 1_024 * 1_024

    private let lock = NSLock()
    private let url: URL
    private var bytesWritten = 0

    init(url: URL) {
        self.url = url
    }

    func append(_ line: String, isError: Bool) {
        lock.withLock {
            guard bytesWritten < Self.maximumRunBytes else { return }
            var data = Data(
                "\(isError ? "[stderr] " : "")\(line)\n".utf8
            )
            let remaining = Self.maximumRunBytes - bytesWritten
            if data.count > Self.maximumLineBytes {
                data = data.prefix(Self.maximumLineBytes)
            }
            if data.count > remaining {
                data = data.prefix(remaining)
            }
            guard !data.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(
                        atPath: url.path,
                        contents: nil
                    )
                }
                let handle = try FileHandle(forWritingTo: url)
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                bytesWritten += data.count
            } catch {
                // Isolation remains useful even if its optional native log
                // cannot be written.
            }
        }
    }
}
