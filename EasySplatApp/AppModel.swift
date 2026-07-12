import Foundation
import SwiftUI
import EasySplatCore

@MainActor
final class AppModel: ObservableObject {
    enum ViewState {
        case home
        case processing
        case viewer
    }

    enum AppModelError: LocalizedError {
        case noDocumentsDirectory

        var errorDescription: String? {
            switch self {
            case .noDocumentsDirectory:
                return "Unable to locate the Documents folder."
            }
        }
    }

    @Published var viewState: ViewState = .home
    @Published var stage: PipelineStage? = nil
    @Published var progress: Double? = nil
    @Published var statusTitle: String = "Ready to start"
    @Published var statusDetail: String? = nil
    @Published var stageStartedAt: Date? = nil
    @Published var lastPipelineEventAt: Date? = nil
    @Published var logLines: [String] = []
    @Published var errorLogLines: [String] = []
    @Published var lastError: String? = nil
    @Published var errorDetails: String? = nil
    @Published var outputPlyURL: URL? = nil
    @Published var currentReconstruction: ReconstructionSummary? = nil
    @Published var currentStageTimings: [StageTimingRecord] = []
    @Published var currentOutputPlyInfo: OutputPlyInfo? = nil
    @Published var currentAutoTune: AutoTuneSnapshot? = nil
    @Published var currentPreset: PresetSpec? = nil
    @Published var currentInput: InputSpec? = nil
    @Published var currentProjectNotes: String = ""
    @Published var currentProjectURL: URL? = nil
    @Published var stopAction: StopAction? = nil

    @Published var cachedFreeDiskBytes: Int64? = nil
    @Published var requestedRunOptions = RequestedRunOptions()
    @Published var pendingVideoURLs: [URL] = []
    @Published var pendingPhotosFolderURL: URL? = nil
    @Published var projectSummaries: [ProjectSummary] = []
    @Published var selectionWarning: String? = nil
    @Published var recoveryPromptProject: ProjectSummary? = nil
    @Published var shareStatusMessage: String? = nil
    @Published var shareStatusIsError: Bool = false
    @Published var isShareSheetActive: Bool = false

    let toolchainManager: ToolchainManaging
    let pipelineRunnerFactory: (URL, PipelineRunner.PipelineConfig) -> PipelineRunning
    let powerAssertion: PowerAssertionManaging
    let projectBaseURL: URL?
    var currentTask: Task<Void, Never>?
    var currentTaskToken: UUID?
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
    var pendingNotesSave: (url: URL, text: String)?
    /// In-memory cache for recent pipeline error counts. Keyed by log URL,
    /// invalidated when the log's mtime OR size changes between refreshes
    /// (mtime alone has only second-level precision on some filesystems,
    /// so two writes inside the same second would falsely cache-hit).
    var pipelineErrorCountCache: [URL: (mtime: Date, size: Int64, count: Int)] = [:]
    var exitIntent: ExitIntent = .none
    weak var pendingCloseWindow: NSWindow?
    var allowNextWindowClose = false
    var replyToTerminationRequest: (Bool) -> Void = { shouldTerminate in
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }
    var forcedExitTask: Task<Void, Never>?
    var activeShareSession: ShareSession?
    var ignoredRecoveryProjectIDs: Set<UUID> = []
    static let forcedExitTimeoutNanoseconds: UInt64 = 25_000_000_000

    /// Project metadata v1 requires a two-value preset. Runtime policy must use
    /// `RequestedRunOptions` and `ResolvedRunPlan`, never this lossy projection.
    static func compatibilityPreset(for options: RequestedRunOptions) -> PresetSpec {
        let mode: CaptureMode = switch options.capturePath {
        case .automatic, .orbit: .object
        case .walkthrough, .largeArea: .room
        }
        let quality: QualityPreset = switch options.detailProfile {
        case .fast: .draft
        case .balanced: .standard
        case .highDetail: .ultra
        }
        return PresetSpec(mode: mode, quality: quality)
    }

    enum StopAction {
        case keepProject
        case deleteProject
    }

    struct StopFailurePresentation: Equatable {
        let title: String
        let detail: String
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
        if action == .deleteProject {
            return StopFailurePresentation(
                title: "Couldn’t delete the project",
                detail: "The project was not deleted because EasySplat could not stop safely. Review the details and try again."
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
        toolchainManager: ToolchainManaging = ToolchainManager(),
        projectBaseURL: URL? = nil,
        pipelineRunnerFactory: @escaping (URL, PipelineRunner.PipelineConfig) -> PipelineRunning = { projectURL, config in
            PipelineRunner(projectURL: projectURL, config: config)
        },
        powerAssertion: PowerAssertionManaging = SystemPowerAssertion()
    ) {
        self.toolchainManager = toolchainManager
        self.projectBaseURL = projectBaseURL
        self.pipelineRunnerFactory = pipelineRunnerFactory
        self.powerAssertion = powerAssertion
        refreshProjectSummaries()
    }
}
