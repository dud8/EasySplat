import Foundation

public enum UIVerifierCommand: Equatable, Sendable {
    case run
    case summarize
}

public enum UIVerifierArgumentError: Error, LocalizedError, Equatable {
    case usage(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message): message
        }
    }
}

public struct UIVerifierArguments: Sendable {
    public var command: UIVerifierCommand
    public var appURL: URL?
    public var scenario: UIVerificationScenario?
    public var outputURL: URL
    public var screenshotDirectory: URL?
    public var resultURLs: [URL]

    public static func parse(_ raw: [String]) throws -> UIVerifierArguments {
        guard let commandValue = raw.first else {
            throw UIVerifierArgumentError.usage(Self.usage)
        }
        let command: UIVerifierCommand
        switch commandValue {
        case "run": command = .run
        case "summarize": command = .summarize
        default: throw UIVerifierArgumentError.usage("Unknown command: \(commandValue)\n\(Self.usage)")
        }

        var values: [String: String] = [:]
        var results: [String] = []
        var index = 1
        while index < raw.count {
            let option = raw[index]
            guard index + 1 < raw.count else {
                throw UIVerifierArgumentError.usage("Missing value for \(option).")
            }
            let value = raw[index + 1]
            if option == "--result" {
                results.append(value)
            } else if ["--app", "--scenario", "--output", "--screenshots"].contains(option) {
                guard values[option] == nil else {
                    throw UIVerifierArgumentError.usage("Duplicate option: \(option).")
                }
                values[option] = value
            } else {
                throw UIVerifierArgumentError.usage("Unknown option: \(option).")
            }
            index += 2
        }

        guard let output = values["--output"] else {
            throw UIVerifierArgumentError.usage(Self.usage)
        }
        let outputURL = try absoluteURL(output, option: "--output")
        switch command {
        case .run:
            guard let app = values["--app"], (app as NSString).pathExtension == "app",
                  let rawScenario = values["--scenario"],
                  let scenario = UIVerificationScenario(rawValue: rawScenario),
                  let screenshots = values["--screenshots"],
                  results.isEmpty else {
                throw UIVerifierArgumentError.usage(Self.usage)
            }
            return UIVerifierArguments(
                command: command,
                appURL: try absoluteURL(app, option: "--app", isDirectory: true),
                scenario: scenario,
                outputURL: outputURL,
                screenshotDirectory: try absoluteURL(
                    screenshots,
                    option: "--screenshots",
                    isDirectory: true
                ),
                resultURLs: []
            )
        case .summarize:
            guard !results.isEmpty,
                  values["--app"] == nil,
                  values["--scenario"] == nil,
                  values["--screenshots"] == nil else {
                throw UIVerifierArgumentError.usage(Self.usage)
            }
            return UIVerifierArguments(
                command: command,
                appURL: nil,
                scenario: nil,
                outputURL: outputURL,
                screenshotDirectory: nil,
                resultURLs: try results.map { try absoluteURL($0, option: "--result") }
            )
        }
    }

    private static func absoluteURL(
        _ path: String,
        option: String,
        isDirectory: Bool = false
    ) throws -> URL {
        guard (path as NSString).isAbsolutePath else {
            throw UIVerifierArgumentError.usage("\(option) must be an absolute path.")
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
    }

    public static let usage = """
    Usage:
      EasySplatUIVerifier run --app <EasySplat.app> --scenario <light|dark|reduce-motion|increase-contrast|differentiate-without-color> --output <result.json> --screenshots <directory>
      EasySplatUIVerifier summarize --result <result.json> [--result <result.json> ...] --output <suite.json>
    """
}
