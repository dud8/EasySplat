import Foundation

public struct SubprocessFailure: Error, LocalizedError, Sendable {
    public let tool: String
    public let command: String
    public let exitCode: Int32
    public let terminationReason: Process.TerminationReason
    public let stdoutTail: String
    public let stderrTail: String

    public init(
        tool: String,
        command: String,
        exitCode: Int32,
        terminationReason: Process.TerminationReason,
        stdoutTail: String,
        stderrTail: String
    ) {
        self.tool = tool
        self.command = command
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    public var errorDescription: String? {
        "\(tool) failed: \(command) (exit \(exitCode), reason: \(terminationReason))"
    }

    public var debugDescription: String {
        """
        Tool: \(tool)
        Command: \(command)
        Exit code: \(exitCode)
        Termination reason: \(terminationReason)
        Stdout tail:
        \(stdoutTail)
        Stderr tail:
        \(stderrTail)
        """
    }
}

