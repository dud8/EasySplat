import CryptoKit
import Foundation
import MetalSplatter

/// Renders a list of held-out cameras from one PLY so they can be scored against ground truth.
///
/// This is deliberately not `BenchmarkRenderJob`. That path serves the release gate: it pins
/// ground truth to a signed artifact root and refuses any job whose training set includes a
/// held-out index, neither of which a research sweep over a public dataset can satisfy. What
/// the two share is the part that decides the numbers -- `MetalOffscreenRenderer`, and so one
/// `SplatRenderer` configuration and one sort ordering for every figure either lane produces.
///
/// That sharing is the reason this exists at all. The mip-NeRF 360 harness used to carry its
/// own copy of the renderer, which named a MetalSplatter by absolute path and defaulted the
/// sort ordering. Both went wrong, and the second was worth up to 1.33 dB. Built from this
/// package there is exactly one MetalSplatter to resolve and no ordering to choose.
public enum HeldOutViewRendering {
    public struct View: Decodable, Sendable {
        public var name: String
        public var camera: RenderCamera

        public init(name: String, camera: RenderCamera) {
            self.name = name
            self.camera = camera
        }

        public init(from decoder: Decoder) throws {
            name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .name)
            // The camera keys sit alongside `name` rather than under it, matching the request
            // the scorer already writes. Decoding `RenderCamera` from the same decoder reuses
            // its coding keys and its Double-to-Float narrowing instead of restating them.
            camera = try RenderCamera(from: decoder)
        }

        private enum CodingKeys: String, CodingKey {
            case name
        }
    }

    public struct Request: Decodable, Sendable {
        public var ply: String
        public var outputDirectory: String
        public var views: [View]

        public init(ply: String, outputDirectory: String, views: [View]) {
            self.ply = ply
            self.outputDirectory = outputDirectory
            self.views = views
        }

        private enum CodingKeys: String, CodingKey {
            case ply
            case outputDirectory = "output_dir"
            case views
        }
    }

    public struct Result: Encodable, Equatable, Sendable {
        public var name: String
        public var path: String
        public var renderSeconds: Double

        private enum CodingKeys: String, CodingKey {
            case name
            case path
            case renderSeconds = "render_seconds"
        }
    }

    /// What produced the numbers. Every field here answers a question that has actually been
    /// asked of a benchmark row and could not be answered afterwards.
    public struct Provenance: Encodable, Equatable, Sendable {
        public var sortOrdering: String
        public var rendererExecutableSHA256: String
        public var metalSplatterSourceSHA256: String
        public var cameraSetDigest: String
        public var plySHA256: String
        public var gitCommit: String
        public var workingTreeDirty: Bool

        private enum CodingKeys: String, CodingKey {
            case sortOrdering = "sort_ordering"
            case rendererExecutableSHA256 = "renderer_executable_sha256"
            case metalSplatterSourceSHA256 = "metalsplatter_source_sha256"
            case cameraSetDigest = "camera_set_digest"
            case plySHA256 = "ply_sha256"
            case gitCommit = "git_commit"
            case workingTreeDirty = "working_tree_dirty"
        }
    }

    public struct Manifest: Encodable, Sendable {
        public var ply: String
        public var splatCount: Int
        public var loadSeconds: Double
        public var sortSeconds: Double
        public var totalRenderSeconds: Double
        public var peakMetalAllocatedBytes: UInt64
        public var provenance: Provenance
        public var views: [Result]

        private enum CodingKeys: String, CodingKey {
            case ply
            case splatCount = "splat_count"
            case loadSeconds = "load_seconds"
            case sortSeconds = "sort_seconds"
            case totalRenderSeconds = "total_render_seconds"
            case peakMetalAllocatedBytes = "peak_metal_allocated_bytes"
            case provenance
            case views
        }
    }

    /// A stable name for the ordering the renderer was built with.
    ///
    /// Exhaustive on purpose: adding a third ordering to MetalSplatter should fail this build
    /// rather than let a manifest keep reporting one of the first two.
    public static func describe(_ ordering: SplatRenderer.SortOrdering) -> String {
        switch ordering {
        case .euclideanCameraDistance: "euclidean_camera_distance"
        case .cameraForwardDepth: "camera_forward_depth"
        }
    }

    /// A digest over MetalSplatter's sources, so an uncommitted shader edit cannot hide behind
    /// a commit hash. Paths are relative and sorted, and both path and contents are hashed --
    /// a renamed file has to change the digest or the digest is not describing the tree.
    public static func sourceDigest(directory: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walk = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            throw BenchmarkDriverError.invalidJob("The MetalSplatter source tree is unreadable.")
        }
        let prefix = directory.standardizedFileURL.path
        var files: [(String, URL)] = []
        for case let url as URL in walk {
            guard try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            files.append((String(path.dropFirst(prefix.count)), url))
        }
        guard !files.isEmpty else {
            throw BenchmarkDriverError.invalidJob("The MetalSplatter source tree is empty.")
        }
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat MetalSplatter source digest v1\0".utf8))
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
            hasher.update(data: Data([0]))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of the camera set as a whole, folded from each camera's own stable digest.
    /// A changed holdout split or a changed intrinsic rescale moves this, and would otherwise
    /// present as a quality delta.
    public static func cameraSetDigest(views: [View]) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat camera set digest v1\0".utf8))
        for view in views {
            hasher.update(data: Data(view.name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(try view.camera.stableDigest().utf8))
            hasher.update(data: Data([0]))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Where a rendered view is written. The ground-truth name keeps its original extension so
    /// the scorer can find the source image; only the rendered file becomes a PNG.
    public static func outputURL(forView name: String, in directory: URL) throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty, !stem.contains("/"), stem != ".", stem != ".." else {
            throw BenchmarkDriverError.invalidJob("A held-out view name is not a plain filename.")
        }
        return directory.appendingPathComponent(stem + ".png")
    }
}

public struct HeldOutViewRenderer {
    typealias LoadScene = (URL) throws -> any LoadedSceneRendering

    private let loadScene: LoadScene
    private let allocatedBytes: () -> UInt64
    private let checkoutRoot: URL

    public init(renderer: MetalOffscreenRenderer, checkoutRoot: URL) {
        self.init(
            loadScene: renderer.loadScene,
            allocatedBytes: { renderer.currentAllocatedBytes },
            checkoutRoot: checkoutRoot
        )
    }

    init(
        loadScene: @escaping LoadScene,
        allocatedBytes: @escaping () -> UInt64,
        checkoutRoot: URL
    ) {
        self.loadScene = loadScene
        self.allocatedBytes = allocatedBytes
        self.checkoutRoot = checkoutRoot
    }

    public func execute(
        request: HeldOutViewRendering.Request,
        rendererExecutableURL: URL
    ) throws -> HeldOutViewRendering.Manifest {
        guard !request.views.isEmpty else {
            throw BenchmarkDriverError.invalidJob("A held-out render request has no views.")
        }
        var seen = Set<String>()
        for view in request.views where !seen.insert(view.name).inserted {
            throw BenchmarkDriverError.invalidJob("A held-out view name is repeated: \(view.name).")
        }

        let plyURL = URL(fileURLWithPath: request.ply)
        let outputDirectory = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let loadStart = Date()
        let scene = try loadScene(plyURL)
        let loadSeconds = Date().timeIntervalSince(loadStart)

        var results: [HeldOutViewRendering.Result] = []
        var totalRenderSeconds = 0.0
        var peakAllocatedBytes: UInt64 = 0
        for view in request.views {
            let outputURL = try HeldOutViewRendering.outputURL(
                forView: view.name,
                in: outputDirectory
            )
            let start = Date()
            _ = try scene.render(camera: view.camera, outputURL: outputURL)
            let seconds = Date().timeIntervalSince(start)
            totalRenderSeconds += seconds
            peakAllocatedBytes = max(peakAllocatedBytes, allocatedBytes())
            results.append(
                HeldOutViewRendering.Result(
                    name: view.name,
                    path: outputURL.path,
                    renderSeconds: seconds
                )
            )
        }

        let checkout = try CheckoutSnapshot.describe(root: checkoutRoot)
        return HeldOutViewRendering.Manifest(
            ply: request.ply,
            splatCount: scene.splatCount,
            loadSeconds: loadSeconds,
            // The scene blocks on its sort inside the first render, so it is not separable
            // here. Reported as zero rather than as a fabricated split of the render time.
            sortSeconds: 0,
            totalRenderSeconds: totalRenderSeconds,
            peakMetalAllocatedBytes: peakAllocatedBytes,
            provenance: HeldOutViewRendering.Provenance(
                sortOrdering: HeldOutViewRendering.describe(MetalOffscreenRenderer.sortOrdering),
                rendererExecutableSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: rendererExecutableURL
                ),
                metalSplatterSourceSHA256: try HeldOutViewRendering.sourceDigest(
                    directory: checkoutRoot
                        .appendingPathComponent("ThirdParty/MetalSplatter/MetalSplatter/Sources")
                ),
                cameraSetDigest: try HeldOutViewRendering.cameraSetDigest(views: request.views),
                plySHA256: try MetalOffscreenRenderer.sha256(fileAt: plyURL),
                gitCommit: checkout.commit,
                workingTreeDirty: checkout.dirty
            ),
            views: results
        )
    }
}
