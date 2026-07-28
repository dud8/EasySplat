import Foundation
import SwiftUI
import EasySplatCore

enum RunValidationRecovery: Equatable {
    case useUnordered
    case useFast
    case useFastForMemory
    case useBalanced
    case useAutomaticPhotoSelection
    case useMoreTrainingMemory(Int64)

    func apply(to options: inout RequestedRunOptions) {
        switch self {
        case .useUnordered:
            options.inputOrdering = .unordered
        case .useFast:
            options.detailProfile = .fast
            options.resourcePolicy = .conserveMemory
        case .useFastForMemory:
            options.detailProfile = .fast
        case .useBalanced:
            options.detailProfile = .balanced
        case .useAutomaticPhotoSelection:
            options.photoSelection = .automatic
        case .useMoreTrainingMemory:
            break
        }
    }
}

struct ProjectPublicationCheckpointHook: Sendable {
    static let none = ProjectPublicationCheckpointHook()

    private let handler: ProjectPublicationTransaction.CheckpointHandler

    init(
        _ handler: @escaping ProjectPublicationTransaction.CheckpointHandler = { _ in }
    ) {
        self.handler = handler
    }

    func handle(_ checkpoint: ProjectPublicationTransaction.Checkpoint) throws {
        try handler(checkpoint)
    }
}

@MainActor
final class AppModel: ObservableObject {
    typealias FinishedOutputValidator = @Sendable (URL) -> URL?
    typealias SubjectIsolationCoordinatorFactory =
        @Sendable () -> any SubjectIsolationCoordinating
    typealias SubjectIsolationArtifactLoader =
        @Sendable (ProjectPaths) -> IsolationArtifactLoadResult
    typealias SubjectIsolationArtifactRemover =
        @Sendable (ProjectPaths) throws -> Bool

    enum ViewState: Equatable {
        case home
        case opening
        case processing
        case viewer
    }

    @Published var viewState: ViewState = .home
    @Published var stage: PipelineStage? = nil
    @Published var progress: Double? = nil
    @Published var statusTitle: String = "Ready to start"
    @Published var statusDetail: String? = nil
    @Published var stageStartedAt: Date? = nil
    @Published var phaseStartedAt: Date? = nil
    @Published var lastPipelineEventAt: Date? = nil
    @Published var logLines: [String] = []
    @Published var errorLogLines: [String] = []
    @Published var lastError: String? = nil
    @Published var errorDetails: String? = nil
    @Published var validationRecovery: RunValidationRecovery? = nil
    @Published var failureRetryAllowed = true
    @Published var outputPlyURL: URL? = nil
    @Published var isSubjectIsolationActive = false
    @Published var subjectIsolationProgress: SubjectIsolationProgress?
    @Published var subjectChoiceRequest: SubjectChoiceRequest?
    @Published var subjectOutput: ValidatedSplatOutput?
    @Published var selectedSplatOutputVariant: SplatOutputVariant = .original
    @Published var subjectIsolationStatusMessage: String?
    @Published var subjectIsolationStatusIsError = false
    @Published var isSubjectVersionRemovalActive = false
    @Published var currentStageTimings: [StageTimingRecord] = []
    @Published var currentCreateToViewerReadySeconds: TimeInterval? = nil
    @Published var currentOutputPlyInfo: OutputPlyInfo? = nil
    @Published var currentRunOptions: RequestedRunOptions? = nil
    @Published var currentInput: InputSpec? = nil
    @Published var currentProjectNotes: String = ""
    @Published var notesSaveState: NotesSaveState = .idle
    @Published var currentProjectURL: URL? = nil
    @Published var stopAction: StopAction? = nil
    @Published var isRunActive = false
    @Published var actionFailure: ActionFailurePresentation?

    /// Live training preview. `trainingPreviewPublication` is the reload token: the
    /// URL is republished in place, so identity has to come from the counter rather
    /// than the path.
    @Published var trainingPreviewURL: URL? = nil
    @Published var trainingPreviewIteration: Int = 0
    @Published var trainingPreviewPublication: Int = 0
    @Published var trainingPreviewSceneBounds: SplatSceneBounds? = nil
    /// Latched once memory pressure has been seen to leave normal during a run.
    /// The permit granted before launch describes one instant; the preview is the
    /// expendable party, so it stays down for the rest of the run rather than
    /// flapping back in and bidding against the trainer again.
    @Published private(set) var isTrainingPreviewMemoryRefused = false
    let memoryPressureProbe: @Sendable () -> MemoryPressureState
    var trainingPreviewMemoryWatch: (any DispatchSourceMemoryPressure)?
    /// User's display preference. Independent of whether a preview exists: the run
    /// may have been refused a preview, and the user may hide one that does.
    @Published var isTrainingPreviewShown = AppModel.storedTrainingPreviewPreference()

    /// How the active run was started. Fresh runs are the only ones the
    /// historical duration estimate describes; resumes and retrains skip
    /// stages and would make it misleading.
    enum RunOrigin {
        case fresh
        case resume
        case retrain
    }

    var currentRunOrigin: RunOrigin = .fresh

    /// Bumped by the File > Export… menu command; the result workspace owns
    /// the save-panel flow and observes this token.
    @Published var exportMenuRequestCount = 0

    /// Result inspector visibility, shared by the View menu, the toolbar
    /// button, and the result workspace.
    @Published var isResultInspectorPresented = false

    /// Last settled workspace width, kept current by WorkspaceView.
    var workspaceWidthHint: CGFloat = 0

    @Published var cachedFreeDiskBytes: Int64? = nil
    @Published var requestedRunOptions = RequestedRunOptions()
    @Published var pendingVideoURLs: [URL] = []
    @Published var pendingPhotoURLs: [URL] = []
    /// A pre-processed dataset selection. Exclusive with `pendingVideoURLs`
    /// and `pendingPhotoURLs`: setting it clears any pending media, and while
    /// it is set new media selections are rejected.
    @Published var pendingDataset: PendingDataset? = nil
    @Published var projectSummaries: [ProjectSummary] = []
    @Published var selectionWarning: String? = nil
    /// Splats dropped where capture input was expected. Opening one is what the user
    /// meant, so the drop is routed to the viewer rather than refused. Drained by the
    /// view that presents the window.
    @Published var splatOpenRequests: [URL] = []
    @Published var shareStatusMessage: String? = nil
    @Published var shareStatusIsError: Bool = false
    @Published var isShareSheetActive: Bool = false
    @Published var isShareReady: Bool = false
    @Published var isPreparingShare: Bool = false

    let toolchainManager: ToolchainManaging
    let hardwareProfile: HardwareProfile
    let pipelineRunnerFactory: (URL, PipelineRunner.PipelineConfig) -> PipelineRunning
    let powerAssertion: PowerAssertionManaging
    let finishedOutputValidator: FinishedOutputValidator
    let videoInputPreflight: VideoInputPreflight
    let projectPublicationCheckpointHook: ProjectPublicationCheckpointHook
    let subjectIsolationCoordinatorFactory: SubjectIsolationCoordinatorFactory
    let subjectIsolationArtifactLoader: SubjectIsolationArtifactLoader
    let subjectIsolationArtifactRemover: SubjectIsolationArtifactRemover
    let projectBaseURL: URL?
    let projectTrashHandler: (URL) throws -> Void
    var currentTask: Task<Void, Never>?
    var currentTaskToken: UUID?
    var subjectIsolationTask: Task<Void, Never>?
    var subjectIsolationTaskToken: UUID?
    var subjectIsolationCancellationRequested = false
    var pendingResultViewerTiming: PendingResultViewerTiming?
    var lastProgressLogAt: Date = .distantPast
    var lastProgressLogMessage: String = ""
    var lastProgressLogStage: PipelineStage? = nil
    var lastTrainingImagesBucket: Int = -1
    var lastTrainingSparseBucket: Int = -1
    var lastTrainingStepsBucket: Int = -1
    var lastStageLogAt: Date = .distantPast
    var lastStageLogMessage: String = ""
    var lastStageLogStage: PipelineStage? = nil
    var lastToolchainMilestoneMessage: String = ""
    var toolchainDownloadBucketByLabel: [String: Int] = [:]
    let trainingStepLogInterval = 120
    let trainingProgressLogMinInterval: TimeInterval = 3.0
    var notesSaveTask: Task<Void, Never>?
    var projectSummaryRefreshTask: Task<Void, Never>?
    var pendingNotesSave: (url: URL, text: String)?
    var exitIntent: ExitIntent = .none
    weak var pendingCloseWindow: NSWindow?
    var allowNextWindowClose = false
    var exitDecisionOverride: (() -> ExitDecision)?
    var replyToTerminationRequest: (Bool) -> Void = { shouldTerminate in
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }
    var forcedExitTask: Task<Void, Never>?
    var activeShareSession: ShareSession?
    var inFlightShareSessions: [UUID: ShareSession] = [:]
    var latestShareOperationID: UUID?
    var preparedShareItem: PreparedShareItem?
    var sharePreparationToken: UUID?
    var sharePreparationTask: Task<Void, Never>?
    static let forcedExitTimeoutNanoseconds: UInt64 = 25_000_000_000

    enum StopAction {
        case keepProject
        case deleteProject
    }

    struct StopFailurePresentation: Equatable {
        let title: String
        let detail: String
    }

    struct ActionFailurePresentation: Equatable {
        let title: String
        let message: String
    }

    enum NotesSaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    struct ExitConfirmationPresentation: Equatable {
        let title: String
        let message: String
        let primaryActionTitle: String
        let destructiveActionTitle: String?
    }

    enum ExitIntent {
        case none
        case quit
        case closeWindow
    }

    enum ExitDecision {
        case save
        case delete
        case cancel
    }

    var isStopping: Bool {
        stopAction != nil
    }

    var hasActiveWork: Bool {
        isRunActive || isSubjectIsolationActive || isSubjectVersionRemovalActive
    }

    var displayedOutputURL: URL? {
        switch selectedSplatOutputVariant {
        case .original:
            outputPlyURL
        case .subject:
            subjectOutput?.url
        }
    }

    var displayedOutputPlyInfo: OutputPlyInfo? {
        switch selectedSplatOutputVariant {
        case .original:
            currentOutputPlyInfo
        case .subject:
            subjectOutput.map {
                OutputPlyInfo(
                    vertexCount: $0.gaussianCount,
                    sizeBytes: Int64(clamping: $0.byteCount),
                    format: ""
                )
            }
        }
    }

    var displayedOutputSceneBounds: SplatSceneBounds? {
        selectedSplatOutputVariant == .subject ? subjectOutput?.sceneBounds : nil
    }

    var isTrainingStageActive: Bool {
        stage == .trainSplat
    }

    /// A preview is only worth showing while the model it depicts is still being
    /// trained; once the run leaves training the real result takes over.
    var isTrainingPreviewVisible: Bool {
        isTrainingPreviewAvailable && isTrainingPreviewShown
    }

    /// Whether this run has a preview to show at all. A run can be refused one for
    /// memory, or release it after a failed load, and the control must not offer to
    /// show something that does not exist.
    var isTrainingPreviewAvailable: Bool {
        isTrainingStageActive && trainingPreviewURL != nil
            && trainingPreviewSceneBounds != nil && lastError == nil
    }

    nonisolated static let trainingPreviewPreferenceKey = "EasySplatTrainingPreviewShown"

    /// Defaults to on: a user who has never chosen benefits most from seeing the
    /// splat form, and the run withholds the preview on its own when it cannot
    /// afford one.
    nonisolated static func storedTrainingPreviewPreference() -> Bool {
        UserDefaults.standard.object(forKey: trainingPreviewPreferenceKey) as? Bool ?? true
    }

    func setTrainingPreviewShown(_ shown: Bool) {
        isTrainingPreviewShown = shown
        UserDefaults.standard.set(shown, forKey: Self.trainingPreviewPreferenceKey)
    }

    /// Drops the preview identity so a stale file from a previous run can never be
    /// mounted against the next one. The display preference deliberately survives.
    func clearTrainingPreview() {
        stopTrainingPreviewMemoryWatch()
        trainingPreviewURL = nil
        trainingPreviewIteration = 0
        trainingPreviewPublication = 0
        trainingPreviewSceneBounds = nil
        isTrainingPreviewMemoryRefused = false
    }

    /// Re-tests memory pressure before a new preview generation is mounted, and
    /// unmounts the resident one the first time pressure leaves normal. Returns
    /// whether the publication may be shown.
    @discardableResult
    func acceptTrainingPreviewUnderCurrentMemoryPressure() -> Bool {
        guard !isTrainingPreviewMemoryRefused else { return false }
        guard memoryPressureProbe() == .normal else {
            releaseTrainingPreview(reason: "memory pressure")
            return false
        }
        return true
    }

    /// Takes the preview down for the rest of the run and returns the workspace to
    /// the ordinary processing screen. Latched rather than retried: a preview that
    /// failed to load or cost memory under pressure has already shown it is the
    /// expendable party, and retrying it competes with training again.
    func releaseTrainingPreview(reason: String) {
        guard trainingPreviewURL != nil || !isTrainingPreviewMemoryRefused else { return }
        isTrainingPreviewMemoryRefused = true
        trainingPreviewURL = nil
        trainingPreviewSceneBounds = nil
        appendLogLine("[Training] Live preview released (\(reason)); training is unaffected.")
    }

    /// Installs a run-scoped memory-pressure watch so the preview is released the
    /// moment the system reports strain, not at the next publication — which may
    /// never arrive if the trainer has stalled or stopped publishing.
    func startTrainingPreviewMemoryWatch() {
        stopTrainingPreviewMemoryWatch()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.releaseTrainingPreview(reason: "memory pressure")
            }
        }
        source.resume()
        trainingPreviewMemoryWatch = source
    }

    func stopTrainingPreviewMemoryWatch() {
        trainingPreviewMemoryWatch?.cancel()
        trainingPreviewMemoryWatch = nil
    }

    func stopFailurePresentation(for action: StopAction) -> StopFailurePresentation {
        if currentProjectURL == nil {
            return StopFailurePresentation(
                title: "Couldn’t stop setup",
                detail: "EasySplat could not stop safely. Review the details and try again."
            )
        }
        if action == .deleteProject {
            return StopFailurePresentation(
                title: "Couldn’t move project to Trash",
                detail: "The project stayed in place because EasySplat could not stop safely. Review the details and try again."
            )
        }
        if isTrainingStageActive {
            return StopFailurePresentation(
                title: "Couldn’t save the project",
                detail: "The training checkpoint was not saved. Review the details and try again."
            )
        }
        return StopFailurePresentation(
            title: "Couldn’t save the project",
            detail: "The project was not saved. Review the details and try again."
        )
    }

    /// How many log lines the live Technical Details pane renders. The full
    /// buffers stay available through `errorDetailsText` for Copy Details and
    /// failure forensics; re-laying-out the whole log on every pipeline event
    /// is what froze the UI during heavy training.
    static let technicalLogTailLimit = 300

    /// Recoverable errors must stay visible in the live pane even after they
    /// scroll out of the general tail, so they get their own bounded section.
    static let technicalErrorTailLimit = 20

    var processingDetailsText: String? {
        var parts: [String] = []
        if let statusDetail, !statusDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(statusDetail)
        }
        if !errorLogLines.isEmpty {
            parts.append(
                "Recent Error Output:\n"
                    + errorLogLines.suffix(Self.technicalErrorTailLimit).joined(separator: "\n")
            )
        }
        if !logLines.isEmpty {
            parts.append(logLines.suffix(Self.technicalLogTailLimit).joined(separator: "\n"))
        }
        let combined = parts.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    var errorDetailsText: String? {
        var parts: [String] = []
        if let statusDetail, !statusDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(statusDetail)
        }
        if let errorDetails, !errorDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(errorDetails)
        }
        if !errorLogLines.isEmpty {
            parts.append("Error Logs:\n" + errorLogLines.joined(separator: "\n"))
        }
        if !logLines.isEmpty {
            parts.append("Logs:\n" + logLines.joined(separator: "\n"))
        }
        let combined = parts.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    init(
        toolchainManager: ToolchainManaging = AppModel.makeDefaultToolchainManager(),
        projectBaseURL: URL? = nil,
        hardwareProfile: HardwareProfile? = nil,
        videoInputPreflight: VideoInputPreflight = VideoInputPreflight(),
        pipelineRunnerFactory: @escaping (URL, PipelineRunner.PipelineConfig) -> PipelineRunning = { projectURL, config in
            PipelineRunner(projectURL: projectURL, config: config)
        },
        projectPublicationCheckpointHook: ProjectPublicationCheckpointHook = .none,
        powerAssertion: PowerAssertionManaging = SystemPowerAssertion(),
        subjectIsolationCoordinatorFactory: @escaping SubjectIsolationCoordinatorFactory = {
            SubjectIsolationCoordinator()
        },
        subjectIsolationArtifactLoader: @escaping SubjectIsolationArtifactLoader = {
            SubjectIsolationArtifactStore.load(paths: $0)
        },
        subjectIsolationArtifactRemover: @escaping SubjectIsolationArtifactRemover = {
            try SubjectIsolationArtifactStore.removeValidatedSubject(paths: $0)
        },
        projectTrashHandler: @escaping (URL) throws -> Void = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        },
        finishedOutputValidator: @escaping FinishedOutputValidator = { projectURL in
            AppModel.readyOutputURLOnDisk(
                projectURL: projectURL,
                validationDepth: .full
            )
        },
        memoryPressureProbe: @escaping @Sendable () -> MemoryPressureState = {
            // A failed observation is not evidence of calm.
            (try? LiveTrainingResourceObserver().observe())?.memoryPressure ?? .unknown
        }
    ) {
        self.memoryPressureProbe = memoryPressureProbe
        self.toolchainManager = toolchainManager
        self.projectBaseURL = projectBaseURL
        self.hardwareProfile = hardwareProfile ?? .detect()
        self.finishedOutputValidator = finishedOutputValidator
        self.videoInputPreflight = videoInputPreflight
        self.projectPublicationCheckpointHook = projectPublicationCheckpointHook
        self.subjectIsolationCoordinatorFactory = subjectIsolationCoordinatorFactory
        self.subjectIsolationArtifactLoader = subjectIsolationArtifactLoader
        self.subjectIsolationArtifactRemover = subjectIsolationArtifactRemover
        self.projectTrashHandler = projectTrashHandler
        self.pipelineRunnerFactory = pipelineRunnerFactory
        self.powerAssertion = powerAssertion
        if self.hardwareProfile.memoryGB <= 8.5 {
            requestedRunOptions.detailProfile = .fast
            requestedRunOptions.resourcePolicy = .conserveMemory
        }
        if projectBaseURL != nil {
            refreshProjectSummaries()
        }
    }

    static func makeDefaultToolchainManager(
        bundledBootstrap: ToolchainBootstrap? = AppConfig.bundledToolchainBootstrap,
        sourcePolicy: ToolchainSourcePolicy = AppModel.defaultToolchainSourcePolicy(),
        developmentOverrides: DevelopmentOverrides = AppConfig.currentDevelopmentOverrides,
        factory: (ToolchainBootstrap?, ToolchainSourcePolicy, URL?) -> ToolchainManaging = {
            bundledBootstrap,
            sourcePolicy,
            localToolchainRoot in
            ToolchainManager(
                appVersion: EasySplatReleaseIdentity.version(),
                localToolchainRoot: localToolchainRoot,
                allowInsecureLoopbackHTTP: AppConfig.allowInsecureLoopbackToolchainHTTP,
                bundledBootstrap: bundledBootstrap,
                sourcePolicy: sourcePolicy
            )
        }
    ) -> ToolchainManaging {
        factory(bundledBootstrap, sourcePolicy, developmentOverrides.localToolchainRoot)
    }

    static func defaultToolchainSourcePolicy(
        releaseVerificationConfiguration: AppConfig.ReleaseVerificationConfiguration?
            = AppConfig.releaseVerificationConfiguration
    ) -> ToolchainSourcePolicy {
        releaseVerificationConfiguration == nil ? .automatic : .bundledBootstrapOnly
    }
}
