import Darwin
import EasySplatUIVerifierCore
import Foundation

@main
private enum EasySplatUIVerifierMain {
    @MainActor
    static func main() async {
        do {
            let arguments = try UIVerifierArguments.parse(Array(CommandLine.arguments.dropFirst()))
            switch arguments.command {
            case .run:
                guard let appURL = arguments.appURL,
                      let scenario = arguments.scenario,
                      let screenshotDirectory = arguments.screenshotDirectory else {
                    throw UIVerifierArgumentError.usage(UIVerifierArguments.usage)
                }
                let result: ScenarioVerificationResult
                do {
                    result = try await PackagedAppVerifier.run(
                        appURL: appURL,
                        scenario: scenario,
                        screenshotDirectory: screenshotDirectory
                    )
                } catch {
                    result = PackagedAppVerifier.failureResult(
                        appURL: appURL,
                        scenario: scenario,
                        error: error
                    )
                }
                try JSONDocument.write(result, to: arguments.outputURL)
                if !result.failures.isEmpty
                    || !result.keyboardActivationPassed
                    || !result.longProjectTitleFound
                    || result.viewerShortcutEvidence == nil
                    || result.viewports.contains(where: { !$0.accessibilityIssues.isEmpty }) {
                    throw UIHarnessValidationError.invalid(
                        "The \(scenario.rawValue) packaged-app UI verification failed. See \(arguments.outputURL.path)."
                    )
                }
            case .summarize:
                let results = try arguments.resultURLs.map {
                    try JSONDocument.read(ScenarioVerificationResult.self, from: $0)
                }
                do {
                    try UIHarnessSuiteValidator.validate(results)
                    try UIHarnessArtifactValidator.validate(results)
                    try JSONDocument.write(
                        UIHarnessSuiteResult(
                            schemaVersion: 3,
                            passed: true,
                            failures: [],
                            scenarios: results
                        ),
                        to: arguments.outputURL
                    )
                } catch {
                    try JSONDocument.write(
                        UIHarnessSuiteResult(
                            schemaVersion: 3,
                            passed: false,
                            failures: [error.localizedDescription],
                            scenarios: results
                        ),
                        to: arguments.outputURL
                    )
                    throw error
                }
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
