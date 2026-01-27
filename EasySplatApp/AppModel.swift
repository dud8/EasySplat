import Foundation
import SwiftUI
import EasySplatCore

@MainActor
final class AppModel: ObservableObject {
    enum ViewState {
        case home
        case processing
        case viewer
    }

    @Published var viewState: ViewState = .home
    @Published var stage: PipelineStage? = nil
    @Published var progress: Double = 0
    @Published var statusText: String = "Ready to start"
    @Published var logLines: [String] = []
    @Published var lastError: String? = nil
    @Published var outputPlyURL: URL? = nil
    @Published var currentProjectURL: URL? = nil
    @Published var toolchainPaths: ToolchainPaths? = nil

    @Published var captureMode: CaptureMode = .object
    @Published var qualityPreset: QualityPreset = .standard

    private let toolchainManager: ToolchainManaging
    private let pipelineRunnerFactory: (URL, PipelineRunner.PipelineConfig) -> PipelineRunning
    private let projectBaseURL: URL?

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
    }

    func startWithVideo(url: URL) {
        Task { await startProject(inputURL: url, isFolder: false) }
    }

    func startWithPhotoFolder(url: URL) {
        Task { await startProject(inputURL: url, isFolder: true) }
    }

    func startProject(inputURL: URL, isFolder: Bool) async {
        reset()
        viewState = .processing
        statusText = "Preparing project"

        do {
            let projectURL = try createProjectDirectory(title: inputURL.deletingPathExtension().lastPathComponent)
            currentProjectURL = projectURL
            let inputSpec: InputSpec = isFolder
                ? .photos(folder: inputURL.path)
                : .video(files: [inputURL.path])

            let metadata = ProjectMetadata(
                title: projectURL.deletingPathExtension().lastPathComponent,
                input: inputSpec,
                preset: PresetSpec(mode: captureMode, quality: qualityPreset)
            )
            let paths = ProjectPaths(root: projectURL)
            try paths.ensureDirectories()
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

            statusText = "Downloading tools"
            let toolchain = try await toolchainManager.ensureToolchain(
                manifestURL: AppConfig.toolchainManifestURL,
                publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
                targetName: "macos-arm64"
            ) { fraction, message in
                self.progress = fraction * 0.2
                self.statusText = message
            }
            self.toolchainPaths = toolchain

            let runner = pipelineRunnerFactory(projectURL, .init(toolchain: toolchain, preset: metadata.preset))
            let forwarder = EventForwarder(model: self)
            try await runner.run { event in
                forwarder.handle(event)
            }

            if let output = try? ProjectMetadataStore.load(from: paths.metadataURL).outputs?.splatPlyPath {
                outputPlyURL = projectURL.appendingPathComponent(output)
            }
            viewState = .viewer
        } catch {
            lastError = error.localizedDescription
            statusText = "Something went wrong"
            viewState = .processing
        }
    }

    private func handle(event: PipelineEvent) {
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
        case .pipelineFailed(_, let userMessage, _):
            self.lastError = userMessage
            self.statusText = userMessage
        }
    }

    private func reset() {
        stage = nil
        progress = 0
        statusText = "Ready"
        logLines = []
        lastError = nil
        outputPlyURL = nil
        toolchainPaths = nil
    }

    private func createProjectDirectory(title: String) throws -> URL {
        let fm = FileManager.default
        let base = projectBaseURL ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("EasySplat Projects", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTitle = title.isEmpty ? "Project" : title
        var projectURL = base.appendingPathComponent("\(safeTitle).easysplatproj", isDirectory: true)
        if fm.fileExists(atPath: projectURL.path) {
            projectURL = base.appendingPathComponent("\(safeTitle)-\(UUID().uuidString.prefix(6)).easysplatproj", isDirectory: true)
        }
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
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

protocol PipelineRunning {
    func run(events: @escaping @Sendable (PipelineEvent) -> Void) async throws
}

extension PipelineRunner: PipelineRunning {}

enum AppConfig {
    static var toolchainManifestURL: URL {
        if let url = urlFromEnv("EASYSPLAT_TOOLCHAIN_MANIFEST_URL") {
            return url
        }
        if let url = readURLResource(named: "toolchain_manifest_url") {
            return url
        }
        return URL(string: "https://github.com/<OWNER>/EasySplat/releases/latest/download/manifest.json")!
    }

    static var toolchainPublicKeyBase64: String {
        if let env = ProcessInfo.processInfo.environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"], !env.isEmpty {
            return env
        }
        guard let url = Bundle.main.url(forResource: "public_key_ed25519", withExtension: "txt"),
              let text = try? String(contentsOf: url) else {
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
              let text = try? String(contentsOf: url) else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
