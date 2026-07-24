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
            SidebarSearchField(text: $searchText, prompt: "Search Projects")
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.top, Theme.Spacing.small)

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
                        ForEach(visibleProjects, id: \.selectionID) { project in
                            projectRow(project)
                                .tag(project.selectionID)
                                .contextMenu { projectMenu(project) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .toolbar {
            ToolbarItem {
                Button(action: onNewSplat) {
                    Label("New Splat", systemImage: "plus")
                }
                .disabled(isRunActive)
                .help("New Splat")
                .accessibilityIdentifier("sidebar.newSplat")
            }
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
        .tint(Color.primary)
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
        .tint(Color.primary)
        .fixedSize()
    }

    private func projectRow(_ project: ProjectSummary) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            if project.status == .ready && !isRunActive {
                projectLabel(project)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Open project")
                    .accessibilityAction {
                        _ = open(project)
                    }
            } else {
                projectLabel(project)
            }

            if !isRunActive,
               let actionTitle = Self.rowActionTitle(status: project.status) {
                Button(actionTitle) {
                    open(project)
                }
                .buttonStyle(.bordered)
                .tint(Color.primary)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("\(actionTitle) \(project.title)")
                .accessibilityIdentifier(Self.actionAccessibilityIdentifier(for: project.url))
            }
        }
        .padding(.vertical, 2)
        .selectionDisabled(rowIsUnavailable(project))
    }

    private func projectLabel(_ project: ProjectSummary) -> some View {
        let unavailable = rowIsUnavailable(project)
        return VStack(alignment: .leading, spacing: 3) {
            Text(project.title)
                .font(.body)
                .foregroundStyle(unavailable ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(unavailable ? "Opens after the current run finishes." : project.title)

            let caption = Self.rowCaption(
                status: project.status,
                isInterrupted: project.isInterrupted
            )
            let date = project.lastActivityAt.formatted(date: .abbreviated, time: .omitted)
            // At tight widths the date yields rather than truncating both.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) {
                    if let caption { Text(caption).fixedSize() }
                    Spacer(minLength: Theme.Spacing.small)
                    Text(date).fixedSize()
                }
                HStack(spacing: Theme.Spacing.small) {
                    if let caption { Text(caption) }
                    Spacer(minLength: 0)
                }
            }
            .font(.caption)
            .foregroundStyle(unavailable ? .tertiary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(project.title), \(statusText(for: project)), \(project.lastActivityAt.formatted(date: .long, time: .omitted))"
        )
        .accessibilityIdentifier(Self.rowAccessibilityIdentifier(for: project.url))
    }

    @ViewBuilder
    private func projectMenu(_ project: ProjectSummary) -> some View {
        Button(openActionTitle(for: project)) {
            open(project)
        }
        .disabled(isRunActive)

        Button("Rename…") {
            renameDraft = project.title
            renameTarget = project
        }
        .disabled(isLocked(project))

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
        isRunActive
    }

    private func rowIsUnavailable(_ project: ProjectSummary) -> Bool {
        Self.rowIsUnavailableDuringRun(
            isRunActive: isRunActive,
            isActiveProject: ProjectSummary.hasSameLocation(model.currentProjectURL, project.url)
        )
    }

    private func statusText(for project: ProjectSummary) -> String {
        Self.rowCaption(status: project.status, isInterrupted: project.isInterrupted) ?? "Ready"
    }

    /// Visible status caption for a row; ready rows carry none. The full
    /// status stays in the row's accessibility label.
    nonisolated static func rowCaption(status: ProjectStatus, isInterrupted: Bool) -> String? {
        if isInterrupted { return "Unfinished" }
        switch status {
        case .ready: return nil
        case .inProgress: return "In Progress"
        case .failed: return "Failed"
        }
    }

    private func openActionTitle(for project: ProjectSummary) -> String {
        switch project.status {
        case .ready: return "Open"
        case .failed: return "Try Again"
        case .inProgress: return "Resume"
        }
    }

    nonisolated static func opensOnSelection(status: ProjectStatus) -> Bool {
        status == .ready
    }

    /// While a run is active every other project is inert; the selection
    /// binding already refuses it, so the row must also look and act held.
    /// The running project keeps full prominence.
    nonisolated static func rowIsUnavailableDuringRun(
        isRunActive: Bool,
        isActiveProject: Bool
    ) -> Bool {
        isRunActive && !isActiveProject
    }

    nonisolated static func rowActionTitle(status: ProjectStatus) -> String? {
        switch status {
        case .inProgress: return "Resume"
        case .failed: return "Try Again"
        case .ready: return nil
        }
    }

    nonisolated static func renameDraftIsInvalid(draft: String, currentTitle: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == currentTitle
    }

    nonisolated static func selectionID(for project: ProjectSummary) -> URL {
        project.selectionID
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
