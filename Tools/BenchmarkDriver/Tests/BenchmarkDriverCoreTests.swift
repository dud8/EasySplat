import Foundation
import ImageIO
import Metal
import XCTest
@testable import EasySplatBenchmarkDriverCore

final class BenchmarkDriverCoreTests: XCTestCase {
    func testValidationRejectsHeldOutViewInTrainingSelection() throws {
        var job = makeJob()
        job.trainingViewIndices.append(4)

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("excluded from training"))
        }
    }

    func testValidationRejectsMisorderedViewsAndSources() throws {
        var misorderedViews = makeJob()
        misorderedViews.views.reverse()
        XCTAssertThrowsError(try misorderedViews.validate())

        var misorderedSources = makeJob()
        misorderedSources.views[0].sources.swapAt(0, 1)
        XCTAssertThrowsError(try misorderedSources.validate())
    }

    func testValidationRejectsMixedSourceRunAcrossHoldouts() throws {
        var job = makeJob()
        job.views[1].sources[2].runID = "different-candidate-run"

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("one immutable source"),
                error.localizedDescription
            )
        }
    }

    func testValidationRejectsMixedSourcePLYAcrossHoldouts() throws {
        var job = makeJob()
        job.views[1].sources[2].plySHA256 = digest("9")

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("one immutable source"),
                error.localizedDescription
            )
        }
    }

    func testValidationRejectsRenderTargetsAbovePixelBudget() throws {
        var job = makeJob()
        job.views[0].camera.width = 4_096
        job.views[0].camera.height = 2_048

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("render camera"))
        }
    }

    func testRendererFailsWhenMetalIsUnavailable() {
        XCTAssertThrowsError(try MetalOffscreenRenderer(device: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Metal is unavailable"))
        }
    }

    func testSortFailureWakesImmediately() {
        let started = ContinuousClock.now

        XCTAssertThrowsError(
            try MetalOffscreenRenderer.awaitSort(timeout: .seconds(5)) { finish in
                finish(.failure("synthetic sort failure"))
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("synthetic sort failure"))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCheckoutSnapshotDetectsMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "--quiet"], at: root)
        try "fixture\n".write(
            to: root.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "fixture.txt"], at: root)
        try runGit(
            [
                "-c", "user.name=EasySplat Tests",
                "-c", "user.email=tests@easysplat.invalid",
                "commit", "--quiet", "-m", "fixture",
            ],
            at: root
        )
        let snapshot = try CheckoutSnapshot.capture(root: root)

        try "changed\n".write(
            to: root.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try snapshot.verifyUnchanged()) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed during rendering"))
        }
    }

    func testDriverWritesBoundManifestAndOneReceiptPerRender() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try makeCheckout(at: root.appendingPathComponent("candidate"))
        let baseline = try makeCheckout(at: root.appendingPathComponent("baseline"))
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("benchmark-driver")
        try Data("renderer executable".utf8).write(to: executable)
        let groundTruth = artifacts.appendingPathComponent("ground-truth.png")
        try Data("ground truth".utf8).write(to: groundTruth)

        let sources = try RenderVariant.allCases.map { variant -> RenderSource in
            let sourcePath = "sources/\(variant.rawValue).ply"
            let sourceURL = artifacts.appendingPathComponent(sourcePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ply \(variant.rawValue)".utf8).write(to: sourceURL)
            return RenderSource(
                variant: variant,
                runID: "\(variant.rawValue)-run",
                checkoutCommit: variant == .pairedBaseline ? baseline.commit : candidate.commit,
                toolchainIdentity: digest("4"),
                sourceExecutableSHA256: digest("6"),
                plyPath: sourcePath,
                plySHA256: try MetalOffscreenRenderer.sha256(fileAt: sourceURL),
                outputPath: "rendering/\(variant.rawValue)/000001.png"
            )
        }
        let job = BenchmarkRenderJob(
            schemaVersion: 1,
            sceneID: "orbit-01",
            scale: 2,
            requestDigest: digest("0"),
            inputDigest: digest("2"),
            rendererClosureSHA256: digest("8"),
            rendererExecutableSHA256: try MetalOffscreenRenderer.sha256(fileAt: executable),
            holdoutIndices: [1],
            trainingViewIndices: [0],
            candidateCheckout: CheckoutBinding(path: candidate.root.path, commit: candidate.commit),
            baselineCheckout: CheckoutBinding(path: baseline.root.path, commit: baseline.commit),
            views: [
                RenderViewJob(
                    holdoutIndex: 1,
                    camera: RenderCamera(
                        width: 64,
                        height: 64,
                        projectionMatrixColumnMajor: identity,
                        worldToCameraMatrixColumnMajor: identity
                    ),
                    groundTruth: GroundTruthImage(
                        path: "ground-truth.png",
                        sha256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth)
                    ),
                    sources: sources
                )
            ]
        )
        let driver = BenchmarkRenderDriver { source, _, output in
            try Data("rendered \(source.lastPathComponent)".utf8).write(to: output, options: .atomic)
            return try MetalOffscreenRenderer.sha256(fileAt: output)
        }
        let manifestURL = artifacts.appendingPathComponent("rendering-manifest.json")

        var substitutedJob = job
        substitutedJob.rendererExecutableSHA256 = digest("f")
        XCTAssertThrowsError(
            try driver.execute(
                job: substitutedJob,
                artifactRoot: artifacts,
                manifestURL: manifestURL,
                rendererExecutableURL: executable
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("approved"))
        }

        try driver.execute(
            job: job,
            artifactRoot: artifacts,
            manifestURL: manifestURL,
            rendererExecutableURL: executable
        )

        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(manifest["request_digest"] as? String, job.requestDigest)
        XCTAssertEqual(manifest["renderer_closure_sha256"] as? String,
                       job.rendererClosureSHA256)
        XCTAssertEqual(manifest["renderer_executable_sha256"] as? String,
                       try MetalOffscreenRenderer.sha256(fileAt: executable))
        let operations = try XCTUnwrap(manifest["render_operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, RenderVariant.allCases.count)
        XCTAssertEqual(operations.map { $0["variant"] as? String }, RenderVariant.allCases.map(\.rawValue))
        XCTAssertTrue(operations.allSatisfy { $0["source_executable_sha256"] as? String == digest("6") })
        XCTAssertTrue(operations.allSatisfy { $0["argv"] == nil && $0["exit_code"] == nil })
        XCTAssertEqual(try CheckoutSnapshot.capture(root: candidate.root).commit, candidate.commit)
        XCTAssertEqual(try CheckoutSnapshot.capture(root: baseline.root).commit, baseline.commit)
    }

    func testDriverLoadsEachImmutableSourceOnceAndKeepsCanonicalEvidenceOrder() throws {
        let fixture = try makeDriverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var loads = [String]()
        let driver = BenchmarkRenderDriver(loadScene: { source in
            loads.append(source.lastPathComponent)
            return StubLoadedScene { _, output in
                try Data("rendered \(source.lastPathComponent)".utf8).write(
                    to: output,
                    options: .atomic
                )
                return try MetalOffscreenRenderer.sha256(fileAt: output)
            }
        })
        let manifestURL = fixture.artifacts.appendingPathComponent("rendering-manifest.json")

        try driver.execute(
            job: fixture.job,
            artifactRoot: fixture.artifacts,
            manifestURL: manifestURL,
            rendererExecutableURL: fixture.executable
        )

        XCTAssertEqual(
            loads,
            RenderVariant.allCases.map { "\($0.rawValue).ply" }
        )
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let views = try XCTUnwrap(manifest["views"] as? [[String: Any]])
        XCTAssertEqual(views.compactMap { $0["holdout_index"] as? Int }, fixture.job.holdoutIndices)
        for view in views {
            let renders = try XCTUnwrap(view["renders"] as? [[String: Any]])
            XCTAssertEqual(
                renders.compactMap { $0["variant"] as? String },
                RenderVariant.allCases.map(\.rawValue)
            )
        }
        let operations = try XCTUnwrap(manifest["render_operations"] as? [[String: Any]])
        let expectedOperations = RenderVariant.allCases.flatMap { variant in
            fixture.job.holdoutIndices.map { "render-\(String(format: "%06d", $0))-\(variant.rawValue)" }
        }
        XCTAssertEqual(
            operations.compactMap { $0["operation_id"] as? String },
            expectedOperations
        )
    }

    func testDriverRejectsSnapshotMutationDuringSceneLoad() throws {
        let fixture = try makeDriverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let driver = BenchmarkRenderDriver(loadScene: { source in
            try Data("tampered snapshot".utf8).write(to: source, options: .atomic)
            return StubLoadedScene { _, _ in self.digest("f") }
        })

        XCTAssertThrowsError(
            try driver.execute(
                job: fixture.job,
                artifactRoot: fixture.artifacts,
                manifestURL: fixture.artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: fixture.executable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("snapshot changed"),
                error.localizedDescription
            )
        }
    }

    func testDriverRejectsGroundTruthMutationBeforeCompletion() throws {
        let fixture = try makeDriverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let groundTruth = fixture.artifacts.appendingPathComponent(
            fixture.job.views[0].groundTruth.path
        )
        var mutated = false
        let driver = BenchmarkRenderDriver(loadScene: { source in
            StubLoadedScene { _, output in
                if !mutated {
                    mutated = true
                    try Data("changed ground truth".utf8).write(to: groundTruth, options: .atomic)
                }
                try Data("rendered \(source.lastPathComponent)".utf8).write(
                    to: output,
                    options: .atomic
                )
                return try MetalOffscreenRenderer.sha256(fileAt: output)
            }
        })

        XCTAssertThrowsError(
            try driver.execute(
                job: fixture.job,
                artifactRoot: fixture.artifacts,
                manifestURL: fixture.artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: fixture.executable
            )
        ) { error in
            let description = error.localizedDescription
            XCTAssertTrue(
                description.contains("ground-truth image") && description.contains("changed"),
                description
            )
        }
    }

    func testProductionRendererProducesDeterministicRGBPNG() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ply = root.appendingPathComponent("fixture.ply")
        try minimalSplatPLY.write(to: ply, atomically: true, encoding: .utf8)
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        let camera = RenderCamera(
            width: 64,
            height: 64,
            projectionMatrixColumnMajor: perspectiveProjection,
            worldToCameraMatrixColumnMajor: translatedView
        )
        let renderer = try MetalOffscreenRenderer(device: device)

        let firstSHA = try renderer.render(plyURL: ply, camera: camera, outputURL: first)
        let secondSHA = try renderer.render(plyURL: ply, camera: camera, outputURL: second)

        XCTAssertEqual(firstSHA, secondSHA)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(first as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 64)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertTrue(pixels.contains { $0 != 0 }, "The production raster path must draw the fixture splat.")
    }

    func testJobRequiresSupervisorProvidedRequestAndRendererDigests() throws {
        let job = makeJob()
        var substituted = job
        substituted.requestDigest = "not-a-digest"
        XCTAssertThrowsError(try substituted.validate())

        substituted = job
        substituted.rendererClosureSHA256 = "not-a-digest"
        XCTAssertThrowsError(try substituted.validate())
    }

    func testDriverRejectsSymlinkedInputAncestorsBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try makeCheckout(at: root.appendingPathComponent("candidate"))
        let baseline = try makeCheckout(at: root.appendingPathComponent("baseline"))
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("benchmark-driver")
        try Data("renderer executable".utf8).write(to: executable)
        let outsideGroundTruth = outside.appendingPathComponent("ground-truth.png")
        let outsidePLY = outside.appendingPathComponent("source.ply")
        try Data("ground truth".utf8).write(to: outsideGroundTruth)
        try Data("ply source".utf8).write(to: outsidePLY)
        try FileManager.default.createSymbolicLink(
            at: artifacts.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        var job = makeJob()
        job.candidateCheckout = CheckoutBinding(path: candidate.root.path, commit: candidate.commit)
        job.baselineCheckout = CheckoutBinding(path: baseline.root.path, commit: baseline.commit)
        for viewIndex in job.views.indices {
            for sourceIndex in job.views[viewIndex].sources.indices {
                let variant = job.views[viewIndex].sources[sourceIndex].variant
                job.views[viewIndex].sources[sourceIndex].checkoutCommit =
                    variant == .pairedBaseline ? baseline.commit : candidate.commit
            }
        }
        job.rendererExecutableSHA256 = try MetalOffscreenRenderer.sha256(fileAt: executable)
        job.views[0].groundTruth = GroundTruthImage(
            path: "linked/ground-truth.png",
            sha256: try MetalOffscreenRenderer.sha256(fileAt: outsideGroundTruth)
        )
        var rendered = false
        let driver = BenchmarkRenderDriver { _, _, _ in
            rendered = true
            return self.digest("f")
        }

        XCTAssertThrowsError(
            try driver.execute(
                job: job,
                artifactRoot: artifacts,
                manifestURL: artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: executable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("symbolic link"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(rendered)

        for index in job.holdoutIndices {
            let groundTruth = artifacts.appendingPathComponent(
                "rendering/ground-truth/\(index).png"
            )
            try FileManager.default.createDirectory(
                at: groundTruth.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ground truth \(index)".utf8).write(to: groundTruth)
            let position = try XCTUnwrap(job.views.firstIndex { $0.holdoutIndex == index })
            job.views[position].groundTruth = GroundTruthImage(
                path: "rendering/ground-truth/\(index).png",
                sha256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth)
            )
        }
        for viewIndex in job.views.indices {
            job.views[viewIndex].sources[0].plyPath = "linked/source.ply"
            job.views[viewIndex].sources[0].plySHA256 =
                try MetalOffscreenRenderer.sha256(fileAt: outsidePLY)
        }

        XCTAssertThrowsError(
            try driver.execute(
                job: job,
                artifactRoot: artifacts,
                manifestURL: artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: executable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("symbolic link"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(rendered)
    }

    private func makeJob() -> BenchmarkRenderJob {
        let holdouts = [4, 9]
        let job = BenchmarkRenderJob(
            schemaVersion: 1,
            sceneID: "orbit-01",
            scale: 12,
            requestDigest: digest("0"),
            inputDigest: digest("2"),
            rendererClosureSHA256: digest("8"),
            rendererExecutableSHA256: digest("7"),
            holdoutIndices: holdouts,
            trainingViewIndices: (0..<12).filter { !holdouts.contains($0) },
            candidateCheckout: CheckoutBinding(path: "/tmp/candidate", commit: String(repeating: "a", count: 40)),
            baselineCheckout: CheckoutBinding(path: "/tmp/baseline", commit: String(repeating: "b", count: 40)),
            views: holdouts.map { index in
                RenderViewJob(
                    holdoutIndex: index,
                    camera: RenderCamera(
                        width: 64,
                        height: 64,
                        projectionMatrixColumnMajor: identity,
                        worldToCameraMatrixColumnMajor: identity
                    ),
                    groundTruth: GroundTruthImage(
                        path: "rendering/ground-truth/\(index).png",
                        sha256: digest("3")
                    ),
                    sources: RenderVariant.allCases.map { variant in
                        RenderSource(
                            variant: variant,
                            runID: "\(variant.rawValue)-run",
                            checkoutCommit: variant == .pairedBaseline
                                ? String(repeating: "b", count: 40)
                                : String(repeating: "a", count: 40),
                            toolchainIdentity: digest("4"),
                            sourceExecutableSHA256: digest("6"),
                            plyPath: "sources/\(variant.rawValue).ply",
                            plySHA256: digest("5"),
                            outputPath: "rendering/\(variant.rawValue)/\(index).png"
                        )
                    }
                )
            }
        )
        return job
    }

    private func makeDriverFixture() throws -> DriverFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = try makeCheckout(at: root.appendingPathComponent("candidate"))
        let baseline = try makeCheckout(at: root.appendingPathComponent("baseline"))
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("benchmark-driver")
        try Data("renderer executable".utf8).write(to: executable)
        var job = makeJob()
        job.candidateCheckout = CheckoutBinding(path: candidate.root.path, commit: candidate.commit)
        job.baselineCheckout = CheckoutBinding(path: baseline.root.path, commit: baseline.commit)
        job.rendererExecutableSHA256 = try MetalOffscreenRenderer.sha256(fileAt: executable)
        for variant in RenderVariant.allCases {
            let source = artifacts.appendingPathComponent("sources/\(variant.rawValue).ply")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ply \(variant.rawValue)".utf8).write(to: source)
        }
        for viewIndex in job.views.indices {
            let holdout = job.views[viewIndex].holdoutIndex
            let groundTruth = artifacts.appendingPathComponent(
                "rendering/ground-truth/\(holdout).png"
            )
            try FileManager.default.createDirectory(
                at: groundTruth.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ground truth \(holdout)".utf8).write(to: groundTruth)
            job.views[viewIndex].groundTruth = GroundTruthImage(
                path: "rendering/ground-truth/\(holdout).png",
                sha256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth)
            )
            for sourceIndex in job.views[viewIndex].sources.indices {
                let variant = job.views[viewIndex].sources[sourceIndex].variant
                let sourcePath = "sources/\(variant.rawValue).ply"
                let source = artifacts.appendingPathComponent(sourcePath)
                job.views[viewIndex].sources[sourceIndex].runID = "\(variant.rawValue)-run"
                job.views[viewIndex].sources[sourceIndex].checkoutCommit =
                    variant == .pairedBaseline ? baseline.commit : candidate.commit
                job.views[viewIndex].sources[sourceIndex].plyPath = sourcePath
                job.views[viewIndex].sources[sourceIndex].plySHA256 =
                    try MetalOffscreenRenderer.sha256(fileAt: source)
                job.views[viewIndex].sources[sourceIndex].outputPath =
                    "rendering/\(variant.rawValue)/\(holdout).png"
            }
        }
        return DriverFixture(
            root: root,
            artifacts: artifacts,
            executable: executable,
            job: job
        )
    }

    private var identity: [Float] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
    }

    private var perspectiveProjection: [Float] {
        [
            1.732_050_8, 0, 0, 0,
            0, 1.732_050_8, 0, 0,
            0, 0, -1.002_002, -1,
            0, 0, -0.200_200_2, 0,
        ]
    }

    private var translatedView: [Float] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, -3, 1,
        ]
    }

    private var minimalSplatPLY: String {
        """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 1 0 0 -2 -2 -2 3 1 0 0 0
        """
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeCheckout(at root: URL) throws -> CheckoutSnapshot {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], at: root)
        try "fixture\n".write(
            to: root.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "fixture.txt"], at: root)
        try runGit(
            [
                "-c", "user.name=EasySplat Tests",
                "-c", "user.email=tests@easysplat.invalid",
                "commit", "--quiet", "-m", "fixture",
            ],
            at: root
        )
        return try CheckoutSnapshot.capture(root: root)
    }
}

private struct DriverFixture {
    let root: URL
    let artifacts: URL
    let executable: URL
    let job: BenchmarkRenderJob
}

private final class StubLoadedScene: LoadedSceneRendering {
    private let body: (RenderCamera, URL) throws -> String

    init(body: @escaping (RenderCamera, URL) throws -> String) {
        self.body = body
    }

    func render(camera: RenderCamera, outputURL: URL) throws -> String {
        try body(camera, outputURL)
    }
}
