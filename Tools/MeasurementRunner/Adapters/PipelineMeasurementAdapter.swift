import CryptoKit
import CoreFoundation
import Darwin
import Foundation

@testable import EasySplatCore

#if !CURRENT_ADAPTER && !BASELINE_ADAPTER && !ACCURATE_REFERENCE
  #error("Exactly one measurement adapter variant must be defined")
#elseif (CURRENT_ADAPTER && BASELINE_ADAPTER) || (CURRENT_ADAPTER && ACCURATE_REFERENCE) || (BASELINE_ADAPTER && ACCURATE_REFERENCE)
  #error("Exactly one measurement adapter variant must be defined")
#endif

enum AdapterError: Error, LocalizedError {
  case invalidArguments(String)
  case invalidRequest(String)
  case pipelineFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let detail): "Invalid adapter arguments: \(detail)"
    case .invalidRequest(let detail): "Invalid measurement request: \(detail)"
    case .pipelineFailed(let detail): "Pipeline measurement failed: \(detail)"
    }
  }
}

struct AdapterArguments {
  let request: URL
  let input: URL
  let toolchainRoot: URL
  let projectRoot: URL
  let variant: String
  let output: URL
  let geometryOnly: Bool
  let matchingOnly: Bool
  let mappingFromCheckpoint: URL?
  let mapperCadence: String?
  let trialRoot: URL?

  static func parse(_ arguments: [String]) throws -> Self {
    let required = [
      "--request", "--input", "--toolchain-root", "--project-root", "--variant", "--output",
    ]
    let mappingOptions = [
      "--mapping-from-checkpoint", "--mapper-cadence", "--trial-root",
    ]
    let allowed = required + ["--geometry-only", "--matching-only"] + mappingOptions
    let tail = Array(arguments.dropFirst())
    guard tail.count.isMultiple(of: 2),
      tail.count >= required.count * 2,
      tail.count <= allowed.count * 2
    else {
      throw AdapterError.invalidArguments("expected the fixed measurement boundary")
    }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: tail.count, by: 2) {
      let key = tail[index]
      guard allowed.contains(key), values[key] == nil, !tail[index + 1].isEmpty else {
        throw AdapterError.invalidArguments("unknown, duplicate, or empty option")
      }
      values[key] = tail[index + 1]
    }
    guard Set(required).isSubset(of: Set(values.keys)) else {
      throw AdapterError.invalidArguments("missing option")
    }
    #if ACCURATE_REFERENCE
      guard values["--geometry-only"] == nil,
        values["--matching-only"] == nil,
        mappingOptions.allSatisfy({ values[$0] == nil })
      else {
        throw AdapterError.invalidArguments(
          "accurate-reference does not support partial pipeline modes"
        )
      }
      guard values["--variant"] == "accurate_reference" else {
        throw AdapterError.invalidArguments(
          "the accurate-reference worker accepts only accurate_reference"
        )
      }
    #elseif BASELINE_ADAPTER
      guard values["--geometry-only"] == nil,
        values["--matching-only"] == nil,
        mappingOptions.allSatisfy({ values[$0] == nil })
      else {
        throw AdapterError.invalidArguments("baseline does not support partial pipeline modes")
      }
      guard values["--variant"] == "baseline" else {
        throw AdapterError.invalidArguments("the baseline worker accepts only baseline")
      }
    #elseif CURRENT_ADAPTER
      if let geometryOnly = values["--geometry-only"], geometryOnly != "true" {
        throw AdapterError.invalidArguments("geometry-only must be true when present")
      }
      if let matchingOnly = values["--matching-only"], matchingOnly != "true" {
        throw AdapterError.invalidArguments("matching-only must be true when present")
      }
      guard values["--geometry-only"] == nil || values["--matching-only"] == nil else {
        throw AdapterError.invalidArguments(
          "geometry-only and matching-only are mutually exclusive"
        )
      }
      let suppliedMappingOptionCount = mappingOptions.reduce(0) {
        $0 + (values[$1] == nil ? 0 : 1)
      }
      guard suppliedMappingOptionCount == 0 || suppliedMappingOptionCount == mappingOptions.count
      else {
        throw AdapterError.invalidArguments(
          "mapping checkpoint, cadence, and trial root must be supplied together"
        )
      }
      if suppliedMappingOptionCount == mappingOptions.count {
        guard values["--geometry-only"] == nil, values["--matching-only"] == nil else {
          throw AdapterError.invalidArguments(
            "mapping-from-checkpoint is mutually exclusive with other partial modes"
          )
        }
        guard
          values["--mapper-cadence"] == "frequent-global"
            || values["--mapper-cadence"] == "balanced-global"
        else {
          throw AdapterError.invalidArguments("mapper-cadence is unsupported")
        }
      }
      guard
        values["--variant"] == "candidate"
          || values["--variant"] == "fast_candidate"
      else {
        throw AdapterError.invalidArguments(
          "the current worker accepts only candidate or fast_candidate"
        )
      }
    #endif
    return Self(
      request: URL(fileURLWithPath: values["--request"]!),
      input: URL(fileURLWithPath: values["--input"]!),
      toolchainRoot: URL(fileURLWithPath: values["--toolchain-root"]!, isDirectory: true),
      projectRoot: URL(fileURLWithPath: values["--project-root"]!, isDirectory: true),
      variant: values["--variant"]!,
      output: URL(fileURLWithPath: values["--output"]!),
      geometryOnly: values["--geometry-only"] == "true",
      matchingOnly: values["--matching-only"] == "true",
      mappingFromCheckpoint: values["--mapping-from-checkpoint"].map {
        URL(fileURLWithPath: $0)
      },
      mapperCadence: values["--mapper-cadence"],
      trialRoot: values["--trial-root"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
    )
  }
}

func mapping(_ value: Any?, _ label: String) throws -> [String: Any] {
  guard let result = value as? [String: Any] else {
    throw AdapterError.invalidRequest("\(label) must be an object")
  }
  return result
}

func string(_ value: Any?, _ label: String) throws -> String {
  guard let result = value as? String, !result.isEmpty else {
    throw AdapterError.invalidRequest("\(label) must be a nonempty string")
  }
  return result
}

func integer(_ value: Any?, _ label: String) throws -> Int {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else {
    throw AdapterError.invalidRequest("\(label) must be an integer")
  }
  let result = number.intValue
  guard Double(result) == number.doubleValue else {
    throw AdapterError.invalidRequest("\(label) must be an integer")
  }
  return result
}

func integerArray(_ value: Any?, _ label: String) throws -> [Int] {
  guard let values = value as? [Any] else {
    throw AdapterError.invalidRequest("\(label) must be an integer array")
  }
  return try values.enumerated().map { index, value in
    try integer(value, "\(label)[\(index)]")
  }
}

func files(in directory: URL, extensions: Set<String>) throws -> [String] {
  try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
    options: [.skipsHiddenFiles]
  ).filter { url in
    guard extensions.contains(url.pathExtension.lowercased()),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else {
      return false
    }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(\.path)
}

func inputSpec(kind: String, input: URL) throws -> InputSpec {
  switch kind {
  case "video":
    return .video(files: [input.path])
  case "multi_video":
    return .video(files: try files(in: input, extensions: ["mov", "mp4", "m4v"]))
  case "photos":
    return .photos(folder: input.path)
  case "mixed":
    let videos = try files(in: input, extensions: ["mov", "mp4", "m4v"])
    return videos.isEmpty
      ? .photos(folder: input.path) : .mixed(videos: videos, photosFolder: input.path)
  default:
    throw AdapterError.invalidRequest("input_kind is unsupported")
  }
}

func requestedOptions(_ configuration: [String: Any]) throws -> RequestedRunOptions {
  let capture: CapturePath
  switch try string(configuration["capture_path"], "capture_path") {
  case "around_subject": capture = .orbit
  case "through_space": capture = .walkthrough
  case "large_area": capture = .largeArea
  case "automatic": capture = .automatic
  default: throw AdapterError.invalidRequest("capture_path is unsupported")
  }
  let detail: DetailProfile
  switch try string(configuration["detail_profile"], "detail_profile") {
  case "fast": detail = .fast
  case "balanced": detail = .balanced
  case "high_detail": detail = .highDetail
  default: throw AdapterError.invalidRequest("detail_profile is unsupported")
  }
  let grouping: CameraGrouping
  switch try string(configuration["camera_grouping"], "camera_grouping") {
  case "automatic": grouping = .automatic
  case "same_camera_and_lens": grouping = .sameCameraAndLens
  case "mixed_cameras_or_lenses": grouping = .mixedCamerasOrLenses
  default: throw AdapterError.invalidRequest("camera_grouping is unsupported")
  }
  let lens: LensProjection
  switch try string(configuration["lens_projection"], "lens_projection") {
  case "automatic": lens = .automatic
  case "perspective": lens = .perspective
  case "fisheye": lens = .fisheye
  default: throw AdapterError.invalidRequest("lens_projection is unsupported")
  }
  guard let topology = MeasurementInputTopology(
    rawValue: try string(configuration["input_topology"], "input_topology")
  ) else {
    throw AdapterError.invalidRequest("input_topology is unsupported")
  }
  let resource: ResourcePolicy
  switch try string(configuration["resource_policy"], "resource_policy") {
  case "conserve_memory": resource = .conserveMemory
  case "maximum_performance": resource = .maximumPerformance
  default: resource = .automatic
  }
  return RequestedRunOptions(
    capturePath: capture,
    detailProfile: detail,
    cameraGrouping: grouping,
    lensProjection: lens,
    inputOrdering: topology.requestedInputOrdering,
    resourcePolicy: resource,
    photoSelection: .automatic
  )
}

func toolchain(at root: URL) -> ToolchainPaths {
  let da3Root = root.appendingPathComponent("da3_mps", isDirectory: true)
  return ToolchainPaths(
    root: root,
    colmap: root.appendingPathComponent("bin/colmap"),
    msplat: root.appendingPathComponent("bin/easysplat-train"),
    da3: Da3Toolchain(
      root: da3Root,
      sfmTool: da3Root.appendingPathComponent("bin/easysplat_da3_sfm"),
      python: da3Root.appendingPathComponent("python/bin/python3"),
      models: da3Root.appendingPathComponent("models", isDirectory: true),
      modelBundle: da3Root.appendingPathComponent("models/DA3-BASE", isDirectory: true),
      smallModelBundle: da3Root.appendingPathComponent("models/DA3-SMALL", isDirectory: true)
    )
  )
}

func configuredPlan(
  options: RequestedRunOptions,
  input: InputSpec,
  configuration: [String: Any],
  scale: Int,
  hardware: HardwareProfile
) throws -> ResolvedRunPlan {
  let seed = try integer(configuration["run_seed"], "run_seed")
  var plan = RunPlanResolver.resolve(
    requestedOptions: options,
    input: input,
    hardware: hardware,
    developmentOverrides: DevelopmentOverrides(candidateRoute: .colmap, benchmarkSeed: seed)
  )
  plan.keyframeBudget = scale
  #if ACCURATE_REFERENCE
    plan.trainerIterationLimit = 30_000
    plan.plateauWindow = 30_000
  #else
    plan.trainerIterationLimit = try integer(
      configuration["trainer_iterations"], "trainer_iterations")
    plan.plateauWindow = try integer(
      configuration["trainer_plateau_window"], "trainer_plateau_window")
  #endif
  return plan
}

func measurementTrainerMemoryBudget(_ plan: ResolvedRunPlan) -> Int64 {
  #if BASELINE_ADAPTER
    return Int64(min(ProcessInfo.processInfo.physicalMemory * 3 / 4, UInt64(Int64.max)))
  #else
    return plan.trainerMemoryBudgetBytes
  #endif
}

func stageName(_ stage: PipelineStage) -> String {
  switch stage {
  case .importInput, .extractFrames, .selectFrames: "prepare"
  case .sfmFeatures, .sfmMatching, .sfmMapping: "reconstruct"
  case .trainSplat: "train"
  case .exportSplat: "finish"
  case .done: "completed"
  }
}

struct PreparedMeasurementDataset {
  let url: URL
  let identity: MsplatDatasetIdentity
  let split: MeasurementTrainingSplit
  let filteredModel: MeasurementFilteredCOLMAPModel
  let sourceModelDigest: String
  let filteredModelDigest: String
  let splitManifest: URL
}

func canonicalOrientationQuaternion(from geometryManifest: URL) throws -> [Double] {
  let value = try mapping(
    JSONSerialization.jsonObject(with: Data(contentsOf: geometryManifest)),
    "geometry_manifest"
  )
  guard let orientation = value["canonicalOrientation"] as? [String: Any] else {
    return [1, 0, 0, 0]
  }
  guard let rawQuaternion = orientation["sourceToCanonicalQuaternionWXYZ"] else {
    return [1, 0, 0, 0]
  }
  guard let quaternion = rawQuaternion as? [String: Any],
    let w = quaternion["w"] as? NSNumber,
    let x = quaternion["x"] as? NSNumber,
    let y = quaternion["y"] as? NSNumber,
    let z = quaternion["z"] as? NSNumber
  else {
    throw AdapterError.pipelineFailed("canonical orientation quaternion is invalid")
  }
  let components = [w.doubleValue, x.doubleValue, y.doubleValue, z.doubleValue]
  let norm = components.reduce(0) { $0 + $1 * $1 }
  guard components.allSatisfy(\.isFinite), abs(norm - 1) <= 1e-6 else {
    throw AdapterError.pipelineFailed("canonical orientation quaternion is not a unit rotation")
  }
  return components
}

func orderedGeometryImageNames(from geometryManifest: URL) throws -> [String] {
  let value = try mapping(
    JSONSerialization.jsonObject(with: Data(contentsOf: geometryManifest)),
    "geometry_manifest"
  )
  guard let names = value["orderedImageNames"] as? [String],
    !names.isEmpty,
    names.count <= 3_000,
    Set(names).count == names.count
  else {
    throw AdapterError.pipelineFailed("geometry manifest has invalid ordered image names")
  }
  return names
}

func createMeasurementTextModelDirectory(
  paths: ProjectPaths,
  variant: String
) throws -> URL {
  guard ["candidate", "fast_candidate", "baseline"].contains(variant) else {
    throw AdapterError.invalidArguments("measurement variant is unsupported")
  }
  let relativePath = "Training/measurement-\(variant)-source-text"
  try paths.ensureMutableTrainingDirectories()
  let destination = try paths.resolveProjectRelativePath(relativePath)
  let fileManager = FileManager.default
  guard !fileManager.fileExists(atPath: destination.path),
    (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) == nil
  else {
    throw AdapterError.pipelineFailed("measurement text model destination already exists")
  }

  var created = false
  var verified = false
  defer {
    if created && !verified {
      try? fileManager.removeItem(at: destination)
    }
  }
  try fileManager.createDirectory(
    at: destination,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  created = true
  let values = try destination.resourceValues(
    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
  )
  guard values.isDirectory == true,
    values.isSymbolicLink != true,
    try paths.projectRelativePath(for: destination) == relativePath
  else {
    throw AdapterError.pipelineFailed("measurement text model destination is unsafe")
  }
  verified = true
  return destination
}

func projectSpelledPath(
  paths: ProjectPaths,
  artifact: URL
) throws -> String {
  let relativePath = try paths.projectRelativePath(for: artifact)
  return paths.root.appendingPathComponent(relativePath).path
}

func prepareMeasurementDataset(
  paths: ProjectPaths,
  textModel: URL,
  selectedImageNames: [String],
  holdoutIndices: [Int],
  toolchainRoot: URL,
  label: String,
  orientationQuaternion: [Double]? = nil
) throws -> PreparedMeasurementDataset {
  guard holdoutIndices == holdoutIndices.sorted(),
    Set(holdoutIndices).count == holdoutIndices.count,
    holdoutIndices.allSatisfy(selectedImageNames.indices.contains)
  else {
    throw AdapterError.invalidRequest("holdout_indices are invalid")
  }
  let fileManager = FileManager.default
  let root = paths.trainingURL.appendingPathComponent(label, isDirectory: true)
  guard !fileManager.fileExists(atPath: root.path) else {
    throw AdapterError.pipelineFailed("measurement dataset destination already exists")
  }
  let filteredText = root.appendingPathComponent("filtered-text", isDirectory: true)
  let dataset = root.appendingPathComponent("dataset", isDirectory: true)
  let images = dataset.appendingPathComponent("images", isDirectory: true)
  let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
  try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
  try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
  try fileManager.createDirectory(at: sparse, withIntermediateDirectories: true)
  let holdoutNames = Set(holdoutIndices.map { selectedImageNames[$0] })
  let filtered = try MeasurementCOLMAPTextFilter.filter(
    source: textModel,
    destination: filteredText,
    holdoutImageNames: holdoutNames
  )
  let registeredTraining = Set(filtered.trainingImageNames)
  let orderedDatasetNames = selectedImageNames.filter(registeredTraining.contains)
  guard orderedDatasetNames.count == registeredTraining.count else {
    throw AdapterError.pipelineFailed("filtered model contains images outside the selected order")
  }
  var copiedImages: [URL] = []
  copiedImages.reserveCapacity(orderedDatasetNames.count)
  for name in orderedDatasetNames {
    let source = paths.framesSelectedURL.appendingPathComponent(name)
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AdapterError.pipelineFailed("selected training image is not a regular file")
    }
    let destination = images.appendingPathComponent(name)
    try fileManager.copyItem(at: source, to: destination)
    copiedImages.append(destination)
  }
  try ColmapRunner().runModelConverter(
    colmapPath: toolchain(at: toolchainRoot).colmap,
    inputPath: filteredText,
    outputPath: sparse,
    outputType: "BIN",
    onLog: { _, _ in }
  )
  var overlay = try JSONSerialization.data(
    withJSONObject: [
      "schema_version": 1,
      "source_to_canonical_wxyz": try orientationQuaternion
        ?? canonicalOrientationQuaternion(from: paths.geometryManifestURL),
    ],
    options: [.sortedKeys]
  )
  overlay.append(0x0A)
  try overlay.write(
    to: sparse.appendingPathComponent("easysplat_orientation.json"),
    options: .atomic
  )
  let identity = try MsplatDatasetIdentity.compute(
    imageFiles: copiedImages,
    sparseDirectory: sparse
  )
  let split = try MeasurementTrainingSplit.make(
    selectedImageNames: selectedImageNames,
    holdoutViewIndices: holdoutIndices,
    imagesDirectory: images,
    datasetImageNames: orderedDatasetNames
  )
  let measuredTrainingImageDigest = try MeasurementDatasetImageIdentity.digest(
    imagesDirectory: images,
    orderedImageNames: orderedDatasetNames
  )
  guard split.trainingImageDigest == measuredTrainingImageDigest,
    Set(split.datasetImageNames).isDisjoint(with: holdoutNames)
  else {
    throw AdapterError.pipelineFailed("training split does not match the prepared dataset")
  }
  let splitManifest = root.appendingPathComponent("training-split.json")
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  try (encoder.encode(split) + Data("\n".utf8)).write(to: splitManifest, options: .atomic)
  return PreparedMeasurementDataset(
    url: dataset,
    identity: identity,
    split: split,
    filteredModel: filtered,
    sourceModelDigest: try MeasurementFileSetIdentity.digest(
      directory: textModel,
      orderedNames: ["cameras.txt", "images.txt", "points3D.txt"]
    ),
    filteredModelDigest: try MeasurementFileSetIdentity.digest(
      directory: filteredText,
      orderedNames: ["cameras.txt", "images.txt", "points3D.txt"]
    ),
    splitManifest: splitManifest
  )
}

func runMeasurementTraining(
  dataset: PreparedMeasurementDataset,
  output: URL,
  profile: DetailProfile,
  seed: UInt64,
  iterationLimit: Int,
  plateauWindow: Int,
  memoryBudgetBytes: Int64,
  toolchainRoot: URL
) async throws -> MsplatTrainingResult {
  #if BASELINE_ADAPTER
    return try await MsplatRunner().runTrain(
      msplatPath: toolchain(at: toolchainRoot).msplat,
      datasetPath: dataset.url,
      outputPath: output,
      profile: profile,
      seed: seed,
      iterationLimit: iterationLimit,
      plateauWindow: plateauWindow,
      onLog: { _, _ in }
    )
  #else
    return try await MsplatRunner().runTrain(
      msplatPath: toolchain(at: toolchainRoot).msplat,
      datasetPath: dataset.url,
      outputPath: output,
      expectedIdentity: dataset.identity,
      profile: profile,
      seed: seed,
      iterationLimit: iterationLimit,
      plateauWindow: plateauWindow,
      memoryBudgetBytes: memoryBudgetBytes,
      onLog: { _, _ in }
    )
  #endif
}

func writeMeasurementTrainingReceipt(
  result: MsplatTrainingResult,
  dataset: PreparedMeasurementDataset,
  output: URL,
  geometryManifest: URL,
  profile: DetailProfile,
  seed: UInt64,
  memoryBudgetBytes: Int64,
  to destination: URL
) throws -> String {
  let outputDigest = try GeometryArtifactStore.sha256(of: output)
  let geometryManifestDigest = try GeometryArtifactStore.sha256(of: geometryManifest)
  let outputBytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  var receipt: [String: Any] = [
    "schema_version": 1,
    "training_split_digest": dataset.split.closureDigest,
    "training_split_manifest_sha256": try GeometryArtifactStore.sha256(
      of: dataset.splitManifest
    ),
    "training_image_digest": dataset.split.trainingImageDigest,
    "dataset_input_digest": dataset.identity.inputDigest,
    "dataset_geometry_digest": dataset.identity.geometryDigest,
    "source_model_digest": dataset.sourceModelDigest,
    "filtered_model_digest": dataset.filteredModelDigest,
    "geometry_manifest_sha256": geometryManifestDigest,
    "output_sha256": outputDigest,
    "output_bytes": outputBytes,
    "profile": profile.rawValue,
    "seed": seed,
    "iteration_limit": result.iterationLimit,
    "plateau_window": result.plateauWindow,
    "completed_iteration": result.completedIteration,
    "gaussian_count": result.gaussianCount,
    "elapsed_seconds": result.elapsedSeconds,
    "input_digest": result.inputDigest,
    "geometry_digest": result.geometryDigest,
    "trainer_build_digest": result.trainerBuildDigest,
    "completion_status": "completed",
    "training_split_manifest": "training-split.json",
  ]
  #if BASELINE_ADAPTER
    receipt["peak_memory_bytes"] = result.peakMemoryBytes
    receipt["memory_budget_bytes"] = memoryBudgetBytes
    receipt["dropped_intersection_count"] = 0
  #else
    receipt["peak_memory_bytes"] = result.peakMemoryBytes
    receipt["memory_budget_bytes"] = result.memoryBudgetBytes
    receipt["raster_fallback_count"] = result.rasterFallbackCount
    receipt["raster_exact_fallback_elapsed_seconds"] =
      result.rasterExactFallbackElapsedSeconds
    receipt["raster_exact_buffer_growth_count"] = result.rasterExactBufferGrowthCount
    receipt["raster_exact_buffer_bytes_added"] = result.rasterExactBufferBytesAdded
    receipt["raster_replay_elapsed_seconds"] = result.rasterReplayElapsedSeconds
    receipt["raster_peak_exact_intersection_capacity"] =
      result.rasterPeakExactIntersectionCapacity
    receipt["dropped_intersection_count"] = result.droppedIntersectionCount
    receipt["scene_bounds"] = [
      "center": [
        "x": result.sceneBounds.center.x,
        "y": result.sceneBounds.center.y,
        "z": result.sceneBounds.center.z,
      ],
      "radius": result.sceneBounds.radius,
    ]
  #endif
  let data = try JSONSerialization.data(
    withJSONObject: receipt,
    options: [.sortedKeys, .withoutEscapingSlashes]
  )
  try (data + Data("\n".utf8)).write(to: destination, options: .atomic)
  return outputDigest
}

func writeJSON(_ value: [String: Any], to destination: URL) throws {
  let data = try JSONSerialization.data(
    withJSONObject: value,
    options: [.sortedKeys, .withoutEscapingSlashes]
  )
  try (data + Data("\n".utf8)).write(to: destination, options: .atomic)
}

func publishMeasurementPLY(_ source: URL, paths: ProjectPaths) throws -> URL {
  guard ProjectArtifactValidator.validatePlyFile(at: source) == .valid else {
    throw AdapterError.pipelineFailed("native trainer produced an invalid PLY")
  }
  let destination = paths.outputURL.appendingPathComponent("splat.ply")
  guard !FileManager.default.fileExists(atPath: destination.path) else {
    throw AdapterError.pipelineFailed("measurement output already exists")
  }
  try FileManager.default.copyItem(at: source, to: destination)
  guard ProjectArtifactValidator.validatePlyFile(at: destination) == .valid,
    try GeometryArtifactStore.sha256(of: destination)
      == GeometryArtifactStore.sha256(of: source)
  else {
    try? FileManager.default.removeItem(at: destination)
    throw AdapterError.pipelineFailed("published measurement PLY failed validation")
  }
  return destination
}

#if ACCURATE_REFERENCE
  func writeAccurateReferencePairList(imageNames: [String], to output: URL) throws {
    guard imageNames.count >= 2, imageNames.count <= 3_000,
      Set(imageNames).count == imageNames.count,
      imageNames.allSatisfy({ name in
        !name.isEmpty && name.utf8.count <= 4_096
          && name.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
          }
      })
    else {
      throw AdapterError.pipelineFailed("accurate reference needs 2...3,000 unique selected images")
    }

    let fileManager = FileManager.default
    let temporary = output.deletingLastPathComponent().appendingPathComponent(
      ".\(output.lastPathComponent).\(UUID().uuidString).tmp"
    )
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw AdapterError.pipelineFailed("could not create the accurate-reference pair list")
    }
    var moved = false
    defer {
      if !moved {
        try? fileManager.removeItem(at: temporary)
      }
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      var buffer = ""
      buffer.reserveCapacity(1_048_576)
      for left in imageNames.indices {
        for right in imageNames.index(after: left)..<imageNames.endIndex {
          buffer += "\(imageNames[left]) \(imageNames[right])\n"
          if buffer.utf8.count >= 1_048_576 {
            try handle.write(contentsOf: Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
          }
        }
      }
      if !buffer.isEmpty {
        try handle.write(contentsOf: Data(buffer.utf8))
      }
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    guard Darwin.rename(temporary.path, output.path) == 0 else {
      throw AdapterError.pipelineFailed("could not publish the accurate-reference pair list")
    }
    moved = true
  }

  func runAccurateReference(
    arguments: AdapterArguments,
    plan: ResolvedRunPlan,
    paths: ProjectPaths,
    freshPublicationAttestation: FreshProjectPublicationAttestation,
    holdoutIndices: [Int],
    candidateStartedMonotonicSeconds: TimeInterval,
    candidatePreparationStartedAt: Date
  ) async throws {
    let development = DevelopmentOverrides(
      candidateRoute: .colmap,
      stopAfterStage: .sfmFeatures,
      benchmarkSeed: Int(plan.runSeed)
    )
    let runner = PipelineRunner(
      projectURL: paths.root,
      config: .init(
        toolchain: toolchain(at: arguments.toolchainRoot),
        developmentOverrides: development,
        hardwareProfile: .detect(),
        resolvedRunPlan: plan,
        prePipelineDurationSeconds: ProcessInfo.processInfo.systemUptime
          - candidateStartedMonotonicSeconds,
        prePipelineStartedAt: candidatePreparationStartedAt
      )
    )
    try await runner.run(
      freshPublicationAttestation: freshPublicationAttestation
    ) { _ in }
    let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
    guard metadata.state.stage == .sfmFeatures else {
      throw AdapterError.pipelineFailed("accurate reference did not stop after feature extraction")
    }
    let selectedImages = try files(in: paths.framesSelectedURL, extensions: ["jpg", "jpeg", "png"])
      .map { URL(fileURLWithPath: $0).lastPathComponent }
    let referenceRoot = paths.colmapSparseURL.deletingLastPathComponent()
    let pairList = referenceRoot.appendingPathComponent("accurate-reference-pairs.txt")
    try writeAccurateReferencePairList(imageNames: selectedImages, to: pairList)

    let geometry = ColmapRunner()
    let matcherStarted = ProcessInfo.processInfo.systemUptime
    try await geometry.runMatchesImporter(
      colmapPath: toolchain(at: arguments.toolchainRoot).colmap,
      database: paths.colmapDatabaseURL,
      matchListPath: pairList,
      matchType: "pairs",
      randomSeed: plan.runSeed,
      options: ColmapOptions(
        useGPU: false,
        extractThreads: max(1, plan.geometryWorkerBudget.featureExtractionWorkers),
        matchThreads: max(1, plan.geometryWorkerBudget.coupledMatchingWorkers),
        maxNumFeatures: plan.colmapMaximumFeatureCount,
        maxNumMatches: plan.colmapMaximumMatchCount,
        descriptorMatcher: .exact
      ),
      onLog: { _, _ in }
    )
    let matcherEnded = ProcessInfo.processInfo.systemUptime

    let mapperRoot = referenceRoot.appendingPathComponent(
      "accurate-reference-map", isDirectory: true)
    try FileManager.default.createDirectory(at: mapperRoot, withIntermediateDirectories: true)
    let mapperArguments = [
      "mapper",
      "--database_path", paths.colmapDatabaseURL.path,
      "--image_path", paths.framesSelectedURL.path,
      "--output_path", mapperRoot.path,
    ]
    let mappingStarted = ProcessInfo.processInfo.systemUptime
    let mapperResult = try await SubprocessRunner().runAsync(
      toolchain(at: arguments.toolchainRoot).colmap.path,
      mapperArguments,
      currentDirectory: nil,
      environment: [:],
      onStdout: { _ in },
      onStderr: { _ in }
    )
    guard mapperResult.exitCode == 0,
      mapperResult.terminationReason == Process.TerminationReason.exit
    else {
      throw AdapterError.pipelineFailed("accurate reference mapper failed")
    }
    let modelDirectories = try FileManager.default.contentsOfDirectory(
      at: mapperRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      guard Int(url.lastPathComponent) != nil,
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else {
        return false
      }
      return values.isDirectory == true && values.isSymbolicLink != true
    }
    let memberships = try ColmapSparseModelMembershipReader(
      databaseURL: paths.colmapDatabaseURL,
      selectedImageNames: selectedImages
    ).read(modelDirectories: modelDirectories)
    let candidates = memberships.models.map {
      MeasurementSparseModelCandidate(
        order: $0.modelOrder,
        registeredViewCount: $0.imageIDs.count
      )
    }
    guard let selectedModel = MeasurementSparseModelSelector.select(candidates) else {
      throw AdapterError.pipelineFailed("accurate reference mapper produced no valid model")
    }
    let mappedModel = mapperRoot.appendingPathComponent(
      String(selectedModel.order),
      isDirectory: true
    )
    let adjustedModel = referenceRoot.appendingPathComponent(
      "accurate-reference-ba",
      isDirectory: true
    )
    try await geometry.runBundleAdjuster(
      colmapPath: toolchain(at: arguments.toolchainRoot).colmap,
      inputPath: mappedModel,
      outputPath: adjustedModel,
      environment: [:],
      bundleOptions: ColmapBundleAdjustmentOptions(
        maxNumIterations: 200,
        refineFocalLength: true,
        refinePrincipalPoint: false,
        refineExtraParams: true
      ),
      onLog: { _, _ in }
    )
    let mappingEnded = ProcessInfo.processInfo.systemUptime

    let textModel = referenceRoot.appendingPathComponent(
      "accurate-reference-text",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: textModel, withIntermediateDirectories: true)
    try geometry.runModelConverter(
      colmapPath: toolchain(at: arguments.toolchainRoot).colmap,
      inputPath: adjustedModel,
      outputPath: textModel,
      outputType: "TXT",
      onLog: { _, _ in }
    )
    let measured = try ColmapResidualAnalyzer.analyze(modelDirectory: textModel)
    let dataset = try prepareMeasurementDataset(
      paths: paths,
      textModel: textModel,
      selectedImageNames: selectedImages,
      holdoutIndices: holdoutIndices,
      toolchainRoot: arguments.toolchainRoot,
      label: "accurate-reference-dataset",
      orientationQuaternion: [1, 0, 0, 0]
    )
    let trainedPLY = paths.trainingURL.appendingPathComponent("accurate-reference/splat.ply")
    let trainingStarted = ProcessInfo.processInfo.systemUptime
    let training = try await runMeasurementTraining(
      dataset: dataset,
      output: trainedPLY,
      profile: .highDetail,
      seed: plan.runSeed,
      iterationLimit: 30_000,
      plateauWindow: 30_000,
      memoryBudgetBytes: plan.trainerMemoryBudgetBytes,
      toolchainRoot: arguments.toolchainRoot
    )
    guard training.iterationLimit == 30_000, training.completedIteration == 30_000 else {
      throw AdapterError.pipelineFailed(
        "accurate reference trainer stopped before 30,000 iterations")
    }
    let referenceGeometryManifest = referenceRoot.appendingPathComponent(
      "accurate-reference-geometry.json"
    )
    try writeJSON(
      [
        "schema_version": 1,
        "mapped_model_order": selectedModel.order,
        "ordered_image_names": selectedImages,
        "registered_views": measured.registeredViewCount,
        "point_count": measured.pointCount,
        "observation_count": measured.observationCount,
        "median_residual_pixels": measured.medianPixelResidual,
        "p90_residual_pixels": measured.p90PixelResidual,
        "source_model_digest": dataset.sourceModelDigest,
        "filtered_model_digest": dataset.filteredModelDigest,
      ],
      to: referenceGeometryManifest
    )
    let trainingReceipt = paths.trainingURL.appendingPathComponent(
      "accurate-reference-training.json"
    )
    let outputDigest = try writeMeasurementTrainingReceipt(
      result: training,
      dataset: dataset,
      output: trainedPLY,
      geometryManifest: referenceGeometryManifest,
      profile: .highDetail,
      seed: plan.runSeed,
      memoryBudgetBytes: plan.trainerMemoryBudgetBytes,
      to: trainingReceipt
    )
    let publishedPLY = try publishMeasurementPLY(trainedPLY, paths: paths)
    guard try GeometryArtifactStore.sha256(of: publishedPLY) == outputDigest else {
      throw AdapterError.pipelineFailed("published accurate-reference PLY digest changed")
    }
    let ended = ProcessInfo.processInfo.systemUptime
    let envelope: [String: Any] = [
      "schema_version": 1,
      "variant": "accurate_reference",
      "started_monotonic_seconds": candidateStartedMonotonicSeconds,
      "ended_monotonic_seconds": ended,
      "project_root": arguments.projectRoot.path,
      "output_ply": publishedPLY.path,
      "output_sha256": outputDigest,
      "geometry_manifest": referenceGeometryManifest.path,
      "training_manifest": trainingReceipt.path,
      "selection_manifest": paths.framesSelectedManifestURL.path,
      "training_split_manifest": dataset.splitManifest.path,
      "training_split_digest": dataset.split.closureDigest,
      "training_image_digest": dataset.split.trainingImageDigest,
      "dataset_input_digest": dataset.identity.inputDigest,
      "dataset_geometry_digest": dataset.identity.geometryDigest,
      "source_model_digest": dataset.sourceModelDigest,
      "filtered_model_digest": dataset.filteredModelDigest,
      "pipeline_log": paths.pipelineLogURL.path,
      "registered_views": measured.registeredViewCount,
      "point_count": measured.pointCount,
      "observation_count": measured.observationCount,
      "median_residual_pixels": measured.medianPixelResidual,
      "p90_residual_pixels": measured.p90PixelResidual,
      "mapper_argv": [toolchain(at: arguments.toolchainRoot).colmap.path] + mapperArguments,
      "mapped_model_order": selectedModel.order,
      "stage_seconds": [
        "reconstruct_matching": matcherEnded - matcherStarted,
        "reconstruct_mapping": mappingEnded - mappingStarted,
        "training": ended - trainingStarted,
        "end_to_end": ended - candidateStartedMonotonicSeconds,
      ],
    ]
    try writeJSON(envelope, to: arguments.output)
  }
#endif

#if !BASELINE_ADAPTER
  struct PublishedMeasurementProject {
    let paths: ProjectPaths
    let freshPublicationAttestation: FreshProjectPublicationAttestation
  }

  func publishCurrentMeasurementProject(
    input: InputSpec,
    options: RequestedRunOptions,
    plan: ResolvedRunPlan,
    projectRoot: URL
  ) async throws -> PublishedMeasurementProject {
    try Task.checkCancellation()
    let projectParent = projectRoot.deletingLastPathComponent()
    let expectedProjectRoot = ProjectPublicationTransaction.candidateURL(
      in: projectParent, title: "project", attempt: 0
    )
    guard projectRoot.standardizedFileURL == expectedProjectRoot.standardizedFileURL else {
      throw AdapterError.invalidArguments(
        "project-root must be the first protected project candidate"
      )
    }

    let reserve = VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
      keyframeBudget: plan.keyframeBudget,
      maximumImageDimension: plan.maximumImageDimension,
      maximumFeatureCount: plan.colmapMaximumFeatureCount,
      maximumMatchCount: plan.colmapMaximumMatchCount,
      retrievalCandidateCount: plan.retrievalCandidateCount
    )
    var preparedVideos: PreparedVideoInput?
    var preparedPhotos: PreparedPhotoInput?
    var emptyMixedPhotoInput = false
    defer { preparedVideos?.discard() }
    defer { preparedPhotos?.discard() }

    if let photosFolder = input.photosFolder {
      let reservedVideoFrames = RunPlanResolver.minimumReservedVideoFrameCount(
        keyframeBudget: plan.keyframeBudget,
        videoCount: input.videoFiles.count
      )
      let photoBudget = max(1, plan.keyframeBudget - reservedVideoFrames)
      do {
        preparedPhotos = try await PhotoInputPreflight.prepare(
          folder: URL(fileURLWithPath: photosFolder, isDirectory: true),
          stagingParent: projectParent,
          photoSelection: plan.photoSelection,
          inputOrdering: plan.inputOrdering,
          keyframeBudget: photoBudget,
          requiredAtomicWorkspaceReserveBytes: reserve,
          limits: .init(maximumDecodedDimension: min(4_096, plan.maximumImageDimension)),
          progress: { _, _ in }
        )
      } catch let failure as PhotoInputPreflightFailure
        where input.hasVideos && failure.issue == .noValidPhotos
      {
        emptyMixedPhotoInput = true
      }
      if let preparedPhotos {
        try RunPlanResolver.validatePhotoSelection(
          validPhotoCount: preparedPhotos.summary.validPhotoCount,
          resolvedPlan: plan,
          input: input
        )
      } else if emptyMixedPhotoInput {
        try RunPlanResolver.validatePhotoSelection(
          validPhotoCount: 0,
          resolvedPlan: plan,
          input: input
        )
      }
    }
    try Task.checkCancellation()
    if input.hasVideos {
      preparedVideos = try await VideoInputPreflight().prepare(
        videoURLs: input.videoFiles.map(URL.init(fileURLWithPath:)),
        stagingParent: projectParent,
        requiredAtomicWorkspaceReserveBytes: reserve,
        analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
        pairingPolicy: plan.pairingPolicy,
        progress: { _, _ in }
      )
    }
    try Task.checkCancellation()

    let projectID = UUID()
    let title = "project"
    let publication = try ProjectPublicationTransaction.begin(
      in: projectParent,
      title: title,
      projectID: projectID
    )
    var hiddenPublication: ProjectPublicationTransaction? = publication
    defer { try? hiddenPublication?.abort() }
    let stagedPaths = ProjectPaths(root: publication.bundleURL)
    var inputAdoption = ProjectInputAdoption(requestedInput: input)
    if let preparedVideos {
      try inputAdoption.adoptVideos(preparedVideos, into: stagedPaths)
      try publication.reached(.videoAdopted)
    }
    try Task.checkCancellation()
    if let preparedPhotos {
      try inputAdoption.adoptPhotos(preparedPhotos, into: stagedPaths)
      try publication.reached(.photosAdopted)
    } else if emptyMixedPhotoInput {
      try inputAdoption.adoptEmptyMixedPhotoFolder(into: stagedPaths)
      try publication.reached(.photosAdopted)
    }
    try Task.checkCancellation()
    try stagedPaths.ensureDirectories()
    defer { inputAdoption.videoInputIntegrityHandoff?.discard() }

    let metadata = ProjectMetadata(
      id: projectID,
      title: title,
      input: inputAdoption.input,
      videoInputReceipts: inputAdoption.videoInputReceipts,
      photoInputReceipts: inputAdoption.photoInputReceipts,
      photoSelectionReceipt: inputAdoption.photoSelectionReceipt,
      requestedRunOptions: options,
      resolvedRunPlan: plan,
      lastRunStartedAt: Date()
    )
    try ProjectMetadataStore.save(metadata, to: stagedPaths.metadataURL)
    try publication.validateAndSeal(expectedMetadata: metadata)
    try Task.checkCancellation()
    let freshPublication: FreshProjectPublication
    if inputAdoption.input.hasVideos {
      guard let videoInputIntegrityHandoff = inputAdoption.videoInputIntegrityHandoff else {
        throw VideoInputIntegrityHandoffError.unavailable
      }
      freshPublication = try publication.publishWithFreshAttestation(
        videoInputIntegrityHandoff: videoInputIntegrityHandoff
      )
    } else {
      freshPublication = try publication.publishWithFreshAttestationForProjectWithoutVideos()
    }
    var pendingFreshPublicationAttestation: FreshProjectPublicationAttestation? =
      freshPublication.attestation
    defer { pendingFreshPublicationAttestation?.discard() }
    hiddenPublication = nil
    guard freshPublication.projectURL.resolvingSymlinksInPath().standardizedFileURL
      == projectRoot.resolvingSymlinksInPath().standardizedFileURL
    else {
      throw AdapterError.pipelineFailed("published project path changed")
    }
    let publishedProject = PublishedMeasurementProject(
      paths: ProjectPaths(root: freshPublication.projectURL),
      freshPublicationAttestation: freshPublication.attestation
    )
    pendingFreshPublicationAttestation = nil
    return publishedProject
  }
#endif

#if CURRENT_ADAPTER
  final class MeasurementEvidenceFileBinding {
    private struct FileStatus: Equatable {
      let deviceID: UInt64
      let inode: UInt64
      let mode: UInt32
      let linkCount: UInt64
      let ownerUID: UInt32
      let ownerGID: UInt32
      let byteCount: Int64
      let modifiedSeconds: Int64
      let modifiedNanoseconds: Int64
      let changedSeconds: Int64
      let changedNanoseconds: Int64

      init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        mode = UInt32(status.st_mode)
        linkCount = UInt64(status.st_nlink)
        ownerUID = UInt32(status.st_uid)
        ownerGID = UInt32(status.st_gid)
        byteCount = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
      }
    }

    let sha256: String
    let byteCount: Int64

    private let url: URL
    private let descriptor: Int32
    private let initialStatus: FileStatus
    private let maximumBytes: off_t
    private let capturedData: Data

    init(url: URL, maximumBytes: off_t) throws {
      let boundURL = url.standardizedFileURL
      guard maximumBytes > 0,
        boundURL.isFileURL,
        boundURL.path.hasPrefix("/")
      else {
        throw AdapterError.pipelineFailed("measurement evidence path is invalid")
      }

      var pathStatus = stat()
      guard Self.retryingEINTR({ Darwin.lstat(boundURL.path, &pathStatus) }) == 0 else {
        throw AdapterError.pipelineFailed(
          "could not inspect measurement evidence \(boundURL.lastPathComponent)"
        )
      }
      let descriptor = try Self.open(boundURL)
      var retained = false
      defer {
        if !retained { Darwin.close(descriptor) }
      }
      var status = stat()
      guard Self.retryingEINTR({ Darwin.fstat(descriptor, &status) }) == 0 else {
        throw AdapterError.pipelineFailed(
          "could not inspect retained measurement evidence \(boundURL.lastPathComponent)"
        )
      }
      try Self.validate(status: status, maximumBytes: maximumBytes, name: boundURL.lastPathComponent)
      let capturedStatus = FileStatus(status)
      guard FileStatus(pathStatus) == capturedStatus else {
        throw AdapterError.pipelineFailed(
          "measurement evidence path changed while it was opened"
        )
      }
      let capturedData = try Self.readData(
        descriptor: descriptor,
        expectedByteCount: status.st_size,
        name: boundURL.lastPathComponent
      )
      let digest = SHA256.hash(data: capturedData)
        .map { String(format: "%02x", $0) }.joined()
      let finalDescriptorStatus = try Self.descriptorStatus(
        descriptor,
        name: boundURL.lastPathComponent
      )
      let finalPathStatus = try Self.pathStatus(boundURL)
      guard finalDescriptorStatus == capturedStatus,
        finalPathStatus == capturedStatus
      else {
        throw AdapterError.pipelineFailed(
          "measurement evidence changed while it was captured"
        )
      }

      self.url = boundURL
      self.descriptor = descriptor
      self.initialStatus = capturedStatus
      self.maximumBytes = maximumBytes
      self.capturedData = capturedData
      self.sha256 = digest
      self.byteCount = Int64(capturedData.count)
      retained = true
    }

    deinit {
      Darwin.close(descriptor)
    }

    func revalidate() throws {
      let descriptorStatus = try Self.descriptorStatus(
        descriptor,
        name: url.lastPathComponent
      )
      let pathStatus = try Self.pathStatus(url)
      guard descriptorStatus == initialStatus,
        pathStatus == initialStatus
      else {
        throw AdapterError.pipelineFailed(
          "measurement evidence changed during checkpoint verification"
        )
      }
      let digest = try Self.sha256(
        descriptor: descriptor,
        expectedByteCount: off_t(initialStatus.byteCount),
        name: url.lastPathComponent
      )
      let finalDescriptorStatus = try Self.descriptorStatus(
        descriptor,
        name: url.lastPathComponent
      )
      let finalPathStatus = try Self.pathStatus(url)
      guard digest == sha256,
        finalDescriptorStatus == initialStatus,
        finalPathStatus == initialStatus,
        initialStatus.byteCount <= Int64(maximumBytes)
      else {
        throw AdapterError.pipelineFailed(
          "measurement evidence bytes changed during checkpoint verification"
        )
      }
    }

    func dataSnapshot() throws -> Data {
      try revalidate()
      return capturedData
    }

    private static func validate(
      status: stat,
      maximumBytes: off_t,
      name: String
    ) throws {
      guard status.st_uid == geteuid(),
        status.st_nlink == 1,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_size > 0,
        status.st_size <= maximumBytes
      else {
        throw AdapterError.pipelineFailed(
          "measurement evidence \(name) is not a bounded current-user regular file"
        )
      }
    }

    private static func open(_ url: URL) throws -> Int32 {
      while true {
        let result = Darwin.open(
          url.path,
          O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if result >= 0 { return result }
        if errno == EINTR { continue }
        throw AdapterError.pipelineFailed(
          "could not retain measurement evidence \(url.lastPathComponent)"
        )
      }
    }

    private static func descriptorStatus(_ descriptor: Int32, name: String) throws -> FileStatus {
      var status = stat()
      guard retryingEINTR({ Darwin.fstat(descriptor, &status) }) == 0 else {
        throw AdapterError.pipelineFailed(
          "could not restat retained measurement evidence \(name)"
        )
      }
      return FileStatus(status)
    }

    private static func pathStatus(_ url: URL) throws -> FileStatus {
      var status = stat()
      guard retryingEINTR({ Darwin.lstat(url.path, &status) }) == 0 else {
        throw AdapterError.pipelineFailed(
          "could not restat measurement evidence \(url.lastPathComponent)"
        )
      }
      return FileStatus(status)
    }

    private static func sha256(
      descriptor: Int32,
      expectedByteCount: off_t,
      name: String
    ) throws -> String {
      var hasher = SHA256()
      var offset: off_t = 0
      var buffer = [UInt8](repeating: 0, count: 1_048_576)
      while offset < expectedByteCount {
        try Task.checkCancellation()
        let requested = min(buffer.count, Int(expectedByteCount - offset))
        let count: Int
        while true {
          let result = buffer.withUnsafeMutableBytes { bytes in
            Darwin.pread(descriptor, bytes.baseAddress, requested, offset)
          }
          if result >= 0 {
            count = result
            break
          }
          if errno != EINTR {
            throw AdapterError.pipelineFailed(
              "could not read retained measurement evidence \(name)"
            )
          }
        }
        guard count > 0 else {
          throw AdapterError.pipelineFailed(
            "measurement evidence \(name) ended before its recorded size"
          )
        }
        hasher.update(data: Data(buffer[0..<count]))
        offset += off_t(count)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readData(
      descriptor: Int32,
      expectedByteCount: off_t,
      name: String
    ) throws -> Data {
      var data = Data(count: Int(expectedByteCount))
      var offset = 0
      try data.withUnsafeMutableBytes { bytes in
        while offset < bytes.count {
          try Task.checkCancellation()
          let count: Int
          while true {
            let result = Darwin.pread(
              descriptor,
              bytes.baseAddress?.advanced(by: offset),
              bytes.count - offset,
              off_t(offset)
            )
            if result >= 0 {
              count = result
              break
            }
            if errno != EINTR {
              throw AdapterError.pipelineFailed(
                "could not read retained measurement evidence \(name)"
              )
            }
          }
          guard count > 0 else {
            throw AdapterError.pipelineFailed(
              "measurement evidence \(name) ended before its recorded size"
            )
          }
          offset += count
        }
      }
      return data
    }

    private static func retryingEINTR(_ operation: () -> Int32) -> Int32 {
      while true {
        let result = operation()
        if result >= 0 || errno != EINTR { return result }
      }
    }
  }

  struct AuthenticatedMapperCadenceTrial: Equatable {
    let ordinal: Int
    let name: String
    let mapperCadence: String
    let ratio: Double
    let discarded: Bool
  }

  final class AuthenticatedMapperCadenceDevelopmentRequest {
    let requestBinding: MeasurementEvidenceFileBinding
    let adapterBinding: MeasurementEvidenceFileBinding
    let colmapBinding: MeasurementEvidenceFileBinding
    let openMPBinding: MeasurementEvidenceFileBinding
    let candidateConfiguration: [String: Any]
    let fixedMapperOptions: [String: Any]
    let fixedMapperOptionsSHA256: String
    let cadenceScheduleSHA256: String
    let qualityThresholdsSHA256: String
    let experimentContractSHA256: String
    let runtimeClosure: ColmapRuntimeClosureEvidence
    let inputKind: String
    let scale: Int
    let deterministicSeed: Int
    let trials: [AuthenticatedMapperCadenceTrial]

    init(
      requestBinding: MeasurementEvidenceFileBinding,
      adapterBinding: MeasurementEvidenceFileBinding,
      colmapBinding: MeasurementEvidenceFileBinding,
      openMPBinding: MeasurementEvidenceFileBinding,
      candidateConfiguration: [String: Any],
      fixedMapperOptions: [String: Any],
      fixedMapperOptionsSHA256: String,
      cadenceScheduleSHA256: String,
      qualityThresholdsSHA256: String,
      experimentContractSHA256: String,
      runtimeClosure: ColmapRuntimeClosureEvidence,
      inputKind: String,
      scale: Int,
      deterministicSeed: Int,
      trials: [AuthenticatedMapperCadenceTrial]
    ) {
      self.requestBinding = requestBinding
      self.adapterBinding = adapterBinding
      self.colmapBinding = colmapBinding
      self.openMPBinding = openMPBinding
      self.candidateConfiguration = candidateConfiguration
      self.fixedMapperOptions = fixedMapperOptions
      self.fixedMapperOptionsSHA256 = fixedMapperOptionsSHA256
      self.cadenceScheduleSHA256 = cadenceScheduleSHA256
      self.qualityThresholdsSHA256 = qualityThresholdsSHA256
      self.experimentContractSHA256 = experimentContractSHA256
      self.runtimeClosure = runtimeClosure
      self.inputKind = inputKind
      self.scale = scale
      self.deterministicSeed = deterministicSeed
      self.trials = trials
    }

    func trial(named name: String) -> AuthenticatedMapperCadenceTrial? {
      trials.first { $0.name == name }
    }

    func revalidate() throws {
      try requestBinding.revalidate()
      try adapterBinding.revalidate()
      try colmapBinding.revalidate()
      try openMPBinding.revalidate()
    }
  }

  func requireExactKeys(
    _ value: [String: Any],
    _ expected: Set<String>,
    label: String
  ) throws {
    guard Set(value.keys) == expected else {
      throw AdapterError.invalidRequest("\(label) has missing or unknown fields")
    }
  }

  func boolean(_ value: Any?, _ label: String) throws -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
      throw AdapterError.invalidRequest("\(label) must be a boolean")
    }
    return number.boolValue
  }

  func finiteNumber(_ value: Any?, _ label: String) throws -> Double {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite
    else {
      throw AdapterError.invalidRequest("\(label) must be a finite number")
    }
    return number.doubleValue
  }

  func safeRelativePath(_ value: Any?, _ label: String) throws -> String {
    let result = try string(value, label)
    let components = result.split(separator: "/", omittingEmptySubsequences: false)
    guard !result.hasPrefix("/"),
      !result.contains("\\"),
      !result.contains("\0"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw AdapterError.invalidRequest("\(label) must be a safe relative path")
    }
    return result
  }

  func prefixedSHA256(_ value: Any?, _ label: String) throws -> String {
    let result = try string(value, label)
    let suffix = String(result.dropFirst("sha256:".count))
    guard result.hasPrefix("sha256:"),
      suffix.count == 64,
      suffix.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      })
    else {
      throw AdapterError.invalidRequest("\(label) must be a sha256:-prefixed digest")
    }
    return result
  }

  func developmentExecutionAssurance() -> [String: Any] {
    [
      "level": "observational",
      "mutation_threat_model": "no_concurrent_same_uid_mutation",
      "runner_isolation_mode": "owner_private_local_process",
      "child_database_binding": "pre_post_descriptor_path",
      "child_database_open_inode_verified": false,
      "child_runtime_binding": "pre_post_closure_path",
      "child_runtime_exec_inode_verified": false,
      "release_gate_eligible": false,
    ]
  }

  func executingAdapterURL() throws -> URL {
    guard let executable = CommandLine.arguments.first, !executable.isEmpty else {
      throw AdapterError.pipelineFailed("executing adapter path is unavailable")
    }
    let url: URL
    if executable.hasPrefix("/") {
      url = URL(fileURLWithPath: executable)
    } else {
      url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(executable)
    }
    let standardized = url.standardizedFileURL
    guard standardized.path.hasPrefix("/") else {
      throw AdapterError.pipelineFailed("executing adapter path is not absolute")
    }
    return standardized
  }

  func parseAuthenticatedTrial(
    _ value: Any?,
    expected: AuthenticatedMapperCadenceTrial,
    label: String
  ) throws -> AuthenticatedMapperCadenceTrial {
    let object = try mapping(value, label)
    try requireExactKeys(
      object,
      ["ordinal", "name", "mapper_cadence", "ratio", "discarded"],
      label: label
    )
    let trial = AuthenticatedMapperCadenceTrial(
      ordinal: try integer(object["ordinal"], "\(label).ordinal"),
      name: try string(object["name"], "\(label).name"),
      mapperCadence: try string(object["mapper_cadence"], "\(label).mapper_cadence"),
      ratio: try finiteNumber(object["ratio"], "\(label).ratio"),
      discarded: try boolean(object["discarded"], "\(label).discarded")
    )
    guard trial == expected else {
      throw AdapterError.invalidRequest("\(label) differs from the fixed cadence schedule")
    }
    return trial
  }

  func authenticateMapperCadenceDevelopmentRequest(
    arguments: AdapterArguments,
    requestBinding: MeasurementEvidenceFileBinding,
    request: [String: Any]
  ) throws -> AuthenticatedMapperCadenceDevelopmentRequest {
    try requireExactKeys(
      request,
      [
        "schema_version", "evidence_class", "request_kind", "binding", "category",
        "input_kind", "video_source_count", "holdout_indices",
        "candidate_run_configuration", "input_closure", "runtime_closure",
        "build_identity", "experiment",
      ],
      label: "mapper cadence request"
    )
    guard try integer(request["schema_version"], "schema_version") == 1,
      try string(request["evidence_class"], "evidence_class") == "development_only",
      try string(request["request_kind"], "request_kind") == "mapper_cadence_ab"
    else {
      throw AdapterError.invalidRequest(
        "partial mapper modes require the development-only cadence request"
      )
    }

    let binding = try mapping(request["binding"], "binding")
    try requireExactKeys(binding, ["scene_id", "scale"], label: "binding")
    let sceneID = try string(binding["scene_id"], "binding.scene_id")
    guard sceneID.range(of: "^[a-z0-9][a-z0-9_-]{0,127}$", options: .regularExpression)
      != nil
    else {
      throw AdapterError.invalidRequest("binding.scene_id is invalid")
    }
    let scale = try integer(binding["scale"], "binding.scale")
    guard [30, 120, 250, 500, 3_000].contains(scale) else {
      throw AdapterError.invalidRequest("binding.scale is unsupported")
    }
    let categories = Set([
      "object_orbit", "interior_walkthrough", "professional_photos",
      "large_area_exterior", "low_light", "invalid",
    ])
    guard categories.contains(try string(request["category"], "category")) else {
      throw AdapterError.invalidRequest("category is unsupported")
    }
    let inputKind = try string(request["input_kind"], "input_kind")
    let videoSourceCount = try integer(request["video_source_count"], "video_source_count")
    guard (inputKind == "video" && videoSourceCount == 1)
      || (inputKind == "multi_video" && videoSourceCount >= 2)
    else {
      throw AdapterError.invalidRequest("video_source_count does not match input_kind")
    }
    guard try integerArray(request["holdout_indices"], "holdout_indices").isEmpty else {
      throw AdapterError.invalidRequest("mapper cadence requests cannot contain holdouts")
    }

    let candidate = try mapping(
      request["candidate_run_configuration"],
      "candidate_run_configuration"
    )
    try requireExactKeys(
      candidate,
      [
        "detail_profile", "selected_frame_count", "capture_path", "input_topology",
        "camera_grouping", "lens_projection", "resource_policy", "compute_policy",
        "pairing_policy", "temporal_pairing", "temporal_offsets",
        "vocabulary_candidate_count", "vocabulary_returned_neighbor_count",
        "vocabulary_query_stride", "descriptor_matcher", "ba_global_frames_ratio",
        "ba_global_points_ratio", "ba_global_max_refinements",
        "ba_local_max_refinements", "ba_local_max_num_iterations",
        "ba_local_function_tolerance", "ba_global_function_tolerance",
        "ba_local_num_images", "trainer_iterations", "trainer_plateau_window",
        "feature_extraction_workers", "coupled_matching_workers",
        "vocabulary_retrieval_workers",
        "maximum_concurrent_video_source_analysis_tasks", "run_seed",
      ],
      label: "candidate_run_configuration"
    )
    guard try integer(candidate["selected_frame_count"], "selected_frame_count") == scale,
      try string(candidate["compute_policy"], "compute_policy")
        == "metal_for_supported_stages",
      try string(candidate["descriptor_matcher"], "descriptor_matcher") == "faiss",
      try integer(candidate["run_seed"], "run_seed") == 42
    else {
      throw AdapterError.invalidRequest("candidate configuration is not cadence-safe")
    }
    _ = try requestedOptions(candidate)
    guard let topology = MeasurementInputTopology(
      rawValue: try string(candidate["input_topology"], "input_topology")
    ),
      (inputKind == "video" && topology == .continuous)
        || (inputKind == "multi_video" && topology == .segmentedMixed)
    else {
      throw AdapterError.invalidRequest("input topology does not match input_kind")
    }
    guard let temporalOffsets = candidate["temporal_offsets"] as? [Any] else {
      throw AdapterError.invalidRequest("temporal_offsets must be an array")
    }
    let offsets = try temporalOffsets.enumerated().map {
      try integer($0.element, "temporal_offsets[\($0.offset)]")
    }
    guard offsets == offsets.sorted(), Set(offsets).count == offsets.count,
      offsets.allSatisfy({ (1...128).contains($0) })
    else {
      throw AdapterError.invalidRequest("temporal_offsets are invalid")
    }
    for field in ["vocabulary_candidate_count", "vocabulary_returned_neighbor_count"] {
      guard try integer(candidate[field], field) >= 0 else {
        throw AdapterError.invalidRequest("\(field) must be nonnegative")
      }
    }
    for field in [
      "vocabulary_query_stride", "ba_global_max_refinements",
      "ba_local_max_refinements", "ba_local_max_num_iterations", "ba_local_num_images",
      "trainer_iterations", "trainer_plateau_window", "feature_extraction_workers",
      "coupled_matching_workers", "vocabulary_retrieval_workers",
      "maximum_concurrent_video_source_analysis_tasks",
    ] {
      guard try integer(candidate[field], field) > 0 else {
        throw AdapterError.invalidRequest("\(field) must be positive")
      }
    }
    for field in [
      "ba_global_frames_ratio", "ba_global_points_ratio",
      "ba_local_function_tolerance", "ba_global_function_tolerance",
    ] {
      guard try finiteNumber(candidate[field], field) >= 0 else {
        throw AdapterError.invalidRequest("\(field) must be nonnegative")
      }
    }

    let inputClosure = try mapping(request["input_closure"], "input_closure")
    try requireExactKeys(
      inputClosure,
      [
        "digest_algorithm", "source_input_digest", "consumed_media_paths",
        "consumed_media_digest", "ignored_input_manifest",
        "ignored_input_manifest_sha256",
      ],
      label: "input_closure"
    )
    guard try string(inputClosure["digest_algorithm"], "digest_algorithm")
      == "easysplat-benchmark-input-v1",
      let consumedMedia = inputClosure["consumed_media_paths"] as? [Any],
      consumedMedia.count == videoSourceCount,
      let ignoredMedia = inputClosure["ignored_input_manifest"] as? [Any]
    else {
      throw AdapterError.invalidRequest("input closure shape is invalid")
    }
    _ = try prefixedSHA256(inputClosure["source_input_digest"], "source_input_digest")
    _ = try prefixedSHA256(inputClosure["consumed_media_digest"], "consumed_media_digest")
    _ = try requiredSHA256(inputClosure, "ignored_input_manifest_sha256")
    let consumedPaths = try consumedMedia.enumerated().map {
      try safeRelativePath($0.element, "consumed_media_paths[\($0.offset)]")
    }
    guard consumedPaths == consumedPaths.sorted(), Set(consumedPaths).count == consumedPaths.count
    else {
      throw AdapterError.invalidRequest("consumed media paths are not sorted and unique")
    }
    for (index, rawRecord) in ignoredMedia.enumerated() {
      let record = try mapping(rawRecord, "ignored_input_manifest[\(index)]")
      try requireExactKeys(
        record,
        ["relative_path", "bytes", "sha256"],
        label: "ignored_input_manifest[\(index)]"
      )
      _ = try safeRelativePath(record["relative_path"], "ignored relative path")
      guard try integer(record["bytes"], "ignored bytes") >= 0 else {
        throw AdapterError.invalidRequest("ignored media byte count is invalid")
      }
      _ = try prefixedSHA256(record["sha256"], "ignored media sha256")
    }

    let runtime = try mapping(request["runtime_closure"], "runtime_closure")
    try requireExactKeys(
      runtime,
      [
        "adapter_executable_name", "adapter_executable_bytes",
        "adapter_executable_sha256", "colmap_runtime_components",
        "colmap_runtime_closure_sha256", "toolchain_provenance_status",
      ],
      label: "runtime_closure"
    )
    guard try string(runtime["toolchain_provenance_status"], "toolchain provenance")
      == "local_adhoc_unsigned"
    else {
      throw AdapterError.invalidRequest("toolchain provenance is not development-only")
    }
    let adapterBinding = try MeasurementEvidenceFileBinding(
      url: executingAdapterURL(),
      maximumBytes: 512 * 1_024 * 1_024
    )
    guard try string(runtime["adapter_executable_name"], "adapter executable name")
      == executingAdapterURL().lastPathComponent,
      try integer(runtime["adapter_executable_bytes"], "adapter executable bytes")
        == Int(adapterBinding.byteCount),
      try requiredSHA256(runtime, "adapter_executable_sha256") == adapterBinding.sha256
    else {
      throw AdapterError.invalidRequest("executing adapter differs from the request")
    }
    let toolchainPaths = toolchain(at: arguments.toolchainRoot)
    let colmapBinding = try MeasurementEvidenceFileBinding(
      url: toolchainPaths.colmap,
      maximumBytes: 2 * 1_024 * 1_024 * 1_024
    )
    let openMPBinding = try MeasurementEvidenceFileBinding(
      url: arguments.toolchainRoot.appendingPathComponent("lib/libomp.dylib"),
      maximumBytes: 2 * 1_024 * 1_024 * 1_024
    )
    let liveRuntimeClosure = try ColmapRunner().captureRuntimeClosure(
      colmapPath: toolchainPaths.colmap
    )
    guard try requiredSHA256(runtime, "colmap_runtime_closure_sha256")
      == liveRuntimeClosure.closureSHA256,
      let componentValues = runtime["colmap_runtime_components"] as? [Any],
      componentValues.count == liveRuntimeClosure.components.count
    else {
      throw AdapterError.invalidRequest("COLMAP runtime closure differs from the request")
    }
    let runtimeBindings = [colmapBinding, openMPBinding]
    for (index, liveComponent) in liveRuntimeClosure.components.enumerated() {
      let component = try mapping(componentValues[index], "runtime component \(index)")
      try requireExactKeys(
        component,
        ["toolchain_relative_path", "sha256"],
        label: "runtime component \(index)"
      )
      guard try string(component["toolchain_relative_path"], "runtime component path")
        == liveComponent.toolchainRelativePath,
        try requiredSHA256(component, "sha256") == liveComponent.sha256,
        runtimeBindings[index].sha256 == liveComponent.sha256
      else {
        throw AdapterError.invalidRequest("COLMAP runtime component differs from the request")
      }
    }

    let build = try mapping(request["build_identity"], "build_identity")
    try requireExactKeys(
      build,
      [
        "source_provenance_scope", "source_git_commit", "source_tree_state",
        "xcode_version", "swift_version", "measurement_runner_closure_identity_sha256",
      ],
      label: "build_identity"
    )
    let commit = try string(build["source_git_commit"], "source_git_commit")
    guard try string(build["source_provenance_scope"], "source_provenance_scope")
      == "binary_only_dirty_worktree",
      try string(build["source_tree_state"], "source_tree_state") == "dirty",
      commit.count == 40,
      commit.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      })
    else {
      throw AdapterError.invalidRequest("build identity is not a dirty-worktree request")
    }
    _ = try string(build["xcode_version"], "xcode_version")
    _ = try string(build["swift_version"], "swift_version")
    if !(build["measurement_runner_closure_identity_sha256"] is NSNull) {
      _ = try requiredSHA256(build, "measurement_runner_closure_identity_sha256")
    }

    let experiment = try mapping(request["experiment"], "experiment")
    try requireExactKeys(
      experiment,
      [
        "deterministic_seed", "fixed_mapper_options", "fixed_mapper_options_sha256",
        "warmup", "measured_trials", "cadence_schedule_sha256",
        "quality_thresholds", "quality_thresholds_sha256",
        "experiment_contract_sha256",
      ],
      label: "experiment"
    )
    let deterministicSeed = try integer(
      experiment["deterministic_seed"],
      "experiment.deterministic_seed"
    )
    guard deterministicSeed == 42 else {
      throw AdapterError.invalidRequest("experiment seed must be 42")
    }
    let fixedMapperOptions = try mapping(
      experiment["fixed_mapper_options"],
      "fixed_mapper_options"
    )
    try requireExactKeys(
      fixedMapperOptions,
      [
        "local_max_refinements", "global_max_refinements",
        "global_max_num_iterations", "local_max_num_iterations",
        "local_function_tolerance", "global_function_tolerance", "local_image_count",
        "random_seed", "refine_focal_length", "minimum_pair_inlier_count",
      ],
      label: "fixed_mapper_options"
    )
    let fixedMapperOptionsSHA256 = try requiredSHA256(
      experiment,
      "fixed_mapper_options_sha256"
    )
    let expectedTrials = [
      AuthenticatedMapperCadenceTrial(
        ordinal: 0, name: "mapper-cadence-warmup-1p4",
        mapperCadence: "balanced-global", ratio: 1.4, discarded: true),
      AuthenticatedMapperCadenceTrial(
        ordinal: 1, name: "mapper-cadence-01-1p1",
        mapperCadence: "frequent-global", ratio: 1.1, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 2, name: "mapper-cadence-02-1p4",
        mapperCadence: "balanced-global", ratio: 1.4, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 3, name: "mapper-cadence-03-1p4",
        mapperCadence: "balanced-global", ratio: 1.4, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 4, name: "mapper-cadence-04-1p1",
        mapperCadence: "frequent-global", ratio: 1.1, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 5, name: "mapper-cadence-05-1p1",
        mapperCadence: "frequent-global", ratio: 1.1, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 6, name: "mapper-cadence-06-1p4",
        mapperCadence: "balanced-global", ratio: 1.4, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 7, name: "mapper-cadence-07-1p4",
        mapperCadence: "balanced-global", ratio: 1.4, discarded: false),
      AuthenticatedMapperCadenceTrial(
        ordinal: 8, name: "mapper-cadence-08-1p1",
        mapperCadence: "frequent-global", ratio: 1.1, discarded: false),
    ]
    var trials = [try parseAuthenticatedTrial(
      experiment["warmup"],
      expected: expectedTrials[0],
      label: "experiment.warmup"
    )]
    guard let measuredTrials = experiment["measured_trials"] as? [Any],
      measuredTrials.count == 8
    else {
      throw AdapterError.invalidRequest("measured cadence schedule is invalid")
    }
    for index in measuredTrials.indices {
      trials.append(try parseAuthenticatedTrial(
        measuredTrials[index],
        expected: expectedTrials[index + 1],
        label: "experiment.measured_trials[\(index)]"
      ))
    }
    let cadenceScheduleSHA256 = try requiredSHA256(
      experiment,
      "cadence_schedule_sha256"
    )
    guard cadenceScheduleSHA256
      == "dbaca0655def6198950dbaa1cb31acf8b9f4b8a1fda090120682a073378046fb"
    else {
      throw AdapterError.invalidRequest("cadence schedule digest is invalid")
    }
    let qualityThresholds = try mapping(
      experiment["quality_thresholds"],
      "quality_thresholds"
    )
    let expectedQualityThresholds: [String: Double] = [
      "maximum_within_arm_mapping_elapsed_range_seconds": 30.0,
      "maximum_registered_view_loss": 2,
      "maximum_registered_view_loss_fraction": 0.01,
      "maximum_point_count_loss_fraction": 0.01,
      "maximum_observation_count_loss_fraction": 0.01,
      "maximum_median_residual_regression_pixels": 0.05,
      "maximum_p90_residual_regression_pixels": 0.10,
      "maximum_median_residual_pixels": 1.5,
      "maximum_p90_residual_pixels": 3.0,
      "maximum_camera_center_p95_scene_radius_fraction": 0.01,
      "maximum_rotation_p95_degrees": 0.20,
    ]
    try requireExactKeys(
      qualityThresholds,
      Set(expectedQualityThresholds.keys),
      label: "quality_thresholds"
    )
    for (field, expected) in expectedQualityThresholds {
      guard try finiteNumber(qualityThresholds[field], "quality_thresholds.\(field)")
        == expected
      else {
        throw AdapterError.invalidRequest("quality threshold \(field) is invalid")
      }
    }
    let qualityThresholdsSHA256 = try requiredSHA256(
      experiment,
      "quality_thresholds_sha256"
    )
    guard qualityThresholdsSHA256
      == "12e5e642381b5ced787f83471462dc8e9166b000d3f7f70be34bcdbc37f26ebc"
    else {
      throw AdapterError.invalidRequest("quality thresholds digest is invalid")
    }
    let experimentContractSHA256 = try requiredSHA256(
      experiment,
      "experiment_contract_sha256"
    )
    let contractJSON = "{\"cadence_schedule_sha256\":\"\(cadenceScheduleSHA256)\","
      + "\"deterministic_seed\":\(deterministicSeed),"
      + "\"fixed_mapper_options_sha256\":\"\(fixedMapperOptionsSHA256)\","
      + "\"quality_thresholds_sha256\":\"\(qualityThresholdsSHA256)\"}"
    let measuredContractSHA256 = SHA256.hash(data: Data(contractJSON.utf8))
      .map { String(format: "%02x", $0) }.joined()
    guard experimentContractSHA256 == measuredContractSHA256 else {
      throw AdapterError.invalidRequest("experiment contract digest is invalid")
    }

    return AuthenticatedMapperCadenceDevelopmentRequest(
      requestBinding: requestBinding,
      adapterBinding: adapterBinding,
      colmapBinding: colmapBinding,
      openMPBinding: openMPBinding,
      candidateConfiguration: candidate,
      fixedMapperOptions: fixedMapperOptions,
      fixedMapperOptionsSHA256: fixedMapperOptionsSHA256,
      cadenceScheduleSHA256: cadenceScheduleSHA256,
      qualityThresholdsSHA256: qualityThresholdsSHA256,
      experimentContractSHA256: experimentContractSHA256,
      runtimeClosure: liveRuntimeClosure,
      inputKind: inputKind,
      scale: scale,
      deterministicSeed: deterministicSeed,
      trials: trials
    )
  }

  func mapperFixedOptionsJSONObject(
    _ options: MeasurementMapperFixedOptions,
    minimumPairInlierCount: Int
  ) -> [String: Any] {
    [
      "local_max_refinements": options.localMaxRefinements,
      "global_max_refinements": options.globalMaxRefinements,
      "global_max_num_iterations": options.globalMaxNumIterations,
      "local_max_num_iterations": options.localMaxNumIterations,
      "local_function_tolerance": options.localFunctionTolerance,
      "global_function_tolerance": options.globalFunctionTolerance,
      "local_image_count": options.localImageCount,
      "random_seed": Int(options.randomSeed),
      "refine_focal_length": options.refineFocalLength,
      "minimum_pair_inlier_count": minimumPairInlierCount,
    ]
  }

  func validateMapperCadenceResolvedPlan(
    _ authenticatedRequest: AuthenticatedMapperCadenceDevelopmentRequest,
    resolvedPlan: ResolvedRunPlan,
    expectedRequestedOptions: RequestedRunOptions
  ) throws -> MeasurementMapperFixedOptions {
    let configuration = authenticatedRequest.candidateConfiguration
    let configuredOptions = try requestedOptions(configuration)
    let pairingPolicy: ResolvedPairingPolicy
    switch try string(configuration["pairing_policy"], "pairing_policy") {
    case "generic_continuous": pairingPolicy = .orderedContinuous
    case "object_orbit": pairingPolicy = .orderedOrbit
    case "walkthrough": pairingPolicy = .orderedWalkthrough
    case "large_area": pairingPolicy = .orderedLargeArea
    case "segmented_mixed": pairingPolicy = .segmentedMixed
    case "unordered_retrieval": pairingPolicy = .unorderedRetrieval
    default: throw AdapterError.invalidRequest("pairing_policy is unsupported")
    }
    guard let temporalPairing = TemporalPairing(
      rawValue: try string(configuration["temporal_pairing"], "temporal_pairing")
    ),
      let rawOffsets = configuration["temporal_offsets"] as? [Any]
    else {
      throw AdapterError.invalidRequest("temporal pairing is invalid")
    }
    let offsets = try rawOffsets.enumerated().map {
      try integer($0.element, "temporal_offsets[\($0.offset)]")
    }
    let budget = resolvedPlan.geometryWorkerBudget
    let suppressesShortGenericRetrieval = authenticatedRequest.scale < 120
      && resolvedPlan.pairingPolicy == .orderedContinuous
    let effectiveCandidateCount = suppressesShortGenericRetrieval
      ? 0 : resolvedPlan.retrievalCandidateCount
    let effectiveNeighborCount = suppressesShortGenericRetrieval
      ? 0 : resolvedPlan.retrievalNeighborCount
    let requestedCandidateCount = try integer(
      configuration["vocabulary_candidate_count"],
      "candidate count"
    )
    let requestedNeighborCount = try integer(
      configuration["vocabulary_returned_neighbor_count"],
      "returned neighbor count"
    )
    let requestedQueryStride = try integer(
      configuration["vocabulary_query_stride"],
      "query stride"
    )
    let requestedFramesRatio = try finiteNumber(
      configuration["ba_global_frames_ratio"],
      "frames ratio"
    )
    let requestedPointsRatio = try finiteNumber(
      configuration["ba_global_points_ratio"],
      "points ratio"
    )
    let requestedGlobalRefinements = try integer(
      configuration["ba_global_max_refinements"],
      "global refinements"
    )
    let requestedLocalRefinements = try integer(
      configuration["ba_local_max_refinements"],
      "local refinements"
    )
    let requestedLocalIterations = try integer(
      configuration["ba_local_max_num_iterations"],
      "local iterations"
    )
    let requestedLocalTolerance = try finiteNumber(
      configuration["ba_local_function_tolerance"],
      "local tolerance"
    )
    let requestedGlobalTolerance = try finiteNumber(
      configuration["ba_global_function_tolerance"],
      "global tolerance"
    )
    let requestedLocalImageCount = try integer(
      configuration["ba_local_num_images"],
      "local image count"
    )
    let requestedTrainerIterations = try integer(
      configuration["trainer_iterations"],
      "trainer iterations"
    )
    let requestedPlateauWindow = try integer(
      configuration["trainer_plateau_window"],
      "plateau window"
    )
    let requestedFeatureWorkers = try integer(
      configuration["feature_extraction_workers"],
      "feature workers"
    )
    let requestedMatchingWorkers = try integer(
      configuration["coupled_matching_workers"],
      "matching workers"
    )
    let requestedRetrievalWorkers = try integer(
      configuration["vocabulary_retrieval_workers"],
      "retrieval workers"
    )
    let requestedVideoAnalysisWorkers = try integer(
      configuration["maximum_concurrent_video_source_analysis_tasks"],
      "video analysis workers"
    )
    guard configuredOptions == expectedRequestedOptions,
      resolvedPlan.keyframeBudget == authenticatedRequest.scale,
      resolvedPlan.capturePath == expectedRequestedOptions.capturePath,
      resolvedPlan.lensProjection == expectedRequestedOptions.lensProjection,
      resolvedPlan.pairingPolicy == pairingPolicy,
      resolvedPlan.temporalPairing == temporalPairing,
      resolvedPlan.temporalOffsets == offsets,
      effectiveCandidateCount == requestedCandidateCount,
      effectiveNeighborCount == requestedNeighborCount,
      resolvedPlan.retrievalQueryStride == requestedQueryStride,
      resolvedPlan.normalDescriptorMatcher == .faiss,
      resolvedPlan.baGlobalFramesRatio == requestedFramesRatio,
      resolvedPlan.baGlobalPointsRatio == requestedPointsRatio,
      resolvedPlan.baGlobalMaxRefinements == requestedGlobalRefinements,
      resolvedPlan.baLocalMaxRefinements == requestedLocalRefinements,
      resolvedPlan.baLocalMaxNumIterations == requestedLocalIterations,
      resolvedPlan.baLocalFunctionTolerance == requestedLocalTolerance,
      resolvedPlan.baGlobalFunctionTolerance == requestedGlobalTolerance,
      resolvedPlan.baLocalImageCount == requestedLocalImageCount,
      resolvedPlan.trainerIterationLimit == requestedTrainerIterations,
      resolvedPlan.plateauWindow == requestedPlateauWindow,
      budget.featureExtractionWorkers == requestedFeatureWorkers,
      budget.coupledMatchingWorkers == requestedMatchingWorkers,
      budget.vocabularyRetrievalWorkers == requestedRetrievalWorkers,
      budget.maximumConcurrentVideoSourceAnalysisTasks == requestedVideoAnalysisWorkers,
      Int(resolvedPlan.runSeed) == authenticatedRequest.deterministicSeed
    else {
      throw AdapterError.invalidRequest(
        "resolved run plan differs from the authenticated cadence configuration"
      )
    }

    let fixedOptions = try MeasurementMapperFixedOptions(
      localMaxRefinements: resolvedPlan.baLocalMaxRefinements,
      globalMaxRefinements: resolvedPlan.baGlobalMaxRefinements,
      globalMaxNumIterations: resolvedPlan.refinementIterationLimit,
      localMaxNumIterations: resolvedPlan.baLocalMaxNumIterations,
      localFunctionTolerance: resolvedPlan.baLocalFunctionTolerance,
      globalFunctionTolerance: resolvedPlan.baGlobalFunctionTolerance,
      localImageCount: resolvedPlan.baLocalImageCount,
      randomSeed: resolvedPlan.runSeed,
      refineFocalLength: true
    )
    let minimumPairInlierCount = ColmapMappingPolicy.minimumPairInlierCount
    let fixedJSONObject = mapperFixedOptionsJSONObject(
      fixedOptions,
      minimumPairInlierCount: minimumPairInlierCount
    )
    let fixedSHA256 = try fixedOptions.bindingSHA256(
      minimumPairInlierCount: minimumPairInlierCount
    )
    guard try canonicalJSONSHA256(
      fixedJSONObject,
      label: "resolved fixed mapper options"
    ) == canonicalJSONSHA256(
      authenticatedRequest.fixedMapperOptions,
      label: "requested fixed mapper options"
    ),
      fixedSHA256 == authenticatedRequest.fixedMapperOptionsSHA256
    else {
      throw AdapterError.invalidRequest(
        "fixed mapper options differ from the authenticated cadence experiment"
      )
    }
    return fixedOptions
  }

  final class MeasurementBoundedMapperLog: @unchecked Sendable {
    private static let maximumBytes = 64 * 1_024 * 1_024
    private let lock = NSLock()
    private var bytes = Data()
    private var exceededLimit = false

    func append(_ chunk: String) {
      let chunkBytes = Data(chunk.utf8)
      lock.lock()
      defer { lock.unlock() }
      guard !exceededLimit else { return }
      let separatorCount = chunk.hasSuffix("\n") ? 0 : 1
      guard bytes.count <= Self.maximumBytes - chunkBytes.count - separatorCount else {
        exceededLimit = true
        bytes.removeAll(keepingCapacity: false)
        return
      }
      bytes.append(chunkBytes)
      if separatorCount == 1 { bytes.append(0x0A) }
    }

    func snapshot() throws -> Data {
      lock.lock()
      defer { lock.unlock() }
      guard !exceededLimit, !bytes.isEmpty else {
        throw AdapterError.pipelineFailed(
          exceededLimit ? "mapper log exceeded 64 MiB" : "mapper emitted no diagnostic log"
        )
      }
      return bytes
    }
  }

  func encodedJSONObject<T: Encodable>(_ value: T, label: String) throws -> Any {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    guard JSONSerialization.isValidJSONObject(object) else {
      throw AdapterError.pipelineFailed("\(label) could not be represented as JSON")
    }
    return object
  }

  func canonicalJSONSHA256(_ value: Any, label: String) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw AdapterError.pipelineFailed("\(label) is not a valid JSON value")
    }
    let data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func encodedSHA256<T: Encodable>(_ value: T, label: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard !data.isEmpty else {
      throw AdapterError.pipelineFailed("\(label) encoded to no bytes")
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func requiredSHA256(_ object: [String: Any], _ key: String) throws -> String {
    let digest = try string(object[key], key)
    guard digest.count == 64,
      digest.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      })
    else {
      throw AdapterError.invalidRequest("\(key) must be a lowercase SHA-256 digest")
    }
    return digest
  }

  func requiredStringArray(
    _ object: [String: Any],
    _ key: String,
    maximumCount: Int = 3_000
  ) throws -> [String] {
    guard let values = object[key] as? [Any],
      !values.isEmpty,
      values.count <= maximumCount
    else {
      throw AdapterError.invalidRequest("\(key) must be a nonempty bounded array")
    }
    let result = try values.enumerated().map { index, value in
      try string(value, "\(key)[\(index)]")
    }
    guard Set(result).count == result.count else {
      throw AdapterError.invalidRequest("\(key) contains duplicate values")
    }
    return result
  }

  func requireExactDirectoryTree(
    root: URL,
    expectedDirectories: Set<String>,
    expectedFiles: Set<String> = [],
    label: String
  ) throws {
    let standardizedRoot = root.standardizedFileURL
    guard root.isFileURL,
      root.path == standardizedRoot.path,
      root.path.hasPrefix("/")
    else {
      throw AdapterError.pipelineFailed("\(label) root is not a normalized absolute path")
    }
    let expectedEntries = expectedDirectories.union(expectedFiles)
    guard expectedDirectories.isDisjoint(with: expectedFiles),
      expectedEntries.allSatisfy({ relativePath in
      !relativePath.isEmpty
        && !relativePath.hasPrefix("/")
        && !relativePath.contains("\\")
        && relativePath.split(separator: "/", omittingEmptySubsequences: false)
          .allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty })
    }) else {
      throw AdapterError.pipelineFailed("\(label) expected tree is invalid")
    }

    var rootStatus = stat()
    guard Darwin.lstat(standardizedRoot.path, &rootStatus) == 0,
      (rootStatus.st_mode & S_IFMT) == S_IFDIR
    else {
      throw AdapterError.pipelineFailed("\(label) root is not a plain directory")
    }

    var observedDirectories = Set<String>()
    var observedFiles = Set<String>()
    var pending: [(relativePath: String, url: URL)] = [("", standardizedRoot)]
    while let current = pending.popLast() {
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: current.url.path)
          .sorted()
      } catch {
        throw AdapterError.pipelineFailed("\(label) tree could not be enumerated")
      }
      for name in names {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
          throw AdapterError.pipelineFailed("\(label) contains an invalid entry")
        }
        let relativePath = current.relativePath.isEmpty
          ? name : "\(current.relativePath)/\(name)"
        let childURL = current.url.appendingPathComponent(name, isDirectory: false)
        var childStatus = stat()
        guard Darwin.lstat(childURL.path, &childStatus) == 0 else {
          throw AdapterError.pipelineFailed(
            "\(label) contains an entry that could not be inspected"
          )
        }
        switch childStatus.st_mode & S_IFMT {
        case S_IFDIR where expectedDirectories.contains(relativePath):
          observedDirectories.insert(relativePath)
          pending.append((relativePath, childURL))
        case S_IFREG where expectedFiles.contains(relativePath):
          observedFiles.insert(relativePath)
        default:
          throw AdapterError.pipelineFailed(
            "\(label) contains an unexpected entry type or path"
          )
        }
      }
    }
    guard observedDirectories == expectedDirectories,
      observedFiles == expectedFiles
    else {
      throw AdapterError.pipelineFailed("\(label) expected closure is incomplete")
    }
  }

  func requireAbsentOrExactDirectoryTree(
    root: URL,
    expectedDirectories: Set<String>,
    label: String
  ) throws {
    var status = stat()
    errno = 0
    if Darwin.lstat(root.path, &status) == 0 {
      try requireExactDirectoryTree(
        root: root,
        expectedDirectories: expectedDirectories,
        label: label
      )
      return
    }
    guard errno == ENOENT else {
      throw AdapterError.pipelineFailed("\(label) state could not be inspected")
    }
  }

  func requireCleanMatchingArtifactClosure(
    paths: ProjectPaths,
    pairEvidence: PairGraphEvidence,
    workerExecution: GeometryWorkerExecutionArtifact,
    resolvedPlan: ResolvedRunPlan,
    groups: [ColmapPairGroup]
  ) throws -> [MeasurementEvidenceFileBinding] {
    let seedSidecars = try PairGraphEvidenceStore.matchingSeedSidecarContents(
      evidence: pairEvidence,
      workerExecution: workerExecution,
      resolvedPlan: resolvedPlan,
      groups: groups
    )
    try requireExactDirectoryTree(
      root: paths.colmapSparseURL,
      expectedDirectories: [],
      label: "COLMAP sparse output"
    )
    try requireExactDirectoryTree(
      root: paths.colmapSeedURL,
      expectedDirectories: [],
      expectedFiles: Set(seedSidecars.keys),
      label: "COLMAP seed output"
    )
    try requireExactDirectoryTree(
      root: paths.outputURL,
      expectedDirectories: [],
      label: "public output"
    )
    try requireAbsentOrExactDirectoryTree(
      root: paths.trainingURL,
      expectedDirectories: [
        "checkpoints",
        "checkpoints/msplat",
        "msplat",
        "msplat_dataset",
        "msplat_dataset/images",
        "msplat_dataset/sparse",
        "msplat_dataset/sparse/0",
      ],
      label: "training output"
    )

    var geometryManifestStatus = stat()
    errno = 0
    guard Darwin.lstat(paths.geometryManifestURL.path, &geometryManifestStatus) != 0,
      errno == ENOENT
    else {
      throw AdapterError.pipelineFailed("matching checkpoint contains geometry evidence")
    }

    var sidecarBindings = [MeasurementEvidenceFileBinding]()
    for name in seedSidecars.keys.sorted() {
      guard let expectedData = seedSidecars[name] else {
        throw AdapterError.pipelineFailed("matching seed sidecar closure is inconsistent")
      }
      let binding = try MeasurementEvidenceFileBinding(
        url: paths.colmapSeedURL.appendingPathComponent(name),
        maximumBytes: 64 * 1_024 * 1_024
      )
      guard try binding.dataSnapshot() == expectedData else {
        throw AdapterError.pipelineFailed(
          "matching seed sidecar \(name) differs from durable evidence"
        )
      }
      sidecarBindings.append(binding)
    }
    return sidecarBindings
  }

  func requirePrivateTrialDirectory(_ url: URL) throws -> URL {
    let standardized = url.standardizedFileURL
    guard url.isFileURL,
      url.path == standardized.path,
      url.path.hasPrefix("/"),
      !url.path.contains("/../"),
      !url.path.hasSuffix("/..")
    else {
      throw AdapterError.invalidArguments("trial-root must be a normalized absolute path")
    }
    var status = stat()
    guard Darwin.lstat(standardized.path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == geteuid(),
      (status.st_mode & 0o7777) == 0o700
    else {
      throw AdapterError.invalidArguments(
        "trial-root must be an owner-private 0700 directory"
      )
    }
    guard try FileManager.default.contentsOfDirectory(atPath: standardized.path).isEmpty else {
      throw AdapterError.invalidArguments("trial-root must be empty")
    }
    return standardized
  }

  func requireUnusedDirectChild(
    _ child: URL,
    of parent: URL,
    named expectedName: String,
    label: String
  ) throws {
    let standardized = child.standardizedFileURL
    guard child.isFileURL,
      child.path == standardized.path,
      standardized.deletingLastPathComponent() == parent,
      standardized.lastPathComponent == expectedName
    else {
      throw AdapterError.invalidArguments(
        "\(label) must be the reserved direct child \(expectedName)"
      )
    }
    var status = stat()
    errno = 0
    guard Darwin.lstat(standardized.path, &status) != 0, errno == ENOENT else {
      throw AdapterError.invalidArguments("\(label) must not already exist")
    }
  }

  func createPrivateTrialDirectory(
    parent: URL,
    name: String
  ) throws -> URL {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw AdapterError.pipelineFailed("internal trial directory name is invalid")
    }
    let destination = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: destination,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    var status = stat()
    guard Darwin.lstat(destination.path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == geteuid(),
      (status.st_mode & 0o7777) == 0o700
    else {
      throw AdapterError.pipelineFailed("trial directory is not owner-private")
    }
    return destination
  }

  func writePrivateTrialFile(_ data: Data, to destination: URL) throws {
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    let descriptor = Darwin.open(destination.path, flags, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw AdapterError.pipelineFailed(
        "could not create \(destination.lastPathComponent)"
      )
    }
    var succeeded = false
    defer {
      Darwin.close(descriptor)
      if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw AdapterError.pipelineFailed(
            "could not write \(destination.lastPathComponent)"
          )
        }
        offset += count
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw AdapterError.pipelineFailed(
        "could not sync \(destination.lastPathComponent)"
      )
    }
    succeeded = true
  }

  func mappingCadenceTrial(
    trialRoot: URL,
    schedule: MeasurementMapperCadenceSchedule,
    requestedCadence: String
  ) throws -> MeasurementMapperCadenceTrial {
    let trial: MeasurementMapperCadenceTrial
    if trialRoot.lastPathComponent == MeasurementMapperCadenceTrial.warmup.name {
      trial = .warmup
    } else if let scheduled = schedule.trials.first(where: {
      $0.name == trialRoot.lastPathComponent
    }) {
      trial = scheduled
    } else {
      throw AdapterError.invalidArguments(
        "trial-root does not identify a fixed mapper-cadence trial"
      )
    }
    let expectedCadence = trial.ratio == 1.1 ? "frequent-global" : "balanced-global"
    guard requestedCadence == expectedCadence else {
      throw AdapterError.invalidArguments(
        "mapper-cadence does not match the trial-root schedule"
      )
    }
    return trial
  }

  func rejectedVocabularyRetrievalHistory(
    _ workerExecution: GeometryWorkerExecutionArtifact,
    resolvedPlan: ResolvedRunPlan,
    selectedImageNames: [String],
    groups: [ColmapPairGroup],
    acceptedPairAttemptNumber: Int
  ) throws -> [[String: Any]] {
    try GeometryWorkerExecutionArtifact.validateRejectedVocabularyRetrievalHistory(
      workerExecution.rejectedVocabularyRetrievalInvocations,
      expectedWorkerCount:
        resolvedPlan.geometryWorkerBudget.vocabularyRetrievalWorkers,
      acceptedInvocations: workerExecution.vocabularyRetrievalInvocations
    )
    return try workerExecution.rejectedVocabularyRetrievalInvocations.map { rejected in
      guard let pairExecution = rejected.invocation.pairExecution else {
        throw AdapterError.pipelineFailed(
          "rejected vocabulary retrieval is missing its pair-attempt binding"
        )
      }
      let noRankedNeighborQueryCount = rejected.retrieval.queryOutcomes.reduce(into: 0) {
        count, outcome in
        if outcome.status == .noRankedNeighbors { count += 1 }
      }
      guard rejected.pairingPolicy == resolvedPlan.pairingPolicy,
        rejected.planBinding == PairGraphPlanBinding(resolvedPlan),
        rejected.imageNames == selectedImageNames,
        rejected.groups == groups,
        pairExecution.attemptOrdinal > 0,
        pairExecution.attemptOrdinal <= acceptedPairAttemptNumber,
        pairExecution.retrievalRequestDigest
          == PairGraphEvidenceStore.retrievalRequestDigest(rejected.retrieval),
        pairExecution.retrievalOutputDigest == rejected.retrieval.outputDigest,
        rejected.retrieval.queryOutcomes.count
          == rejected.retrieval.queryImageNames.count,
        let retrievalRequestDigest = pairExecution.retrievalRequestDigest,
        let retrievalOutputDigest = pairExecution.retrievalOutputDigest
      else {
        throw AdapterError.pipelineFailed(
          "rejected vocabulary retrieval is not bound to the accepted run"
        )
      }
      return [
        "retrieval_attempt_ordinal": rejected.retrievalAttemptOrdinal,
        "pair_attempt_ordinal": pairExecution.attemptOrdinal,
        "pairing_policy": rejected.pairingPolicy.rawValue,
        "recovery_level": rejected.recoveryLevel.rawValue,
        "selected_view_count": rejected.imageNames.count,
        "query_count": rejected.retrieval.queryImageNames.count,
        "no_ranked_neighbor_query_count": noRankedNeighborQueryCount,
        "candidate_count": rejected.retrieval.candidateCount,
        "returned_neighbor_count": rejected.retrieval.returnedNeighborCount,
        "retrieval_request_digest": retrievalRequestDigest,
        "retrieval_output_digest": retrievalOutputDigest,
      ]
    }
  }

  func verifiedMatchingRecovery(
    metadata: ProjectMetadata,
    resolvedPlan: ResolvedRunPlan,
    pairEvidence: PairGraphEvidence,
    selectedImageNames: [String]
  ) throws -> GeometryRecoveryState {
    guard metadata.formatVersion == ProjectMetadataStore.supportedFormatVersion,
      metadata.lastRunStartedAt == nil,
      metadata.resolvedRunPlan == resolvedPlan,
      let recovery = metadata.geometryRecovery,
      recovery.activeBackend == .colmap,
      recovery.mappingAttemptCount == 0,
      recovery.pendingPairRecoveryLevel == nil,
      recovery.colmapComputeMode != nil,
      recovery.activeIncrementalCadence == resolvedPlan.incrementalMappingCadence,
      recovery.cadenceFallbackTrigger == nil,
      recovery.mappingFallbackReasons == pairEvidence.fallbackReasons
    else {
      throw AdapterError.pipelineFailed(
        "matching checkpoint recovery state is not a clean COLMAP handoff"
      )
    }
    try recovery.validate()
    try recovery.validateBinding(
      expectedImageNames: selectedImageNames,
      expectedSelectedFramesDigest: pairEvidence.selectedFramesDigest,
      expectedPlannedIncrementalCadence: resolvedPlan.incrementalMappingCadence
    )
    try recovery.validatePairGraphBinding(
      acceptedPairAttemptOrdinal: pairEvidence.acceptedAttemptNumber,
      pairListDigest: pairEvidence.pairListDigest,
      matchingDatabaseDigest: pairEvidence.acceptedInspection.matchingDatabaseDigest
    )
    return recovery
  }

  func validateDecisionRecoverySemantics(
    decision: [String: Any],
    recovery: GeometryRecoveryState,
    pairEvidence: PairGraphEvidence,
    workerExecution: GeometryWorkerExecutionArtifact,
    resolvedPlan: ResolvedRunPlan,
    selectedImageNames: [String],
    groups: [ColmapPairGroup]
  ) throws {
    guard let computeMode = recovery.colmapComputeMode,
      let acceptedAttempt = pairEvidence.attempts.last,
      try string(decision["colmap_compute_mode"], "colmap_compute_mode")
        == computeMode.rawValue,
      decision["fallback_reasons"] as? [String] == pairEvidence.fallbackReasons,
      try string(decision["recovery_level"], "recovery_level")
        == acceptedAttempt.artifact.recoveryLevel.rawValue
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint recovery semantics differ from durable evidence"
      )
    }
    let expectedExactReason = acceptedAttempt.artifact.exactRecoveryReason?.rawValue
    let recordedExactReason: String?
    if decision["exact_recovery_reason"] is NSNull {
      recordedExactReason = nil
    } else {
      recordedExactReason = try string(
        decision["exact_recovery_reason"],
        "exact_recovery_reason"
      )
    }
    let history = try rejectedVocabularyRetrievalHistory(
      workerExecution,
      resolvedPlan: resolvedPlan,
      selectedImageNames: selectedImageNames,
      groups: groups,
      acceptedPairAttemptNumber: pairEvidence.acceptedAttemptNumber
    )
    guard recordedExactReason == expectedExactReason,
      try integer(
        decision["rejected_vocabulary_retrieval_count"],
        "rejected_vocabulary_retrieval_count"
      ) == history.count,
      let recordedHistory = decision["rejected_vocabulary_retrieval_history"],
      try canonicalJSONSHA256(
        recordedHistory,
        label: "recorded rejected vocabulary retrieval history"
      ) == canonicalJSONSHA256(
        history,
        label: "rejected vocabulary retrieval history"
      )
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint recovery history differs from worker evidence"
      )
    }
  }

  func runMappingCadenceTrial(
    arguments: AdapterArguments
  ) async throws {
    guard let checkpointURL = arguments.mappingFromCheckpoint,
      let requestedCadence = arguments.mapperCadence,
      let requestedTrialRoot = arguments.trialRoot
    else {
      throw AdapterError.invalidArguments("mapping checkpoint arguments are incomplete")
    }

    let trialRoot = try requirePrivateTrialDirectory(requestedTrialRoot)
    try requireUnusedDirectChild(
      arguments.projectRoot,
      of: trialRoot,
      named: "project.easysplatproj",
      label: "project-root"
    )
    try requireUnusedDirectChild(
      arguments.output,
      of: trialRoot,
      named: "trial-envelope.json",
      label: "output"
    )

    let requestBinding = try MeasurementEvidenceFileBinding(
      url: arguments.request,
      maximumBytes: 16 * 1_024 * 1_024
    )
    let request = try mapping(
      JSONSerialization.jsonObject(with: try requestBinding.dataSnapshot()),
      "mapper cadence request"
    )
    let authenticatedRequest = try authenticateMapperCadenceDevelopmentRequest(
      arguments: arguments,
      requestBinding: requestBinding,
      request: request
    )
    let decisionBinding = try MeasurementEvidenceFileBinding(
      url: checkpointURL,
      maximumBytes: 16 * 1_024 * 1_024
    )
    let decision = try mapping(
      JSONSerialization.jsonObject(with: try decisionBinding.dataSnapshot()),
      "matching checkpoint"
    )
    guard try integer(decision["schema_version"], "schema_version") == 3,
      try string(decision["measurement_scope"], "measurement_scope") == "matching_only",
      try string(decision["variant"], "variant") == arguments.variant,
      try requiredSHA256(decision, "request_sha256") == requestBinding.sha256
    else {
      throw AdapterError.invalidRequest(
        "mapping checkpoint is not a matching-only decision for this request"
      )
    }
    guard try canonicalJSONSHA256(
      decision["execution_assurance"] ?? NSNull(),
      label: "recorded execution assurance"
    ) == canonicalJSONSHA256(
      developmentExecutionAssurance(),
      label: "expected execution assurance"
    ) else {
      throw AdapterError.invalidRequest(
        "mapping checkpoint execution assurance is missing or invalid"
      )
    }

    let decisionRootPath = try string(decision["project_root"], "project_root")
    let decisionRoot = URL(fileURLWithPath: decisionRootPath, isDirectory: true)
    guard decisionRootPath == decisionRoot.standardizedFileURL.path,
      decisionRootPath.hasPrefix("/")
    else {
      throw AdapterError.invalidRequest("matching checkpoint project_root is not normalized")
    }
    let decisionPaths = ProjectPaths(root: decisionRoot)
    let metadataBinding = try MeasurementEvidenceFileBinding(
      url: decisionPaths.metadataURL,
      maximumBytes: 8 * 1_024 * 1_024
    )
    let metadata = try ProjectMetadataStore.decodeValidatedMetadataSnapshot(
      try metadataBinding.dataSnapshot(),
      metadataURL: decisionPaths.metadataURL
    )
    guard metadata.formatVersion == ProjectMetadataStore.supportedFormatVersion,
      metadata.state.stage == .sfmMatching,
      metadata.state.lastError == nil,
      metadata.lastRunStartedAt == nil,
      metadata.checkpoint == nil,
      let resolvedPlan = metadata.resolvedRunPlan
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint project is not a current durable matching boundary"
      )
    }
    try resolvedPlan.validate()
    let resolvedPlanSHA256 = try encodedSHA256(
      resolvedPlan,
      label: "resolved run plan"
    )
    guard try requiredSHA256(decision, "resolved_plan_binding_sha256")
      == resolvedPlanSHA256,
      try integer(decision["deterministic_seed"], "deterministic_seed")
        == Int(resolvedPlan.runSeed),
      resolvedPlan.baGlobalMaxRefinements == 5
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint run plan differs from its authenticated binding"
      )
    }
    let checkpointToolchain = toolchain(at: arguments.toolchainRoot)
    let checkpointPipeline = PipelineRunner(
      projectURL: decisionRoot,
      config: .init(
        toolchain: checkpointToolchain,
        resolvedRunPlan: resolvedPlan
      )
    )

    let fixedOptions = try validateMapperCadenceResolvedPlan(
      authenticatedRequest,
      resolvedPlan: resolvedPlan,
      expectedRequestedOptions: metadata.requestedRunOptions
    )
    let schedule = MeasurementMapperCadenceSchedule(fixedOptions: fixedOptions)
    let trial = try mappingCadenceTrial(
      trialRoot: trialRoot,
      schedule: schedule,
      requestedCadence: requestedCadence
    )
    guard let authenticatedTrial = authenticatedRequest.trial(
      named: trialRoot.lastPathComponent
    ),
      authenticatedTrial.ordinal == trial.ordinal,
      authenticatedTrial.mapperCadence == requestedCadence,
      authenticatedTrial.ratio == trial.ratio,
      authenticatedTrial.discarded == (trial.ordinal == 0)
    else {
      throw AdapterError.invalidRequest(
        "requested mapper trial differs from the authenticated experiment schedule"
      )
    }
    let mapperOptions = try schedule.mapperOptions(for: trial)
    let minimumPairInlierCount = ColmapMappingPolicy.minimumPairInlierCount
    let fixedMapperOptions = mapperFixedOptionsJSONObject(
      fixedOptions,
      minimumPairInlierCount: minimumPairInlierCount
    )
    let fixedMapperOptionsSHA256 = try fixedOptions.bindingSHA256(
      minimumPairInlierCount: minimumPairInlierCount
    )

    let databaseRelativePath = try string(
      decision["database_project_relative_path"],
      "database_project_relative_path"
    )
    let databasePath = try string(decision["database_path"], "database_path")
    let expectedDatabaseRelativePath = try decisionPaths.projectRelativePath(
      for: decisionPaths.colmapDatabaseURL
    )
    let expectedDatabasePath = try projectSpelledPath(
      paths: decisionPaths,
      artifact: decisionPaths.colmapDatabaseURL
    )
    guard databaseRelativePath == expectedDatabaseRelativePath,
      databasePath == expectedDatabasePath
    else {
      throw AdapterError.invalidRequest("matching checkpoint database path is not canonical")
    }

    func boundArtifact(
      field: String,
      expectedURL: URL,
      expectedRelativePath: String,
      expectedSHAField: String,
      maximumBytes: off_t
    ) throws -> MeasurementEvidenceFileBinding {
      guard try string(decision[field], field) == expectedRelativePath else {
        throw AdapterError.invalidRequest("\(field) is not the reserved project artifact")
      }
      let resolved = try decisionPaths.resolveProjectRelativePath(expectedRelativePath)
      guard resolved.standardizedFileURL == expectedURL.standardizedFileURL else {
        throw AdapterError.invalidRequest("\(field) escapes its reserved location")
      }
      let binding = try MeasurementEvidenceFileBinding(
        url: resolved,
        maximumBytes: maximumBytes
      )
      let expectedSHA256 = try requiredSHA256(decision, expectedSHAField)
      guard binding.sha256 == expectedSHA256 else {
        throw AdapterError.invalidRequest("\(field) digest differs from the checkpoint")
      }
      return binding
    }

    let selectionRelative = try decisionPaths.projectRelativePath(
      for: decisionPaths.framesSelectedManifestURL)
    let pairRelative = try decisionPaths.projectRelativePath(
      for: decisionPaths.pairGraphEvidenceURL)
    let workerURL = GeometryWorkerExecutionArtifactStore.canonicalURL(for: decisionPaths)
    let workerRelative = try decisionPaths.projectRelativePath(for: workerURL)
    let selectionBinding = try boundArtifact(
      field: "selection_manifest",
      expectedURL: decisionPaths.framesSelectedManifestURL,
      expectedRelativePath: selectionRelative,
      expectedSHAField: "selection_manifest_sha256",
      maximumBytes: 4 * 1_024 * 1_024
    )
    let pairBinding = try boundArtifact(
      field: "pair_graph_evidence",
      expectedURL: decisionPaths.pairGraphEvidenceURL,
      expectedRelativePath: pairRelative,
      expectedSHAField: "pair_graph_evidence_sha256",
      maximumBytes: off_t(PairGraphEvidenceStore.maximumBytes)
    )
    let workerBinding = try boundArtifact(
      field: "worker_execution",
      expectedURL: workerURL,
      expectedRelativePath: workerRelative,
      expectedSHAField: "worker_execution_sha256",
      maximumBytes: off_t(GeometryWorkerExecutionArtifactStore.maximumBytes)
    )

    let selectedManifest = try checkpointPipeline.loadSelectedFrameManifest(
      data: selectionBinding.dataSnapshot()
    )
    let selectedImages = try files(
      in: decisionPaths.framesSelectedURL,
      extensions: PhotoInputPreflight.supportedExtensions
    ).map { URL(fileURLWithPath: $0) }
    let selectedImageNames = selectedImages.map(\.lastPathComponent)
    let decisionImageNames = try requiredStringArray(decision, "selected_image_names")
    let selectedImageCount = try integer(
      decision["selected_image_count"],
      "selected_image_count"
    )
    guard selectedImageNames == selectedManifest.map(\.outputFileName),
      selectedImageNames == decisionImageNames,
      selectedImageNames.count == selectedImageCount
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint selected image order is not reproducible"
      )
    }

    let cameraEvidence = try PipelineRunner.colmapCameraGroupingEvidence(
      imageNames: selectedImageNames,
      manifest: selectedManifest
    )
    let expectedCameraInitialization = try ColmapCameraInitializationReceipt.resolve(
      plan: resolvedPlan,
      detailProfile: metadata.requestedRunOptions.detailProfile,
      selectedImages: selectedImages
    )
    let featureEvidence = try ColmapFeatureEvidenceStore.loadVerified(
      from: decisionPaths.colmapFeatureEvidenceURL,
      expectedImageNames: selectedImageNames,
      expectedCameraEvidence: cameraEvidence,
      expectedCameraGroupingMode: PipelineRunner.colmapCameraGroupingMode(
        cameraGrouping: resolvedPlan.cameraGrouping,
        evidence: cameraEvidence
      ),
      expectedCameraInitializationReceipt: expectedCameraInitialization,
      databaseURL: decisionPaths.colmapDatabaseURL,
      projectPaths: decisionPaths
    )
    let pairEvidence = try PairGraphEvidenceStore.loadVerified(
      data: pairBinding.dataSnapshot(),
      expectedImageNames: selectedImageNames,
      databaseURL: decisionPaths.colmapDatabaseURL,
      projectPaths: decisionPaths
    )
    let groups = try PipelineRunner.colmapPairGroups(
      imageNames: selectedImageNames,
      manifest: selectedManifest
    )
    try PairGraphEvidenceStore.validateSchedule(
      pairEvidence,
      resolvedPlan: resolvedPlan,
      groups: groups
    )
    let workerExecution = try GeometryWorkerExecutionArtifactStore.load(
      data: workerBinding.dataSnapshot(),
      expectedBudget: resolvedPlan.geometryWorkerBudget
    )
    guard workerExecution.mappingAndRefinementInvocations.isEmpty,
      workerExecution.matchingInvocations.last?.succeeded == true
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint worker evidence already contains mapping work"
      )
    }
    try PairGraphEvidenceStore.validateWorkerExecution(
      pairEvidence,
      workerExecution: workerExecution
    )
    let recovery = try verifiedMatchingRecovery(
      metadata: metadata,
      resolvedPlan: resolvedPlan,
      pairEvidence: pairEvidence,
      selectedImageNames: selectedImageNames
    )
    try validateDecisionRecoverySemantics(
      decision: decision,
      recovery: recovery,
      pairEvidence: pairEvidence,
      workerExecution: workerExecution,
      resolvedPlan: resolvedPlan,
      selectedImageNames: selectedImageNames,
      groups: groups
    )
    let seedSidecarBindings = try requireCleanMatchingArtifactClosure(
      paths: decisionPaths,
      pairEvidence: pairEvidence,
      workerExecution: workerExecution,
      resolvedPlan: resolvedPlan,
      groups: groups
    )
    let colmapPath = checkpointToolchain.colmap
    let runtimeClosure = try ColmapRunner().captureRuntimeClosure(colmapPath: colmapPath)
    let expectedRuntimeClosureSHA256 = try requiredSHA256(
      decision,
      "colmap_runtime_closure_sha256"
    )
    guard runtimeClosure == authenticatedRequest.runtimeClosure,
      runtimeClosure == workerExecution.colmapRuntimeClosure,
      runtimeClosure.closureSHA256 == expectedRuntimeClosureSHA256
    else {
      throw AdapterError.invalidRequest(
        "live COLMAP runtime differs from the matching checkpoint"
      )
    }

    let sourceLogicalDigests = try ColmapDatabaseDigester.digests(
      at: decisionPaths.colmapDatabaseURL
    )
    let pairMeasurement = try pairEvidence.pairGraphMeasurement()
    let expectedFeatureDatabaseDigest = try requiredSHA256(
      decision,
      "feature_database_digest"
    )
    let expectedMatchingDatabaseDigest = try requiredSHA256(
      decision,
      "matching_database_digest"
    )
    let expectedSelectedFramesDigest = try requiredSHA256(
      decision,
      "selected_frames_digest"
    )
    let expectedPairListDigest = try requiredSHA256(decision, "pair_list_digest")
    guard sourceLogicalDigests.feature == featureEvidence.featureDatabaseDigest,
      sourceLogicalDigests.feature == pairMeasurement.featureDatabaseDigest,
      sourceLogicalDigests.feature == expectedFeatureDatabaseDigest,
      sourceLogicalDigests.matching == pairMeasurement.matchingDatabaseDigest,
      sourceLogicalDigests.matching == expectedMatchingDatabaseDigest,
      pairEvidence.selectedFramesDigest == expectedSelectedFramesDigest,
      pairEvidence.pairListDigest == expectedPairListDigest
    else {
      throw AdapterError.invalidRequest(
        "matching checkpoint logical evidence differs from its database"
      )
    }

    let frozenDatabase = try MeasurementFrozenCOLMAPDatabase(
      sourceParent: decisionPaths.colmapDatabaseURL.deletingLastPathComponent(),
      sourceName: decisionPaths.colmapDatabaseURL.lastPathComponent,
      destinationParent: trialRoot
    )
    let sourceInitialEvidence = frozenDatabase.sourceEvidence
    let expectedDatabaseFileSHA256 = try requiredSHA256(
      decision,
      "database_file_sha256"
    )
    let expectedDatabaseFileBytes = try integer(
      decision["database_file_bytes"],
      "database_file_bytes"
    )
    let expectedDatabaseSourceDeviceID = try integer(
      decision["database_source_device_id"],
      "database_source_device_id"
    )
    let expectedDatabaseSourceInode = try integer(
      decision["database_source_inode"],
      "database_source_inode"
    )
    let expectedDatabaseSourceMode = try integer(
      decision["database_source_mode"],
      "database_source_mode"
    )
    guard sourceInitialEvidence.sha256 == expectedDatabaseFileSHA256,
      sourceInitialEvidence.byteCount == expectedDatabaseFileBytes,
      sourceInitialEvidence.deviceID == UInt64(expectedDatabaseSourceDeviceID),
      sourceInitialEvidence.inode == UInt64(expectedDatabaseSourceInode),
      sourceInitialEvidence.mode == UInt32(S_IFREG | S_IRUSR),
      sourceInitialEvidence.mode == UInt32(expectedDatabaseSourceMode),
      sourceInitialEvidence.ownerUID == UInt32(geteuid()),
      sourceInitialEvidence.companionNames.isEmpty
    else {
      throw AdapterError.invalidRequest(
        "matching database bytes or identity differ from the checkpoint"
      )
    }

    let lease = try frozenDatabase.makeTrialCloneLease(
      for: trial,
      destinationName: sourceInitialEvidence.sourceName
    )
    let cloneEvidence = try lease.revalidatePreRunUnchanged()
    guard cloneEvidence.strategy == .apfsClone,
      sourceInitialEvidence.parentDeviceID == cloneEvidence.destinationParentDeviceID,
      sourceInitialEvidence.deviceID == cloneEvidence.destinationDeviceID,
      cloneEvidence.destinationParentDeviceID == cloneEvidence.destinationDeviceID
    else {
      throw AdapterError.pipelineFailed(
        "mapper cadence evidence requires a same-filesystem APFS clone"
      )
    }
    let cloneLogicalBefore = try ColmapDatabaseDigester.digests(at: lease.databaseURL)
    guard cloneLogicalBefore == sourceLogicalDigests else {
      throw AdapterError.pipelineFailed(
        "trial database clone differs logically from the matching checkpoint"
      )
    }
    let clonePairEvidence = try PairGraphEvidenceStore.loadVerified(
      data: pairBinding.dataSnapshot(),
      expectedImageNames: selectedImageNames,
      databaseURL: lease.databaseURL,
      projectPaths: decisionPaths
    )
    guard clonePairEvidence == pairEvidence else {
      throw AdapterError.pipelineFailed(
        "trial database clone does not reproduce the accepted pair graph"
      )
    }

    let mapperOutput = try createPrivateTrialDirectory(
      parent: trialRoot,
      name: "mapper-sparse"
    )
    let mapperLog = MeasurementBoundedMapperLog()
    let memorySampler = GeometryMemorySampler()
    memorySampler.start()
    defer { memorySampler.cancel() }
    let mappingStarted = ProcessInfo.processInfo.systemUptime
    try await ColmapRunner().runMapper(
      colmapPath: colmapPath,
      database: lease.databaseURL,
      imagePath: decisionPaths.framesSelectedURL,
      outputPath: mapperOutput,
      environment: [:],
      mapperOptions: mapperOptions,
      mapperContext: pairEvidence.mapperWorkerInvocationContext(),
      emitSolverReports: true,
      onLog: { line, _ in mapperLog.append(line) }
    )
    let mappingEnded = ProcessInfo.processInfo.systemUptime
    guard mappingEnded > mappingStarted,
      let peakMemoryBytes = memorySampler.stop(),
      peakMemoryBytes > 0
    else {
      throw AdapterError.pipelineFailed("mapper timing or memory evidence is unavailable")
    }
    guard try ColmapRunner().captureRuntimeClosure(colmapPath: colmapPath) == runtimeClosure
    else {
      throw AdapterError.pipelineFailed("COLMAP runtime changed during mapping")
    }
    try ColmapDatabaseDurability.seal(at: lease.databaseURL)

    let mapperLogData = try mapperLog.snapshot()
    let mapperLogURL = trialRoot.appendingPathComponent("mapper.log")
    try writePrivateTrialFile(mapperLogData, to: mapperLogURL)
    let mapperLogSHA256 = SHA256.hash(data: mapperLogData)
      .map { String(format: "%02x", $0) }.joined()

    let modelDirectories = try FileManager.default.contentsOfDirectory(
      at: mapperOutput,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url -> (URL, Int)? in
      guard let order = Int(url.lastPathComponent), order >= 0,
        let values = try? url.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        url.deletingLastPathComponent().standardizedFileURL
          == mapperOutput.standardizedFileURL
      else {
        return nil
      }
      return (url, order)
    }
    let memberships = try ColmapSparseModelMembershipReader(
      databaseURL: lease.databaseURL,
      selectedImageNames: selectedImageNames
    ).read(modelDirectories: modelDirectories.map(\.0))
    let candidates = memberships.models.map {
      MeasurementSparseModelCandidate(
        order: $0.modelOrder,
        registeredViewCount: $0.imageIDs.count
      )
    }
    guard let selectedCandidate = MeasurementSparseModelSelector.select(candidates),
      let selectedBinaryModel = modelDirectories.first(where: {
        $0.1 == selectedCandidate.order
      })?.0
    else {
      throw AdapterError.pipelineFailed("mapper produced no valid sparse model")
    }
    let textModel = try createPrivateTrialDirectory(
      parent: trialRoot,
      name: "mapper-text-model"
    )
    try ColmapRunner().runModelConverter(
      colmapPath: colmapPath,
      inputPath: selectedBinaryModel,
      outputPath: textModel,
      outputType: "TXT",
      onLog: { _, _ in }
    )
    guard try ColmapRunner().captureRuntimeClosure(colmapPath: colmapPath) == runtimeClosure
    else {
      throw AdapterError.pipelineFailed("COLMAP runtime changed during model conversion")
    }

    let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
      modelDirectory: textModel,
      checkCancellation: { try Task.checkCancellation() }
    )
    let residuals = analysis.residuals
    let registeredImageNames = residuals.registeredImageNames.sorted()
    guard registeredImageNames.count == residuals.registeredViewCount,
      Set(registeredImageNames).isSubset(of: Set(selectedImageNames))
    else {
      throw AdapterError.pipelineFailed(
        "measured registered views do not belong to the matching checkpoint"
      )
    }
    let cameraSamples = residuals.cameraSamples.sorted { $0.imageName < $1.imageName }
    guard cameraSamples.map(\.imageName) == registeredImageNames else {
      throw AdapterError.pipelineFailed(
        "measured camera poses do not bind every registered image name"
      )
    }
    let cameraPoses: [[Double]] = try cameraSamples.map { sample in
      let quaternion = sample.rotationWorldToCamera.canonicalQuaternion()
      let pose = [
        quaternion.w,
        quaternion.x,
        quaternion.y,
        quaternion.z,
        sample.translation.x,
        sample.translation.y,
        sample.translation.z,
      ]
      guard pose.allSatisfy(\.isFinite) else {
        throw AdapterError.pipelineFailed("measured camera pose is non-finite")
      }
      return pose
    }
    let conditioningObject = try encodedJSONObject(
      analysis.measurement,
      label: "conditioning measurement"
    )
    let modelHashes = analysis.modelSnapshot.modelHashes
    guard Set(modelHashes.keys) == ["cameras.txt", "images.txt", "points3D.txt"] else {
      throw AdapterError.pipelineFailed("measured text model closure is incomplete")
    }
    let modelSHA256 = try canonicalJSONSHA256(modelHashes, label: "model closure")

    let cloneLogicalAfter = try ColmapDatabaseDigester.digests(at: lease.databaseURL)
    guard cloneLogicalAfter == sourceLogicalDigests else {
      throw AdapterError.pipelineFailed(
        "mapper changed the trial database's logical matching closure"
      )
    }
    let clonePostEvidence = try lease.finalizePostRun()
    let sourceFinalEvidence = try frozenDatabase.finalizeSourceRehash()
    guard sourceFinalEvidence == sourceInitialEvidence,
      try ColmapDatabaseDigester.digests(at: decisionPaths.colmapDatabaseURL)
        == sourceLogicalDigests
    else {
      throw AdapterError.pipelineFailed("matching database changed during mapping")
    }
    try authenticatedRequest.revalidate()
    try decisionBinding.revalidate()
    try metadataBinding.revalidate()
    try selectionBinding.revalidate()
    try pairBinding.revalidate()
    try workerBinding.revalidate()
    for binding in seedSidecarBindings {
      try binding.revalidate()
    }
    guard try ColmapRunner().captureRuntimeClosure(colmapPath: colmapPath) == runtimeClosure
    else {
      throw AdapterError.pipelineFailed("COLMAP runtime changed before evidence publication")
    }

    let envelope: [String: Any] = [
      "schema_version": 3,
      "measurement_scope": "mapping_cadence_trial",
      "trial_name": trial.name,
      "trial_ordinal": trial.ordinal,
      "discarded": trial.ordinal == 0,
      "mapper_cadence": requestedCadence,
      "ba_global_frames_ratio": mapperOptions.globalFramesRatio,
      "ba_global_points_ratio": mapperOptions.globalPointsRatio,
      "ba_global_max_refinements": mapperOptions.globalMaxRefinements,
      "request_sha256": requestBinding.sha256,
      "evidence_class": "development_only",
      "request_kind": "mapper_cadence_ab",
      "source_provenance_scope": "binary_only_dirty_worktree",
      "source_tree_state": "dirty",
      "toolchain_provenance_status": "local_adhoc_unsigned",
      "execution_assurance": developmentExecutionAssurance(),
      "adapter_executable_bytes": authenticatedRequest.adapterBinding.byteCount,
      "adapter_executable_sha256": authenticatedRequest.adapterBinding.sha256,
      "resolved_plan_binding_sha256": resolvedPlanSHA256,
      "deterministic_seed": Int(resolvedPlan.runSeed),
      "colmap_runtime_closure_sha256": runtimeClosure.closureSHA256,
      "selection_manifest_sha256": selectionBinding.sha256,
      "selected_frames_digest": pairEvidence.selectedFramesDigest,
      "selected_image_names": selectedImageNames,
      "pair_graph_evidence_sha256": pairBinding.sha256,
      "pair_list_digest": pairEvidence.pairListDigest,
      "feature_database_digest": sourceLogicalDigests.feature,
      "matching_database_digest": sourceLogicalDigests.matching,
      "source_database_initial_evidence": try encodedJSONObject(
        sourceInitialEvidence,
        label: "source database initial evidence"
      ),
      "source_database_final_evidence": try encodedJSONObject(
        sourceFinalEvidence,
        label: "source database final evidence"
      ),
      "clone_database_pre_run_evidence": try encodedJSONObject(
        cloneEvidence,
        label: "clone database pre-run evidence"
      ),
      "clone_database_post_run_evidence": try encodedJSONObject(
        clonePostEvidence,
        label: "clone database post-run evidence"
      ),
      "clone_feature_database_digest_after": cloneLogicalAfter.feature,
      "clone_matching_database_digest_after": cloneLogicalAfter.matching,
      "clone_database_companion_names": [],
      "output_root": trialRoot.path,
      "fixed_mapper_options": fixedMapperOptions,
      "fixed_mapper_options_sha256": fixedMapperOptionsSHA256,
      "cadence_schedule_sha256": authenticatedRequest.cadenceScheduleSHA256,
      "quality_thresholds_sha256": authenticatedRequest.qualityThresholdsSHA256,
      "experiment_contract_sha256": authenticatedRequest.experimentContractSHA256,
      "mapping_elapsed_seconds": mappingEnded - mappingStarted,
      "peak_memory_bytes": peakMemoryBytes,
      "registered_views": residuals.registeredViewCount,
      "registered_image_names": registeredImageNames,
      "point_count": residuals.pointCount,
      "observation_count": residuals.observationCount,
      "point_track_topology_digest": residuals.pointTrackTopologySHA256,
      "median_residual_pixels": residuals.medianPixelResidual,
      "p90_residual_pixels": residuals.p90PixelResidual,
      "conditioning_status": "accepted",
      "conditioning_provenance": GeometryConditioningMeasurement.provenance,
      "conditioning_measurement": conditioningObject,
      "camera_poses_wxyz_xyz": cameraPoses,
      "model_sha256": modelSHA256,
      "model_hashes": modelHashes,
      "mapped_model_order": selectedCandidate.order,
      "mapper_log": mapperLogURL.lastPathComponent,
      "mapper_log_sha256": mapperLogSHA256,
      "mapper_log_bytes": mapperLogData.count,
    ]
    let envelopeData = try JSONSerialization.data(
      withJSONObject: envelope,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ) + Data("\n".utf8)
    try writePrivateTrialFile(envelopeData, to: arguments.output)
  }

  func verifiedMatchingOnlyMeasurement(
    arguments: AdapterArguments,
    authenticatedRequest: AuthenticatedMapperCadenceDevelopmentRequest,
    paths: ProjectPaths,
    pipeline: PipelineRunner,
    resolvedPlan: ResolvedRunPlan,
    requestSHA256: String,
    startedMonotonicSeconds: TimeInterval,
    endedMonotonicSeconds: TimeInterval,
    peakMemoryBytes: Int64?
  ) throws -> [String: Any] {
    let metadataBinding = try MeasurementEvidenceFileBinding(
      url: paths.metadataURL,
      maximumBytes: 8 * 1_024 * 1_024
    )
    let metadata = try ProjectMetadataStore.decodeValidatedMetadataSnapshot(
      try metadataBinding.dataSnapshot(),
      metadataURL: paths.metadataURL
    )
    guard metadata.formatVersion == ProjectMetadataStore.supportedFormatVersion,
      metadata.state.stage == .sfmMatching,
      metadata.state.lastError == nil,
      metadata.lastRunStartedAt == nil,
      metadata.resolvedRunPlan == resolvedPlan,
      metadata.checkpoint == nil,
      let peakMemoryBytes,
      peakMemoryBytes > 0
    else {
      throw AdapterError.pipelineFailed(
        metadata.state.lastError ?? "pipeline did not stop at a clean matching checkpoint"
      )
    }

    let workerExecutionURL = GeometryWorkerExecutionArtifactStore.canonicalURL(
      for: paths
    )
    let selectionManifestBinding = try MeasurementEvidenceFileBinding(
      url: paths.framesSelectedManifestURL,
      maximumBytes: 4 * 1_024 * 1_024
    )
    let pairGraphEvidenceBinding = try MeasurementEvidenceFileBinding(
      url: paths.pairGraphEvidenceURL,
      maximumBytes: off_t(PairGraphEvidenceStore.maximumBytes)
    )
    let workerExecutionBinding = try MeasurementEvidenceFileBinding(
      url: workerExecutionURL,
      maximumBytes: off_t(GeometryWorkerExecutionArtifactStore.maximumBytes)
    )

    let preFreezeDatabaseDigests = try ColmapDatabaseDigester.digests(
      at: paths.colmapDatabaseURL
    )
    let databaseParent = paths.colmapDatabaseURL.deletingLastPathComponent()
    let frozenDatabase = try MeasurementFrozenCOLMAPDatabase(
      sourceParent: databaseParent,
      sourceName: paths.colmapDatabaseURL.lastPathComponent,
      destinationParent: databaseParent
    )
    let sourceEvidence = frozenDatabase.sourceEvidence
    guard sourceEvidence.sourceName == paths.colmapDatabaseURL.lastPathComponent,
      sourceEvidence.linkCount == 1,
      sourceEvidence.byteCount > 0,
      sourceEvidence.mode == UInt32(S_IFREG | S_IRUSR),
      sourceEvidence.ownerUID == UInt32(geteuid()),
      sourceEvidence.companionNames.isEmpty
    else {
      throw AdapterError.pipelineFailed(
        "matching database does not satisfy the observational source closure"
      )
    }
    try frozenDatabase.revalidateSourceStatOnly()

    let selectedManifest = try pipeline.loadSelectedFrameManifest(
      data: selectionManifestBinding.dataSnapshot()
    )
    let selectedImages = try files(
      in: paths.framesSelectedURL,
      extensions: PhotoInputPreflight.supportedExtensions
    ).map { URL(fileURLWithPath: $0) }
    let selectedImageNames = selectedImages.map(\.lastPathComponent)
    let manifestImageNames = selectedManifest.map(\.outputFileName)
    guard selectedImageNames.count >= RunPlanResolver.minimumReconstructionImageCount,
      selectedImageNames.count <= 3_000,
      selectedImageNames == manifestImageNames,
      Set(selectedImageNames).count == selectedImageNames.count
    else {
      throw AdapterError.pipelineFailed(
        "selected images do not match the current selection manifest"
      )
    }

    let cameraEvidence = try PipelineRunner.colmapCameraGroupingEvidence(
      imageNames: selectedImageNames,
      manifest: selectedManifest
    )
    let expectedCameraInitialization = try ColmapCameraInitializationReceipt.resolve(
      plan: resolvedPlan,
      detailProfile: metadata.requestedRunOptions.detailProfile,
      selectedImages: selectedImages
    )
    let featureEvidence = try ColmapFeatureEvidenceStore.loadVerified(
      from: paths.colmapFeatureEvidenceURL,
      expectedImageNames: selectedImageNames,
      expectedCameraEvidence: cameraEvidence,
      expectedCameraGroupingMode: PipelineRunner.colmapCameraGroupingMode(
        cameraGrouping: resolvedPlan.cameraGrouping,
        evidence: cameraEvidence
      ),
      expectedCameraInitializationReceipt: expectedCameraInitialization,
      databaseURL: paths.colmapDatabaseURL,
      projectPaths: paths
    )
    let pairEvidence = try PairGraphEvidenceStore.loadVerified(
      data: pairGraphEvidenceBinding.dataSnapshot(),
      expectedImageNames: selectedImageNames,
      databaseURL: paths.colmapDatabaseURL,
      projectPaths: paths
    )
    let groups = try PipelineRunner.colmapPairGroups(
      imageNames: selectedImageNames,
      manifest: selectedManifest
    )
    try PairGraphEvidenceStore.validateSchedule(
      pairEvidence,
      resolvedPlan: resolvedPlan,
      groups: groups
    )

    let workerExecution = try GeometryWorkerExecutionArtifactStore.load(
      data: workerExecutionBinding.dataSnapshot(),
      expectedBudget: resolvedPlan.geometryWorkerBudget
    )
    guard
      workerExecution.schemaVersion
        == GeometryWorkerExecutionArtifact.currentSchemaVersion,
      !workerExecution.featureExtractionInvocations.isEmpty,
      workerExecution.featureExtractionInvocations.contains(where: \.succeeded),
      !workerExecution.matchingInvocations.isEmpty,
      workerExecution.matchingInvocations.last?.succeeded == true,
      workerExecution.mappingAndRefinementInvocations.isEmpty
    else {
      throw AdapterError.pipelineFailed(
        "matching-only worker execution is incomplete or contains mapping work"
      )
    }
    let liveRuntimeClosure = try ColmapRunner().captureRuntimeClosure(
      colmapPath: toolchain(at: arguments.toolchainRoot).colmap
    )
    guard liveRuntimeClosure == authenticatedRequest.runtimeClosure,
      liveRuntimeClosure == workerExecution.colmapRuntimeClosure
    else {
      throw AdapterError.pipelineFailed(
        "live COLMAP runtime differs from the recorded matching worker"
      )
    }
    try PairGraphEvidenceStore.validateWorkerExecution(
      pairEvidence,
      workerExecution: workerExecution
    )
    let geometryRecovery = try verifiedMatchingRecovery(
      metadata: metadata,
      resolvedPlan: resolvedPlan,
      pairEvidence: pairEvidence,
      selectedImageNames: selectedImageNames
    )
    guard let colmapComputeMode = geometryRecovery.colmapComputeMode else {
      throw AdapterError.pipelineFailed("matching recovery compute mode is unavailable")
    }
    let rejectedVocabularyRetrievalHistory = try rejectedVocabularyRetrievalHistory(
      workerExecution,
      resolvedPlan: resolvedPlan,
      selectedImageNames: selectedImageNames,
      groups: groups,
      acceptedPairAttemptNumber: pairEvidence.acceptedAttemptNumber
    )
    let seedSidecarBindings = try requireCleanMatchingArtifactClosure(
      paths: paths,
      pairEvidence: pairEvidence,
      workerExecution: workerExecution,
      resolvedPlan: resolvedPlan,
      groups: groups
    )

    let measurement = try pairEvidence.pairGraphMeasurement()
    let databaseDigests = try ColmapDatabaseDigester.digests(at: paths.colmapDatabaseURL)
    guard preFreezeDatabaseDigests == databaseDigests,
      featureEvidence.featureDatabaseDigest == databaseDigests.feature,
      measurement.featureDatabaseDigest == databaseDigests.feature,
      measurement.matchingDatabaseDigest == databaseDigests.matching,
      geometryRecovery.matchingDatabaseDigest == databaseDigests.matching,
      let acceptedAttempt = pairEvidence.attempts.last,
      acceptedAttempt.artifact.attemptNumber == pairEvidence.acceptedAttemptNumber,
      acceptedAttempt.artifact.outcome == .completed,
      acceptedAttempt.artifact.matcher
        == workerExecution.matchingInvocations.last?.pairExecution?.descriptorMatcher
    else {
      throw AdapterError.pipelineFailed(
        "matching evidence does not match the live COLMAP database"
      )
    }
    let exactRecoveryReason: Any
    if let reason = acceptedAttempt.artifact.exactRecoveryReason {
      exactRecoveryReason = reason.rawValue
    } else {
      exactRecoveryReason = NSNull()
    }

    try frozenDatabase.revalidateSourceStatOnly()
    let finalSourceEvidence = try frozenDatabase.finalizeSourceRehash()
    guard finalSourceEvidence == sourceEvidence else {
      throw AdapterError.pipelineFailed(
        "matching database source evidence changed during verification"
      )
    }
    let finalDatabaseDigests = try ColmapDatabaseDigester.digests(at: paths.colmapDatabaseURL)
    guard finalDatabaseDigests == databaseDigests else {
      throw AdapterError.pipelineFailed(
        "matching database logical contents changed during verification"
      )
    }
    try selectionManifestBinding.revalidate()
    try pairGraphEvidenceBinding.revalidate()
    try workerExecutionBinding.revalidate()
    try metadataBinding.revalidate()
    for binding in seedSidecarBindings {
      try binding.revalidate()
    }
    try authenticatedRequest.revalidate()

    guard let databaseSourceDeviceID = Int64(exactly: sourceEvidence.deviceID),
      let databaseSourceInode = Int64(exactly: sourceEvidence.inode)
    else {
      throw AdapterError.pipelineFailed(
        "matching database identity cannot be represented in measurement output"
      )
    }

    let resolvedPlanBindingSHA256 = try encodedSHA256(
      resolvedPlan,
      label: "resolved run plan"
    )
    let pipelineStageSeconds = Dictionary(
      uniqueKeysWithValues: (metadata.stageTimings ?? []).map {
        ($0.stage.rawValue, $0.durationSeconds)
      }
    )
    return [
      "schema_version": 3,
      "measurement_scope": "matching_only",
      "variant": arguments.variant,
      "started_monotonic_seconds": startedMonotonicSeconds,
      "ended_monotonic_seconds": endedMonotonicSeconds,
      "project_root": arguments.projectRoot.path,
      "database_path": try projectSpelledPath(paths: paths, artifact: paths.colmapDatabaseURL),
      "database_project_relative_path": try paths.projectRelativePath(
        for: paths.colmapDatabaseURL),
      "selection_manifest": try paths.projectRelativePath(
        for: paths.framesSelectedManifestURL),
      "pair_graph_evidence": try paths.projectRelativePath(
        for: paths.pairGraphEvidenceURL),
      "worker_execution": try paths.projectRelativePath(for: workerExecutionURL),
      "pipeline_log": try paths.projectRelativePath(for: paths.pipelineLogURL),
      "request_sha256": requestSHA256,
      "evidence_class": "development_only",
      "request_kind": "mapper_cadence_ab",
      "source_provenance_scope": "binary_only_dirty_worktree",
      "source_tree_state": "dirty",
      "toolchain_provenance_status": "local_adhoc_unsigned",
      "execution_assurance": developmentExecutionAssurance(),
      "adapter_executable_bytes": authenticatedRequest.adapterBinding.byteCount,
      "adapter_executable_sha256": authenticatedRequest.adapterBinding.sha256,
      "fixed_mapper_options": authenticatedRequest.fixedMapperOptions,
      "fixed_mapper_options_sha256": authenticatedRequest.fixedMapperOptionsSHA256,
      "cadence_schedule_sha256": authenticatedRequest.cadenceScheduleSHA256,
      "quality_thresholds_sha256": authenticatedRequest.qualityThresholdsSHA256,
      "experiment_contract_sha256": authenticatedRequest.experimentContractSHA256,
      "resolved_plan_binding_sha256": resolvedPlanBindingSHA256,
      "deterministic_seed": Int(resolvedPlan.runSeed),
      "selection_manifest_sha256": selectionManifestBinding.sha256,
      "pair_graph_evidence_sha256": pairGraphEvidenceBinding.sha256,
      "worker_execution_sha256": workerExecutionBinding.sha256,
      "database_file_sha256": sourceEvidence.sha256,
      "database_file_bytes": sourceEvidence.byteCount,
      "database_source_device_id": databaseSourceDeviceID,
      "database_source_inode": databaseSourceInode,
      "database_source_mode": Int(sourceEvidence.mode),
      "pair_graph_schema_version": pairEvidence.schemaVersion,
      "worker_execution_schema_version": workerExecution.schemaVersion,
      "colmap_runtime_closure_sha256": workerExecution.colmapRuntimeClosure.closureSHA256,
      "selected_frames_digest": pairEvidence.selectedFramesDigest,
      "selected_image_count": selectedImageNames.count,
      "selected_image_names": selectedImageNames,
      "pairing_policy": pairEvidence.pairingPolicy.rawValue,
      "pair_attempt_ordinal": pairEvidence.acceptedAttemptNumber,
      "pair_list_digest": pairEvidence.pairListDigest,
      "descriptor_matcher": acceptedAttempt.artifact.matcher.rawValue,
      "colmap_compute_mode": colmapComputeMode.rawValue,
      "fallback_reasons": pairEvidence.fallbackReasons,
      "recovery_level": acceptedAttempt.artifact.recoveryLevel.rawValue,
      "exact_recovery_reason": exactRecoveryReason,
      "rejected_vocabulary_retrieval_count":
        rejectedVocabularyRetrievalHistory.count,
      "rejected_vocabulary_retrieval_history":
        rejectedVocabularyRetrievalHistory,
      "feature_database_digest": databaseDigests.feature,
      "matching_database_digest": databaseDigests.matching,
      "scheduled_pair_count": measurement.scheduledPairCount,
      "attempted_pair_count": measurement.attemptedPairCount,
      "raw_matched_pair_count": measurement.rawMatchedPairCount,
      "spatially_verified_pair_count": measurement.spatiallyVerifiedPairCount,
      "local_pair_count": measurement.localPairCount,
      "retrieval_pair_count": measurement.retrievalPairCount,
      "loop_revisit_pair_count": measurement.loopRevisitPairCount,
      "connected_component_count": measurement.connectedComponentCount,
      "component_view_counts": measurement.componentViewCounts,
      "isolated_view_count": measurement.isolatedViewCount,
      "descriptorless_view_count": measurement.descriptorlessViewCount,
      "articulation_view_count": measurement.articulationViewCount,
      "biconnected_block_count": measurement.biconnectedBlockCount,
      "largest_biconnected_block_view_count":
        measurement.largestBiconnectedBlockViewCount,
      "second_largest_biconnected_block_view_count":
        measurement.secondLargestBiconnectedBlockViewCount,
      "degree_p10": measurement.degreeP10,
      "degree_median": measurement.degreeMedian,
      "degree_p90": measurement.degreeP90,
      "feature_invocation_count": workerExecution.featureExtractionInvocations.count,
      "matching_invocation_count": workerExecution.matchingInvocations.count,
      "retrieval_invocation_count": workerExecution.vocabularyRetrievalInvocations.count,
      "matching_duration_seconds": measurement.matchingDurationSeconds,
      "peak_memory_bytes": peakMemoryBytes,
      "pipeline_stage_seconds": pipelineStageSeconds,
      "stage_seconds": [
        "matching": measurement.matchingDurationSeconds,
        "end_to_end": endedMonotonicSeconds - startedMonotonicSeconds,
      ],
    ]
  }
#endif

@main
struct PipelineMeasurementAdapter {
  static func main() async {
    #if CURRENT_ADAPTER
      var invalidInputReceiptContext:
        (output: URL, variant: String, requestSHA256: String)?
    #endif
    do {
      let arguments = try AdapterArguments.parse(CommandLine.arguments)
      #if CURRENT_ADAPTER
        if arguments.mappingFromCheckpoint != nil {
          try await runMappingCadenceTrial(arguments: arguments)
          return
        }
      #endif
      #if !BASELINE_ADAPTER
        let candidatePreparationStartedAt = Date()
        let candidateStartedMonotonicSeconds = ProcessInfo.processInfo.systemUptime
        #if CURRENT_ADAPTER
          let matchingMemorySampler = arguments.matchingOnly ? GeometryMemorySampler() : nil
          matchingMemorySampler?.start()
          defer { matchingMemorySampler?.cancel() }
        #endif
      #endif
      #if CURRENT_ADAPTER
        let partialRequestBinding = arguments.matchingOnly
          ? try MeasurementEvidenceFileBinding(
            url: arguments.request,
            maximumBytes: 16 * 1_024 * 1_024
          ) : nil
        let requestData = try partialRequestBinding?.dataSnapshot()
          ?? Data(contentsOf: arguments.request)
      #else
        let requestData = try Data(contentsOf: arguments.request)
      #endif
      let requestSHA256 = SHA256.hash(data: requestData)
        .map { String(format: "%02x", $0) }.joined()
      let request = try mapping(
        JSONSerialization.jsonObject(with: requestData),
        "request"
      )
      #if CURRENT_ADAPTER
        let expectedOutcome = try mapping(
          request["expected_outcome"],
          "expected_outcome"
        )
        if try string(expectedOutcome["kind"], "expected_outcome.kind") == "invalid" {
          invalidInputReceiptContext = (
            output: arguments.output,
            variant: arguments.variant,
            requestSHA256: requestSHA256
          )
        }
      #endif
      let binding = try mapping(request["binding"], "binding")
      let scale = try integer(binding["scale"], "binding.scale")
      let holdoutIndices = try integerArray(request["holdout_indices"], "holdout_indices")
      let candidateConfiguration = try mapping(
        request["candidate_run_configuration"],
        "candidate_run_configuration"
      )
      #if CURRENT_ADAPTER
        let authenticatedMapperCadenceRequest: AuthenticatedMapperCadenceDevelopmentRequest?
        if let partialRequestBinding {
          authenticatedMapperCadenceRequest = try authenticateMapperCadenceDevelopmentRequest(
            arguments: arguments,
            requestBinding: partialRequestBinding,
            request: request
          )
        } else {
          authenticatedMapperCadenceRequest = nil
        }
      #endif
      #if ACCURATE_REFERENCE
        let configuration = candidateConfiguration
      #else
        let configuration =
          arguments.variant == "baseline"
          ? try mapping(request["baseline_run_configuration"], "baseline_run_configuration")
          : candidateConfiguration
      #endif
      let benchmarkSeed = try integer(configuration["run_seed"], "run_seed")
      let input = try inputSpec(
        kind: try string(request["input_kind"], "input_kind"),
        input: arguments.input
      )
      var options = try requestedOptions(candidateConfiguration)
      if arguments.variant == "fast_candidate" {
        options.detailProfile = .fast
      }
      let hardware = HardwareProfile.detect()
      #if !BASELINE_ADAPTER
        try RunPlanResolver.validate(
          requestedOptions: options,
          input: input,
          hardware: hardware
        )
      #endif
      var plan = try configuredPlan(
        options: options,
        input: input,
        configuration: configuration,
        scale: scale,
        hardware: hardware
      )
      if arguments.variant == "fast_candidate" {
        plan.trainerIterationLimit = 3_000
        plan.plateauWindow = 400
      }
      #if CURRENT_ADAPTER
        if let authenticatedMapperCadenceRequest {
          _ = try validateMapperCadenceResolvedPlan(
            authenticatedMapperCadenceRequest,
            resolvedPlan: plan,
            expectedRequestedOptions: options
          )
        }
      #endif
      #if BASELINE_ADAPTER
        // The paired baseline is intentionally compiled against the frozen 4f3c117
        // project contract, which predates current input receipts and immutable adoption.
        let paths = ProjectPaths(root: arguments.projectRoot)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
          ProjectMetadata(
            title: "Protected benchmark",
            input: input,
            requestedRunOptions: options,
            resolvedRunPlan: plan
          ),
          to: paths.metadataURL
        )
      #else
        let publishedProject = try await publishCurrentMeasurementProject(
          input: input,
          options: options,
          plan: plan,
          projectRoot: arguments.projectRoot
        )
        let paths = publishedProject.paths
      #endif
      #if ACCURATE_REFERENCE
        try await runAccurateReference(
          arguments: arguments,
          plan: plan,
          paths: paths,
          freshPublicationAttestation: publishedProject.freshPublicationAttestation,
          holdoutIndices: holdoutIndices,
          candidateStartedMonotonicSeconds: candidateStartedMonotonicSeconds,
          candidatePreparationStartedAt: candidatePreparationStartedAt
        )
      #else
        #if BASELINE_ADAPTER
          let started = ProcessInfo.processInfo.systemUptime
          let pipelineConfig = PipelineRunner.PipelineConfig(
            toolchain: toolchain(at: arguments.toolchainRoot),
            developmentOverrides: DevelopmentOverrides(
              candidateRoute: .colmap,
              stopAfterStage: .sfmMapping,
              benchmarkSeed: benchmarkSeed
            ),
            hardwareProfile: .detect(),
            resolvedRunPlan: plan
          )
        #else
          let started = candidateStartedMonotonicSeconds
          let pipelineConfig = PipelineRunner.PipelineConfig(
            toolchain: toolchain(at: arguments.toolchainRoot),
            developmentOverrides: DevelopmentOverrides(
              candidateRoute: .colmap,
              stopAfterStage: arguments.matchingOnly ? .sfmMatching : .sfmMapping,
              benchmarkSeed: benchmarkSeed
            ),
            hardwareProfile: .detect(),
            resolvedRunPlan: plan,
            prePipelineDurationSeconds: ProcessInfo.processInfo.systemUptime
              - candidateStartedMonotonicSeconds,
            prePipelineStartedAt: candidatePreparationStartedAt
          )
        #endif
        #if BASELINE_ADAPTER
          let pipelineProjectURL = arguments.projectRoot
        #else
          let pipelineProjectURL = paths.root
        #endif
        let pipeline = PipelineRunner(
          projectURL: pipelineProjectURL,
          config: pipelineConfig
        )
        #if BASELINE_ADAPTER
          try await pipeline.run { _ in }
        #else
          try await pipeline.run(
            freshPublicationAttestation: publishedProject.freshPublicationAttestation
          ) { _ in }
        #endif
        let geometryEnded = ProcessInfo.processInfo.systemUptime
        #if CURRENT_ADAPTER
          if arguments.matchingOnly {
            guard let authenticatedMapperCadenceRequest else {
              throw AdapterError.invalidRequest(
                "matching-only execution requires an authenticated cadence request"
              )
            }
            let envelope = try verifiedMatchingOnlyMeasurement(
              arguments: arguments,
              authenticatedRequest: authenticatedMapperCadenceRequest,
              paths: paths,
              pipeline: pipeline,
              resolvedPlan: plan,
              requestSHA256: requestSHA256,
              startedMonotonicSeconds: started,
              endedMonotonicSeconds: geometryEnded,
              peakMemoryBytes: matchingMemorySampler?.stop()
            )
            try writeJSON(envelope, to: arguments.output)
            return
          }
        #endif
        let snapshot = try ProjectArtifactSnapshotStore.load(projectURL: paths.root)
        guard snapshot.metadata.state.stage == .sfmMapping,
          snapshot.metadata.state.lastError == nil,
          snapshot.geometryArtifact != nil else {
          throw AdapterError.pipelineFailed(
            snapshot.metadata.state.lastError ?? "pipeline did not complete"
          )
        }
        let selectedImageNames = try orderedGeometryImageNames(from: paths.geometryManifestURL)
        let textModel = try createMeasurementTextModelDirectory(
          paths: paths,
          variant: arguments.variant
        )
        try ColmapRunner().runModelConverter(
          colmapPath: toolchain(at: arguments.toolchainRoot).colmap,
          inputPath: paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true),
          outputPath: textModel,
          outputType: "TXT",
          onLog: { _, _ in }
        )
        let measured = try ColmapResidualAnalyzer.analyze(modelDirectory: textModel)
        if arguments.geometryOnly {
          #if CURRENT_ADAPTER
            let ended = ProcessInfo.processInfo.systemUptime
            let pipelineStageSeconds = Dictionary(
              uniqueKeysWithValues: (metadata.stageTimings ?? []).map {
                ($0.stage.rawValue, $0.durationSeconds)
              }
            )
            let envelope: [String: Any] = [
              "schema_version": 2,
              "measurement_scope": "geometry_only",
              "variant": arguments.variant,
              "started_monotonic_seconds": started,
              "ended_monotonic_seconds": ended,
              "project_root": arguments.projectRoot.path,
              "geometry_manifest": paths.geometryManifestURL.path,
              "selection_manifest": paths.framesSelectedManifestURL.path,
              "pair_graph_evidence": paths.pairGraphEvidenceURL.path,
              "canonical_text_model": try projectSpelledPath(
                paths: paths, artifact: textModel),
              "pipeline_log": paths.pipelineLogURL.path,
              "registered_views": measured.registeredViewCount,
              "point_count": measured.pointCount,
              "observation_count": measured.observationCount,
              "median_residual_pixels": measured.medianPixelResidual,
              "p90_residual_pixels": measured.p90PixelResidual,
              "geometry_completed_monotonic_seconds": geometryEnded,
              "pipeline_stage_seconds": pipelineStageSeconds,
              "stage_seconds": [
                "geometry": geometryEnded - started,
                "end_to_end": ended - started,
              ],
            ]
            try writeJSON(envelope, to: arguments.output)
            return
          #else
            throw AdapterError.invalidArguments("geometry-only is unavailable for this worker")
          #endif
        }
        let dataset = try prepareMeasurementDataset(
          paths: paths,
          textModel: textModel,
          selectedImageNames: selectedImageNames,
          holdoutIndices: holdoutIndices,
          toolchainRoot: arguments.toolchainRoot,
          label: "measurement-\(arguments.variant)-dataset"
        )
        let trainedPLY = paths.trainingURL.appendingPathComponent(
          "measurement-\(arguments.variant)/splat.ply"
        )
        let trainingStarted = ProcessInfo.processInfo.systemUptime
        let training = try await runMeasurementTraining(
          dataset: dataset,
          output: trainedPLY,
          profile: options.detailProfile,
          seed: UInt64(benchmarkSeed),
          iterationLimit: plan.trainerIterationLimit,
          plateauWindow: plan.plateauWindow,
          memoryBudgetBytes: measurementTrainerMemoryBudget(plan),
          toolchainRoot: arguments.toolchainRoot
        )
        let trainingEnded = ProcessInfo.processInfo.systemUptime
        let trainingReceipt = paths.trainingURL.appendingPathComponent(
          "measurement_training_receipt.json"
        )
        let outputDigest = try writeMeasurementTrainingReceipt(
          result: training,
          dataset: dataset,
          output: trainedPLY,
          geometryManifest: paths.geometryManifestURL,
          profile: options.detailProfile,
          seed: UInt64(benchmarkSeed),
          memoryBudgetBytes: measurementTrainerMemoryBudget(plan),
          to: trainingReceipt
        )
        let output = try publishMeasurementPLY(trainedPLY, paths: paths)
        guard try GeometryArtifactStore.sha256(of: output) == outputDigest else {
          throw AdapterError.pipelineFailed("published measurement PLY digest changed")
        }
        let ended = ProcessInfo.processInfo.systemUptime
        var timings = Dictionary(
          grouping: metadata.stageTimings ?? [],
          by: { stageName($0.stage) }
        )
          .mapValues { values in values.reduce(0) { $0 + $1.durationSeconds } }
        timings["train"] = trainingEnded - trainingStarted
        timings["finish"] = ended - trainingEnded
        timings["end_to_end"] = ended - started
        let pipelineStageSeconds = Dictionary(
          uniqueKeysWithValues: (metadata.stageTimings ?? []).map {
            ($0.stage.rawValue, $0.durationSeconds)
          }
        )
        let envelope: [String: Any] = [
          "schema_version": 1,
          "variant": arguments.variant,
          "started_monotonic_seconds": started,
          "ended_monotonic_seconds": ended,
          "project_root": arguments.projectRoot.path,
          "output_ply": output.path,
          "output_sha256": outputDigest,
          "geometry_manifest": paths.geometryManifestURL.path,
          "training_manifest": trainingReceipt.path,
          "selection_manifest": paths.framesSelectedManifestURL.path,
          "training_split_manifest": dataset.splitManifest.path,
          "training_split_digest": dataset.split.closureDigest,
          "training_image_digest": dataset.split.trainingImageDigest,
          "dataset_input_digest": dataset.identity.inputDigest,
          "dataset_geometry_digest": dataset.identity.geometryDigest,
          "source_model_digest": dataset.sourceModelDigest,
          "filtered_model_digest": dataset.filteredModelDigest,
          "pipeline_log": paths.pipelineLogURL.path,
          "geometry_completed_monotonic_seconds": geometryEnded,
          "pipeline_stage_seconds": pipelineStageSeconds,
          "stage_seconds": timings,
        ]
        try writeJSON(envelope, to: arguments.output)
      #endif
    } catch {
      #if CURRENT_ADAPTER
        if let context = invalidInputReceiptContext,
          let failureType = PipelineRunner.captureFailureType(for: error)
        {
          do {
            try MeasurementInvalidInputRejectionReceipt(
              variant: context.variant,
              requestSHA256: context.requestSHA256,
              failureType: failureType.rawValue
            ).write(to: context.output)
          } catch {
            FileHandle.standardError.write(
              Data("Pipeline adapter could not publish its typed rejection receipt.\n".utf8)
            )
          }
        }
      #endif
      FileHandle.standardError.write(Data("Pipeline adapter: \(error.localizedDescription)\n".utf8))
      Foundation.exit(1)
    }
  }
}
