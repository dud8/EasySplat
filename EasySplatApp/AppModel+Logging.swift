import EasySplatCore
import Foundation

extension AppModel {
    func handle(event: PipelineEvent) {
        let now = Date()
        switch event {
        case .stageStarted(let stage):
            self.stage = stage
            progress = nil
            statusTitle = stage.displayName
            statusDetail = nil
            stageStartedAt = now
            lastPipelineEventAt = now
            appendLogLine("[\(stage.displayName)] started")
        case .stageProgress(let stage, let fraction, let message):
            let previousStage = self.stage
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
        progress = fraction < 0 ? nil : fraction
        statusTitle = "Preparing tools"
        statusDetail = message
        maybeAppendToolchainProgressLog(fraction: fraction, message: message)
    }

    func maybeAppendProgressLog(stage: PipelineStage, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if stage == .trainSplat {
            if trimmed.hasPrefix("Preparing training dataset (images)") {
                if let ratio = parseProgressRatio(trimmed) {
                    let bucket = bucketedPercent(current: ratio.current, total: ratio.total)
                    if bucket == lastTrainingImagesBucket {
                        return
                    }
                    lastTrainingImagesBucket = bucket
                }
            } else if trimmed.hasPrefix("Preparing training dataset (sparse)") {
                if let ratio = parseProgressRatio(trimmed) {
                    let bucket = bucketedPercent(current: ratio.current, total: ratio.total)
                    if bucket == lastTrainingSparseBucket {
                        return
                    }
                    lastTrainingSparseBucket = bucket
                }
            } else if trimmed.hasPrefix("Training model") {
                if let ratio = parseProgressRatio(trimmed) {
                    let bucket = bucketedSteps(current: ratio.current, bucketSize: trainingStepLogInterval)
                    if bucket == lastTrainingStepsBucket {
                        return
                    }
                    lastTrainingStepsBucket = bucket
                } else {
                    return
                }
            }
        }

        let now = Date()
        let minInterval: TimeInterval = stage == .trainSplat && trimmed.hasPrefix("Training model")
            ? trainingProgressLogMinInterval
            : 1.5
        if stage == lastProgressLogStage && trimmed == lastProgressLogMessage && now.timeIntervalSince(lastProgressLogAt) < minInterval {
            return
        }

        lastProgressLogStage = stage
        lastProgressLogMessage = trimmed
        lastProgressLogAt = now
        appendLogLine("[\(stage.displayName)] \(trimmed)")
    }

    func parseProgressRatio(_ message: String) -> (current: Int, total: Int)? {
        let chars = Array(message)
        var index = 0
        while index < chars.count {
            if chars[index].isNumber {
                let start = index
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "," {
                    end += 1
                }
                if end < chars.count, chars[end] == "/" {
                    let secondStart = end + 1
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
        let logURL = ProjectPaths(root: projectURL).pipelineLogURL
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(maxBytes), fileSize)
        guard readSize > 0 else { return [] }
        do {
            try handle.seek(toOffset: fileSize - readSize)
            var data = try handle.readToEnd() ?? Data()
            // If we didn't read from the start of the file, the seek may have landed mid-line
            // (and possibly mid-multibyte-UTF-8). Drop everything up to and including the first
            // newline so the first surviving line is always whole and decodes cleanly.
            if readSize < fileSize, let firstNewline = data.firstIndex(of: 0x0A) {
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
                guard shouldKeepLoadedLogLine(sanitized) else { continue }
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

    func shouldKeepLoadedLogLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("[training model]") {
            if lower.contains("completed loading") || lower.contains("evaluating every") {
                return false
            }
            if lower.contains("🖌") || lower.contains("░") || lower.contains("▓") || lower.contains("█") || lower.contains("•") || lower.contains("·") {
                return false
            }
            if lower.contains("[2k") || lower.contains("[1b") {
                return false
            }
        }
        return true
    }
}
