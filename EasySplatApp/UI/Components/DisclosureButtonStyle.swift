import SwiftUI

struct DisclosureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureButtonBody(configuration: configuration)
    }
}

private struct DisclosureButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false

    var body: some View {
        return configuration.label
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(hoverBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .strokeBorder(hoverBorder, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : Theme.Motion.hover, value: isHovering)
            .animation(reduceMotion ? nil : Theme.Motion.press, value: configuration.isPressed)
    }

    private var hoverBackground: Color {
        guard isEnabled else { return Color.clear }
        if configuration.isPressed {
            return Theme.surface.opacity(0.85)
        }
        if isHovering {
            return Theme.surface.opacity(0.7)
        }
        return Color.clear
    }

    private var hoverBorder: Color {
        guard isEnabled else { return Color.clear }
        if configuration.isPressed {
            return Theme.border.opacity(0.8)
        }
        if isHovering {
            return Theme.border.opacity(0.6)
        }
        return Color.clear
    }
}
