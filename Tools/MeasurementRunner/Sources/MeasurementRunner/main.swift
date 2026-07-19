import EasySplatCore
import EasySplatMeasurementRunnerCore
import Foundation

private func mapping(_ value: Any?, _ label: String) throws -> [String: Any] {
  guard let result = value as? [String: Any] else {
    throw MeasurementRunnerError.invalidRequest("\(label) must be an object")
  }
  return result
}

private func number(_ value: Any?, _ label: String) throws -> Double {
  guard let result = value as? NSNumber, result.doubleValue.isFinite,
    result.doubleValue >= 0
  else {
    throw MeasurementRunnerError.subprocessFailed("\(label) is invalid")
  }
  return result.doubleValue
}

private func canonicalDigest(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(
    withJSONObject: value,
    options: [.sortedKeys, .withoutEscapingSlashes]
  )
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "measurement-digest-\(UUID().uuidString)"
  )
  defer { try? FileManager.default.removeItem(at: temporary) }
  try data.write(to: temporary, options: .withoutOverwriting)
  return "sha256:" + (try MeasurementWorkerExecutor.sha256(temporary))
}

private func copyExclusive(_ source: URL, to destination: URL) throws {
  guard !FileManager.default.fileExists(atPath: destination.path) else {
    throw MeasurementRunnerError.unsafePath("artifact destination already exists")
  }
  try FileManager.default.copyItem(at: source, to: destination)
  guard try MeasurementWorkerExecutor.sha256(source)
    == MeasurementWorkerExecutor.sha256(destination)
  else {
    throw MeasurementRunnerError.identityMismatch("copied artifact digest changed")
  }
}

private func readObject(_ url: URL, maximumBytes: Int = 16 * 1_024 * 1_024) throws
  -> [String: Any]
{
  let values = try url.resourceValues(forKeys: [
    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
  ])
  guard values.isRegularFile == true, values.isSymbolicLink != true,
    let size = values.fileSize, (1...maximumBytes).contains(size),
    let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  else {
    throw MeasurementRunnerError.subprocessFailed("bounded JSON artifact is invalid")
  }
  return result
}

private func writeJSON(_ value: [String: Any], to destination: URL) throws {
  var data = try JSONSerialization.data(
    withJSONObject: value,
    options: [.sortedKeys, .withoutEscapingSlashes]
  )
  data.append(0x0A)
  try data.write(to: destination, options: .withoutOverwriting)
}

private func executable(for variant: MeasurementVariant, workers: MeasurementWorkerSet) -> URL {
  switch variant {
  case .baseline: workers.baseline
  case .candidate, .fastCandidate: workers.candidate
  case .accurateReference: workers.accurateReference
  }
}

private func toolchainRoot(
  for variant: MeasurementVariant,
  arguments: MeasurementRunnerArguments
) -> URL {
  variant == .baseline ? arguments.baselineToolchainRoot : arguments.toolchainRoot
}

private func configuration(
  for variant: MeasurementVariant,
  request: [String: Any]
) throws -> [String: Any] {
  switch variant {
  case .baseline:
    return try mapping(request["baseline_run_configuration"], "baseline_run_configuration")
  case .candidate:
    return try mapping(request["candidate_run_configuration"], "candidate_run_configuration")
  case .fastCandidate:
    var value = try mapping(
      request["candidate_run_configuration"],
      "candidate_run_configuration"
    )
    value["detail_profile"] = "fast"
    value["trainer_iterations"] = 3_000
    value["trainer_plateau_window"] = 400
    return value
  case .accurateReference:
    return [
      "mapper": "mapper",
      "bundle_adjustment": "full",
      "render_iterations": 30_000,
      "pose_source": "accurate_colmap",
    ]
  }
}

private func redactedArguments(
  variant: MeasurementVariant,
  request: BoundMeasurementRequest
) -> [String] {
  let prefix: String
  switch variant {
  case .baseline: prefix = "baseline://\(request.binding.baselineGitCommit)"
  case .candidate: prefix = "candidate://\(request.binding.gitCommit)"
  case .fastCandidate: prefix = "fast-candidate://\(request.binding.gitCommit)"
  case .accurateReference: prefix = "accurate-reference://full-ba-30k"
  }
  let toolchain = variant == .baseline
    ? "baseline-toolchain://\(request.binding.baselineToolchainIdentity)"
    : "toolchain://\(request.binding.toolchainIdentity)"
  return ["easysplat-benchmark", prefix, toolchain, "corpus://\(request.binding.sceneID)"]
}

private struct RuntimeGeometryEvidence {
  let receipt: [String: Any]
  let mapperInvocations: [[String: Any]]
  let plannedMapperCadence: [String: Any]?
  let acceptedMapperCadence: [String: Any]?
  let cadenceFallbackTrigger: String?
  let artifactPaths: [String: String]
  let geometry: GeometryArtifact
}

private func mapperCadenceEvidence(
  _ cadence: IncrementalMappingCadenceArtifact
) -> MeasurementMapperCadenceEvidence {
  MeasurementMapperCadenceEvidence(
    localMaxRefinements: cadence.localMaxRefinements,
    globalFramesRatio: cadence.globalFramesRatio,
    globalPointsRatio: cadence.globalPointsRatio,
    globalMaxRefinements: cadence.globalMaxRefinements,
    localMaxNumIterations: cadence.localMaxNumIterations,
    localFunctionTolerance: cadence.localFunctionTolerance,
    globalFunctionTolerance: cadence.globalFunctionTolerance,
    localImageCount: cadence.localImageCount
  )
}

private func runtimeGeometryEvidence(
  project: URL,
  runID: String
) throws -> RuntimeGeometryEvidence {
  let paths = ProjectPaths(root: project)
  let workerURL = project.appendingPathComponent("SfM/worker_execution.json")
  let geometryURL = project.appendingPathComponent("SfM/geometry_manifest.json")
  let decoder = JSONDecoder()
  let manifestEvidence: MeasurementRuntimeManifestEvidence
  let worker: GeometryWorkerExecutionArtifact
  let geometry: GeometryArtifact
  let metadata: ProjectMetadata
  do {
    _ = try paths.resolveProjectRelativePath("SfM/worker_execution.json")
    _ = try paths.resolveProjectRelativePath("SfM/geometry_manifest.json")
    manifestEvidence = try MeasurementRuntimeManifestEvidence.capture(
      workerURL: workerURL,
      geometryURL: geometryURL
    )
    let decodedWorker = try decoder.decode(
      GeometryWorkerExecutionArtifact.self,
      from: manifestEvidence.worker.data
    )
    worker = try GeometryWorkerExecutionArtifactStore.load(
      data: manifestEvidence.worker.data,
      expectedBudget: decodedWorker.resolvedBudget
    )
    geometry = try decoder.decode(GeometryArtifact.self, from: manifestEvidence.geometry.data)
    let authenticatedGeometry = try ProjectArtifactValidator.validatePublishedGeometry(
      at: project,
      expectedGeometry: geometry
    )
    guard authenticatedGeometry == geometry else {
      throw MeasurementRunnerError.identityMismatch(
        "published geometry validator returned a different artifact"
      )
    }
    metadata = try ProjectMetadataStore.load(
      from: paths.metadataURL
    )
    try worker.validateForPublishedGeometry(
      expectedBudget: worker.resolvedBudget,
      context: GeometryWorkerExecutionPublicationContext(
        mapping: geometry.mapping,
        pairGraph: geometry.pairGraph,
        input: metadata.input
      )
    )
  } catch {
    throw MeasurementRunnerError.subprocessFailed("runtime geometry evidence is invalid")
  }
  guard geometry.workerExecution == worker
  else {
    throw MeasurementRunnerError.subprocessFailed(
      "runtime worker evidence is not authenticated by the published project"
    )
  }
  let workerName = "worker_execution_\(runID)"
  let geometryName = "geometry_manifest_\(runID)"
  let canonicalCamerasName = "canonical_cameras_\(runID)"
  guard geometry.sourceModelPath == "SfM/colmap/sparse/0",
    let expectedCamerasDigest = geometry.modelHashes["cameras.txt"]
  else {
    throw MeasurementRunnerError.subprocessFailed(
      "runtime geometry does not bind the canonical cameras model"
    )
  }
  let canonicalModel = try paths.resolveProjectRelativePath(geometry.sourceModelPath)
  let canonicalCamerasURL = canonicalModel.appendingPathComponent("cameras.txt")
  let canonicalCameras = try MeasurementStableFileEvidence.read(
    canonicalCamerasURL,
    maximumBytes: 1_048_576
  ).requiringSHA256(expectedCamerasDigest, label: "canonical cameras")
  let receipt: [String: Any] = [
    "artifact_name": workerName,
    "artifact_sha256": "sha256:\(manifestEvidence.worker.sha256)",
    "geometry_manifest_name": geometryName,
    "geometry_manifest_sha256": "sha256:\(manifestEvidence.geometry.sha256)",
    "geometry_input_digest": "sha256:\(geometry.inputDigest)",
    "selected_frames_digest": "sha256:\(geometry.selectedFramesDigest)",
    "canonical_cameras_name": canonicalCamerasName,
    "canonical_cameras_sha256": "sha256:\(canonicalCameras.sha256)",
  ]

  let successfulMappers = worker.mappingAndRefinementInvocations.filter {
    $0.command == .mapper && $0.succeeded && $0.mappingAttemptOrdinal != nil
  }
  let mapperEvidence = try successfulMappers.map { invocation in
    guard let ordinal = invocation.mappingAttemptOrdinal,
      let execution = invocation.mapperExecution,
      let evaluation = execution.evaluation
    else {
      throw MeasurementRunnerError.subprocessFailed(
        "successful mapper execution lacks authenticated evaluation evidence"
      )
    }
    return MeasurementMapperInvocationEvidence(
      mappingAttemptOrdinal: ordinal,
      incrementalCadence: mapperCadenceEvidence(execution.incrementalCadence),
      globalMaxNumIterations: execution.globalMaxNumIterations,
      randomSeed: execution.randomSeed,
      refineFocalLength: execution.refineFocalLength,
      minimumPairInlierCount: execution.minimumPairInlierCount,
      pairGraphAttemptOrdinal: execution.pairGraphAttemptOrdinal,
      pairListDigest: execution.pairListDigest,
      descriptorMatcher: execution.descriptorMatcher.rawValue,
      matchingDatabaseDigest: execution.matchingDatabaseDigest,
      evaluation: MeasurementMapperEvaluationEvidence(
        status: evaluation.status.rawValue,
        fallbackTrigger: evaluation.fallbackTrigger?.rawValue
      ),
    )
  }
  let mapperInvocations = try MeasurementMapperEvidenceExporter.export(mapperEvidence)
  let plannedCadence = geometry.mapping.plannedIncrementalCadence.map(mapperCadenceEvidence)
  let acceptedCadence = geometry.mapping.incrementalCadence.map(mapperCadenceEvidence)
  return RuntimeGeometryEvidence(
    receipt: receipt,
    mapperInvocations: mapperInvocations,
    plannedMapperCadence: plannedCadence?.jsonObject,
    acceptedMapperCadence: acceptedCadence?.jsonObject,
    cadenceFallbackTrigger: geometry.mapping.cadenceFallbackTrigger?.rawValue,
    artifactPaths: [
      workerName: "worker-runs/\(runID)/project.easysplatproj/SfM/worker_execution.json",
      geometryName: "worker-runs/\(runID)/project.easysplatproj/SfM/geometry_manifest.json",
      canonicalCamerasName:
        "worker-runs/\(runID)/project.easysplatproj/SfM/colmap/sparse/0/cameras.txt",
    ],
    geometry: geometry
  )
}

private func referenceMapperInvocation(
  variant: MeasurementVariant,
  envelope: [String: Any]
) throws -> [[String: Any]] {
  let executable = variant == .baseline
    ? "baseline-toolchain://resolved/bin/colmap"
    : "toolchain://resolved/bin/colmap"
  guard let digest = envelope["source_model_digest"] as? String,
    digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  else {
    throw MeasurementRunnerError.subprocessFailed("reference model digest is invalid")
  }
  return [[
    "argv": [executable, "mapper"],
    "outcome": "accepted",
    "mapping_attempt_ordinal": 1,
    "matching_attempt": 1,
    "pair_list_digest": "sha256:\(digest)",
    "descriptor_matcher": "exact",
  ]]
}

private func pipelineMetrics(
  runtime: RuntimeGeometryEvidence,
  envelope: [String: Any]
) throws -> [String: Any] {
  guard let measurement = runtime.geometry.pairGraph.measurement,
    let trainingPath = envelope["training_manifest"] as? String
  else {
    throw MeasurementRunnerError.subprocessFailed("published pipeline measurements are missing")
  }
  let training = try readObject(URL(fileURLWithPath: trainingPath))
  let stages = try mapping(envelope["pipeline_stage_seconds"], "pipeline_stage_seconds")
  func trainingValue(_ name: String) -> Any {
    training[name] ?? NSNull()
  }
  var metrics: [String: Any] = [
    "scheduled_pairs": measurement.scheduledPairCount,
    "attempted_pairs": measurement.attemptedPairCount,
    "raw_matched_pairs": measurement.rawMatchedPairCount,
    "spatially_verified_pairs": measurement.spatiallyVerifiedPairCount,
    "connected_components": measurement.connectedComponentCount,
    "isolated_views": measurement.isolatedViewCount,
    "articulation_views": measurement.articulationViewCount,
    "biconnected_blocks": measurement.biconnectedBlockCount,
    "largest_biconnected_block_views": measurement.largestBiconnectedBlockViewCount,
    "second_largest_biconnected_block_views": measurement.secondLargestBiconnectedBlockViewCount,
    "local_pairs": measurement.localPairCount,
    "retrieval_pairs": measurement.retrievalPairCount,
    "loop_pairs": measurement.loopRevisitPairCount,
    "bundle_adjustment_cycles": runtime.geometry.mapping.acceptedRefinementInvocationCount,
    "matcher_seconds": measurement.matchingDurationSeconds,
    "mapping_seconds": try number(stages["sfmMapping"], "sfmMapping"),
    "raster_fallback_count": trainingValue("raster_fallback_count"),
    "raster_exact_fallback_elapsed_seconds": trainingValue(
      "raster_exact_fallback_elapsed_seconds"
    ),
    "raster_exact_buffer_growth_count": trainingValue("raster_exact_buffer_growth_count"),
    "raster_exact_buffer_bytes_added": trainingValue("raster_exact_buffer_bytes_added"),
    "raster_replay_elapsed_seconds": trainingValue("raster_replay_elapsed_seconds"),
    "raster_peak_exact_intersection_capacity": trainingValue(
      "raster_peak_exact_intersection_capacity"
    ),
    "maximum_tile_intersections": NSNull(),
    "dropped_intersection_count": trainingValue("dropped_intersection_count"),
  ]
  MeasurementOrientationMetricBoundary.reserveSupervisorFields(in: &metrics)
  return metrics
}

private func run() throws {
  let arguments = try MeasurementRunnerArguments.parse(CommandLine.arguments)
  let request = try BoundMeasurementRequest.load(
    from: arguments.request,
    expectedLane: arguments.lane
  )
  let rawRequest = try readObject(arguments.request, maximumBytes: 2 * 1_024 * 1_024)
  let workers = try MeasurementWorkerSet.resolve(
    nextTo: URL(fileURLWithPath: CommandLine.arguments[0])
  )
  let rootValues = try arguments.artifactRoot.resourceValues(forKeys: [
    .isDirectoryKey, .isSymbolicLinkKey,
  ])
  guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
    throw MeasurementRunnerError.unsafePath("artifact root must be a plain directory")
  }
  let observationsURL = arguments.artifactRoot.appendingPathComponent("observations.json")
  guard !FileManager.default.fileExists(atPath: observationsURL.path) else {
    throw MeasurementRunnerError.unsafePath("observations.json already exists")
  }
  let needsSceneQualityReferences = arguments.lane == .reference
    && request.expectedOutcome.kind == "valid"
    && request.gateScopes.contains("scene_quality")
  let referenceClosure: MeasurementReferenceArtifactClosure?
  var protectedReferenceArtifacts: [String: String] = [:]
  if needsSceneQualityReferences {
    guard let sourceRoot = arguments.referenceArtifactRoot else {
      throw MeasurementRunnerError.invalidArguments(
        "scene-quality evidence requires --reference-artifact-root")
    }
    let references = try mapping(rawRequest["reference_artifacts"], "reference_artifacts")
    let declarations: [(artifact: String, filename: String, requestField: String)] = [
      ("accurate_colmap_model", "accurate-colmap-model.json", "accurate_colmap_model_sha256"),
      ("accurate_rendering_reference", "accurate-rendering-reference.json", "accurate_rendering_reference_sha256"),
      ("ground_truth_poses", "ground-truth-poses.json", "ground_truth_poses_sha256"),
      ("ground_truth_preparation", "ground-truth-preparation.json", "ground_truth_preparation_sha256"),
      ("orientation_label", "orientation-label.json", "orientation_label_sha256"),
      ("paired_baseline_rendering_reference", "paired-baseline-rendering-reference.json", "paired_baseline_rendering_reference_sha256"),
    ]
    let expected = try declarations.map { declaration in
      guard let digest = references[declaration.requestField] as? String else {
        throw MeasurementRunnerError.invalidRequest(
          "reference_artifacts.\(declaration.requestField) is missing")
      }
      protectedReferenceArtifacts[declaration.artifact] = declaration.filename
      return MeasurementReferenceArtifactClosure.ExpectedArtifact(
        filename: declaration.filename, sha256: digest)
    }
    referenceClosure = try MeasurementReferenceArtifactClosure.stage(
      sourceRoot: sourceRoot,
      artifactRoot: arguments.artifactRoot,
      expected: expected.sorted { $0.filename < $1.filename }
    )
  } else {
    guard arguments.referenceArtifactRoot == nil else {
      throw MeasurementRunnerError.invalidArguments(
        "--reference-artifact-root is reserved for reference scene-quality evidence")
    }
    referenceClosure = nil
  }
  let runs = MeasurementSchedule.make(
    for: arguments.lane,
    gateScopes: Set(request.gateScopes),
    validOutcome: request.expectedOutcome.kind == "valid"
  )
  let runnerDigest = "sha256:" + (try MeasurementWorkerExecutor.sha256(
    URL(fileURLWithPath: CommandLine.arguments[0])
  ))
  var commands: [[String: Any]] = []
  var timing: [String: [[String: Any]]] = [:]
  var artifacts: [String: String] = [:]
  artifacts.merge(protectedReferenceArtifacts) { _, _ in
    preconditionFailure("duplicate protected reference artifact")
  }
  var publishedEnvelope: [String: Any]?
  var publishedRuntimeEvidence: RuntimeGeometryEvidence?
  var memorySamples: [[String: Any]] = []
  var invalidExitCode: Int?
  var invalidFailureType: String?

  let workerRuns = arguments.artifactRoot.appendingPathComponent("worker-runs", isDirectory: true)
  let envelopes = arguments.artifactRoot.appendingPathComponent(
    "worker-envelopes",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: workerRuns, withIntermediateDirectories: false)
  try FileManager.default.createDirectory(at: envelopes, withIntermediateDirectories: false)

  for measurement in runs {
    let runParent = workerRuns.appendingPathComponent(measurement.runID, isDirectory: true)
    let project = ProjectPublicationTransaction.candidateURL(
      in: runParent, title: "project", attempt: 0
    )
    let envelopeURL = envelopes.appendingPathComponent("\(measurement.runID).json")
    let invocation = MeasurementWorkerInvocation(
      executable: executable(for: measurement.variant, workers: workers),
      request: arguments.request,
      input: arguments.input,
      toolchainRoot: toolchainRoot(for: measurement.variant, arguments: arguments),
      projectRoot: project,
      variant: measurement.variant,
      envelope: envelopeURL,
      stdoutLog: arguments.artifactRoot.appendingPathComponent(
        "worker-\(measurement.runID).stdout.log"
      ),
      stderrLog: arguments.artifactRoot.appendingPathComponent(
        "worker-\(measurement.runID).stderr.log"
      )
    )
    if request.expectedOutcome.kind == "invalid" {
      let failure = try MeasurementWorkerExecutor.runExpectedFailure(invocation)
      guard let expectedFailureType = request.expectedOutcome.failureType else {
        throw MeasurementRunnerError.invalidRequest("invalid outcome lacks failure_type")
      }
      guard failure.failureType == expectedFailureType else {
        throw MeasurementRunnerError.identityMismatch(
          "typed invalid-input rejection differs from the bound expectation"
        )
      }
      invalidExitCode = Int(failure.exitCode)
      invalidFailureType = failure.failureType
      let runConfiguration = try configuration(for: measurement.variant, request: rawRequest)
      commands.append([
        "run_id": measurement.runID,
        "phase": measurement.phase.rawValue,
        "variant": measurement.variant.rawValue,
        "argv": redactedArguments(variant: measurement.variant, request: request),
        "mapper_invocations": [],
        "planned_mapper_cadence": NSNull(),
        "accepted_mapper_cadence": NSNull(),
        "cadence_fallback_trigger": NSNull(),
        "runtime_worker_evidence": NSNull(),
        "started_monotonic_seconds": failure.startedMonotonicSeconds,
        "ended_monotonic_seconds": failure.endedMonotonicSeconds,
        "process_cpu_microseconds": [
          "user": failure.userCPUMicroseconds,
          "system": failure.systemCPUMicroseconds,
        ],
        "exit_code": Int(failure.exitCode),
        "checkout_commit": request.binding.gitCommit,
        "toolchain_identity": request.binding.toolchainIdentity,
        "run_configuration_digest": try canonicalDigest(runConfiguration),
        "executable_sha256": runnerDigest,
        "output_sha256": "sha256:\(failure.failureReceiptSHA256)",
        "scene_id": request.binding.sceneID,
        "input_digest": request.binding.inputDigest,
        "scale": request.binding.scale,
        "lane": request.binding.lane.rawValue,
        "published_output": false,
      ])
      continue
    }
    let execution = try MeasurementWorkerExecutor.run(invocation)
    let envelope = try readObject(envelopeURL)
    let runConfiguration = try configuration(for: measurement.variant, request: rawRequest)
    let runtimeEvidence: RuntimeGeometryEvidence?
    let mapperInvocations: [[String: Any]]
    switch measurement.variant {
    case .candidate, .fastCandidate:
      let evidence = try runtimeGeometryEvidence(project: project, runID: measurement.runID)
      runtimeEvidence = evidence
      mapperInvocations = evidence.mapperInvocations
      for (name, path) in evidence.artifactPaths {
        guard artifacts.updateValue(path, forKey: name) == nil else {
          throw MeasurementRunnerError.identityMismatch("runtime artifact name was reused")
        }
      }
      if needsSceneQualityReferences, measurement.phase == .ordinary,
        measurement.variant == .candidate
      {
        let orientationRoot = arguments.artifactRoot
          .appendingPathComponent("orientation-runs", isDirectory: true)
          .appendingPathComponent(measurement.runID, isDirectory: true)
        try FileManager.default.createDirectory(
          at: orientationRoot, withIntermediateDirectories: true)
        try copyExclusive(
          project.appendingPathComponent("SfM/geometry_manifest.json"),
          to: orientationRoot.appendingPathComponent("geometry-manifest.json")
        )
        let model = try ProjectPaths(root: project).resolveProjectRelativePath(
          evidence.geometry.sourceModelPath)
        try copyExclusive(
          model.appendingPathComponent("images.txt"),
          to: orientationRoot.appendingPathComponent("candidate-images.txt")
        )
      }
    case .baseline, .accurateReference:
      runtimeEvidence = nil
      mapperInvocations = try referenceMapperInvocation(
        variant: measurement.variant,
        envelope: envelope
      )
    }
    if measurement.variant == .candidate || measurement.variant == .fastCandidate {
      memorySamples.append(contentsOf: execution.memorySamples.map { sample in
        [
          "run_id": measurement.runID,
          "elapsed_seconds": sample.elapsedSeconds,
          "process_tree_resident_bytes": sample.processTreeResidentBytes,
          "metal_allocated_bytes": sample.metalAllocatedBytes,
        ]
      })
    }
    let endToEnd = execution.endedMonotonicSeconds - execution.startedMonotonicSeconds
    var timingRecord: [String: Any] = [
      "run_id": measurement.runID,
      "variant": measurement.variant.rawValue,
      "discarded": measurement.discarded,
      "end_to_end_seconds": endToEnd,
    ]
    if measurement.phase == .ordinary {
      let stages = try mapping(envelope["stage_seconds"], "stage_seconds")
      timingRecord["geometry_seconds"] = try number(stages["reconstruct"], "reconstruct")
      timingRecord["training_seconds"] = try number(stages["train"], "train")
    } else if measurement.phase == .phase {
      if measurement.variant == .accurateReference {
        let stages = try mapping(envelope["stage_seconds"], "stage_seconds")
        timingRecord["matcher_seconds"] = try number(
          stages["reconstruct_matching"],
          "reconstruct_matching"
        )
        timingRecord["mapping_seconds"] = try number(
          stages["reconstruct_mapping"],
          "reconstruct_mapping"
        )
      } else {
        let stages = try mapping(envelope["pipeline_stage_seconds"], "pipeline_stage_seconds")
        timingRecord["matcher_seconds"] = try number(stages["sfmMatching"], "sfmMatching")
        timingRecord["mapping_seconds"] = try number(stages["sfmMapping"], "sfmMapping")
      }
    }
    timing["\(measurement.phase.rawValue)_runs", default: []].append(timingRecord)

    let configurationDigest = try canonicalDigest(runConfiguration)
    let outputDigest = "sha256:\(execution.outputSHA256)"
    commands.append([
      "run_id": measurement.runID,
      "phase": measurement.phase.rawValue,
      "variant": measurement.variant.rawValue,
      "argv": redactedArguments(variant: measurement.variant, request: request),
      "mapper_invocations": mapperInvocations,
      "planned_mapper_cadence": runtimeEvidence?.plannedMapperCadence ?? NSNull(),
      "accepted_mapper_cadence": runtimeEvidence?.acceptedMapperCadence ?? NSNull(),
      "cadence_fallback_trigger": runtimeEvidence?.cadenceFallbackTrigger ?? NSNull(),
      "runtime_worker_evidence": runtimeEvidence?.receipt ?? NSNull(),
      "started_monotonic_seconds": execution.startedMonotonicSeconds,
      "ended_monotonic_seconds": execution.endedMonotonicSeconds,
      "process_cpu_microseconds": [
        "user": execution.userCPUMicroseconds,
        "system": execution.systemCPUMicroseconds,
      ],
      "exit_code": Int(execution.exitCode),
      "checkout_commit": measurement.variant == .baseline
        ? request.binding.baselineGitCommit : request.binding.gitCommit,
      "toolchain_identity": measurement.variant == .baseline
        ? request.binding.baselineToolchainIdentity : request.binding.toolchainIdentity,
      "run_configuration_digest": configurationDigest,
      "executable_sha256": runnerDigest,
      "output_sha256": outputDigest,
      "scene_id": request.binding.sceneID,
      "input_digest": request.binding.inputDigest,
      "scale": request.binding.scale,
      "lane": request.binding.lane.rawValue,
      "published_output": measurement.publishesOutput,
    ])
    if measurement.publishesOutput {
      publishedEnvelope = envelope
      publishedRuntimeEvidence = runtimeEvidence
      try copyExclusive(
        execution.outputPLY,
        to: arguments.artifactRoot.appendingPathComponent("splat.ply")
      )
      if let source = envelope["training_manifest"] as? String {
        try copyExclusive(
          URL(fileURLWithPath: source),
          to: arguments.artifactRoot.appendingPathComponent("training-manifest.json")
        )
      }
      if let source = envelope["selection_manifest"] as? String {
        let sourceURL = URL(fileURLWithPath: source)
        let references = try mapping(rawRequest["reference_artifacts"], "reference_artifacts")
        guard let expectedDigest = references["selection_manifest_sha256"] as? String,
          expectedDigest == "sha256:\(try MeasurementWorkerExecutor.sha256(sourceURL))"
        else {
          throw MeasurementRunnerError.identityMismatch(
            "published selection does not match the protected split"
          )
        }
        try copyExclusive(
          sourceURL,
          to: arguments.artifactRoot.appendingPathComponent("selection-manifest.json")
        )
      }
      if let source = envelope["training_split_manifest"] as? String {
        try copyExclusive(
          URL(fileURLWithPath: source),
          to: arguments.artifactRoot.appendingPathComponent("training-split.json")
        )
      }
      if let source = envelope["geometry_manifest"] as? String {
        try copyExclusive(
          URL(fileURLWithPath: source),
          to: arguments.artifactRoot.appendingPathComponent("geometry-manifest.json")
        )
      }
      if needsSceneQualityReferences {
        guard let runtimeEvidence,
          let measurement = runtimeEvidence.geometry.pairGraph.measurement
        else {
          throw MeasurementRunnerError.subprocessFailed(
            "published pair-graph evidence is missing"
          )
        }
        let pairList = try MeasurementPairListBuilder.write(
          source: project.appendingPathComponent("SfM/pair_graph_evidence.json"),
          selectedFrameCount: request.binding.scale,
          to: arguments.artifactRoot.appendingPathComponent("pair-list.json")
        )
        let attemptsMatch = pairList.attempts.count == measurement.matcherAttempts.count
          && zip(pairList.attempts, measurement.matcherAttempts).allSatisfy { actual, expected in
            actual.attemptNumber == expected.attemptNumber
              && actual.matcher == expected.matcher.rawValue
              && actual.exactRecoveryReason == expected.exactRecoveryReason?.rawValue
              && actual.recoveryLevel == expected.recoveryLevel.rawValue
              && actual.outcome == expected.outcome.rawValue
              && actual.scheduledPairCount == expected.scheduledPairCount
              && actual.attemptedPairCount == expected.attemptedPairCount
              && actual.rawMatchedPairCount == expected.rawMatchedPairCount
              && actual.spatiallyVerifiedPairCount == expected.spatiallyVerifiedPairCount
          }
        guard pairList.pairListDigest == measurement.pairListDigest,
          pairList.scheduledPairCount == measurement.scheduledPairCount,
          pairList.attemptedPairCount == measurement.attemptedPairCount,
          pairList.rawMatchedPairCount == measurement.rawMatchedPairCount,
          pairList.spatiallyVerifiedPairCount == measurement.spatiallyVerifiedPairCount,
          pairList.localPairCount == measurement.localPairCount,
          pairList.retrievalPairCount == measurement.retrievalPairCount,
          pairList.loopPairCount == measurement.loopRevisitPairCount,
          attemptsMatch
        else {
          throw MeasurementRunnerError.identityMismatch(
            "published pair-list evidence does not match the geometry artifact"
          )
        }
        artifacts["pair_list"] = "pair-list.json"
      }
      artifacts["output_ply"] = "splat.ply"
      artifacts["training_manifest"] = "training-manifest.json"
      artifacts["selection_manifest"] = "selection-manifest.json"
      artifacts["training_split"] = "training-split.json"
      artifacts["geometry_manifest"] = "geometry-manifest.json"
    }
  }

  guard request.expectedOutcome.kind != "valid" || publishedEnvelope != nil else {
    throw MeasurementRunnerError.subprocessFailed("valid schedule did not publish an output")
  }
  artifacts["stdout_log"] = "stdout.log"
  artifacts["stderr_log"] = "stderr.log"
  artifacts["command_log"] = "command.jsonl"
  var observations: [String: Any] = [
    "schema_version": 3,
    "artifacts": artifacts,
    "commands": commands,
    "actual": [
      "exit_code": invalidExitCode ?? 0,
      "termination_reason": "exit",
      "cancelled": false,
      "failure_type": invalidFailureType.map { $0 as Any } ?? NSNull(),
      "corrupt_ply": false,
    ],
    "baseline": [
      "git_commit": request.binding.baselineGitCommit,
      "toolchain_identity": request.binding.baselineToolchainIdentity,
      "configuration_digest": try canonicalDigest(
        mapping(rawRequest["baseline_run_configuration"], "baseline_run_configuration")
      ),
    ],
  ]
  if request.expectedOutcome.kind == "valid" {
    guard let publishedEnvelope, let publishedRuntimeEvidence else {
      throw MeasurementRunnerError.subprocessFailed("published candidate evidence is missing")
    }
    observations["timing"] = timing
    observations["memory"] = [
      "sample_interval_seconds": 0.5,
      "samples": memorySamples,
    ]
    observations["resolved_compute"] = [
      "stages": [
        "feature_extraction": "cpu",
        "matching": "cpu",
        "mapping": "cpu",
        "training": "metal",
        "rendering": "metal",
      ],
      "cpu_only_reasons": [
        "feature_extraction": "colmap_sift_has_no_supported_metal_backend",
        "matching": "faiss_metal_disabled_selected_indices_unsupported",
        "mapping": "ceres_has_no_supported_metal_backend",
      ],
    ]
    observations["pipeline_metrics"] = try pipelineMetrics(
      runtime: publishedRuntimeEvidence,
      envelope: publishedEnvelope
    )
  }
  try referenceClosure?.reverify()
  try writeJSON(observations, to: observationsURL)
}

do {
  try run()
} catch {
  FileHandle.standardError.write(
    Data("EasySplat measurement runner: \(error.localizedDescription)\n".utf8)
  )
  Foundation.exit(1)
}
