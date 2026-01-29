import SwiftUI
import AppKit

struct ProjectListView: View {
    let projects: [ProjectSummary]

    @EnvironmentObject private var model: AppModel
    @State private var projectToDelete: ProjectSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects")
                .font(.headline)

            if projects.isEmpty {
                Text("No projects yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projects) { project in
                    projectRow(project)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                }
            }
        }
        .confirmationDialog("Delete this project?", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        ), titleVisibility: .visible) {
            if let project = projectToDelete {
                Button("Delete Project", role: .destructive) {
                    deleteProject(project)
                }
            }
            Button("Cancel", role: .cancel) {
                projectToDelete = nil
            }
        } message: {
            Text("This removes the project folder from disk.")
        }
    }

    private func projectRow(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor(for: project.status))
                    .frame(width: 8, height: 8)
                Text(project.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusLabel(for: project.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(for: project.status))
            }

            Text(Self.dateFormatter.string(from: project.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if project.status == .failed, let lastError = project.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if project.isRetrying, let lastError = project.lastError, !lastError.isEmpty {
                Text("Previous attempt failed: \(lastError)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Open/Resume") {
                    model.resumeProject(at: project.url)
                }
                .buttonStyle(.bordered)

                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                }
                .buttonStyle(.bordered)

                Button("Delete") {
                    projectToDelete = project
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func statusLabel(for status: ProjectStatus) -> String {
        switch status {
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .failed: return "Failed"
        }
    }

    private func statusColor(for status: ProjectStatus) -> Color {
        switch status {
        case .ready: return Theme.success
        case .inProgress: return Theme.accent
        case .failed: return .red
        }
    }

    private func deleteProject(_ project: ProjectSummary) {
        if model.currentProjectURL == project.url {
            model.cancelCurrentProject(deleteProject: true)
            projectToDelete = nil
            return
        }
        try? FileManager.default.removeItem(at: project.url)
        projectToDelete = nil
        model.refreshProjectSummaries()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
