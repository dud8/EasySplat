import Foundation
import EasySplatCore

struct ProjectSummary: Identifiable {
    let id: UUID
    let title: String
    let url: URL
    let createdAt: Date
    let status: ProjectStatus
    let isActive: Bool
    let isRetrying: Bool
    let isInterrupted: Bool
    let checkpointUpdatedAt: Date?
    let lastError: String?
    let outputPlyURL: URL?
    let outputPlySizeBytes: Int64?
    let reconstruction: ReconstructionSummary?
    let stageTimings: [StageTimingRecord]
    let preset: PresetSpec?
    let lastOpenedAt: Date?
    let lastFailureAt: Date?
    let recentErrorCount: Int?
}

extension ProjectSummary {
    var outputSizeText: String? {
        guard let bytes = outputPlySizeBytes, bytes > 0 else { return nil }
        // ByteCountFormatter cannot be cached safely in a Swift 6 nonisolated
        // global; the per-call cost is sub-microsecond, so build one each time.
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    /// Total wall-clock time recorded across the run's stages, if any timings exist.
    var totalRunDurationText: String? {
        guard let total = stageTimings.totalDurationSeconds, total > 0 else { return nil }
        return StageTimingDisplay.formatDuration(seconds: total)
    }

    /// Approximate timestamp used for sorting by recent activity. Prefers
    /// the explicit user signal (last opened in the viewer), then the most
    /// recent stage completion, then checkpoint updatedAt, then creation
    /// time so projects without any signals still sort sensibly.
    var lastActivityAt: Date {
        if let lastOpenedAt {
            return lastOpenedAt
        }
        return lastRunCompletedAt
    }

    var lastRunCompletedAt: Date {
        if let lastTiming = stageTimings.max(by: { $0.startedAt < $1.startedAt }) {
            return lastTiming.startedAt.addingTimeInterval(lastTiming.durationSeconds)
        }
        if let checkpointUpdatedAt {
            return checkpointUpdatedAt
        }
        return createdAt
    }
}

enum ProjectListFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case inProgress
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .failed: return "Failed"
        }
    }

    func matches(_ project: ProjectSummary) -> Bool {
        switch self {
        case .all: return true
        case .ready: return project.status == .ready
        case .inProgress: return project.status == .inProgress
        case .failed: return project.status == .failed
        }
    }
}

enum ProjectListSort: String, CaseIterable, Identifiable {
    case createdNewest
    case lastActivityNewest
    case titleAlphabetical
    case durationLongest
    case coverageHighest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .createdNewest: return "Newest first"
        case .lastActivityNewest: return "Recent activity"
        case .titleAlphabetical: return "Title (A–Z)"
        case .durationLongest: return "Longest run"
        case .coverageHighest: return "Highest coverage"
        }
    }

    func apply(to projects: [ProjectSummary]) -> [ProjectSummary] {
        switch self {
        case .createdNewest:
            return projects.sorted { $0.createdAt > $1.createdAt }
        case .lastActivityNewest:
            return projects.sorted { $0.lastActivityAt > $1.lastActivityAt }
        case .titleAlphabetical:
            return projects.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .durationLongest:
            return projects.sorted {
                let lhs = $0.stageTimings.totalDurationSeconds ?? -1
                let rhs = $1.stageTimings.totalDurationSeconds ?? -1
                if lhs == rhs {
                    return $0.createdAt > $1.createdAt
                }
                return lhs > rhs
            }
        case .coverageHighest:
            return projects.sorted {
                let lhs = $0.reconstruction?.registeredFraction ?? -1
                let rhs = $1.reconstruction?.registeredFraction ?? -1
                if lhs == rhs {
                    return $0.createdAt > $1.createdAt
                }
                return lhs > rhs
            }
        }
    }
}

enum ProjectStatus: String {
    case ready
    case inProgress
    case failed
    /// Project metadata is from a future build of EasySplat; current build can't safely open it.
    case needsAppUpdate
}
