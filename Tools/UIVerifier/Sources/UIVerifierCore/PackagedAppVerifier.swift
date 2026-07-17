import ApplicationServices
import AppKit
import CoreGraphics
import CryptoKit
import EasySplatCore
import Foundation

public enum PackagedAppVerificationError: Error, LocalizedError {
    case accessibilityPermission
    case screenCapturePermission
    case invalidAppBundle(String)
    case invalidFixture(String)
    case displayTooSmall(required: VerificationViewport)
    case launchFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            return "Accessibility access is unavailable. Grant the verifier host Accessibility access before running this release gate."
        case .screenCapturePermission:
            return "Screen Recording access is unavailable. Grant the verifier host Screen Recording access before running this release gate."
        case .invalidAppBundle(let reason):
            return "The packaged app is invalid: \(reason)"
        case .invalidFixture(let reason):
            return "The UI verification fixture is invalid: \(reason)"
        case .displayTooSmall(let required):
            return "The active display cannot contain the required \(required.width)x\(required.height) app window."
        case .launchFailed:
            return "The packaged app did not launch as a distinct process."
        }
    }
}

@MainActor
public enum PackagedAppVerifier {
    public static let longProjectTitle = UIVerificationFixture.longProjectTitle

    public static func run(
        appURL: URL,
        scenario: UIVerificationScenario,
        screenshotDirectory: URL
    ) async throws -> ScenarioVerificationResult {
        guard AXIsProcessTrusted() else {
            throw PackagedAppVerificationError.accessibilityPermission
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw PackagedAppVerificationError.screenCapturePermission
        }
        let appIdentity = try validatePackagedApp(at: appURL)
        try validateDisplayCapacity()

        let fileManager = FileManager.default
        let harnessHome = screenshotDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("harness-home-\(scenario.rawValue)", isDirectory: true)
        try? fileManager.removeItem(at: harnessHome)
        let fixture = try createFixtureProjects(in: harnessHome)
        try fileManager.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: harnessHome.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        let processingVerification = try await verifyProcessingFixture(
            appURL: appURL,
            projectURL: fixture.processingProject,
            scenario: scenario,
            harnessHome: harnessHome,
            screenshotDirectory: screenshotDirectory
        )
        let configuration = appConfiguration(
            scenario: scenario,
            harnessHome: harnessHome,
            processingProjectURL: nil
        )

        let running = try await launchApplication(
            at: appURL,
            configuration: configuration
        )
        guard !running.isTerminated else {
            throw PackagedAppVerificationError.launchFailed
        }
        defer {
            terminate(running)
            try? fileManager.removeItem(at: harnessHome)
        }
        let controller = AXApplicationController(processIdentifier: running.processIdentifier)
        let mainWindow = try await controller.waitForMainWindow()
        try await controller.activate()
        let observedReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let observedIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let observedDifferentiateWithoutColor = NSWorkspace.shared
            .accessibilityDisplayShouldDifferentiateWithoutColor
        let runner = runnerEnvironment()
        var failures = processingVerification.failures
        if !runner.isReleaseLane {
            failures.append("The verifier is not running on the declared isolated macOS 15 arm64/Xcode 16.4 release lane.")
        }
        if observedReduceMotion != scenario.expectsReduceMotion {
            failures.append("Observed Reduce Motion setting does not match the \(scenario.rawValue) scenario.")
        }
        if observedIncreaseContrast != scenario.expectsIncreaseContrast {
            failures.append("Observed Increase Contrast setting does not match the \(scenario.rawValue) scenario.")
        }
        if observedDifferentiateWithoutColor != scenario.expectsDifferentiateWithoutColor {
            failures.append("Observed Differentiate Without Color setting does not match the \(scenario.rawValue) scenario.")
        }
        if UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode") & 0x2 == 0 {
            failures.append("Full keyboard access is not enabled for the verification process.")
        }

        var observedIdentifiers = processingVerification.observedIdentifiers
        var passedInteractions = processingVerification.passedInteractions
        var viewerShortcutEvidence: ViewerShortcutVerificationEvidence?
        var viewerFocusOrder: [String] = []
        let readyRowIdentifier = ProjectRowAccessibilityIdentifier.make(for: fixture.readyProject)
        let invalidRowIdentifier = ProjectRowAccessibilityIdentifier.make(for: fixture.invalidOptionsProject)
        let invalidActionIdentifier = ProjectRowAccessibilityIdentifier.action(for: fixture.invalidOptionsProject)
        let homeIdentifiers: Set<String> = [
            "home.chooseInput",
            "home.start",
            readyRowIdentifier,
            invalidRowIdentifier,
            invalidActionIdentifier,
        ]
        try await controller.requireIdentifiers(homeIdentifiers)
        observedIdentifiers.formUnion(homeIdentifiers)

        let keyboard = await controller.testChooseInputKeyboardActivation()
        failures.append(contentsOf: keyboard.failures)
        if keyboard.passed {
            passedInteractions.append(.chooseInputKeyboardActivation)
        }

        var viewportResults = processingVerification.capture.results
        let homeCapture = try await captureWorkspace(
            .home,
            scenario: scenario,
            controller: controller,
            mainWindow: mainWindow,
            processIdentifier: running.processIdentifier,
            screenshotDirectory: screenshotDirectory
        )
        viewportResults.append(contentsOf: homeCapture.results)
        failures.append(contentsOf: homeCapture.failures)

        try await controller.press(identifier: readyRowIdentifier)
        let resultIdentifiers = UIVerificationWorkspace.result.requiredVisibleIdentifiers
        try await controller.requireIdentifiers(resultIdentifiers)
        observedIdentifiers.formUnion(resultIdentifiers)
        passedInteractions.append(.openReadyProject)
        try await Task.sleep(for: .milliseconds(500))
        guard await controller.waitForText("Loading splat…", present: false, timeoutSeconds: 8),
              !(await controller.waitForText("Couldn’t load splat", present: true, timeoutSeconds: 0.2)) else {
            throw AXAutomationError.actionFailed("loading the validated result fixture")
        }

        let resultCapture = try await captureWorkspace(
            .result,
            scenario: scenario,
            controller: controller,
            mainWindow: mainWindow,
            processIdentifier: running.processIdentifier,
            screenshotDirectory: screenshotDirectory
        )
        viewportResults.append(contentsOf: resultCapture.results)
        failures.append(contentsOf: resultCapture.failures)

        try await controller.verifyInspectorToggle()
        passedInteractions.append(.toggleResultInspector)
        try await controller.pressAndCancelDialog(
            identifier: "result.export",
            relativeTo: mainWindow
        )
        passedInteractions.append(.cancelResultExport)
        viewerFocusOrder = try await controller.focusViewerForKeyboardEvidence()
        passedInteractions.append(.verifyViewerKeyboardTraversal)
        viewerShortcutEvidence = try await captureViewerShortcutEvidence(
            scenario: scenario,
            controller: controller,
            mainWindow: mainWindow,
            processIdentifier: running.processIdentifier,
            screenshotDirectory: screenshotDirectory
        )
        passedInteractions.append(.verifyViewerShortcutRendering)

        try await controller.pressMenuItem(identifier: "result.newSplat", menuName: "More")
        observedIdentifiers.insert("result.newSplat")
        try await controller.requireIdentifiers(homeIdentifiers)
        passedInteractions.append(.startNewSplatFromResult)

        try await controller.press(identifier: invalidActionIdentifier)
        let failureIdentifiers = UIVerificationWorkspace.failure.requiredVisibleIdentifiers
        try await controller.requireIdentifiers(failureIdentifiers)
        observedIdentifiers.formUnion(failureIdentifiers)
        passedInteractions.append(.openInvalidOptionsProject)

        let failureCapture = try await captureWorkspace(
            .failure,
            scenario: scenario,
            controller: controller,
            mainWindow: mainWindow,
            processIdentifier: running.processIdentifier,
            screenshotDirectory: screenshotDirectory
        )
        viewportResults.append(contentsOf: failureCapture.results)
        failures.append(contentsOf: failureCapture.failures)

        let technicalMarker = "Resume preflight stopped before downloading tools or changing project files."
        guard await controller.waitForText(technicalMarker, present: false, timeoutSeconds: 1) else {
            throw AXAutomationError.actionFailed("keeping technical failure details collapsed")
        }
        try await controller.press(identifier: "processing.technicalDetails")
        guard await controller.waitForText(technicalMarker, present: true) else {
            throw AXAutomationError.actionFailed("expanding technical failure details")
        }
        passedInteractions.append(.expandFailureTechnicalDetails)

        try await controller.press(identifier: "processing.backToProjects")
        try await controller.requireIdentifiers(homeIdentifiers)
        passedInteractions.append(.returnToProjectsFromFailure)

        let sortedLuminance = homeCapture.results.map(\.averageLuminance).sorted()
        let medianLuminance = sortedLuminance[sortedLuminance.count / 2]
        let observedAppearance: UIAppearanceExpectation = medianLuminance >= 0.5 ? .light : .dark
        if observedAppearance != scenario.expectedAppearance {
            failures.append("Screenshot luminance does not match the \(scenario.rawValue) appearance.")
        }

        return ScenarioVerificationResult(
            schemaVersion: 3,
            app: appIdentity,
            runner: runner,
            scenario: scenario,
            observedAppearance: observedAppearance,
            observedReduceMotion: observedReduceMotion,
            observedIncreaseContrast: observedIncreaseContrast,
            observedDifferentiateWithoutColor: observedDifferentiateWithoutColor,
            accessibilityPermission: true,
            screenCapturePermission: true,
            keyboardActivationPassed: keyboard.passed,
            focusOrder: keyboard.focusOrder
                + processingVerification.focusOrder
                + viewerFocusOrder,
            longProjectTitleFound: homeCapture.longProjectTitleFound,
            observedControlIdentifiers: observedIdentifiers.sorted(),
            passedInteractions: passedInteractions.sorted { $0.rawValue < $1.rawValue },
            viewerShortcutEvidence: viewerShortcutEvidence,
            viewports: viewportResults,
            failures: failures.sorted()
        )
    }

    public static func failureResult(
        appURL: URL,
        scenario: UIVerificationScenario,
        error: Error
    ) -> ScenarioVerificationResult {
        ScenarioVerificationResult(
            schemaVersion: 3,
            app: try? validatePackagedApp(at: appURL),
            runner: runnerEnvironment(),
            scenario: scenario,
            observedAppearance: nil,
            observedReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            observedIncreaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            observedDifferentiateWithoutColor: NSWorkspace.shared
                .accessibilityDisplayShouldDifferentiateWithoutColor,
            accessibilityPermission: AXIsProcessTrusted(),
            screenCapturePermission: CGPreflightScreenCaptureAccess(),
            keyboardActivationPassed: false,
            focusOrder: [],
            longProjectTitleFound: false,
            observedControlIdentifiers: [],
            passedInteractions: [],
            viewerShortcutEvidence: nil,
            viewports: [],
            failures: [error.localizedDescription]
        )
    }

    private static func validatePackagedApp(at url: URL) throws -> VerifiedAppIdentity {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard url.pathExtension == "app", values.isDirectory == true, values.isSymbolicLink != true else {
            throw PackagedAppVerificationError.invalidAppBundle("expected a plain .app directory")
        }
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.easysplat.app" else {
            throw PackagedAppVerificationError.invalidAppBundle("bundle identifier must be com.easysplat.app")
        }
        guard let executable = bundle.executableURL else {
            throw PackagedAppVerificationError.invalidAppBundle("CFBundleExecutable is missing")
        }
        let executableValues = try executable.resourceValues(forKeys: [
            .isRegularFileKey,
            .isExecutableKey,
            .isSymbolicLinkKey,
        ])
        guard executableValues.isRegularFile == true,
              executableValues.isExecutable == true,
              executableValues.isSymbolicLink != true else {
            throw PackagedAppVerificationError.invalidAppBundle("the main executable is not a regular executable file")
        }
        let version = (bundle.object(forInfoDictionaryKey: "EasySplatReleaseVersion") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        guard let version,
              !version.isEmpty else {
            throw PackagedAppVerificationError.invalidAppBundle("CFBundleShortVersionString is missing")
        }
        return VerifiedAppIdentity(
            path: url.standardizedFileURL.path,
            bundleIdentifier: "com.easysplat.app",
            version: version,
            executableSHA256: try sha256(of: executable)
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func terminate(_ application: NSRunningApplication) {
        guard !application.isTerminated else { return }
        _ = application.terminate()
        let gracefulDeadline = Date().addingTimeInterval(2)
        while !application.isTerminated, Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !application.isTerminated else { return }
        _ = application.forceTerminate()
        let forcedDeadline = Date().addingTimeInterval(2)
        while !application.isTerminated, Date() < forcedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func validateDisplayCapacity() throws {
        guard let largest = NSScreen.screens.max(by: {
            $0.visibleFrame.width * $0.visibleFrame.height < $1.visibleFrame.width * $1.visibleFrame.height
        }) else {
            throw PackagedAppVerificationError.displayTooSmall(required: VerificationViewport.required.last!)
        }
        let required = VerificationViewport.required.last!
        guard largest.visibleFrame.width >= CGFloat(required.width),
              largest.visibleFrame.height >= CGFloat(required.height) else {
            throw PackagedAppVerificationError.displayTooSmall(required: required)
        }
    }

    private struct FixtureProjects {
        var processingProject: URL
        var readyProject: URL
        var invalidOptionsProject: URL
    }

    private struct ProcessingVerification {
        var capture: WorkspaceCapture
        var observedIdentifiers: Set<String>
        var focusOrder: [String]
        var passedInteractions: [UIVerificationInteraction]
        var failures: [String]
    }

    private struct WorkspaceCapture {
        var results: [ViewportVerificationResult]
        var longProjectTitleFound: Bool
        var failures: [String]
    }

    private static func appConfiguration(
        scenario: UIVerificationScenario,
        harnessHome: URL,
        processingProjectURL: URL?
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("EASYSPLAT_") }
        let appearanceOverride = scenario.expectedAppearance == .dark ? "Dark" : "Light"
        let requiresAqua = scenario.expectedAppearance == .light ? "YES" : "NO"
        environment["AppleInterfaceStyle"] = appearanceOverride
        environment["NSRequiresAquaSystemAppearance"] = requiresAqua
        environment["HOME"] = harnessHome.path
        environment["CFFIXED_USER_HOME"] = harnessHome.path
        environment["TMPDIR"] = harnessHome.appendingPathComponent("tmp", isDirectory: true).path
        var arguments = [
            "-AppleInterfaceStyle", appearanceOverride,
            "-AppleKeyboardUIMode", "3",
            "-NSRequiresAquaSystemAppearance", requiresAqua,
        ]
        if let processingProjectURL {
            environment["EASYSPLAT_ISOLATED_UI_RUNNER"] = ProcessInfo.processInfo
                .environment["EASYSPLAT_ISOLATED_UI_RUNNER"]
            environment["EASYSPLAT_UI_VERIFIER_PROCESSING_PROJECT"] = processingProjectURL.path
            arguments.append("--easysplat-ui-verifier-processing-fixture")
        }
        configuration.environment = environment
        configuration.arguments = arguments
        return configuration
    }

    private static func launchApplication(
        at appURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            ) { runningApplication, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let runningApplication {
                    continuation.resume(returning: runningApplication)
                } else {
                    continuation.resume(throwing: PackagedAppVerificationError.launchFailed)
                }
            }
        }
    }

    private static func verifyProcessingFixture(
        appURL: URL,
        projectURL: URL,
        scenario: UIVerificationScenario,
        harnessHome: URL,
        screenshotDirectory: URL
    ) async throws -> ProcessingVerification {
        let running = try await launchApplication(
            at: appURL,
            configuration: appConfiguration(
                scenario: scenario,
                harnessHome: harnessHome,
                processingProjectURL: projectURL
            )
        )
        guard !running.isTerminated else {
            throw PackagedAppVerificationError.launchFailed
        }
        defer { terminate(running) }

        let controller = AXApplicationController(processIdentifier: running.processIdentifier)
        let mainWindow = try await controller.waitForMainWindow()
        try await controller.activate()
        let identifiers = UIVerificationWorkspace.processing.requiredVisibleIdentifiers
        try await controller.requireIdentifiers(identifiers)
        guard await controller.waitForText("Step 2 of 4 · Reconstructing scene", present: true),
              await controller.waitForText("In progress", present: true),
              await controller.waitForText("Elapsed", present: true),
              await controller.waitForText("Last update", present: true) else {
            throw AXAutomationError.actionFailed("presenting the active processing fixture")
        }

        let keyboard = await controller.testKeyboardTraversal(
            requiredIdentifiers: ["processing.stop", "processing.technicalDetails"]
        )
        var interactions: [UIVerificationInteraction] = []
        if keyboard.passed {
            interactions.append(.verifyProcessingKeyboardTraversal)
        }
        let capture = try await captureWorkspace(
            .processing,
            scenario: scenario,
            controller: controller,
            mainWindow: mainWindow,
            processIdentifier: running.processIdentifier,
            screenshotDirectory: screenshotDirectory
        )

        try await controller.pressAndCancelDialog(
            identifier: "processing.stop",
            relativeTo: mainWindow
        )
        interactions.append(.cancelProcessingStop)

        let technicalMarker = "Refinement pass 2 of 3."
        guard await controller.waitForText(technicalMarker, present: false, timeoutSeconds: 1) else {
            throw AXAutomationError.actionFailed("keeping active processing details collapsed")
        }
        try await controller.press(identifier: "processing.technicalDetails")
        guard await controller.waitForText(technicalMarker, present: true) else {
            throw AXAutomationError.actionFailed("expanding active processing details")
        }
        interactions.append(.expandProcessingTechnicalDetails)

        return ProcessingVerification(
            capture: capture,
            observedIdentifiers: identifiers,
            focusOrder: keyboard.focusOrder,
            passedInteractions: interactions,
            failures: keyboard.failures + capture.failures
        )
    }

    private static func captureWorkspace(
        _ workspace: UIVerificationWorkspace,
        scenario: UIVerificationScenario,
        controller: AXApplicationController,
        mainWindow: AXUIElement,
        processIdentifier: pid_t,
        screenshotDirectory: URL
    ) async throws -> WorkspaceCapture {
        var results: [ViewportVerificationResult] = []
        var longTitleFound = false
        var failures: [String] = []
        for viewport in VerificationViewport.required {
            try await controller.setSize(viewport, of: mainWindow)
            guard let actualFrame = await controller.waitForSize(viewport, of: mainWindow) else {
                throw AXAutomationError.noMainWindow("window disappeared during resize")
            }
            try await Task.sleep(for: .milliseconds(250))
            let nodes = controller.snapshots(from: mainWindow)
            let accessibilityIssues = AccessibilityAudit.issues(
                nodes: nodes,
                windowFrame: actualFrame,
                longProjectTitle: longProjectTitle,
                workspace: workspace
            )
            if workspace == .home, nodes.contains(where: { node in
                node.title?.contains(longProjectTitle) == true
                    || node.label?.contains(longProjectTitle) == true
                    || node.value?.contains(longProjectTitle) == true
            }) {
                longTitleFound = true
            }

            let artifactPrefix = "\(scenario.rawValue)-\(workspace.rawValue)-\(viewport.width)x\(viewport.height)"
            let accessibilityURL = screenshotDirectory.appendingPathComponent(
                "\(artifactPrefix)-accessibility.json"
            )
            try JSONDocument.write(nodes, to: accessibilityURL)
            let screenshotURL = screenshotDirectory.appendingPathComponent("\(artifactPrefix).png")
            let screenshot = try await ScreenshotCapture.capture(
                processIdentifier: processIdentifier,
                viewport: viewport,
                to: screenshotURL
            )
            if abs(actualFrame.width - CGFloat(viewport.width)) > 2
                || abs(actualFrame.height - CGFloat(viewport.height)) > 2 {
                failures.append(
                    "The \(workspace.rawValue) app window did not reach \(viewport.width)x\(viewport.height)."
                )
            }
            if !(0...1).contains(screenshot.luminance) {
                failures.append(
                    "The \(workspace.rawValue) \(viewport.width)x\(viewport.height) screenshot luminance is invalid."
                )
            }
            results.append(ViewportVerificationResult(
                workspace: workspace,
                viewport: viewport,
                actualWidth: Int(actualFrame.width.rounded()),
                actualHeight: Int(actualFrame.height.rounded()),
                screenshotPath: screenshotURL.path,
                screenshotSizeBytes: screenshot.sizeBytes,
                accessibilitySnapshotPath: accessibilityURL.path,
                accessibilityNodeCount: nodes.count,
                averageLuminance: screenshot.luminance,
                accessibilityIssues: accessibilityIssues
            ))
        }
        return WorkspaceCapture(
            results: results,
            longProjectTitleFound: longTitleFound,
            failures: failures
        )
    }

    private static func captureViewerShortcutEvidence(
        scenario: UIVerificationScenario,
        controller: AXApplicationController,
        mainWindow: AXUIElement,
        processIdentifier: pid_t,
        screenshotDirectory: URL
    ) async throws -> ViewerShortcutVerificationEvidence {
        let viewport = VerificationViewport(width: 1_100, height: 760)
        try await controller.setSize(viewport, of: mainWindow)
        guard await controller.waitForSize(viewport, of: mainWindow) != nil else {
            throw AXAutomationError.noMainWindow("window disappeared before viewer shortcut evidence")
        }
        try await controller.performViewerShortcutGroup(.reset)
        try await Task.sleep(for: .milliseconds(450))

        let prefix = "\(scenario.rawValue)-viewer"
        let baselineURL = screenshotDirectory.appendingPathComponent(
            "\(prefix)-baseline-\(viewport.width)x\(viewport.height).png"
        )
        let baselineCapture = try await ScreenshotCapture.capture(
            processIdentifier: processIdentifier,
            viewport: viewport,
            to: baselineURL
        )
        var previousURL = baselineURL
        var groups: [ViewerShortcutGroupEvidence] = []
        for group in ViewerShortcutGroup.allCases {
            try await controller.performViewerShortcutGroup(group)
            try await Task.sleep(for: .milliseconds(450))
            let screenshotURL = screenshotDirectory.appendingPathComponent(
                "\(prefix)-\(group.rawValue)-\(viewport.width)x\(viewport.height).png"
            )
            let screenshot = try await ScreenshotCapture.capture(
                processIdentifier: processIdentifier,
                viewport: viewport,
                to: screenshotURL
            )
            let referenceURL = group == .reset ? baselineURL : previousURL
            groups.append(ViewerShortcutGroupEvidence(
                group: group,
                screenshotPath: screenshotURL.path,
                screenshotSizeBytes: screenshot.sizeBytes,
                screenshotSHA256: screenshot.sha256,
                normalizedPixelDistance: try ScreenshotEvidenceAnalyzer.normalizedPixelDistance(
                    between: referenceURL,
                    and: screenshotURL
                )
            ))
            previousURL = screenshotURL
        }
        let evidence = ViewerShortcutVerificationEvidence(
            viewport: viewport,
            baselineScreenshotPath: baselineURL.path,
            baselineScreenshotSizeBytes: baselineCapture.sizeBytes,
            baselineScreenshotSHA256: baselineCapture.sha256,
            groups: groups
        )
        try ViewerShortcutEvidenceValidator.validate(evidence)
        return evidence
    }

    private static func createFixtureProjects(in home: URL) throws -> FixtureProjects {
        let projects = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("EasySplat Projects", isDirectory: true)
        let projectRoot = projects.appendingPathComponent(
            "\(longProjectTitle).easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectRoot)
        try paths.ensureDirectories()
        let input = home.appendingPathComponent(
            "Riverside Estate — final walkthrough — mixed cameras — source.mov"
        )
        try Data("UI verification fixture".utf8).write(to: input, options: [.atomic])
        let metadata = ProjectMetadata(
            title: longProjectTitle,
            input: .video(files: [input.path]),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let processingRoot = projects.appendingPathComponent(
            "Processing Fixture.easysplatproj",
            isDirectory: true
        )
        let processingPaths = ProjectPaths(root: processingRoot)
        try processingPaths.ensureDirectories()
        let processingMetadata = ProjectMetadata(
            createdAt: Date(timeIntervalSince1970: 1_700_000_050),
            title: "Processing Fixture",
            input: .video(files: [input.path]),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            state: PipelineState(stage: .sfmMapping, lastError: nil)
        )
        try ProjectMetadataStore.save(processingMetadata, to: processingPaths.metadataURL)

        let readyRoot = projects.appendingPathComponent(
            "Harbor House Ready Result.easysplatproj",
            isDirectory: true
        )
        let readyPaths = ProjectPaths(root: readyRoot)
        try readyPaths.ensureDirectories()
        let photoFolder = home.appendingPathComponent("Harbor House Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        let outputURL = readyPaths.outputURL.appendingPathComponent("splat.ply")
        try validatedFixturePLY.write(to: outputURL, atomically: true, encoding: .utf8)
        guard ProjectArtifactValidator.validatePlyFile(at: outputURL) == .valid else {
            throw PackagedAppVerificationError.invalidFixture("ready-project PLY did not pass validation")
        }
        let readyMetadata = ProjectMetadata(
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            title: "Harbor House Ready Result",
            input: .photos(folder: photoFolder.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(
                splatPlyPath: "Output/splat.ply",
                colmapModelPath: "SfM/colmap/sparse/0"
            ),
            notes: "UI verification fixture"
        )
        try ProjectMetadataStore.save(readyMetadata, to: readyPaths.metadataURL)

        let invalidRoot = projects.appendingPathComponent(
            "Separate Clips Invalid Options.easysplatproj",
            isDirectory: true
        )
        let invalidPaths = ProjectPaths(root: invalidRoot)
        try invalidPaths.ensureDirectories()
        let firstClip = home.appendingPathComponent("separate-clip-a.mov")
        let secondClip = home.appendingPathComponent("separate-clip-b.mov")
        try Data("clip-a".utf8).write(to: firstClip, options: [.atomic])
        try Data("clip-b".utf8).write(to: secondClip, options: [.atomic])
        let invalidMetadata = ProjectMetadata(
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            title: "Separate Clips Invalid Options",
            input: .video(files: [firstClip.path, secondClip.path]),
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .fast,
                inputOrdering: .continuous
            )
        )
        try ProjectMetadataStore.save(invalidMetadata, to: invalidPaths.metadataURL)
        return FixtureProjects(
            processingProject: processingRoot,
            readyProject: readyRoot,
            invalidOptionsProject: invalidRoot
        )
    }

    private static let validatedFixturePLY: String = {
        var rows: [String] = []
        for depth in 0..<3 {
            for row in 0..<11 {
                for column in 0..<15 {
                    let x = Double(column - 7) * 0.35
                    let y = Double(row - 5) * 0.30
                    let z = Double(depth - 1) * 0.80
                    let red = Double(column) / 14 * 1.4 - 0.4
                    let green = Double(row) / 10 * 1.4 - 0.4
                    let blue = Double(depth) / 2 * 1.4 - 0.4
                    rows.append(String(
                        format: "%.4f %.4f %.4f %.4f %.4f %.4f -2 -2 -2 3 1 0 0 0",
                        x, y, z, red, green, blue
                    ))
                }
            }
        }
        let header = """
        ply
        format ascii 1.0
        element vertex \(rows.count)
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        """
        return header + "\n" + rows.joined(separator: "\n") + "\n"
    }()

    private static func runnerEnvironment() -> UIRunnerEnvironment {
        let environment = ProcessInfo.processInfo.environment
        return UIRunnerEnvironment(
            architecture: environment["EASYSPLAT_UI_RUNNER_ARCHITECTURE"] ?? "",
            macOSVersion: environment["EASYSPLAT_UI_RUNNER_MACOS_VERSION"] ?? "",
            xcodeVersion: environment["EASYSPLAT_UI_RUNNER_XCODE_VERSION"] ?? "",
            isolatedAccount: environment["EASYSPLAT_ISOLATED_UI_RUNNER"] == "1"
        )
    }
}
