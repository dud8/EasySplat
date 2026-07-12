import EasySplatCore
import Foundation

enum CurrentSplatExportError: LocalizedError {
    case noFinishedOutput

    var errorDescription: String? {
        switch self {
        case .noFinishedOutput:
            return "This project does not have a valid finished splat to export."
        }
    }
}

extension AppModel {
    func validatedCurrentSplatForExport() throws -> URL {
        guard let projectURL = currentProjectURL,
              let source = readyOutputURL(projectURL: projectURL) else {
            throw CurrentSplatExportError.noFinishedOutput
        }
        return source
    }

    func exportCurrentSplat(to destination: URL) throws {
        let source = try validatedCurrentSplatForExport()
        try Self.exportValidatedSplat(from: source, to: destination)
    }

    nonisolated static func exportValidatedSplat(from source: URL, to destination: URL) throws {
        if source.standardizedFileURL == destination.standardizedFileURL {
            return
        }
        try SplatExport.copyIfExists(from: source, to: destination)
    }
}
