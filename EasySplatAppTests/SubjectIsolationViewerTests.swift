import AppKit
import EasySplatCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatApp

final class SubjectIsolationViewerTests: XCTestCase {
    func testAspectFitHitTestingRejectsLetterboxAndMapsImageCoordinates() throws {
        let mask = try SubjectChoiceLabelMask(
            width: 4,
            height: 2,
            pixels: [
                0, 3, 3, 0,
                0, 0, 7, 7,
            ]
        )
        let request = choiceRequest()

        XCTAssertNil(SubjectChoiceSelectionResolver.anchor(
            at: CGPoint(x: 150, y: 50),
            in: CGSize(width: 300, height: 300),
            request: request,
            mask: mask
        ))

        let anchor = try XCTUnwrap(SubjectChoiceSelectionResolver.anchor(
            at: CGPoint(x: 112.5, y: 112.5),
            in: CGSize(width: 300, height: 300),
            request: request,
            mask: mask
        ))
        XCTAssertEqual(anchor.imageIdentity, "keyframe.png")
        XCTAssertEqual(anchor.instanceLabel, 3)
        XCTAssertEqual(anchor.normalizedX, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(anchor.normalizedY, 0.25, accuracy: 0.000_001)
    }

    func testHitTestingRejectsBackgroundAndUnadvertisedLabels() throws {
        let mask = try SubjectChoiceLabelMask(
            width: 2,
            height: 1,
            pixels: [0, 9]
        )
        let request = choiceRequest()

        XCTAssertNil(SubjectChoiceSelectionResolver.anchor(
            at: CGPoint(x: 25, y: 25),
            in: CGSize(width: 100, height: 50),
            request: request,
            mask: mask
        ))
        XCTAssertNil(SubjectChoiceSelectionResolver.anchor(
            at: CGPoint(x: 75, y: 25),
            in: CGSize(width: 100, height: 50),
            request: request,
            mask: mask
        ))
    }

    func testPointerSelectionUsesDeterministicCandidateAnchorRatherThanTappedPixel() throws {
        let mask = try SubjectChoiceLabelMask(
            width: 4,
            height: 3,
            pixels: [
                3, 0, 3, 0,
                0, 0, 0, 0,
                3, 0, 3, 0,
            ]
        )
        let request = SubjectChoiceRequest(
            keyframeImageURL: URL(fileURLWithPath: "/tmp/keyframe.png"),
            combinedInstanceLabelMaskURL: URL(fileURLWithPath: "/tmp/mask.png"),
            pixelWidth: 4,
            pixelHeight: 3,
            candidates: [
                SubjectChoiceRequest.Candidate(
                    componentIdentity: "subject",
                    instanceLabel: 3,
                    confidence: 0.9
                ),
            ]
        )

        let anchor = try XCTUnwrap(SubjectChoiceSelectionResolver.anchor(
            at: CGPoint(x: 62.5, y: 50),
            in: CGSize(width: 100, height: 60),
            request: request,
            mask: mask
        ))

        XCTAssertEqual(anchor.instanceLabel, 3)
        XCTAssertEqual(anchor.normalizedX, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(anchor.normalizedY, 1.0 / 6.0, accuracy: 0.000_001)
    }

    func testSelectionFailsClosedForInvalidCandidateAdvertisements() throws {
        let mask = try SubjectChoiceLabelMask(width: 1, height: 1, pixels: [3])
        let point = CGPoint(x: 10, y: 10)
        let size = CGSize(width: 20, height: 20)

        for labels: [UInt8] in [[0, 3], [3, 3], [3, 7]] {
            let request = choiceRequest(width: 1, height: 1, labels: labels)
            XCTAssertNil(
                SubjectChoiceSelectionResolver.anchor(
                    at: point,
                    in: size,
                    request: request,
                    mask: mask
                ),
                "Expected labels \(labels) to invalidate the entire preview"
            )
        }

        XCTAssertNil(SubjectChoiceSelectionResolver.anchor(
            at: point,
            in: size,
            request: choiceRequest(width: 1, height: 2, labels: [3]),
            mask: mask
        ))
    }

    func testPreviewKeepsCoordinatorOrderAndUsesCanonicalRealPixelCenters() throws {
        let mask = try SubjectChoiceLabelMask(
            width: 4,
            height: 4,
            pixels: [
                3, 0, 3, 0,
                0, 0, 0, 0,
                3, 0, 3, 0,
                0, 0, 0, 7,
            ]
        )
        let request = choiceRequest(width: 4, height: 4, labels: [7, 3])

        let preview = try XCTUnwrap(SubjectChoicePreview(
            request: request,
            mask: mask,
            imagePixelSize: CGSize(width: 4, height: 4)
        ))

        XCTAssertEqual(preview.options.map(\.ordinal), [1, 2])
        XCTAssertEqual(preview.options.map(\.anchor.instanceLabel), [7, 3])
        XCTAssertEqual(preview.options[0].anchor.normalizedX, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(preview.options[0].anchor.normalizedY, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(preview.options[1].anchor.normalizedX, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(preview.options[1].anchor.normalizedY, 0.125, accuracy: 0.000_001)
    }

    func testPreviewTraversesMaskExactlyTwiceForOneAndManyCandidates() throws {
        let pixels = (1...255).map(UInt8.init)
        let mask = try SubjectChoiceLabelMask(
            width: pixels.count,
            height: 1,
            pixels: pixels
        )

        for candidateCount in [1, 64, 255] {
            var visitsByPass = [Int: Int]()
            let preview = try XCTUnwrap(SubjectChoicePreview(
                request: choiceRequest(
                    width: pixels.count,
                    height: 1,
                    labels: Array(pixels.prefix(candidateCount))
                ),
                mask: mask,
                imagePixelSize: CGSize(width: pixels.count, height: 1),
                onMaskPixelVisit: { pass, _ in
                    visitsByPass[pass, default: 0] += 1
                }
            ))

            XCTAssertEqual(visitsByPass, [1: pixels.count, 2: pixels.count])
            XCTAssertEqual(preview.options.count, candidateCount)
            XCTAssertEqual(
                preview.outlineAlpha,
                [UInt8](repeating: 255, count: candidateCount)
                    + [UInt8](repeating: 0, count: pixels.count - candidateCount)
            )
            XCTAssertEqual(
                try XCTUnwrap(preview.options.first?.anchor.normalizedX),
                0.5 / Double(pixels.count),
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                try XCTUnwrap(preview.options.last?.anchor.normalizedX),
                (Double(candidateCount) - 0.5) / Double(pixels.count),
                accuracy: 0.000_001
            )
        }
    }

    func testPreviewRejectsAnImageWithDifferentPixelDimensions() throws {
        let mask = try SubjectChoiceLabelMask(width: 2, height: 1, pixels: [3, 3])

        XCTAssertNil(SubjectChoicePreview(
            request: choiceRequest(width: 2, height: 1),
            mask: mask,
            imagePixelSize: CGSize(width: 1, height: 2)
        ))
    }

    func testAspectFitTransformMapsInputAndControlPositionsThroughOneImageRect() throws {
        let transform = try XCTUnwrap(SubjectChoiceAspectFitTransform(
            containerSize: CGSize(width: 300, height: 300),
            imageSize: CGSize(width: 4, height: 2)
        ))

        XCTAssertEqual(transform.imageRect, CGRect(x: 0, y: 75, width: 300, height: 150))
        XCTAssertNil(transform.normalizedImagePoint(at: CGPoint(x: 150, y: 50)))
        XCTAssertEqual(
            transform.normalizedImagePoint(at: CGPoint(x: 112.5, y: 112.5)),
            CGPoint(x: 0.375, y: 0.25)
        )
        XCTAssertEqual(
            transform.point(for: CGPoint(x: 0.375, y: 0.25)),
            CGPoint(x: 112.5, y: 112.5)
        )
    }

    func testOutlineKeepsCandidateBoundaryAndDropsInteriorAndOtherLabels() throws {
        let mask = try SubjectChoiceLabelMask(
            width: 5,
            height: 5,
            pixels: [
                9, 9, 9, 9, 9,
                9, 3, 3, 3, 9,
                9, 3, 3, 3, 9,
                9, 3, 3, 3, 9,
                9, 9, 9, 9, 9,
            ]
        )

        let alpha = mask.outlineAlpha(allowedLabels: [3])

        XCTAssertEqual(alpha[0], 0)
        XCTAssertEqual(alpha[6], 255)
        XCTAssertEqual(alpha[12], 0)
    }

    func testCandidateAccessibilityProvidesExactSemanticValues() {
        let anchor = SubjectAnchor(
            imageIdentity: "keyframe.png",
            instanceLabel: 3,
            normalizedX: 0.125,
            normalizedY: 0.125
        )
        let unselected = SubjectChoiceCandidateAccessibility(
            ordinal: 1,
            totalCount: 2,
            anchor: anchor,
            isSelected: false
        )
        let selected = SubjectChoiceCandidateAccessibility(
            ordinal: 1,
            totalCount: 2,
            anchor: anchor,
            isSelected: true
        )

        XCTAssertEqual(unselected.identifier, "subjectChoice.candidate.1")
        XCTAssertEqual(unselected.label, "Subject candidate 1 of 2, upper left")
        XCTAssertEqual(unselected.value, "Not selected")
        XCTAssertEqual(unselected.hint, "Selects this subject.")
        XCTAssertEqual(selected.value, "Selected")
    }

    func testKeyboardIntentInitiallyFocusesFirstCandidateWithoutSelecting() {
        var state = SubjectChoiceInteractionState()

        XCTAssertNil(state.reduce(.appeared(firstCandidateOrdinal: 1)))
        XCTAssertEqual(state.focusedCandidateOrdinal, 1)
        XCTAssertNil(state.selectedAnchor)
        XCTAssertFalse(state.canSubmit)
    }

    func testSpaceOrAccessibilityActivationSelectsAndMovesFocus() {
        let anchor = subjectAnchor(label: 7)
        var state = SubjectChoiceInteractionState()

        XCTAssertNil(state.reduce(.activateCandidate(ordinal: 2, anchor: anchor)))
        XCTAssertEqual(state.focusedCandidateOrdinal, 2)
        XCTAssertEqual(state.selectedAnchor, anchor)
        XCTAssertTrue(state.canSubmit)
    }

    func testReturnIntentRequiresSelectionBeforeIsolating() {
        let anchor = subjectAnchor(label: 3)
        var state = SubjectChoiceInteractionState()

        XCTAssertNil(state.reduce(.submit))
        XCTAssertNil(state.reduce(.activateCandidate(ordinal: 1, anchor: anchor)))
        XCTAssertEqual(state.reduce(.submit), .isolate(anchor))
    }

    func testEscapeIntentCancelsWithOrWithoutSelection() {
        let anchor = subjectAnchor(label: 3)
        var state = SubjectChoiceInteractionState()

        XCTAssertEqual(state.reduce(.cancel), .cancel)
        XCTAssertNil(state.reduce(.activateCandidate(ordinal: 1, anchor: anchor)))
        XCTAssertEqual(state.reduce(.cancel), .cancel)
    }

    @MainActor
    func testHostedPreviewExposesOrderedAccessibleCandidateButtons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("keyframe.png")
        let maskURL = directory.appendingPathComponent("mask.png")
        try writeSubjectChoiceRGBImage(at: imageURL, width: 2, height: 2)
        try writeSubjectChoiceMask(
            at: maskURL,
            width: 2,
            height: 2,
            pixels: [3, 0, 0, 7]
        )

        let request = SubjectChoiceRequest(
            keyframeImageURL: imageURL,
            combinedInstanceLabelMaskURL: maskURL,
            pixelWidth: 2,
            pixelHeight: 2,
            candidates: [
                .init(componentIdentity: "first", instanceLabel: 3, confidence: 0.9),
                .init(componentIdentity: "second", instanceLabel: 7, confidence: 0.8),
            ]
        )
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ))
        let loadedMask = try SubjectChoiceLabelMask(
            contentsOf: maskURL,
            expectedWidth: 2,
            expectedHeight: 2
        )
        XCTAssertNotNil(SubjectChoicePreview(
            request: request,
            mask: loadedMask,
            imagePixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        ))
        var canceledCount = 0
        var isolatedAnchors = [SubjectAnchor]()
        let previewPresented = expectation(description: "Subject preview presented")
        let host = NSHostingView(rootView: SubjectChoiceSheet(
            request: request,
            onCancel: { canceledCount += 1 },
            onIsolate: { isolatedAnchors.append($0) },
            onPreviewPresented: { previewPresented.fulfill() }
        ))
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        defer {
            window.orderOut(nil)
            _ = application.setActivationPolicy(originalActivationPolicy)
        }
        try requireActiveTestWindow(window)
        await fulfillment(of: [previewPresented], timeout: 1)
        await Task.yield()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let elements = accessibilityDescendants(of: host)
        XCTAssertFalse(elements.contains {
            accessibilityIdentifier(of: $0) == "subjectChoice.gesture"
        })
        let group = try XCTUnwrap(elements.first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidates"
        }, accessibilityDebugTree(of: host))
        let candidateElements = accessibilityDescendants(of: group).filter {
            accessibilityIdentifier(of: $0)?.hasPrefix("subjectChoice.candidate.") == true
        }
        XCTAssertEqual(
            candidateElements.compactMap(accessibilityIdentifier),
            ["subjectChoice.candidate.1", "subjectChoice.candidate.2"]
        )
        let firstCandidate = try XCTUnwrap(candidateElements.first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.1"
        })
        let secondCandidate = try XCTUnwrap(candidateElements.first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.2"
        })

        XCTAssertEqual(accessibilityRole(of: group), NSAccessibility.Role.group)
        XCTAssertEqual(accessibilityLabel(of: group), "Subject candidates")
        XCTAssertEqual(accessibilityRole(of: firstCandidate), NSAccessibility.Role.button)
        XCTAssertEqual(accessibilityRole(of: secondCandidate), NSAccessibility.Role.button)
        XCTAssertEqual(accessibilityLabel(of: firstCandidate), "Subject candidate 1 of 2, upper left")
        XCTAssertEqual(accessibilityValue(of: firstCandidate) as? String, "Not selected")
        XCTAssertEqual(accessibilityHelp(of: firstCandidate), "Selects this subject.")
        XCTAssertEqual(accessibilityValue(of: secondCandidate) as? String, "Not selected")
        XCTAssertFalse(firstCandidate is NSView)
        XCTAssertFalse(firstCandidate is NSAccessibilityElement)
        XCTAssertTrue(firstCandidate is NSObject)
        XCTAssertTrue(accessibilityIsFocused(firstCandidate), accessibilityDebugTree(of: host))

        sendKey(.return, to: window)
        XCTAssertTrue(isolatedAnchors.isEmpty)

        sendKey(.space, to: window)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let spaceSelectedElements = accessibilityDescendants(of: host)
        XCTAssertNotNil(spaceSelectedElements.first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.1"
                && accessibilityValue(of: $0) as? String == "Selected"
        })
        XCTAssertTrue(isolatedAnchors.isEmpty)

        let currentSecondCandidate = try XCTUnwrap(
            accessibilityDescendants(of: host).first {
                accessibilityIdentifier(of: $0) == "subjectChoice.candidate.2"
            },
            accessibilityDebugTree(of: host)
        )
        XCTAssertTrue(accessibilityPerformPress(on: currentSecondCandidate))

        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let selectedElements = accessibilityDescendants(of: host)
        let selectedCandidate = try XCTUnwrap(selectedElements.first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.2"
        })
        XCTAssertEqual(accessibilityValue(of: selectedCandidate) as? String, "Selected")

        sendKey(.return, to: window)
        XCTAssertEqual(isolatedAnchors.map(\.instanceLabel), [7])

        sendKey(.escape, to: window)
        XCTAssertEqual(canceledCount, 1)
    }

    @MainActor
    func testHostedCandidateMarkerUsesExact28PointHitArea() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("keyframe.png")
        let maskURL = directory.appendingPathComponent("mask.png")
        let dimension = 100
        var pixels = [UInt8](repeating: 0, count: dimension * dimension)
        pixels[50 * dimension + 50] = 3
        try writeSubjectChoiceRGBImage(at: imageURL, width: dimension, height: dimension)
        try writeSubjectChoiceMask(
            at: maskURL,
            width: dimension,
            height: dimension,
            pixels: pixels
        )
        let request = SubjectChoiceRequest(
            keyframeImageURL: imageURL,
            combinedInstanceLabelMaskURL: maskURL,
            pixelWidth: dimension,
            pixelHeight: dimension,
            candidates: [
                .init(componentIdentity: "subject", instanceLabel: 3, confidence: 0.9),
            ]
        )
        let previewPresented = expectation(description: "Subject preview presented")
        let host = NSHostingView(rootView: SubjectChoiceSheet(
            request: request,
            onCancel: {},
            onIsolate: { _ in },
            onPreviewPresented: { previewPresented.fulfill() }
        ))
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        defer {
            window.orderOut(nil)
            _ = application.setActivationPolicy(originalActivationPolicy)
        }
        try requireActiveTestWindow(window)
        await fulfillment(of: [previewPresented], timeout: 1)
        await Task.yield()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let initialElements = accessibilityDescendants(of: host)
        let candidate = try XCTUnwrap(initialElements.first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.1"
        }, accessibilityDebugTree(of: host))
        let candidateFrame = accessibilityFrame(of: candidate)
        XCTAssertEqual(candidateFrame.width, 28, accuracy: 0.5)
        XCTAssertEqual(candidateFrame.height, 28, accuracy: 0.5)

        sendMouseClick(
            atScreenPoint: CGPoint(x: candidateFrame.midX, y: candidateFrame.midY),
            to: window
        )
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(accessibilityDescendants(of: host).first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.1"
                && accessibilityValue(of: $0) as? String == "Selected"
        })

        sendMouseClick(
            atScreenPoint: CGPoint(x: candidateFrame.midX + 17, y: candidateFrame.midY),
            to: window
        )
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(accessibilityDescendants(of: host).first {
            accessibilityIdentifier(of: $0) == "subjectChoice.candidate.1"
                && accessibilityValue(of: $0) as? String == "Not selected"
        })
    }

    func testVariantPickerAppearsOnlyWhenSubjectOutputExists() {
        XCTAssertEqual(
            ViewerView.availableOutputVariants(hasSubjectOutput: false),
            [.original]
        )
        XCTAssertEqual(
            ViewerView.availableOutputVariants(hasSubjectOutput: true),
            [.original, .subject]
        )
    }

    @MainActor
    func testViewMenuMirrorsVariantAvailabilityAndSelection() throws {
        let model = AppModel(toolchainManager: SubjectViewerToolchainManager())
        model.viewState = .viewer
        model.outputPlyURL = URL(fileURLWithPath: "/tmp/original.ply")
        let delegate = AppDelegate(model: model)
        let mainMenu = delegate.makeMainMenu(for: NSApplication.shared)
        let viewMenu = mainMenu.items
            .compactMap(\.submenu)
            .first { $0.title == "View" }
        let originalItem = viewMenu?.items.first { $0.title == "Show Original" }
        let subjectItem = viewMenu?.items.first { $0.title == "Show Subject" }

        XCTAssertNotNil(originalItem)
        XCTAssertNotNil(subjectItem)
        XCTAssertTrue(delegate.validateMenuItem(try XCTUnwrap(originalItem)))
        XCTAssertEqual(originalItem?.state, .on)
        XCTAssertFalse(delegate.validateMenuItem(try XCTUnwrap(subjectItem)))
        XCTAssertEqual(subjectItem?.state, .off)

        model.subjectOutput = ValidatedSplatOutput(
            variant: .subject,
            url: URL(fileURLWithPath: "/tmp/isolated.ply"),
            sha256: String(repeating: "a", count: 64),
            byteCount: 120,
            gaussianCount: 4,
            sceneBounds: SplatSceneBounds(
                center: ScenePoint3D(x: 1, y: 2, z: 3),
                radius: 4
            )
        )
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))

        XCTAssertTrue(delegate.validateMenuItem(try XCTUnwrap(originalItem)))
        XCTAssertEqual(originalItem?.state, .off)
        XCTAssertTrue(delegate.validateMenuItem(try XCTUnwrap(subjectItem)))
        XCTAssertEqual(subjectItem?.state, .on)
    }

    private func choiceRequest(
        width: Int = 4,
        height: Int = 2,
        labels: [UInt8] = [3]
    ) -> SubjectChoiceRequest {
        SubjectChoiceRequest(
            keyframeImageURL: URL(fileURLWithPath: "/tmp/keyframe.png"),
            combinedInstanceLabelMaskURL: URL(fileURLWithPath: "/tmp/mask.png"),
            pixelWidth: width,
            pixelHeight: height,
            candidates: labels.map {
                SubjectChoiceRequest.Candidate(
                    componentIdentity: "subject",
                    instanceLabel: $0,
                    confidence: 0.9
                )
            }
        )
    }

    private func subjectAnchor(label: UInt8) -> SubjectAnchor {
        SubjectAnchor(
            imageIdentity: "keyframe.png",
            instanceLabel: label,
            normalizedX: 0.25,
            normalizedY: 0.25
        )
    }
}

private struct SubjectViewerToolchainManager: ToolchainManaging {
    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        throw CancellationError()
    }
}

@MainActor
private func accessibilityDescendants(of element: Any) -> [Any] {
    var result = [Any]()
    var queue = accessibilityChildren(of: element).map { ($0, 1) }
    var nextIndex = 0
    var visited = Set<ObjectIdentifier>()

    while nextIndex < queue.count, result.count < 512 {
        let (current, depth) = queue[nextIndex]
        nextIndex += 1
        if let object = current as AnyObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
        }
        result.append(current)
        if depth < 32 {
            queue.append(contentsOf: accessibilityChildren(of: current).map {
                ($0, depth + 1)
            })
        }
    }
    return result
}

@MainActor
private func accessibilityChildren(of element: Any) -> [Any] {
    if let accessible = element as? any NSAccessibilityProtocol {
        return accessible.accessibilityChildren() ?? []
    }
    return accessibilityObjectValue(
        of: element,
        selectorName: "accessibilityChildren"
    ) as? [Any] ?? []
}

@MainActor
private func accessibilityIdentifier(of element: Any) -> String? {
    if let accessible = element as? any NSAccessibilityProtocol,
       let identifier = accessible.accessibilityIdentifier() {
        return identifier
    }
    return accessibilityObjectValue(
        of: element,
        selectorName: "accessibilityIdentifier"
    ) as? String
}

@MainActor
private func accessibilityRole(of element: Any) -> NSAccessibility.Role? {
    if let accessible = element as? any NSAccessibilityProtocol,
       let role = accessible.accessibilityRole() {
        return role
    }
    guard let rawValue = accessibilityObjectValue(
        of: element,
        selectorName: "accessibilityRole"
    ) as? String else {
        return nil
    }
    return NSAccessibility.Role(rawValue: rawValue)
}

@MainActor
private func accessibilityLabel(of element: Any) -> String? {
    if let accessible = element as? any NSAccessibilityProtocol,
       let label = accessible.accessibilityLabel() {
        return label
    }
    return accessibilityObjectValue(
        of: element,
        selectorName: "accessibilityLabel"
    ) as? String
}

@MainActor
private func accessibilityValue(of element: Any) -> Any? {
    if let accessible = element as? any NSAccessibilityProtocol,
       let value = accessible.accessibilityValue() {
        return value
    }
    return accessibilityObjectValue(
        of: element,
        selectorName: "accessibilityValue"
    )
}

@MainActor
private func accessibilityHelp(of element: Any) -> String? {
    if let accessible = element as? any NSAccessibilityProtocol,
       let help = accessible.accessibilityHelp() {
        return help
    }
    return accessibilityObjectValue(
        of: element,
        selectorName: "accessibilityHelp"
    ) as? String
}

@MainActor
private func accessibilityPerformPress(on element: Any) -> Bool {
    if let accessible = element as? any NSAccessibilityProtocol {
        return accessible.accessibilityPerformPress()
    }
    return accessibilityBoolValue(
        of: element,
        selectorName: "accessibilityPerformPress"
    )
}

@MainActor
private func accessibilityIsFocused(_ element: Any) -> Bool {
    if let accessible = element as? any NSAccessibilityProtocol {
        return accessible.isAccessibilityFocused()
    }
    return accessibilityBoolValue(
        of: element,
        selectorName: "isAccessibilityFocused"
    )
}

@MainActor
private func accessibilityFrame(of element: Any) -> CGRect {
    if let accessible = element as? any NSAccessibilityProtocol {
        return accessible.accessibilityFrame()
    }
    guard let object = element as? NSObject else { return .zero }
    let selector = NSSelectorFromString("accessibilityFrame")
    guard object.responds(to: selector),
          let implementation = object.method(for: selector) else {
        return .zero
    }
    typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
    let getter = unsafeBitCast(implementation, to: FrameGetter.self)
    return getter(object, selector)
}

@MainActor
private func accessibilityObjectValue(
    of element: Any,
    selectorName: String
) -> Any? {
    guard let object = element as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
}

@MainActor
private func accessibilityBoolValue(
    of element: Any,
    selectorName: String
) -> Bool {
    guard let object = element as? NSObject else { return false }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          let implementation = object.method(for: selector) else {
        return false
    }
    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    let getter = unsafeBitCast(implementation, to: BoolGetter.self)
    return getter(object, selector)
}

@MainActor
private func accessibilityDebugTree(of element: Any, depth: Int = 0) -> String {
    ([element] + accessibilityDescendants(of: element)).map { current in
        let identifier = accessibilityIdentifier(of: current) ?? "nil"
        let label = accessibilityLabel(of: current) ?? "nil"
        let role = accessibilityRole(of: current)?.rawValue ?? "nil"
        let isProtocol = current is any NSAccessibilityProtocol
        let isObject = current is NSObject
        return "\(String(describing: type(of: current))) id=\(identifier) label=\(label) role=\(role) protocol=\(isProtocol) object=\(isObject)"
    }.joined(separator: "\n")
}

private enum SubjectChoiceTestKey {
    case escape
    case `return`
    case space

    var characters: String {
        switch self {
        case .escape: "\u{1B}"
        case .return: "\r"
        case .space: " "
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .escape: 53
        case .return: 36
        case .space: 49
        }
    }
}

@MainActor
private func sendKey(_ key: SubjectChoiceTestKey, to window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.keyCode
        ) else {
            XCTFail("Could not create \(key) key event")
            return
        }
        window.sendEvent(event)
    }
}

@MainActor
private func sendMouseClick(atScreenPoint screenPoint: CGPoint, to window: NSWindow) {
    let windowPoint = window.convertPoint(fromScreen: screenPoint)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            XCTFail("Could not create mouse event")
            return
        }
        window.sendEvent(event)
    }
}

@MainActor
private func requireActiveTestWindow(_ window: NSWindow) throws {
    let application = NSApplication.shared
    application.finishLaunching()
    guard application.setActivationPolicy(.regular) else {
        throw XCTSkip("Hosted accessibility requires a regular macOS app test host.")
    }
    window.orderFrontRegardless()
    window.makeKey()
    _ = NSRunningApplication.current.activate(options: .activateAllWindows)
    application.activate(ignoringOtherApps: true)
    guard application.isActive,
          NSRunningApplication.current.isActive,
          window.isKeyWindow else {
        throw XCTSkip("Hosted accessibility requires an active macOS app test host.")
    }
}

private func writeSubjectChoiceRGBImage(
    at url: URL,
    width: Int,
    height: Int
) throws {
    let pixels = [UInt8](repeating: 255, count: width * height * 4)
    try writeSubjectChoicePNG(
        at: url,
        width: width,
        height: height,
        pixels: pixels,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
}

private func writeSubjectChoiceMask(
    at url: URL,
    width: Int,
    height: Int,
    pixels: [UInt8]
) throws {
    try writeSubjectChoicePNG(
        at: url,
        width: width,
        height: height,
        pixels: pixels,
        bitsPerPixel: 8,
        bytesPerRow: width,
        colorSpace: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
    )
}

private func writeSubjectChoicePNG(
    at url: URL,
    width: Int,
    height: Int,
    pixels: [UInt8],
    bitsPerPixel: Int,
    bytesPerRow: Int,
    colorSpace: CGColorSpace,
    bitmapInfo: CGBitmapInfo
) throws {
    let data = Data(pixels)
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let image = try XCTUnwrap(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: bitsPerPixel,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}
