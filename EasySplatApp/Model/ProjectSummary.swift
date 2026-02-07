import Foundation

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
}

enum ProjectStatus: String {
    case ready
    case inProgress
    case failed
}
