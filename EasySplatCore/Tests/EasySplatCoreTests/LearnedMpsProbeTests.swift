import XCTest
@testable import EasySplatCore

final class LearnedMpsProbeTests: XCTestCase {
    func testProbeParsesSuccess() async throws {
        let python = URL(fileURLWithPath: "/mock/python")
        let json = """
        {"pythonMachine":"arm64","platform":"macos","torchVersion":"2.1.0","mpsBuilt":true,"mpsAvailable":true,"mpsAllocOK":true,"failure":null}
        """
        let runner = MockSubprocessRunner(scripts: [
            .init(path: python.path, argsPrefix: ["-c"], result: .init(exitCode: 0, terminationReason: .exit, stdout: json, stderr: ""), onRun: nil)
        ])
        let result = try await LearnedMpsProbe.run(python: python, runner: runner)
        XCTAssertTrue(result.isMpsUsable)
    }

    func testProbeRejectsInvalidJSON() async {
        let python = URL(fileURLWithPath: "/mock/python")
        let runner = MockSubprocessRunner(scripts: [
            .init(path: python.path, argsPrefix: ["-c"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "not json", stderr: ""), onRun: nil)
        ])
        do {
            _ = try await LearnedMpsProbe.run(python: python, runner: runner)
            XCTFail("Expected invalidOutput")
        } catch let error as LearnedMpsProbeError {
            guard case .invalidOutput = error else { return XCTFail("Expected invalidOutput") }
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testProbeFailureUsesPayloadMessage() async {
        let python = URL(fileURLWithPath: "/mock/python")
        let json = """
        {"pythonMachine":"arm64","platform":"macos","torchVersion":"missing","mpsBuilt":false,"mpsAvailable":false,"mpsAllocOK":false,"failure":"torch import failed"}
        """
        let runner = MockSubprocessRunner(scripts: [
            .init(path: python.path, argsPrefix: ["-c"], result: .init(exitCode: 1, terminationReason: .exit, stdout: json, stderr: "stderr"), onRun: nil)
        ])
        do {
            _ = try await LearnedMpsProbe.run(python: python, runner: runner)
            XCTFail("Expected commandFailed")
        } catch let error as LearnedMpsProbeError {
            guard case .commandFailed(let message) = error else { return XCTFail("Expected commandFailed") }
            XCTAssertTrue(message.contains("torch import failed"))
        } catch {
            XCTFail("Unexpected error")
        }
    }
}
