import Foundation
import SwiftUI

struct ViewerArtifactLoadRequest: Equatable, Sendable {
    let projectURL: URL
    let outputURL: URL

    init(projectURL: URL, outputURL: URL) {
        self.projectURL = projectURL.standardizedFileURL
        self.outputURL = outputURL.standardizedFileURL
    }
}

enum ViewerArtifactLoadOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

/// Owns the lifetime of result verification work. Full project verification is
/// synchronous, so it runs away from the main actor; request generations keep a
/// cancelled or superseded verification from publishing stale UI state.
@MainActor
final class ViewerArtifactLoader<Value: Sendable>: ObservableObject {
    typealias Operation = @Sendable (URL) throws -> Value
    typealias Completion = @MainActor (
        ViewerArtifactLoadRequest,
        ViewerArtifactLoadOutcome<Value>
    ) -> Void

    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    func load(
        _ request: ViewerArtifactLoadRequest,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) {
        cancel()
        generation &+= 1
        let requestGeneration = generation
        let worker = Task.detached(priority: .userInitiated) {
            () -> ViewerArtifactLoadOutcome<Value> in
            do {
                try Task.checkCancellation()
                let value = try operation(request.projectURL)
                try Task.checkCancellation()
                return .success(value)
            } catch is CancellationError {
                return .failure(CancellationError().localizedDescription)
            } catch {
                return .failure(error.localizedDescription)
            }
        }

        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  generation == requestGeneration else {
                return
            }
            task = nil
            completion(request, outcome)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
