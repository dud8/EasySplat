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
    @Published var currentProjectURL: URL? = nil
    @Published var toolchainPaths: ToolchainPaths? = nil
    @Published var stopAction: StopAction? = nil
    @Published var isShowingTrainingConsent: Bool = false
    @Published var isLivePreviewEnabled: Bool = false
    @Published var activeTrainingBackend: TrainingBackend? = nil

    @Published var captureMode: CaptureMode = .object
    @Published var qualityPreset: QualityPreset = .draft
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

    static let trainingConsentRememberedKey = "EasySplatTrainingConsentRemembered"

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
