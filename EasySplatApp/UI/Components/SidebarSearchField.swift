import AppKit
import SwiftUI

/// A hand-placed native search field. The system `.searchable(placement: .sidebar)`
/// chrome pins its field flush against the top of the sidebar column with no way to
/// inset it, so the sidebar owns the field directly.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldDidSendAction(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        // The cancel (clear) button sends the action without a text-change
        // notification, so mirror the value here as well.
        @objc func searchFieldDidSendAction(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}
