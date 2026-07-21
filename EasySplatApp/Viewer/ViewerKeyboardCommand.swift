import AppKit

struct ViewerKeyboardModifiers: OptionSet {
    let rawValue: Int

    static let option = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let command = Self(rawValue: 1 << 2)
    static let control = Self(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: Self = []
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
}

enum ViewerKeyboardCommand: Equatable {
    case orbit(horizontal: Int, vertical: Int)
    case pan(horizontal: Int, vertical: Int)
    case zoomIn
    case zoomOut
    case fit
    case reset

    static func resolve(
        keyCode: UInt16,
        characters: String?,
        modifiers: ViewerKeyboardModifiers
    ) -> Self? {
        guard modifiers.isDisjoint(with: [.command, .control]) else { return nil }

        let direction: (horizontal: Int, vertical: Int)? = switch keyCode {
        case 123: (-1, 0)
        case 124: (1, 0)
        case 125: (0, -1)
        case 126: (0, 1)
        default: nil
        }
        if let direction {
            return modifiers.contains(.option)
                ? .pan(horizontal: direction.horizontal, vertical: direction.vertical)
                : .orbit(horizontal: direction.horizontal, vertical: direction.vertical)
        }

        guard !modifiers.contains(.option) else { return nil }
        switch keyCode {
        case 24, 69:
            return .zoomIn
        case 27, 78:
            return .zoomOut
        default:
            break
        }

        switch characters?.lowercased() {
        case "f": return .fit
        case "r": return .reset
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        default: return nil
        }
    }
}
