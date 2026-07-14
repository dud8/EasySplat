import Foundation
import Darwin

enum DescriptorMatcherRecoveryReason: String, Sendable, Equatable {
    case faissCrash
    case faissUnsupportedOperation
    case faissGeometryRejectedAfterRetries
}

enum DescriptorMatcherRecoveryPolicy {
    private static let fatalComputeSignals: Set<Int32> = [
        SIGILL,
        SIGABRT,
        SIGFPE,
        SIGBUS,
        SIGSEGV,
    ]

    private static let matchingCommands: Set<String> = [
        "sequential_matcher",
        "exhaustive_matcher",
        "matches_importer",
    ]

    static func reason(
        for error: Error,
        currentMatcher: DescriptorMatcher
    ) -> DescriptorMatcherRecoveryReason? {
        guard currentMatcher == .faiss,
              case let ColmapRunnerError.failed(command, exitCode, terminationReason, stdoutTail, stderrTail) = error,
              matchingCommands.contains(command) else {
            return nil
        }

        if terminationReason == .uncaughtSignal,
           fatalComputeSignals.contains(exitCode) {
            return .faissCrash
        }

        let output = "\(stderrTail)\n\(stdoutTail)".lowercased()
        let unavailable = output.contains("not available")
            || output.contains("not enabled")
            || output.contains("not built")
        let unsupported = output.contains("unsupported operation")
            || output.contains("not implemented")
        if output.contains("feature descriptor index not implemented")
            || (output.contains("faiss") && (unavailable || unsupported))
            || (output.contains("descriptor index") && unsupported) {
            return .faissUnsupportedOperation
        }

        return nil
    }

    static func reasonForRejectedGeometry(
        currentMatcher: DescriptorMatcher,
        exhaustedFaissRetries: Bool
    ) -> DescriptorMatcherRecoveryReason? {
        guard currentMatcher == .faiss, exhaustedFaissRetries else {
            return nil
        }
        return .faissGeometryRejectedAfterRetries
    }
}
