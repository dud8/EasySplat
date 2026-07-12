import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedProjectID: UUID?

    private var isRunActive: Bool {
        Self.newSplatIsDisabled(
            isProcessing: model.viewState == .processing,
            hasError: model.lastError != nil
        )
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(
                selection: $selectedProjectID,
                isRunActive: isRunActive,
                onNewSplat: beginNewSplat
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
        } detail: {
            WorkspaceView()
                .frame(minWidth: 680, minHeight: 640)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .background(WindowAccessor())
    }

    private func beginNewSplat() {
        guard !isRunActive else { return }
        model.flushPendingNotesSave()
        model.clearPendingInputs()
        selectedProjectID = nil
        model.viewState = .home
    }

    nonisolated static func newSplatIsDisabled(isProcessing: Bool, hasError: Bool) -> Bool {
        isProcessing && !hasError
    }
}
