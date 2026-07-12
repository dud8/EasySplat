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
    func validatedCurrentSplatForExport() async throws -> URL {
        guard let projectURL = currentProjectURL,
              let source = try await validatedFinishedOutputURL(projectURL: projectURL) else {
            throw CurrentSplatExportError.noFinishedOutput
        }
        try Task.checkCancellation()
        guard ProjectSummary.hasSameLocation(currentProjectURL, projectURL) else {
            throw CancellationError()
        }
        return source
    }

    func exportCurrentSplat(to destination: URL) async throws {
        let source = try await validatedCurrentSplatForExport()
        try await Task.detached(priority: .userInitiated) {
            try Self.exportValidatedSplat(from: source, to: destination)
        }.value
    }

    nonisolated static func exportValidatedSplat(from source: URL, to destination: URL) throws {
        if source.standardizedFileURL == destination.standardizedFileURL {
            return
        }
        try SplatExport.copyIfExists(from: source, to: destination)
    }
}
