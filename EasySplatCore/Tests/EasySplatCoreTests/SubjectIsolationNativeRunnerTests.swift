import XCTest
@testable import EasySplatCore

final class SubjectIsolationNativeRunnerTests: XCTestCase {
    func testRunPassesAuthenticatedIsolationArgumentsAndOptionalAnchor() async throws {
        let fixture = try NativeIsolationRunnerFixture()
        defer { fixture.cleanup() }
        let anchor = SubjectAnchor(
            imageIdentity: "frame-1.png",
            instanceLabel: 7,
            normalizedX: 0.25,
            normalizedY: 0.75
        )
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["--isolate"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLinesProvider: { arguments in
                    fixture.writeOutputAndCompletion(arguments: arguments)
                }
            ),
        ])

        let result = try await SubjectIsolationNativeRunner(runner: mock).run(
            fixture.request(anchor: anchor),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed(let completion) = result else {
            return XCTFail("Expected completion.")
        }
        XCTAssertEqual(completion.gaussianCount, 1)
        let arguments = try XCTUnwrap(mock.calls.first?.1)
        XCTAssertEqual(argument("--dataset", in: arguments), fixture.dataset.path)
        XCTAssertEqual(argument("--source-ply", in: arguments), fixture.source.path)
        XCTAssertEqual(argument("--mask-manifest", in: arguments), fixture.manifest.path)
        XCTAssertEqual(argument("--analysis-cache", in: arguments), fixture.cache.path)
        XCTAssertEqual(argument("--output", in: arguments), fixture.output.path)
        XCTAssertEqual(argument("--expected-source-ply-digest", in: arguments), fixture.digests.sourcePly)
        XCTAssertEqual(argument("--expected-input-digest", in: arguments), fixture.digests.input)
        XCTAssertEqual(argument("--expected-geometry-digest", in: arguments), fixture.digests.geometry)
        XCTAssertEqual(argument("--expected-selected-frames-digest", in: arguments), fixture.digests.selectedFrames)
        XCTAssertEqual(argument("--expected-training-manifest-digest", in: arguments), fixture.digests.trainingManifest)
        XCTAssertEqual(argument("--memory-budget-bytes", in: arguments), "1073741824")
        XCTAssertEqual(argument("--events-fd", in: arguments), "1")
        XCTAssertEqual(argument("--anchor-image", in: arguments), anchor.imageIdentity)
        XCTAssertEqual(argument("--anchor-instance", in: arguments), String(anchor.instanceLabel))
    }

    func testRunParsesProgressAndRequiresOneCoherentTerminal() async throws {
        let fixture = try NativeIsolationRunnerFixture()
        defer { fixture.cleanup() }
        let progress = NativeIsolationRecorder<SubjectIsolationProgress>()
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["--isolate"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLinesProvider: { arguments in
                    [
                        #"{"event":"isolation_started","schema_version":2,"sequence":1,"status":"running","cached_work_view_count":0,"held_out_view_count":1,"memory_budget_bytes":1073741824,"source_gaussian_count":1,"work_view_count":1}"#,
                        #"{"event":"isolation_progress","schema_version":2,"sequence":2,"status":"running","cache_reused":false,"completed_unit_count":1,"total_unit_count":2,"image_identity":"frame-0.png","phase":"filtering"}"#,
                    ] + fixture.writeOutputAndCompletion(arguments: arguments, firstSequence: 3)
                }
            ),
        ])

        _ = try await SubjectIsolationNativeRunner(runner: mock).run(
            fixture.request(),
            onProgress: { progress.append($0) },
            onLog: { _, _ in }
        )
        XCTAssertEqual(
            progress.values,
            [
                SubjectIsolationProgress(
                    phase: .filtering,
                    completedUnitCount: 1,
                    totalUnitCount: 2
                ),
            ]
        )

        for lines in [
            [#"{"event":"isolation_started","schema_version":2,"sequence":1,"status":"running","cached_work_view_count":0,"held_out_view_count":1,"memory_budget_bytes":1073741824,"source_gaussian_count":1,"work_view_count":1}"#],
            [
                #"{"event":"isolation_no_subject","schema_version":2,"sequence":1,"status":"no_subject","source_gaussian_count":1,"components":[]}"#,
                #"{"event":"isolation_ambiguity","schema_version":2,"sequence":2,"status":"ambiguity","source_gaussian_count":1,"anchor_allowed":true,"components":[]}"#,
            ],
        ] {
            let invalid = MockSubprocessRunner(scripts: [
                .init(
                    path: fixture.executable.path,
                    argsPrefix: ["--isolate"],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    stdoutLines: lines
                ),
            ])
            do {
                _ = try await SubjectIsolationNativeRunner(runner: invalid).run(
                    fixture.request(output: fixture.root.appendingPathComponent(UUID().uuidString + ".ply")),
                    onProgress: { _ in },
                    onLog: { _, _ in }
                )
                XCTFail("Expected protocol failure.")
            } catch let error as SubjectIsolationNativeRunnerError {
                guard case .protocolFailure = error else {
                    return XCTFail("Expected protocol failure, got \(error).")
                }
            }
        }
    }

    func testRunRejectsCompletionWhoseFileIdentityDoesNotMatchEvent() async throws {
        let fixture = try NativeIsolationRunnerFixture()
        defer { fixture.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.executable.path,
                argsPrefix: ["--isolate"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLinesProvider: { arguments in
                    fixture.writeOutputAndCompletion(
                        arguments: arguments,
                        outputSHA256: String(repeating: "f", count: 64)
                    )
                }
            ),
        ])

        do {
            _ = try await SubjectIsolationNativeRunner(runner: mock).run(
                fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected output validation failure.")
        } catch let error as SubjectIsolationNativeRunnerError {
            guard case .protocolFailure(let message) = error else {
                return XCTFail("Expected protocol failure.")
            }
            XCTAssertTrue(message.contains("output"))
        }
    }

    func testRunSurfacesCancellationAndMemoryRefusalWithRequiredExitStatuses() async throws {
        let fixture = try NativeIsolationRunnerFixture()
        defer { fixture.cleanup() }
        let scripts: [(Int32, String)] = [
            (130, #"{"event":"isolation_cancelled","schema_version":2,"sequence":1,"signal":15,"status":"cancelled"}"#),
            (75, #"{"event":"isolation_memory_refused","schema_version":2,"sequence":1,"budget_bytes":1073741824,"required_bytes":2147483648,"reason":"working_set","status":"refused"}"#),
        ]
        for (exitCode, line) in scripts {
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: fixture.executable.path,
                    argsPrefix: ["--isolate"],
                    result: .init(exitCode: exitCode, terminationReason: .exit, stdout: "", stderr: ""),
                    stdoutLines: [line]
                ),
            ])
            do {
                _ = try await SubjectIsolationNativeRunner(runner: mock).run(
                    fixture.request(output: fixture.root.appendingPathComponent(UUID().uuidString + ".ply")),
                    onProgress: { _ in },
                    onLog: { _, _ in }
                )
                XCTFail("Expected terminal error.")
            } catch is CancellationError {
                XCTAssertEqual(exitCode, 130)
            } catch let error as SubjectIsolationNativeRunnerError {
                guard case .memoryRefused(let required, let budget) = error else {
                    return XCTFail("Expected memory refusal.")
                }
                XCTAssertEqual(exitCode, 75)
                XCTAssertEqual(required, 2_147_483_648)
                XCTAssertEqual(budget, 1_073_741_824)
            }
        }
    }
}

private struct NativeIsolationRunnerFixture {
    let root: URL
    let executable: URL
    let dataset: URL
    let source: URL
    let manifest: URL
    let cache: URL
    let output: URL
    let digests: SubjectIsolationNativeDigests

    init() throws {
        root = try TestFileBuilder.makeTempDir()
        executable = root.appendingPathComponent("easysplat-train")
        dataset = root.appendingPathComponent("dataset", isDirectory: true)
        source = root.appendingPathComponent("source.ply")
        manifest = root.appendingPathComponent("mask-manifest.json")
        cache = root.appendingPathComponent("analysis.cache")
        output = root.appendingPathComponent("isolated.ply")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: source)
        try Data("manifest".utf8).write(to: manifest)
        digests = SubjectIsolationNativeDigests(
            sourcePly: try GeometryArtifactStore.sha256(of: source),
            input: String(repeating: "1", count: 64),
            geometry: String(repeating: "2", count: 64),
            selectedFrames: String(repeating: "3", count: 64),
            trainingManifest: String(repeating: "4", count: 64)
        )
    }

    var metallib: URL {
        executable.deletingLastPathComponent().appendingPathComponent("default.metallib")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func request(
        anchor: SubjectAnchor? = nil,
        output requestedOutput: URL? = nil
    ) -> SubjectIsolationNativeRunRequest {
        SubjectIsolationNativeRunRequest(
            executableURL: executable,
            metallibURL: metallib,
            datasetURL: dataset,
            sourcePlyURL: source,
            maskManifestURL: manifest,
            analysisCacheURL: cache,
            outputURL: requestedOutput ?? output,
            digests: digests,
            memoryBudgetBytes: 1_073_741_824,
            anchor: anchor
        )
    }

    func writeOutputAndCompletion(
        arguments: [String],
        firstSequence: Int = 1,
        outputSHA256: String? = nil
    ) -> [String] {
        do {
            let output = URL(fileURLWithPath: try XCTUnwrap(argument("--output", in: arguments)))
            try TestFileBuilder.writeMinimalPly(at: output)
            let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: output)
            let event: [String: Any] = [
                "event": "isolation_completed",
                "schema_version": 2,
                "sequence": firstSequence,
                "status": "completed",
                "bounds_minimum": [-1.0, -1.0, -1.0],
                "bounds_maximum": [1.0, 1.0, 1.0],
                "gaussian_count": evidence.vertexCount,
                "held_out_evidence": [
                    ["best_instance": 1, "image_identity": "frame-1.png", "soft_iou": 0.8],
                ],
                "held_out_mean_soft_iou": 0.8,
                "held_out_median_soft_iou": 0.8,
                "held_out_q1_soft_iou": 0.8,
                "held_out_view_identities": ["frame-1.png"],
                "output_bytes": evidence.byteCount,
                "output_sha256": outputSHA256 ?? evidence.sha256,
                "retained_gaussian_fraction": 0.5,
                "scene_center": [
                    evidence.sceneBounds.center.x,
                    evidence.sceneBounds.center.y,
                    evidence.sceneBounds.center.z,
                ],
                "scene_radius": evidence.sceneBounds.radius,
                "selected_component": [
                    "component_identity": "component-1",
                    "gaussian_count": evidence.vertexCount,
                    "keyframe_contributions": [
                        [
                            "fraction": 0.9,
                            "image_identity": "frame-0.png",
                            "instance": 1,
                            "weight": 10.0,
                        ],
                    ],
                    "projection_centrality": 0.9,
                    "score": 0.9,
                    "view_coverage": 0.9,
                    "visible_support": 10.0,
                ],
                "selected_view_identities": ["frame-0.png"],
                "source_gaussian_count": evidence.vertexCount,
                "source_ply_sha256": digests.sourcePly,
            ]
            return [String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!]
        } catch {
            XCTFail("Could not build native completion fixture: \(error)")
            return []
        }
    }
}

private final class NativeIsolationRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private func argument(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}
