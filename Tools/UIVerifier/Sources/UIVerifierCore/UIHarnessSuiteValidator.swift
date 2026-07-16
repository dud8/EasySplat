import Foundation

public enum UIHarnessValidationError: Error, LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public enum UIHarnessSuiteValidator {
    public static func validate(_ results: [ScenarioVerificationResult]) throws {
        let appIdentities = Set(results.compactMap(\.app))
        guard appIdentities.count == 1,
              let app = appIdentities.first,
              results.allSatisfy({ $0.app == app }),
              (app.path as NSString).isAbsolutePath,
              app.bundleIdentifier == "com.easysplat.app",
              !app.version.isEmpty,
              app.executableSHA256.count == 64,
              app.executableSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UIHarnessValidationError.invalid("Scenario results do not identify one exact packaged app.")
        }
        let grouped = Dictionary(grouping: results, by: \.scenario)
        for scenario in UIVerificationScenario.allCases {
            guard grouped[scenario]?.count == 1, let result = grouped[scenario]?.first else {
                throw UIHarnessValidationError.invalid("Expected exactly one \(scenario.rawValue) result.")
            }
            let requiredInteractions = Set(UIVerificationInteraction.allCases)
            let observedIdentifiers = Set(result.observedControlIdentifiers)
            let requiredIdentifiers = UIVerificationWorkspace.allCases.reduce(into: Set<String>()) {
                $0.formUnion($1.requiredVisibleIdentifiers)
            }.union(["result.newSplat"])
            let projectRows = observedIdentifiers.filter { identifier in
                identifier.range(
                    of: #"^project\.row\.[0-9a-f]{16}$"#,
                    options: .regularExpression
                ) != nil
            }
            guard let viewerEvidence = result.viewerShortcutEvidence else {
                throw UIHarnessValidationError.invalid(
                    "Scenario \(scenario.rawValue) is missing viewer shortcut render evidence."
                )
            }
            try ViewerShortcutEvidenceValidator.validate(viewerEvidence)
            guard result.schemaVersion == 3,
                  result.runner.isReleaseLane,
                  result.observedAppearance == scenario.expectedAppearance,
                  result.observedReduceMotion == scenario.expectsReduceMotion,
                  result.observedIncreaseContrast == scenario.expectsIncreaseContrast,
                  result.observedDifferentiateWithoutColor == scenario.expectsDifferentiateWithoutColor,
                  result.accessibilityPermission,
                  result.screenCapturePermission,
                  result.keyboardActivationPassed,
                  result.focusOrder.contains("home.chooseInput"),
                  result.focusOrder.contains("processing.stop"),
                  result.focusOrder.contains("processing.technicalDetails"),
                  result.focusOrder.contains("result.viewer"),
                  result.longProjectTitleFound,
                  result.observedControlIdentifiers == Array(observedIdentifiers).sorted(),
                  observedIdentifiers.isSuperset(of: requiredIdentifiers),
                  projectRows.count >= 2,
                  result.passedInteractions.count == requiredInteractions.count,
                  Set(result.passedInteractions) == requiredInteractions,
                  viewerEvidence.viewport == VerificationViewport(width: 1_100, height: 760),
                  result.failures.isEmpty else {
                throw UIHarnessValidationError.invalid("Scenario \(scenario.rawValue) did not pass its declared environment and interaction checks.")
            }
            let requiredArtifactCount = UIVerificationWorkspace.allCases.count
                * VerificationViewport.required.count
            guard result.viewports.count == requiredArtifactCount else {
                throw UIHarnessValidationError.invalid("Scenario \(scenario.rawValue) has an unexpected viewport result.")
            }
            let byWorkspace = Dictionary(grouping: result.viewports, by: \.workspace)
            for workspace in UIVerificationWorkspace.allCases {
                guard let workspaceResults = byWorkspace[workspace],
                      workspaceResults.count == VerificationViewport.required.count else {
                    throw UIHarnessValidationError.invalid(
                        "Scenario \(scenario.rawValue) is missing \(workspace.rawValue) workspace evidence."
                    )
                }
                let viewports = Dictionary(grouping: workspaceResults, by: \.viewport)
                for required in VerificationViewport.required {
                    guard viewports[required]?.count == 1, let viewport = viewports[required]?.first else {
                        throw UIHarnessValidationError.invalid(
                            "Scenario \(scenario.rawValue) is missing \(workspace.rawValue) \(required.width)x\(required.height)."
                        )
                    }
                    guard abs(viewport.actualWidth - required.width) <= 2,
                          abs(viewport.actualHeight - required.height) <= 2,
                          !viewport.screenshotPath.isEmpty,
                          viewport.screenshotSizeBytes > 0,
                          !viewport.accessibilitySnapshotPath.isEmpty,
                          viewport.accessibilityNodeCount > 0,
                          (0...1).contains(viewport.averageLuminance),
                          viewport.accessibilityIssues.isEmpty else {
                        throw UIHarnessValidationError.invalid(
                            "Scenario \(scenario.rawValue) failed \(workspace.rawValue) viewport \(required.width)x\(required.height)."
                        )
                    }
                }
            }
        }
        guard results.count == UIVerificationScenario.allCases.count else {
            throw UIHarnessValidationError.invalid("Unexpected duplicate or unknown scenario results.")
        }

        let comparisonViewport = VerificationViewport(width: 1_100, height: 760)
        guard let light = results.first(where: { $0.scenario == .light })?.viewports.first(where: {
                  $0.workspace == .home && $0.viewport == comparisonViewport
              }),
              let dark = results.first(where: { $0.scenario == .dark })?.viewports.first(where: {
                  $0.workspace == .home && $0.viewport == comparisonViewport
              }),
              light.averageLuminance - dark.averageLuminance >= 0.12 else {
            throw UIHarnessValidationError.invalid("Light and dark screenshots are not visually distinguishable.")
        }
    }
}

public enum UIHarnessArtifactValidator {
    public static func validate(_ results: [ScenarioVerificationResult]) throws {
        var paths: Set<String> = []
        var workspaceHashes: [String: Set<String>] = [:]
        for result in results {
            for viewport in result.viewports {
                guard paths.insert(viewport.screenshotPath).inserted,
                      paths.insert(viewport.accessibilitySnapshotPath).inserted else {
                    throw UIHarnessValidationError.invalid("UI verification artifact paths are not unique.")
                }
                try validateRegularFile(
                    path: viewport.screenshotPath,
                    expectedSize: viewport.screenshotSizeBytes
                )
                try validateRegularFile(path: viewport.accessibilitySnapshotPath)
                let prefix = "\(result.scenario.rawValue)-\(viewport.workspace.rawValue)-\(viewport.viewport.width)x\(viewport.viewport.height)"
                guard URL(fileURLWithPath: viewport.screenshotPath).lastPathComponent == "\(prefix).png",
                      URL(fileURLWithPath: viewport.accessibilitySnapshotPath).lastPathComponent == "\(prefix)-accessibility.json" else {
                    throw UIHarnessValidationError.invalid(
                        "UI verification artifact name does not match its scenario, workspace, and viewport."
                    )
                }
                let screenshotMetadata = try validateScreenshot(
                    path: viewport.screenshotPath,
                    expectedWidth: viewport.viewport.width,
                    expectedHeight: viewport.viewport.height
                )
                let workspaceKey = "\(result.scenario.rawValue)|\(viewport.viewport.width)x\(viewport.viewport.height)"
                workspaceHashes[workspaceKey, default: []].insert(screenshotMetadata.sha256)
                try validateAccessibilitySnapshot(
                    path: viewport.accessibilitySnapshotPath,
                    expectedNodeCount: viewport.accessibilityNodeCount,
                    expectedWidth: viewport.actualWidth,
                    expectedHeight: viewport.actualHeight,
                    workspace: viewport.workspace,
                    expectedProjectRows: Set(result.observedControlIdentifiers.filter {
                        $0.hasPrefix("project.row.")
                    })
                )
            }
            guard let viewerEvidence = result.viewerShortcutEvidence else {
                throw UIHarnessValidationError.invalid(
                    "UI verification result is missing viewer shortcut evidence."
                )
            }
            try validateViewerEvidence(
                viewerEvidence,
                scenario: result.scenario,
                paths: &paths
            )
        }
        for result in results {
            for viewport in VerificationViewport.required {
                let key = "\(result.scenario.rawValue)|\(viewport.width)x\(viewport.height)"
                guard workspaceHashes[key]?.count == UIVerificationWorkspace.allCases.count else {
                    throw UIHarnessValidationError.invalid(
                        "Workspace screenshots must contain distinct pixels for \(result.scenario.rawValue) \(viewport.width)x\(viewport.height)."
                    )
                }
            }
        }
    }

    private static func validateScreenshot(
        path: String,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> ScreenshotEvidenceMetadata {
        let url = URL(fileURLWithPath: path)
        let metadata: ScreenshotEvidenceMetadata
        do {
            metadata = try ScreenshotEvidenceAnalyzer.metadata(at: url)
        } catch {
            throw UIHarnessValidationError.invalid(
                "UI verification screenshot is not a complete decodable image: \(path)"
            )
        }
        guard metadata.width == expectedWidth, metadata.height == expectedHeight else {
            throw UIHarnessValidationError.invalid(
                "UI verification screenshot pixels are \(metadata.width)x\(metadata.height), expected \(expectedWidth)x\(expectedHeight): \(path)"
            )
        }
        return metadata
    }

    private static func validateViewerEvidence(
        _ evidence: ViewerShortcutVerificationEvidence,
        scenario: UIVerificationScenario,
        paths: inout Set<String>
    ) throws {
        try ViewerShortcutEvidenceValidator.validate(evidence)
        let prefix = "\(scenario.rawValue)-viewer"
        guard URL(fileURLWithPath: evidence.baselineScreenshotPath).lastPathComponent
            == "\(prefix)-baseline-\(evidence.viewport.width)x\(evidence.viewport.height).png",
              paths.insert(evidence.baselineScreenshotPath).inserted else {
            throw UIHarnessValidationError.invalid(
                "Viewer baseline screenshot path is mislabeled or reused."
            )
        }
        try validateRegularFile(
            path: evidence.baselineScreenshotPath,
            expectedSize: evidence.baselineScreenshotSizeBytes
        )
        let baseline = try validateScreenshot(
            path: evidence.baselineScreenshotPath,
            expectedWidth: evidence.viewport.width,
            expectedHeight: evidence.viewport.height
        )
        guard baseline.sha256 == evidence.baselineScreenshotSHA256 else {
            throw UIHarnessValidationError.invalid("Viewer baseline screenshot digest does not match.")
        }

        let groups = Dictionary(uniqueKeysWithValues: evidence.groups.map { ($0.group, $0) })
        let references: [ViewerShortcutGroup: URL] = [
            .orbitPanZoom: URL(fileURLWithPath: evidence.baselineScreenshotPath),
            .fit: URL(fileURLWithPath: groups[.orbitPanZoom]!.screenshotPath),
            .reset: URL(fileURLWithPath: evidence.baselineScreenshotPath),
        ]
        for group in ViewerShortcutGroup.allCases {
            guard let item = groups[group], let reference = references[group],
                  URL(fileURLWithPath: item.screenshotPath).lastPathComponent
                    == "\(prefix)-\(group.rawValue)-\(evidence.viewport.width)x\(evidence.viewport.height).png",
                  paths.insert(item.screenshotPath).inserted else {
                throw UIHarnessValidationError.invalid(
                    "Viewer shortcut screenshot path is mislabeled or reused for \(group.rawValue)."
                )
            }
            try validateRegularFile(path: item.screenshotPath, expectedSize: item.screenshotSizeBytes)
            let metadata = try validateScreenshot(
                path: item.screenshotPath,
                expectedWidth: evidence.viewport.width,
                expectedHeight: evidence.viewport.height
            )
            let measuredDistance = try ScreenshotEvidenceAnalyzer.normalizedPixelDistance(
                between: reference,
                and: URL(fileURLWithPath: item.screenshotPath)
            )
            guard metadata.sha256 == item.screenshotSHA256,
                  abs(measuredDistance - item.normalizedPixelDistance) <= 1e-12 else {
                throw UIHarnessValidationError.invalid(
                    "Viewer shortcut screenshot evidence does not match for \(group.rawValue)."
                )
            }
        }
    }

    private static func validateAccessibilitySnapshot(
        path: String,
        expectedNodeCount: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        workspace: UIVerificationWorkspace,
        expectedProjectRows: Set<String>
    ) throws {
        let nodes: [AccessibilityNodeSnapshot]
        do {
            nodes = try JSONDocument.read(
                [AccessibilityNodeSnapshot].self,
                from: URL(fileURLWithPath: path)
            )
        } catch {
            throw UIHarnessValidationError.invalid(
                "UI verification accessibility snapshot is not valid JSON: \(path)"
            )
        }
        guard !nodes.isEmpty, nodes.count == expectedNodeCount else {
            throw UIHarnessValidationError.invalid(
                "UI verification accessibility node count does not match its artifact: \(path)"
            )
        }
        guard let rootFrame = nodes.first(where: { $0.order == 0 })?.frame,
              !rootFrame.isEmpty,
              abs(rootFrame.width - CGFloat(expectedWidth)) <= 2,
              abs(rootFrame.height - CGFloat(expectedHeight)) <= 2 else {
            throw UIHarnessValidationError.invalid(
                "UI verification accessibility snapshot has no matching root window frame: \(path)"
            )
        }
        let auditedIssues = AccessibilityAudit.issues(
            nodes: nodes,
            windowFrame: rootFrame,
            longProjectTitle: UIVerificationFixture.longProjectTitle,
            workspace: workspace
        )
        guard auditedIssues.isEmpty else {
            throw UIHarnessValidationError.invalid(
                "UI verification accessibility snapshot failed its stored-frame audit: \(path)"
            )
        }
        let identifiers = Dictionary(grouping: nodes.compactMap(\.identifier), by: { $0 })
        for required in workspace.requiredVisibleIdentifiers where identifiers[required]?.count != 1 {
            throw UIHarnessValidationError.invalid(
                "UI verification accessibility snapshot is missing \(required): \(path)"
            )
        }
        if workspace == .home {
            guard expectedProjectRows.count >= 2 else {
                throw UIHarnessValidationError.invalid(
                    "UI verification result does not identify its ready and failure project rows."
                )
            }
            for row in expectedProjectRows where identifiers[row]?.count != 1 {
                throw UIHarnessValidationError.invalid(
                    "UI verification Home snapshot is missing project row \(row): \(path)"
                )
            }
            let longTitleFound = nodes.contains { node in
                [node.title, node.label, node.value]
                    .compactMap { $0 }
                    .contains { $0.contains(UIVerificationFixture.longProjectTitle) }
            }
            guard longTitleFound else {
                throw UIHarnessValidationError.invalid(
                    "UI verification Home snapshot is missing the long-title fixture: \(path)"
                )
            }
        }
    }

    private static func validateRegularFile(path: String, expectedSize: Int64? = nil) throws {
        let url = URL(fileURLWithPath: path)
        guard url.path == path, (path as NSString).isAbsolutePath else {
            throw UIHarnessValidationError.invalid("UI verification artifact path is not absolute: \(path)")
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        let actualSize = Int64(values.fileSize ?? 0)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              actualSize > 0,
              expectedSize == nil || actualSize == expectedSize else {
            throw UIHarnessValidationError.invalid("UI verification artifact is missing or invalid: \(path)")
        }
    }
}
