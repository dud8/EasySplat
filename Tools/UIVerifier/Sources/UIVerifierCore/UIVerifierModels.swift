import CoreGraphics
import Foundation

public enum UIAppearanceExpectation: String, Codable, Sendable {
    case light
    case dark
}

public enum UIVerificationFixture {
    public static let longProjectTitle = "Riverside Estate — Final Exterior and Interior Walkthrough — Mixed Cameras — East Wing — July 2026"
}

public enum UIVerificationScenario: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case reduceMotion = "reduce-motion"
    case increaseContrast = "increase-contrast"
    case differentiateWithoutColor = "differentiate-without-color"

    public var expectedAppearance: UIAppearanceExpectation {
        self == .dark ? .dark : .light
    }

    public var expectsReduceMotion: Bool {
        self == .reduceMotion
    }

    public var expectsIncreaseContrast: Bool {
        self == .increaseContrast
    }

    public var expectsDifferentiateWithoutColor: Bool {
        self == .differentiateWithoutColor
    }
}

public enum UIVerificationWorkspace: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case processing
    case result
    case failure

    var requiredVisibleIdentifiers: Set<String> {
        switch self {
        case .processing:
            Set(requiredVoiceOverOrder).union(["processing.stop"])
        case .home, .result, .failure:
            Set(requiredVoiceOverOrder)
        }
    }

    var requiredVoiceOverOrder: [String] {
        switch self {
        case .home:
            ["home.chooseInput", "home.start"]
        case .processing:
            [
                "processing.phase",
                "processing.progress",
                "processing.timing",
                "processing.technicalDetails",
            ]
        case .result:
            ["result.export", "result.share", "result.inspector", "result.viewer"]
        case .failure:
            [
                "processing.phase",
                "processing.tryAgain",
                "processing.backToProjects",
                "processing.failureMore",
                "processing.technicalDetails",
            ]
        }
    }
}

public enum UIVerificationInteraction: String, Codable, CaseIterable, Hashable, Sendable {
    case chooseInputKeyboardActivation
    case verifyProcessingKeyboardTraversal
    case cancelProcessingStop
    case expandProcessingTechnicalDetails
    case openReadyProject
    case toggleResultInspector
    case cancelResultExport
    case verifyViewerKeyboardTraversal
    case verifyViewerShortcutRendering
    case startNewSplatFromResult
    case openInvalidOptionsProject
    case expandFailureTechnicalDetails
    case returnToProjectsFromFailure
}

public enum ViewerShortcutGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case orbitPanZoom = "orbit-pan-zoom"
    case fit
    case reset
}

public struct ViewerShortcutGroupEvidence: Codable, Sendable {
    public var group: ViewerShortcutGroup
    public var screenshotPath: String
    public var screenshotSizeBytes: Int64
    public var screenshotSHA256: String
    public var normalizedPixelDistance: Double

    public init(
        group: ViewerShortcutGroup,
        screenshotPath: String,
        screenshotSizeBytes: Int64,
        screenshotSHA256: String,
        normalizedPixelDistance: Double
    ) {
        self.group = group
        self.screenshotPath = screenshotPath
        self.screenshotSizeBytes = screenshotSizeBytes
        self.screenshotSHA256 = screenshotSHA256
        self.normalizedPixelDistance = normalizedPixelDistance
    }
}

public struct ViewerShortcutVerificationEvidence: Codable, Sendable {
    public var viewport: VerificationViewport
    public var baselineScreenshotPath: String
    public var baselineScreenshotSizeBytes: Int64
    public var baselineScreenshotSHA256: String
    public var groups: [ViewerShortcutGroupEvidence]

    public init(
        viewport: VerificationViewport,
        baselineScreenshotPath: String,
        baselineScreenshotSizeBytes: Int64,
        baselineScreenshotSHA256: String,
        groups: [ViewerShortcutGroupEvidence]
    ) {
        self.viewport = viewport
        self.baselineScreenshotPath = baselineScreenshotPath
        self.baselineScreenshotSizeBytes = baselineScreenshotSizeBytes
        self.baselineScreenshotSHA256 = baselineScreenshotSHA256
        self.groups = groups
    }
}

public struct UIRunnerEnvironment: Codable, Equatable, Sendable {
    public var architecture: String
    public var macOSVersion: String
    public var xcodeVersion: String
    public var isolatedAccount: Bool

    public init(
        architecture: String,
        macOSVersion: String,
        xcodeVersion: String,
        isolatedAccount: Bool
    ) {
        self.architecture = architecture
        self.macOSVersion = macOSVersion
        self.xcodeVersion = xcodeVersion
        self.isolatedAccount = isolatedAccount
    }

    public var isReleaseLane: Bool {
        architecture == "arm64"
            && macOSVersion.split(separator: ".").first == "15"
            && xcodeVersion == "16.4"
            && isolatedAccount
    }
}

public struct VerifiedAppIdentity: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var bundleIdentifier: String
    public var version: String
    public var executableSHA256: String

    public init(
        path: String,
        bundleIdentifier: String,
        version: String,
        executableSHA256: String
    ) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.executableSHA256 = executableSHA256
    }
}

public struct VerificationViewport: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let required = [
        VerificationViewport(width: 920, height: 640),
        VerificationViewport(width: 1_100, height: 760),
        VerificationViewport(width: 1_440, height: 900),
    ]
}

public struct AccessibilityNodeSnapshot: Codable, Sendable {
    public var order: Int
    public var role: String
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var identifier: String?
    public var enabled: Bool
    public var frame: CGRect?
    public var actions: [String]

    public init(
        order: Int,
        role: String,
        subrole: String?,
        title: String?,
        label: String?,
        value: String?,
        placeholder: String?,
        identifier: String?,
        enabled: Bool,
        frame: CGRect?,
        actions: [String]
    ) {
        self.order = order
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
        self.enabled = enabled
        self.frame = frame
        self.actions = actions
    }

    var displayName: String? {
        [label, title, value, placeholder, identifier, subrole]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

public struct ViewportVerificationResult: Codable, Sendable {
    public var workspace: UIVerificationWorkspace
    public var viewport: VerificationViewport
    public var actualWidth: Int
    public var actualHeight: Int
    public var screenshotPath: String
    public var screenshotSizeBytes: Int64
    public var accessibilitySnapshotPath: String
    public var accessibilityNodeCount: Int
    public var averageLuminance: Double
    public var accessibilityIssues: [String]

    public init(
        workspace: UIVerificationWorkspace,
        viewport: VerificationViewport,
        actualWidth: Int,
        actualHeight: Int,
        screenshotPath: String,
        screenshotSizeBytes: Int64,
        accessibilitySnapshotPath: String,
        accessibilityNodeCount: Int,
        averageLuminance: Double,
        accessibilityIssues: [String]
    ) {
        self.workspace = workspace
        self.viewport = viewport
        self.actualWidth = actualWidth
        self.actualHeight = actualHeight
        self.screenshotPath = screenshotPath
        self.screenshotSizeBytes = screenshotSizeBytes
        self.accessibilitySnapshotPath = accessibilitySnapshotPath
        self.accessibilityNodeCount = accessibilityNodeCount
        self.averageLuminance = averageLuminance
        self.accessibilityIssues = accessibilityIssues
    }
}

public struct ScenarioVerificationResult: Codable, Sendable {
    public var schemaVersion: Int
    public var app: VerifiedAppIdentity?
    public var runner: UIRunnerEnvironment
    public var scenario: UIVerificationScenario
    public var observedAppearance: UIAppearanceExpectation?
    public var observedReduceMotion: Bool
    public var observedIncreaseContrast: Bool
    public var observedDifferentiateWithoutColor: Bool
    public var accessibilityPermission: Bool
    public var screenCapturePermission: Bool
    public var keyboardActivationPassed: Bool
    public var focusOrder: [String]
    public var longProjectTitleFound: Bool
    public var observedControlIdentifiers: [String]
    public var passedInteractions: [UIVerificationInteraction]
    public var viewerShortcutEvidence: ViewerShortcutVerificationEvidence?
    public var viewports: [ViewportVerificationResult]
    public var failures: [String]

    public init(
        schemaVersion: Int,
        app: VerifiedAppIdentity?,
        runner: UIRunnerEnvironment,
        scenario: UIVerificationScenario,
        observedAppearance: UIAppearanceExpectation?,
        observedReduceMotion: Bool,
        observedIncreaseContrast: Bool,
        observedDifferentiateWithoutColor: Bool,
        accessibilityPermission: Bool,
        screenCapturePermission: Bool,
        keyboardActivationPassed: Bool,
        focusOrder: [String],
        longProjectTitleFound: Bool,
        observedControlIdentifiers: [String],
        passedInteractions: [UIVerificationInteraction],
        viewerShortcutEvidence: ViewerShortcutVerificationEvidence?,
        viewports: [ViewportVerificationResult],
        failures: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.runner = runner
        self.scenario = scenario
        self.observedAppearance = observedAppearance
        self.observedReduceMotion = observedReduceMotion
        self.observedIncreaseContrast = observedIncreaseContrast
        self.observedDifferentiateWithoutColor = observedDifferentiateWithoutColor
        self.accessibilityPermission = accessibilityPermission
        self.screenCapturePermission = screenCapturePermission
        self.keyboardActivationPassed = keyboardActivationPassed
        self.focusOrder = focusOrder
        self.longProjectTitleFound = longProjectTitleFound
        self.observedControlIdentifiers = observedControlIdentifiers
        self.passedInteractions = passedInteractions
        self.viewerShortcutEvidence = viewerShortcutEvidence
        self.viewports = viewports
        self.failures = failures
    }
}

public struct UIHarnessSuiteResult: Codable, Sendable {
    public var schemaVersion: Int
    public var passed: Bool
    public var failures: [String]
    public var scenarios: [ScenarioVerificationResult]

    public init(
        schemaVersion: Int,
        passed: Bool,
        failures: [String],
        scenarios: [ScenarioVerificationResult]
    ) {
        self.schemaVersion = schemaVersion
        self.passed = passed
        self.failures = failures
        self.scenarios = scenarios
    }
}
