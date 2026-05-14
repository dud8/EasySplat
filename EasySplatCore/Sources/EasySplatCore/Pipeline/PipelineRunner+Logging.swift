import Foundation

extension PipelineRunner {
    static func normalizedToolLogIsError(_ line: String, isError: Bool) -> Bool {
        guard isError else { return false }
        let trimmed = sanitizeToolLogLine(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let severity = glogSeverity(trimmed) else {
            return true
        }
        switch severity {
        case "I", "W":
            return false
        case "E", "F":
            return true
        default:
            return true
        }
    }

    static func shouldEmitToolLogLine(_ line: String, isError: Bool) -> Bool {
        let trimmed = sanitizeToolLogLine(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let tracebackContext = looksLikeTracebackContextLine(trimmed)
        let hasAlertKeyword = lower.contains("warning")
            || lower.contains("warn")
            || lower.contains("error")
            || lower.contains("fatal")
            || lower.contains("failed")
        if looksLikeProgressBar(trimmed),
           !hasAlertKeyword {
            return false
        }
        if tracebackContext {
            return true
        }
        if isError {
            if hasAlertKeyword {
                return true
            }
            if glogSeverity(trimmed) == "I" {
                return false
            }
            return true
        }
        if trimmed.hasPrefix("EasySplat:") {
            return true
        }
        if let severity = glogSeverity(trimmed), severity != "I" {
            return true
        }
        if lower.contains("warning") || lower.contains("warn") {
            return true
        }
        if lower.contains("error") || lower.contains("fatal") || lower.contains("failed") {
            return true
        }
        return false
    }

    private static func looksLikeTracebackContextLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("traceback (most recent call last):") {
            return true
        }
        if lower.hasPrefix("during handling of the above exception") {
            return true
        }
        if trimmed.hasPrefix("File \"") && trimmed.contains(", line ") {
            return true
        }
        if trimmed.hasPrefix("  File \"") && trimmed.contains(", line ") {
            return true
        }
        if trimmed.hasPrefix("^") {
            return true
        }
        return false
    }

    private static func glogSeverity(_ line: String) -> Character? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5 else { return nil }
        let chars = Array(trimmed)
        let severity = chars[0]
        switch severity {
        case "I", "W", "E", "F":
            break
        default:
            return nil
        }
        guard chars[1...4].allSatisfy(\.isNumber) else { return nil }
        return severity
    }

    static func sanitizeToolLogLine(_ line: String) -> String {
        let stripped = stripAnsiCodes(line)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(stripped.unicodeScalars.count)
        for scalar in stripped.unicodeScalars {
            if scalar.value == 9 {
                scalars.append(scalar)
                continue
            }
            if scalar.value < 32 || scalar.value == 127 {
                continue
            }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func stripAnsiCodes(_ line: String) -> String {
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
            output.append(scalar)
            index += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func looksLikeProgressBar(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("steps") && (lower.contains("/s") || lower.contains("remaining") || lower.contains("eta")) {
            return true
        }
        if lower.contains("it/s") && (lower.contains("remaining") || lower.contains("eta")) {
            return true
        }
        if trimmed.contains("░") || trimmed.contains("▓") || trimmed.contains("█") || trimmed.contains("▉") || trimmed.contains("▊") {
            return true
        }
        let nonWhitespace = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        guard nonWhitespace > 0 else { return false }
        let alnumCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return alnumCount * 3 < nonWhitespace
    }

    static func looksLikeErrorishLine(_ lowercasedLine: String) -> Bool {
        if lowercasedLine.contains("error") || lowercasedLine.contains("fatal") || lowercasedLine.contains("failed") {
            return true
        }
        if lowercasedLine.contains("panic") || lowercasedLine.contains("traceback") || lowercasedLine.contains("exception") {
            return true
        }
        if lowercasedLine.contains("warning") || lowercasedLine.contains("warn") {
            return true
        }
        return false
    }

    static func looksLikeBrushSpinnerLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard lower.contains("training") else { return false }
        if line.contains("🖌") || line.contains("·") || line.contains("•") {
            return true
        }
        if line.contains("░") || line.contains("▓") || line.contains("█") || line.contains("▉") || line.contains("▊") {
            return true
        }
        return false
    }

    private static let brushStepRateRegex = try? NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:it)?/s"#,
        options: [.caseInsensitive]
    )

    func brushTrainStepProgress(from line: String) -> BrushTrainProgress? {
        let s = line
        var index = s.startIndex

        func isDigit(_ c: Character) -> Bool {
            c >= "0" && c <= "9"
        }

        while index < s.endIndex {
            while index < s.endIndex, !isDigit(s[index]) {
                index = s.index(after: index)
            }
            if index >= s.endIndex { break }

            let aStart = index
            var aEnd = index
            while aEnd < s.endIndex, isDigit(s[aEnd]) {
                aEnd = s.index(after: aEnd)
            }
            let aStr = String(s[aStart..<aEnd])
            let a = Int(aStr) ?? -1

            var slash = aEnd
            while slash < s.endIndex, s[slash] == " " {
                slash = s.index(after: slash)
            }
            guard slash < s.endIndex, s[slash] == "/" else {
                index = aEnd
                continue
            }

            var bStart = s.index(after: slash)
            while bStart < s.endIndex, s[bStart] == " " {
                bStart = s.index(after: bStart)
            }
            var bEnd = bStart
            while bEnd < s.endIndex, isDigit(s[bEnd]) {
                bEnd = s.index(after: bEnd)
            }
            guard bEnd > bStart else {
                index = aEnd
                continue
            }

            let bStr = String(s[bStart..<bEnd])
            let b = Int(bStr) ?? -1
            guard a >= 0, b > 0 else {
                index = aEnd
                continue
            }
            return BrushTrainProgress(step: a, total: b)
        }

        return nil
    }

    func brushTrainStepRate(from line: String) -> Double? {
        guard let regex = Self.brushStepRateRegex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        guard match.numberOfRanges > 1, let rateRange = Range(match.range(at: 1), in: line) else { return nil }
        let value = Double(line[rateRange])
        guard let value, value > 0 else { return nil }
        return value
    }
}

final class StageTimingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var starts: [PipelineStage: ContinuousClock.Instant] = [:]

    func start(_ stage: PipelineStage) {
        lock.lock()
        starts[stage] = clock.now
        lock.unlock()
    }

    func finish(_ stage: PipelineStage) -> String? {
        lock.lock()
        guard let start = starts[stage] else {
            lock.unlock()
            return nil
        }
        starts[stage] = nil
        let duration = clock.now - start
        lock.unlock()
        return Self.format(duration)
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = max(0, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        let totalSeconds = Int(seconds.rounded(.down))

        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let rem = totalSeconds % 60
            return "\(minutes)m \(rem)s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

final class PipelineLogger: @unchecked Sendable {
    private let eventsURL: URL
    private let logURL: URL
    private let emit: @Sendable (PipelineEvent) -> Void
    private let encoder: JSONEncoder
    private let logHandle: FileHandle?
    private let eventsHandle: FileHandle?
    private let lock = NSLock()
    private var lastProgressKeyByStage: [PipelineStage: String] = [:]

    init(eventsURL: URL, logURL: URL, emit: @escaping @Sendable (PipelineEvent) -> Void) {
        self.eventsURL = eventsURL
        self.logURL = logURL
        self.emit = emit
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: eventsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        fm.createFile(atPath: eventsURL.path, contents: nil)
        self.logHandle = try? FileHandle(forWritingTo: logURL)
        self.eventsHandle = try? FileHandle(forWritingTo: eventsURL)
        if self.logHandle == nil {
            FileHandle.standardError.write(Data("PipelineLogger: failed to open pipeline log at \(logURL.path)\n".utf8))
        }
        if self.eventsHandle == nil {
            FileHandle.standardError.write(Data("PipelineLogger: failed to open events log at \(eventsURL.path)\n".utf8))
        }
    }

    deinit {
        try? logHandle?.close()
        try? eventsHandle?.close()
    }

    func emit(_ event: PipelineEvent) {
        emit(event)
        lock.lock()
        appendEvent(event)
        switch event {
        case let .stageStarted(stage):
            appendLogLine(stage: stage, line: "Stage started", isError: false)
        case let .stageProgress(stage, fraction, message):
            appendProgressLine(stage: stage, fraction: fraction, message: message)
        case let .stageLog(stage, line, isError):
            appendLogLine(stage: stage, line: line, isError: isError)
        case let .trainingBackendSelected(backend):
            appendLogLine(stage: .trainBrush, line: "Training backend: \(backend.rawValue)", isError: false)
        case let .stageFinished(stage):
            appendLogLine(stage: stage, line: "Stage finished", isError: false)
        case let .pipelineFailed(stage, userMessage, _):
            appendLogLine(stage: stage, line: userMessage, isError: true)
        }
        lock.unlock()
    }

    private func appendEvent(_ event: PipelineEvent) {
        guard let data = try? encoder.encode(event) else { return }
        var line = data
        line.append(0x0A)
        guard let handle = eventsHandle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
    }

    private func appendLogLine(stage: PipelineStage?, line: String, isError: Bool) {
        guard let handle = logHandle else { return }
        let prefix = isError ? "[err] " : ""
        let stagePrefix: String = {
            guard let stage else { return "" }
            return "[\(stage.displayName)] "
        }()
        if let data = "\(prefix)\(stagePrefix)\(line)\n".data(using: .utf8) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    private func appendProgressLine(stage: PipelineStage, fraction: Double, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let line: String
        if fraction < 0 {
            line = trimmed
        } else {
            let clamped = min(max(fraction, 0.0), 1.0)
            let pct = Int((clamped * 100.0).rounded())
            line = "\(pct)% \(trimmed)"
        }

        let key = line
        if lastProgressKeyByStage[stage] == key {
            return
        }
        lastProgressKeyByStage[stage] = key
        appendLogLine(stage: stage, line: line, isError: false)
    }
}
