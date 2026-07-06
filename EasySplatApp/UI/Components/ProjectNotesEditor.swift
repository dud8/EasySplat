import SwiftUI

/// Isolates the notes TextEditor binding so each keystroke only invalidates
/// this small subtree instead of re-rendering the entire viewer body.
struct ProjectNotesEditor: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
            }
            TextEditor(text: Binding(
                get: { model.currentProjectNotes },
                set: { newValue in
                    model.currentProjectNotes = newValue
                    if let url = model.currentProjectURL {
                        // Debounce so each keystroke doesn't rewrite project.json.
                        model.scheduleNotesSave(at: url, to: newValue)
                    }
                }
            ))
            .font(.body)
            .frame(minHeight: 70, maxHeight: 140)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .stroke(Theme.border)
            )
        }
    }
}
