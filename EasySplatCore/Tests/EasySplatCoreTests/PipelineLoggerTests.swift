import XCTest
@testable import EasySplatCore

final class PipelineLoggerTests: XCTestCase {
    func testStageTimingCanBeSampledWithoutStoppingTheStage() throws {
        let tracker = StageTimingTracker()
        tracker.start(.sfmMapping)
        Thread.sleep(forTimeInterval: 0.01)

        let sampled = try XCTUnwrap(tracker.elapsedSeconds(.sfmMapping))
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertNotNil(tracker.finish(.sfmMapping))
        let finished = try XCTUnwrap(tracker.consumeRecord(.sfmMapping))

        XCTAssertGreaterThan(sampled, 0)
        XCTAssertGreaterThan(finished.durationSeconds, sampled)
    }

    func testStageTimingAccumulatesFailedAndSuccessfulRetryAttempts() throws {
        let tracker = StageTimingTracker()
        tracker.start(.sfmMapping)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertNotNil(tracker.finish(.sfmMapping))
        let first = try XCTUnwrap(tracker.consumeRecord(.sfmMapping))

        tracker.start(.sfmMapping)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertNotNil(tracker.finish(.sfmMapping))
        let cumulative = try XCTUnwrap(tracker.consumeRecord(.sfmMapping))

        XCTAssertEqual(cumulative.startedAt, first.startedAt)
        XCTAssertGreaterThan(cumulative.durationSeconds, first.durationSeconds)
        XCTAssertGreaterThanOrEqual(
            cumulative.durationSeconds,
            first.durationSeconds + 0.005
        )
    }

    func testProgressDeduplication() throws {
        let dir = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("pipeline.log")
        let eventsURL = dir.appendingPathComponent("events.jsonl")

        let events: [PipelineEvent] = [
            .stageStarted(stage: .importInput),
            .stageProgress(stage: .importInput, fraction: 0.5, message: "Copying input 1/2"),
            .stageProgress(stage: .importInput, fraction: 0.5, message: "Copying input 1/2"),
            .stageProgress(stage: .importInput, fraction: 0.6, message: "Copying input 2/2"),
            .stageFinished(stage: .importInput)
        ]

        PipelineRunner.test_writePipelineLogs(events: events, logURL: logURL, eventsURL: eventsURL)

        let logText = try String(contentsOf: logURL, encoding: .utf8)
        let lines = logText.split(separator: "\n").map(String.init)
        let progressLines = lines.filter { $0.contains("Copying input") }
        XCTAssertEqual(progressLines.count, 2)

        let eventsText = try String(contentsOf: eventsURL, encoding: .utf8)
        let eventLines = eventsText.split(separator: "\n").map(String.init)
        XCTAssertEqual(eventLines.count, events.count)
    }

    func testNewLoggerReplacesPreviousRunLogs() throws {
        let dir = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("pipeline.log")
        let eventsURL = dir.appendingPathComponent("events.jsonl")
        try Data("stale pipeline\n".utf8).write(to: logURL)
        try Data("stale events\n".utf8).write(to: eventsURL)

        PipelineRunner.test_writePipelineLogs(
            events: [.stageStarted(stage: .importInput)],
            logURL: logURL,
            eventsURL: eventsURL
        )

        XCTAssertFalse(try String(contentsOf: logURL, encoding: .utf8).contains("stale"))
        XCTAssertFalse(try String(contentsOf: eventsURL, encoding: .utf8).contains("stale"))
    }

    func testSymlinkedLogsAreRejectedWithoutOverwritingExternalFiles() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let logs = parent.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let pipelineOutside = parent.appendingPathComponent("outside-pipeline.log")
        let eventsOutside = parent.appendingPathComponent("outside-events.jsonl")
        let pipelineSentinel = Data("keep pipeline\n".utf8)
        let eventsSentinel = Data("keep events\n".utf8)
        try pipelineSentinel.write(to: pipelineOutside)
        try eventsSentinel.write(to: eventsOutside)
        let logURL = logs.appendingPathComponent("pipeline.log")
        let eventsURL = logs.appendingPathComponent("events.jsonl")
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: pipelineOutside)
        try FileManager.default.createSymbolicLink(at: eventsURL, withDestinationURL: eventsOutside)

        PipelineRunner.test_writePipelineLogs(
            events: [.stageStarted(stage: .importInput)],
            logURL: logURL,
            eventsURL: eventsURL
        )

        XCTAssertEqual(try Data(contentsOf: pipelineOutside), pipelineSentinel)
        XCTAssertEqual(try Data(contentsOf: eventsOutside), eventsSentinel)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: logURL.path))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: eventsURL.path))
    }

    func testHardLinkedLogsAreRejectedBeforeExternalFilesAreTruncated() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let logs = parent.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let pipelineOutside = parent.appendingPathComponent("outside-pipeline.log")
        let eventsOutside = parent.appendingPathComponent("outside-events.jsonl")
        let pipelineSentinel = Data("keep pipeline\n".utf8)
        let eventsSentinel = Data("keep events\n".utf8)
        try pipelineSentinel.write(to: pipelineOutside)
        try eventsSentinel.write(to: eventsOutside)
        let logURL = logs.appendingPathComponent("pipeline.log")
        let eventsURL = logs.appendingPathComponent("events.jsonl")
        try FileManager.default.linkItem(at: pipelineOutside, to: logURL)
        try FileManager.default.linkItem(at: eventsOutside, to: eventsURL)

        PipelineRunner.test_writePipelineLogs(
            events: [.stageStarted(stage: .importInput)],
            logURL: logURL,
            eventsURL: eventsURL
        )

        XCTAssertEqual(try Data(contentsOf: pipelineOutside), pipelineSentinel)
        XCTAssertEqual(try Data(contentsOf: eventsOutside), eventsSentinel)
    }
}
