import Foundation

public final class PipelineRunner: @unchecked Sendable {
    public struct Tooling {
        public var colmap: ColmapRunner
        public var glomap: GlomapRunner
        public var brush: BrushRunner

        public init(colmap: ColmapRunner = ColmapRunner(),
                    glomap: GlomapRunner = GlomapRunner(),
                    brush: BrushRunner = BrushRunner()) {
            self.colmap = colmap
            self.glomap = glomap
            self.brush = brush
        }

        public init(runner: SubprocessRunning) {
            self.colmap = ColmapRunner(runner: runner)
            self.glomap = GlomapRunner(runner: runner)
            self.brush = BrushRunner(runner: runner)
        }
    }
    public struct PipelineConfig: Sendable {
        public var toolchain: ToolchainPaths
        public var preset: PresetSpec

        public init(toolchain: ToolchainPaths, preset: PresetSpec) {
            self.toolchain = toolchain
            self.preset = preset
        }
    }

    private let projectURL: URL
    private let config: PipelineConfig
    private let tooling: Tooling

    public init(projectURL: URL, config: PipelineConfig, tooling: Tooling = Tooling()) {
        self.projectURL = projectURL
        self.config = config
        self.tooling = tooling
    }

    public func run(events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let logger = PipelineLogger(eventsURL: paths.eventsLogURL, logURL: paths.pipelineLogURL, emit: events)

        let emit: @Sendable (PipelineEvent) -> Void = { event in
            logger.emit(event)
        }

        emit(.stageStarted(stage: .importInput))
        try importInputs(metadata: metadata, paths: paths)
        emit(.stageFinished(stage: .importInput))

        let (targetFrames, maxDim) = framePreset(for: metadata.preset.quality)
        var selectedFrames: [URL] = []

        switch metadata.input {
        case .video(let files):
            guard let first = files.first else { throw PipelineError.invalidInput }
            let sourceName = URL(fileURLWithPath: first).lastPathComponent
            let videoURL = paths.originalsURL.appendingPathComponent(sourceName)
            emit(.stageStarted(stage: .extractFrames))
            let extractor = FrameExtractor()
            let rawFrames = try await extractor.extractFrames(
                from: videoURL,
                to: paths.framesRawURL,
                options: FrameExtractionOptions(targetCount: targetFrames, maxDimension: maxDim),
                progress: { fraction, message in emit(.stageProgress(stage: .extractFrames, fraction: fraction, message: message)) }
            )
            emit(.stageFinished(stage: .extractFrames))

            emit(.stageStarted(stage: .selectFrames))
            let selector = FrameSelector()
            let chosen = selector.selectFrames(from: rawFrames, targetCount: targetFrames) { fraction, message in
                emit(.stageProgress(stage: .selectFrames, fraction: fraction, message: message))
            }
            selectedFrames = try copySelected(chosen, to: paths.framesSelectedURL)
            emit(.stageFinished(stage: .selectFrames))
        case .photos:
            emit(.stageStarted(stage: .selectFrames))
            selectedFrames = try copyPhotosToSelected(paths: paths)
            emit(.stageFinished(stage: .selectFrames))
        }

        emit(.stageStarted(stage: .sfmFeatures))
        try tooling.colmap.runFeatureExtractor(
            colmapPath: config.toolchain.colmap,
            database: paths.colmapDatabaseURL,
            imagePath: paths.framesSelectedURL,
            maxImageSize: Int(maxDim),
            cameraModel: cameraModel(for: metadata.preset),
            onLog: { line, isErr in emit(.stageLog(stage: .sfmFeatures, line: line, isError: isErr)) }
        )
        emit(.stageFinished(stage: .sfmFeatures))

        emit(.stageStarted(stage: .sfmMatching))
        if shouldUseSequential(selectedFrames: selectedFrames) {
            try tooling.colmap.runMatcherSequential(
                colmapPath: config.toolchain.colmap,
                database: paths.colmapDatabaseURL,
                onLog: { line, isErr in emit(.stageLog(stage: .sfmMatching, line: line, isError: isErr)) }
            )
        } else {
            try tooling.colmap.runMatcherExhaustive(
                colmapPath: config.toolchain.colmap,
                database: paths.colmapDatabaseURL,
                onLog: { line, isErr in emit(.stageLog(stage: .sfmMatching, line: line, isError: isErr)) }
            )
        }
        emit(.stageFinished(stage: .sfmMatching))

        emit(.stageStarted(stage: .sfmMapping))
        var mappingSucceeded = false
        var lastMappingError: Error?

        for attempt in 1...2 {
            do {
                if attempt == 1 {
                    try tooling.glomap.runMapper(
                        glomapPath: config.toolchain.glomap,
                        database: paths.colmapDatabaseURL,
                        imagePath: paths.framesSelectedURL,
                        outputPath: paths.colmapSparseURL,
                        onLog: { line, isErr in emit(.stageLog(stage: .sfmMapping, line: line, isError: isErr)) }
                    )
                } else {
                    try tooling.colmap.runMapper(
                        colmapPath: config.toolchain.colmap,
                        database: paths.colmapDatabaseURL,
                        imagePath: paths.framesSelectedURL,
                        outputPath: paths.colmapSparseURL,
                        onLog: { line, isErr in emit(.stageLog(stage: .sfmMapping, line: line, isError: isErr)) }
                    )
                }

                let report = try tooling.colmap.runModelAnalyzer(colmapPath: config.toolchain.colmap, modelPath: paths.colmapSparseURL.appendingPathComponent("0"))
                let score = ReconstructionScorer.parseModelAnalyzerOutput(report)
                if ReconstructionScorer.isAcceptable(score, mode: metadata.preset.mode) {
                    mappingSucceeded = true
                    break
                } else {
                    lastMappingError = PipelineError.lowQualityReconstruction
                }
            } catch {
                lastMappingError = error
            }
        }

        guard mappingSucceeded else {
            emit(.pipelineFailed(stage: .sfmMapping, userMessage: "I couldn't get a stable camera solve. Try a slower capture and more light.", debugMessage: "\(lastMappingError ?? PipelineError.lowQualityReconstruction)"))
            throw lastMappingError ?? PipelineError.lowQualityReconstruction
        }
        emit(.stageFinished(stage: .sfmMapping))

        emit(.stageStarted(stage: .trainBrush))
        let datasetURL = try prepareBrushDataset(paths: paths)
        try tooling.brush.runTrain(
            brushPath: config.toolchain.brush,
            datasetPath: datasetURL,
            onLog: { line, isErr in emit(.stageLog(stage: .trainBrush, line: line, isError: isErr)) }
        )
        emit(.stageFinished(stage: .trainBrush))

        emit(.stageStarted(stage: .exportSplat))
        guard let ply = tooling.brush.findLatestPly(in: paths.trainingURL) else {
            throw PipelineError.outputMissing
        }
        let outputPly = paths.outputURL.appendingPathComponent("splat.ply")
        try SplatExport.copyIfExists(from: ply, to: outputPly)
        emit(.stageFinished(stage: .exportSplat))

        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        emit(.stageFinished(stage: .done))
    }
}

private extension PipelineRunner {
    enum PipelineError: Error {
        case invalidInput
        case lowQualityReconstruction
        case outputMissing
    }

    func importInputs(metadata: ProjectMetadata, paths: ProjectPaths) throws {
        let fm = FileManager.default
        switch metadata.input {
        case .video(let files):
            for file in files {
                let source = URL(fileURLWithPath: file)
                let dest = paths.originalsURL.appendingPathComponent(source.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: source, to: dest)
                }
            }
        case .photos(let folder):
            let sourceFolder = URL(fileURLWithPath: folder)
            let dest = paths.originalsURL.appendingPathComponent(sourceFolder.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: sourceFolder, to: dest)
            }
        }
    }

    func copySelected(_ frames: [URL], to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var output: [URL] = []
        for (index, url) in frames.enumerated() {
            let dest = directory.appendingPathComponent(String(format: "frame_%06d.jpg", index))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            output.append(dest)
        }
        return output
    }

    func copyPhotosToSelected(paths: ProjectPaths) throws -> [URL] {
        let fm = FileManager.default
        let originals = try fm.contentsOfDirectory(at: paths.originalsURL, includingPropertiesForKeys: nil)
        guard let photosFolder = originals.first(where: { $0.hasDirectoryPath }) else { return [] }
        let images = try fm.contentsOfDirectory(at: photosFolder, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var output: [URL] = []
        for (index, url) in images.enumerated() {
            let dest = paths.framesSelectedURL.appendingPathComponent(String(format: "frame_%06d.%@", index, url.pathExtension))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            output.append(dest)
        }
        return output
    }

    func framePreset(for quality: QualityPreset) -> (Int, CGFloat) {
        switch quality {
        case .draft: return (120, 1024)
        case .standard: return (250, 1600)
        case .ultra: return (500, 2048)
        }
    }

    func cameraModel(for preset: PresetSpec) -> String {
        if preset.mode == .room && preset.quality == .ultra {
            return "OPENCV"
        }
        return "SIMPLE_RADIAL"
    }

    func shouldUseSequential(selectedFrames: [URL]) -> Bool {
        return true
    }

    func prepareBrushDataset(paths: ProjectPaths) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent("dataset", isDirectory: true)
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        try fm.createDirectory(at: sparse, withIntermediateDirectories: true)

        let selected = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        for url in selected {
            let dest = images.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
        }

        let sourceSparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        if fm.fileExists(atPath: sourceSparse.path) {
            let files = try fm.contentsOfDirectory(at: sourceSparse, includingPropertiesForKeys: nil)
            for file in files {
                let dest = sparse.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
            }
        }
        return dataset
    }
}

private final class PipelineLogger: @unchecked Sendable {
    private let eventsURL: URL
    private let logURL: URL
    private let emit: @Sendable (PipelineEvent) -> Void
    private let encoder: JSONEncoder
    private let logHandle: FileHandle?
    private let eventsHandle: FileHandle?
    private let lock = NSLock()

    init(eventsURL: URL, logURL: URL, emit: @escaping @Sendable (PipelineEvent) -> Void) {
        self.eventsURL = eventsURL
        self.logURL = logURL
        self.emit = emit
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        self.logHandle = try? FileHandle(forWritingTo: logURL)
        self.eventsHandle = try? FileHandle(forWritingTo: eventsURL)
    }

    deinit {
        try? logHandle?.close()
        try? eventsHandle?.close()
    }

    func emit(_ event: PipelineEvent) {
        emit(event)
        lock.lock()
        appendEvent(event)
        if case let .stageLog(_, line, isError) = event {
            appendLogLine(line, isError: isError)
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

    private func appendLogLine(_ line: String, isError: Bool) {
        guard let handle = logHandle else { return }
        let prefix = isError ? "[err] " : ""
        if let data = "\(prefix)\(line)\n".data(using: .utf8) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}
