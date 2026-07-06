import SwiftUI

/// Subtle hover treatment for project rows in the home list. macOS users
/// expect interactive rows to acknowledge the cursor; we lift the card
/// slightly and brighten the stroke without overdoing the motion.
struct ProjectRowHoverEffect: ViewModifier {
    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.005 : 1.0)
            .shadow(
                color: Theme.accent.opacity(isHovered ? 0.12 : 0),
                radius: isHovered ? 6 : 0,
                x: 0,
                y: isHovered ? 2 : 0
            )
            .animation(reduceMotion ? nil : Theme.Motion.hover, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
