#if canImport(XCTest)
import XCTest
@testable import EasySplatApp

final class TrainingLivePreviewStateTests: XCTestCase {
    func testStateBeginsInWaitingMode() {
        let state = TrainingLivePreviewState()
        XCTAssertFalse(state.hasDetectedSnapshot)
        XCTAssertFalse(state.hasRenderedPreview)
        XCTAssertFalse(state.shouldCreateViewerSurface)
        XCTAssertNil(state.lastLoadError)
        XCTAssertEqual(state.pollIntervalSeconds, 5.0)
    }

    func testStateTransitionsToReadyAfterLoad() {
        var state = TrainingLivePreviewState()
        let start = Date()
        let firstFingerprint = SnapshotFingerprint(modifiedAt: start, fileSize: 42)
        state.ingestFingerprint(firstFingerprint, now: start, isLoadable: true)
        XCTAssertEqual(state.reloadToken, 0)
        XCTAssertFalse(state.isLoading)

        state.ingestFingerprint(firstFingerprint, now: start.addingTimeInterval(2), isLoadable: true)
        XCTAssertTrue(state.hasDetectedSnapshot)
        XCTAssertEqual(state.reloadToken, 1)
        XCTAssertTrue(state.isLoading)

        state.ingestLoadState(.ready)
        XCTAssertTrue(state.hasRenderedPreview)
        XCTAssertTrue(state.shouldCreateViewerSurface)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.lastLoadError)
        XCTAssertEqual(state.pollIntervalSeconds, 5.0)
    }

    func testStableExistingSnapshotLoadsImmediatelyOnFirstDetection() {
        var state = TrainingLivePreviewState()
        let modifiedAt = Date(timeIntervalSince1970: 1_726_000_000)
        let now = modifiedAt.addingTimeInterval(10)
        let fingerprint = SnapshotFingerprint(modifiedAt: modifiedAt, fileSize: 42)

        state.ingestFingerprint(fingerprint, now: now, isLoadable: true)

        XCTAssertTrue(state.hasDetectedSnapshot)
        XCTAssertEqual(state.reloadToken, 1)
        XCTAssertTrue(state.isLoading)
    }

    func testFreshSnapshotStillWaitsForStabilityWindowBeforeFirstLoad() {
        var state = TrainingLivePreviewState()
        let modifiedAt = Date(timeIntervalSince1970: 1_726_000_000)
        let fingerprint = SnapshotFingerprint(modifiedAt: modifiedAt, fileSize: 42)

        state.ingestFingerprint(fingerprint, now: modifiedAt.addingTimeInterval(0.5), isLoadable: true)
        XCTAssertEqual(state.reloadToken, 0)
        XCTAssertFalse(state.isLoading)

        state.ingestFingerprint(fingerprint, now: modifiedAt.addingTimeInterval(2.7), isLoadable: true)
        XCTAssertEqual(state.reloadToken, 1)
        XCTAssertTrue(state.isLoading)
    }

    func testFailureBeforeFirstRenderClearsOnNewSnapshot() {
        var state = TrainingLivePreviewState()
        let start = Date()
        let firstFingerprint = SnapshotFingerprint(modifiedAt: start, fileSize: 1)
        state.ingestFingerprint(firstFingerprint, now: start, isLoadable: true)
        state.ingestFingerprint(firstFingerprint, now: start.addingTimeInterval(2), isLoadable: true)
        state.ingestLoadState(.failed("invalid ply"))
        XCTAssertFalse(state.hasRenderedPreview)
        XCTAssertEqual(state.lastLoadError, "invalid ply")

        let secondFingerprint = SnapshotFingerprint(modifiedAt: start.addingTimeInterval(2), fileSize: 2)
        state.ingestFingerprint(secondFingerprint, now: start.addingTimeInterval(3), isLoadable: true)
        state.ingestFingerprint(secondFingerprint, now: start.addingTimeInterval(5), isLoadable: true)
        XCTAssertNil(state.lastLoadError)
        XCTAssertTrue(state.isLoading)
        XCTAssertEqual(state.reloadToken, 2)
    }

    func testFailureAfterRenderKeepsRenderedPreview() {
        var state = TrainingLivePreviewState()
        let start = Date()
        let fingerprint = SnapshotFingerprint(modifiedAt: start, fileSize: 1)
        state.ingestFingerprint(fingerprint, now: start, isLoadable: true)
        state.ingestFingerprint(fingerprint, now: start.addingTimeInterval(2), isLoadable: true)
        state.ingestLoadState(.ready)
        XCTAssertTrue(state.hasRenderedPreview)

        state.ingestLoadState(.failed("temporary load issue"))
        XCTAssertTrue(state.hasRenderedPreview)
        XCTAssertEqual(state.lastLoadError, "temporary load issue")
    }

    func testPlaceholderMessageUsesLatestPreviewCopyWhenSnapshotDetectedAndLoading() {
        var state = TrainingLivePreviewState()
        let start = Date()
        let fingerprint = SnapshotFingerprint(modifiedAt: start, fileSize: 1)
        state.ingestFingerprint(fingerprint, now: start, isLoadable: true)
        state.ingestFingerprint(fingerprint, now: start.addingTimeInterval(2), isLoadable: true)

        XCTAssertTrue(state.hasDetectedSnapshot)
        XCTAssertTrue(state.isLoading)
        XCTAssertEqual(state.placeholderMessage, "Loading preview…")
    }

    func testUnreadySnapshotDoesNotTriggerReload() {
        var state = TrainingLivePreviewState()
        let start = Date()
        let fingerprint = SnapshotFingerprint(modifiedAt: start, fileSize: 128)
        state.ingestFingerprint(fingerprint, now: start, isLoadable: false)
        state.ingestFingerprint(fingerprint, now: start.addingTimeInterval(5), isLoadable: false)
        XCTAssertTrue(state.hasDetectedSnapshot)
        XCTAssertFalse(state.shouldCreateViewerSurface)
        XCTAssertEqual(state.reloadToken, 0)
        XCTAssertFalse(state.isLoading)
    }

    func testSplatSchemaErrorIsReportedAsTransientReadinessIssue() {
        var state = TrainingLivePreviewState()
        state.ingestLoadState(.failed("Unexpected file contents for a splat PLY: No property named \"nx\" found"))
        XCTAssertEqual(state.lastLoadError, "Preview file is still updating; waiting for the next snapshot.")
    }

    func testSnapshotReadinessAcceptsBinaryPayloadAfterHeader() throws {
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        end_header
        """
        var data = Data(header.utf8)
        data.append(contentsOf: [0x00, 0xFF, 0x80, 0x01, 0xAB, 0xCD, 0xEF, 0x7F])
        let url = try makeTempSnapshot(data: data)
        XCTAssertTrue(test_isSnapshotPreviewLoadable(url))
    }

    func testPollStatusLineTracksChecksAndLatestPollTimestamp() {
        var state = TrainingLivePreviewState()
        let firstPoll = Date(timeIntervalSince1970: 1_726_000_000)
        state.recordPoll(at: firstPoll)
        XCTAssertEqual(state.pollCount, 1)
        XCTAssertEqual(state.lastPollAt, firstPoll)
        XCTAssertEqual(state.pollStatusLine, "Refreshes every 5s.")

        let secondPoll = firstPoll.addingTimeInterval(1)
        state.recordPoll(at: secondPoll)
        XCTAssertEqual(state.pollCount, 2)
        XCTAssertEqual(state.lastPollAt, secondPoll)
        XCTAssertEqual(state.pollStatusLine, "Refreshes every 5s.")
    }

    func testPollCadenceAdaptsAcrossTrainingProgressTiers() {
        var state = TrainingLivePreviewState()
        XCTAssertEqual(state.pollIntervalSeconds, 5.0)
        XCTAssertEqual(state.pollCadenceTier, .early)

        state.updateTrainingProgress(0.45)
        XCTAssertEqual(state.pollIntervalSeconds, 10.0)
        XCTAssertEqual(state.pollCadenceTier, .mid)
        XCTAssertTrue(state.pollStatusLine.contains("every 10s"))

        state.updateTrainingProgress(0.92)
        XCTAssertEqual(state.pollIntervalSeconds, 15.0)
        XCTAssertEqual(state.pollCadenceTier, .late)
        XCTAssertTrue(state.pollStatusLine.contains("every 15s"))
    }

    func testFirstLoadFailureQueuesRetryForSameSnapshot() {
        var state = TrainingLivePreviewState()
        let modifiedAt = Date(timeIntervalSince1970: 1_726_000_000)
        let now = modifiedAt.addingTimeInterval(10)
        let fingerprint = SnapshotFingerprint(modifiedAt: modifiedAt, fileSize: 256)

        state.ingestFingerprint(fingerprint, now: now, isLoadable: true)
        XCTAssertEqual(state.reloadToken, 1)
        XCTAssertTrue(state.isLoading)

        state.ingestLoadState(.failed("temporary load issue"))
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.lastLoadError, "temporary load issue")

        state.ingestFingerprint(fingerprint, now: now.addingTimeInterval(1), isLoadable: true)
        XCTAssertEqual(state.reloadToken, 2)
        XCTAssertTrue(state.isLoading)
    }

    private func makeTempSnapshot(data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("latest_snapshot.ply")
        try data.write(to: url, options: [.atomic])
        return url
    }
}
#endif
