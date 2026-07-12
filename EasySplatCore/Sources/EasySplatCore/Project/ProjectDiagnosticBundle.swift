import Foundation

/// Builds a paste-ready diagnostic summary for a single project. The output is a
/// markdown-flavored text block containing pipeline metadata, stage timings, and
/// trimmed tails of the relevant log files. Designed for bug reports: no
/// machine-specific home-directory paths leak through, byte budgets keep the
/// text manageable in chat/email clients, and missing or empty logs are skipped
/// without making bundle creation fail.
public enum ProjectDiagnosticBundle {
    /// Maximum lines retained from each log tail. Tuned to keep the bundle under
    /// ~64 KB even when several logs are present.
    public static let defaultTailLineLimit = 120
    public static let defaultTailByteLimit = 32 * 1024

    /// Schema version embedded in the machine-readable JSON block. Bump
    /// when adding/removing/renaming top-level keys so downstream tools can
    /// detect a format change.
    public static let machineReadableSchemaVersion = 4

    /// Scrub a user-visible technical payload before it reaches a clipboard,
    /// save panel, or share surface. Project identity is included when the
    /// project metadata is readable; path and URL scrubbing always applies.
    public static func sanitizeForSharing(
        _ text: String,
        projectURL: URL? = nil
    ) -> String {
        var sensitiveValues: [String] = []
        if let projectURL {
            sensitiveValues.append(projectURL.lastPathComponent)
            if let metadata = try? ProjectMetadataStore.load(
                from: ProjectPaths(root: projectURL).metadataURL
            ) {
                sensitiveValues.append(metadata.title)
                sensitiveValues.append(metadata.id.uuidString)
            }
        }
        return HomePathSanitizer(sensitiveValues: sensitiveValues).sanitize(text)
    }

    /// Compose the diagnostic text for the project rooted at `projectURL`.
    /// `hardwareLine` lets the caller inject a one-line hardware summary that
    /// only the app knows (e.g., macOS version, Mac model). Returns `nil` when
    /// the project metadata cannot be loaded — there is nothing useful to share.
    ///
    /// `includeNotes` defaults to `false` so the bundle is safe to paste into
    /// a public bug report. Notes are user-authored free text and can contain
    /// locations, names, or other private context the user did not intend to
    /// share. Opt in explicitly when the caller knows the destination is
    /// trustworthy.
    public static func build(
        projectURL: URL,
        hardwareLine: String? = nil,
        includeNotes: Bool = false,
        now: Date = Date(),
        tailLineLimit: Int = defaultTailLineLimit,
        tailByteLimit: Int = defaultTailByteLimit
    ) -> String? {
        let paths = ProjectPaths(root: projectURL)
        guard let metadata = try? ProjectMetadataStore.load(from: paths.metadataURL) else {
            return nil
        }
        let pathSanitizer = HomePathSanitizer(
            sensitiveValues: [metadata.title, metadata.id.uuidString, projectURL.lastPathComponent]
        )

        var sections: [String] = []
        sections.append(buildHeader(metadata: metadata, now: now, hardwareLine: hardwareLine, includeNotes: includeNotes))

        if includeNotes,
           let notes = metadata.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            // Cap the note body so a runaway entry can't dominate the bundle
            // and sanitize the home path the same way log tails are.
            let cap = 2048
            let truncated = String(notes.prefix(cap))
            let sanitized = pathSanitizer.sanitize(truncated)
            let suffix = notes.count > cap ? "\n…(notes truncated to \(cap) characters)" : ""
            sections.append("## Notes\n\(sanitized)\(suffix)")
        }
        if let reconstructionSection = reconstructionSection(metadata: metadata) {
            sections.append(reconstructionSection)
        }
        if let timingSection = stageTimingSection(metadata: metadata) {
            sections.append(timingSection)
        }
        if let stateSection = stateSection(metadata: metadata, sanitizer: pathSanitizer) {
            sections.append(stateSection)
        }
        if let machineSection = machineReadableSection(metadata: metadata, sanitizer: pathSanitizer) {
            sections.append(machineSection)
        }

        let logSources: [(label: String, url: URL)] = [
            ("pipeline.log", paths.pipelineLogURL),
            ("colmap.log", paths.colmapLogURL),
            ("global_mapper.log", paths.globalMapperLogURL),
            ("da3.log", paths.da3LogURL),
            ("msplat.log", paths.msplatLogURL)
        ]
        for source in logSources {
            guard (try? paths.projectRelativePath(for: source.url)) != nil else { continue }
            if let tail = logTailSection(label: source.label, url: source.url, sanitizer: pathSanitizer, tailLineLimit: tailLineLimit, tailByteLimit: tailByteLimit) {
                sections.append(tail)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private static func buildHeader(
        metadata: ProjectMetadata,
        now: Date,
        hardwareLine: String?,
        includeNotes: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("# EasySplat Diagnostic Bundle")
        lines.append("Generated: \(iso8601(now))")
        lines.append("Privacy: \(includeNotes ? "notes opted in" : "notes excluded by default")")
        lines.append("Created: \(iso8601(metadata.createdAt))")
        let options = metadata.requestedRunOptions
        lines.append("Options: capture=\(options.capturePath.rawValue) detail=\(options.detailProfile.rawValue)")
        switch metadata.input {
        case .video(let files):
            lines.append("Input: \(files.count) video(s)")
        case .photos:
            lines.append("Input: photos folder")
        case .mixed(let videos, _):
            lines.append("Input: mixed (\(videos.count) videos + photos folder)")
        }
        if let hardwareLine, !hardwareLine.isEmpty {
            lines.append("Hardware: \(hardwareLine)")
        }
        return lines.joined(separator: "\n")
    }

    private static func reconstructionSection(metadata: ProjectMetadata) -> String? {
        guard let reconstruction = metadata.reconstruction else { return nil }
        var lines: [String] = ["## Reconstruction"]
        lines.append("Mapper: \(reconstruction.mapper)")
        lines.append("Captured: \(iso8601(reconstruction.capturedAt))")
        lines.append("Registered: \(reconstruction.registeredImages) / \(reconstruction.totalImages)")
        if let reproj = reconstruction.meanReprojectionError {
            lines.append("Mean reprojection error: \(String(format: "%.3f px", reproj))")
        }
        if let points = reconstruction.pointCount {
            lines.append("Points: \(points)")
        }
        if let observations = reconstruction.observationCount {
            lines.append("Observations: \(observations)")
        }
        if let track = reconstruction.meanTrackLength {
            lines.append("Mean track length: \(String(format: "%.2f", track))")
        }
        return lines.joined(separator: "\n")
    }

    private static func stageTimingSection(metadata: ProjectMetadata) -> String? {
        guard let timings = metadata.stageTimings, !timings.isEmpty else { return nil }
        var lines: [String] = ["## Stage Timings"]
        for record in timings.sorted(by: { $0.startedAt < $1.startedAt }) {
            let seconds = Int(record.durationSeconds.rounded())
            lines.append("- \(record.stage.rawValue): \(seconds)s")
        }
        if let total = timings.totalDurationSeconds {
            lines.append("Total: \(Int(total.rounded()))s")
        }
        return lines.joined(separator: "\n")
    }

    private static func stateSection(metadata: ProjectMetadata, sanitizer: HomePathSanitizer) -> String? {
        var lines: [String] = ["## Pipeline State"]
        lines.append("Current stage: \(metadata.state.stage.rawValue)")
        if let lastFailureAt = metadata.lastFailureAt {
            lines.append("Last failure: \(iso8601(lastFailureAt))")
        }
        if let lastError = metadata.state.lastError, !lastError.isEmpty {
            lines.append("Last error: \(sanitizer.sanitize(lastError))")
        }
        if let checkpoint = metadata.checkpoint {
            lines.append("Checkpoint stage: \(checkpoint.stage.rawValue)")
            if let progress = checkpoint.progressFraction {
                lines.append("Checkpoint progress: \(String(format: "%.1f%%", progress * 100))")
            }
            if let message = checkpoint.message, !message.isEmpty {
                lines.append("Checkpoint message: \(sanitizer.sanitize(message))")
            }
        }
        if lines.count == 1 { return nil }
        return lines.joined(separator: "\n")
    }

    /// Emit a JSON-fenced block carrying the run's structured metrics so
    /// downstream analysis tools (or future EasySplat builds) can ingest a
    /// diagnostic bundle without parsing markdown. Excludes notes and project
    /// identifiers regardless of `includeNotes`.
    private static func machineReadableSection(
        metadata: ProjectMetadata,
        sanitizer: HomePathSanitizer
    ) -> String? {
        guard metadata.reconstruction != nil
            || (metadata.stageTimings?.isEmpty == false)
            || metadata.lastFailureAt != nil else {
            return nil
        }
        struct Payload: Encodable {
            var schemaVersion: Int
            var requestedRunOptions: RequestedRunOptions
            var reconstruction: ReconstructionSummary?
            var stageTimings: [StageTimingRecord]?
            var lastFailureAt: Date?
        }
        let payload = Payload(
            schemaVersion: ProjectDiagnosticBundle.machineReadableSchemaVersion,
            requestedRunOptions: metadata.requestedRunOptions,
            reconstruction: metadata.reconstruction,
            stageTimings: metadata.stageTimings,
            lastFailureAt: metadata.lastFailureAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "## Metrics (machine readable)\n```json\n\(sanitizer.sanitize(json))\n```"
    }

    private static func logTailSection(
        label: String,
        url: URL,
        sanitizer: HomePathSanitizer,
        tailLineLimit: Int,
        tailByteLimit: Int
    ) -> String? {
        guard let tail = boundedTail(of: url, byteLimit: tailByteLimit), !tail.isEmpty else { return nil }
        let limitedByLines = TextTails.tailLines(tail, limit: tailLineLimit, byteLimit: tailByteLimit)
        let sanitized = sanitizer.sanitize(limitedByLines)
        return "## \(label) (tail)\n```\n\(sanitized)\n```"
    }

    /// Read at most `byteLimit` bytes from the end of `url` without slurping
    /// the entire file into memory. Decodes the result as UTF-8, dropping a
    /// partial leading byte if seeking landed mid-codepoint.
    private static func boundedTail(of url: URL, byteLimit: Int) -> String? {
        guard byteLimit > 0 else { return nil }
        guard let tail = try? BoundedFileReader.readRegularFileTail(
            at: url,
            maximumBytes: byteLimit
        ), !tail.data.isEmpty else { return nil }
        // If we started mid-UTF8-codepoint, drop bytes until we hit a valid leading byte.
        var trimmed = tail.data
        if !tail.startsAtFileBeginning {
            while let first = trimmed.first, first & 0b1100_0000 == 0b1000_0000 {
                trimmed.removeFirst()
            }
        }
        return String(data: trimmed, encoding: .utf8)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Removes local identity from paths and URLs before diagnostics leave the app.
struct HomePathSanitizer {
    let homePath: String
    let sensitiveValues: [String]

    init(sensitiveValues: [String] = []) {
        self.homePath = NSHomeDirectory()
        self.sensitiveValues = sensitiveValues
    }

    init(homePath: String, sensitiveValues: [String] = []) {
        self.homePath = homePath
        self.sensitiveValues = sensitiveValues
    }

    func sanitize(_ text: String) -> String {
        var sanitized = text
        for value in sensitiveValues
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: value)
            sanitized = replacingMatches(
                in: sanitized,
                pattern: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                template: "<redacted>"
            )
        }
        if !homePath.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: homePath, with: "~")
        }
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"/Volumes/[^/\r\n]+(?=/)"#,
            template: "/Volumes/<redacted>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"/Volumes/[^/\r\n\"']+(?=[\"']|$)"#,
            template: "/Volumes/<redacted>"
        )
        return replacingMatches(
            in: sanitized,
            pattern: #"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@"#,
            template: "$1"
        )
    }

    private func replacingMatches(in text: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
