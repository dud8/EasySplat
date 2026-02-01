import XCTest
@testable import EasySplatCore

final class GlomapRunnerTests: XCTestCase {
    func testRunMapperFailsWithSubprocessFailure() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let glomap = root.appendingPathComponent("glomap")
        TestFileBuilder.createFile(at: glomap, data: Data([0x00]))

        let runner = MockSubprocessRunner(scripts: [
            .init(path: glomap.path, argsPrefix: ["mapper"], result: .init(exitCode: 2, terminationReason: .exit, stdout: "out", stderr: "err"), onRun: nil)
        ])

        let glomapRunner = GlomapRunner(runner: runner)
        do {
            try await glomapRunner.runMapper(
                glomapPath: glomap,
                database: root.appendingPathComponent("db"),
                imagePath: root.appendingPathComponent("images"),
                outputPath: root.appendingPathComponent("out"),
                onLog: { _, _ in }
            )
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertEqual(error.tool, "glomap")
            XCTAssertEqual(error.command, "mapper")
        } catch {
            XCTFail("Unexpected error")
        }
    }
}
