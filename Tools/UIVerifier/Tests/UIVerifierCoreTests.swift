import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatUIVerifierCore

private func accessibilityNode(
    order: Int = 0,
    role: String,
    subrole: String? = nil,
    title: String? = nil,
    value: String? = nil,
    identifier: String? = nil,
    actions: [String] = []
) -> AccessibilityNodeSnapshot {
    AccessibilityNodeSnapshot(
        order: order,
        role: role,
        subrole: subrole,
        title: title,
        label: nil,
        value: value,
        placeholder: nil,
        identifier: identifier,
        enabled: true,
        frame: nil,
        actions: actions
    )
}

final class UIVerifierCoreTests: XCTestCase {
    @MainActor
    func testActivationReturnsWithoutRequestsWhenTargetIsAlreadyFrontmost() async throws {
        let targetPID = pid_t(42)
        var appKitRequests = 0
        var accessibilityRequests = 0
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { targetPID },
                activateWithAppKit: {
                    appKitRequests += 1
                    return true
                },
                activateWithAccessibility: {
                    accessibilityRequests += 1
                    return .success
                }
            )
        )

        try await controller.activate(timeoutSeconds: 0)

        XCTAssertEqual(appKitRequests, 0)
        XCTAssertEqual(accessibilityRequests, 0)
    }

    @MainActor
    func testActivationStopsAfterAppKitMakesExactTargetFrontmost() async throws {
        let targetPID = pid_t(42)
        var frontmostPID: pid_t? = 7
        var appKitRequests = 0
        var accessibilityRequests = 0
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { frontmostPID },
                activateWithAppKit: {
                    appKitRequests += 1
                    frontmostPID = targetPID
                    return true
                },
                activateWithAccessibility: {
                    accessibilityRequests += 1
                    return .success
                }
            )
        )

        try await controller.activate(timeoutSeconds: 0)

        XCTAssertEqual(appKitRequests, 1)
        XCTAssertEqual(accessibilityRequests, 0)
    }

    @MainActor
    func testActivationUsesAccessibilityWhenAppKitRequestIsDenied() async throws {
        let targetPID = pid_t(42)
        var frontmostPID: pid_t? = 7
        var accessibilityRequests = 0
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { frontmostPID },
                activateWithAppKit: { false },
                activateWithAccessibility: {
                    accessibilityRequests += 1
                    frontmostPID = targetPID
                    return .success
                }
            )
        )

        try await controller.activate(timeoutSeconds: 0)

        XCTAssertEqual(accessibilityRequests, 1)
    }

    @MainActor
    func testActivationReportsAccessibilityRejectionWhenTargetStaysInBackground() async {
        let targetPID = pid_t(42)
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { 7 },
                activateWithAppKit: { false },
                activateWithAccessibility: { .apiDisabled }
            )
        )

        do {
            try await controller.activate(timeoutSeconds: 0)
            XCTFail("Expected activation to fail")
        } catch AXAutomationError.cannotActivate(let accessibilityError) {
            XCTAssertEqual(accessibilityError, .apiDisabled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testActivationRejectsWrongFrontmostProcessAfterSuccessfulAccessibilityRequest() async {
        let targetPID = pid_t(42)
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { 99 },
                activateWithAppKit: { false },
                activateWithAccessibility: { .success }
            )
        )

        do {
            try await controller.activate(timeoutSeconds: 0)
            XCTFail("Expected activation to fail")
        } catch AXAutomationError.cannotActivate(let accessibilityError) {
            XCTAssertNil(accessibilityError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testActivationRejectsMissingFrontmostProcessAfterSuccessfulAccessibilityRequest() async {
        let targetPID = pid_t(42)
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { nil },
                activateWithAppKit: { false },
                activateWithAccessibility: { .success }
            )
        )

        do {
            try await controller.activate(timeoutSeconds: 0)
            XCTFail("Expected activation to fail")
        } catch AXAutomationError.cannotActivate(let accessibilityError) {
            XCTAssertNil(accessibilityError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testActivationRetriesRequestsUntilTheExactTargetIsFrontmost() async throws {
        let targetPID = pid_t(42)
        var frontmostPID: pid_t? = 7
        var appKitRequests = 0
        var accessibilityRequests = 0
        let controller = AXApplicationController(
            processIdentifier: targetPID,
            activationRequests: .init(
                frontmostProcessIdentifier: { frontmostPID },
                activateWithAppKit: {
                    appKitRequests += 1
                    return false
                },
                activateWithAccessibility: {
                    accessibilityRequests += 1
                    if accessibilityRequests == 2 {
                        frontmostPID = targetPID
                    }
                    return .success
                }
            )
        )

        try await controller.activate(timeoutSeconds: 0.25)

        XCTAssertGreaterThanOrEqual(appKitRequests, 2)
        XCTAssertEqual(accessibilityRequests, 2)
    }

    @MainActor
    func testTransientAccessibilityOperationRetriesCannotComplete() async throws {
        var attempts = 0

        let result = try await AXApplicationController.retryTransientOperation(
            timeoutSeconds: 0.25,
            retryDelay: .milliseconds(1)
        ) {
            attempts += 1
            return attempts == 1 ? .cannotComplete : .success
        }

        XCTAssertEqual(result, .success)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testTransientAccessibilityOperationDoesNotRetryPermanentFailure() async throws {
        var attempts = 0

        let result = try await AXApplicationController.retryTransientOperation(
            timeoutSeconds: 0.25,
            retryDelay: .milliseconds(1)
        ) {
            attempts += 1
            return .illegalArgument
        }

        XCTAssertEqual(result, .illegalArgument)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testTransientAccessibilityOperationPropagatesCancellation() async {
        let task = Task { @MainActor () throws -> AXError in
            try await AXApplicationController.retryTransientOperation(
                timeoutSeconds: 0.05,
                retryDelay: .seconds(1)
            ) {
                .cannotComplete
            }
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to stop accessibility retries")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKeyboardFocusProxyMustCoverTheTargetControl() {
        let target = CGRect(x: 120, y: 80, width: 580, height: 180)

        XCTAssertTrue(AXApplicationController.focusProxyMatchesTarget(
            focusedFrame: target.insetBy(dx: -1, dy: -1),
            targetFrame: target
        ))
        XCTAssertFalse(AXApplicationController.focusProxyMatchesTarget(
            focusedFrame: CGRect(x: 120, y: 80, width: 580, height: 40),
            targetFrame: target
        ))
        XCTAssertFalse(AXApplicationController.focusProxyMatchesTarget(
            focusedFrame: target.offsetBy(dx: 12, dy: 0),
            targetFrame: target
        ))
    }

    func testPressActionRequiresAnAdvertisedAXPressCapability() {
        XCTAssertTrue(AXApplicationController.supportsPressAction(["AXPress", "AXShowMenu"]))
        XCTAssertFalse(AXApplicationController.supportsPressAction(["AXShowMenu"]))
        XCTAssertFalse(AXApplicationController.supportsPressAction([]))
    }

    func testReverseFocusTraversalUsesTheNativeTextControlShortcut() {
        XCTAssertEqual(
            AXApplicationController.reverseTraversalFlags(forRole: "AXTextArea"),
            [.maskControl, .maskShift]
        )
        XCTAssertEqual(
            AXApplicationController.reverseTraversalFlags(forRole: "AXTextField"),
            [.maskControl, .maskShift]
        )
        XCTAssertEqual(
            AXApplicationController.reverseTraversalFlags(forRole: "AXButton"),
            .maskShift
        )
    }

    func testNativeConfirmationRequiresARealPresentationWithExactActions() {
        let confirmation = [
            accessibilityNode(role: "AXSheet"),
            accessibilityNode(order: 1, role: "AXStaticText", value: "Stop this project?"),
            accessibilityNode(
                order: 2,
                role: "AXButton",
                title: "Stop and Keep Project",
                actions: ["AXPress"]
            ),
            accessibilityNode(
                order: 3,
                role: "AXButton",
                title: "Cancel",
                actions: ["AXPress"]
            ),
        ]

        XCTAssertTrue(AXApplicationController.isNativeConfirmationPresentation(
            confirmation,
            title: "Stop this project?",
            actionTitle: "Stop and Keep Project"
        ))

        var ordinaryWindow = confirmation
        ordinaryWindow[0] = accessibilityNode(role: "AXWindow")
        XCTAssertFalse(AXApplicationController.isNativeConfirmationPresentation(
            ordinaryWindow,
            title: "Stop this project?",
            actionTitle: "Stop and Keep Project"
        ))

        var popover = confirmation
        popover[0] = accessibilityNode(role: "AXPopover")
        XCTAssertTrue(AXApplicationController.isNativeConfirmationPresentation(
            popover,
            title: "Stop this project?",
            actionTitle: "Stop and Keep Project"
        ))

        var dialogWindow = confirmation
        dialogWindow[0] = accessibilityNode(role: "AXWindow", subrole: "AXDialog")
        XCTAssertTrue(AXApplicationController.isNativeConfirmationPresentation(
            dialogWindow,
            title: "Stop this project?",
            actionTitle: "Stop and Keep Project"
        ))

        XCTAssertFalse(AXApplicationController.isNativeConfirmationPresentation(
            confirmation,
            title: "Stop training?",
            actionTitle: "Stop and Keep Project"
        ))
        XCTAssertFalse(AXApplicationController.isNativeConfirmationPresentation(
            confirmation,
            title: "Stop this project?",
            actionTitle: "Stop Setup"
        ))
        XCTAssertFalse(AXApplicationController.isNativeConfirmationPresentation(
            confirmation,
            title: "Stop this project?",
            actionTitle: "Stop and Keep Project",
            presentationVisible: false
        ))

        XCTAssertFalse(AXApplicationController.isNativeConfirmationPresentation(
            Array(confirmation.dropLast()),
            title: "Stop this project?",
            actionTitle: "Stop and Keep Project"
        ))
    }

    func testNativeSavePanelRequiresExactPanelIdentityAndCancelAction() {
        let savePanel = [
            accessibilityNode(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                title: "Export Splat",
                identifier: "save-panel"
            ),
            accessibilityNode(
                order: 1,
                role: "AXButton",
                title: "Cancel",
                identifier: "CancelButton",
                actions: ["AXPress"]
            ),
        ]

        XCTAssertTrue(AXApplicationController.isNativeSavePanelPresentation(
            savePanel,
            title: "Export Splat"
        ))

        var wrongIdentifier = savePanel
        wrongIdentifier[0] = accessibilityNode(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Export Splat"
        )
        XCTAssertFalse(AXApplicationController.isNativeSavePanelPresentation(
            wrongIdentifier,
            title: "Export Splat"
        ))

        var wrongTitle = savePanel
        wrongTitle[0] = accessibilityNode(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Save Diagnostics",
            identifier: "save-panel"
        )
        XCTAssertFalse(AXApplicationController.isNativeSavePanelPresentation(
            wrongTitle,
            title: "Export Splat"
        ))

        var ordinaryWindow = savePanel
        ordinaryWindow[0] = accessibilityNode(
            role: "AXWindow",
            subrole: "AXDialog",
            title: "Export Splat",
            identifier: "save-panel"
        )
        XCTAssertFalse(AXApplicationController.isNativeSavePanelPresentation(
            ordinaryWindow,
            title: "Export Splat"
        ))

        XCTAssertFalse(AXApplicationController.isNativeSavePanelPresentation(
            Array(savePanel.dropLast()),
            title: "Export Splat"
        ))
        XCTAssertFalse(AXApplicationController.isNativeSavePanelPresentation(
            savePanel,
            title: "Export Splat",
            presentationVisible: false
        ))
    }

    func testRunArgumentsRequirePackagedAppScenarioAndOutput() throws {
        let arguments = try UIVerifierArguments.parse([
            "run",
            "--app", "/tmp/EasySplat.app",
            "--scenario", "reduce-motion",
            "--output", "/tmp/result.json",
            "--screenshots", "/tmp/screenshots",
        ])

        XCTAssertEqual(arguments.command, .run)
        XCTAssertEqual(arguments.appURL?.path, "/tmp/EasySplat.app")
        XCTAssertEqual(arguments.scenario, .reduceMotion)
        XCTAssertEqual(arguments.outputURL.path, "/tmp/result.json")
        XCTAssertEqual(arguments.screenshotDirectory?.path, "/tmp/screenshots")
        XCTAssertThrowsError(try UIVerifierArguments.parse(["run", "--app", "/tmp/EasySplat.app"]))
        XCTAssertThrowsError(try UIVerifierArguments.parse([
            "run", "--app", "/tmp/EasySplat", "--scenario", "light",
            "--output", "/tmp/result.json", "--screenshots", "/tmp/screenshots",
        ]))
        XCTAssertThrowsError(try UIVerifierArguments.parse([
            "run", "--app", "EasySplat.app", "--scenario", "light",
            "--output", "/tmp/result.json", "--screenshots", "/tmp/screenshots",
        ]))
        XCTAssertThrowsError(try UIVerifierArguments.parse([
            "summarize", "--result", "result.json", "--output", "/tmp/suite.json",
        ]))
    }

    func testScenarioContractsAreExplicit() {
        XCTAssertTrue(UIRunnerEnvironment(
            architecture: "arm64",
            macOSVersion: "15.6",
            xcodeVersion: "16.4",
            isolatedAccount: true
        ).isReleaseLane)
        XCTAssertFalse(UIRunnerEnvironment(
            architecture: "arm64",
            macOSVersion: "16.0",
            xcodeVersion: "16.4",
            isolatedAccount: true
        ).isReleaseLane)
        XCTAssertEqual(UIVerificationScenario.light.expectedAppearance, .light)
        XCTAssertFalse(UIVerificationScenario.light.expectsReduceMotion)
        XCTAssertFalse(UIVerificationScenario.light.expectsIncreaseContrast)
        XCTAssertEqual(UIVerificationScenario.dark.expectedAppearance, .dark)
        XCTAssertTrue(UIVerificationScenario.reduceMotion.expectsReduceMotion)
        XCTAssertFalse(UIVerificationScenario.reduceMotion.expectsIncreaseContrast)
        XCTAssertFalse(UIVerificationScenario.increaseContrast.expectsReduceMotion)
        XCTAssertTrue(UIVerificationScenario.increaseContrast.expectsIncreaseContrast)
        XCTAssertFalse(UIVerificationScenario.increaseContrast.expectsDifferentiateWithoutColor)
        XCTAssertFalse(UIVerificationScenario.differentiateWithoutColor.expectsReduceMotion)
        XCTAssertFalse(UIVerificationScenario.differentiateWithoutColor.expectsIncreaseContrast)
        XCTAssertTrue(UIVerificationScenario.differentiateWithoutColor.expectsDifferentiateWithoutColor)
        XCTAssertEqual(
            VerificationViewport.required,
            [
                .init(width: 920, height: 640),
                .init(width: 1_100, height: 760),
                .init(width: 1_440, height: 900),
            ]
        )
    }

    func testProcessingWorkspaceContractCoversVisibleStateAndVoiceOverOrder() throws {
        XCTAssertEqual(
            Set(UIVerificationWorkspace.allCases.map(\.rawValue)),
            Set(["home", "processing", "result", "failure"])
        )

        let processing = try XCTUnwrap(UIVerificationWorkspace(rawValue: "processing"))
        XCTAssertEqual(
            processing.requiredVisibleIdentifiers,
            Set([
                "processing.phase",
                "processing.progress",
                "processing.timing",
                "processing.stop",
                "processing.technicalDetails",
            ])
        )
        XCTAssertEqual(
            processing.requiredVoiceOverOrder,
            [
                "processing.phase",
                "processing.progress",
                "processing.timing",
                "processing.technicalDetails",
            ]
        )

        let result = try XCTUnwrap(UIVerificationWorkspace(rawValue: "result"))
        XCTAssertEqual(
            result.requiredVisibleIdentifiers,
            Set(["result.export", "result.share", "result.inspector", "result.viewer"])
        )
        XCTAssertEqual(
            result.requiredVoiceOverOrder,
            ["result.export", "result.share", "result.inspector"]
        )
    }

    func testAccessibilityAuditRejectsMissingUnnamedAndOutOfBoundsControls() {
        let window = CGRect(x: 0, y: 0, width: 1_100, height: 760)
        let longTitle = String(repeating: "Long Project Name ", count: 8)
        let valid = [
            AccessibilityNodeSnapshot(
                order: 0,
                role: "AXButton",
                subrole: nil,
                title: "New Splat",
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 20, width: 180, height: 40),
                actions: ["AXPress"]
            ),
            AccessibilityNodeSnapshot(
                order: 1,
                role: "AXStaticText",
                subrole: nil,
                title: longTitle,
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 80, width: 220, height: 24),
                actions: []
            ),
            AccessibilityNodeSnapshot(
                order: 2,
                role: "AXButton",
                subrole: nil,
                title: "Choose Input…",
                label: "Choose Input…",
                value: nil,
                placeholder: nil,
                identifier: "home.chooseInput",
                enabled: true,
                frame: CGRect(x: 300, y: 100, width: 500, height: 260),
                actions: ["AXPress"]
            ),
            AccessibilityNodeSnapshot(
                order: 3,
                role: "AXButton",
                subrole: nil,
                title: "Create Splat",
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: "home.start",
                enabled: false,
                frame: CGRect(x: 650, y: 650, width: 140, height: 40),
                actions: ["AXPress"]
            ),
        ]

        XCTAssertTrue(
            AccessibilityAudit.issues(nodes: valid, windowFrame: window, longProjectTitle: longTitle).isEmpty
        )

        var invalid = valid.filter { $0.identifier != "home.start" }
        invalid.append(.init(
            order: 4,
            role: "AXButton",
            subrole: nil,
            title: nil,
            label: nil,
            value: nil,
            placeholder: nil,
            identifier: nil,
            enabled: true,
            frame: CGRect(x: 1_090, y: 700, width: 100, height: 40),
            actions: ["AXPress"]
        ))
        let issues = AccessibilityAudit.issues(nodes: invalid, windowFrame: window, longProjectTitle: longTitle)
        XCTAssertTrue(issues.contains(where: { $0.contains("home.start") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("unnamed") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("outside") }))
    }

    func testAccessibilityAuditFindsLongTitleInsideCombinedRowLabel() {
        let longTitle = String(repeating: "Riverside Property ", count: 6)
        let nodes = [
            AccessibilityNodeSnapshot(
                order: 0,
                role: "AXStaticText",
                subrole: nil,
                title: nil,
                label: "\(longTitle), Ready, Today",
                value: nil,
                placeholder: nil,
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 40, width: 300, height: 24),
                actions: []
            ),
            AccessibilityNodeSnapshot(
                order: 1,
                role: "AXButton",
                subrole: nil,
                title: "Choose Input…",
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: "home.chooseInput",
                enabled: true,
                frame: CGRect(x: 350, y: 80, width: 500, height: 180),
                actions: ["AXPress"]
            ),
            AccessibilityNodeSnapshot(
                order: 2,
                role: "AXButton",
                subrole: nil,
                title: "Create Splat",
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: "home.start",
                enabled: false,
                frame: CGRect(x: 700, y: 600, width: 140, height: 36),
                actions: ["AXPress"]
            ),
        ]

        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: nodes,
            windowFrame: CGRect(x: 0, y: 0, width: 920, height: 640),
            longProjectTitle: longTitle
        ).isEmpty)
    }

    func testAccessibilityAuditUsesAXValuePlaceholderAndNativeSubrole() {
        let longTitle = String(repeating: "Riverside Property ", count: 6)
        let nodes = [
            AccessibilityNodeSnapshot(
                order: 0,
                role: "AXStaticText",
                subrole: nil,
                title: nil,
                label: nil,
                value: longTitle,
                placeholder: nil,
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 40, width: 300, height: 24),
                actions: []
            ),
            AccessibilityNodeSnapshot(
                order: 1,
                role: "AXTextField",
                subrole: nil,
                title: nil,
                label: nil,
                value: nil,
                placeholder: "Search Projects",
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 80, width: 240, height: 28),
                actions: []
            ),
            AccessibilityNodeSnapshot(
                order: 2,
                role: "AXButton",
                subrole: "AXCloseButton",
                title: nil,
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 12, width: 14, height: 14),
                actions: ["AXPress"]
            ),
            AccessibilityNodeSnapshot(
                order: 3,
                role: "AXButton",
                subrole: nil,
                title: "Choose Input…",
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: "home.chooseInput",
                enabled: true,
                frame: CGRect(x: 300, y: 100, width: 500, height: 180),
                actions: ["AXPress"]
            ),
            AccessibilityNodeSnapshot(
                order: 4,
                role: "AXButton",
                subrole: nil,
                title: "Create Splat",
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: "home.start",
                enabled: false,
                frame: CGRect(x: 700, y: 600, width: 140, height: 36),
                actions: ["AXPress"]
            ),
        ]

        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: nodes,
            windowFrame: CGRect(x: 0, y: 0, width: 920, height: 640),
            longProjectTitle: longTitle
        ).isEmpty)
    }

    func testAccessibilityAuditUsesWorkspaceSpecificControlContracts() {
        let identifiers = ["result.export", "result.share", "result.inspector", "result.viewer"]
        let resultNodes = identifiers.enumerated().map { offset, identifier in
            AccessibilityNodeSnapshot(
                order: offset,
                role: identifier == "result.viewer" ? "AXGroup" : "AXButton",
                subrole: nil,
                title: identifier == "result.viewer" ? nil : identifier,
                label: identifier == "result.viewer" ? "Interactive 3D splat viewer" : nil,
                value: nil,
                placeholder: nil,
                identifier: identifier,
                enabled: true,
                frame: CGRect(x: 20 + CGFloat(offset * 100), y: 20, width: 90, height: 32),
                actions: identifier == "result.viewer" ? [] : ["AXPress"]
            )
        }
        let window = CGRect(x: 0, y: 0, width: 920, height: 640)

        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: resultNodes,
            windowFrame: window,
            longProjectTitle: "not required outside Home",
            workspace: .result
        ).isEmpty)
        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: Array(resultNodes.dropLast()),
            windowFrame: window,
            longProjectTitle: "not required outside Home",
            workspace: .result
        ).contains(where: { $0.contains("result.viewer") }))
    }

    func testAccessibilityAuditRequiresTheNamedNativeViewerGroup() {
        let window = CGRect(x: 0, y: 0, width: 920, height: 640)
        let identifiers = ["result.export", "result.share", "result.inspector", "result.viewer"]
        let valid = identifiers.enumerated().map { offset, identifier in
            AccessibilityNodeSnapshot(
                order: offset,
                role: identifier == "result.viewer" ? "AXGroup" : "AXButton",
                subrole: nil,
                title: identifier == "result.viewer" ? nil : identifier,
                label: identifier == "result.viewer" ? "Interactive 3D splat viewer" : nil,
                value: nil,
                placeholder: nil,
                identifier: identifier,
                enabled: true,
                frame: CGRect(x: 20 + CGFloat(offset * 100), y: 20, width: 90, height: 32),
                actions: identifier == "result.viewer" ? [] : ["AXPress"]
            )
        }

        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: valid,
            windowFrame: window,
            longProjectTitle: "not required outside Home",
            workspace: .result
        ).isEmpty)

        var wrongRole = valid
        wrongRole[3].role = "AXButton"
        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: wrongRole,
            windowFrame: window,
            longProjectTitle: "not required outside Home",
            workspace: .result
        ).contains(where: { $0.contains("AXGroup") }))

        var wrongLabel = valid
        wrongLabel[3].label = "Viewer"
        XCTAssertTrue(AccessibilityAudit.issues(
            nodes: wrongLabel,
            windowFrame: window,
            longProjectTitle: "not required outside Home",
            workspace: .result
        ).contains(where: { $0.contains("Interactive 3D splat viewer") }))
    }

    func testAccessibilityAuditEnforcesProcessingFailureAndResultVoiceOverOrder() {
        func nodes(_ identifiers: [String]) -> [AccessibilityNodeSnapshot] {
            identifiers.enumerated().map { offset, identifier in
                AccessibilityNodeSnapshot(
                    order: offset,
                    role: "AXButton",
                    subrole: nil,
                    title: identifier,
                    label: nil,
                    value: nil,
                    placeholder: nil,
                    identifier: identifier,
                    enabled: true,
                    frame: CGRect(x: 20 + CGFloat(offset * 80), y: 20, width: 70, height: 32),
                    actions: ["AXPress"]
                )
            }
        }

        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes(["processing.phase", "processing.technicalDetails"]),
            workspace: .failure
        ).isEmpty)
        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes(["processing.technicalDetails", "processing.phase"]),
            workspace: .failure
        ).contains(where: { $0.contains("processing.phase before processing.technicalDetails") }))

        let processingOrder = [
            "processing.phase",
            "processing.progress",
            "processing.timing",
            "processing.technicalDetails",
            "processing.stop",
        ]
        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes(processingOrder),
            workspace: .processing
        ).isEmpty)
        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes([
                "processing.phase",
                "processing.timing",
                "processing.progress",
                "processing.technicalDetails",
                "processing.stop",
            ]),
            workspace: .processing
        ).contains(where: { $0.contains("processing.progress before processing.timing") }))

        let failureOrder = [
            "processing.phase",
            "processing.tryAgain",
            "processing.backToProjects",
            "processing.failureMore",
            "processing.technicalDetails",
        ]
        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes(failureOrder),
            workspace: .failure
        ).isEmpty)
        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes([
                "processing.phase",
                "processing.backToProjects",
                "processing.tryAgain",
                "processing.failureMore",
                "processing.technicalDetails",
            ]),
            workspace: .failure
        ).contains(where: { $0.contains("processing.tryAgain before processing.backToProjects") }))

        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes(["result.viewer", "result.export", "result.share", "result.inspector"]),
            workspace: .result
        ).isEmpty)
        XCTAssertTrue(AccessibilityAudit.voiceOverOrderIssues(
            nodes: nodes(["result.viewer", "result.share", "result.export", "result.inspector"]),
            workspace: .result
        ).contains(where: { $0.contains("result.export before result.share") }))
    }

    func testAccessibilityAuditRejectsRequiredControlsWithoutVisibleContainedFrames() {
        let window = CGRect(x: 0, y: 0, width: 920, height: 640)
        let identifiers = ["result.export", "result.share", "result.inspector", "result.viewer"]
        let valid = identifiers.enumerated().map { offset, identifier in
            AccessibilityNodeSnapshot(
                order: offset,
                role: identifier == "result.viewer" ? "AXGroup" : "AXButton",
                subrole: nil,
                title: identifier == "result.viewer" ? nil : identifier,
                label: identifier == "result.viewer" ? "Interactive 3D splat viewer" : nil,
                value: nil,
                placeholder: nil,
                identifier: identifier,
                enabled: true,
                frame: CGRect(x: 20 + CGFloat(offset * 100), y: 20, width: 90, height: 32),
                actions: identifier == "result.viewer" ? [] : ["AXPress"]
            )
        }

        for invalidFrame in [
            nil,
            CGRect.zero,
            CGRect(x: 1_000, y: 20, width: 90, height: 32),
            CGRect(x: 880, y: 20, width: 90, height: 32),
        ] as [CGRect?] {
            var nodes = valid
            nodes[0].frame = invalidFrame
            let issues = AccessibilityAudit.issues(
                nodes: nodes,
                windowFrame: window,
                longProjectTitle: "not required outside Home",
                workspace: .result
            )
            XCTAssertTrue(issues.contains(where: { $0.contains("result.export") }))
        }
    }

    func testSuiteValidatorRequiresEveryScenarioViewportAndVisibleAppearanceDifference() {
        let passing = UIHarnessSuiteResult.fixture(lightLuminance: 0.82, darkLuminance: 0.18)
        XCTAssertNoThrow(try UIHarnessSuiteValidator.validate(passing.scenarios))

        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(
            passing.scenarios.filter { $0.scenario != .increaseContrast }
        ))

        var missingViewport = passing.scenarios
        missingViewport[0].viewports.removeLast()
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingViewport))

        let indistinguishable = UIHarnessSuiteResult.fixture(lightLuminance: 0.51, darkLuminance: 0.49)
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(indistinguishable.scenarios))

        var missingKeyboardFocus = passing.scenarios
        missingKeyboardFocus[0].focusOrder = []
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingKeyboardFocus))

        var mixedApps = passing.scenarios
        mixedApps[0].app?.executableSHA256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(mixedApps))

        var uppercaseDigest = passing.scenarios
        uppercaseDigest[0].app?.executableSHA256 = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(uppercaseDigest))

        var missingResultControl = passing.scenarios
        missingResultControl[0].observedControlIdentifiers.removeAll { $0 == "result.export" }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingResultControl))

        var missingInteraction = passing.scenarios
        missingInteraction[0].passedInteractions.removeAll { $0 == .cancelResultExport }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingInteraction))

        var missingViewerFocus = passing.scenarios
        missingViewerFocus[0].focusOrder.removeAll { $0 == "result.viewer" }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingViewerFocus))

        var missingViewerTraversal = passing.scenarios
        missingViewerTraversal[0].passedInteractions.removeAll { $0 == .verifyViewerKeyboardTraversal }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingViewerTraversal))

        var missingViewerEvidence = passing.scenarios
        missingViewerEvidence[0].viewerShortcutEvidence = nil
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingViewerEvidence))
    }

    func testSuiteValidatorRejectsHomeOnlyWorkspaceEvidence() {
        var homeOnly = UIHarnessSuiteResult.fixture(lightLuminance: 0.82, darkLuminance: 0.18)
        for index in homeOnly.scenarios.indices {
            homeOnly.scenarios[index].viewports.removeAll { $0.workspace != .home }
        }

        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(homeOnly.scenarios))
    }

    func testSuiteValidatorRejectsOneMissingOrDuplicateWorkspaceState() {
        let passing = UIHarnessSuiteResult.fixture(lightLuminance: 0.82, darkLuminance: 0.18)

        var missingFailure = passing.scenarios
        missingFailure[0].viewports.removeAll { $0.workspace == .failure }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingFailure))

        var duplicateResult = passing.scenarios
        let duplicate = try! XCTUnwrap(
            duplicateResult[0].viewports.first { $0.workspace == .result }
        )
        duplicateResult[0].viewports.append(duplicate)
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(duplicateResult))
    }

    func testSuiteValidatorRequiresProcessingControlsAndKeyboardEvidence() {
        let passing = UIHarnessSuiteResult.fixture(lightLuminance: 0.82, darkLuminance: 0.18)
        XCTAssertNoThrow(try UIHarnessSuiteValidator.validate(passing.scenarios))

        var missingProcessing = passing.scenarios
        missingProcessing[0].viewports.removeAll { $0.workspace == .processing }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingProcessing))

        var missingStop = passing.scenarios
        missingStop[0].observedControlIdentifiers.removeAll { $0 == "processing.stop" }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingStop))

        var missingKeyboardFocus = passing.scenarios
        missingKeyboardFocus[0].focusOrder.removeAll {
            $0 == "processing.stop" || $0 == "processing.technicalDetails"
        }
        XCTAssertThrowsError(try UIHarnessSuiteValidator.validate(missingKeyboardFocus))
    }

    func testProjectRowIdentifierUsesCanonicalPathAndStableLowercaseDigest() {
        let direct = URL(
            fileURLWithPath: "/Users/example/EasySplat Projects/Ready.easysplatproj",
            isDirectory: true
        )
        let lexicalAlias = URL(
            fileURLWithPath: "/Users/example/EasySplat Projects/Folder/../Ready.easysplatproj",
            isDirectory: true
        )

        XCTAssertEqual(
            ProjectRowAccessibilityIdentifier.canonicalPath(for: lexicalAlias),
            "/Users/example/EasySplat Projects/Ready.easysplatproj"
        )
        XCTAssertEqual(
            ProjectRowAccessibilityIdentifier.make(for: direct),
            "project.row.f702a96ca017092d"
        )
        XCTAssertEqual(
            ProjectRowAccessibilityIdentifier.make(for: lexicalAlias),
            ProjectRowAccessibilityIdentifier.make(for: direct)
        )
        XCTAssertEqual(
            ProjectRowAccessibilityIdentifier.action(for: lexicalAlias),
            "project.action.f702a96ca017092d"
        )
        XCTAssertNotEqual(
            ProjectRowAccessibilityIdentifier.make(for: direct),
            ProjectRowAccessibilityIdentifier.make(for: direct.deletingLastPathComponent())
        )
    }

    func testArtifactValidatorRequiresRegularLabeledFilesAndMatchingAccessibilityContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try materializedArtifactFixture(in: root)
        XCTAssertNoThrow(try UIHarnessArtifactValidator.validate(suite.scenarios))

        var wrongNodeCount = suite
        wrongNodeCount.scenarios[0].viewports[0].accessibilityNodeCount += 1
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(wrongNodeCount.scenarios))

        var mislabeled = suite
        let original = URL(fileURLWithPath: mislabeled.scenarios[0].viewports[0].screenshotPath)
        let renamed = original.deletingLastPathComponent().appendingPathComponent("wrong-workspace.png")
        try FileManager.default.copyItem(at: original, to: renamed)
        mislabeled.scenarios[0].viewports[0].screenshotPath = renamed.path
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(mislabeled.scenarios))

        var missingProjectRows = suite
        let snapshotURL = URL(
            fileURLWithPath: missingProjectRows.scenarios[0].viewports[0].accessibilitySnapshotPath
        )
        let workspace = missingProjectRows.scenarios[0].viewports[0].workspace
        let nodesWithoutRows = artifactNodes(
            for: workspace,
            viewport: missingProjectRows.scenarios[0].viewports[0].viewport
        ).filter {
            $0.identifier?.hasPrefix("project.row.") != true
        }
        try JSONDocument.write(nodesWithoutRows, to: snapshotURL)
        missingProjectRows.scenarios[0].viewports[0].accessibilityNodeCount = nodesWithoutRows.count
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(missingProjectRows.scenarios))
        try JSONDocument.write(
            artifactNodes(for: workspace, viewport: suite.scenarios[0].viewports[0].viewport),
            to: snapshotURL
        )

        let corruptScreenshot = suite
        let corruptURL = URL(fileURLWithPath: corruptScreenshot.scenarios[0].viewports[0].screenshotPath)
        let corruptData = Data(
            repeating: 1,
            count: Int(corruptScreenshot.scenarios[0].viewports[0].screenshotSizeBytes)
        )
        try corruptData.write(to: corruptURL)
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(corruptScreenshot.scenarios))
    }

    func testArtifactValidatorRejectsWrongPixelDimensionsAndReusedWorkspaceContent() throws {
        let dimensionsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dimensionsRoot) }
        var wrongDimensions = try materializedArtifactFixture(in: dimensionsRoot)
        let wrongTarget = wrongDimensions.scenarios[0].viewports[0]
        let wrongURL = URL(fileURLWithPath: wrongTarget.screenshotPath)
        let wrongSize = try writeSolidPNG(width: 1, height: 1, color: (20, 40, 60), to: wrongURL)
        wrongDimensions.scenarios[0].viewports[0].screenshotSizeBytes = wrongSize
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(wrongDimensions.scenarios))

        let reusedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: reusedRoot) }
        var reused = try materializedArtifactFixture(in: reusedRoot)
        let scenario = reused.scenarios[0]
        let viewport = VerificationViewport(width: 920, height: 640)
        let homeIndex = try XCTUnwrap(scenario.viewports.firstIndex {
            $0.workspace == .home && $0.viewport == viewport
        })
        let resultIndex = try XCTUnwrap(scenario.viewports.firstIndex {
            $0.workspace == .result && $0.viewport == viewport
        })
        let homeURL = URL(fileURLWithPath: scenario.viewports[homeIndex].screenshotPath)
        let resultURL = URL(fileURLWithPath: scenario.viewports[resultIndex].screenshotPath)
        let reusedData = try Data(contentsOf: homeURL)
        try reusedData.write(to: resultURL, options: [.atomic])
        reused.scenarios[0].viewports[resultIndex].screenshotSizeBytes = Int64(reusedData.count)
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(reused.scenarios))
    }

    func testArtifactValidatorRejectsRequiredControlWithoutStoredVisibleFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try materializedArtifactFixture(in: root)
        let viewport = suite.scenarios[0].viewports[0]
        let snapshotURL = URL(fileURLWithPath: viewport.accessibilitySnapshotPath)
        var nodes = try JSONDocument.read([AccessibilityNodeSnapshot].self, from: snapshotURL)
        let requiredIndex = try XCTUnwrap(nodes.firstIndex { $0.identifier == "home.chooseInput" })
        nodes[requiredIndex].frame = nil
        try JSONDocument.write(nodes, to: snapshotURL)

        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(suite.scenarios))
    }

    func testArtifactValidatorRejectsUnchangedViewerMutationOrFitAndDistantReset() throws {
        let unchangedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: unchangedRoot) }
        var unchanged = try materializedArtifactFixture(in: unchangedRoot)
        let originalEvidence = try XCTUnwrap(unchanged.scenarios[0].viewerShortcutEvidence)
        var unchangedEvidence = originalEvidence
        let baselineURL = URL(fileURLWithPath: originalEvidence.baselineScreenshotPath)
        let mutationIndex = try XCTUnwrap(originalEvidence.groups.firstIndex { $0.group == .orbitPanZoom })
        let mutationURL = URL(fileURLWithPath: originalEvidence.groups[mutationIndex].screenshotPath)
        let baselineData = try Data(contentsOf: baselineURL)
        let mutationData = try Data(contentsOf: mutationURL)
        try baselineData.write(to: mutationURL, options: [.atomic])
        let unchangedMetadata = try ScreenshotEvidenceAnalyzer.metadata(at: mutationURL)
        unchangedEvidence.groups[mutationIndex].screenshotSizeBytes = unchangedMetadata.sizeBytes
        unchangedEvidence.groups[mutationIndex].screenshotSHA256 = unchangedMetadata.sha256
        unchangedEvidence.groups[mutationIndex].normalizedPixelDistance = 0
        unchanged.scenarios[0].viewerShortcutEvidence = unchangedEvidence
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(unchanged.scenarios))

        try mutationData.write(to: mutationURL, options: [.atomic])
        var unchangedFitEvidence = originalEvidence
        let fitIndex = try XCTUnwrap(originalEvidence.groups.firstIndex { $0.group == .fit })
        let fitURL = URL(fileURLWithPath: originalEvidence.groups[fitIndex].screenshotPath)
        try mutationData.write(to: fitURL, options: [.atomic])
        let fitMetadata = try ScreenshotEvidenceAnalyzer.metadata(at: fitURL)
        unchangedFitEvidence.groups[fitIndex].screenshotSizeBytes = fitMetadata.sizeBytes
        unchangedFitEvidence.groups[fitIndex].screenshotSHA256 = fitMetadata.sha256
        unchangedFitEvidence.groups[fitIndex].normalizedPixelDistance = 0
        unchanged.scenarios[0].viewerShortcutEvidence = unchangedFitEvidence
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(unchanged.scenarios))

        let resetRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: resetRoot) }
        var distantReset = try materializedArtifactFixture(in: resetRoot)
        var resetEvidence = try XCTUnwrap(distantReset.scenarios[0].viewerShortcutEvidence)
        let orbit = try XCTUnwrap(resetEvidence.groups.first { $0.group == .orbitPanZoom })
        let resetIndex = try XCTUnwrap(resetEvidence.groups.firstIndex { $0.group == .reset })
        let orbitData = try Data(contentsOf: URL(fileURLWithPath: orbit.screenshotPath))
        let resetURL = URL(fileURLWithPath: resetEvidence.groups[resetIndex].screenshotPath)
        try orbitData.write(to: resetURL, options: [.atomic])
        let resetMetadata = try ScreenshotEvidenceAnalyzer.metadata(at: resetURL)
        resetEvidence.groups[resetIndex].screenshotSizeBytes = resetMetadata.sizeBytes
        resetEvidence.groups[resetIndex].screenshotSHA256 = resetMetadata.sha256
        resetEvidence.groups[resetIndex].normalizedPixelDistance = try ScreenshotEvidenceAnalyzer
            .normalizedPixelDistance(between: URL(fileURLWithPath: resetEvidence.baselineScreenshotPath), and: resetURL)
        distantReset.scenarios[0].viewerShortcutEvidence = resetEvidence
        XCTAssertThrowsError(try UIHarnessArtifactValidator.validate(distantReset.scenarios))
    }

    private func materializedArtifactFixture(in root: URL) throws -> UIHarnessSuiteResult {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var suite = UIHarnessSuiteResult.fixture(lightLuminance: 0.82, darkLuminance: 0.18)
        suite.scenarios.removeAll { $0.scenario != .light }
        for scenarioIndex in suite.scenarios.indices {
            for viewportIndex in suite.scenarios[scenarioIndex].viewports.indices {
                let result = suite.scenarios[scenarioIndex].viewports[viewportIndex]
                let prefix = "\(suite.scenarios[scenarioIndex].scenario.rawValue)-\(result.workspace.rawValue)-\(result.viewport.width)x\(result.viewport.height)"
                let screenshot = root.appendingPathComponent("\(prefix).png")
                let accessibility = root.appendingPathComponent("\(prefix)-accessibility.json")
                let colorSeed = UInt8((scenarioIndex * 47 + viewportIndex * 31) % 220 + 20)
                let size = try writeSolidPNG(
                    width: result.viewport.width,
                    height: result.viewport.height,
                    color: (colorSeed, colorSeed &+ 17, colorSeed &+ 41),
                    to: screenshot
                )
                let nodes = artifactNodes(for: result.workspace, viewport: result.viewport)
                try JSONDocument.write(nodes, to: accessibility)
                suite.scenarios[scenarioIndex].viewports[viewportIndex].screenshotPath = screenshot.path
                suite.scenarios[scenarioIndex].viewports[viewportIndex].screenshotSizeBytes = size
                suite.scenarios[scenarioIndex].viewports[viewportIndex].accessibilitySnapshotPath = accessibility.path
                suite.scenarios[scenarioIndex].viewports[viewportIndex].accessibilityNodeCount = nodes.count
            }

            let scenario = suite.scenarios[scenarioIndex].scenario
            let viewport = VerificationViewport(width: 1_100, height: 760)
            let baselineURL = root.appendingPathComponent("\(scenario.rawValue)-viewer-baseline-1100x760.png")
            let orbitURL = root.appendingPathComponent("\(scenario.rawValue)-viewer-orbit-pan-zoom-1100x760.png")
            let fitURL = root.appendingPathComponent("\(scenario.rawValue)-viewer-fit-1100x760.png")
            let resetURL = root.appendingPathComponent("\(scenario.rawValue)-viewer-reset-1100x760.png")
            _ = try writeSolidPNG(width: 1_100, height: 760, color: (40, 60, 80), to: baselineURL)
            _ = try writeSolidPNG(width: 1_100, height: 760, color: (190, 60, 80), to: orbitURL)
            _ = try writeSolidPNG(width: 1_100, height: 760, color: (60, 190, 80), to: fitURL)
            _ = try writeSolidPNG(width: 1_100, height: 760, color: (40, 60, 80), to: resetURL)
            let baseline = try ScreenshotEvidenceAnalyzer.metadata(at: baselineURL)
            let groupURLs: [(ViewerShortcutGroup, URL, URL)] = [
                (.orbitPanZoom, orbitURL, baselineURL),
                (.fit, fitURL, orbitURL),
                (.reset, resetURL, baselineURL),
            ]
            let groups = try groupURLs.map { group, screenshot, reference in
                let metadata = try ScreenshotEvidenceAnalyzer.metadata(at: screenshot)
                return ViewerShortcutGroupEvidence(
                    group: group,
                    screenshotPath: screenshot.path,
                    screenshotSizeBytes: metadata.sizeBytes,
                    screenshotSHA256: metadata.sha256,
                    normalizedPixelDistance: try ScreenshotEvidenceAnalyzer.normalizedPixelDistance(
                        between: reference,
                        and: screenshot
                    )
                )
            }
            suite.scenarios[scenarioIndex].viewerShortcutEvidence = ViewerShortcutVerificationEvidence(
                viewport: viewport,
                baselineScreenshotPath: baselineURL.path,
                baselineScreenshotSizeBytes: baseline.sizeBytes,
                baselineScreenshotSHA256: baseline.sha256,
                groups: groups
            )
        }
        return suite
    }

    private func writeSolidPNG(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8),
        to url: URL
    ) throws -> Int64 {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.setFillColor(
            red: CGFloat(color.0) / 255,
            green: CGFloat(color.1) / 255,
            blue: CGFloat(color.2) / 255,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func artifactNodes(
        for workspace: UIVerificationWorkspace,
        viewport: VerificationViewport
    ) -> [AccessibilityNodeSnapshot] {
        let windowFrame = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        var nodes = [AccessibilityNodeSnapshot(
            order: 0,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "EasySplat",
            label: nil,
            value: nil,
            placeholder: nil,
            identifier: nil,
            enabled: true,
            frame: windowFrame,
            actions: []
        )]
        var identifiers = workspace.requiredVoiceOverOrder
        if workspace == .processing {
            identifiers.append("processing.stop")
        } else if workspace == .result {
            identifiers.insert("result.viewer", at: 0)
        }
        nodes.append(contentsOf: identifiers.enumerated().map { index, identifier in
            AccessibilityNodeSnapshot(
                order: index + 1,
                role: identifier == "result.viewer" ? "AXGroup" : "AXButton",
                subrole: nil,
                title: identifier == "result.viewer" ? nil : identifier,
                label: identifier == "result.viewer" ? "Interactive 3D splat viewer" : nil,
                value: nil,
                placeholder: nil,
                identifier: identifier,
                enabled: true,
                frame: CGRect(x: 20 + CGFloat(index * 110), y: 20, width: 100, height: 32),
                actions: identifier == "result.viewer" ? [] : ["AXPress"]
            )
        })
        if workspace == .home {
            for identifier in ["project.row.0000000000000001", "project.row.0000000000000002"] {
                nodes.append(AccessibilityNodeSnapshot(
                    order: nodes.count,
                    role: "AXRow",
                    subrole: nil,
                    title: identifier,
                    label: nil,
                    value: nil,
                    placeholder: nil,
                    identifier: identifier,
                    enabled: true,
                    frame: CGRect(x: 20, y: 80 + CGFloat(nodes.count * 24), width: 300, height: 22),
                    actions: ["AXPress"]
                ))
            }
            nodes.append(AccessibilityNodeSnapshot(
                order: nodes.count,
                role: "AXStaticText",
                subrole: nil,
                title: UIVerificationFixture.longProjectTitle,
                label: nil,
                value: nil,
                placeholder: nil,
                identifier: nil,
                enabled: true,
                frame: CGRect(x: 20, y: 160, width: CGFloat(max(1, viewport.width - 40)), height: 22),
                actions: []
            ))
        }
        return nodes
    }
}

private extension UIHarnessSuiteResult {
    static func fixture(lightLuminance: Double, darkLuminance: Double) -> UIHarnessSuiteResult {
        let scenarios = UIVerificationScenario.allCases.map { scenario in
            ScenarioVerificationResult(
                schemaVersion: 3,
                app: VerifiedAppIdentity(
                    path: "/tmp/EasySplat.app",
                    bundleIdentifier: "com.easysplat.app",
                    version: "0.2.0",
                    executableSHA256: String(repeating: "a", count: 64)
                ),
                runner: UIRunnerEnvironment(
                    architecture: "arm64",
                    macOSVersion: "15.6",
                    xcodeVersion: "16.4",
                    isolatedAccount: true
                ),
                scenario: scenario,
                observedAppearance: scenario.expectedAppearance,
                observedReduceMotion: scenario.expectsReduceMotion,
                observedIncreaseContrast: scenario.expectsIncreaseContrast,
                observedDifferentiateWithoutColor: scenario.expectsDifferentiateWithoutColor,
                accessibilityPermission: true,
                screenCapturePermission: true,
                keyboardActivationPassed: true,
                focusOrder: [
                    "New Splat",
                    "home.chooseInput",
                    "processing.stop",
                    "processing.technicalDetails",
                    "result.viewer",
                ],
                longProjectTitleFound: true,
                observedControlIdentifiers: ([
                    "home.chooseInput",
                    "home.start",
                    "processing.backToProjects",
                    "processing.failureMore",
                    "processing.phase",
                    "processing.progress",
                    "processing.stop",
                    "processing.technicalDetails",
                    "processing.timing",
                    "processing.tryAgain",
                    "project.row.0000000000000001",
                    "project.row.0000000000000002",
                    "result.export",
                    "result.inspector",
                    "result.newSplat",
                    "result.share",
                    "result.viewer",
                ]).sorted(),
                passedInteractions: UIVerificationInteraction.allCases,
                viewerShortcutEvidence: ViewerShortcutVerificationEvidence(
                    viewport: VerificationViewport(width: 1_100, height: 760),
                    baselineScreenshotPath: "/tmp/\(scenario.rawValue)-viewer-baseline-1100x760.png",
                    baselineScreenshotSizeBytes: 1,
                    baselineScreenshotSHA256: String(repeating: "a", count: 64),
                    groups: [
                        ViewerShortcutGroupEvidence(
                            group: .orbitPanZoom,
                            screenshotPath: "/tmp/\(scenario.rawValue)-viewer-orbit-pan-zoom-1100x760.png",
                            screenshotSizeBytes: 1,
                            screenshotSHA256: String(repeating: "b", count: 64),
                            normalizedPixelDistance: 0.1
                        ),
                        ViewerShortcutGroupEvidence(
                            group: .fit,
                            screenshotPath: "/tmp/\(scenario.rawValue)-viewer-fit-1100x760.png",
                            screenshotSizeBytes: 1,
                            screenshotSHA256: String(repeating: "c", count: 64),
                            normalizedPixelDistance: 0.1
                        ),
                        ViewerShortcutGroupEvidence(
                            group: .reset,
                            screenshotPath: "/tmp/\(scenario.rawValue)-viewer-reset-1100x760.png",
                            screenshotSizeBytes: 1,
                            screenshotSHA256: String(repeating: "a", count: 64),
                            normalizedPixelDistance: 0
                        ),
                    ]
                ),
                viewports: UIVerificationWorkspace.allCases.flatMap { workspace in
                    VerificationViewport.required.map { viewport in
                        ViewportVerificationResult(
                            workspace: workspace,
                            viewport: viewport,
                            actualWidth: viewport.width,
                            actualHeight: viewport.height,
                            screenshotPath: "/tmp/\(scenario.rawValue)-\(workspace.rawValue)-\(viewport.width)x\(viewport.height).png",
                            screenshotSizeBytes: 1_024,
                            accessibilitySnapshotPath: "/tmp/\(scenario.rawValue)-\(workspace.rawValue)-\(viewport.width)x\(viewport.height)-accessibility.json",
                            accessibilityNodeCount: 20,
                            averageLuminance: scenario == .dark ? darkLuminance : lightLuminance,
                            accessibilityIssues: []
                        )
                    }
                },
                failures: []
            )
        }
        return UIHarnessSuiteResult(
            schemaVersion: 3,
            passed: true,
            failures: [],
            scenarios: scenarios
        )
    }
}
