import AppKit
import EasySplatCore
import SwiftUI

struct ProjectSidebar: View {
    @Binding var selection: UUID?
    let isRunActive: Bool
    let onNewSplat: () -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage("EasySplatProjectListFilter") private var filterRawValue = ProjectListFilter.all.rawValue
    @AppStorage("EasySplatProjectListSort") private var sortRawValue = ProjectListSort.lastActivityNewest.rawValue
    @State private var searchText = ""
    @State private var projectToTrash: ProjectSummary?
    @State private var renameTarget: ProjectSummary?
    @State private var renameDraft = ""

    private var filter: ProjectListFilter {
        ProjectListFilter(rawValue: filterRawValue) ?? .all
    }

    private var sort: ProjectListSort {
        ProjectListSort(rawValue: sortRawValue) ?? .lastActivityNewest
    }

    private var visibleProjects: [ProjectSummary] {
        Self.visibleProjects(
            model.projectSummaries,
            filter: filter,
            sort: sort,
            searchText: searchText
        )
    }

    private var listSelection: Binding<UUID?> {
        Binding(
            get: {
                if model.viewState != .home,
                   let currentURL = model.currentProjectURL,
                   let current = model.projectSummaries.first(where: { $0.url == currentURL }) {
                    return current.id
                }
                return selection
            },
            set: { selection = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onNewSplat) {
                Label("New Splat", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRunActive)
            .keyboardShortcut("n", modifiers: .command)
            .padding(Theme.Spacing.medium)

            Divider()

            HStack(spacing: Theme.Spacing.small) {
                statusMenu
                sortMenu
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)

            List(selection: listSelection) {
                Section("Projects") {
                    if visibleProjects.isEmpty {
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleProjects) { project in
                            projectRow(project)
                                .tag(project.id)
                                .contextMenu { projectMenu(project) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search Projects")
            .onChange(of: selection) { _, projectID in
                openSelectedProject(projectID)
            }
        }
        .onAppear {
            model.refreshProjectSummaries()
        }
        .confirmationDialog(
            "Move project to Trash?",
            isPresented: Binding(
                get: { projectToTrash != nil },
                set: { if !$0 { projectToTrash = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let project = projectToTrash {
                Button("Move to Trash", role: .destructive) {
                    moveToTrash(project)
                }
            }
            Button("Cancel", role: .cancel) {
                projectToTrash = nil
            }
        } message: {
            Text("You can restore the project from the Trash.")
        }
        .alert(
            "Rename Project",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            presenting: renameTarget
        ) { project in
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                model.renameProject(at: project.url, to: renameDraft)
                renameTarget = nil
            }
            .disabled(Self.renameDraftIsInvalid(draft: renameDraft, currentTitle: project.title))
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        }
    }

    private var emptyMessage: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "No projects match “\(query)”."
        }
        if filter != .all {
            return "No \(filter.displayName.lowercased()) projects."
        }
        return "No projects yet."
    }

    private var statusMenu: some View {
        Menu {
            Picker("Status", selection: Binding(
                get: { filter },
                set: { filterRawValue = $0.rawValue }
            )) {
                ForEach(ProjectListFilter.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } label: {
            Label(filter.displayName, systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { sort },
                set: { sortRawValue = $0.rawValue }
            )) {
                ForEach(ProjectListSort.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } label: {
            Label(sort.displayName, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func projectRow(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: Theme.Spacing.small) {
                Text(statusText(for: project))
                Spacer(minLength: Theme.Spacing.small)
                Text(project.lastActivityAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(project.title), \(statusText(for: project)), \(project.lastActivityAt.formatted(date: .long, time: .omitted))"
        )
    }

    @ViewBuilder
    private func projectMenu(_ project: ProjectSummary) -> some View {
        Button(openActionTitle(for: project)) {
            open(project)
        }
        .disabled(isRunActive || project.status == .needsAppUpdate)

        Button("Rename…") {
            renameDraft = project.title
            renameTarget = project
        }
        .disabled(isLocked(project) || project.status == .needsAppUpdate)

        Divider()

        Button("Copy Diagnostics") {
            model.copyDiagnosticBundle(forProjectURL: project.url)
        }
        Button("Save Diagnostics…") {
            model.saveDiagnosticBundle(forProjectURL: project.url)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }

        Divider()

        Button("Move to Trash…", role: .destructive) {
            projectToTrash = project
        }
        .disabled(isLocked(project))
    }

    private func openSelectedProject(_ projectID: UUID?) {
        guard let projectID,
              let project = model.projectSummaries.first(where: { $0.id == projectID }) else {
            return
        }
        guard !isRunActive else {
            selection = model.projectSummaries.first(where: { $0.url == model.currentProjectURL })?.id
            return
        }
        guard project.status != .needsAppUpdate else {
            selection = nil
            return
        }
        open(project)
    }

    private func open(_ project: ProjectSummary) {
        guard !isRunActive else { return }
        selection = project.id
        if project.isInterrupted {
            model.resumeInterruptedProject(project)
        } else {
            model.resumeProject(at: project.url)
        }
    }

    private func isLocked(_ project: ProjectSummary) -> Bool {
        isRunActive && project.url == model.currentProjectURL
    }

    private func statusText(for project: ProjectSummary) -> String {
        if project.isInterrupted {
            return "Unfinished"
        }
        switch project.status {
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .failed: return "Failed"
        case .needsAppUpdate: return "Update Required"
        }
    }

    private func openActionTitle(for project: ProjectSummary) -> String {
        switch project.status {
        case .ready: return "Open"
        case .failed: return "Try Again"
        case .inProgress: return "Resume"
        case .needsAppUpdate: return "Open"
        }
    }

    nonisolated static func renameDraftIsInvalid(draft: String, currentTitle: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == currentTitle
    }

    nonisolated static func visibleProjects(
        _ projects: [ProjectSummary],
        filter: ProjectListFilter,
        sort: ProjectListSort,
        searchText: String
    ) -> [ProjectSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = projects.filter { project in
            filter.matches(project)
                && (query.isEmpty || project.title.localizedCaseInsensitiveContains(query))
        }
        return sort.apply(to: filtered)
    }

    private func moveToTrash(_ project: ProjectSummary) {
        if model.currentProjectURL == project.url, model.viewState == .processing {
            model.cancelCurrentProject(deleteProject: true)
            projectToTrash = nil
            return
        }
        if model.currentProjectURL == project.url {
            model.flushPendingNotesSave()
            model.viewState = .home
            selection = nil
        }
        NSWorkspace.shared.recycle([project.url]) { _, _ in
            DispatchQueue.main.async {
                model.refreshProjectSummaries()
            }
        }
        projectToTrash = nil
    }
}
