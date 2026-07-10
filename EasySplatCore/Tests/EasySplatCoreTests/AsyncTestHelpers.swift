import XCTest

@MainActor
func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @escaping () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        let failureMessage = message()
        if failureMessage.isEmpty {
            XCTFail("Expected error to be thrown", file: file, line: line)
        } else {
            XCTFail(failureMessage, file: file, line: line)
        }
    } catch {
        errorHandler(error)
    }
}
