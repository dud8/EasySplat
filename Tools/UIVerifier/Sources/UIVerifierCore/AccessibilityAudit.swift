import CoreGraphics
import Foundation

public enum AccessibilityAudit {
    private static let actionableRoles = Set([
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXLink",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
        "AXSearchField",
        "AXTextField",
    ])

    public static func issues(
        nodes: [AccessibilityNodeSnapshot],
        windowFrame: CGRect,
        longProjectTitle: String,
        workspace: UIVerificationWorkspace = .home
    ) -> [String] {
        var issues: [String] = []
        let ordered = nodes.sorted { $0.order < $1.order }
        let byIdentifier = Dictionary(grouping: ordered.compactMap { node in
            node.identifier.map { ($0, node) }
        }, by: { $0.0 })

        for required in workspace.requiredVisibleIdentifiers {
            guard byIdentifier[required]?.count == 1,
                  let node = byIdentifier[required]?.first?.1 else {
                issues.append("Expected exactly one accessibility element with identifier \(required).")
                continue
            }
            guard let frame = node.frame,
                  !frame.isEmpty,
                  frame.intersects(windowFrame),
                  windowFrame.contains(frame) else {
                issues.append("Required accessibility element \(required) does not have a visible frame contained by the window.")
                continue
            }
        }
        issues.append(contentsOf: voiceOverOrderIssues(nodes: ordered, workspace: workspace))
        for (identifier, entries) in byIdentifier where entries.count > 1 {
            issues.append("Duplicate accessibility identifier: \(identifier).")
        }

        let expandedWindow = windowFrame.insetBy(dx: -2, dy: -2)
        for node in ordered {
            if actionableRoles.contains(node.role), node.enabled, node.displayName == nil {
                issues.append("Enabled actionable element at order \(node.order) is unnamed (\(node.role)).")
            }
            if let frame = node.frame,
               !frame.isEmpty,
               frame.intersects(windowFrame),
               !expandedWindow.contains(frame) {
                issues.append("Visible element at order \(node.order) extends outside the window.")
            }
        }

        guard workspace == .home else {
            return issues.sorted()
        }
        let longTitleNode = ordered.first { node in
            node.title?.contains(longProjectTitle) == true
                || node.label?.contains(longProjectTitle) == true
                || node.value?.contains(longProjectTitle) == true
        }
        guard let longTitleNode else {
            issues.append("Long project title is missing from the accessibility hierarchy.")
            return issues
        }
        if let frame = longTitleNode.frame, !expandedWindow.contains(frame) {
            issues.append("Long project title extends outside the window.")
        }
        return issues.sorted()
    }

    public static func voiceOverOrderIssues(
        nodes: [AccessibilityNodeSnapshot],
        workspace: UIVerificationWorkspace
    ) -> [String] {
        let orderByIdentifier = nodes.reduce(into: [String: Int]()) { result, node in
            guard let identifier = node.identifier, result[identifier] == nil else { return }
            result[identifier] = node.order
        }
        var requiredPairs: [(String, String)] = []

        if orderByIdentifier["processing.phase"] != nil,
           orderByIdentifier["processing.technicalDetails"] != nil {
            requiredPairs.append(("processing.phase", "processing.technicalDetails"))
        }
        requiredPairs.append(contentsOf: zip(
            workspace.requiredVoiceOverOrder,
            workspace.requiredVoiceOverOrder.dropFirst()
        ))

        return requiredPairs.compactMap { first, second in
            guard let firstOrder = orderByIdentifier[first],
                  let secondOrder = orderByIdentifier[second],
                  firstOrder >= secondOrder else {
                return nil
            }
            return "VoiceOver order must place \(first) before \(second)."
        }
    }
}
