import Foundation

private final class ColmapMatchingProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBlockMessage: String?

    func updateBlockMessage(_ message: String) {
        lock.lock()
        latestBlockMessage = message
        lock.unlock()
    }

    func blockMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latestBlockMessage
    }
}

extension PipelineRunner {
    private static let maximumGeneratedPairListBytes = 64 * 1_024 * 1_024

    func writeColmapPairList(_ pairs: [String], fileName: String, paths: ProjectPaths) throws -> URL {
        let url = paths.colmapSeedURL.appendingPathComponent(fileName)
        try (pairs.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    func writeColmapPairPlan(
        _ plan: ColmapPairPlan,
        attemptNumber: Int,
        paths: ProjectPaths
    ) throws -> URL {
        let url = paths.colmapSeedURL.appendingPathComponent(
            "match_pairs_attempt_\(attemptNumber).txt"
        )
        try plan.serializedData.write(to: url, options: .atomic)
        guard plan.validates(try Data(contentsOf: url)) else {
            throw PipelineError.outputMissing
        }
        return url
    }

    func writeVocabularyQueryList(
        _ imageNames: [String],
        attemptNumber: Int,
        paths: ProjectPaths
    ) throws -> URL {
        guard !imageNames.isEmpty,
              Set(imageNames).count == imageNames.count,
              imageNames.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        return try writeColmapPairList(
            imageNames,
            fileName: "retrieval_queries_attempt_\(attemptNumber).txt",
            paths: paths
        )
    }

    func readGeneratedPairLines(from url: URL) throws -> [String] {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: Self.maximumGeneratedPairListBytes
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ColmapPairPlanningError.invalidPairPlan
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Runs one COLMAP matcher attempt with database-polling progress.
    func runColmapMatcherAttempt(
        stage: PipelineStage,
        paths: ProjectPaths,
        colmapToolLog: ToolLogWriter,
        expectedPairs: Int,
        progressStart: Double,
        progressSpan: Double,
        blockMessageFallback: String,
        invokeMatcher: @escaping (@escaping @Sendable (String, Bool) -> Void) async throws -> Void,
        emit: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        let state = ColmapMatchingProgressState()
        let blockProgress = ColmapMatchingProgressTracker()
        let onLog: @Sendable (String, Bool) -> Void = { line, isErr in
            colmapToolLog.append(stream: isErr ? "stderr" : "stdout", line: line)
            let sanitized = Self.sanitizeToolLogLine(line)
            let effectiveIsErr = Self.normalizedToolLogIsError(sanitized, isError: isErr)
            if Self.shouldEmitToolLogLine(sanitized, isError: effectiveIsErr) {
                emit(.stageLog(stage: stage, line: sanitized, isError: effectiveIsErr))
            }
            if let update = blockProgress.ingest(line) {
                state.updateBlockMessage(update.message)
            }
        }

        let poller = ColmapDatabaseProgressPoller(databasePath: paths.colmapDatabaseURL)
        let pollTask = Task.detached(priority: .utility) {
            [expectedPairs, poller, state, emit, stage, progressStart, progressSpan, blockMessageFallback] in
            let denom = max(1, expectedPairs)
            var lastFraction: Double = 0
            var lastProcessed = -1
            var lastEmit = Date.distantPast

            while !Task.isCancelled {
                var processed = (try? poller.readAttemptedPairCount()) ?? 0
                if lastProcessed >= 0, processed < lastProcessed {
                    processed = lastProcessed
                }
                let rawFraction = Double(processed) / Double(denom)
                let clamped = max(0, min(0.99, rawFraction))
                if clamped > lastFraction {
                    lastFraction = clamped
                }

                let now = Date()
                let shouldEmitZeroHeartbeat = processed == 0 && now.timeIntervalSince(lastEmit) >= 10
                if processed != lastProcessed || shouldEmitZeroHeartbeat {
                    lastProcessed = processed
                    lastEmit = now
                    let base = state.blockMessage()
                    let message: String
                    if let base {
                        message = "\(base), pairs \(processed)/\(denom)"
                    } else {
                        message = "\(blockMessageFallback) (pairs \(processed)/\(denom))"
                    }
                    let scaled = min(0.99, progressStart + lastFraction * progressSpan)
                    emit(.stageProgress(stage: stage, fraction: scaled, message: message))
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { pollTask.cancel() }

        try await invokeMatcher(onLog)
    }
}
