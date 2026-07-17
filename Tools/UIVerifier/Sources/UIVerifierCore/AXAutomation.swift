import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum AXAutomationError: Error, LocalizedError {
    case attribute(String, AXError)
    case noMainWindow(String)
    case cannotActivate(accessibilityError: AXError?)
    case cannotResize(AXError)
    case keyboardEventCreation
    case elementNotFound(String)
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .attribute(let name, let error):
            return "Could not read accessibility attribute \(name): AX error \(error.rawValue)."
        case .noMainWindow(let detail):
            return "The packaged app did not expose a main accessibility window (\(detail))."
        case .cannotActivate(let accessibilityError):
            if let accessibilityError {
                return "The packaged app did not become the frontmost application; AX error \(accessibilityError.rawValue)."
            }
            return "The packaged app did not become the frontmost application."
        case .cannotResize(let error):
            return "The packaged app window could not be resized: AX error \(error.rawValue)."
        case .keyboardEventCreation:
            return "CoreGraphics could not create a keyboard event."
        case .elementNotFound(let description):
            return "The packaged app did not expose \(description)."
        case .actionFailed(let description):
            return "The packaged app did not complete \(description)."
        }
    }
}

@MainActor
final class AXApplicationController {
    struct ActivationRequests {
        let frontmostProcessIdentifier: () -> pid_t?
        let activateWithAppKit: () -> Bool?
        let activateWithAccessibility: () -> AXError
    }

    private let application: AXUIElement
    private let processIdentifier: pid_t
    private let systemWide = AXUIElementCreateSystemWide()
    private let activationRequests: ActivationRequests

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        let application = AXUIElementCreateApplication(processIdentifier)
        self.application = application
        activationRequests = ActivationRequests(
            frontmostProcessIdentifier: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            },
            activateWithAppKit: {
                NSRunningApplication(processIdentifier: processIdentifier)?
                    .activate(options: [.activateAllWindows])
            },
            activateWithAccessibility: {
                AXUIElementSetAttributeValue(
                    application,
                    kAXFrontmostAttribute as CFString,
                    kCFBooleanTrue
                )
            }
        )
    }

    init(processIdentifier: pid_t, activationRequests: ActivationRequests) {
        self.processIdentifier = processIdentifier
        application = AXUIElementCreateApplication(processIdentifier)
        self.activationRequests = activationRequests
    }

    func activate(timeoutSeconds: Double = 5) async throws {
        if activationRequests.frontmostProcessIdentifier() == processIdentifier {
            return
        }
        guard activationRequests.activateWithAppKit() != nil else {
            throw AXAutomationError.cannotActivate(accessibilityError: nil)
        }
        if activationRequests.frontmostProcessIdentifier() == processIdentifier {
            return
        }
        let accessibilityError = activationRequests.activateWithAccessibility()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if activationRequests.frontmostProcessIdentifier() == processIdentifier {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw AXAutomationError.cannotActivate(
            accessibilityError: accessibilityError == .success ? nil : accessibilityError
        )
    }

    func waitForMainWindow(timeoutSeconds: Double = 15) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        try await Task.sleep(for: .milliseconds(500))
        repeat {
            if let main = elementAttribute(application, kAXMainWindowAttribute), !isMinimized(main) {
                return main
            }
            if let first = elementsAttribute(application, kAXWindowsAttribute).first(where: { !isMinimized($0) }) {
                return first
            }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        throw AXAutomationError.noMainWindow(windowDiagnostic())
    }

    func setSize(_ viewport: VerificationViewport, of window: AXUIElement) throws {
        var size = CGSize(width: viewport.width, height: viewport.height)
        guard let value = AXValueCreate(.cgSize, &size) else {
            throw AXAutomationError.cannotResize(.failure)
        }
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        guard result == .success else {
            throw AXAutomationError.cannotResize(result)
        }
    }

    func waitForSize(
        _ viewport: VerificationViewport,
        of window: AXUIElement,
        timeoutSeconds: Double = 4
    ) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let frame = frame(of: window),
               abs(frame.width - CGFloat(viewport.width)) <= 2,
               abs(frame.height - CGFloat(viewport.height)) <= 2 {
                return frame
            }
            try? await Task.sleep(for: .milliseconds(75))
        } while Date() < deadline
        return frame(of: window)
    }

    func snapshots(from root: AXUIElement) -> [AccessibilityNodeSnapshot] {
        var snapshots: [AccessibilityNodeSnapshot] = []
        var visited: Set<CFHashCode> = []

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 40, snapshots.count < 10_000 else { return }
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { return }

            let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
            let title = stringAttribute(element, kAXTitleAttribute)
            let label = [
                stringAttribute(element, kAXDescriptionAttribute),
                stringAttribute(element, kAXHelpAttribute),
            ].compactMap { $0 }.first(where: { !$0.isEmpty })
            let identifier = stringAttribute(element, kAXIdentifierAttribute)
            let enabled = boolAttribute(element, kAXEnabledAttribute) ?? true
            snapshots.append(AccessibilityNodeSnapshot(
                order: snapshots.count,
                role: role,
                subrole: stringAttribute(element, kAXSubroleAttribute),
                title: title,
                label: label,
                value: stringAttribute(element, kAXValueAttribute),
                placeholder: stringAttribute(element, kAXPlaceholderValueAttribute),
                identifier: identifier,
                enabled: enabled,
                frame: frame(of: element),
                actions: actionNames(of: element)
            ))

            var children: [AXUIElement] = []
            for attribute in [
                kAXChildrenAttribute,
                kAXVisibleChildrenAttribute,
                kAXRowsAttribute,
                kAXWindowsAttribute,
                "AXSheets",
            ] {
                children.append(contentsOf: elementsAttribute(element, attribute))
            }
            for child in children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return snapshots
    }

    func testChooseInputKeyboardActivation() async -> (passed: Bool, focusOrder: [String], failures: [String]) {
        var failures: [String] = []
        var recordedOrder: [String] = []
        for key in [(code: CGKeyCode(49), name: "Space"), (code: CGKeyCode(36), name: "Return")] {
            do {
                try await activate()
                let focus = try await focusElement(identifier: "home.chooseInput", maximumTabs: 80)
                if recordedOrder.isEmpty {
                    recordedOrder = focus.order
                }
                guard focus.found else {
                    failures.append("Keyboard focus did not reach Choose Input before \(key.name) activation.")
                    continue
                }
                let mainWindow = try await waitForMainWindow()
                try sendKey(key.code)
                guard await waitForDialog(relativeTo: mainWindow, presented: true) else {
                    failures.append("\(key.name) did not open the input picker from Choose Input.")
                    continue
                }
                try sendKey(CGKeyCode(53))
                guard await waitForDialog(relativeTo: mainWindow, presented: false) else {
                    failures.append("Escape did not close the input picker after \(key.name) activation.")
                    continue
                }
            } catch {
                failures.append("\(key.name) keyboard check failed: \(error.localizedDescription)")
                try? sendKey(CGKeyCode(53))
            }
        }
        return (failures.isEmpty, recordedOrder, failures)
    }

    func testKeyboardTraversal(
        requiredIdentifiers: Set<String>,
        maximumTabs: Int = 120
    ) async -> (passed: Bool, focusOrder: [String], failures: [String]) {
        do {
            try await activate()
            var order: [String] = []
            var observed: Set<String> = []
            for step in 0...maximumTabs {
                if step > 0 {
                    try sendKey(CGKeyCode(48))
                    try await Task.sleep(for: .milliseconds(90))
                }
                guard let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
                    ?? elementAttribute(systemWide, kAXFocusedUIElementAttribute) else {
                    continue
                }
                var focusedPID = pid_t()
                guard AXUIElementGetPid(focused, &focusedPID) == .success,
                      focusedPID == processIdentifier else {
                    continue
                }
                let name = contextualIdentifier(of: focused)
                    ?? stringAttribute(focused, kAXDescriptionAttribute)
                    ?? stringAttribute(focused, kAXTitleAttribute)
                    ?? stringAttribute(focused, kAXRoleAttribute)
                    ?? "unnamed"
                if order.last != name {
                    order.append(name)
                }
                if requiredIdentifiers.contains(name) {
                    observed.insert(name)
                }
                if observed == requiredIdentifiers {
                    return (true, order, [])
                }
            }
            let missing = requiredIdentifiers.subtracting(observed).sorted().joined(separator: ", ")
            return (false, order, ["Keyboard focus did not reach: \(missing)."])
        } catch {
            return (
                false,
                [],
                ["Processing keyboard traversal failed: \(error.localizedDescription)"]
            )
        }
    }

    func requireIdentifiers(
        _ identifiers: Set<String>,
        timeoutSeconds: Double = 8
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            let observed = Set(snapshots(from: application).compactMap(\.identifier))
            if observed.isSuperset(of: identifiers) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        let observed = Set(snapshots(from: application).compactMap(\.identifier))
        let missing = identifiers.subtracting(observed).sorted().joined(separator: ", ")
        throw AXAutomationError.elementNotFound("accessibility identifiers: \(missing)")
    }

    func press(identifier: String, timeoutSeconds: Double = 8) async throws {
        let element = try await waitForElement(identifier: identifier, timeoutSeconds: timeoutSeconds)
        try press(element, description: identifier)
        try await Task.sleep(for: .milliseconds(120))
    }

    func press(named name: String, timeoutSeconds: Double = 5) async throws {
        let element = try await waitForElement(named: name, timeoutSeconds: timeoutSeconds)
        try press(element, description: name)
        try await Task.sleep(for: .milliseconds(120))
    }

    func pressMenuItem(identifier: String, menuName: String) async throws {
        if let element = findElement(identifier: identifier) {
            try press(element, description: identifier)
            return
        }
        try await press(named: menuName)
        let item = try await waitForElement(identifier: identifier, timeoutSeconds: 5)
        try press(item, description: identifier)
        try await Task.sleep(for: .milliseconds(120))
    }

    func pressAndCancelDialog(identifier: String, relativeTo mainWindow: AXUIElement) async throws {
        try await press(identifier: identifier)
        guard await waitForDialog(relativeTo: mainWindow, presented: true) else {
            throw AXAutomationError.actionFailed("opening the dialog from \(identifier)")
        }
        try sendKey(CGKeyCode(53))
        guard await waitForDialog(relativeTo: mainWindow, presented: false) else {
            throw AXAutomationError.actionFailed("cancelling the dialog from \(identifier)")
        }
    }

    func verifyInspectorToggle() async throws {
        guard await waitForText("Output", present: true) else {
            throw AXAutomationError.elementNotFound("the result inspector Output section")
        }
        try await press(identifier: "result.inspector")
        guard await waitForText("Output", present: false) else {
            throw AXAutomationError.actionFailed("hiding the result inspector")
        }
        try await press(identifier: "result.inspector")
        guard await waitForText("Output", present: true) else {
            throw AXAutomationError.actionFailed("restoring the result inspector")
        }
    }

    func focusViewerForKeyboardEvidence() async throws -> [String] {
        try await activate()
        try await requireIdentifiers(["result.viewer"], timeoutSeconds: 8)
        let focus = try await focusElement(
            identifier: "result.viewer",
            maximumTabs: 120,
            allowProxy: false
        )
        guard focus.found else {
            throw AXAutomationError.actionFailed(
                "reaching the native result viewer with keyboard focus"
            )
        }

        var order = focus.order
        try sendKey(CGKeyCode(48))
        try await Task.sleep(for: .milliseconds(120))
        guard let next = focusedApplicationElement(),
              stringAttribute(next, kAXIdentifierAttribute) != "result.viewer" else {
            throw AXAutomationError.actionFailed(
                "moving keyboard focus forward from the result viewer"
            )
        }
        let nextName = contextualIdentifier(of: next)
            ?? stringAttribute(next, kAXDescriptionAttribute)
            ?? stringAttribute(next, kAXTitleAttribute)
            ?? stringAttribute(next, kAXRoleAttribute)
            ?? "unnamed"
        if order.last != nextName {
            order.append(nextName)
        }

        try sendKey(CGKeyCode(48), flags: .maskShift)
        try await Task.sleep(for: .milliseconds(120))
        guard let returned = focusedApplicationElement(),
              stringAttribute(returned, kAXIdentifierAttribute) == "result.viewer" else {
            throw AXAutomationError.actionFailed(
                "returning keyboard focus to the native result viewer"
            )
        }
        if order.last != "result.viewer" {
            order.append("result.viewer")
        }
        return order
    }

    func performViewerShortcutGroup(_ group: ViewerShortcutGroup) async throws {
        let commands: [(CGKeyCode, CGEventFlags)]
        switch group {
        case .orbitPanZoom:
            var sequence = Array(repeating: (CGKeyCode(124), CGEventFlags()), count: 8)
            sequence.append(contentsOf: Array(repeating: (CGKeyCode(126), CGEventFlags()), count: 4))
            sequence.append(contentsOf: Array(repeating: (CGKeyCode(124), CGEventFlags.maskAlternate), count: 5))
            sequence.append(contentsOf: Array(repeating: (CGKeyCode(126), CGEventFlags.maskAlternate), count: 3))
            sequence.append(contentsOf: Array(repeating: (CGKeyCode(24), CGEventFlags.maskShift), count: 4))
            commands = sequence
        case .fit:
            commands = [(CGKeyCode(3), CGEventFlags())]
        case .reset:
            commands = [(CGKeyCode(15), CGEventFlags())]
        }
        for (keyCode, flags) in commands {
            try sendKey(keyCode, flags: flags)
            try await Task.sleep(for: .milliseconds(35))
        }
        _ = try await waitForMainWindow(timeoutSeconds: 2)
        try await requireIdentifiers(["result.export", "result.inspector"], timeoutSeconds: 2)
    }

    func waitForText(
        _ fragment: String,
        present: Bool,
        timeoutSeconds: Double = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            let found = snapshots(from: application).contains { node in
                [node.title, node.label, node.value, node.placeholder]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(fragment) }
            }
            if found == present {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    private func waitForElement(
        identifier: String,
        timeoutSeconds: Double
    ) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let element = findElement(identifier: identifier) {
                return element
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw AXAutomationError.elementNotFound("an element with identifier \(identifier)")
    }

    private func waitForElement(
        named name: String,
        timeoutSeconds: Double
    ) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let element = findElement(named: name) {
                return element
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw AXAutomationError.elementNotFound("an element named \(name)")
    }

    private func findElement(identifier: String) -> AXUIElement? {
        findElement(in: application) {
            stringAttribute($0, kAXIdentifierAttribute) == identifier
        }
    }

    private func findElement(named name: String) -> AXUIElement? {
        findElement(in: application) { element in
            [
                stringAttribute(element, kAXDescriptionAttribute),
                stringAttribute(element, kAXTitleAttribute),
                stringAttribute(element, kAXValueAttribute),
                stringAttribute(element, kAXHelpAttribute),
            ].compactMap { $0 }.contains(name)
        }
    }

    private func findElement(
        in root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var visited: Set<CFHashCode> = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, queue.count < 12_000 {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= 40, visited.insert(CFHash(element)).inserted else { continue }
            if predicate(element) {
                return element
            }
            for attribute in [
                kAXChildrenAttribute,
                kAXVisibleChildrenAttribute,
                kAXRowsAttribute,
                kAXWindowsAttribute,
                "AXSheets",
            ] {
                queue.append(contentsOf: elementsAttribute(element, attribute).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func press(_ element: AXUIElement, description: String) throws {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return
        }
        if let actionable = findElement(in: element, matching: {
            actionNames(of: $0).contains(kAXPressAction as String)
        }), AXUIElementPerformAction(actionable, kAXPressAction as CFString) == .success {
            return
        }
        try click(element, description: description)
    }

    private func click(_ element: AXUIElement, description: String) throws {
        guard let frame = frame(of: element), !frame.isEmpty else {
            throw AXAutomationError.actionFailed(description)
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw AXAutomationError.actionFailed(description)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func focusElement(
        identifier: String,
        maximumTabs: Int,
        allowProxy: Bool = true
    ) async throws -> (found: Bool, order: [String]) {
        var order: [String] = []
        for step in 0...maximumTabs {
            if step > 0 {
                try sendKey(CGKeyCode(48))
                try await Task.sleep(for: .milliseconds(90))
            }
            guard let focused = focusedApplicationElement() else { continue }
            let directIdentifier = stringAttribute(focused, kAXIdentifierAttribute)
            let focusedIdentifier = contextualIdentifier(of: focused)
            let focusedRole = stringAttribute(focused, kAXRoleAttribute)
            let matchesTargetProxy = allowProxy
                && (focusedRole == kAXGroupRole as String
                || focusedRole == kAXButtonRole as String)
                && findElement(identifier: identifier).flatMap { target in
                    guard let focusedFrame = frame(of: focused),
                          let targetFrame = frame(of: target) else { return false }
                    return Self.focusProxyMatchesTarget(
                        focusedFrame: focusedFrame,
                        targetFrame: targetFrame
                    )
                } == true
            let name = (matchesTargetProxy ? identifier : focusedIdentifier)
                ?? stringAttribute(focused, kAXDescriptionAttribute)
                ?? stringAttribute(focused, kAXTitleAttribute)
                ?? stringAttribute(focused, kAXRoleAttribute)
                ?? "unnamed"
            if order.last != name {
                order.append(name)
            }
            let matchesIdentifier = allowProxy
                ? focusedIdentifier == identifier
                : directIdentifier == identifier
            if matchesIdentifier || matchesTargetProxy {
                return (true, order)
            }
        }
        return (false, order)
    }

    nonisolated static func focusProxyMatchesTarget(
        focusedFrame: CGRect,
        targetFrame: CGRect,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard !focusedFrame.isEmpty, !targetFrame.isEmpty else { return false }
        return abs(focusedFrame.minX - targetFrame.minX) <= tolerance
            && abs(focusedFrame.minY - targetFrame.minY) <= tolerance
            && abs(focusedFrame.maxX - targetFrame.maxX) <= tolerance
            && abs(focusedFrame.maxY - targetFrame.maxY) <= tolerance
    }

    private func contextualIdentifier(of element: AXUIElement) -> String? {
        if let identifier = stringAttribute(element, kAXIdentifierAttribute), !identifier.isEmpty {
            return identifier
        }

        var ancestor = element
        for _ in 0..<8 {
            guard let parent = elementAttribute(ancestor, kAXParentAttribute) else { break }
            if let identifier = stringAttribute(parent, kAXIdentifierAttribute), !identifier.isEmpty {
                return identifier
            }
            let role = stringAttribute(parent, kAXRoleAttribute)
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            ancestor = parent
        }

        var identifiers: Set<String> = []
        func visit(_ candidate: AXUIElement, depth: Int) {
            guard depth <= 3, identifiers.count <= 1 else { return }
            if let identifier = stringAttribute(candidate, kAXIdentifierAttribute), !identifier.isEmpty {
                identifiers.insert(identifier)
            }
            for child in elementsAttribute(candidate, kAXChildrenAttribute) {
                visit(child, depth: depth + 1)
            }
        }
        visit(element, depth: 0)
        return identifiers.count == 1 ? identifiers.first : nil
    }

    private func focusedApplicationElement() -> AXUIElement? {
        guard let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
            ?? elementAttribute(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        var focusedPID = pid_t()
        guard AXUIElementGetPid(focused, &focusedPID) == .success,
              focusedPID == processIdentifier else { return nil }
        return focused
    }

    private func waitForDialog(
        relativeTo mainWindow: AXUIElement,
        presented: Bool,
        timeoutSeconds: Double = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if isDialogPresented(relativeTo: mainWindow) == presented {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    private func isDialogPresented(relativeTo mainWindow: AXUIElement) -> Bool {
        if !elementsAttribute(mainWindow, "AXSheets").isEmpty {
            return true
        }
        return elementsAttribute(application, kAXWindowsAttribute).contains { window in
            !CFEqual(window, mainWindow) && isUsableWindow(window)
        }
    }

    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw AXAutomationError.keyboardEventCreation
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func isUsableWindow(_ window: AXUIElement) -> Bool {
        !isMinimized(window) && frame(of: window)?.isEmpty == false
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        boolAttribute(window, kAXMinimizedAttribute) ?? false
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = valueAttribute(element, kAXPositionAttribute),
              let sizeValue = valueAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAX = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAX) == .cgPoint,
              AXValueGetType(sizeAX) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        valueAttribute(element, name) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        valueAttribute(element, name) as? Bool
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = valueAttribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let values = valueAttribute(element, name) as? [AnyObject] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    private func valueAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func windowDiagnostic() -> String {
        var main: CFTypeRef?
        let mainError = AXUIElementCopyAttributeValue(
            application,
            kAXMainWindowAttribute as CFString,
            &main
        )
        var windows: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windows
        )
        let count = (windows as? [AnyObject])?.count ?? 0
        return "main AX \(mainError.rawValue), windows AX \(windowsError.rawValue), count \(count)"
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else { return [] }
        return (names as NSArray).compactMap { $0 as? String }.sorted()
    }
}
