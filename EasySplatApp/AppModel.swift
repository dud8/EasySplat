import Foundation
import SwiftUI
import UniformTypeIdentifiers
import EasySplatCore

@MainActor
final class AppModel: ObservableObject {
    enum ViewState {
        case home
        case processing
        case viewer
    }

    private enum AppModelError: LocalizedError {
        case noDocumentsDirectory

        var errorDescription: String? {
            switch self {
            case .noDocumentsDirectory:
                return "Unable to locate the Documents folder."
            }
        }
    }

    @Published var viewState: ViewState = .home
    @Published var stage: PipelineStage? = nil
    @Published var progress: Double? = nil
    @Published var statusTitle: String = "Ready to start"
    @Published var statusDetail: String? = nil
    @Published var stageStartedAt: Date? = nil
    @Published var lastPipelineEventAt: Date? = nil
    @Published var logLines: [String] = []
    @Published var lastError: String? = nil
    @Published var errorDetails: String? = nil
    @Published var outputPlyURL: URL? = nil
    @Published var currentProjectURL: URL? = nil
    @Published var toolchainPaths: ToolchainPaths? = nil
    @Published private(set) var stopAction: StopAction? = nil

    @Published var captureMode: CaptureMode = .object
    @Published var qualityPreset: QualityPreset = .standard
    @Published var pendingVideoURLs: [URL] = []
    @Published var pendingPhotosFolderURL: URL? = nil
    @Published var projectSummaries: [ProjectSummary] = []
    @Published var selectionWarning: String? = nil

    private let toolchainManager: ToolchainManaging
    private let pipelineRunnerFactory: (URL, PipelineRunner.PipelineConfig) -> PipelineRunning
    private let projectBaseURL: URL?
    private var currentTask: Task<Void, Never>?
    private var lastProgressLogAt: Date = .distantPast
    private var lastProgressLogMessage: String = ""
    private var lastProgressLogStage: PipelineStage? = nil
    private var lastTrainingImagesBucket: Int = -1
    private var lastTrainingSparseBucket: Int = -1
    private var lastTrainingStepsBucket: Int = -1
    private var lastStageLogAt: Date = .distantPast
    private var lastStageLogMessage: String = ""
    private var lastStageLogStage: PipelineStage? = nil
    private let trainingStepLogInterval = 20

    enum StopAction {
        case keepProject
        case deleteProject
    }

    var isStopping: Bool {
        stopAction != nil
    }

    var processingDetailsText: String? {
        if lastError != nil {
            if let details = errorDetails, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return details
            }
            return statusDetail
        }
        if let detail = statusDetail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        return nil
    }

    var errorDetailsText: String? {
        var parts: [String] = []
        if let statusDetail, !statusDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(statusDetail)
        }
        if let errorDetails, !errorDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(errorDetails)
        }
        if !logLines.isEmpty {
            parts.append("Logs:\n" + logLines.joined(separator: "\n"))
        }
        let combined = parts.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    init(
        toolchainManager: ToolchainManaging = ToolchainManager(),
        projectBaseURL: URL? = nil,
        pipelineRunnerFactory: @escaping (URL, PipelineRunner.PipelineConfig) -> PipelineRunning = { projectURL, config in
            PipelineRunner(projectURL: projectURL, config: config)
        }
    ) {
        self.toolchainManager = toolchainManager
        self.projectBaseURL = projectBaseURL
        self.pipelineRunnerFactory = pipelineRunnerFactory
        refreshProjectSummaries()
    }

    func startWithVideo(url: URL) {
        clearPendingInputs()
        addInputs(urls: [url])
    }

    func startWithPhotoFolder(url: URL) {
        clearPendingInputs()
        addInputs(urls: [url])
    }

    func addInputs(urls: [URL]) {
        var newVideos: [URL] = []
        var newFolder: URL?
        var ignoredFiles: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                newFolder = url
            } else {
                if let type = UTType(filenameExtension: url.pathExtension),
                   type.conforms(to: .movie) || type.conforms(to: .video) {
                    newVideos.append(url)
                } else {
                    ignoredFiles.append(url)
                }
            }
        }
        if !newVideos.isEmpty {
            let existing = Set(pendingVideoURLs.map(\.path))
            let merged = pendingVideoURLs + newVideos.filter { !existing.contains($0.path) }
            pendingVideoURLs = merged
        }
        if let newFolder {
            pendingPhotosFolderURL = newFolder
        }
        if ignoredFiles.isEmpty {
            selectionWarning = nil
        } else {
            selectionWarning = "Ignored \(ignoredFiles.count) file(s). Supported: video files and a photo folder."
        }
    }

    func removeVideo(at offsets: IndexSet) {
        pendingVideoURLs.remove(atOffsets: offsets)
    }

    func clearPendingInputs() {
        pendingVideoURLs = []
        pendingPhotosFolderURL = nil
        selectionWarning = nil
    }

    func startFromPendingSelection() {
        guard let inputSpec = buildInputSpec() else { return }
        let title = projectTitle(for: inputSpec)
        clearPendingInputs()
        currentTask?.cancel()
        currentTask = Task { await startProject(input: inputSpec, title: title) }
    }

    func resumeProject(at url: URL) {
        currentTask?.cancel()
        currentTask = Task { await resumeProjectTask(at: url) }
    }

    func cancelCurrentProject(deleteProject: Bool) {
        guard currentTask != nil else {
            let projectURL = currentProjectURL
            reset()
            viewState = .home
            if deleteProject, let projectURL {
                try? FileManager.default.removeItem(at: projectURL)
            }
            refreshProjectSummaries()
            return
        }

        stopAction = deleteProject ? .deleteProject : .keepProject
        lastError = nil
        errorDetails = nil
        statusTitle = deleteProject ? "Stopping and deleting…" : "Saving progress…"
        statusDetail = "Stopping at the next safe point (up to 15 seconds)…"
        progress = nil
        currentTask?.cancel()
    }

    private func startProject(input: InputSpec, title: String) async {
        defer {
            currentTask = nil
            if stopAction != nil {
                completeStop()
            }
        }
        reset()
        viewState = .processing
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil

        do {
            let projectURL = try createProjectDirectory(title: title)
            currentProjectURL = projectURL
            let metadata = ProjectMetadata(
                title: projectURL.deletingPathExtension().lastPathComponent,
                input: input,
                preset: PresetSpec(mode: captureMode, quality: qualityPreset)
            )
            let paths = ProjectPaths(root: projectURL)
            try paths.ensureDirectories()
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

            statusTitle = "Downloading tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self)
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                targetName: "macos-arm64"
            ) { fraction, message in
                progressForwarder.update(fraction: fraction, message: message)
            }
            self.toolchainPaths = toolchain

            let runner = pipelineRunnerFactory(projectURL, .init(toolchain: toolchain, preset: metadata.preset))
            let forwarder = EventForwarder(model: self)
            try await runner.run(resumeFrom: nil) { event in
                forwarder.handle(event)
            }

            if let output = try? ProjectMetadataStore.load(from: paths.metadataURL).outputs?.splatPlyPath {
                outputPlyURL = projectURL.appendingPathComponent(output)
            }
            viewState = .viewer
            refreshProjectSummaries()
        } catch is CancellationError {
            return
        } catch {
            if stopAction != nil {
                return
            }
            // PipelineRunner emits `.pipelineFailed(...)` with better user/debug messages. Avoid overwriting
            // those with the default `Error.localizedDescription`.
            if lastError == nil {
                lastError = error.localizedDescription
            }
            let envDetails = """
            Underlying error: \(String(reflecting: error))
            Manifest URL: \(AppConfig.toolchainManifestURL.absoluteString)
            Public key present: \(!AppConfig.toolchainPublicKeyBase64.isEmpty)
            """
            if let existing = errorDetails, !existing.isEmpty {
                errorDetails = existing + "\n\n" + envDetails
            } else {
                errorDetails = envDetails
            }
            if statusTitle == "Preparing project" || statusTitle == "Downloading tools" || statusTitle == "Something went wrong" {
                statusTitle = lastError ?? "Something went wrong"
                statusDetail = nil
                progress = nil
            }
            viewState = .processing
            refreshProjectSummaries()
        }
    }

    private func resumeProjectTask(at url: URL) async {
        defer {
            currentTask = nil
            if stopAction != nil {
                completeStop()
            }
        }
        reset()
        viewState = .processing
        statusTitle = "Preparing project"
        statusDetail = nil
        progress = nil

        do {
            let paths = ProjectPaths(root: url)
            let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
            currentProjectURL = url
            logLines = []
            let previousLines = loadPipelineLogTail(projectURL: url)
            if !previousLines.isEmpty {
                appendLogLine("========== PREVIOUS LOG (from Logs/pipeline.log) ==========")
                for line in previousLines {
                    appendLogLine("[previous] \(line)")
                }
            }
            appendLogLine("========== NEW LOG START (current run) ==========")
            appendLogLine("Resumed project")

            if let output = metadata.outputs?.splatPlyPath {
                let outputURL = url.appendingPathComponent(output)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    outputPlyURL = outputURL
                    viewState = .viewer
                    return
                }
            }

            statusTitle = "Downloading tools"
            statusDetail = nil
            progress = nil
            let progressForwarder = ProgressForwarder(model: self)
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                targetName: "macos-arm64"
            ) { fraction, message in
                progressForwarder.update(fraction: fraction, message: message)
            }
            self.toolchainPaths = toolchain

            let runner = pipelineRunnerFactory(url, .init(toolchain: toolchain, preset: metadata.preset))
            let forwarder = EventForwarder(model: self)
            let resumeStage = resumeStage(from: metadata)
            try await runner.run(resumeFrom: resumeStage) { event in
                forwarder.handle(event)
            }

            if let output = try? ProjectMetadataStore.load(from: paths.metadataURL).outputs?.splatPlyPath {
                outputPlyURL = url.appendingPathComponent(output)
            }
            viewState = .viewer
            refreshProjectSummaries()
        } catch is CancellationError {
            return
        } catch {
            if stopAction != nil {
                return
            }
            // PipelineRunner emits `.pipelineFailed(...)` with better user/debug messages. Avoid overwriting
            // those with the default `Error.localizedDescription`.
            if lastError == nil {
                lastError = error.localizedDescription
            }
            let envDetails = """
            Underlying error: \(String(reflecting: error))
            Manifest URL: \(AppConfig.toolchainManifestURL.absoluteString)
            Public key present: \(!AppConfig.toolchainPublicKeyBase64.isEmpty)
            """
            if let existing = errorDetails, !existing.isEmpty {
                errorDetails = existing + "\n\n" + envDetails
            } else {
                errorDetails = envDetails
            }
            if statusTitle == "Preparing project" || statusTitle == "Downloading tools" || statusTitle == "Something went wrong" {
                statusTitle = lastError ?? "Something went wrong"
                statusDetail = nil
                progress = nil
            }
            viewState = .processing
            refreshProjectSummaries()
        }
    }

    fileprivate func handle(event: PipelineEvent) {
        let now = Date()
        switch event {
        case .stageStarted(let stage):
            self.stage = stage
            self.progress = nil
            self.statusTitle = stage.displayName
            self.statusDetail = nil
            self.stageStartedAt = now
            self.lastPipelineEventAt = now
            appendLogLine("[\(stage.displayName)] started")
        case .stageProgress(let stage, let fraction, let message):
            let previousStage = self.stage
            self.stage = stage
            if previousStage != stage || self.stageStartedAt == nil {
                self.stageStartedAt = now
            }
            self.progress = fraction < 0 ? nil : fraction
            self.statusTitle = stage.displayName
            self.statusDetail = message
            self.lastPipelineEventAt = now
            maybeAppendProgressLog(stage: stage, message: message)
        case .stageLog(let stage, let line, let isError):
            if self.stage != stage || self.stageStartedAt == nil {
                self.stage = stage
                self.stageStartedAt = now
            }
            let sanitized = sanitizeLogLine(line)
            let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Backstop against tools that spam redraw/progress output: keep Details useful, not noisy.
            let minInterval: TimeInterval = 0.5
            if stage == lastStageLogStage {
                if trimmed == lastStageLogMessage {
                    return
                }
                if now.timeIntervalSince(lastStageLogAt) < minInterval {
                    return
                }
            }

            lastStageLogStage = stage
            lastStageLogMessage = trimmed
            lastStageLogAt = now

            let errPrefix = isError ? "[err] " : ""
            self.lastPipelineEventAt = now
            appendLogLine("\(errPrefix)[\(stage.displayName)] \(trimmed)")
        case .stageFinished(let stage):
            self.stage = stage
            self.progress = 1.0
            self.lastPipelineEventAt = now
            appendLogLine("[\(stage.displayName)] finished")
        case .pipelineFailed(_, let userMessage, let debugMessage):
            if stopAction != nil {
                return
            }
            self.lastError = userMessage
            self.statusTitle = userMessage
            self.statusDetail = nil
            self.progress = nil
            self.lastPipelineEventAt = now
            self.errorDetails = debugMessage
            appendLogLine("[err] \(userMessage)")
        }
    }

    private func maybeAppendProgressLog(stage: PipelineStage, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if stage == .trainBrush {
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

        // Keep "Details" verbose enough to be useful, but don't spam one line per frame.
        let now = Date()
        let minInterval: TimeInterval = 1.5
        if stage == lastProgressLogStage && trimmed == lastProgressLogMessage && now.timeIntervalSince(lastProgressLogAt) < minInterval {
            return
        }
        if stage == lastProgressLogStage && now.timeIntervalSince(lastProgressLogAt) < minInterval {
            return
        }

        lastProgressLogStage = stage
        lastProgressLogMessage = trimmed
        lastProgressLogAt = now
        appendLogLine("[\(stage.displayName)] \(trimmed)")
    }

    private func parseProgressRatio(_ message: String) -> (current: Int, total: Int)? {
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

    private func bucketedPercent(current: Int, total: Int, bucketSize: Int = 10) -> Int {
        guard total > 0 else { return 0 }
        let percent = Int((Double(current) / Double(total) * 100.0).rounded(.down))
        return max(0, (percent / bucketSize) * bucketSize)
    }

    private func bucketedSteps(current: Int, bucketSize: Int) -> Int {
        guard bucketSize > 0 else { return current }
        return max(0, (current / bucketSize) * bucketSize)
    }

    private func appendLogLine(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    private func sanitizeLogLine(_ line: String) -> String {
        // Strip ANSI escape sequences (common in CLI progress redraws).
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
            // Drop other C0 control characters.
            if scalar.value < 32 || scalar.value == 127 {
                index += 1
                continue
            }
            output.append(scalar)
            index += 1
        }
        return String(String.UnicodeScalarView(output))
    }

    private func reset() {
        stage = nil
        progress = nil
        statusTitle = "Ready"
        statusDetail = nil
        stageStartedAt = nil
        lastPipelineEventAt = nil
        logLines = []
        lastProgressLogAt = .distantPast
        lastProgressLogMessage = ""
        lastProgressLogStage = nil
        lastTrainingImagesBucket = -1
        lastTrainingSparseBucket = -1
        lastTrainingStepsBucket = -1
        lastStageLogAt = .distantPast
        lastStageLogMessage = ""
        lastStageLogStage = nil
        lastError = nil
        errorDetails = nil
        outputPlyURL = nil
        toolchainPaths = nil
        currentProjectURL = nil
        stopAction = nil
    }

    private func completeStop() {
        let action = stopAction
        stopAction = nil

        let projectURL = currentProjectURL
        reset()
        viewState = .home
        if action == .deleteProject, let projectURL {
            try? FileManager.default.removeItem(at: projectURL)
        }
        refreshProjectSummaries()
    }

    private func loadPipelineLogTail(projectURL: URL, maxLines: Int = 200, maxBytes: Int = 64 * 1024) -> [String] {
        let logURL = ProjectPaths(root: projectURL).pipelineLogURL
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(maxBytes), fileSize)
        guard readSize > 0 else { return [] }
        do {
            try handle.seek(toOffset: fileSize - readSize)
            let data = try handle.readToEnd() ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var cleaned: [String] = []
            cleaned.reserveCapacity(min(maxLines, rawLines.count))
            var last: String = ""
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

    private func shouldKeepLoadedLogLine(_ line: String) -> Bool {
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

    private func createProjectDirectory(title: String) throws -> URL {
        let fm = FileManager.default
        let base: URL
        if let projectBaseURL {
            base = projectBaseURL
        } else {
            guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw AppModelError.noDocumentsDirectory
            }
            base = docs.appendingPathComponent("EasySplat Projects", isDirectory: true)
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTitle = title.isEmpty ? "Project" : title
        var projectURL = base.appendingPathComponent("\(safeTitle).easysplatproj", isDirectory: true)
        if fm.fileExists(atPath: projectURL.path) {
            projectURL = base.appendingPathComponent("\(safeTitle)-\(UUID().uuidString.prefix(6)).easysplatproj", isDirectory: true)
        }
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    private func projectBaseDirectory() -> URL {
        let fm = FileManager.default
        if let projectBaseURL {
            return projectBaseURL
        }
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return fm.temporaryDirectory.appendingPathComponent("EasySplat Projects", isDirectory: true)
        }
        return docs.appendingPathComponent("EasySplat Projects", isDirectory: true)
    }

    private func buildInputSpec() -> InputSpec? {
        let videos = pendingVideoURLs
        let photosFolder = pendingPhotosFolderURL
        if !videos.isEmpty && photosFolder != nil {
            return .mixed(videos: videos.map(\.path), photosFolder: photosFolder!.path)
        }
        if !videos.isEmpty {
            return .video(files: videos.map(\.path))
        }
        if let photosFolder {
            return .photos(folder: photosFolder.path)
        }
        return nil
    }

    private func projectTitle(for input: InputSpec) -> String {
        if let firstVideo = input.videoFiles.first {
            return URL(fileURLWithPath: firstVideo).deletingPathExtension().lastPathComponent
        }
        if let photosFolder = input.photosFolder {
            return URL(fileURLWithPath: photosFolder).lastPathComponent
        }
        return "Project"
    }

    private func resumeStage(from metadata: ProjectMetadata) -> PipelineStage? {
        guard metadata.state.lastError == nil else {
            let stages = PipelineStage.allCases
            guard let index = stages.firstIndex(of: metadata.state.stage), index > 0 else {
                return nil
            }
            return stages[index - 1]
        }
        return metadata.state.stage
    }

    func refreshProjectSummaries() {
        let base = projectBaseDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            projectSummaries = []
            return
        }

        var summaries: [ProjectSummary] = []
        for url in contents where url.pathExtension == "easysplatproj" {
            guard let metadata = try? ProjectMetadataStore.load(from: url.appendingPathComponent("project.json")) else {
                continue
            }
            let outputURL = metadata.outputs.map { url.appendingPathComponent($0.splatPlyPath) }
            let outputExists = outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let isActive = currentProjectURL == url && viewState == .processing
            let isRetrying = isActive && metadata.state.lastError != nil
            let status: ProjectStatus
            if isActive {
                status = .inProgress
            } else if outputExists {
                status = .ready
            } else if metadata.state.lastError != nil {
                status = .failed
            } else {
                status = .inProgress
            }
            summaries.append(ProjectSummary(
                id: metadata.id,
                title: metadata.title,
                url: url,
                createdAt: metadata.createdAt,
                status: status,
                isActive: isActive,
                isRetrying: isRetrying,
                lastError: metadata.state.lastError,
                outputPlyURL: outputURL
            ))
        }

        projectSummaries = summaries.sorted { $0.createdAt > $1.createdAt }
    }
}

private final class EventForwarder: @unchecked Sendable {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ event: PipelineEvent) {
        Task { @MainActor in
            self.model?.handle(event: event)
        }
    }
}

    private final class ProgressForwarder: @unchecked Sendable {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func update(fraction: Double, message: String) {
        Task { @MainActor in
            guard let model = self.model else { return }
            model.progress = fraction < 0 ? nil : fraction
            model.statusTitle = "Downloading tools"
            model.statusDetail = message
        }
    }
}

protocol PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws
}

extension PipelineRunner: PipelineRunning {}

enum AppConfig {
    private static let defaultManifestURLString = "https://github.com/dud8/EasySplat/releases/latest/download/manifest.json"
    private static let fallbackManifestURLString = "http://localhost:8000/manifest.json"

    static var toolchainManifestURL: URL {
        if let url = urlFromEnv("EASYSPLAT_TOOLCHAIN_MANIFEST_URL") {
            return url
        }
        if let url = readURLResource(named: "toolchain_manifest_url") {
            return url
        }
        if let url = URL(string: defaultManifestURLString) {
            return url
        }
        return URL(string: fallbackManifestURLString) ?? URL(fileURLWithPath: "/")
    }

    static var toolchainPublicKeyBase64: String {
        if let env = ProcessInfo.processInfo.environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"], !env.isEmpty {
            return env
        }
        guard let url = Bundle.main.url(forResource: "public_key_ed25519", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func urlFromEnv(_ name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private static func readURLResource(named: String) -> URL? {
        guard let url = Bundle.main.url(forResource: named, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

#if DEBUG
extension AppModel {
    func test_loadPipelineLogTail(projectURL: URL, maxLines: Int = 200, maxBytes: Int = 64 * 1024) -> [String] {
        loadPipelineLogTail(projectURL: projectURL, maxLines: maxLines, maxBytes: maxBytes)
    }
}
#endif
