enum ViewerDragMode: Equatable {
    case orbit
    case pan
    case freeLook
}

enum ViewerPointerCommand {
    static let secondaryButtonDragMode = ViewerDragMode.freeLook
    static let middleButtonDragMode = ViewerDragMode.pan

    /// Control doubles as the secondary click on macOS, so it wins over Option.
    static func dragMode(forPrimaryButtonWith modifiers: ViewerKeyboardModifiers) -> ViewerDragMode {
        if modifiers.contains(.control) { return .freeLook }
        if modifiers.contains(.option) { return .pan }
        return .orbit
    }
}
