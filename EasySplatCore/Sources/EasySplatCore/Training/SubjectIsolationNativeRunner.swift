import Foundation

struct SubjectIsolationNativeDigests: Sendable, Equatable {
    let sourcePly: String
    let input: String
    let geometry: String
    let selectedFrames: String
    let trainingManifest: String
}

struct SubjectIsolationNativeRunRequest: Sendable, Equatable {
    let executableURL: URL
    let metallibURL: URL
    let datasetURL: URL
    let sourcePlyURL: URL
    let maskManifestURL: URL
    let analysisCacheURL: URL
    let outputURL: URL
    let digests: SubjectIsolationNativeDigests
    let memoryBudgetBytes: Int64
    let anchor: SubjectAnchor?
}

struct SubjectIsolationNativeKeyframeContribution: Sendable, Equatable {
    let imageIdentity: String
    let instanceLabel: UInt8
    let weight: Double
    let fraction: Double
}

struct SubjectIsolationNativeComponent: Sendable, Equatable {
    let identity: String
    let score: Double
    let keyframes: [SubjectIsolationNativeKeyframeContribution]
}

struct SubjectIsolationNativeCompletion: Sendable, Equatable {
    let outputSHA256: String
    let outputByteCount: UInt64
    let gaussianCount: Int
    let sceneBounds: SplatSceneBounds
    let retainedGaussianFraction: Double
    let heldOutMeanIoU: Double
    let heldOutMedianIoU: Double
    let heldOutFirstQuartileIoU: Double
    let selectedViewIdentities: [String]
    let heldOutViewIdentities: [String]
    let selectedComponent: SubjectIsolationNativeComponent
}

enum SubjectIsolationNativeRunResult: Sendable, Equatable {
    case completed(SubjectIsolationNativeCompletion)
    case ambiguity([SubjectIsolationNativeComponent])
    case noSubject([SubjectIsolationNativeComponent])
    case heldOutRejected
}

public enum SubjectIsolationNativeRunnerError: Error, LocalizedError, Sendable, Equatable {
    case memoryRefused(requiredBytes: Int64?, budgetBytes: Int64)
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case .memoryRefused:
            "Subject isolation needs more unified memory than this run allowed."
        case .protocolFailure(let message):
            "Native subject-isolation protocol error: \(message)"
        }
    }
}

struct SubjectIsolationNativeRunner: Sendable {
    private let runner: SubprocessRunning

    init(runner: SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    func run(
        _ request: SubjectIsolationNativeRunRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        guard request.memoryBudgetBytes > 0 else {
            throw SubjectIsolationNativeRunnerError.protocolFailure(
                "memory budget must be positive"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw SubprocessFailure(
                tool: "msplat",
                command: "isolate",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "easysplat-train is not executable: \(request.executableURL.path)"
            )
        }
        let allDigests = [
            request.digests.sourcePly,
            request.digests.input,
            request.digests.geometry,
            request.digests.selectedFrames,
            request.digests.trainingManifest,
        ]
        guard allDigests.allSatisfy(isSHA256) else {
            throw SubjectIsolationNativeRunnerError.protocolFailure(
                "authenticated digests must be lowercase SHA-256 values"
            )
        }

        var arguments = [
            "--isolate",
            "--dataset", request.datasetURL.path,
            "--source-ply", request.sourcePlyURL.path,
            "--mask-manifest", request.maskManifestURL.path,
            "--analysis-cache", request.analysisCacheURL.path,
            "--output", request.outputURL.path,
            "--expected-source-ply-digest", request.digests.sourcePly,
            "--expected-input-digest", request.digests.input,
            "--expected-geometry-digest", request.digests.geometry,
            "--expected-selected-frames-digest", request.digests.selectedFrames,
            "--expected-training-manifest-digest", request.digests.trainingManifest,
            "--memory-budget-bytes", String(request.memoryBudgetBytes),
            "--events-fd", "1",
            "--metallib", request.metallibURL.path,
        ]
        if let anchor = request.anchor {
            arguments.append(contentsOf: [
                "--anchor-image", anchor.imageIdentity,
                "--anchor-instance", String(anchor.instanceLabel),
            ])
        }

        let events = SubjectIsolationNativeEventStream(
            expectedSourceSHA256: request.digests.sourcePly,
            expectedMemoryBudgetBytes: request.memoryBudgetBytes,
            onProgress: onProgress
        )
        let process: SubprocessResult
        do {
            process = try await runner.runAsync(
                request.executableURL.path,
                arguments,
                currentDirectory: request.datasetURL.deletingLastPathComponent(),
                environment: [:],
                onStdout: {
                    events.consume($0)
                    onLog($0, false)
                },
                onStderr: { onLog($0, true) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubprocessFailure(
                tool: "msplat",
                command: "isolate",
                exitCode: -1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "Failed to launch easysplat-train: \(error)"
            )
        }
        if events.consumedLineCount == 0 {
            for line in process.stdout.split(whereSeparator: \.isNewline) {
                events.consume(String(line))
            }
        }

        let terminal = try events.finish()
        switch terminal {
        case .cancelled:
            guard process.exitCode == 130, process.terminationReason == .exit else {
                throw SubjectIsolationNativeRunnerError.protocolFailure(
                    "cancellation must terminate with status 130"
                )
            }
            throw CancellationError()
        case .memoryRefused(let requiredBytes, let budgetBytes):
            guard process.exitCode == 75, process.terminationReason == .exit else {
                throw SubjectIsolationNativeRunnerError.protocolFailure(
                    "memory refusal must terminate with status 75"
                )
            }
            throw SubjectIsolationNativeRunnerError.memoryRefused(
                requiredBytes: requiredBytes,
                budgetBytes: budgetBytes
            )
        case .failed(let message):
            guard process.exitCode == 1, process.terminationReason == .exit else {
                throw SubjectIsolationNativeRunnerError.protocolFailure(
                    "native failure must terminate with status 1"
                )
            }
            throw SubjectIsolationNativeRunnerError.protocolFailure(
                "native isolation failed: \(message)"
            )
        case .completed(let completion):
            try requireSuccessfulProcess(process)
            let evidence: ValidatedPlyArtifactEvidence
            do {
                evidence = try ProjectArtifactValidator.validatedPlyEvidence(
                    at: request.outputURL
                )
            } catch {
                throw SubjectIsolationNativeRunnerError.protocolFailure(
                    "completed output is not a valid plain PLY file"
                )
            }
            guard evidence.sha256 == completion.outputSHA256,
                  evidence.byteCount == completion.outputByteCount,
                  evidence.vertexCount == completion.gaussianCount,
                  SplatSceneBoundsCalculator.matches(
                    evidence.sceneBounds,
                    completion.sceneBounds
                  ) else {
                throw SubjectIsolationNativeRunnerError.protocolFailure(
                    "completed output identity does not match the staged PLY"
                )
            }
            return .completed(completion)
        case .ambiguity(let components):
            try requireSuccessfulProcess(process)
            return .ambiguity(components)
        case .noSubject(let components):
            try requireSuccessfulProcess(process)
            return .noSubject(components)
        case .heldOutRejected:
            try requireSuccessfulProcess(process)
            return .heldOutRejected
        }
    }

    private func requireSuccessfulProcess(_ process: SubprocessResult) throws {
        guard process.exitCode == 0, process.terminationReason == .exit else {
            throw SubjectIsolationNativeRunnerError.protocolFailure(
                "terminal event does not match process exit status \(process.exitCode)"
            )
        }
    }
}

private final class SubjectIsolationNativeEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSourceSHA256: String
    private let expectedMemoryBudgetBytes: Int64
    private let onProgress: @Sendable (SubjectIsolationProgress) -> Void
    private var lineCount = 0
    private var lastSequence: UInt64 = 0
    private var terminal: Terminal?
    private var failure: SubjectIsolationNativeRunnerError?

    init(
        expectedSourceSHA256: String,
        expectedMemoryBudgetBytes: Int64,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void
    ) {
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.expectedMemoryBudgetBytes = expectedMemoryBudgetBytes
        self.onProgress = onProgress
    }

    var consumedLineCount: Int {
        lock.withLock { lineCount }
    }

    func consume(_ line: String) {
        var acceptedProgress: SubjectIsolationProgress?
        lock.lock()
        defer {
            lock.unlock()
            if let acceptedProgress { onProgress(acceptedProgress) }
        }
        lineCount += 1
        guard failure == nil else { return }
        do {
            let event = try JSONDecoder().decode(
                SubjectIsolationNativeEvent.self,
                from: Data(line.utf8)
            )
            guard event.schemaVersion == 2,
                  event.sequence > lastSequence else {
                throw protocolError("event schema or sequence is invalid")
            }
            lastSequence = event.sequence
            if let parsed = try parseTerminal(event) {
                guard terminal == nil else {
                    throw protocolError("event stream contains conflicting terminal events")
                }
                terminal = parsed
                return
            }
            guard terminal == nil else {
                throw protocolError("event follows the terminal event")
            }
            switch event.event {
            case "isolation_started":
                guard event.status == "running",
                      event.memoryBudgetBytes == expectedMemoryBudgetBytes else {
                    throw protocolError("isolation_started record is invalid")
                }
            case "isolation_progress":
                guard event.status == "running",
                      let phaseName = event.phase,
                      let phase = SubjectIsolationPhase(rawValue: phaseName),
                      let completed = event.completedUnitCount,
                      let total = event.totalUnitCount,
                      completed >= 0,
                      total > 0,
                      completed <= total else {
                    throw protocolError("isolation_progress record is invalid")
                }
                acceptedProgress = SubjectIsolationProgress(
                    phase: phase,
                    completedUnitCount: completed,
                    totalUnitCount: total
                )
            default:
                throw protocolError("unsupported event type \(event.event)")
            }
        } catch let error as SubjectIsolationNativeRunnerError {
            failure = error
        } catch {
            failure = protocolError("event JSON is invalid")
        }
    }

    func finish() throws -> Terminal {
        try lock.withLock {
            if let failure { throw failure }
            guard let terminal else {
                throw protocolError("event stream has no terminal event")
            }
            return terminal
        }
    }

    private func parseTerminal(
        _ event: SubjectIsolationNativeEvent
    ) throws -> Terminal? {
        switch event.event {
        case "isolation_cancelled":
            guard event.status == "cancelled" else {
                throw protocolError("cancellation record is invalid")
            }
            return .cancelled
        case "isolation_memory_refused":
            guard event.status == "refused",
                  let budget = event.budgetBytes,
                  budget == expectedMemoryBudgetBytes,
                  event.requiredBytes.map({ $0 > 0 }) ?? true else {
                throw protocolError("memory refusal record is invalid")
            }
            return .memoryRefused(event.requiredBytes, budget)
        case "isolation_failed":
            guard event.status == "failed",
                  let message = event.message,
                  !message.isEmpty else {
                throw protocolError("failure record is invalid")
            }
            return .failed(message)
        case "isolation_no_subject":
            guard event.status == "no_subject" else {
                throw protocolError("no-subject record is invalid")
            }
            return .noSubject(try components(from: event.components ?? []))
        case "isolation_ambiguity":
            guard event.status == "ambiguity",
                  event.anchorAllowed == true else {
                throw protocolError("ambiguity record is invalid")
            }
            return .ambiguity(try components(from: event.components ?? []))
        case "isolation_held_out_rejected":
            guard event.status == "rejected",
                  validUnit(event.heldOutMeanIoU),
                  validUnit(event.heldOutMedianIoU),
                  validUnit(event.heldOutFirstQuartileIoU) else {
                throw protocolError("held-out rejection record is invalid")
            }
            return .heldOutRejected
        case "isolation_completed":
            guard event.status == "completed",
                  event.sourcePlySHA256 == expectedSourceSHA256,
                  let outputSHA256 = event.outputSHA256,
                  isSHA256(outputSHA256),
                  let outputBytes = event.outputBytes,
                  outputBytes > 0,
                  let gaussianCount = event.gaussianCount,
                  gaussianCount > 0,
                  let sceneCenter = finiteTriplet(event.sceneCenter),
                  let sceneRadius = event.sceneRadius,
                  sceneRadius.isFinite,
                  sceneRadius > 0,
                  let minimum = finiteTriplet(event.boundsMinimum),
                  let maximum = finiteTriplet(event.boundsMaximum),
                  zip(minimum, maximum).allSatisfy({ $0 <= $1 }),
                  let retained = event.retainedGaussianFraction,
                  validUnit(retained),
                  let heldOutMean = event.heldOutMeanIoU,
                  validUnit(heldOutMean),
                  let heldOutMedian = event.heldOutMedianIoU,
                  validUnit(heldOutMedian),
                  let heldOutQ1 = event.heldOutFirstQuartileIoU,
                  validUnit(heldOutQ1),
                  let selectedViews = event.selectedViewIdentities,
                  !selectedViews.isEmpty,
                  Set(selectedViews).count == selectedViews.count,
                  let heldOutViews = event.heldOutViewIdentities,
                  !heldOutViews.isEmpty,
                  Set(heldOutViews).count == heldOutViews.count,
                  Set(selectedViews).isDisjoint(with: Set(heldOutViews)),
                  let component = event.selectedComponent else {
                throw protocolError("completion record is invalid")
            }
            return .completed(SubjectIsolationNativeCompletion(
                outputSHA256: outputSHA256,
                outputByteCount: outputBytes,
                gaussianCount: gaussianCount,
                sceneBounds: SplatSceneBounds(
                    center: ScenePoint3D(
                        x: sceneCenter[0],
                        y: sceneCenter[1],
                        z: sceneCenter[2]
                    ),
                    radius: sceneRadius
                ),
                retainedGaussianFraction: retained,
                heldOutMeanIoU: heldOutMean,
                heldOutMedianIoU: heldOutMedian,
                heldOutFirstQuartileIoU: heldOutQ1,
                selectedViewIdentities: selectedViews,
                heldOutViewIdentities: heldOutViews,
                selectedComponent: try componentValue(from: component)
            ))
        default:
            return nil
        }
    }

    private func components(
        from records: [SubjectIsolationNativeEvent.Component]
    ) throws -> [SubjectIsolationNativeComponent] {
        try records.map(componentValue)
    }

    private func componentValue(
        from record: SubjectIsolationNativeEvent.Component
    ) throws -> SubjectIsolationNativeComponent {
        guard !record.componentIdentity.isEmpty,
              record.score.isFinite,
              record.score >= 0 else {
            throw protocolError("component evidence is invalid")
        }
        return SubjectIsolationNativeComponent(
            identity: record.componentIdentity,
            score: record.score,
            keyframes: try record.keyframeContributions.map { keyframe in
                guard !keyframe.imageIdentity.isEmpty,
                      let label = UInt8(exactly: keyframe.instance),
                      label > 0,
                      keyframe.weight.isFinite,
                      keyframe.weight >= 0,
                      validUnit(keyframe.fraction) else {
                    throw protocolError("component keyframe evidence is invalid")
                }
                return SubjectIsolationNativeKeyframeContribution(
                    imageIdentity: keyframe.imageIdentity,
                    instanceLabel: label,
                    weight: keyframe.weight,
                    fraction: keyframe.fraction
                )
            }
        )
    }

    private func validUnit(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...1).contains($0) } == true
    }

    private func finiteTriplet(_ values: [Double]?) -> [Double]? {
        guard let values, values.count == 3, values.allSatisfy(\.isFinite) else {
            return nil
        }
        return values
    }

    private func protocolError(_ message: String) -> SubjectIsolationNativeRunnerError {
        .protocolFailure(message)
    }

    enum Terminal {
        case completed(SubjectIsolationNativeCompletion)
        case ambiguity([SubjectIsolationNativeComponent])
        case noSubject([SubjectIsolationNativeComponent])
        case heldOutRejected
        case cancelled
        case memoryRefused(Int64?, Int64)
        case failed(String)
    }
}

private struct SubjectIsolationNativeEvent: Decodable {
    let event: String
    let schemaVersion: Int
    let sequence: UInt64
    let status: String?
    let phase: String?
    let completedUnitCount: Int?
    let totalUnitCount: Int?
    let memoryBudgetBytes: Int64?
    let budgetBytes: Int64?
    let requiredBytes: Int64?
    let message: String?
    let sourcePlySHA256: String?
    let outputSHA256: String?
    let outputBytes: UInt64?
    let gaussianCount: Int?
    let sceneCenter: [Double]?
    let sceneRadius: Double?
    let boundsMinimum: [Double]?
    let boundsMaximum: [Double]?
    let retainedGaussianFraction: Double?
    let heldOutMeanIoU: Double?
    let heldOutMedianIoU: Double?
    let heldOutFirstQuartileIoU: Double?
    let selectedViewIdentities: [String]?
    let heldOutViewIdentities: [String]?
    let anchorAllowed: Bool?
    let components: [Component]?
    let selectedComponent: Component?

    struct Component: Decodable {
        let componentIdentity: String
        let score: Double
        let keyframeContributions: [Keyframe]

        enum CodingKeys: String, CodingKey {
            case componentIdentity = "component_identity"
            case score
            case keyframeContributions = "keyframe_contributions"
        }
    }

    struct Keyframe: Decodable {
        let imageIdentity: String
        let instance: Int
        let weight: Double
        let fraction: Double

        enum CodingKeys: String, CodingKey {
            case imageIdentity = "image_identity"
            case instance
            case weight
            case fraction
        }
    }

    enum CodingKeys: String, CodingKey {
        case event
        case schemaVersion = "schema_version"
        case sequence
        case status
        case phase
        case completedUnitCount = "completed_unit_count"
        case totalUnitCount = "total_unit_count"
        case memoryBudgetBytes = "memory_budget_bytes"
        case budgetBytes = "budget_bytes"
        case requiredBytes = "required_bytes"
        case message
        case sourcePlySHA256 = "source_ply_sha256"
        case outputSHA256 = "output_sha256"
        case outputBytes = "output_bytes"
        case gaussianCount = "gaussian_count"
        case sceneCenter = "scene_center"
        case sceneRadius = "scene_radius"
        case boundsMinimum = "bounds_minimum"
        case boundsMaximum = "bounds_maximum"
        case retainedGaussianFraction = "retained_gaussian_fraction"
        case heldOutMeanIoU = "held_out_mean_soft_iou"
        case heldOutMedianIoU = "held_out_median_soft_iou"
        case heldOutFirstQuartileIoU = "held_out_q1_soft_iou"
        case selectedViewIdentities = "selected_view_identities"
        case heldOutViewIdentities = "held_out_view_identities"
        case anchorAllowed = "anchor_allowed"
        case components
        case selectedComponent = "selected_component"
    }
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}
