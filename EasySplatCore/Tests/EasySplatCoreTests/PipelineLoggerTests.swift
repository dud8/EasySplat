import XCTest
@testable import EasySplatCore

final class PipelineLoggerTests: XCTestCase {
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
}
