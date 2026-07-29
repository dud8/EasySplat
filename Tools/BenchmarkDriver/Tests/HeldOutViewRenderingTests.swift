import Foundation
import XCTest
@testable import EasySplatBenchmarkDriverCore

/// The mip-NeRF 360 harness used to carry its own renderer, and the two things it got wrong
/// were the ones nothing checked: which MetalSplatter it linked, and which sort ordering it
/// asked for. These tests hold the replacement to the contract the scorer reads and to the
/// provenance that makes a benchmark row attributable afterwards.
final class HeldOutViewRenderingTests: XCTestCase {
    private func makeCamera(seed: Float = 1) -> RenderCamera {
        RenderCamera(
            width: 8,
            height: 6,
            projectionMatrixColumnMajor: (0..<16).map { Float($0) * seed },
            worldToCameraMatrixColumnMajor: (0..<16).map { Float(15 - $0) * seed }
        )
    }

    /// The scene is stubbed, but the manifest still digests the PLY it was handed, so the
    /// path has to be a real file.
    private func makeRequest(
        in directory: URL,
        names: [String]
    ) throws -> HeldOutViewRendering.Request {
        let ply = directory.appendingPathComponent("scene.ply")
        try Data("ply\nformat binary_little_endian 1.0\n".utf8).write(to: ply, options: .atomic)
        return HeldOutViewRendering.Request(
            ply: ply.path,
            outputDirectory: directory.appendingPathComponent("renders", isDirectory: true).path,
            views: names.enumerated().map { index, name in
                HeldOutViewRendering.View(name: name, camera: makeCamera(seed: Float(index + 1)))
            }
        )
    }

    private func run(
        request: HeldOutViewRendering.Request,
        splatCount: Int = 4321,
        render: @escaping (RenderCamera, URL) throws -> Void = { _, output in
            try Data("rendered".utf8).write(to: output, options: .atomic)
        }
    ) throws -> HeldOutViewRendering.Manifest {
        let renderer = HeldOutViewRenderer(
            loadScene: { _ in
                StubScene(splatCount: splatCount) { camera, output in
                    try render(camera, output)
                    return try MetalOffscreenRenderer.sha256(fileAt: output)
                }
            },
            allocatedBytes: { 1_234 },
            checkoutRoot: repositoryRoot
        )
        return try renderer.execute(
            request: request,
            rendererExecutableURL: URL(fileURLWithPath: #filePath)
        )
    }

    // MARK: - The scorer's contract

    func testRequestDecodesTheShapeTheScorerWrites() throws {
        let json = """
        {
          "ply": "/tmp/scene.ply",
          "output_dir": "/tmp/renders",
          "views": [
            {
              "name": "DSC_0001.JPG",
              "width": 1237,
              "height": 822,
              "projection_matrix_column_major": [\(Array(repeating: "0.5", count: 16).joined(separator: ","))],
              "world_to_camera_matrix_column_major": [\(Array(repeating: "0.25", count: 16).joined(separator: ","))]
            }
          ]
        }
        """
        let request = try JSONDecoder().decode(
            HeldOutViewRendering.Request.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(request.ply, "/tmp/scene.ply")
        XCTAssertEqual(request.outputDirectory, "/tmp/renders")
        XCTAssertEqual(request.views.count, 1)
        XCTAssertEqual(request.views[0].name, "DSC_0001.JPG")
        XCTAssertEqual(request.views[0].camera.width, 1237)
        XCTAssertEqual(request.views[0].camera.height, 822)
        XCTAssertEqual(request.views[0].camera.projectionMatrixColumnMajor.first, 0.5)
        XCTAssertEqual(request.views[0].camera.worldToCameraMatrixColumnMajor.last, 0.25)
    }

    func testManifestKeepsTheGroundTruthNameAndWritesAPNGBesideIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try run(
            request: try makeRequest(in: directory, names: ["DSC_0001.JPG", "DSC_0009.JPG"])
        )

        // The scorer looks the ground truth up by `name` and the render up by `path`, so the
        // name has to survive with its original extension while only the file becomes a PNG.
        XCTAssertEqual(manifest.views.map(\.name), ["DSC_0001.JPG", "DSC_0009.JPG"])
        XCTAssertEqual(
            manifest.views.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            ["DSC_0001.png", "DSC_0009.png"]
        )
        for view in manifest.views {
            XCTAssertTrue(FileManager.default.fileExists(atPath: view.path))
        }
        XCTAssertEqual(manifest.splatCount, 4321)
        XCTAssertEqual(manifest.peakMetalAllocatedBytes, 1_234)
    }

    func testViewsAreRenderedInRequestOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let order = Recorder()

        _ = try run(
            request: try makeRequest(in: directory, names: ["c.JPG", "a.JPG", "b.JPG"]),
            render: { _, output in
                order.append(output.lastPathComponent)
                try Data("rendered".utf8).write(to: output, options: .atomic)
            }
        )

        // The scorer pairs by name rather than by position, so a reordering would not corrupt
        // a score -- but it would make two runs of the same arm disagree on render_seconds.
        XCTAssertEqual(order.values, ["c.png", "a.png", "b.png"])
    }

    func testEncodedManifestUsesTheKeysTheScorerReads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try run(
            request: try makeRequest(in: directory, names: ["only.JPG"])
        )
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(manifest)
        ) as? [String: Any]
        let object = try XCTUnwrap(encoded)
        for key in ["ply", "splat_count", "load_seconds", "peak_metal_allocated_bytes", "views"] {
            XCTAssertNotNil(object[key], "the scorer reads \(key)")
        }
        let views = try XCTUnwrap(object["views"] as? [[String: Any]])
        for key in ["name", "path", "render_seconds"] {
            XCTAssertNotNil(views.first?[key], "the scorer reads views[].\(key)")
        }
    }

    // MARK: - Provenance

    func testProvenanceStatesTheOrderingTheRendererWasBuiltWith() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try run(
            request: try makeRequest(in: directory, names: ["only.JPG"])
        )
        // The single field that would have caught the harness bug with one grep.
        XCTAssertEqual(manifest.provenance.sortOrdering, "camera_forward_depth")
        XCTAssertEqual(
            HeldOutViewRendering.describe(.euclideanCameraDistance),
            "euclidean_camera_distance"
        )
        XCTAssertTrue(manifest.provenance.metalSplatterSourceSHA256.hasPrefix("sha256:"))
        XCTAssertTrue(manifest.provenance.plySHA256.hasPrefix("sha256:"))
        XCTAssertTrue(manifest.provenance.cameraSetDigest.hasPrefix("sha256:"))
        XCTAssertEqual(manifest.provenance.gitCommit.count, 40)
    }

    func testCameraSetDigestMovesWithTheSplitAndWithTheIntrinsics() throws {
        let base = [
            HeldOutViewRendering.View(name: "a.JPG", camera: makeCamera(seed: 1)),
            HeldOutViewRendering.View(name: "b.JPG", camera: makeCamera(seed: 2)),
        ]
        let digest = try HeldOutViewRendering.cameraSetDigest(views: base)

        XCTAssertEqual(try HeldOutViewRendering.cameraSetDigest(views: base), digest)
        // A dropped view: a changed holdout rule would otherwise present as a quality delta.
        XCTAssertNotEqual(
            try HeldOutViewRendering.cameraSetDigest(views: [base[0]]),
            digest
        )
        // A reordered set is a different set of render_seconds, so it is a different digest.
        XCTAssertNotEqual(
            try HeldOutViewRendering.cameraSetDigest(views: base.reversed()),
            digest
        )
        // A changed intrinsic rescale with the same names and count.
        XCTAssertNotEqual(
            try HeldOutViewRendering.cameraSetDigest(views: [
                base[0],
                HeldOutViewRendering.View(name: "b.JPG", camera: makeCamera(seed: 3)),
            ]),
            digest
        )
    }

    func testSourceDigestCoversPathsAsWellAsContents() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("shader".utf8).write(to: nested.appendingPathComponent("a.metal"))
        let digest = try HeldOutViewRendering.sourceDigest(directory: directory)

        XCTAssertEqual(try HeldOutViewRendering.sourceDigest(directory: directory), digest)

        try Data("shader edited".utf8).write(to: nested.appendingPathComponent("a.metal"))
        let edited = try HeldOutViewRendering.sourceDigest(directory: directory)
        XCTAssertNotEqual(edited, digest)

        // A rename with identical bytes: the commit hash would not move for an uncommitted
        // one, so the digest has to.
        try FileManager.default.moveItem(
            at: nested.appendingPathComponent("a.metal"),
            to: nested.appendingPathComponent("b.metal")
        )
        XCTAssertNotEqual(try HeldOutViewRendering.sourceDigest(directory: directory), edited)
    }

    func testSourceDigestRefusesAnEmptyOrAbsentTree() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try HeldOutViewRendering.sourceDigest(directory: directory))
        XCTAssertThrowsError(
            try HeldOutViewRendering.sourceDigest(
                directory: directory.appendingPathComponent("absent", isDirectory: true)
            )
        )
    }

    // MARK: - Refusals

    func testRepeatedAndUnusableViewNamesAreRefused() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renders = directory.appendingPathComponent("renders", isDirectory: true)

        // Two views sharing a name would render over each other and score the survivor twice.
        XCTAssertThrowsError(
            try run(request: try makeRequest(in: directory, names: ["same.JPG", "same.JPG"]))
        )
        // A name that is a path escapes the output directory.
        XCTAssertThrowsError(
            try HeldOutViewRendering.outputURL(forView: "../escape.JPG", in: renders)
        )
        XCTAssertThrowsError(
            try HeldOutViewRendering.outputURL(forView: "nested/view.JPG", in: renders)
        )
    }

    func testAnEmptyRequestIsRefusedRatherThanScoredAsPerfect() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(
            try run(
                request: HeldOutViewRendering.Request(
                    ply: directory.appendingPathComponent("scene.ply").path,
                    outputDirectory: directory.appendingPathComponent("renders").path,
                    views: []
                )
            )
        )
    }

    func testANonFiniteCameraIsRefusedBeforeAnythingIsRendered() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = HeldOutViewRendering.View(
            name: "bad.JPG",
            camera: RenderCamera(
                width: 8,
                height: 6,
                projectionMatrixColumnMajor: [.nan] + Array(repeating: Float(0), count: 15),
                worldToCameraMatrixColumnMajor: Array(repeating: Float(0), count: 16)
            )
        )
        XCTAssertThrowsError(try HeldOutViewRendering.cameraSetDigest(views: [broken]))
    }

    // MARK: - Helpers

    private var repositoryRoot: URL {
        // Tests/<file> -> Tests -> BenchmarkDriver -> Tools -> repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-out-views-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class StubScene: LoadedSceneRendering {
    let splatCount: Int
    private let body: (RenderCamera, URL) throws -> String

    init(splatCount: Int, body: @escaping (RenderCamera, URL) throws -> String) {
        self.splatCount = splatCount
        self.body = body
    }

    func render(camera: RenderCamera, outputURL: URL) throws -> String {
        try body(camera, outputURL)
    }
}
