import Foundation
import EasySplatCore

struct ProjectSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let url: URL
    let createdAt: Date
    let status: ProjectStatus
    let hasPreviousResultHint: Bool
    let isActive: Bool
    let isInterrupted: Bool
    let checkpointUpdatedAt: Date?
    let stageTimings: [StageTimingRecord]
    let createToViewerReadySeconds: TimeInterval?
    let input: InputSpec?
    let requestedRunOptions: RequestedRunOptions?
    let lastOpenedAt: Date?
    let lastRunStartedAt: Date?
    let lastFailureAt: Date?
}

extension ProjectSummary {
    static func canonicalURL(for url: URL) -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return URL(filePath: resolved.path, directoryHint: .notDirectory)
    }

    static func hasSameLocation(_ first: URL?, _ second: URL) -> Bool {
        guard let first else { return false }
        return canonicalURL(for: first) == canonicalURL(for: second)
    }

    /// Single identity for sidebar row diffing and List selection tags; the
    /// two must never diverge or a reorder can strand the highlight.
    var selectionID: URL {
        Self.canonicalURL(for: url)
    }

    /// Latest durable pipeline activity used by the Recent sort. Opening a
    /// project deliberately does not count: the list must not reshuffle
    /// underneath the row the user just clicked.
    var lastActivityAt: Date {
        [lastRunStartedAt, lastFailureAt, lastRunCompletedAt]
            .compactMap { $0 }
            .max() ?? createdAt
    }

    var lastRunCompletedAt: Date {
        let stageEnds = stageTimings.map {
            $0.startedAt.addingTimeInterval($0.durationSeconds)
        }
        return (stageEnds + [checkpointUpdatedAt, createdAt].compactMap { $0 }).max() ?? createdAt
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .createdNewest: return "Created"
        case .lastActivityNewest: return "Recent"
        case .titleAlphabetical: return "Name"
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
        }
    }
}

enum ProjectStatus: String, Sendable {
    case ready
    case inProgress
    case failed
}
