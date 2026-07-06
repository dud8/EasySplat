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
    @Published var toolchainPaths: ToolchainPaths? = nil
    @Published var stopAction: StopAction? = nil
    @Published var isShowingTrainingConsent: Bool = false
    @Published var isLivePreviewEnabled: Bool = false
    @Published var activeTrainingBackend: TrainingBackend? = nil

    @Published var cachedFreeDiskBytes: Int64? = nil
    @Published var captureMode: CaptureMode = AppModel.persistedCaptureMode() {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: AppModel.captureModeUserDefaultsKey) }
    }
    @Published var qualityPreset: QualityPreset = AppModel.persistedQualityPreset() {
        didSet { UserDefaults.standard.set(qualityPreset.rawValue, forKey: AppModel.qualityPresetUserDefaultsKey) }
    }
    @Published var pendingVideoURLs: [URL] = []
    @Published var pendingPhotosFolderURL: URL? = nil
    @Published var projectSummaries: [ProjectSummary] = []
    @Published var selectionWarning: String? = nil
    @Published var recoveryPromptProject: ProjectSummary? = nil
    @Published var shareStatusMessage: String? = nil
    @Published var shareStatusIsError: Bool = false
    @Published var shareMetrics: ShareMetrics = .init()
    @Published var isShareSheetActive: Bool = false

    let toolchainManager: ToolchainManaging
    let pipelineRunnerFactory: (URL, PipelineRunner.PipelineConfig) -> PipelineRunning
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
    var trainingConsentContinuation: CheckedContinuation<Bool, Never>?
    var trainingConsentPauseStartedAt: Date?
    var trainingConsentPausedDuration: TimeInterval = 0
    var exitIntent: ExitIntent = .none
    weak var pendingCloseWindow: NSWindow?
    var allowNextWindowClose = false
    var pendingSnapshotRevealURL: URL?
    var pendingSnapshotRevealRequiresExit: Bool = false
    var forcedExitTask: Task<Void, Never>?
    var activeShareSession: ShareSession?
    var ignoredRecoveryProjectIDs: Set<UUID> = []
    static let forcedExitTimeoutNanoseconds: UInt64 = 25_000_000_000

    nonisolated static let trainingConsentRememberedKey = "EasySplatTrainingConsentRemembered"
    nonisolated static let captureModeUserDefaultsKey = "EasySplatCaptureMode"
    nonisolated static let qualityPresetUserDefaultsKey = "EasySplatQualityPreset"

    static func persistedCaptureMode() -> CaptureMode {
        let raw = UserDefaults.standard.string(forKey: captureModeUserDefaultsKey) ?? ""
        return CaptureMode(rawValue: raw) ?? .object
    }

    static func persistedQualityPreset() -> QualityPreset {
        let raw = UserDefaults.standard.string(forKey: qualityPresetUserDefaultsKey) ?? ""
        return QualityPreset(rawValue: raw) ?? .draft
    }

    enum StopAction {
        case keepProject
        case deleteProject
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
        stage == .trainBrush
    }

    var isBrushSnapshotTrainingActive: Bool {
        isTrainingStageActive && activeTrainingBackend == .brush
    }

    var trainingSnapshotURL: URL? {
        guard let currentProjectURL else { return nil }
        return ProjectPaths(root: currentProjectURL)
            .trainingURL
            .appendingPathComponent("latest_snapshot.ply")
    }

    var shareSummaryText: String? {
        let completed = shareMetrics.shareCompletedCount
        guard completed > 0 else { return nil }
        let prefix = completed == 1 ? "Shared once." : "Shared \(completed) times."
        if let service = shareMetrics.lastShareService, !service.isEmpty {
            return "\(prefix) Last via \(service)."
        }
        return prefix
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
        }
    ) {
        self.toolchainManager = toolchainManager
        self.projectBaseURL = projectBaseURL
        self.pipelineRunnerFactory = pipelineRunnerFactory
        refreshProjectSummaries()
    }
}
