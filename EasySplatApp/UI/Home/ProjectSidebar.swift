import AppKit
import CryptoKit
import EasySplatCore
import SwiftUI

struct ProjectSidebar: View {
    @Binding var selection: URL?
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

    private var listSelection: Binding<URL?> {
        Binding(
            get: { selection },
            set: { updateSelection($0) }
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
                        ForEach(visibleProjects, id: \.url) { project in
                            projectRow(project)
                                .tag(Self.selectionID(for: project))
                                .accessibilityIdentifier(Self.rowAccessibilityIdentifier(for: project.url))
                                .contextMenu { projectMenu(project) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search Projects")
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
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.title)

                HStack(spacing: Theme.Spacing.small) {
                    Text(statusText(for: project))
                    Spacer(minLength: Theme.Spacing.small)
                    Text(project.lastActivityAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(project.title), \(statusText(for: project)), \(project.lastActivityAt.formatted(date: .long, time: .omitted))"
            )

            if let actionTitle = Self.rowActionTitle(status: project.status) {
                Button(actionTitle) {
                    open(project)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .disabled(isRunActive)
                .accessibilityLabel("\(actionTitle) \(project.title)")
                .accessibilityIdentifier(Self.actionAccessibilityIdentifier(for: project.url))
            }
        }
        .padding(.vertical, 2)
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

    private func updateSelection(_ requestedSelection: URL?) {
        guard !isRunActive else { return }
        selection = Self.selectionAfterOpening(
            requestedSelection,
            current: selection,
            projects: model.projectSummaries,
            open: beginOpening
        )
    }

    @discardableResult
    private func open(_ project: ProjectSummary) -> Bool {
        guard beginOpening(project) else { return false }
        selection = Self.selectionID(for: project)
        return true
    }

    private func beginOpening(_ project: ProjectSummary) -> Bool {
        guard !isRunActive else { return false }
        return model.resumeProject(at: project.url)
    }

    private func isLocked(_ project: ProjectSummary) -> Bool {
        isRunActive && ProjectSummary.hasSameLocation(model.currentProjectURL, project.url)
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

    nonisolated static func opensOnSelection(status: ProjectStatus) -> Bool {
        status == .ready
    }

    nonisolated static func rowActionTitle(status: ProjectStatus) -> String? {
        switch status {
        case .inProgress: return "Resume"
        case .failed: return "Try Again"
        case .ready, .needsAppUpdate: return nil
        }
    }

    nonisolated static func renameDraftIsInvalid(draft: String, currentTitle: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == currentTitle
    }

    nonisolated static func selectionID(for project: ProjectSummary) -> URL {
        selectionID(for: project.url)
    }

    nonisolated static func selectionID(for projectURL: URL) -> URL {
        ProjectSummary.canonicalURL(for: projectURL)
    }

    nonisolated static func project(
        forSelectionID selectionID: URL,
        in projects: [ProjectSummary]
    ) -> ProjectSummary? {
        projects.first { Self.selectionID(for: $0) == selectionID }
    }

    nonisolated static func acceptedUserSelection(
        _ requestedSelection: URL?,
        current: URL?,
        projects: [ProjectSummary]
    ) -> URL? {
        guard let requestedSelection,
              let project = project(forSelectionID: requestedSelection, in: projects),
              opensOnSelection(status: project.status) else {
            return current
        }
        return selectionID(for: project)
    }

    @MainActor
    static func selectionAfterOpening(
        _ requestedSelection: URL?,
        current: URL?,
        projects: [ProjectSummary],
        open: (ProjectSummary) -> Bool
    ) -> URL? {
        let accepted = acceptedUserSelection(
            requestedSelection,
            current: current,
            projects: projects
        )
        guard accepted != current,
              let accepted,
              let project = project(forSelectionID: accepted, in: projects) else {
            return current
        }
        return open(project) ? accepted : current
    }

    nonisolated static func rowAccessibilityIdentifier(for projectURL: URL) -> String {
        accessibilityIdentifier(prefix: "project.row", projectURL: projectURL)
    }

    nonisolated static func actionAccessibilityIdentifier(for projectURL: URL) -> String {
        accessibilityIdentifier(prefix: "project.action", projectURL: projectURL)
    }

    private nonisolated static func accessibilityIdentifier(prefix: String, projectURL: URL) -> String {
        let canonicalPath = ProjectSummary.canonicalURL(for: projectURL).path
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        let shortDigest = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(prefix).\(shortDigest)"
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
        if ProjectSummary.hasSameLocation(model.currentProjectURL, project.url), isRunActive {
            model.cancelCurrentProject(deleteProject: true)
            projectToTrash = nil
            return
        }
        if model.moveProjectToTrash(at: project.url), selection == Self.selectionID(for: project) {
            selection = nil
        }
        projectToTrash = nil
    }
}
