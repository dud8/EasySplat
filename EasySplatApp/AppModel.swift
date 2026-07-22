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

    @Published var cachedFreeDiskBytes: Int64? = nil
    @Published var requestedRunOptions = RequestedRunOptions()
    @Published var pendingVideoURLs: [URL] = []
    @Published var pendingPhotosFolderURL: URL? = nil
    @Published var projectSummaries: [ProjectSummary] = []
    @Published var selectionWarning: String? = nil
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
    let projectBaseURL: URL?
    let projectTrashHandler: (URL) throws -> Void
    var currentTask: Task<Void, Never>?
    var currentTaskToken: UUID?
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
    var photoFolderCountTask: Task<Void, Never>?
    var exitIntent: ExitIntent = .none
    weak var pendingCloseWindow: NSWindow?
    var allowNextWindowClose = false
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

    var isTrainingStageActive: Bool {
        stage == .trainSplat
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

    var processingDetailsText: String? {
        if lastError != nil {
            if let details = errorDetails, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return details
            }
            return statusDetail
        }
        if let liveErrors = liveErrorDetailsText {
            if let detail = statusDetail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(detail)\n\nRecent Error Output:\n\(liveErrors)"
            }
            return "Recent Error Output:\n\(liveErrors)"
        }
        if let detail = statusDetail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        return nil
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

    private var liveErrorDetailsText: String? {
        guard !errorLogLines.isEmpty else { return nil }
        let tail = errorLogLines.suffix(300)
        let text = tail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
        projectTrashHandler: @escaping (URL) throws -> Void = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        },
        finishedOutputValidator: @escaping FinishedOutputValidator = { projectURL in
            AppModel.readyOutputURLOnDisk(
                projectURL: projectURL,
                validationDepth: .full
            )
        }
    ) {
        self.toolchainManager = toolchainManager
        self.projectBaseURL = projectBaseURL
        self.hardwareProfile = hardwareProfile ?? .detect()
        self.finishedOutputValidator = finishedOutputValidator
        self.videoInputPreflight = videoInputPreflight
        self.projectPublicationCheckpointHook = projectPublicationCheckpointHook
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
