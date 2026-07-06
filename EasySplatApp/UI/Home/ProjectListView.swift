import SwiftUI
import AppKit
import EasySplatCore

struct ProjectListView: View {
    let projects: [ProjectSummary]

    @EnvironmentObject private var model: AppModel
    @State private var projectToDelete: ProjectSummary?
    @State private var renameTarget: ProjectSummary?
    @State private var renameDraft: String = ""
    // Persist filter + sort selections across launches so power users with
    // many projects don't re-pick "Failed / Recent activity" every session.
    @AppStorage("EasySplatProjectListFilter") private var filterRawValue: String = ProjectListFilter.all.rawValue
    @AppStorage("EasySplatProjectListSort") private var sortRawValue: String = ProjectListSort.createdNewest.rawValue
    @State private var searchText: String = ""
    @State private var showTrashAllFailedConfirm: Bool = false

    private var filter: ProjectListFilter {
        ProjectListFilter(rawValue: filterRawValue) ?? .all
    }
    private func setFilter(_ value: ProjectListFilter) { filterRawValue = value.rawValue }

    private var sort: ProjectListSort {
        ProjectListSort(rawValue: sortRawValue) ?? .createdNewest
    }
    private func setSort(_ value: ProjectListSort) { sortRawValue = value.rawValue }

    private var filteredAndSortedProjects: [ProjectSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = projects
            .filter { filter.matches($0) }
            .filter { project in
                guard !query.isEmpty else { return true }
                return project.title.localizedCaseInsensitiveContains(query)
            }
        return sort.apply(to: filtered)
    }

    private func countForFilter(_ filter: ProjectListFilter) -> Int {
        projects.filter { filter.matches($0) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Projects")
                    .font(.headline)
                Spacer()
                if !projects.isEmpty {
                    sortMenu
                }
            }

            if !projects.isEmpty {
                filterBar
                if projects.count >= 4 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        TextField("Search projects by title", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            let visible = filteredAndSortedProjects
            if projects.isEmpty {
                emptyStateCard
            } else if visible.isEmpty {
                let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(trimmedQuery.isEmpty
                     ? "No projects match the \(filter.displayName.lowercased()) filter."
                     : "No projects match “\(trimmedQuery)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible) { project in
                    decoratedProjectRow(project)
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
            Text("The project bundle moves to the Trash. You can restore it from Finder if you change your mind.")
        }
        .confirmationDialog(
            "Move all failed projects to the Trash?",
            isPresented: $showTrashAllFailedConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                trashAllFailedProjects()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            let count = countForFilter(.failed)
            Text("\(count) failed project\(count == 1 ? "" : "s") will move to the Trash. Recover individually from Finder if needed.")
        }
        .alert("Rename project", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { project in
            TextField("Title", text: $renameDraft)
            Button("Save") {
                model.renameProject(at: project.url, to: renameDraft)
                renameTarget = nil
            }
            .disabled(Self.renameDraftIsInvalid(draft: renameDraft, currentTitle: project.title))
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: { _ in
            Text("Renaming updates the title shown in EasySplat. The project bundle on disk keeps its current folder name.")
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                Text("No projects yet")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Drop a video or photos folder above to build your first 3D splat. Every run lives in its own .easysplatproj bundle and stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.border.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ProjectListFilter.allCases) { option in
                filterPill(option)
            }
            Spacer(minLength: 0)
            if filter == .failed, countForFilter(.failed) > 0 {
                Button("Trash All Failed") {
                    showTrashAllFailedConfirm = true
                }
                .buttonStyle(SecondaryButtonStyle(variant: .destructive))
                .controlSize(.small)
                .help("Move every failed project to the Trash. You can recover them from Finder if needed.")
            }
        }
    }

    private func filterPill(_ option: ProjectListFilter) -> some View {
        let count = countForFilter(option)
        let isSelected = filter == option
        return Button {
            setFilter(option)
        } label: {
            HStack(spacing: 6) {
                Text(option.displayName)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.20) : Theme.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? Theme.accent.opacity(0.55) : Theme.border)
            )
            .foregroundStyle(isSelected ? Theme.accent : .primary)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && option != .all)
        .opacity(count == 0 && option != .all ? 0.5 : 1.0)
        .accessibilityLabel("\(option.displayName), \(count) project\(count == 1 ? "" : "s")")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(
                get: { sort },
                set: { setSort($0) }
            )) {
                ForEach(ProjectListSort.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sort.displayName)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func decoratedProjectRow(_ project: ProjectSummary) -> some View {
        projectRow(project)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.border)
            )
            .modifier(ProjectRowHoverEffect())
            .contextMenu { projectRowContextMenu(project) }
    }

    @ViewBuilder
    private func projectRowContextMenu(_ project: ProjectSummary) -> some View {
        Button("Rename…") {
            renameDraft = project.title
            renameTarget = project
        }
        .disabled(project.status == .needsAppUpdate)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        Button("Open Pipeline Log") {
            let log = ProjectPaths(root: project.url).pipelineLogURL
            if FileManager.default.fileExists(atPath: log.path) {
                NSWorkspace.shared.open(log)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
        }
        if project.status == .failed {
            Button("Copy Diagnostics") {
                model.copyDiagnosticBundle(forProjectURL: project.url)
            }
            Button("Save Diagnostics…") {
                model.saveDiagnosticBundle(forProjectURL: project.url)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            projectToDelete = project
        }
    }

    private func projectRow(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(project.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                statusPill(for: project.status)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(project.title), \(statusLabel(for: project.status))")

            ProjectRowMetadataBadges(
                project: project,
                createdAtText: Self.dateFormatter.string(from: project.createdAt)
            )

            if project.status == .failed, let lastError = project.lastError, !lastError.isEmpty {
                let category = ProjectFailureCategory.classify(message: lastError)
                Label(lastError, systemImage: category.systemImageName)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.red)
                if let hint = category.hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if project.isRetrying, let lastError = project.lastError, !lastError.isEmpty {
                Text("Previous attempt failed: \(lastError)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if project.status == .needsAppUpdate {
                Text("This project was created with a newer version of EasySplat. Update the app to open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Open/Resume") {
                    model.resumeProject(at: project.url)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(project.status == .needsAppUpdate)

                if project.status == .failed {
                    Button("Copy Diagnostics") {
                        model.copyDiagnosticBundle(forProjectURL: project.url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Copy a paste-ready diagnostic summary (metadata + log tails) for bug reports.")
                }

                Spacer()

                Button("Delete", role: .destructive) {
                    projectToDelete = project
                }
                .buttonStyle(SecondaryButtonStyle(variant: .destructive))
            }
        }
    }

    @ViewBuilder
    private func statusPill(for status: ProjectStatus) -> some View {
        let tint = statusColor(for: status)
        Text(statusLabel(for: status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.13))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private func statusLabel(for status: ProjectStatus) -> String {
        switch status {
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .failed: return "Failed"
        case .needsAppUpdate: return "Update EasySplat"
        }
    }

    private func statusColor(for status: ProjectStatus) -> Color {
        switch status {
        case .ready: return Theme.success
        case .inProgress: return Theme.accent
        case .failed: return .red
        case .needsAppUpdate: return Theme.accent
        }
    }

    private func trashAllFailedProjects() {
        let urls = Self.trashCandidateURLs(in: projects, excludingActive: model.currentProjectURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, _ in
            DispatchQueue.main.async {
                model.refreshProjectSummaries()
            }
        }
    }

    /// Pure helper extracted so unit tests can exercise the filter logic
    /// without touching NSWorkspace. Returns the URLs of every failed
    /// project except the actively-processing one (which the cancel path
    /// owns).
    nonisolated static func trashCandidateURLs(
        in projects: [ProjectSummary],
        excludingActive activeURL: URL?
    ) -> [URL] {
        return projects
            .filter { $0.status == .failed && $0.url != activeURL }
            .map(\.url)
    }

    nonisolated static func renameDraftIsInvalid(draft: String, currentTitle: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == currentTitle
    }

    private func deleteProject(_ project: ProjectSummary) {
        // Two paths:
        // 1. The project is the one a live pipeline is processing — cancel
        //    the pipeline first; cancelCurrentProject(deleteProject: true)
        //    handles the recycle as part of its teardown.
        // 2. Everything else (including the just-finished project still
        //    parked in the viewer) goes through NSWorkspace.recycle so the
        //    confirmation dialog's "moves to Trash" promise stays accurate.
        let isActivelyProcessing = model.currentProjectURL == project.url
            && model.viewState == .processing
        if isActivelyProcessing {
            model.cancelCurrentProject(deleteProject: true)
            projectToDelete = nil
            return
        }
        // If we're trashing the project the viewer is currently showing,
        // also tear down its in-memory state so the next refresh doesn't
        // try to re-display a vanished bundle.
        if model.currentProjectURL == project.url {
            model.flushPendingNotesSave()
            model.viewState = .home
        }
        NSWorkspace.shared.recycle([project.url]) { _, _ in
            DispatchQueue.main.async {
                model.refreshProjectSummaries()
            }
        }
        projectToDelete = nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
