import AppKit
import SwiftUI

@MainActor
final class ShareToolbarNSButton: NSButton {
    var onActivate: ((NSView) -> Void)?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        onActivate?(self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate?(self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            performClick(self)
            return
        }
        super.keyDown(with: event)
    }

    @objc private func activateShare(_ sender: NSButton) {
        onActivate?(self)
    }

    private func configure() {
        title = "Share"
        image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: nil
        )
        imagePosition = .imageOnly
        bezelStyle = .toolbar
        controlSize = .regular
        toolTip = "Share the validated PLY"
        target = self
        action = #selector(activateShare(_:))
        sendAction(on: .leftMouseDown)
        setAccessibilityIdentifier("result.share")
        setAccessibilityLabel("Share")
        setAccessibilityHelp("Share the validated PLY")
    }
}

struct ShareToolbarButton: NSViewRepresentable {
    let isEnabled: Bool
    let onActivate: (NSView) -> Void

    func makeNSView(context: Context) -> ShareToolbarNSButton {
        let button = ShareToolbarNSButton()
        button.isEnabled = isEnabled
        button.onActivate = onActivate
        return button
    }

    func updateNSView(_ button: ShareToolbarNSButton, context: Context) {
        button.isEnabled = isEnabled
        button.onActivate = onActivate
    }

    static func dismantleNSView(_ button: ShareToolbarNSButton, coordinator: ()) {
        button.onActivate = nil
        button.target = nil
    }
}
