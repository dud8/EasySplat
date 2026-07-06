import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let padding = paddingForControlSize(controlSize)
        let scale = resolvedScale
        let shadow = resolvedShadow

        return configuration.label
            .padding(.horizontal, padding.horizontal)
            .padding(.vertical, padding.vertical)
            .foregroundStyle(.white.opacity(isEnabled ? 1.0 : 0.7))
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(Theme.accent.opacity(isEnabled ? 1.0 : 0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(overlayColor)
                    )
                    .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button + 2, style: .continuous)
                    .stroke(Theme.accent.opacity(isFocused ? 0.85 : 0), lineWidth: 2)
                    .padding(-2)
            )
            .scaleEffect(scale)
            .focused($isFocused)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : Theme.Motion.hover, value: isHovering)
            .animation(reduceMotion ? nil : Theme.Motion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : Theme.Motion.hover, value: isFocused)
    }

    private var overlayColor: Color {
        if !isEnabled {
            return Color.black.opacity(0.05)
        }
        if configuration.isPressed {
            return Color.black.opacity(0.12)
        }
        if isHovering {
            return Color.white.opacity(0.08)
        }
        return Color.clear
    }

    private var resolvedScale: CGFloat {
        if !isEnabled || reduceMotion {
            return 1.0
        }
        if configuration.isPressed {
            return 0.985
        }
        if isHovering {
            return 1.015
        }
        return 1.0
    }

    private var resolvedShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        guard isEnabled else { return (.clear, 0, 0) }
        if configuration.isPressed {
            return (Color.black.opacity(0.12), 2, 1)
        }
        if isHovering {
            return (Color.black.opacity(0.18), 6, 3)
        }
        return (Color.black.opacity(0.14), 4, 2)
    }

    private func paddingForControlSize(_ controlSize: ControlSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        switch controlSize {
        case .mini:
            return (12, 6)
        case .small:
            return (14, 8)
        default:
            return (18, 10)
        }
    }
}
