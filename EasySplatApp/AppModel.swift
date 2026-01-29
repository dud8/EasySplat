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
    @Published var progress: Double = 0
    @Published var statusText: String = "Ready to start"
    @Published var logLines: [String] = []
    @Published var lastError: String? = nil
    @Published var errorDetails: String? = nil
    @Published var outputPlyURL: URL? = nil
    @Published var currentProjectURL: URL? = nil
    @Published var toolchainPaths: ToolchainPaths? = nil

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

    var errorDetailsText: String? {
        var parts: [String] = []
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
        currentTask?.cancel()
        currentTask = nil
        let projectURL = currentProjectURL
        reset()
        viewState = .home
        if deleteProject, let projectURL {
            try? FileManager.default.removeItem(at: projectURL)
        }
        refreshProjectSummaries()
    }

    private func startProject(input: InputSpec, title: String) async {
        defer { currentTask = nil }
        reset()
        viewState = .processing
        statusText = "Preparing project"

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

            statusText = "Downloading tools"
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
            if statusText == "Preparing project" || statusText == "Downloading tools" || statusText == "Something went wrong" {
                statusText = lastError ?? "Something went wrong"
            }
            viewState = .processing
            refreshProjectSummaries()
        }
    }

    private func resumeProjectTask(at url: URL) async {
        defer { currentTask = nil }
        reset()
        viewState = .processing
        statusText = "Preparing project"

        do {
            let paths = ProjectPaths(root: url)
            let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
            currentProjectURL = url

            if let output = metadata.outputs?.splatPlyPath {
                let outputURL = url.appendingPathComponent(output)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    outputPlyURL = outputURL
                    viewState = .viewer
                    return
                }
            }

            statusText = "Downloading tools"
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
            if statusText == "Preparing project" || statusText == "Downloading tools" || statusText == "Something went wrong" {
                statusText = lastError ?? "Something went wrong"
            }
            viewState = .processing
            refreshProjectSummaries()
        }
    }

    fileprivate func handle(event: PipelineEvent) {
        switch event {
        case .stageStarted(let stage):
            self.stage = stage
            self.progress = 0
            self.statusText = stage.displayName
        case .stageProgress(let stage, let fraction, let message):
            self.stage = stage
            self.progress = fraction
            self.statusText = message
        case .stageLog(_, let line, _):
            self.logLines.append(line)
            if self.logLines.count > 500 {
                self.logLines.removeFirst(self.logLines.count - 500)
            }
        case .stageFinished(let stage):
            self.stage = stage
            self.progress = 1.0
        case .pipelineFailed(_, let userMessage, let debugMessage):
            self.lastError = userMessage
            self.statusText = userMessage
            self.errorDetails = debugMessage
        }
    }

    private func reset() {
        stage = nil
        progress = 0
        statusText = "Ready"
        logLines = []
        lastError = nil
        errorDetails = nil
        outputPlyURL = nil
        toolchainPaths = nil
        currentProjectURL = nil
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
            model.progress = fraction * 0.2
            model.statusText = message
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
