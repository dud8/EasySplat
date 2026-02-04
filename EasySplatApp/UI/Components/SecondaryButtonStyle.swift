import SwiftUI

struct SecondaryButtonStyle: ButtonStyle {
    enum Variant {
        case standard
        case subtleAccent
        case destructive
    }

    var variant: Variant = .standard

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, variant: variant)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: SecondaryButtonStyle.Variant

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false

    var body: some View {
        let padding = paddingForControlSize(controlSize)
        let scale = resolvedScale
        let shadow = resolvedShadow

        return configuration.label
            .padding(.horizontal, padding.horizontal)
            .padding(.vertical, padding.vertical)
            .foregroundStyle(labelColor)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(baseTintOverlayColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(overlayColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
                    .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .scaleEffect(scale)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : Theme.Motion.hover, value: isHovering)
            .animation(reduceMotion ? nil : Theme.Motion.press, value: configuration.isPressed)
    }

    private var baseTintOverlayColor: Color {
        guard isEnabled else { return Color.clear }
        switch variant {
        case .standard:
            return Color.clear
        case .subtleAccent:
            return accentColor.opacity(0.08)
        case .destructive:
            return accentColor.opacity(0.06)
        }
    }

    private var overlayColor: Color {
        if !isEnabled {
            return Color.clear
        }
        if configuration.isPressed {
            return accentColor.opacity(0.12)
        }
        if isHovering {
            return accentColor.opacity(0.08)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if !isEnabled {
            return Theme.border.opacity(0.6)
        }
        if configuration.isPressed {
            return accentColor.opacity(0.32)
        }
        if isHovering {
            return accentColor.opacity(0.25)
        }
        switch variant {
        case .standard:
            return Theme.border
        case .subtleAccent:
            return accentColor.opacity(0.16)
        case .destructive:
            return accentColor.opacity(0.3)
        }
    }

    private var resolvedScale: CGFloat {
        if !isEnabled || reduceMotion {
            return 1.0
        }
        if configuration.isPressed {
            return 0.99
        }
        if isHovering {
            return 1.01
        }
        return 1.0
    }

    private var resolvedShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        guard isEnabled else { return (.clear, 0, 0) }
        if configuration.isPressed {
            return (Color.black.opacity(0.06), 2, 1)
        }
        if isHovering {
            return (Color.black.opacity(0.08), 4, 2)
        }
        return (.clear, 0, 0)
    }

    private func paddingForControlSize(_ controlSize: ControlSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        switch controlSize {
        case .mini:
            return (10, 5)
        case .small:
            return (12, 7)
        default:
            return (16, 9)
        }
    }

    private var accentColor: Color {
        switch variant {
        case .standard, .subtleAccent:
            return Theme.accent
        case .destructive:
            return .red
        }
    }

    private var labelColor: Color {
        if !isEnabled {
            return .secondary
        }
        if variant == .destructive {
            return accentColor
        }
        return .primary
    }
}
