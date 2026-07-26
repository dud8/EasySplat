import SwiftUI

/// A disclosure section whose entire header row toggles it. `DisclosureGroup`
/// only accepts clicks on its chevron, which is a hard target to hit and gives
/// no hint that the row is interactive.
struct DisclosureSection<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private static var headerInset: CGFloat { 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, Self.headerInset)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
            // Cancels the hit-target padding so the header stays optically
            // aligned with the section's content.
            .padding(.horizontal, -Self.headerInset)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content()
            }
        }
    }

    private func toggle() {
        let animation = reduceMotion
            ? nil
            : Theme.Motion.workspace(duration: Theme.Motion.standardWorkspaceDuration)
        withAnimation(animation) { isExpanded.toggle() }
    }
}
