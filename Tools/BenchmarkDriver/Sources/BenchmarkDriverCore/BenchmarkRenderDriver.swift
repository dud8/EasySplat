import CryptoKit
import Darwin
import Foundation

public final class BenchmarkRenderDriver {
    typealias RenderImage = (URL, RenderCamera, URL) throws -> String
    typealias LoadScene = (URL) throws -> any LoadedSceneRendering

    private let loadScene: LoadScene

    public convenience init(renderer: MetalOffscreenRenderer) {
        self.init(loadScene: renderer.loadScene)
    }

    init(renderImage: @escaping RenderImage) {
        self.loadScene = { source in
            ClosureLoadedScene { camera, output in
                try renderImage(source, camera, output)
            }
        }
    }

    init(loadScene: @escaping LoadScene) {
        self.loadScene = loadScene
    }

    @discardableResult
    public func execute(
        job: BenchmarkRenderJob,
        artifactRoot: URL,
        manifestURL: URL,
        rendererExecutableURL: URL
    ) throws -> URL {
        try job.validate()
        let artifacts = try ArtifactRoot(root: artifactRoot)
        let expectedManifest = try artifacts.outputURL(for: "rendering-manifest.json")
        guard manifestURL.standardizedFileURL == expectedManifest.standardizedFileURL else {
            throw BenchmarkDriverError.invalidJob(
                "The rendering manifest must be written at the artifact-root contract path."
            )
        }
        let executable = try Self.regularFile(rendererExecutableURL, label: "renderer executable")
        let rendererExecutableSHA256 = try MetalOffscreenRenderer.sha256(fileAt: executable)
        guard rendererExecutableSHA256 == job.rendererExecutableSHA256 else {
            throw BenchmarkDriverError.invalidJob(
                "The running benchmark renderer is not the executable approved by the render job."
            )
        }

        let candidate = try CheckoutSnapshot.capture(
            root: URL(fileURLWithPath: job.candidateCheckout.path, isDirectory: true)
        )
        let baseline = try CheckoutSnapshot.capture(
            root: URL(fileURLWithPath: job.baselineCheckout.path, isDirectory: true)
        )
        guard candidate.root != baseline.root,
              candidate.commit == job.candidateCheckout.commit,
              baseline.commit == job.baselineCheckout.commit else {
            throw BenchmarkDriverError.invalidJob("A render checkout does not match its signed commit.")
        }

        let groundTruthInputs = try job.views.enumerated().map { position, view in
            try StableArtifactInput.capture(
                artifactRoot: artifacts.root,
                relativePath: view.groundTruth.path,
                expectedSHA256: view.groundTruth.sha256,
                label: "held-out ground-truth image \(position)"
            )
        }
        let cameraDigests = try job.views.map { try Self.digest(of: $0.camera) }
        let snapshots = try RenderInputSnapshotDirectory()
        var rendersByView = Array(
            repeating: [RenderVariant: RenderingManifestRender](),
            count: job.views.count
        )
        var renderOperations = [RenderOperationReceipt]()
        var previousCommandEnd = 0.0

        func verifyProtectedState() throws {
            for input in groundTruthInputs {
                try input.verifyUnchanged()
            }
            try candidate.verifyUnchanged()
            try baseline.verifyUnchanged()
        }

        do {
            for (sourceIndex, variant) in RenderVariant.allCases.enumerated() {
                let immutableSource = job.views[0].sources[sourceIndex]
                guard immutableSource.variant == variant else {
                    throw BenchmarkDriverError.invalidJob(
                        "Render sources must use the canonical variant order."
                    )
                }
                let snapshot = try snapshots.copy(
                    artifactRoot: artifacts.root,
                    relativePath: immutableSource.plyPath,
                    expectedSHA256: immutableSource.plySHA256,
                    filename: "\(variant.rawValue).ply"
                )
                let loadedScene = try loadScene(snapshot.url)
                try snapshot.verifyUnchanged()

                for (viewIndex, view) in job.views.enumerated() {
                    let source = view.sources[sourceIndex]
                    let cameraDigest = cameraDigests[viewIndex]
                    let outputURL = try artifacts.outputURL(for: source.outputPath)
                    let operationID = "render-\(String(format: "%06d", view.holdoutIndex))-\(source.variant.rawValue)"
                    let started = max(ProcessInfo.processInfo.systemUptime, previousCommandEnd)
                    let reportedOutputSHA = try loadedScene.render(
                        camera: view.camera,
                        outputURL: outputURL
                    )
                    let actualOutputSHA = try MetalOffscreenRenderer.sha256(fileAt: outputURL)
                    guard reportedOutputSHA == actualOutputSHA else {
                        throw BenchmarkDriverError.renderFailed(
                            "The renderer output digest does not match the written PNG."
                        )
                    }
                    let ended = max(ProcessInfo.processInfo.systemUptime, started.nextUp)
                    previousCommandEnd = ended
                    rendersByView[viewIndex][source.variant] = RenderingManifestRender(
                        variant: source.variant,
                        path: source.outputPath,
                        sha256: actualOutputSHA,
                        cameraDigest: cameraDigest,
                        sourceRunID: source.runID,
                        plySHA256: source.plySHA256,
                        rendererExecutableSHA256: rendererExecutableSHA256,
                        renderOperationID: operationID
                    )
                    renderOperations.append(
                        RenderOperationReceipt(
                            operationID: operationID,
                            holdoutIndex: view.holdoutIndex,
                            variant: source.variant,
                            rendererExecutableSHA256: rendererExecutableSHA256,
                            sourceRunID: source.runID,
                            sourceCheckoutCommit: source.checkoutCommit,
                            sourceToolchainIdentity: source.toolchainIdentity,
                            sourceExecutableSHA256: source.sourceExecutableSHA256,
                            inputPlySHA256: source.plySHA256,
                            cameraDigest: cameraDigest,
                            outputSHA256: actualOutputSHA,
                            startedMonotonicSeconds: started,
                            endedMonotonicSeconds: ended,
                            status: "completed"
                        )
                    )
                }
                try snapshot.verifyUnchanged()
            }
        } catch {
            try verifyProtectedState()
            throw error
        }

        try verifyProtectedState()
        let manifestViews = try job.views.enumerated().map { viewIndex, view in
            let renders = try RenderVariant.allCases.map { variant in
                guard let render = rendersByView[viewIndex][variant] else {
                    throw BenchmarkDriverError.renderFailed(
                        "A held-out render is missing from the canonical evidence order."
                    )
                }
                return render
            }
            return RenderingManifestView(
                holdoutIndex: view.holdoutIndex,
                camera: view.camera,
                cameraDigest: cameraDigests[viewIndex],
                groundTruth: ManifestGroundTruth(
                    path: view.groundTruth.path,
                    sha256: groundTruthInputs[viewIndex].fingerprint.sha256,
                    inputDigest: job.inputDigest
                ),
                renders: renders
            )
        }

        let manifest = RenderingManifest(
            schemaVersion: 1,
            sceneID: job.sceneID,
            scale: job.scale,
            requestDigest: job.requestDigest,
            inputDigest: job.inputDigest,
            holdoutIndices: job.holdoutIndices,
            trainingViewIndices: job.trainingViewIndices,
            colorSpace: "srgb",
            pixelFormat: "png_rgb8",
            rendererClosureSHA256: job.rendererClosureSHA256,
            rendererExecutableSHA256: rendererExecutableSHA256,
            renderOperations: renderOperations,
            views: manifestViews
        )
        let data = try Self.canonicalJSON(manifest)
        try data.write(to: manifestURL, options: .atomic)
        try verifyProtectedState()
        return manifestURL
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8)
    }

    private static func digest<T: Encodable>(of value: T) throws -> String {
        var data = try canonicalJSON(value)
        if data.last == Character("\n").asciiValue { data.removeLast() }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func regularFile(_ url: URL, label: String) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.isFileURL,
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw BenchmarkDriverError.invalidJob("The \(label) is not a regular file.")
        }
        return resolved
    }
}

private final class ClosureLoadedScene: LoadedSceneRendering {
    private let renderImage: (RenderCamera, URL) throws -> String

    init(renderImage: @escaping (RenderCamera, URL) throws -> String) {
        self.renderImage = renderImage
    }

    func render(camera: RenderCamera, outputURL: URL) throws -> String {
        try renderImage(camera, outputURL)
    }
}

struct ArtifactRoot {
    let root: URL

    init(root: URL) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isFileURL,
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw BenchmarkDriverError.invalidJob("The render artifact root is not a real directory.")
        }
        self.root = resolved
    }

    func outputURL(for relativePath: String) throws -> URL {
        let url = try containedURL(for: relativePath, requireExisting: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkDriverError.invalidJob("A render output already exists.")
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolvedParent) else {
            throw BenchmarkDriverError.invalidJob("A render output escapes the artifact root.")
        }
        return url
    }

    private func containedURL(for relativePath: String, requireExisting: Bool = true) throws -> URL {
        guard BenchmarkRenderJob.isSafeRelativePath(relativePath) else {
            throw BenchmarkDriverError.invalidJob("A render artifact path is unsafe.")
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        try rejectSymlinkAncestors(of: candidate, requireFinalEntry: requireExisting)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved), !requireExisting || FileManager.default.fileExists(atPath: resolved.path) else {
            throw BenchmarkDriverError.invalidJob("A render artifact escapes the artifact root or is missing.")
        }
        return resolved
    }

    private func rejectSymlinkAncestors(
        of candidate: URL,
        requireFinalEntry: Bool
    ) throws {
        let components = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard components.starts(with: rootComponents) else {
            throw BenchmarkDriverError.invalidJob("A render artifact escapes the artifact root.")
        }
        var cursor = root
        let remaining = components.dropFirst(rootComponents.count)
        for (offset, component) in remaining.enumerated() {
            cursor.appendPathComponent(component)
            var metadata = stat()
            let status = cursor.path.withCString { lstat($0, &metadata) }
            let isFinal = offset == remaining.count - 1
            if status != 0 {
                if errno == ENOENT && (!requireFinalEntry || !isFinal) {
                    continue
                }
                throw BenchmarkDriverError.invalidJob("A render artifact is missing.")
            }
            if (metadata.st_mode & S_IFMT) == S_IFLNK {
                throw BenchmarkDriverError.invalidJob(
                    "A render artifact path contains a symbolic link."
                )
            }
            if !isFinal && (metadata.st_mode & S_IFMT) != S_IFDIR {
                throw BenchmarkDriverError.invalidJob(
                    "A render artifact ancestor is not a directory."
                )
            }
        }
    }

    private func contains(_ url: URL) -> Bool {
        url == root || url.path.hasPrefix(root.path + "/")
    }
}

private struct RenderingManifest: Encodable {
    let schemaVersion: Int
    let sceneID: String
    let scale: Int
    let requestDigest: String
    let inputDigest: String
    let holdoutIndices: [Int]
    let trainingViewIndices: [Int]
    let colorSpace: String
    let pixelFormat: String
    let rendererClosureSHA256: String
    let rendererExecutableSHA256: String
    let renderOperations: [RenderOperationReceipt]
    let views: [RenderingManifestView]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sceneID = "scene_id"
        case scale
        case requestDigest = "request_digest"
        case inputDigest = "input_digest"
        case holdoutIndices = "holdout_indices"
        case trainingViewIndices = "training_view_indices"
        case colorSpace = "color_space"
        case pixelFormat = "pixel_format"
        case rendererClosureSHA256 = "renderer_closure_sha256"
        case rendererExecutableSHA256 = "renderer_executable_sha256"
        case renderOperations = "render_operations"
        case views
    }
}

private struct RenderingManifestView: Encodable {
    let holdoutIndex: Int
    let camera: RenderCamera
    let cameraDigest: String
    let groundTruth: ManifestGroundTruth
    let renders: [RenderingManifestRender]

    enum CodingKeys: String, CodingKey {
        case holdoutIndex = "holdout_index"
        case camera
        case cameraDigest = "camera_digest"
        case groundTruth = "ground_truth"
        case renders
    }
}

private struct ManifestGroundTruth: Encodable {
    let path: String
    let sha256: String
    let inputDigest: String

    enum CodingKeys: String, CodingKey {
        case path, sha256
        case inputDigest = "input_digest"
    }
}

private struct RenderingManifestRender: Encodable {
    let variant: RenderVariant
    let path: String
    let sha256: String
    let cameraDigest: String
    let sourceRunID: String
    let plySHA256: String
    let renderer = "MetalSplatter"
    let rendererExecutableSHA256: String
    let renderOperationID: String

    enum CodingKeys: String, CodingKey {
        case variant, path, sha256
        case cameraDigest = "camera_digest"
        case sourceRunID = "source_run_id"
        case plySHA256 = "ply_sha256"
        case renderer
        case rendererExecutableSHA256 = "renderer_executable_sha256"
        case renderOperationID = "render_operation_id"
    }
}

private struct RenderOperationReceipt: Encodable {
    let operationID: String
    let holdoutIndex: Int
    let variant: RenderVariant
    let rendererExecutableSHA256: String
    let sourceRunID: String
    let sourceCheckoutCommit: String
    let sourceToolchainIdentity: String
    let sourceExecutableSHA256: String
    let inputPlySHA256: String
    let cameraDigest: String
    let outputSHA256: String
    let startedMonotonicSeconds: Double
    let endedMonotonicSeconds: Double
    let status: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case holdoutIndex = "holdout_index"
        case variant
        case rendererExecutableSHA256 = "renderer_executable_sha256"
        case sourceRunID = "source_run_id"
        case sourceCheckoutCommit = "source_checkout_commit"
        case sourceToolchainIdentity = "source_toolchain_identity"
        case sourceExecutableSHA256 = "source_executable_sha256"
        case inputPlySHA256 = "input_ply_sha256"
        case cameraDigest = "camera_digest"
        case outputSHA256 = "output_sha256"
        case startedMonotonicSeconds = "started_monotonic_seconds"
        case endedMonotonicSeconds = "ended_monotonic_seconds"
        case status
    }
}
