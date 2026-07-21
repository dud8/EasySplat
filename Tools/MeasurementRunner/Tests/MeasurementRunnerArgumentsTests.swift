import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EasySplatCore
@testable import EasySplatMeasurementAdapterSupport
@testable import EasySplatMeasurementRunnerCore

@Suite("Measurement runner arguments")
struct MeasurementRunnerArgumentsTests {
  @Test("invalid measurement plans have no input-admission side effects")
  func invalidMeasurementPlansHaveNoInputAdmissionSideEffects() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let photos = root.appendingPathComponent("photos", isDirectory: true)
    let video = root.appendingPathComponent("capture.mov")
    try FileManager.default.createDirectory(
      at: photos,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try Data("source-video".utf8).write(to: video)
    defer { try? FileManager.default.removeItem(at: root) }
    let initialLeaves = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

    #expect(throws: RunPlanResolver.ValidationError.continuousMixedInputUnsupported) {
      try RunPlanResolver.validate(
        requestedOptions: RequestedRunOptions(inputOrdering: .continuous),
        input: .mixed(videos: [video.path], photosFolder: photos.path),
        hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
      )
    }
    #expect(throws: RunPlanResolver.ValidationError.fastDetailRequired) {
      try RunPlanResolver.validate(
        requestedOptions: RequestedRunOptions(detailProfile: .balanced),
        input: .video(files: [video.path]),
        hardware: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
      )
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == initialLeaves)
  }

  @Test("current measurement input adoption binds controlled photo receipts")
  func currentMeasurementInputAdoptionBindsControlledPhotoReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let project = root.appendingPathComponent("measurement-project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: source,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMeasurementPNG(at: source.appendingPathComponent("outside.png"))

    let unadmittedPaths = ProjectPaths(
      root: root.appendingPathComponent("unadmitted-project", isDirectory: true)
    )
    try unadmittedPaths.ensureDirectories()
    #expect(throws: PhotoInputReceiptValidationError.invalidPhotoRoot) {
      try ProjectMetadataStore.save(
        ProjectMetadata(
          title: "Broken benchmark",
          input: .photos(folder: source.path)
        ),
        to: unadmittedPaths.metadataURL
      )
    }

    let prepared = try await PhotoInputPreflight.prepare(
      folder: source,
      stagingParent: root,
      photoSelection: .useAllValidPhotos,
      inputOrdering: .unordered,
      keyframeBudget: 1,
      requiredAtomicWorkspaceReserveBytes: 0,
      limits: PhotoInputPreflightLimits(
        maximumPhotoCount: 1,
        maximumTotalBytes: 1_048_576,
        maximumSinglePhotoBytes: 1_048_576,
        maximumPixelCount: 4_096,
        maximumDecodedDimension: 64,
        maximumTraversalEntryCount: 8,
        maximumRecursionDepth: 2,
        minimumFreeSpaceReserveBytes: 0
      ),
      progress: { _, _ in }
    )
    defer { prepared.discard() }
    try FileManager.default.createDirectory(
      at: project,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let paths = ProjectPaths(root: project)
    var adoption = ProjectInputAdoption(
      requestedInput: .photos(folder: source.path)
    )

    try adoption.adoptPhotos(prepared, into: paths)
    try paths.ensureDirectories()
    let metadata = ProjectMetadata(
      title: "Protected benchmark",
      input: adoption.input,
      videoInputReceipts: adoption.videoInputReceipts,
      photoInputReceipts: adoption.photoInputReceipts,
      photoSelectionReceipt: adoption.photoSelectionReceipt
    )
    try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    let loaded = try ProjectMetadataStore.load(from: paths.metadataURL)
    let receipts = try #require(loaded.photoInputReceipts)
    let receipt = try #require(receipts.first)
    let metadataText = try #require(
      String(data: Data(contentsOf: paths.metadataURL), encoding: .utf8)
    )

    #expect(loaded.input.photosFolder == "Originals/Photos")
    #expect(receipts.count == 1)
    #expect(receipt.projectRelativePath == "Originals/Photos/photo-0000.png")
    #expect(receipt.safeDisplayName == "outside.png")
    #expect(!metadataText.contains(source.path))
  }

  @Test("segmented benchmark topology preserves clip-local temporal pairing")
  func segmentedBenchmarkTopologyPreservesClipLocalTemporalPairing() throws {
    let segmentedOrdering = try #require(
      MeasurementInputTopology(rawValue: "segmented_mixed")
    ).requestedInputOrdering
    let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
    let segmentedInputs: [InputSpec] = [
      .video(files: ["/tmp/first.mov", "/tmp/second.mov"]),
      .mixed(videos: ["/tmp/clip.mov"], photosFolder: "/tmp/photos"),
    ]

    for input in segmentedInputs {
      let plan = RunPlanResolver.resolve(
        requestedOptions: RequestedRunOptions(inputOrdering: segmentedOrdering),
        input: input,
        hardware: hardware,
        developmentOverrides: .none
      )

      #expect(plan.pairingPolicy == .segmentedMixed)
      #expect(plan.temporalPairing == .linear)
      #expect(plan.temporalOffsets == [1, 2, 3, 4, 5, 6])
    }

    let unorderedOrdering = try #require(
      MeasurementInputTopology(rawValue: "unordered")
    ).requestedInputOrdering
    let unorderedPlan = RunPlanResolver.resolve(
      requestedOptions: RequestedRunOptions(inputOrdering: unorderedOrdering),
      input: segmentedInputs[0],
      hardware: hardware,
      developmentOverrides: .none
    )

    #expect(unorderedPlan.pairingPolicy == .unorderedRetrieval)
    #expect(unorderedPlan.temporalPairing == .none)
    #expect(unorderedPlan.temporalOffsets.isEmpty)
  }

  @Test("selects the largest sparse model and lower-order tie")
  func selectsLargestSparseModel() {
    let candidates = [
      MeasurementSparseModelCandidate(order: 7, registeredViewCount: 24),
      MeasurementSparseModelCandidate(order: 3, registeredViewCount: 24),
      MeasurementSparseModelCandidate(order: 1, registeredViewCount: 12),
    ]

    #expect(MeasurementSparseModelSelector.select(candidates)?.order == 3)
    #expect(MeasurementSparseModelSelector.select([]) == nil)
  }

  @Test("filters held-out cameras and prunes tracks without two training views")
  func filtersHeldOutCOLMAPModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("filtered", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "1 PINHOLE 640 480 500 500 320 240\n".write(
      to: source.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
    try """
      1 1 0 0 0 0 0 0 1 a.jpg
      0 0 10 1 1 20
      2 1 0 0 0 1 0 0 1 b.jpg
      0 0 10 1 1 30
      3 1 0 0 0 2 0 0 1 c.jpg
      0 0 20 1 1 30
      """.write(
        to: source.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
    try """
      10 0 0 0 255 0 0 0.1 1 0 2 0
      20 1 0 0 0 255 0 0.2 1 1 3 0
      30 2 0 0 0 0 255 0.3 2 1 3 1
      """.write(
        to: source.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

    let filtered = try MeasurementCOLMAPTextFilter.filter(
      source: source,
      destination: output,
      holdoutImageNames: ["b.jpg"]
    )

    #expect(filtered.registeredImageNames == ["a.jpg", "b.jpg", "c.jpg"])
    #expect(filtered.trainingImageNames == ["a.jpg", "c.jpg"])
    #expect(filtered.holdoutImageNames == ["b.jpg"])
    #expect(filtered.retainedPointCount == 1)
    let images = try String(contentsOf: output.appendingPathComponent("images.txt"), encoding: .utf8)
    let points = try String(contentsOf: output.appendingPathComponent("points3D.txt"), encoding: .utf8)
    #expect(images.contains("1 1 0 0 0 0 0 0 1 a.jpg\n0 0 -1 1 1 20"))
    #expect(!images.contains("b.jpg"))
    #expect(images.contains("3 1 0 0 0 2 0 0 1 c.jpg\n0 0 20 1 1 -1"))
    #expect(points.contains("20 1 0 0 0 255 0 0.2 1 1 3 0"))
    #expect(!points.contains("10 0 0 0"))
    #expect(!points.contains("30 2 0 0"))
  }

  @Test("training split digest binds order and image bytes")
  func trainingSplitDigestBindsDataset() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, bytes) in [("a.jpg", "a"), ("c.jpg", "c")] {
      try Data(bytes.utf8).write(to: root.appendingPathComponent(name))
    }

    let split = try MeasurementTrainingSplit.make(
      selectedImageNames: ["a.jpg", "b.jpg", "c.jpg"],
      holdoutViewIndices: [1],
      imagesDirectory: root
    )
    let reversed = try MeasurementTrainingSplit.make(
      selectedImageNames: ["c.jpg", "b.jpg", "a.jpg"],
      holdoutViewIndices: [1],
      imagesDirectory: root
    )
    try Data("changed".utf8).write(to: root.appendingPathComponent("c.jpg"))
    let changed = try MeasurementTrainingSplit.make(
      selectedImageNames: ["a.jpg", "b.jpg", "c.jpg"],
      holdoutViewIndices: [1],
      imagesDirectory: root
    )

    #expect(split.trainingViewIndices == [0, 2])
    #expect(split.holdoutImageNames == ["b.jpg"])
    #expect(split.trainingImageNames == ["a.jpg", "c.jpg"])
    #expect(split.closureDigest != reversed.closureDigest)
    #expect(split.trainingImageDigest != changed.trainingImageDigest)
    #expect(split.closureDigest != changed.closureDigest)
  }

  @Test("reference lane uses the protected alternating run schedule")
  func referenceSchedule() throws {
    let schedule = MeasurementSchedule.make(
      for: .reference,
      gateScopes: ["suite_performance"],
      validOutcome: true
    )

    #expect(schedule.count == 28)
    #expect(
      schedule.prefix(8).map(\.variant)
        == [.baseline, .candidate, .baseline, .candidate, .candidate, .baseline, .baseline, .candidate]
    )
    #expect(schedule.prefix(2).allSatisfy { $0.discarded })
    #expect(schedule.dropFirst(2).prefix(6).allSatisfy { !$0.discarded })
    #expect(schedule.filter { $0.phase == .phase }.count == 12)
    #expect(schedule.filter { $0.phase == .fastProfile }.count == 8)
    #expect(schedule.filter { $0.variant == .accurateReference }.count == 4)
    #expect(schedule.filter(\.publishesOutput).count == 1)
    #expect(schedule.last?.variant == .fastCandidate)
    #expect(schedule.last?.publishesOutput == false)
  }

  @Test("constrained lanes execute one warmup and three measured candidates")
  func constrainedSchedules() throws {
    for lane in [MeasurementLane.constrained, .eightGB] {
      let schedule = MeasurementSchedule.make(
        for: lane,
        gateScopes: ["suite_performance"],
        validOutcome: true
      )
      #expect(schedule.count == 4)
      #expect(schedule.allSatisfy { $0.phase == .candidate })
      #expect(schedule.allSatisfy { $0.variant == .candidate })
      #expect(schedule.map(\.discarded) == [true, false, false, false])
      #expect(schedule.map(\.publishesOutput) == [false, false, false, true])
    }
  }

  @Test("scene-quality and invalid-input schedules execute only required workers")
  func scopedSchedules() {
    let quality = MeasurementSchedule.make(
      for: .reference,
      gateScopes: ["scene_quality"],
      validOutcome: true
    )
    #expect(quality.count == 16)
    #expect(quality.filter { $0.phase == .phase }.isEmpty)
    #expect(quality.filter { $0.phase == .ordinary }.count == 8)
    #expect(quality.filter { $0.phase == .fastProfile }.count == 8)

    let invalid = MeasurementSchedule.make(
      for: .reference,
      gateScopes: ["invalid_input"],
      validOutcome: false
    )
    #expect(invalid.count == 1)
    #expect(invalid[0].runID == "invalid-input-0")
    #expect(invalid[0].phase == .invalidInput)
    #expect(invalid[0].variant == .candidate)
    #expect(invalid[0].publishesOutput == false)
  }

  @Test("measurement runner leaves orientation labels to the authenticated supervisor")
  func supervisorOwnsOrientationLabels() {
    var metrics: [String: Any] = ["sentinel": 1]

    MeasurementOrientationMetricBoundary.reserveSupervisorFields(in: &metrics)

    #expect(metrics["sentinel"] as? Int == 1)
    #expect(metrics["orientation_status"] is NSNull)
    #expect(metrics["orientation_physical_up_error_degrees"] is NSNull)
    #expect(metrics["orientation_sign_correct"] is NSNull)
  }

  @Test("request loader binds schema lane identities and scale")
  func boundRequest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let requestURL = root.appendingPathComponent("request.json")
    var request: [String: Any] = [
      "schema_version": 11,
      "binding": [
        "profile": "release",
        "scene_id": "orbit-01",
        "scale": 250,
        "lane": "reference_m4_max",
        "input_digest": "sha256:" + String(repeating: "1", count: 64),
        "git_commit": String(repeating: "2", count: 40),
        "toolchain_identity": "sha256:" + String(repeating: "3", count: 64),
        "baseline_git_commit": String(repeating: "4", count: 40),
        "baseline_toolchain_identity": "sha256:" + String(repeating: "5", count: 64),
      ],
      "input_kind": "video",
      "holdout_indices": [4, 9, 14, 19, 24, 29, 34, 39, 44, 49, 54, 59, 64, 69, 74, 79,
        84, 89, 94, 99, 104, 109, 114, 119, 124, 129, 134, 139, 144, 149, 154, 159,
        164, 169, 174, 179, 184, 189, 194, 199, 204, 209, 214, 219, 224, 229, 234, 239,
        244, 249],
      "gate_scopes": ["scene_quality"],
      "expected_outcome": ["kind": "valid"],
    ]
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    try data.write(to: requestURL)

    let decoded = try BoundMeasurementRequest.load(from: requestURL, expectedLane: .reference)
    #expect(decoded.binding.scale == 250)
    #expect(decoded.binding.sceneID == "orbit-01")
    #expect(decoded.holdoutIndices.last == 249)
    #expect(decoded.gateScopes == ["scene_quality"])
    #expect(throws: MeasurementRunnerError.self) {
      try BoundMeasurementRequest.load(from: requestURL, expectedLane: .constrained)
    }
    request["schema_version"] = 10
    try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
      .write(to: requestURL)
    #expect(throws: MeasurementRunnerError.invalidRequest("request binding is invalid")) {
      try BoundMeasurementRequest.load(from: requestURL, expectedLane: .reference)
    }
  }

  @Test("request loader binds an invalid outcome to its expected failure type")
  func boundInvalidRequest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let requestURL = root.appendingPathComponent("request.json")
    var request: [String: Any] = [
      "schema_version": 11,
      "binding": [
        "profile": "release", "scene_id": "invalid-02", "scale": 120,
        "lane": "reference_m4_max",
        "input_digest": "sha256:" + String(repeating: "1", count: 64),
        "git_commit": String(repeating: "2", count: 40),
        "toolchain_identity": "sha256:" + String(repeating: "3", count: 64),
        "baseline_git_commit": String(repeating: "4", count: 40),
        "baseline_toolchain_identity": "sha256:" + String(repeating: "5", count: 64),
      ],
      "input_kind": "mixed",
      "holdout_indices": [],
      "gate_scopes": ["invalid_input"],
      "expected_outcome": [
        "kind": "invalid",
        "failure_type": "insufficient_overlap",
      ],
    ]
    try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
      .write(to: requestURL)

    let decoded = try BoundMeasurementRequest.load(
      from: requestURL,
      expectedLane: .reference
    )
    #expect(decoded.expectedOutcome.failureType == "insufficient_overlap")

    request["expected_outcome"] = ["kind": "invalid"]
    try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
      .write(to: requestURL)
    #expect(throws: MeasurementRunnerError.invalidRequest("request binding is invalid")) {
      try BoundMeasurementRequest.load(from: requestURL, expectedLane: .reference)
    }
  }

  @Test("request loader rejects video holdout drift")
  func boundRequestRejectsHoldoutDrift() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let requestURL = root.appendingPathComponent("request.json")
    let request: [String: Any] = [
      "schema_version": 11,
      "binding": [
        "profile": "release", "scene_id": "orbit-01", "scale": 30,
        "lane": "reference_m4_max",
        "input_digest": "sha256:" + String(repeating: "1", count: 64),
        "git_commit": String(repeating: "2", count: 40),
        "toolchain_identity": "sha256:" + String(repeating: "3", count: 64),
        "baseline_git_commit": String(repeating: "4", count: 40),
        "baseline_toolchain_identity": "sha256:" + String(repeating: "5", count: 64),
      ],
      "input_kind": "video",
      "holdout_indices": [4, 9, 14, 19, 24],
      "gate_scopes": ["scene_quality"],
      "expected_outcome": ["kind": "valid"],
    ]
    try JSONSerialization.data(withJSONObject: request).write(to: requestURL)

    #expect(throws: MeasurementRunnerError.self) {
      try BoundMeasurementRequest.load(from: requestURL, expectedLane: .reference)
    }
  }

  @Test("worker set requires all three sibling executables")
  func workerSet() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = root.appendingPathComponent("EasySplatMeasurementRunner")
    for name in [
      "PipelineMeasurementAdapter-current",
      "PipelineMeasurementAdapter-baseline",
      "AccurateReferenceMeasurementAdapter",
    ] {
      let worker = root.appendingPathComponent(name)
      try Data("worker".utf8).write(to: worker)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: worker.path
      )
    }

    let workers = try MeasurementWorkerSet.resolve(nextTo: runner)
    #expect(workers.accurateReference.lastPathComponent == "AccurateReferenceMeasurementAdapter")
    try FileManager.default.removeItem(at: workers.baseline)
    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementWorkerSet.resolve(nextTo: runner)
    }
  }

  @Test("worker executor runs the fixed boundary and authenticates its envelope")
  func workerExecutor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = root.appendingPathComponent("worker")
    try """
      #!/bin/sh
      set -eu
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --project-root) project="$2" ;;
          --output) envelope="$2" ;;
          --variant) variant="$2" ;;
        esac
        shift 2
      done
      mkdir -p "$project/Output"
      printf 'ply\\nformat binary_little_endian 1.0\\nelement vertex 1\\nend_header\\n' > "$project/Output/splat.ply"
      printf '{"schema_version":1,"variant":"%s","output_ply":"%s/Output/splat.ply","output_sha256":"1bc1739c0b93dba4679bd19f210d9802852b104ed9bd527e7894f5d8601742e0","stage_seconds":{"end_to_end":1.0}}\\n' "$variant" "$project" > "$envelope"
      """.write(to: worker, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)

    let invocation = MeasurementWorkerInvocation(
      executable: worker,
      request: root.appendingPathComponent("request.json"),
      input: root.appendingPathComponent("input.mov"),
      toolchainRoot: root.appendingPathComponent("toolchain"),
      projectRoot: root.appendingPathComponent("project.easysplatproj"),
      variant: .candidate,
      envelope: root.appendingPathComponent("envelope.json"),
      stdoutLog: root.appendingPathComponent("stdout.log"),
      stderrLog: root.appendingPathComponent("stderr.log")
    )
    let result = try MeasurementWorkerExecutor.run(invocation)

    #expect(result.exitCode == 0)
    #expect(result.variant == .candidate)
    #expect(result.outputPLY == invocation.projectRoot.appendingPathComponent("Output/splat.ply"))
    #expect(result.stageSeconds["end_to_end"] == 1)
    #expect(result.endedMonotonicSeconds > result.startedMonotonicSeconds)
    #expect(result.userCPUMicroseconds + result.systemCPUMicroseconds > 0)
    #expect(result.memorySamples.first?.elapsedSeconds == 0)
    #expect(
      result.memorySamples.last?.elapsedSeconds
        == result.endedMonotonicSeconds - result.startedMonotonicSeconds
    )
    #expect(result.memorySamples.allSatisfy { $0.processTreeResidentBytes > 0 })
  }

  @Test("expected-invalid worker requires a typed rejection receipt")
  func expectedInvalidWorkerRequiresTypedReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = root.appendingPathComponent("worker")
    try """
      #!/bin/sh
      echo 'invalid capture' >&2
      exit 23
      """.write(to: worker, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
    let invocation = MeasurementWorkerInvocation(
      executable: worker,
      request: root.appendingPathComponent("request.json"),
      input: root.appendingPathComponent("input.mov"),
      toolchainRoot: root.appendingPathComponent("toolchain"),
      projectRoot: root.appendingPathComponent("project.easysplatproj"),
      variant: .candidate,
      envelope: root.appendingPathComponent("envelope.json"),
      stdoutLog: root.appendingPathComponent("stdout.log"),
      stderrLog: root.appendingPathComponent("stderr.log")
    )

    #expect(
      throws: MeasurementRunnerError.subprocessFailed(
        "invalid-input worker did not publish a typed rejection receipt"
      )
    ) {
      try MeasurementWorkerExecutor.runExpectedFailure(invocation)
    }
  }

  @Test("expected-invalid worker authenticates its typed rejection receipt")
  func expectedInvalidWorkerAuthenticatesTypedReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = root.appendingPathComponent("request.json")
    try Data("bound invalid request".utf8).write(to: request)
    let requestDigest = try MeasurementWorkerExecutor.sha256(request)
    let worker = root.appendingPathComponent("worker")
    try """
      #!/bin/sh
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--output" ]; then
          output=$2
          break
        fi
        shift 2
      done
      printf '%s\n' '{"failure_type":"insufficient_overlap","kind":"invalid_input_rejection","request_sha256":"\(requestDigest)","schema_version":1,"variant":"candidate"}' > "$output"
      echo 'invalid capture' >&2
      exit 23
      """.write(to: worker, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
    let invocation = MeasurementWorkerInvocation(
      executable: worker,
      request: request,
      input: root.appendingPathComponent("input.mov"),
      toolchainRoot: root.appendingPathComponent("toolchain"),
      projectRoot: root.appendingPathComponent("project.easysplatproj"),
      variant: .candidate,
      envelope: root.appendingPathComponent("envelope.json"),
      stdoutLog: root.appendingPathComponent("stdout.log"),
      stderrLog: root.appendingPathComponent("stderr.log")
    )

    let result = try MeasurementWorkerExecutor.runExpectedFailure(invocation)
    let failureReceiptDigest = try MeasurementWorkerExecutor.sha256(invocation.envelope)
    let stderrDigest = try MeasurementWorkerExecutor.sha256(invocation.stderrLog)

    #expect(result.exitCode == 23)
    #expect(result.failureType == "insufficient_overlap")
    #expect(result.failureReceiptSHA256 == failureReceiptDigest)
    #expect(result.endedMonotonicSeconds > result.startedMonotonicSeconds)
    #expect(result.userCPUMicroseconds + result.systemCPUMicroseconds > 0)
    #expect(result.stderrSHA256 == stderrDigest)
    #expect(!FileManager.default.fileExists(
      atPath: invocation.projectRoot.appendingPathComponent("Output/splat.ply").path
    ))
  }

  @Test("invalid-input rejection receipt publishes an exact bound document")
  func invalidInputRejectionReceiptPublishesExactDocument() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("rejection.json")
    let requestDigest = String(repeating: "a", count: 64)
    let receipt = try MeasurementInvalidInputRejectionReceipt(
      variant: "candidate",
      requestSHA256: requestDigest,
      failureType: "multiple_scenes"
    )

    try receipt.write(to: destination)

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination))
        as? [String: Any]
    )
    #expect(Set(object.keys) == [
      "schema_version", "kind", "variant", "request_sha256", "failure_type",
    ])
    #expect((object["schema_version"] as? NSNumber)?.intValue == 1)
    #expect(object["kind"] as? String == "invalid_input_rejection")
    #expect(object["variant"] as? String == "candidate")
    #expect(object["request_sha256"] as? String == requestDigest)
    #expect(object["failure_type"] as? String == "multiple_scenes")
    #expect(throws: MeasurementInvalidInputRejectionReceipt.Error.destinationExists) {
      try receipt.write(to: destination)
    }
  }

  @Test("accepts the protected lane boundary")
  func acceptsBoundary() throws {
    let arguments = try MeasurementRunnerArguments.parse([
      "EasySplatMeasurementRunner",
      "--request", "/protected/request.json",
      "--input", "/protected/media",
      "--toolchain-root", "/protected/toolchain",
      "--candidate-checkout-root", "/protected/candidate",
      "--baseline-checkout-root", "/protected/baseline",
      "--baseline-toolchain-root", "/protected/baseline-toolchain",
      "--reference-config", "/protected/reference.json",
      "--reference-artifact-root", "/protected/references",
      "--artifact-root", "/protected/artifacts",
      "--lane", "reference_m4_max",
    ])

    #expect(arguments.lane == .reference)
    #expect(arguments.request.path == "/protected/request.json")
    #expect(arguments.referenceArtifactRoot?.path == "/protected/references")
    #expect(arguments.artifactRoot.path == "/protected/artifacts")
  }

  @Test("stages and rechecks an exact protected reference closure")
  func protectedReferenceClosure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(#"{"schema_version":1,"value":"ground truth"}"#.utf8)
    try bytes.write(to: source.appendingPathComponent("ground-truth-poses.json"))
    let digest = "sha256:\(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())"
    let expected = [
      MeasurementReferenceArtifactClosure.ExpectedArtifact(
        filename: "ground-truth-poses.json", sha256: digest)
    ]

    let closure = try MeasurementReferenceArtifactClosure.stage(
      sourceRoot: source, artifactRoot: output, expected: expected)
    try closure.reverify()
    #expect(try Data(contentsOf: output.appendingPathComponent("ground-truth-poses.json")) == bytes)

    let secondOutput = root.appendingPathComponent("second-output", isDirectory: true)
    try FileManager.default.createDirectory(at: secondOutput, withIntermediateDirectories: true)
    let stagedClosure = try MeasurementReferenceArtifactClosure.stage(
      sourceRoot: source, artifactRoot: secondOutput, expected: expected)
    try Data(#"{"schema_version":1,"value":"staged change"}"#.utf8).write(
      to: secondOutput.appendingPathComponent("ground-truth-poses.json"))
    #expect(throws: MeasurementRunnerError.self) { try stagedClosure.reverify() }

    try Data(#"{"schema_version":1,"value":"changed"}"#.utf8).write(
      to: source.appendingPathComponent("ground-truth-poses.json"))
    #expect(throws: MeasurementRunnerError.self) { try closure.reverify() }
  }

  @Test("ground-truth preparation expands the exact rendering asset closure")
  func protectedRenderingAssetClosure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let sourceImage = source.appendingPathComponent("rendering/source/000004.png")
    let targetImage = source.appendingPathComponent("rendering/ground-truth/000004.png")
    try FileManager.default.createDirectory(
      at: sourceImage.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: targetImage.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = Data("png fixture".utf8)
    let imageDigest = "sha256:\(SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined())"
    try image.write(to: sourceImage)
    try image.write(to: targetImage)
    let preparation: [String: Any] = [
      "schema_version": 2,
      "views": [[
        "source": ["path": "rendering/source/000004.png", "sha256": imageDigest],
        "target": ["path": "rendering/ground-truth/000004.png", "sha256": imageDigest],
      ]],
    ]
    let preparationBytes = try JSONSerialization.data(
      withJSONObject: preparation, options: [.sortedKeys])
    let preparationURL = source.appendingPathComponent("ground-truth-preparation.json")
    try preparationBytes.write(to: preparationURL)
    let preparationHex = SHA256.hash(data: preparationBytes).map {
      String(format: "%02x", $0)
    }.joined()
    let preparationDigest = "sha256:\(preparationHex)"

    _ = try MeasurementReferenceArtifactClosure.stage(
      sourceRoot: source,
      artifactRoot: output,
      expected: [.init(
        filename: "ground-truth-preparation.json", sha256: preparationDigest)]
    )
    #expect(try Data(contentsOf: output.appendingPathComponent("rendering/source/000004.png")) == image)
    #expect(
      try Data(contentsOf: output.appendingPathComponent("rendering/ground-truth/000004.png"))
        == image)
  }

  @Test("rejects linked, extra, malformed, and digest-mismatched reference artifacts")
  func rejectsUnsafeReferenceClosure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = MeasurementReferenceArtifactClosure.ExpectedArtifact(
      filename: "orientation-label.json", sha256: "sha256:" + String(repeating: "0", count: 64))

    for mode in ["extra", "malformed", "hardlink", "symlink", "digest"] {
      let source = root.appendingPathComponent(mode).appendingPathComponent("source", isDirectory: true)
      let output = root.appendingPathComponent(mode).appendingPathComponent("output", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let artifact = source.appendingPathComponent(expected.filename)
      let bytes = Data((mode == "malformed" ? "{}" : #"{"schema_version":1}"#).utf8)
      if mode == "symlink" {
        let outside = root.appendingPathComponent(mode).appendingPathComponent("outside.json")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: outside)
      } else {
        try bytes.write(to: artifact)
      }
      if mode == "extra" {
        try Data("extra".utf8).write(to: source.appendingPathComponent("extra.json"))
      } else if mode == "hardlink" {
        try FileManager.default.linkItem(
          at: artifact,
          to: root.appendingPathComponent(mode).appendingPathComponent("outside.json"))
      }
      #expect(throws: MeasurementRunnerError.self) {
        try MeasurementReferenceArtifactClosure.stage(
          sourceRoot: source, artifactRoot: output, expected: [expected])
      }
    }
  }

  @Test("rejects duplicate options")
  func rejectsDuplicateOption() {
    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementRunnerArguments.parse([
        "EasySplatMeasurementRunner",
        "--request", "/one",
        "--request", "/two",
      ])
    }
  }

  @Test("exports a current schema-20 pair graph and retrieval closure losslessly")
  func exportsLosslessPairList() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    let destination = root.appendingPathComponent("pair-list.json")
    let fixture = measurementPairGraphFixture()
    try JSONSerialization.data(withJSONObject: fixture.evidence, options: [.sortedKeys])
      .write(to: source)

    let result = try MeasurementPairListBuilder.write(
      source: source, selectedFrameCount: 4, to: destination)

    #expect(result.pairListDigest == fixture.pairDigest)
    #expect(result.attempts.map(\.matcher) == ["faiss"])
    #expect(result.localPairCount == 2)
    #expect(result.retrievalPairCount == 1)
    #expect(result.loopPairCount == 0)
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
    let attempts = try #require(output["attempts"] as? [[String: Any]])
    #expect(output["schema_version"] as? Int == 5)
    #expect(attempts[0]["exact_recovery_reason"] is NSNull)
    let retrieval = try #require(attempts[0]["retrieval"] as? [String: Any])
    #expect(retrieval["query_views"] as? [Int] == [0])
    let outcomes = try #require(retrieval["query_outcomes"] as? [[String: Any]])
    #expect(outcomes.count == 1)
    #expect(outcomes[0]["query_view"] as? Int == 0)
    #expect(outcomes[0]["status"] as? String == "ranked")
    #expect(outcomes[0]["ranked_neighbor_views"] as? [Int] == [3])
    #expect(retrieval["request_digest"] as? String == "sha256:\(fixture.requestDigest)")
    #expect(retrieval["output_digest"] as? String == "sha256:\(fixture.outputDigest)")
    let exportedPairs = try #require(output["pairs"] as? [[String: Any]])
    #expect(exportedPairs.map { $0["pair_type"] as? String } == ["local", "retrieval", "local"])
    #expect(exportedPairs[1]["query_view"] as? Int == 0)
    #expect(exportedPairs.allSatisfy { $0["attempted"] as? Bool == true })
  }

  @Test("rejects stale pair-graph schemas against the current source contract")
  func rejectsStalePairGraphSchema() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var stale = measurementPairGraphFixture().evidence
    stale["schemaVersion"] = 13
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    try JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys]).write(to: source)

    #expect(throws: MeasurementRunnerError.subprocessFailed(
      "pair-graph evidence does not match schema 20"
    )) {
      try MeasurementPairListBuilder.write(
        source: source,
        selectedFrameCount: 4,
        to: root.appendingPathComponent("pair-list.json")
      )
    }
  }

  @Test("bounds exact descriptor recovery to 256 scheduled pairs")
  func boundsExactDescriptorRecovery() {
    #expect(MeasurementPairListBuilder.permitsExactRecovery(scheduledPairCount: 256))
    #expect(!MeasurementPairListBuilder.permitsExactRecovery(scheduledPairCount: 257))
  }

  @Test("exports one typed exact recovery bound to its failed FAISS schedule")
  func exportsTypedExactRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    let destination = root.appendingPathComponent("pair-list.json")
    try JSONSerialization.data(
      withJSONObject: measurementExactRecoveryEvidence(),
      options: [.sortedKeys]
    ).write(to: source)

    let result = try MeasurementPairListBuilder.write(
      source: source, selectedFrameCount: 4, to: destination)

    #expect(result.attempts.map(\.matcher) == ["faiss", "exact"])
    #expect(result.attempts.map(\.exactRecoveryReason) == [nil, "faissCrash"])
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
    let attempts = try #require(output["attempts"] as? [[String: Any]])
    #expect(attempts[0]["exact_recovery_reason"] is NSNull)
    #expect(attempts[1]["exact_recovery_reason"] as? String == "faissCrash")
  }

  @Test("rejects repeated exact recovery even after the first exact attempt fails")
  func rejectsRepeatedExactRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    try JSONSerialization.data(
      withJSONObject: measurementExactRecoveryEvidence(repeatedExact: true),
      options: [.sortedKeys]
    ).write(to: source)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementPairListBuilder.write(
        source: source,
        selectedFrameCount: 4,
        to: root.appendingPathComponent("pair-list.json")
      )
    }
  }

  @Test("rejects pair-graph list, digest, and retrieval closure mutations")
  func rejectsMutatedPairGraphClosure() throws {
    let mutations: [(String, (inout [String: Any]) -> Void)] = [
      ("digest", { $0["pairListDigest"] = String(repeating: "f", count: 64) }),
      ("accepted list", { value in
        var inspection = value["acceptedInspection"] as! [String: Any]
        var pairs = inspection["rawMatchedPairs"] as! [[String: Any]]
        pairs.swapAt(0, 1)
        inspection["rawMatchedPairs"] = pairs
        value["acceptedInspection"] = inspection
      }),
      ("retrieval edge", { value in
        var attempts = value["attempts"] as! [[String: Any]]
        var retrieval = attempts[0]["retrieval"] as! [String: Any]
        retrieval["directedPairLines"] = ["c.jpg b.jpg"]
        attempts[0]["retrieval"] = retrieval
        value["attempts"] = attempts
      }),
      ("selected frames digest", {
        $0["selectedFramesDigest"] = String(repeating: "z", count: 64)
      }),
      ("plan binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding["pairingPolicy"] = "orderedContinuous"
        value["planBinding"] = binding
      }),
      ("geometry backend binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding["geometryBackend"] = "da3"
        value["planBinding"] = binding
      }),
      ("model binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding["modelIdentifier"] = "DA3-BASE"
        value["planBinding"] = binding
      }),
      ("cross-clip plan binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding["requiresCrossClipRetrieval"] = true
        value["planBinding"] = binding
      }),
      ("missing cross-clip plan binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding.removeValue(forKey: "requiresCrossClipRetrieval")
        value["planBinding"] = binding
      }),
      ("camera initialization plan binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding["cameraInitializationRecipe"] = "unknown"
        value["planBinding"] = binding
      }),
      ("missing camera initialization plan binding", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding.removeValue(forKey: "cameraInitializationRecipe")
        value["planBinding"] = binding
      }),
      ("out-of-range run seed", { value in
        var binding = value["planBinding"] as! [String: Any]
        binding["runSeed"] = Int64(Int32.max) + 1
        value["planBinding"] = binding
      }),
      ("retrieval scheduling", { $0["retrievalWasScheduled"] = false }),
      ("accepted retrieval flag", { $0["usedLocalVocabularyRetrieval"] = false }),
      ("matching duration", { $0["matchingDurationSeconds"] = 2.0 }),
      ("inspection role counts", { value in
        var inspection = value["acceptedInspection"] as! [String: Any]
        inspection["retrievalPairCount"] = 0
        value["acceptedInspection"] = inspection
      }),
      ("retrieval outcomes", { value in
        var attempts = value["attempts"] as! [[String: Any]]
        var retrieval = attempts[0]["retrieval"] as! [String: Any]
        retrieval["queryOutcomes"] = []
        attempts[0]["retrieval"] = retrieval
        value["attempts"] = attempts
      }),
      ("retrieval output digest", { value in
        var attempts = value["attempts"] as! [[String: Any]]
        var retrieval = attempts[0]["retrieval"] as! [String: Any]
        retrieval["outputDigest"] = String(repeating: "f", count: 64)
        attempts[0]["retrieval"] = retrieval
        value["attempts"] = attempts
      }),
      ("edge-only retrieval output digest", { value in
        var attempts = value["attempts"] as! [[String: Any]]
        var retrieval = attempts[0]["retrieval"] as! [String: Any]
        retrieval["outputDigest"] = measurementReceiptDigest(["a.jpg d.jpg"])
        attempts[0]["retrieval"] = retrieval
        value["attempts"] = attempts
      }),
      ("rehashed contradictory retrieval status", { value in
        var attempts = value["attempts"] as! [[String: Any]]
        var retrieval = attempts[0]["retrieval"] as! [String: Any]
        retrieval["queryOutcomes"] = [[
          "queryImageName": "a.jpg", "status": "noRankedNeighbors",
          "rankedNeighborImageNames": ["d.jpg"],
        ]]
        let requestDigest = measurementReceiptDigest([
          "localSiftVocabularyV2", "2", "20", "8", "0", "a.jpg",
        ])
        retrieval["outputDigest"] = measurementReceiptDigest([
          "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 8 0 1 "
            + requestDigest,
          "Q noRankedNeighbors a.jpg 1 d.jpg",
          "P a.jpg d.jpg",
        ])
        attempts[0]["retrieval"] = retrieval
        value["attempts"] = attempts
      }),
    ]
    for (label, mutate) in mutations {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      var evidence = measurementPairGraphFixture().evidence
      mutate(&evidence)
      let source = root.appendingPathComponent("pair_graph_evidence.json")
      try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        .write(to: source)
      #expect(throws: MeasurementRunnerError.self, "\(label)") {
        try MeasurementPairListBuilder.write(
          source: source,
          selectedFrameCount: 4,
          to: root.appendingPathComponent("pair-list.json")
        )
      }
    }
  }

  @Test("accepts zero-neighbor retrieval when the scheduled graph stays connected")
  func acceptsConnectedZeroNeighborRetrieval() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    let destination = root.appendingPathComponent("pair-list.json")
    try JSONSerialization.data(
      withJSONObject: measurementZeroNeighborEvidence(connected: true),
      options: [.sortedKeys]
    ).write(to: source)

    let result = try MeasurementPairListBuilder.write(
      source: source,
      selectedFrameCount: 4,
      to: destination
    )

    #expect(result.localPairCount == 3)
    #expect(result.retrievalPairCount == 0)
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
    )
    let attempts = try #require(output["attempts"] as? [[String: Any]])
    let retrieval = try #require(attempts[0]["retrieval"] as? [String: Any])
    #expect((retrieval["directed_pairs"] as? [[String: Any]])?.isEmpty == true)
    let outcomes = try #require(retrieval["query_outcomes"] as? [[String: Any]])
    #expect(outcomes.count == 1)
    #expect(outcomes[0]["query_view"] as? Int == 0)
    #expect(outcomes[0]["status"] as? String == "noRankedNeighbors")
    #expect(outcomes[0]["ranked_neighbor_views"] as? [Int] == [])
  }

  @Test("accepts short segmented multi-clip retrieval required by the resolved plan")
  func acceptsShortSegmentedCrossClipRetrieval() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var evidence = measurementPairGraphFixture().evidence
    evidence["pairingPolicy"] = "segmentedMixed"
    var binding = evidence["planBinding"] as! [String: Any]
    binding["pairingPolicy"] = "segmentedMixed"
    binding["temporalPairing"] = "linear"
    binding["temporalOffsets"] = [1]
    binding["requiresCrossClipRetrieval"] = true
    evidence["planBinding"] = binding
    let groupLines = ["a.jpg\t0", "b.jpg\t0", "c.jpg\t1", "d.jpg\t1"]
    let groupDigest = measurementReceiptDigest(["crossGroupV1"] + groupLines)
    let requestDigest = measurementReceiptDigest([
      "localSiftVocabularyV2", "2", "20", "8", "0", "crossGroupV1",
      groupDigest, "a.jpg",
    ])
    let outputDigest = measurementReceiptDigest([
      "EASYSPLAT_RETRIEVAL_OUTCOMES_V3 localSiftVocabularyV2 2 20 8 0 "
        + "crossGroupV1 \(groupDigest) 1 \(requestDigest)",
      "Q ranked a.jpg 1 d.jpg",
      "P a.jpg d.jpg",
    ])
    var attempts = evidence["attempts"] as! [[String: Any]]
    var attempt = attempts[0]
    var retrieval = attempt["retrieval"] as! [String: Any]
    retrieval["candidatePolicy"] = "crossGroupV1"
    retrieval["imageGroupListDigest"] = groupDigest
    retrieval["imageGroupLines"] = groupLines
    retrieval["outputDigest"] = outputDigest
    attempt["retrieval"] = retrieval
    attempts[0] = attempt
    evidence["attempts"] = attempts
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    let destination = root.appendingPathComponent("pair-list.json")
    try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
      .write(to: source)

    let result = try MeasurementPairListBuilder.write(
      source: source, selectedFrameCount: 4, to: destination)

    #expect(result.retrievalPairCount == 1)
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
    let exportedAttempts = try #require(output["attempts"] as? [[String: Any]])
    let exported = try #require(exportedAttempts[0]["retrieval"] as? [String: Any])
    #expect(exported["candidate_policy"] as? String == "crossGroupV1")
    #expect(exported["image_group_list_digest"] as? String == "sha256:\(groupDigest)")
  }

  @Test("rejects cross-clip group digest, membership, and same-group outcomes")
  func rejectsCrossClipRetrievalTampering() throws {
    for label in ["digest", "membership", "same-group"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      var evidence = measurementPairGraphFixture().evidence
      evidence["pairingPolicy"] = "orderedContinuous"
      var binding = evidence["planBinding"] as! [String: Any]
      binding["pairingPolicy"] = "orderedContinuous"
      binding["temporalPairing"] = "linear"
      binding["temporalOffsets"] = [1]
      binding["requiresCrossClipRetrieval"] = true
      evidence["planBinding"] = binding
      var attempts = evidence["attempts"] as! [[String: Any]]
      var attempt = attempts[0]
      var retrieval = attempt["retrieval"] as! [String: Any]
      let validLines = ["a.jpg\t0", "b.jpg\t0", "c.jpg\t1", "d.jpg\t1"]
      let lines = label == "membership"
        ? ["a.jpg\t0", "b.jpg\t0", "c.jpg\t0", "d.jpg\t1"] : validLines
      let validDigest = measurementReceiptDigest(["crossGroupV1"] + validLines)
      let validRequestDigest = measurementReceiptDigest([
        "localSiftVocabularyV2", "2", "20", "8", "0", "crossGroupV1",
        validDigest, "a.jpg",
      ])
      retrieval["candidatePolicy"] = "crossGroupV1"
      retrieval["imageGroupLines"] = lines
      retrieval["imageGroupListDigest"] = label == "digest"
        ? String(repeating: "f", count: 64) : validDigest
      retrieval["outputDigest"] = measurementReceiptDigest([
        "EASYSPLAT_RETRIEVAL_OUTCOMES_V3 localSiftVocabularyV2 2 20 8 0 "
          + "crossGroupV1 \(validDigest) 1 \(validRequestDigest)",
        "Q ranked a.jpg 1 d.jpg",
        "P a.jpg d.jpg",
      ])
      if label == "same-group" {
        retrieval["queryOutcomes"] = [[
          "queryImageName": "a.jpg", "status": "ranked",
          "rankedNeighborImageNames": ["b.jpg"],
        ]]
        retrieval["directedPairLines"] = []
        retrieval["outputDigest"] = measurementReceiptDigest([
          "EASYSPLAT_RETRIEVAL_OUTCOMES_V3 localSiftVocabularyV2 2 20 8 0 "
            + "crossGroupV1 \(validDigest) 1 \(validRequestDigest)",
          "Q ranked a.jpg 1 b.jpg",
        ])
      }
      attempt["retrieval"] = retrieval
      attempts[0] = attempt
      evidence["attempts"] = attempts
      let source = root.appendingPathComponent("pair_graph_evidence.json")
      try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        .write(to: source)

      #expect(throws: MeasurementRunnerError.self, "\(label)") {
        try MeasurementPairListBuilder.write(
          source: source,
          selectedFrameCount: 4,
          to: root.appendingPathComponent("pair-list.json"))
      }
    }
  }

  @Test("rejects a ranked temporal base edge even when no pair record is emitted")
  func rejectsRankedBaseEdge() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var evidence = measurementPairGraphFixture().evidence
    var attempts = evidence["attempts"] as! [[String: Any]]
    var attempt = attempts[0]
    var retrieval = attempt["retrieval"] as! [String: Any]
    let requestDigest = measurementReceiptDigest([
      "localSiftVocabularyV2", "2", "20", "8", "0", "a.jpg",
    ])
    retrieval["queryOutcomes"] = [[
      "queryImageName": "a.jpg", "status": "ranked",
      "rankedNeighborImageNames": ["b.jpg"],
    ]]
    retrieval["directedPairLines"] = []
    retrieval["outputDigest"] = measurementReceiptDigest([
      "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 8 0 1 \(requestDigest)",
      "Q ranked a.jpg 1 b.jpg",
    ])
    attempt["retrieval"] = retrieval
    attempts[0] = attempt
    evidence["attempts"] = attempts
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
      .write(to: source)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementPairListBuilder.write(
        source: source,
        selectedFrameCount: 4,
        to: root.appendingPathComponent("pair-list.json"))
    }
  }

  @Test("pair-list source reads reject swaps, hard links, symlinks, and restored mtimes")
  func pairListSourceReadIsDescriptorBound() throws {
    for attack in ["swap", "hard-link", "symlink", "restored-mtime"] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let canonical = root.appendingPathComponent("canonical.json")
      let source = root.appendingPathComponent("pair_graph_evidence.json")
      let sourceData = try JSONSerialization.data(
        withJSONObject: measurementPairGraphFixture().evidence,
        options: [.sortedKeys])
      try sourceData.write(to: canonical)
      switch attack {
      case "hard-link":
        try FileManager.default.linkItem(at: canonical, to: source)
      case "symlink":
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: canonical)
      default:
        try sourceData.write(to: source)
      }
      let hooks = MeasurementPairListBuilder.IOHooks(afterSourceRead: {
        switch attack {
        case "swap":
          let opened = root.appendingPathComponent("opened.json")
          try FileManager.default.moveItem(at: source, to: opened)
          try sourceData.write(to: source)
        case "restored-mtime":
          let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
          let modified = attributes[.modificationDate] as? Date
          var changed = sourceData
          changed[0] = changed[0] == 0x7B ? 0x5B : 0x7B
          let handle = try FileHandle(forWritingTo: source)
          try handle.write(contentsOf: changed)
          try handle.synchronize()
          try handle.close()
          if let modified {
            try FileManager.default.setAttributes(
              [.modificationDate: modified],
              ofItemAtPath: source.path)
          }
        default:
          break
        }
      })

      #expect(throws: MeasurementRunnerError.self, "\(attack)") {
        try MeasurementPairListBuilder.write(
          source: source,
          selectedFrameCount: 4,
          to: root.appendingPathComponent("pair-list.json"),
          hooks: hooks)
      }
      #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("pair-list.json").path))
    }
  }

  @Test("pair-list publication is exclusive and preserves raced replacements")
  func pairListDestinationPublicationIsDescriptorBound() throws {
    for attack in [
      "symlink", "hard-link", "staging-replacement", "parent-swap",
      "post-publish-swap",
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let displacedRoot = root.deletingLastPathComponent().appendingPathComponent(
        root.lastPathComponent + "-displaced")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: displacedRoot)
      }
      let source = root.appendingPathComponent("pair_graph_evidence.json")
      try JSONSerialization.data(
        withJSONObject: measurementPairGraphFixture().evidence,
        options: [.sortedKeys]).write(to: source)
      let destination = root.appendingPathComponent("pair-list.json")
      let external = root.appendingPathComponent("external.txt")
      let replacement = Data("replacement-must-survive".utf8)
      try replacement.write(to: external)
      let hooks = MeasurementPairListBuilder.IOHooks(
        beforeDestinationPublish: {
          switch attack {
          case "symlink":
            try FileManager.default.createSymbolicLink(
              at: destination,
              withDestinationURL: external)
          case "hard-link":
            try FileManager.default.linkItem(at: external, to: destination)
          case "staging-replacement":
            let staging = try #require(
              FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
              ).first { $0.lastPathComponent.hasPrefix(".easysplat-pair-list-") })
            let displaced = root.appendingPathComponent("displaced-staging.json")
            try FileManager.default.moveItem(at: staging, to: displaced)
            try replacement.write(to: staging)
          case "parent-swap":
            try FileManager.default.moveItem(at: root, to: displacedRoot)
            try FileManager.default.createDirectory(
              at: root,
              withIntermediateDirectories: false)
            try replacement.write(to: root.appendingPathComponent("marker.txt"))
          default:
            break
          }
        },
        afterDestinationPublish: {
          guard attack == "post-publish-swap" else { return }
          let displaced = root.appendingPathComponent("displaced.json")
          try FileManager.default.moveItem(at: destination, to: displaced)
          try replacement.write(to: destination)
        })

      #expect(throws: MeasurementRunnerError.self, "\(attack)") {
        try MeasurementPairListBuilder.write(
          source: source,
          selectedFrameCount: 4,
          to: destination,
          hooks: hooks)
      }
      if attack != "parent-swap" {
        #expect(try Data(contentsOf: external) == replacement)
      }
      if attack == "post-publish-swap" {
        #expect(try Data(contentsOf: destination) == replacement)
      } else if attack == "staging-replacement" {
        let survivor = try #require(
          FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
          ).first { $0.lastPathComponent.hasPrefix(".easysplat-pair-list-") })
        #expect(try Data(contentsOf: survivor) == replacement)
      } else if attack == "parent-swap" {
        #expect(try Data(contentsOf: root.appendingPathComponent("marker.txt")) == replacement)
      }
    }
  }

  @Test("accepts expanded and maximum retrieval limits from their recovery policy")
  func acceptsRecoverySpecificRetrievalLimits() throws {
    for fixture in [
      measurementRetrievalRecoveryFixture(level: "expanded", imageCount: 4),
      measurementRetrievalRecoveryFixture(level: "maximum", imageCount: 251),
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let source = root.appendingPathComponent("pair_graph_evidence.json")
      let destination = root.appendingPathComponent("pair-list.json")
      try JSONSerialization.data(withJSONObject: fixture.evidence, options: [.sortedKeys])
        .write(to: source)

      _ = try MeasurementPairListBuilder.write(
        source: source, selectedFrameCount: fixture.imageCount, to: destination)

      let output = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
      let attempts = try #require(output["attempts"] as? [[String: Any]])
      let retrieval = try #require(attempts[0]["retrieval"] as? [String: Any])
      #expect(retrieval["candidate_count"] as? Int == fixture.candidateCount)
      #expect(retrieval["returned_neighbor_count"] as? Int == fixture.neighborCount)
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var orderedExpanded = measurementZeroNeighborEvidence(connected: true)
    var attempts = orderedExpanded["attempts"] as! [[String: Any]]
    var artifact = attempts[0]["artifact"] as! [String: Any]
    artifact["recoveryLevel"] = "expanded"
    attempts[0]["artifact"] = artifact
    orderedExpanded["attempts"] = attempts
    orderedExpanded["fallbackReasons"] = ["normal graph was rejected"]
    let source = root.appendingPathComponent("ordered-expanded.json")
    try JSONSerialization.data(withJSONObject: orderedExpanded, options: [.sortedKeys])
      .write(to: source)
    _ = try MeasurementPairListBuilder.write(
      source: source,
      selectedFrameCount: 4,
      to: root.appendingPathComponent("ordered-expanded-pairs.json")
    )
  }

  @Test("rejects rehashed normal retrieval limits at denser recovery levels")
  func rejectsRecoverySpecificRetrievalLimitDrift() throws {
    for fixture in [
      measurementRetrievalRecoveryFixture(level: "expanded", imageCount: 4),
      measurementRetrievalRecoveryFixture(level: "maximum", imageCount: 251),
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      var evidence = fixture.evidence
      var attempts = evidence["attempts"] as! [[String: Any]]
      var retrieval = attempts[0]["retrieval"] as! [String: Any]
      retrieval["candidateCount"] = 20
      retrieval["returnedNeighborCount"] = 8
      let queryNames = retrieval["queryImageNames"] as! [String]
      let queryStride = retrieval["queryStride"] as! Int
      let minimumSeparation = retrieval["minimumFrameSeparation"] as! Int
      let requestDigest = measurementReceiptDigest([
        "localSiftVocabularyV2", String(queryStride), "20", "8",
        String(minimumSeparation),
      ] + queryNames)
      let outcomes = retrieval["queryOutcomes"] as! [[String: Any]]
      let directedPairs = retrieval["directedPairLines"] as! [String]
      let contractLines = [
        "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 \(queryStride) "
          + "20 8 \(minimumSeparation) \(queryNames.count) \(requestDigest)",
      ] + outcomes.map { outcome in
        let neighbors = outcome["rankedNeighborImageNames"] as! [String]
        return ([
          "Q", outcome["status"] as! String,
          outcome["queryImageName"] as! String, String(neighbors.count),
        ] + neighbors).joined(separator: " ")
      } + directedPairs.map { "P \($0)" }
      retrieval["outputDigest"] = measurementReceiptDigest(contractLines)
      attempts[0]["retrieval"] = retrieval
      evidence["attempts"] = attempts
      let source = root.appendingPathComponent("pair_graph_evidence.json")
      try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        .write(to: source)

      #expect(throws: MeasurementRunnerError.self) {
        try MeasurementPairListBuilder.write(
          source: source,
          selectedFrameCount: fixture.imageCount,
          to: root.appendingPathComponent("pair-list.json")
        )
      }
    }
  }

  @Test("accepts mapping-driven recovery that skips a rejected retrieval density")
  func acceptsMappingDrivenMaximumRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = measurementMappingDrivenRecoveryFixture()
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    let destination = root.appendingPathComponent("pair-list.json")
    try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: source)

    let result = try MeasurementPairListBuilder.write(
      source: source, selectedFrameCount: 4, to: destination)

    #expect(result.attempts.map(\.recoveryLevel) == ["normal", "maximum"])
    #expect(result.attempts.map(\.outcome) == ["completed", "completed"])
  }

  @Test("rejects mapping-driven density skips without the rejected recovery evidence")
  func rejectsUnjustifiedMappingDrivenRecoverySkip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var fixture = measurementMappingDrivenRecoveryFixture()
    fixture["fallbackReasons"] = ["normal mapping was rejected"]
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: source)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementPairListBuilder.write(
        source: source,
        selectedFrameCount: 4,
        to: root.appendingPathComponent("pair-list.json")
      )
    }
  }

  @Test("rejects a coherently rehashed retrieval pair absent from its ranked outcome")
  func rejectsContradictoryRetrievalOutcomeClosure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var evidence = measurementPairGraphFixture().evidence
    var attempts = evidence["attempts"] as! [[String: Any]]
    var attempt = attempts[0]
    var retrieval = attempt["retrieval"] as! [String: Any]
    retrieval["directedPairLines"] = ["a.jpg c.jpg"]
    let requestDigest = measurementReceiptDigest([
      "localSiftVocabularyV2", "2", "20", "8", "0", "a.jpg",
    ])
    retrieval["outputDigest"] = measurementReceiptDigest([
      "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 8 0 1 \(requestDigest)",
      "Q ranked a.jpg 1 d.jpg",
      "P a.jpg c.jpg",
    ])
    var scheduledPairs = attempt["scheduledPairs"] as! [[String: Any]]
    scheduledPairs[1]["secondImageName"] = "c.jpg"
    attempt["retrieval"] = retrieval
    attempt["scheduledPairs"] = scheduledPairs
    attempts[0] = attempt
    evidence["attempts"] = attempts
    var inspection = evidence["acceptedInspection"] as! [String: Any]
    inspection["attemptedPairs"] = scheduledPairs
    inspection["rawMatchedPairs"] = scheduledPairs
    inspection["spatiallyVerifiedPairs"] = scheduledPairs
    evidence["acceptedInspection"] = inspection
    evidence["pairListDigest"] = measurementScheduleDigest(scheduledPairs)
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: source)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementPairListBuilder.write(
        source: source,
        selectedFrameCount: 4,
        to: root.appendingPathComponent("pair-list.json")
      )
    }
  }

  @Test("permits secondary verified components only for denser ordered recovery")
  func bindsSecondaryVerifiedComponentPolicy() {
    #expect(!MeasurementPairListBuilder.permitsSecondaryVerifiedComponent(
      pairingPolicy: "unorderedRetrieval", recoveryLevel: "normal"))
    #expect(!MeasurementPairListBuilder.permitsSecondaryVerifiedComponent(
      pairingPolicy: "orderedOrbit", recoveryLevel: "normal"))
    #expect(MeasurementPairListBuilder.permitsSecondaryVerifiedComponent(
      pairingPolicy: "orderedOrbit", recoveryLevel: "expanded"))
    #expect(!MeasurementPairListBuilder.permitsSecondaryVerifiedComponent(
      pairingPolicy: "segmentedMixed", recoveryLevel: "expanded"))
  }

  @Test("rejects zero-neighbor retrieval when the scheduled graph is disconnected")
  func rejectsDisconnectedZeroNeighborRetrieval() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    try JSONSerialization.data(
      withJSONObject: measurementZeroNeighborEvidence(connected: false),
      options: [.sortedKeys]
    ).write(to: source)

    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementPairListBuilder.write(
        source: source,
        selectedFrameCount: 4,
        to: root.appendingPathComponent("pair-list.json")
      )
    }
  }

  @Test("exports ordered maximum recovery as exhaustive matching")
  func exportsOrderedMaximumRecoveryAsExhaustive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pair_graph_evidence.json")
    let destination = root.appendingPathComponent("pair-list.json")
    let fixture = measurementOrderedMaximumRecoveryFixture()
    try JSONSerialization.data(withJSONObject: fixture.evidence, options: [.sortedKeys])
      .write(to: source)

    let result = try MeasurementPairListBuilder.write(
      source: source, selectedFrameCount: 4, to: destination)

    #expect(result.pairListDigest == fixture.pairDigest)
    #expect(result.retrievalPairCount == 6)
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
    let pairs = try #require(output["pairs"] as? [[String: Any]])
    #expect(pairs.count == 6)
    #expect(pairs.allSatisfy { $0["pair_type"] as? String == "exhaustive" })
    #expect(pairs.allSatisfy { $0["query_view"] is NSNull })
    #expect(pairs.allSatisfy { $0["matcher_used"] as? String == "faiss" })
  }

  @Test("rejects unknown lanes")
  func rejectsUnknownLane() {
    #expect(throws: MeasurementRunnerError.self) {
      try MeasurementRunnerArguments.parse([
        "EasySplatMeasurementRunner",
        "--request", "/request",
        "--input", "/input",
        "--toolchain-root", "/toolchain",
        "--candidate-checkout-root", "/candidate",
        "--baseline-checkout-root", "/baseline",
        "--baseline-toolchain-root", "/baseline-toolchain",
        "--reference-config", "/reference",
        "--artifact-root", "/artifacts",
        "--lane", "developer_mac",
      ])
    }
  }

  @Test("overlay package binds one exact local checkout")
  func overlayPackageBindsCheckout() throws {
    let checkout = URL(fileURLWithPath: "/protected/Easy Splat", isDirectory: true)
    let manifest = try AdapterOverlayPackage.manifest(checkout: checkout)

    #expect(manifest.contains(#".package(name: "EasySplat", path: "/protected/Easy Splat")"#))
    #expect(manifest.contains(#".product(name: "EasySplatCore", package: "EasySplat")"#))
    #expect(!manifest.contains("http://"))
    #expect(!manifest.contains("https://"))
  }

  @Test("overlay package rejects source-injecting checkout paths")
  func overlayPackageRejectsInjection() {
    let checkout = URL(
      fileURLWithPath: #"/protected/evil"), .package(url: "https://example.com", from: "1.0.0")"#
    )
    #expect(throws: MeasurementRunnerError.self) {
      try AdapterOverlayPackage.manifest(checkout: checkout)
    }
  }
}

private func measurementPairGraphFixture() -> (
  evidence: [String: Any],
  pairDigest: String,
  requestDigest: String,
  outputDigest: String
) {
  func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  func receiptDigest(_ fields: [String]) -> String {
    var data = Data()
    for field in fields {
      let bytes = Data(field.utf8)
      data.append(Data("\(bytes.count):".utf8))
      data.append(bytes)
    }
    return sha256(data)
  }
  let pairs: [[String: Any]] = [
    ["firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"],
    ["firstImageName": "a.jpg", "secondImageName": "d.jpg", "role": "retrieval"],
    ["firstImageName": "c.jpg", "secondImageName": "d.jpg", "role": "local"],
  ]
  let pairDigest = sha256(Data("a.jpg b.jpg\na.jpg d.jpg\nc.jpg d.jpg\n".utf8))
  let requestDigest = receiptDigest([
    "localSiftVocabularyV2", "2", "20", "8", "0", "a.jpg",
  ])
  let outputDigest = receiptDigest([
    "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 8 0 1 \(requestDigest)",
    "Q ranked a.jpg 1 d.jpg",
    "P a.jpg d.jpg",
  ])
  return ([
    "schemaVersion": 20,
    "selectedFramesDigest": String(repeating: "1", count: 64),
    "imageNames": ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
    "pairingPolicy": "segmentedMixed",
    "planBinding": [
      "pairingPolicy": "segmentedMixed", "geometryBackend": "colmap",
      "modelIdentifier": "none", "temporalPairing": "linear",
      "temporalOffsets": [1, 2], "retrievalEngine": "localSiftVocabularyV2",
      "retrievalCandidateCount": 20, "retrievalNeighborCount": 8,
      "retrievalQueryStride": 2, "requiresCrossClipRetrieval": false,
      "normalDescriptorMatcher": "faiss",
      "cameraInitializationRecipe": "colmapAutomatic", "runSeed": 42,
    ],
    "attempts": [[
      "artifact": [
        "attemptNumber": 1, "matcher": "faiss", "recoveryLevel": "normal",
        "exactRecoveryReason": NSNull(),
        "outcome": "completed", "scheduledPairCount": 3, "attemptedPairCount": 3,
        "rawMatchedPairCount": 3, "spatiallyVerifiedPairCount": 3,
        "durationSeconds": 1.25,
      ],
      "scheduledPairs": pairs,
      "retrieval": [
        "engine": "localSiftVocabularyV2", "queryImageNames": ["a.jpg"],
        "queryStride": 2, "candidateCount": 20, "returnedNeighborCount": 8,
        "minimumFrameSeparation": 0,
        "queryOutcomes": [[
          "queryImageName": "a.jpg", "status": "ranked",
          "rankedNeighborImageNames": ["d.jpg"],
        ]],
        "directedPairLines": ["a.jpg d.jpg"], "outputDigest": outputDigest,
      ],
      "retrievalWasExecuted": true,
    ]],
    "acceptedAttemptNumber": 1,
    "acceptedInspection": [
      "scheduledPairCount": 3, "attemptedPairCount": 3, "rawMatchedPairCount": 3,
      "spatiallyVerifiedPairCount": 3, "localPairCount": 2, "retrievalPairCount": 1,
      "loopRevisitPairCount": 0, "connectedComponentCount": 1, "isolatedViewCount": 0,
      "descriptorlessViewCount": 0, "componentViewCounts": [4],
      "articulationViewCount": 2, "biconnectedBlockCount": 3,
      "largestBiconnectedBlockViewCount": 2, "secondLargestBiconnectedBlockViewCount": 2,
      "degreeP10": 1, "degreeMedian": 1, "degreeP90": 2,
      "featureDatabaseDigest": String(repeating: "2", count: 64),
      "matchingDatabaseDigest": String(repeating: "3", count: 64),
      "attemptedPairs": pairs,
      "rawMatchedPairs": pairs, "spatiallyVerifiedPairs": pairs,
    ],
    "retrievalWasScheduled": true,
    "usedLocalVocabularyRetrieval": true,
    "pairListDigest": pairDigest,
    "matchingDurationSeconds": 1.25,
    "fallbackReasons": [],
  ], pairDigest, requestDigest, outputDigest)
}

private func measurementZeroNeighborEvidence(connected: Bool) -> [String: Any] {
  var evidence = measurementPairGraphFixture().evidence
  let pairs: [[String: Any]] = connected
    ? [
      ["firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"],
      ["firstImageName": "b.jpg", "secondImageName": "c.jpg", "role": "local"],
      ["firstImageName": "c.jpg", "secondImageName": "d.jpg", "role": "local"],
    ]
    : [
      ["firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"],
      ["firstImageName": "a.jpg", "secondImageName": "c.jpg", "role": "local"],
      ["firstImageName": "b.jpg", "secondImageName": "c.jpg", "role": "local"],
    ]
  let requestDigest = measurementReceiptDigest([
    "localSiftVocabularyV2", "2", "20", "8", "12", "a.jpg",
  ])
  let outputDigest = measurementReceiptDigest([
    "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 2 20 8 12 1 \(requestDigest)",
    "Q noRankedNeighbors a.jpg 0",
  ])
  evidence["pairingPolicy"] = "orderedOrbit"
  var binding = evidence["planBinding"] as! [String: Any]
  binding["pairingPolicy"] = "orderedOrbit"
  binding["temporalPairing"] = "multiscale"
  binding["temporalOffsets"] = [1]
  evidence["planBinding"] = binding
  var attempts = evidence["attempts"] as! [[String: Any]]
  var attempt = attempts[0]
  var artifact = attempt["artifact"] as! [String: Any]
  artifact["scheduledPairCount"] = pairs.count
  artifact["attemptedPairCount"] = pairs.count
  artifact["rawMatchedPairCount"] = pairs.count
  artifact["spatiallyVerifiedPairCount"] = pairs.count
  attempt["artifact"] = artifact
  attempt["scheduledPairs"] = pairs
  attempt["retrieval"] = [
    "engine": "localSiftVocabularyV2", "queryImageNames": ["a.jpg"],
    "queryStride": 2, "candidateCount": 20, "returnedNeighborCount": 8,
    "minimumFrameSeparation": 12,
    "queryOutcomes": [[
      "queryImageName": "a.jpg", "status": "noRankedNeighbors",
      "rankedNeighborImageNames": [],
    ]],
    "directedPairLines": [], "outputDigest": outputDigest,
  ]
  attempts[0] = attempt
  evidence["attempts"] = attempts
  var inspection = evidence["acceptedInspection"] as! [String: Any]
  inspection["scheduledPairCount"] = pairs.count
  inspection["attemptedPairCount"] = pairs.count
  inspection["rawMatchedPairCount"] = pairs.count
  inspection["spatiallyVerifiedPairCount"] = pairs.count
  inspection["localPairCount"] = pairs.count
  inspection["retrievalPairCount"] = 0
  inspection["attemptedPairs"] = pairs
  inspection["rawMatchedPairs"] = pairs
  inspection["spatiallyVerifiedPairs"] = pairs
  evidence["acceptedInspection"] = inspection
  evidence["pairListDigest"] = measurementScheduleDigest(pairs)
  return evidence
}

private func measurementReceiptDigest(_ fields: [String]) -> String {
  var data = Data()
  for field in fields {
    let bytes = Data(field.utf8)
    data.append(Data("\(bytes.count):".utf8))
    data.append(bytes)
  }
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func measurementScheduleDigest(_ pairs: [[String: Any]]) -> String {
  let lines = pairs.map {
    "\($0["firstImageName"] as! String) \($0["secondImageName"] as! String)"
  }
  let data = Data((lines.joined(separator: "\n") + "\n").utf8)
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func measurementExactRecoveryEvidence(
  repeatedExact: Bool = false
) -> [String: Any] {
  var evidence = measurementPairGraphFixture().evidence
  var faiss = (evidence["attempts"] as! [[String: Any]])[0]
  var faissArtifact = faiss["artifact"] as! [String: Any]
  faissArtifact["outcome"] = "failed"
  faissArtifact["attemptedPairCount"] = 0
  faissArtifact["rawMatchedPairCount"] = 0
  faissArtifact["spatiallyVerifiedPairCount"] = 0
  faissArtifact["durationSeconds"] = 0.25
  faiss["artifact"] = faissArtifact

  var exact = (evidence["attempts"] as! [[String: Any]])[0]
  var exactArtifact = exact["artifact"] as! [String: Any]
  exactArtifact["attemptNumber"] = 2
  exactArtifact["matcher"] = "exact"
  exactArtifact["exactRecoveryReason"] = "faissCrash"
  exact["artifact"] = exactArtifact
  exact["retrievalWasExecuted"] = false

  var attempts = [faiss, exact]
  if repeatedExact {
    var failedExact = exact
    var failedArtifact = exactArtifact
    failedArtifact["outcome"] = "failed"
    failedArtifact["attemptedPairCount"] = 0
    failedArtifact["rawMatchedPairCount"] = 0
    failedArtifact["spatiallyVerifiedPairCount"] = 0
    failedArtifact["durationSeconds"] = 0.5
    failedExact["artifact"] = failedArtifact
    exactArtifact["attemptNumber"] = 3
    exact["artifact"] = exactArtifact
    attempts = [faiss, failedExact, exact]
  }
  evidence["attempts"] = attempts
  evidence["acceptedAttemptNumber"] = attempts.count
  evidence["matchingDurationSeconds"] = repeatedExact ? 2.0 : 1.5
  return evidence
}

private func measurementRetrievalRecoveryFixture(
  level: String,
  imageCount: Int
) -> (
  evidence: [String: Any], imageCount: Int, candidateCount: Int, neighborCount: Int
) {
  precondition(level == "expanded" || level == "maximum")
  precondition(level != "maximum" || imageCount > 250)
  let imageNames = (0..<imageCount).map { String(format: "frame-%03d.jpg", $0) }
  let candidateCount = level == "expanded" ? 40 : 80
  let neighborCount = level == "expanded" ? 16 : 32
  let queryStride = imageCount
  let requestDigest = measurementReceiptDigest([
    "localSiftVocabularyV2", String(queryStride), String(candidateCount),
    String(neighborCount), "0", imageNames[0],
  ])
  let outputDigest = measurementReceiptDigest([
    "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 \(queryStride) "
      + "\(candidateCount) \(neighborCount) 0 1 \(requestDigest)",
    "Q ranked \(imageNames[0]) 1 \(imageNames[imageCount - 1])",
    "P \(imageNames[0]) \(imageNames[imageCount - 1])",
  ])
  var pairs: [[String: Any]] = (0..<(imageCount - 1)).map { index in
    [
      "firstImageName": imageNames[index],
      "secondImageName": imageNames[index + 1],
      "role": "local",
    ]
  }
  pairs.append([
    "firstImageName": imageNames[0],
    "secondImageName": imageNames[imageCount - 1],
    "role": "retrieval",
  ])
  let imageIndex = Dictionary(
    uniqueKeysWithValues: imageNames.enumerated().map { ($0.element, $0.offset) })
  pairs.sort { lhs, rhs in
    let lhsEdge = (
      imageIndex[lhs["firstImageName"] as! String]!,
      imageIndex[lhs["secondImageName"] as! String]!)
    let rhsEdge = (
      imageIndex[rhs["firstImageName"] as! String]!,
      imageIndex[rhs["secondImageName"] as! String]!)
    return lhsEdge.0 < rhsEdge.0 || (lhsEdge.0 == rhsEdge.0 && lhsEdge.1 < rhsEdge.1)
  }
  let attempt: [String: Any] = [
    "artifact": [
      "attemptNumber": 1, "matcher": "faiss", "recoveryLevel": level,
      "exactRecoveryReason": NSNull(),
      "outcome": "completed", "scheduledPairCount": pairs.count,
      "attemptedPairCount": pairs.count, "rawMatchedPairCount": pairs.count,
      "spatiallyVerifiedPairCount": pairs.count, "durationSeconds": 1.0,
    ],
    "scheduledPairs": pairs,
    "retrieval": [
      "engine": "localSiftVocabularyV2", "queryImageNames": [imageNames[0]],
      "queryStride": queryStride, "candidateCount": candidateCount,
      "returnedNeighborCount": neighborCount, "minimumFrameSeparation": 0,
      "queryOutcomes": [[
        "queryImageName": imageNames[0], "status": "ranked",
        "rankedNeighborImageNames": [imageNames[imageCount - 1]],
      ]],
      "directedPairLines": ["\(imageNames[0]) \(imageNames[imageCount - 1])"],
      "outputDigest": outputDigest,
    ],
    "retrievalWasExecuted": true,
  ]
  let fallbackReasons = level == "expanded"
    ? ["normal graph was rejected"]
    : ["normal graph was rejected", "expanded graph was rejected"]
  return ([
    "schemaVersion": 20,
    "selectedFramesDigest": String(repeating: "1", count: 64),
    "imageNames": imageNames,
    "pairingPolicy": "segmentedMixed",
    "planBinding": [
      "pairingPolicy": "segmentedMixed", "geometryBackend": "colmap",
      "modelIdentifier": "none", "temporalPairing": "linear",
      "temporalOffsets": [1], "retrievalEngine": "localSiftVocabularyV2",
      "retrievalCandidateCount": 20, "retrievalNeighborCount": 8,
      "retrievalQueryStride": queryStride, "requiresCrossClipRetrieval": false,
      "normalDescriptorMatcher": "faiss",
      "cameraInitializationRecipe": "colmapAutomatic", "runSeed": 42,
    ],
    "attempts": [attempt],
    "acceptedAttemptNumber": 1,
    "acceptedInspection": [
      "scheduledPairCount": pairs.count, "attemptedPairCount": pairs.count,
      "rawMatchedPairCount": pairs.count, "spatiallyVerifiedPairCount": pairs.count,
      "localPairCount": imageCount - 1, "retrievalPairCount": 1,
      "loopRevisitPairCount": 0, "connectedComponentCount": 1,
      "isolatedViewCount": 0, "descriptorlessViewCount": 0,
      "componentViewCounts": [imageCount], "articulationViewCount": 0,
      "biconnectedBlockCount": 1, "largestBiconnectedBlockViewCount": imageCount,
      "secondLargestBiconnectedBlockViewCount": 0,
      "degreeP10": 2, "degreeMedian": 2, "degreeP90": 2,
      "featureDatabaseDigest": String(repeating: "2", count: 64),
      "matchingDatabaseDigest": String(repeating: "3", count: 64),
      "attemptedPairs": pairs, "rawMatchedPairs": pairs,
      "spatiallyVerifiedPairs": pairs,
    ],
    "retrievalWasScheduled": true,
    "usedLocalVocabularyRetrieval": true,
    "pairListDigest": measurementScheduleDigest(pairs),
    "matchingDurationSeconds": 1.0,
    "fallbackReasons": fallbackReasons,
  ], imageCount, candidateCount, neighborCount)
}

private func measurementMappingDrivenRecoveryFixture() -> [String: Any] {
  var maximum = measurementOrderedMaximumRecoveryFixture().evidence
  maximum["pairingPolicy"] = "orderedOrbit"
  var binding = maximum["planBinding"] as! [String: Any]
  binding["pairingPolicy"] = "orderedOrbit"
  binding["temporalPairing"] = "multiscale"
  maximum["planBinding"] = binding
  let imageNames = maximum["imageNames"] as! [String]
  let normalPairs: [[String: Any]] = [
    ["firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"],
    ["firstImageName": "b.jpg", "secondImageName": "c.jpg", "role": "local"],
    ["firstImageName": "c.jpg", "secondImageName": "d.jpg", "role": "local"],
  ]
  let requestDigest = measurementReceiptDigest([
    "localSiftVocabularyV2", "1", "20", "8", "12", imageNames[0],
    imageNames[1], imageNames[2], imageNames[3],
  ])
  let outputDigest = measurementReceiptDigest([
    "EASYSPLAT_RETRIEVAL_OUTCOMES_V2 localSiftVocabularyV2 1 20 8 12 4 \(requestDigest)",
    "Q noRankedNeighbors a.jpg 0",
    "Q noRankedNeighbors b.jpg 0",
    "Q noRankedNeighbors c.jpg 0",
    "Q noRankedNeighbors d.jpg 0",
  ])
  let normal: [String: Any] = [
    "artifact": [
      "attemptNumber": 1, "matcher": "faiss", "recoveryLevel": "normal",
      "exactRecoveryReason": NSNull(),
      "outcome": "completed", "scheduledPairCount": normalPairs.count,
      "attemptedPairCount": normalPairs.count, "rawMatchedPairCount": normalPairs.count,
      "spatiallyVerifiedPairCount": normalPairs.count, "durationSeconds": 1.0,
    ],
    "scheduledPairs": normalPairs,
    "retrieval": [
      "engine": "localSiftVocabularyV2", "queryImageNames": imageNames,
      "queryStride": 1, "candidateCount": 20, "returnedNeighborCount": 8,
      "minimumFrameSeparation": 12,
      "queryOutcomes": imageNames.map { name in
        [
          "queryImageName": name, "status": "noRankedNeighbors",
          "rankedNeighborImageNames": [],
        ] as [String: Any]
      },
      "directedPairLines": [], "outputDigest": outputDigest,
    ],
    "retrievalWasExecuted": true,
  ]
  let attempts = maximum["attempts"] as! [[String: Any]]
  var accepted = attempts[0]
  var acceptedArtifact = accepted["artifact"] as! [String: Any]
  acceptedArtifact["attemptNumber"] = 2
  accepted["artifact"] = acceptedArtifact
  maximum["attempts"] = [normal, accepted]
  maximum["acceptedAttemptNumber"] = 2
  maximum["matchingDurationSeconds"] = 2.0
  maximum["retrievalWasScheduled"] = true
  maximum["fallbackReasons"] = [
    "normal mapping was rejected", "expanded retrieval graph was disconnected",
  ]
  return maximum
}

private func measurementOrderedMaximumRecoveryFixture() -> (
  evidence: [String: Any], pairDigest: String
) {
  let imageNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
  let pairs: [[String: Any]] = imageNames.indices.flatMap { first in
    imageNames.indices.compactMap { second in
      guard first < second else { return nil }
      return [
        "firstImageName": imageNames[first],
        "secondImageName": imageNames[second],
        "role": "retrieval",
      ]
    }
  }
  let lines = pairs.map {
    "\($0["firstImageName"] as! String) \($0["secondImageName"] as! String)"
  }.joined(separator: "\n") + "\n"
  let pairDigest = SHA256.hash(data: Data(lines.utf8)).map {
    String(format: "%02x", $0)
  }.joined()
  let attempt: [String: Any] = [
    "artifact": [
      "attemptNumber": 1, "matcher": "faiss", "recoveryLevel": "maximum",
      "exactRecoveryReason": NSNull(),
      "outcome": "completed", "scheduledPairCount": 6, "attemptedPairCount": 6,
      "rawMatchedPairCount": 6, "spatiallyVerifiedPairCount": 6,
      "durationSeconds": 1.0,
    ],
    "scheduledPairs": pairs,
    "retrieval": NSNull(),
    "retrievalWasExecuted": false,
  ]
  return ([
    "schemaVersion": 20,
    "selectedFramesDigest": String(repeating: "1", count: 64),
    "imageNames": imageNames,
    "pairingPolicy": "orderedContinuous",
    "planBinding": [
      "pairingPolicy": "orderedContinuous", "geometryBackend": "colmap",
      "modelIdentifier": "none", "temporalPairing": "linear",
      "temporalOffsets": [1], "retrievalEngine": "localSiftVocabularyV2",
      "retrievalCandidateCount": 20, "retrievalNeighborCount": 8,
      "retrievalQueryStride": 1, "requiresCrossClipRetrieval": false,
      "normalDescriptorMatcher": "faiss",
      "cameraInitializationRecipe": "colmapAutomatic", "runSeed": 42,
    ],
    "attempts": [attempt],
    "acceptedAttemptNumber": 1,
    "acceptedInspection": [
      "scheduledPairCount": 6, "attemptedPairCount": 6, "rawMatchedPairCount": 6,
      "spatiallyVerifiedPairCount": 6, "localPairCount": 0, "retrievalPairCount": 6,
      "loopRevisitPairCount": 0, "connectedComponentCount": 1, "isolatedViewCount": 0,
      "descriptorlessViewCount": 0, "componentViewCounts": [4],
      "articulationViewCount": 0, "biconnectedBlockCount": 1,
      "largestBiconnectedBlockViewCount": 4, "secondLargestBiconnectedBlockViewCount": 0,
      "degreeP10": 3, "degreeMedian": 3, "degreeP90": 3,
      "featureDatabaseDigest": String(repeating: "2", count: 64),
      "matchingDatabaseDigest": String(repeating: "3", count: 64),
      "attemptedPairs": pairs,
      "rawMatchedPairs": pairs, "spatiallyVerifiedPairs": pairs,
    ],
    "retrievalWasScheduled": false,
    "usedLocalVocabularyRetrieval": false,
    "pairListDigest": pairDigest,
    "matchingDurationSeconds": 1.0,
    "fallbackReasons": ["normal graph rejected", "expanded graph rejected"],
  ], pairDigest)
}

private func writeMeasurementPNG(at url: URL) throws {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil,
      width: 8,
      height: 8,
      bitsPerComponent: 8,
      bytesPerRow: 32,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    throw CocoaError(.coderInvalidValue)
  }
  context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    throw CocoaError(.coderInvalidValue)
  }
  CGImageDestinationAddImage(
    destination,
    image,
    [kCGImagePropertyOrientation: 1] as CFDictionary
  )
  guard CGImageDestinationFinalize(destination) else {
    throw CocoaError(.fileWriteUnknown)
  }
}
