import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedProjectURL: URL?

    private var isRunActive: Bool {
        model.isRunActive
    }

    private var actionFailureIsPresented: Binding<Bool> {
        Binding(
            get: { model.actionFailure != nil },
            set: { if !$0 { model.actionFailure = nil } }
        )
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(
                selection: $selectedProjectURL,
                isRunActive: isRunActive,
                onNewSplat: beginNewSplat
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 320)
        } detail: {
            WorkspaceView(
                onNewSplat: beginNewSplat,
                onBackToProjects: showProjects
            )
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .background(WindowAccessor())
        .onChange(of: model.currentProjectURL) { _, projectURL in
            selectedProjectURL = projectURL.map(ProjectSidebar.selectionID(for:))
        }
        .alert(
            model.actionFailure?.title ?? "Action failed",
            isPresented: actionFailureIsPresented
        ) {
            Button("OK") {
                model.actionFailure = nil
            }
        } message: {
            if let message = model.actionFailure?.message {
                Text(message)
            }
        }
    }

    private func beginNewSplat() {
        guard !isRunActive else { return }
        Self.prepareNewSplat(model: model, selectedProjectURL: &selectedProjectURL)
    }

    private func showProjects() {
        guard !isRunActive else { return }
        Self.prepareProjectList(model: model, selectedProjectURL: &selectedProjectURL)
    }

    @MainActor
    static func prepareNewSplat(model: AppModel, selectedProjectURL: inout URL?) {
        guard model.beginNewSplat() else { return }
        selectedProjectURL = nil
    }

    @MainActor
    static func prepareProjectList(model: AppModel, selectedProjectURL: inout URL?) {
        guard model.flushPendingNotesSave() else { return }
        model.reset()
        model.viewState = .home
        model.refreshProjectSummaries()
        selectedProjectURL = nil
    }
}
