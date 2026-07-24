import AppKit
import EasySplatCore
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

    private func choiceRequest() -> SubjectChoiceRequest {
        SubjectChoiceRequest(
            keyframeImageURL: URL(fileURLWithPath: "/tmp/keyframe.png"),
            combinedInstanceLabelMaskURL: URL(fileURLWithPath: "/tmp/mask.png"),
            pixelWidth: 4,
            pixelHeight: 2,
            candidates: [
                SubjectChoiceRequest.Candidate(
                    componentIdentity: "subject",
                    instanceLabel: 3,
                    confidence: 0.9
                ),
            ]
        )
    }
}

private struct SubjectViewerToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        throw CancellationError()
    }
}
