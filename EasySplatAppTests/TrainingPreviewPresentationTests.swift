import EasySplatCore
import XCTest
@testable import EasySplatApp

@MainActor
final class TrainingPreviewPresentationTests: XCTestCase {
    private let bounds = SplatSceneBounds(
        center: .init(x: 1.25, y: -2.5, z: 3.75),
        radius: 8.5
    )

    private func makeModel(
        pressure: MemoryPressureState = .normal
    ) -> AppModel {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AppModel(projectBaseURL: base, memoryPressureProbe: { pressure })
    }

    private func publish(
        _ model: AppModel,
        publication: Int = 1,
        iteration: Int = 500
    ) {
        model.handle(event: .trainingPreviewPublished(
            url: URL(fileURLWithPath: "/tmp/preview.ply"),
            iteration: iteration,
            publication: publication,
            sceneBounds: bounds
        ))
    }

    func testPreviewOnlyMountsDuringTraining() {
        let model = makeModel()
        model.handle(event: .stageStarted(stage: .sfmMapping))
        publish(model)
        XCTAssertNil(model.trainingPreviewURL, "a preview outside training has nothing to describe")

        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)
        XCTAssertNotNil(model.trainingPreviewURL)
        XCTAssertTrue(model.isTrainingPreviewVisible)
    }

    /// The whole feature depends on this: without bounds the viewer refuses the
    /// scene and the canvas renders blank.
    func testPreviewIsNotVisibleWithoutBounds() {
        let model = makeModel()
        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)
        XCTAssertNotNil(ProcessingView.viewerBounds(model.trainingPreviewSceneBounds))

        model.clearTrainingPreview()
        XCTAssertFalse(model.isTrainingPreviewVisible)
        XCTAssertNil(ProcessingView.viewerBounds(model.trainingPreviewSceneBounds))
    }

    func testDegenerateBoundsAreRefusedRatherThanMountedBlank() {
        XCTAssertNil(ProcessingView.viewerBounds(nil))
        XCTAssertNil(ProcessingView.viewerBounds(
            SplatSceneBounds(center: .init(x: 0, y: 0, z: 0), radius: 0)
        ))
        XCTAssertNil(ProcessingView.viewerBounds(
            SplatSceneBounds(center: .init(x: .nan, y: 0, z: 0), radius: 1)
        ))
    }

    func testPreviewIsReleasedWhenMemoryPressureLeavesNormal() {
        let model = makeModel(pressure: .warning)
        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)
        XCTAssertNil(model.trainingPreviewURL, "training memory outranks the preview")
        XCTAssertTrue(model.isTrainingPreviewMemoryRefused)
    }

    /// Once released it stays released for the run: flapping back in would let the
    /// preview bid against the trainer again at the worst possible moment.
    func testReleasedPreviewDoesNotReturnWhilePressureRecovers() {
        let probe = PressureBox(.normal)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(projectBaseURL: base, memoryPressureProbe: { probe.value })

        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model, publication: 1)
        XCTAssertNotNil(model.trainingPreviewURL)

        probe.value = .critical
        publish(model, publication: 2)
        XCTAssertNil(model.trainingPreviewURL)

        probe.value = .normal
        publish(model, publication: 3)
        XCTAssertNil(model.trainingPreviewURL)
    }

    func testUnknownPressureFailsClosed() {
        let model = makeModel(pressure: .unknown)
        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)
        XCTAssertNil(model.trainingPreviewURL, "a failed observation is not evidence of calm")
    }

    /// A failed decode arrives after the canvas has already taken the workspace.
    /// Without a fallback the run just looks broken for the rest of training.
    func testFailedPreviewLoadReturnsTheProcessingWorkspace() {
        let model = makeModel()
        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)
        XCTAssertTrue(model.isTrainingPreviewVisible)

        model.releaseTrainingPreview(reason: "decode failed")
        XCTAssertFalse(model.isTrainingPreviewVisible)
        XCTAssertNil(model.trainingPreviewURL)
        XCTAssertTrue(
            model.logLines.contains { $0.contains("training is unaffected") },
            "the log should say the run itself is fine"
        )

        publish(model, publication: 2)
        XCTAssertNil(model.trainingPreviewURL, "a released preview stays released for the run")
    }

    /// Regression: a publisher that dies after succeeding once used to leave the
    /// last frame on screen indefinitely, presented as the live model.
    func testPreviewDisabledAfterASuccessfulPublicationStopsAdvertisingItAsLive() {
        let model = makeModel()
        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)
        XCTAssertTrue(model.isTrainingPreviewAvailable)

        model.handle(event: .trainingPreviewDisabled(reason: "disk full"))

        XCTAssertFalse(model.isTrainingPreviewAvailable, "a frozen preview is not a live one")
        XCTAssertFalse(model.isTrainingPreviewVisible)
        XCTAssertNil(model.trainingPreviewURL)
        XCTAssertTrue(model.logLines.contains { $0.contains("disk full") })
    }

    func testToggleTitleNamesTheResultingState() {
        XCTAssertEqual(
            ProcessingView.previewToggleTitle(isShown: true, isAvailable: true),
            "Hide Preview"
        )
        XCTAssertEqual(
            ProcessingView.previewToggleTitle(isShown: false, isAvailable: true),
            "Show Preview"
        )
        // Nothing to hide when the run has no preview, whatever the stored
        // preference says.
        XCTAssertEqual(
            ProcessingView.previewToggleTitle(isShown: true, isAvailable: false),
            "Show Preview"
        )
    }

    /// Regression: the display preference used to be captured as the run's
    /// publication policy, so a run started while hidden could never produce a
    /// preview and Show Preview was inert for its whole duration.
    func testShowPreviewWorksOnARunThatStartedHidden() {
        let model = makeModel()
        model.setTrainingPreviewShown(false)
        defer { model.setTrainingPreviewShown(true) }

        model.handle(event: .stageStarted(stage: .trainSplat))
        publish(model)

        // The publication still arrives; only the display was off.
        XCTAssertTrue(model.isTrainingPreviewAvailable)
        XCTAssertFalse(model.isTrainingPreviewVisible)

        model.setTrainingPreviewShown(true)
        XCTAssertTrue(model.isTrainingPreviewVisible, "Show Preview must work mid-run")
    }

    /// A run refused a preview must not offer a control that claims one exists.
    func testControlReportsUnavailableWhenNoPreviewWasPublished() {
        let model = makeModel()
        model.handle(event: .stageStarted(stage: .trainSplat))

        XCTAssertFalse(model.isTrainingPreviewAvailable)
        XCTAssertFalse(model.isTrainingPreviewVisible)
        XCTAssertEqual(
            ProcessingView.previewToggleTitle(
                isShown: model.isTrainingPreviewShown,
                isAvailable: model.isTrainingPreviewAvailable
            ),
            "Show Preview"
        )
        XCTAssertTrue(
            ProcessingView.previewToggleHelp(isAvailable: false).contains("training is unaffected")
        )
    }

    /// The guide keeps trainer counters out of product UI, and an iteration number
    /// would invite comparison against a result that does not exist yet.
    func testPreviewCaptionNamesNoIteration() {
        XCTAssertFalse(ProcessingView.previewCaption.contains(where: \.isNumber))
        XCTAssertTrue(ProcessingView.previewCaption.lowercased().contains("approximate"))
    }
}

private final class PressureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: MemoryPressureState

    init(_ value: MemoryPressureState) { storage = value }

    var value: MemoryPressureState {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
