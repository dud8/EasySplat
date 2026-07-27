import EasySplatCore
import Foundation

extension AppModel {
    func handle(event: PipelineEvent) {
        let now = Date()
        switch event {
        case .stageStarted(let stage):
            updatePhaseStart(for: stage, at: now)
            // The watch only needs to exist while a preview can be resident.
            if stage == .trainSplat {
                startTrainingPreviewMemoryWatch()
            } else if self.stage == .trainSplat {
                stopTrainingPreviewMemoryWatch()
            }
            self.stage = stage
            progress = nil
            statusTitle = stage.displayName
            statusDetail = nil
            stageStartedAt = now
            lastPipelineEventAt = now
            appendLogLine("[\(stage.displayName)] started")
        case .stageProgress(let stage, let fraction, let message):
            let previousStage = self.stage
            updatePhaseStart(for: stage, at: now)
            self.stage = stage
            if previousStage != stage || stageStartedAt == nil {
                stageStartedAt = now
            }
            progress = fraction < 0 ? nil : fraction
            statusTitle = stage.displayName
            statusDetail = message
            lastPipelineEventAt = now
            maybeAppendProgressLog(stage: stage, message: message)
        case .stageLog(let stage, let line, let isError):
            if self.stage != stage || stageStartedAt == nil {
                updatePhaseStart(for: stage, at: now)
                self.stage = stage
                stageStartedAt = now
            }
            let sanitized = sanitizeLogLine(line)
            let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let bypassThrottle = shouldBypassStageLogThrottle(line: trimmed, isError: isError)
            let minInterval: TimeInterval = 0.5
            if stage == lastStageLogStage {
                if trimmed == lastStageLogMessage {
                    return
                }
                if !bypassThrottle && now.timeIntervalSince(lastStageLogAt) < minInterval {
                    return
                }
            }

            lastStageLogStage = stage
            lastStageLogMessage = trimmed
            lastStageLogAt = now

            let errPrefix = isError ? "[err] " : ""
            lastPipelineEventAt = now
            appendLogLine("\(errPrefix)[\(stage.displayName)] \(trimmed)", isError: isError)
        case .stageFinished(let stage):
            self.stage = stage
            progress = 1.0
            lastPipelineEventAt = now
            appendLogLine("[\(stage.displayName)] finished")
        case .trainingPreviewPublished(let url, let iteration, let publication, let sceneBounds):
            // Deliberately does not touch lastPipelineEventAt: a preview is not
            // evidence that the run advanced, and letting it reset the silence
            // timer would mask a stalled trainer.
            guard isTrainingStageActive else { return }
            // Mounting a publication is the one moment the app commits new renderer
            // memory, so the launch-time permit is re-tested here. Training must
            // never lose unified memory to a preview it was not admitted alongside.
            guard acceptTrainingPreviewUnderCurrentMemoryPressure() else { return }
            trainingPreviewURL = url
            trainingPreviewIteration = iteration
            trainingPreviewPublication = publication
            trainingPreviewSceneBounds = sceneBounds
        case .trainingPreviewDisabled(let reason):
            // The last published frame would otherwise sit there indefinitely,
            // reading as the current state of a model that has moved on.
            releaseTrainingPreview(reason: reason)
        case .pipelineFailed(_, let userMessage, let debugMessage):
            if stopAction != nil {
                return
            }
            lastError = userMessage
            statusTitle = userMessage
            statusDetail = nil
            progress = nil
            lastPipelineEventAt = now
            errorDetails = debugMessage
            appendLogLine("[err] \(userMessage)", isError: true)
        }
    }

    func handleToolchainProgress(fraction: Double, message: String) {
        if phaseStartedAt == nil {
            phaseStartedAt = Date()
        }
        progress = fraction < 0 ? nil : fraction
        statusTitle = "Preparing tools"
        statusDetail = message
        maybeAppendToolchainProgressLog(fraction: fraction, message: message)
    }

    private func updatePhaseStart(for newStage: PipelineStage, at date: Date) {
        let previousPhase = stage.map(ProcessingPhase.forStage)
        let nextPhase = ProcessingPhase.forStage(newStage)
        if phaseStartedAt == nil
            || (previousPhase == nil && nextPhase != .prepare)
            || (previousPhase != nil && previousPhase != nextPhase) {
            phaseStartedAt = date
        }
    }

    func maybeAppendProgressLog(stage: PipelineStage, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()

        if stage == .trainSplat {
            // Bucketed training milestones gate on the bucket alone: an
            // advance always logs, a repeat never does.
            if trimmed.hasPrefix("Preparing msplat dataset (images)"),
               let ratio = parseProgressRatio(trimmed) {
                let bucket = bucketedPercent(current: ratio.current, total: ratio.total)
                guard bucket != lastTrainingImagesBucket else { return }
                lastTrainingImagesBucket = bucket
                appendProgressLogLine(stage: stage, message: trimmed, at: now)
                return
            }
            if trimmed.hasPrefix("Preparing msplat dataset (sparse)"),
               let ratio = parseProgressRatio(trimmed) {
                let bucket = bucketedPercent(current: ratio.current, total: ratio.total)
                guard bucket != lastTrainingSparseBucket else { return }
                lastTrainingSparseBucket = bucket
                appendProgressLogLine(stage: stage, message: trimmed, at: now)
                return
            }
            if trimmed.hasPrefix("Training splat") {
                guard let ratio = parseProgressRatio(trimmed) else { return }
                let bucket = bucketedSteps(current: ratio.current, bucketSize: trainingStepLogInterval)
                guard bucket != lastTrainingStepsBucket else { return }
                lastTrainingStepsBucket = bucket
                appendProgressLogLine(stage: stage, message: trimmed, at: now)
                return
            }
        }

        // The interval gates same-stage messages regardless of content:
        // per-event counters ("fallback 22624: …") make every message unique,
        // and matching on identical text alone let them flood the log.
        if stage == lastProgressLogStage && now.timeIntervalSince(lastProgressLogAt) < 1.5 {
            return
        }
        appendProgressLogLine(stage: stage, message: trimmed, at: now)
    }

    private func appendProgressLogLine(stage: PipelineStage, message: String, at now: Date) {
        lastProgressLogStage = stage
        lastProgressLogMessage = message
        lastProgressLogAt = now
        appendLogLine("[\(stage.displayName)] \(message)")
    }

    /// Reads the first `N/M` or `N of M` pair in a progress message. Both spellings
    /// are live: dataset preparation counts with a slash, the trainer counts with
    /// "of".
    func parseProgressRatio(_ message: String) -> (current: Int, total: Int)? {
        let chars = Array(message)
        let separator = Array(" of ")
        var index = 0
        while index < chars.count {
            if chars[index].isNumber {
                let start = index
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "," {
                    end += 1
                }
                var secondStart: Int?
                if end < chars.count, chars[end] == "/" {
                    secondStart = end + 1
                } else if end + separator.count <= chars.count,
                          Array(chars[end..<(end + separator.count)]) == separator {
                    secondStart = end + separator.count
                }
                if let secondStart {
                    var secondEnd = secondStart
                    while secondEnd < chars.count, chars[secondEnd].isNumber || chars[secondEnd] == "," {
                        secondEnd += 1
                    }
                    if secondStart < secondEnd {
                        let left = String(chars[start..<end]).replacingOccurrences(of: ",", with: "")
                        let right = String(chars[secondStart..<secondEnd]).replacingOccurrences(of: ",", with: "")
                        if let current = Int(left), let total = Int(right) {
                            return (current, total)
                        }
                    }
                }
                index = end
            }
            index += 1
        }
        return nil
    }

    func bucketedPercent(current: Int, total: Int, bucketSize: Int = 10) -> Int {
        guard total > 0 else { return 0 }
        let percent = Int((Double(current) / Double(total) * 100.0).rounded(.down))
        return max(0, (percent / bucketSize) * bucketSize)
    }

    func bucketedSteps(current: Int, bucketSize: Int) -> Int {
        guard bucketSize > 0 else { return current }
        return max(0, (current / bucketSize) * bucketSize)
    }

    func appendLogLine(_ line: String, isError: Bool = false) {
        logLines.append(line)
        if logLines.count > 2_000 {
            logLines.removeFirst(logLines.count - 2_000)
        }

        if isError || isTracebackLine(line) {
            errorLogLines.append(line)
            if errorLogLines.count > 4_000 {
                errorLogLines.removeFirst(errorLogLines.count - 4_000)
            }
        }
    }

    func maybeAppendToolchainProgressLog(fraction: Double, message: String) {
        let sanitized = sanitizeLogLine(message)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if fraction < 0 {
            guard trimmed != lastToolchainMilestoneMessage else { return }
            lastToolchainMilestoneMessage = trimmed
            appendLogLine("[Tools] \(trimmed)")
            return
        }

        let clamped = min(max(fraction, 0.0), 1.0)
        let bucket = Int((clamped * 100.0).rounded(.down) / 10.0) * 10
        let label = toolchainProgressLabel(from: trimmed)
        if toolchainDownloadBucketByLabel[label] == bucket {
            return
        }
        toolchainDownloadBucketByLabel[label] = bucket
        appendLogLine("[Tools] \(trimmed)")
    }

    func toolchainProgressLabel(from message: String) -> String {
        guard let open = message.firstIndex(of: "("),
              let close = message[open...].firstIndex(of: ")"),
              open < close else {
            return "tools"
        }
        let inner = message[message.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return inner.isEmpty ? "tools" : inner
    }

    func sanitizeLogLine(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var output: [UnicodeScalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                if index + 1 < scalars.count, scalars[index + 1].value == 0x5B {
                    index += 2
                    while index < scalars.count {
                        let value = scalars[index].value
                        if value >= 0x40 && value <= 0x7E {
                            index += 1
                            break
                        }
                        index += 1
                    }
                    continue
                }
                index += 1
                continue
            }
            if scalar.value < 32 || scalar.value == 127 {
                index += 1
                continue
            }
            output.append(scalar)
            index += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    func shouldBypassStageLogThrottle(line: String, isError: Bool) -> Bool {
        if isError { return true }
        let lower = line.lowercased()
        if lower.hasPrefix("traceback (most recent call last):") {
            return true
        }
        if lower.hasPrefix("during handling of the above exception") {
            return true
        }
        if line.hasPrefix("File \"") && line.contains(", line ") {
            return true
        }
        if line.hasPrefix("  File \"") && line.contains(", line ") {
            return true
        }
        return false
    }

    func isTracebackLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("traceback (most recent call last):") {
            return true
        }
        if lower.contains("runtimeerror:") || lower.contains("typeerror:") || lower.contains("valueerror:") {
            return true
        }
        if line.hasPrefix("File \"") || line.hasPrefix("  File \"") {
            return true
        }
        return false
    }

    func loadPipelineLogTail(projectURL: URL, maxLines: Int = 200, maxBytes: Int = 64 * 1024) -> [String] {
        let paths = ProjectPaths(root: projectURL)
        guard let logURL = try? paths.resolveProjectRelativePath("Logs/pipeline.log") else {
            return []
        }
        do {
            let tail = try BoundedFileReader.readRegularFileTail(
                at: logURL,
                maximumBytes: maxBytes
            )
            guard !tail.data.isEmpty else { return [] }
            var data = tail.data
            // If we didn't read from the start of the file, the seek may have landed mid-line
            // (and possibly mid-multibyte-UTF-8). Drop everything up to and including the first
            // newline so the first surviving line is always whole and decodes cleanly.
            if !tail.startsAtFileBeginning, let firstNewline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: firstNewline)..<data.endIndex)
            }
            let text = String(decoding: data, as: UTF8.self)
            let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var cleaned: [String] = []
            cleaned.reserveCapacity(min(maxLines, rawLines.count))
            var last = ""
            for raw in rawLines {
                let sanitized = sanitizeLogLine(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sanitized.isEmpty else { continue }
                if sanitized == last { continue }
                cleaned.append(sanitized)
                last = sanitized
            }
            if cleaned.count > maxLines {
                return Array(cleaned.suffix(maxLines))
            }
            return cleaned
        } catch {
            return []
        }
    }
}
