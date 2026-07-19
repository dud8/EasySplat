import CryptoKit
import Darwin
import Foundation

public enum MeasurementLane: String, Codable, Sendable {
  case reference = "reference_m4_max"
  case constrained = "constrained_14_16gb"
  case eightGB = "eight_gb_fast"
}

public enum MeasurementVariant: String, Sendable, Equatable {
  case baseline
  case candidate
  case fastCandidate = "fast_candidate"
  case accurateReference = "accurate_reference"
}

public enum MeasurementPhase: String, Sendable, Equatable {
  case ordinary
  case phase
  case fastProfile = "fast_profile"
  case candidate
  case invalidInput = "invalid_input"
}

public struct MeasurementRun: Sendable, Equatable {
  public let runID: String
  public let phase: MeasurementPhase
  public let variant: MeasurementVariant
  public let discarded: Bool
  public let publishesOutput: Bool
}

public enum MeasurementSchedule {
  public static func make(
    for lane: MeasurementLane,
    gateScopes: Set<String>,
    validOutcome: Bool
  ) -> [MeasurementRun] {
    guard validOutcome else {
      return [
        MeasurementRun(
          runID: "invalid-input-0",
          phase: .invalidInput,
          variant: .candidate,
          discarded: false,
          publishesOutput: false
        )
      ]
    }
    guard lane == .reference, gateScopes.contains("suite_performance")
      || gateScopes.contains("scene_quality")
    else {
      return candidateOnlyRuns()
    }

    let alternating: [MeasurementVariant] = [
      .baseline, .candidate,
      .baseline, .candidate,
      .candidate, .baseline,
      .baseline, .candidate,
    ]
    let phaseAlternating: [MeasurementVariant] = [
      .baseline, .candidate,
      .baseline, .candidate,
      .candidate, .baseline,
      .baseline, .candidate,
      .candidate, .baseline,
      .baseline, .candidate,
    ]
    let fastAlternating: [MeasurementVariant] = alternating.map {
      $0 == .baseline ? .accurateReference : .fastCandidate
    }
    var result: [MeasurementRun] = []
    result += runs(
      variants: alternating,
      phase: .ordinary,
      prefix: "ordinary",
      publishedIndex: alternating.count - 1
    )
    if gateScopes.contains("suite_performance") {
      result += runs(variants: phaseAlternating, phase: .phase, prefix: "phase")
    }
    result += runs(variants: fastAlternating, phase: .fastProfile, prefix: "fast-profile")
    return result
  }

  private static func candidateOnlyRuns() -> [MeasurementRun] {
    (0..<4).map { index in
      MeasurementRun(
        runID: "candidate-only-\(index)",
        phase: .candidate,
        variant: .candidate,
        discarded: index == 0,
        publishesOutput: index == 3
      )
    }
  }

  private static func runs(
    variants: [MeasurementVariant],
    phase: MeasurementPhase,
    prefix: String,
    publishedIndex: Int? = nil
  ) -> [MeasurementRun] {
    variants.enumerated().map { index, variant in
      MeasurementRun(
        runID: "\(prefix)-\(index)",
        phase: phase,
        variant: variant,
        discarded: index < 2,
        publishesOutput: index == publishedIndex
      )
    }
  }
}

public enum MeasurementOrientationMetricBoundary {
  private static let supervisorFields = [
    "orientation_status",
    "orientation_physical_up_error_degrees",
    "orientation_sign_correct",
  ]

  public static func reserveSupervisorFields(in metrics: inout [String: Any]) {
    for field in supervisorFields {
      metrics[field] = NSNull()
    }
  }
}

public struct MeasurementStableFileEvidence: Sendable, Equatable {
  public let data: Data
  public let sha256: String
  public var byteCount: Int { data.count }

  public func requiringSHA256(_ expected: String, label: String) throws -> Self {
    guard sha256 == expected else {
      throw MeasurementRunnerError.identityMismatch(
        "\(label) digest does not match published evidence")
    }
    return self
  }

  public static func read(
    _ url: URL,
    maximumBytes: Int
  ) throws -> Self {
    try read(url, maximumBytes: maximumBytes, afterRead: nil)
  }

  static func readForTesting(
    _ url: URL,
    maximumBytes: Int = 1_048_576,
    afterRead: @escaping () throws -> Void
  ) throws -> Self {
    try read(url, maximumBytes: maximumBytes, afterRead: afterRead)
  }

  private static func read(
    _ url: URL,
    maximumBytes: Int,
    afterRead: (() throws -> Void)?
  ) throws -> Self {
    guard url.isFileURL, maximumBytes > 0 else {
      throw MeasurementRunnerError.unsafePath("evidence path is invalid")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw MeasurementRunnerError.unsafePath(
        "evidence must be a bounded single-link regular file")
    }
    defer { Darwin.close(descriptor) }

    var opened = stat()
    var pathBefore = stat()
    guard fstat(descriptor, &opened) == 0,
      lstat(url.path, &pathBefore) == 0,
      isBoundedRegularFile(opened, maximumBytes: maximumBytes),
      sameFile(opened, pathBefore)
    else {
      throw MeasurementRunnerError.unsafePath(
        "evidence must be a bounded single-link regular file")
    }

    var hasher = SHA256()
    var data = Data()
    data.reserveCapacity(Int(opened.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
    while true {
      var count: Int
      repeat {
        count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
      } while count < 0 && errno == EINTR
      guard count >= 0 else {
        throw MeasurementRunnerError.unsafePath("evidence could not be read")
      }
      guard count > 0 else { break }
      guard data.count <= maximumBytes - count else {
        throw MeasurementRunnerError.unsafePath("evidence exceeds its size limit")
      }
      let chunk = Data(buffer.prefix(count))
      data.append(chunk)
      hasher.update(data: chunk)
    }
    guard !data.isEmpty else {
      throw MeasurementRunnerError.unsafePath("evidence is empty")
    }

    try afterRead?()

    var closedOver = stat()
    var pathAfter = stat()
    guard fstat(descriptor, &closedOver) == 0,
      lstat(url.path, &pathAfter) == 0,
      sameIdentity(opened, closedOver),
      sameIdentity(opened, pathAfter)
    else {
      throw MeasurementRunnerError.identityMismatch(
        "evidence changed while it was collected")
    }
    return Self(
      data: data,
      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
    )
  }

  private static func isBoundedRegularFile(_ value: stat, maximumBytes: Int) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG
      && value.st_nlink == 1
      && value.st_size > 0
      && value.st_size <= maximumBytes
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    (rhs.st_mode & S_IFMT) == S_IFREG
      && rhs.st_nlink == 1
      && lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    sameFile(lhs, rhs)
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
}

public struct MeasurementRuntimeManifestEvidence: Sendable, Equatable {
  public let worker: MeasurementStableFileEvidence
  public let geometry: MeasurementStableFileEvidence

  public static func capture(workerURL: URL, geometryURL: URL) throws -> Self {
    try capture(workerURL: workerURL, geometryURL: geometryURL, hooks: .init())
  }

  struct Hooks {
    var afterWorkerRead: () throws -> Void = {}
    var afterGeometryRead: () throws -> Void = {}
  }

  static func capture(
    workerURL: URL,
    geometryURL: URL,
    hooks: Hooks
  ) throws -> Self {
    let worker = try MeasurementStableFileEvidence.readForTesting(
      workerURL,
      maximumBytes: 2 * 1_024 * 1_024,
      afterRead: hooks.afterWorkerRead
    )
    let geometry = try MeasurementStableFileEvidence.readForTesting(
      geometryURL,
      maximumBytes: 1_048_576,
      afterRead: hooks.afterGeometryRead
    )
    return Self(worker: worker, geometry: geometry)
  }
}

public struct BoundMeasurementRequest: Decodable, Sendable, Equatable {
  public struct Binding: Decodable, Sendable, Equatable {
    public let profile: String
    public let sceneID: String
    public let scale: Int
    public let lane: MeasurementLane
    public let inputDigest: String
    public let gitCommit: String
    public let toolchainIdentity: String
    public let baselineGitCommit: String
    public let baselineToolchainIdentity: String

    private enum CodingKeys: String, CodingKey {
      case profile
      case sceneID = "scene_id"
      case scale
      case lane
      case inputDigest = "input_digest"
      case gitCommit = "git_commit"
      case toolchainIdentity = "toolchain_identity"
      case baselineGitCommit = "baseline_git_commit"
      case baselineToolchainIdentity = "baseline_toolchain_identity"
    }
  }

  public struct ExpectedOutcome: Decodable, Sendable, Equatable {
    public let kind: String
    public let failureType: String?

    private enum CodingKeys: String, CodingKey {
      case kind
      case failureType = "failure_type"
    }
  }

  public let schemaVersion: Int
  public let binding: Binding
  public let inputKind: String
  public let holdoutIndices: [Int]
  public let gateScopes: [String]
  public let expectedOutcome: ExpectedOutcome

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case binding
    case inputKind = "input_kind"
    case holdoutIndices = "holdout_indices"
    case gateScopes = "gate_scopes"
    case expectedOutcome = "expected_outcome"
  }

  public static func load(from url: URL, expectedLane: MeasurementLane) throws -> Self {
    let data = try BoundedMeasurementFile.read(url, maximumBytes: 2 * 1_024 * 1_024)
    let request: Self
    do {
      request = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw MeasurementRunnerError.invalidRequest("request JSON does not match schema 11")
    }
    guard request.schemaVersion == 11,
      request.binding.profile == "release",
      request.binding.lane == expectedLane,
      (1...3_000).contains(request.binding.scale),
      ["video", "multi_video", "photos", "mixed"].contains(request.inputKind),
      ["valid", "invalid"].contains(request.expectedOutcome.kind),
      request.gateScopes == request.gateScopes.sorted(),
      Set(request.gateScopes).count == request.gateScopes.count,
      !request.gateScopes.isEmpty,
      request.gateScopes.allSatisfy(Self.allowedGateScopes.contains),
      request.binding.sceneID.range(of: #"^[a-z0-9][a-z0-9_.-]{0,63}$"#, options: .regularExpression)
        != nil,
      isSHA256(request.binding.inputDigest),
      isSHA256(request.binding.toolchainIdentity),
      isSHA256(request.binding.baselineToolchainIdentity),
      isCommit(request.binding.gitCommit),
      isCommit(request.binding.baselineGitCommit),
      (request.expectedOutcome.kind == "valid" && request.expectedOutcome.failureType == nil)
        || (request.expectedOutcome.kind == "invalid"
          && request.expectedOutcome.failureType?.range(
            of: #"^[a-z0-9][a-z0-9_.-]{0,63}$"#,
            options: .regularExpression
          ) != nil)
    else {
      throw MeasurementRunnerError.invalidRequest("request binding is invalid")
    }
    if request.expectedOutcome.kind == "valid" {
      guard !request.gateScopes.contains("invalid_input"),
        !request.holdoutIndices.isEmpty,
        request.holdoutIndices == request.holdoutIndices.sorted(),
        Set(request.holdoutIndices).count == request.holdoutIndices.count,
        request.holdoutIndices.allSatisfy({ (0..<request.binding.scale).contains($0) })
      else {
        throw MeasurementRunnerError.invalidRequest("request holdout indices are invalid")
      }
      if request.inputKind == "video" {
        guard request.holdoutIndices == Array(stride(from: 4, to: request.binding.scale, by: 5))
        else {
          throw MeasurementRunnerError.invalidRequest("video holdout indices are invalid")
        }
      }
    } else if request.gateScopes != ["invalid_input"] || !request.holdoutIndices.isEmpty {
      throw MeasurementRunnerError.invalidRequest("invalid input binding is invalid")
    }
    return request
  }

  private static let allowedGateScopes: Set<String> = [
    "scene_quality", "scene_performance", "suite_performance", "long_sequence",
    "stability", "invalid_input", "toolchain",
  ]

  private static func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }

  private static func isCommit(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
  }
}

public struct MeasurementWorkerSet: Sendable, Equatable {
  public let candidate: URL
  public let baseline: URL
  public let accurateReference: URL

  public static func resolve(nextTo runner: URL) throws -> Self {
    let directory = runner.deletingLastPathComponent()
    let result = Self(
      candidate: directory.appendingPathComponent("PipelineMeasurementAdapter-current"),
      baseline: directory.appendingPathComponent("PipelineMeasurementAdapter-baseline"),
      accurateReference: directory.appendingPathComponent("AccurateReferenceMeasurementAdapter")
    )
    for (label, url) in [
      ("candidate", result.candidate),
      ("baseline", result.baseline),
      ("accurate reference", result.accurateReference),
    ] {
      try BoundedMeasurementFile.requireExecutable(url, label: label)
    }
    return result
  }
}

private enum BoundedMeasurementFile {
  static func read(_ url: URL, maximumBytes: Int) throws -> Data {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
    } catch {
      throw MeasurementRunnerError.unsafePath("request is unavailable")
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, (1...maximumBytes).contains(size)
    else {
      throw MeasurementRunnerError.unsafePath("request must be a bounded regular file")
    }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }

  static func requireExecutable(_ url: URL, label: String) throws {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch {
      throw MeasurementRunnerError.unsafePath("\(label) worker is unavailable")
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      FileManager.default.isExecutableFile(atPath: url.path)
    else {
      throw MeasurementRunnerError.unsafePath("\(label) worker must be a regular executable")
    }
  }
}

public enum MeasurementRunnerError: Error, LocalizedError, Equatable {
  case invalidArguments(String)
  case unsafePath(String)
  case invalidRequest(String)
  case identityMismatch(String)
  case subprocessFailed(String)
  case baselineAdapterUnavailable(String)
  case referenceExecutorUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .invalidArguments(let detail):
      return "Invalid measurement runner arguments: \(detail)"
    case .unsafePath(let detail):
      return "Unsafe measurement path: \(detail)"
    case .invalidRequest(let detail):
      return "Invalid bound measurement request: \(detail)"
    case .identityMismatch(let detail):
      return "Measurement identity mismatch: \(detail)"
    case .subprocessFailed(let detail):
      return "Measurement subprocess failed: \(detail)"
    case .baselineAdapterUnavailable(let detail):
      return "Pinned baseline adapter is unavailable: \(detail)"
    case .referenceExecutorUnavailable(let detail):
      return "Accurate reference executor is unavailable: \(detail)"
    }
  }
}

public struct MeasurementRunnerArguments: Sendable, Equatable {
  public let request: URL
  public let input: URL
  public let toolchainRoot: URL
  public let candidateCheckoutRoot: URL
  public let baselineCheckoutRoot: URL
  public let baselineToolchainRoot: URL
  public let referenceConfig: URL
  public let referenceArtifactRoot: URL?
  public let artifactRoot: URL
  public let lane: MeasurementLane

  private static let options = [
    "--request",
    "--input",
    "--toolchain-root",
    "--candidate-checkout-root",
    "--baseline-checkout-root",
    "--baseline-toolchain-root",
    "--reference-config",
    "--reference-artifact-root",
    "--artifact-root",
    "--lane",
  ]

  public static func parse(_ arguments: [String]) throws -> Self {
    guard arguments.count >= 1 else {
      throw MeasurementRunnerError.invalidArguments("missing executable name")
    }
    let values = Array(arguments.dropFirst())
    guard values.count.isMultiple(of: 2) else {
      throw MeasurementRunnerError.invalidArguments("every option requires one value")
    }
    var parsed: [String: String] = [:]
    for index in stride(from: 0, to: values.count, by: 2) {
      let option = values[index]
      guard options.contains(option) else {
        throw MeasurementRunnerError.invalidArguments("unknown option \(option)")
      }
      guard parsed[option] == nil else {
        throw MeasurementRunnerError.invalidArguments("duplicate option \(option)")
      }
      let value = values[index + 1]
      guard !value.isEmpty else {
        throw MeasurementRunnerError.invalidArguments("empty value for \(option)")
      }
      parsed[option] = value
    }
    let requiredOptions = options.filter { $0 != "--reference-artifact-root" }
    guard Set(requiredOptions).isSubset(of: parsed.keys) else {
      let missing = requiredOptions.filter { parsed[$0] == nil }.joined(separator: ", ")
      throw MeasurementRunnerError.invalidArguments("missing \(missing)")
    }
    guard let lane = MeasurementLane(rawValue: parsed["--lane"]!) else {
      throw MeasurementRunnerError.invalidArguments("unknown lane")
    }
    func fileURL(_ option: String, directory: Bool = false) -> URL {
      URL(fileURLWithPath: parsed[option]!, isDirectory: directory)
    }
    return Self(
      request: fileURL("--request"),
      input: fileURL("--input"),
      toolchainRoot: fileURL("--toolchain-root", directory: true),
      candidateCheckoutRoot: fileURL("--candidate-checkout-root", directory: true),
      baselineCheckoutRoot: fileURL("--baseline-checkout-root", directory: true),
      baselineToolchainRoot: fileURL("--baseline-toolchain-root", directory: true),
      referenceConfig: fileURL("--reference-config"),
      referenceArtifactRoot: parsed["--reference-artifact-root"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      },
      artifactRoot: fileURL("--artifact-root", directory: true),
      lane: lane
    )
  }
}

public struct MeasurementReferenceArtifactClosure: Sendable {
  public struct ExpectedArtifact: Sendable, Equatable {
    public let filename: String
    public let sha256: String

    public init(filename: String, sha256: String) {
      self.filename = filename
      self.sha256 = sha256
    }
  }

  private struct Identity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
  }

  private let sourceRoot: URL
  private let artifactRoot: URL
  private let rootIdentity: Identity
  private let fileIdentities: [String: Identity]
  private let stagedFileIdentities: [String: Identity]
  private let expected: [ExpectedArtifact]

  public static func stage(
    sourceRoot: URL,
    artifactRoot: URL,
    expected: [ExpectedArtifact]
  ) throws -> Self {
    guard !expected.isEmpty, expected.map(\.filename) == expected.map(\.filename).sorted(),
      Set(expected.map(\.filename)).count == expected.count
    else {
      throw MeasurementRunnerError.invalidRequest("reference artifact closure is not canonical")
    }
    guard expected.allSatisfy({
      $0.filename.range(of: #"^[a-z0-9][a-z0-9-]*\.json$"#, options: .regularExpression)
        != nil
        && $0.sha256.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }) else {
      throw MeasurementRunnerError.invalidRequest("reference artifact declaration is invalid")
    }

    let rootIdentity = try directoryIdentity(sourceRoot, label: "reference artifact root")
    let expandedExpected = try expandExpectedArtifacts(expected, sourceRoot: sourceRoot)
    let expectedNames = Set(expandedExpected.map(\.filename))
    let names = try recursiveRegularFiles(sourceRoot)
    guard Set(names) == expectedNames else {
      throw MeasurementRunnerError.unsafePath(
        "reference artifact root must contain exactly the protected closure")
    }

    var fileIdentities: [String: Identity] = [:]
    var stagedFileIdentities: [String: Identity] = [:]
    var totalBytes: Int64 = 0
    for artifact in expandedExpected {
      let source = sourceRoot.appendingPathComponent(artifact.filename)
      let identity = try regularFileIdentity(source, label: artifact.filename)
      guard (1...(64 * 1_024 * 1_024)).contains(identity.size) else {
        throw MeasurementRunnerError.unsafePath("\(artifact.filename) exceeds its size budget")
      }
      totalBytes += identity.size
      guard totalBytes <= 256 * 1_024 * 1_024 else {
        throw MeasurementRunnerError.unsafePath("reference artifact closure exceeds its size budget")
      }
      let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
      guard "sha256:\(SHA256.hash(data: bytes).hexDigest)" == artifact.sha256 else {
        throw MeasurementRunnerError.identityMismatch(
          "\(artifact.filename) does not match the protected request")
      }
      if artifact.filename.hasSuffix(".json") {
        try requireJSONSchema(bytes, label: artifact.filename)
      }
      let destination = artifactRoot.appendingPathComponent(artifact.filename)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw MeasurementRunnerError.unsafePath("\(artifact.filename) destination already exists")
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
      let stagedIdentity = try regularFileIdentity(destination, label: artifact.filename)
      guard stagedIdentity.size == identity.size else {
        throw MeasurementRunnerError.identityMismatch("\(artifact.filename) staging changed bytes")
      }
      let stagedBytes = try Data(contentsOf: destination, options: .mappedIfSafe)
      guard SHA256.hash(data: stagedBytes) == SHA256.hash(data: bytes) else {
        throw MeasurementRunnerError.identityMismatch("\(artifact.filename) staging changed bytes")
      }
      fileIdentities[artifact.filename] = identity
      stagedFileIdentities[artifact.filename] = stagedIdentity
    }
    let closure = Self(
      sourceRoot: sourceRoot,
      artifactRoot: artifactRoot,
      rootIdentity: rootIdentity,
      fileIdentities: fileIdentities,
      stagedFileIdentities: stagedFileIdentities,
      expected: expandedExpected
    )
    try closure.reverify()
    return closure
  }

  public func reverify() throws {
    guard try Self.directoryIdentity(sourceRoot, label: "reference artifact root") == rootIdentity,
      Set(try Self.recursiveRegularFiles(sourceRoot)) == Set(expected.map(\.filename))
    else {
      throw MeasurementRunnerError.identityMismatch("reference artifact root changed during measurement")
    }
    for artifact in expected {
      let source = sourceRoot.appendingPathComponent(artifact.filename)
      guard try Self.regularFileIdentity(source, label: artifact.filename)
        == fileIdentities[artifact.filename]
      else {
        throw MeasurementRunnerError.identityMismatch(
          "\(artifact.filename) changed during measurement")
      }
      let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
      guard "sha256:\(SHA256.hash(data: bytes).hexDigest)" == artifact.sha256 else {
        throw MeasurementRunnerError.identityMismatch(
          "\(artifact.filename) changed during measurement")
      }
      let staged = artifactRoot.appendingPathComponent(artifact.filename)
      guard try Self.regularFileIdentity(staged, label: artifact.filename)
        == stagedFileIdentities[artifact.filename]
      else {
        throw MeasurementRunnerError.identityMismatch(
          "staged \(artifact.filename) changed during measurement")
      }
      let stagedBytes = try Data(contentsOf: staged, options: .mappedIfSafe)
      guard "sha256:\(SHA256.hash(data: stagedBytes).hexDigest)" == artifact.sha256 else {
        throw MeasurementRunnerError.identityMismatch(
          "staged \(artifact.filename) changed during measurement")
      }
    }
  }

  private static func expandExpectedArtifacts(
    _ expected: [ExpectedArtifact],
    sourceRoot: URL
  ) throws -> [ExpectedArtifact] {
    var expanded = Dictionary(uniqueKeysWithValues: expected.map { ($0.filename, $0) })
    guard let preparation = expanded["ground-truth-preparation.json"] else {
      return expected
    }
    let preparationURL = sourceRoot.appendingPathComponent(preparation.filename)
    _ = try regularFileIdentity(preparationURL, label: preparation.filename)
    let bytes = try Data(contentsOf: preparationURL, options: .mappedIfSafe)
    guard "sha256:\(SHA256.hash(data: bytes).hexDigest)" == preparation.sha256 else {
      throw MeasurementRunnerError.identityMismatch(
        "ground-truth-preparation.json does not match the protected request")
    }
    try requireJSONSchema(bytes, label: preparation.filename)
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let views = object["views"] as? [[String: Any]], !views.isEmpty
    else {
      throw MeasurementRunnerError.invalidRequest(
        "ground-truth-preparation.json does not declare rendering views")
    }
    for (index, view) in views.enumerated() {
      for field in ["source", "target"] {
        guard let descriptor = view[field] as? [String: Any],
          let path = descriptor["path"] as? String,
          let digest = descriptor["sha256"] as? String,
          isSafeRenderingPath(path),
          digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
          throw MeasurementRunnerError.invalidRequest(
            "ground-truth-preparation.json views[\(index)].\(field) is invalid")
        }
        let artifact = ExpectedArtifact(filename: path, sha256: digest)
        if let existing = expanded[path], existing != artifact {
          throw MeasurementRunnerError.invalidRequest(
            "ground-truth-preparation.json binds conflicting rendering assets")
        }
        expanded[path] = artifact
      }
    }
    return expanded.values.sorted { $0.filename < $1.filename }
  }

  private static func isSafeRenderingPath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 3
      && parts[0] == "rendering"
      && ["source", "ground-truth"].contains(String(parts[1]))
      && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
  }

  private static func recursiveRegularFiles(_ root: URL) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else {
      throw MeasurementRunnerError.unsafePath("reference artifact root cannot be enumerated")
    }
    let resolvedRootPath = try canonicalPath(root, label: "reference artifact root")
    let rootPath = resolvedRootPath.hasSuffix("/")
      ? String(resolvedRootPath.dropLast()) : resolvedRootPath
    var result: [String] = []
    for case let entry as URL in enumerator {
      let prefix = rootPath + "/"
      guard entry.path.hasPrefix(prefix) else {
        throw MeasurementRunnerError.unsafePath("reference artifact entry escapes its root")
      }
      let relative = String(entry.path.dropFirst(prefix.count))
      var value = stat()
      guard lstat(entry.path, &value) == 0 else {
        throw MeasurementRunnerError.unsafePath("reference artifact entry is unreadable")
      }
      let kind = value.st_mode & S_IFMT
      if kind == S_IFDIR { continue }
      guard kind == S_IFREG, value.st_nlink == 1 else {
        throw MeasurementRunnerError.unsafePath(
          "reference artifact closure contains a link or special file")
      }
      result.append(relative)
    }
    return result.sorted()
  }

  private static func requireJSONSchema(_ bytes: Data, label: String) throws {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: bytes)
    } catch {
      throw MeasurementRunnerError.invalidRequest("\(label) is not JSON")
    }
    guard let mapping = object as? [String: Any],
      let schema = mapping["schema_version"] as? NSNumber,
      CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.intValue > 0
    else {
      throw MeasurementRunnerError.invalidRequest(
        "\(label) does not declare a positive schema_version")
    }
  }

  private static func canonicalPath(_ url: URL, label: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = url.path.withCString { pointer in
      realpath(pointer, &buffer) != nil
    }
    guard resolved else {
      throw MeasurementRunnerError.unsafePath("\(label) cannot be resolved")
    }
    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
    return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func directoryIdentity(_ url: URL, label: String) throws -> Identity {
    var value = stat()
    guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
      throw MeasurementRunnerError.unsafePath("\(label) must be a plain directory")
    }
    let canonical = try canonicalPath(url, label: label)
    let supplied = url.standardizedFileURL.path
    let systemTemporaryAlias = supplied.hasPrefix("/var/") && canonical == "/private" + supplied
    guard canonical == supplied || systemTemporaryAlias else {
      throw MeasurementRunnerError.unsafePath("\(label) cannot contain symbolic links")
    }
    return identity(value)
  }

  private static func regularFileIdentity(_ url: URL, label: String) throws -> Identity {
    var value = stat()
    guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
      value.st_nlink == 1
    else {
      throw MeasurementRunnerError.unsafePath("\(label) must be a single-link regular file")
    }
    return identity(value)
  }

  private static func identity(_ value: stat) -> Identity {
    Identity(
      device: UInt64(value.st_dev),
      inode: UInt64(value.st_ino),
      size: value.st_size,
      modificationSeconds: Int64(value.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
      changeSeconds: Int64(value.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
    )
  }
}

private extension Digest {
  var hexDigest: String { map { String(format: "%02x", $0) }.joined() }
}

public enum AdapterOverlayPackage {
  public static func manifest(checkout: URL) throws -> String {
    let path = checkout.standardizedFileURL.path
    guard checkout.isFileURL,
      path.hasPrefix("/"),
      !path.contains("\"") && !path.contains("\\"),
      path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw MeasurementRunnerError.unsafePath("checkout path cannot be represented safely")
    }
    return """
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
          name: "EasySplatPipelineMeasurementOverlay",
          platforms: [.macOS(.v15)],
          dependencies: [.package(name: "EasySplat", path: "\(path)")],
          targets: [
              .executableTarget(
                  name: "PipelineMeasurementAdapter",
                  dependencies: [.product(name: "EasySplatCore", package: "EasySplat")]
              )
          ]
      )
      """
  }
}

public struct MeasurementWorkerInvocation: Sendable, Equatable {
  public let executable: URL
  public let request: URL
  public let input: URL
  public let toolchainRoot: URL
  public let projectRoot: URL
  public let variant: MeasurementVariant
  public let envelope: URL
  public let stdoutLog: URL
  public let stderrLog: URL

  public init(
    executable: URL,
    request: URL,
    input: URL,
    toolchainRoot: URL,
    projectRoot: URL,
    variant: MeasurementVariant,
    envelope: URL,
    stdoutLog: URL,
    stderrLog: URL
  ) {
    self.executable = executable
    self.request = request
    self.input = input
    self.toolchainRoot = toolchainRoot
    self.projectRoot = projectRoot
    self.variant = variant
    self.envelope = envelope
    self.stdoutLog = stdoutLog
    self.stderrLog = stderrLog
  }
}

public struct MeasurementWorkerExecution: Sendable, Equatable {
  public let variant: MeasurementVariant
  public let startedMonotonicSeconds: Double
  public let endedMonotonicSeconds: Double
  public let exitCode: Int32
  public let userCPUMicroseconds: UInt64
  public let systemCPUMicroseconds: UInt64
  public let memorySamples: [MeasurementMemorySample]
  public let outputPLY: URL
  public let outputSHA256: String
  public let stageSeconds: [String: Double]
}

public struct MeasurementMemorySample: Sendable, Equatable {
  public let elapsedSeconds: Double
  public let processTreeResidentBytes: UInt64
  public let metalAllocatedBytes: UInt64
}

public struct MeasurementWorkerFailureExecution: Sendable, Equatable {
  public let startedMonotonicSeconds: Double
  public let endedMonotonicSeconds: Double
  public let exitCode: Int32
  public let userCPUMicroseconds: UInt64
  public let systemCPUMicroseconds: UInt64
  public let stderrSHA256: String
  public let failureType: String
  public let failureReceiptSHA256: String
}

public enum MeasurementWorkerExecutor {
  public static func runExpectedFailure(_ invocation: MeasurementWorkerInvocation) throws
    -> MeasurementWorkerFailureExecution
  {
    let fileManager = FileManager.default
    try BoundedMeasurementFile.requireExecutable(invocation.executable, label: "pipeline")
    for (url, label) in [
      (invocation.projectRoot, "project root"),
      (invocation.envelope, "worker envelope"),
      (invocation.stdoutLog, "worker stdout"),
      (invocation.stderrLog, "worker stderr"),
    ] where fileManager.fileExists(atPath: url.path) || url.isSymbolicLink {
      throw MeasurementRunnerError.unsafePath("\(label) must not already exist")
    }
    try fileManager.createDirectory(
      at: invocation.projectRoot.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard fileManager.createFile(atPath: invocation.stdoutLog.path, contents: nil),
      fileManager.createFile(atPath: invocation.stderrLog.path, contents: nil)
    else {
      throw MeasurementRunnerError.unsafePath("worker logs could not be created")
    }
    let stdout = try FileHandle(forWritingTo: invocation.stdoutLog)
    let stderr = try FileHandle(forWritingTo: invocation.stderrLog)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    let process = configuredProcess(invocation, stdout: stdout, stderr: stderr)
    var usageBefore = rusage()
    guard getrusage(RUSAGE_CHILDREN, &usageBefore) == 0 else {
      throw MeasurementRunnerError.subprocessFailed("child CPU baseline is unavailable")
    }
    let started = ProcessInfo.processInfo.systemUptime
    do {
      try process.run()
    } catch {
      throw MeasurementRunnerError.subprocessFailed("worker could not start")
    }
    process.waitUntilExit()
    let ended = ProcessInfo.processInfo.systemUptime
    var usageAfter = rusage()
    guard getrusage(RUSAGE_CHILDREN, &usageAfter) == 0 else {
      throw MeasurementRunnerError.subprocessFailed("child CPU receipt is unavailable")
    }
    guard process.terminationReason == .exit, process.terminationStatus != 0 else {
      throw MeasurementRunnerError.subprocessFailed(
        "invalid input did not produce a clean nonzero rejection"
      )
    }
    let output = invocation.projectRoot.appendingPathComponent("Output/splat.ply")
    guard !fileManager.fileExists(atPath: output.path), !output.isSymbolicLink
    else {
      throw MeasurementRunnerError.identityMismatch(
        "invalid-input worker published a success artifact"
      )
    }
    guard fileManager.fileExists(atPath: invocation.envelope.path)
      || invocation.envelope.isSymbolicLink
    else {
      throw MeasurementRunnerError.subprocessFailed(
        "invalid-input worker did not publish a typed rejection receipt"
      )
    }
    let receipt = try MeasurementStableFileEvidence.read(
      invocation.envelope,
      maximumBytes: 4_096
    )
    let raw: [String: Any]
    do {
      guard let object = try JSONSerialization.jsonObject(with: receipt.data) as? [String: Any]
      else {
        throw MeasurementRunnerError.subprocessFailed(
          "invalid-input rejection receipt is not an object"
        )
      }
      raw = object
    } catch let error as MeasurementRunnerError {
      throw error
    } catch {
      throw MeasurementRunnerError.subprocessFailed(
        "invalid-input rejection receipt is invalid JSON"
      )
    }
    let fields: Set<String> = [
      "schema_version", "kind", "variant", "request_sha256", "failure_type",
    ]
    guard Set(raw.keys) == fields,
      let schemaVersion = raw["schema_version"] as? NSNumber,
      String(cString: schemaVersion.objCType) != "c",
      schemaVersion.intValue == 1,
      raw["kind"] as? String == "invalid_input_rejection",
      raw["variant"] as? String == invocation.variant.rawValue,
      let requestSHA256 = raw["request_sha256"] as? String,
      requestSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      requestSHA256 == (try sha256(invocation.request)),
      let failureType = raw["failure_type"] as? String,
      failureType.range(
        of: #"^[a-z0-9][a-z0-9_.-]{0,63}$"#,
        options: .regularExpression
      ) != nil
    else {
      throw MeasurementRunnerError.subprocessFailed(
        "invalid-input rejection receipt fields are invalid"
      )
    }
    return MeasurementWorkerFailureExecution(
      startedMonotonicSeconds: started,
      endedMonotonicSeconds: ended,
      exitCode: process.terminationStatus,
      userCPUMicroseconds: try elapsedMicroseconds(
        from: usageBefore.ru_utime,
        to: usageAfter.ru_utime
      ),
      systemCPUMicroseconds: try elapsedMicroseconds(
        from: usageBefore.ru_stime,
        to: usageAfter.ru_stime
      ),
      stderrSHA256: try sha256(invocation.stderrLog),
      failureType: failureType,
      failureReceiptSHA256: receipt.sha256
    )
  }

  public static func run(_ invocation: MeasurementWorkerInvocation) throws
    -> MeasurementWorkerExecution
  {
    let fileManager = FileManager.default
    try BoundedMeasurementFile.requireExecutable(invocation.executable, label: "pipeline")
    for (url, label) in [
      (invocation.projectRoot, "project root"),
      (invocation.envelope, "worker envelope"),
      (invocation.stdoutLog, "worker stdout"),
      (invocation.stderrLog, "worker stderr"),
    ] where fileManager.fileExists(atPath: url.path) || url.isSymbolicLink {
      throw MeasurementRunnerError.unsafePath("\(label) must not already exist")
    }
    try fileManager.createDirectory(
      at: invocation.projectRoot.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard fileManager.createFile(atPath: invocation.stdoutLog.path, contents: nil),
      fileManager.createFile(atPath: invocation.stderrLog.path, contents: nil)
    else {
      throw MeasurementRunnerError.unsafePath("worker logs could not be created")
    }
    let stdout = try FileHandle(forWritingTo: invocation.stdoutLog)
    let stderr = try FileHandle(forWritingTo: invocation.stderrLog)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    let process = configuredProcess(invocation, stdout: stdout, stderr: stderr)
    var usageBefore = rusage()
    guard getrusage(RUSAGE_CHILDREN, &usageBefore) == 0 else {
      throw MeasurementRunnerError.subprocessFailed("child CPU baseline is unavailable")
    }
    let started = ProcessInfo.processInfo.systemUptime
    do {
      try process.run()
    } catch {
      throw MeasurementRunnerError.subprocessFailed("worker could not start")
    }
    var memorySamples: [MeasurementMemorySample] = []
    var lastResidentBytes: UInt64 = 0
    while process.isRunning {
      let residentBytes = processTreeResidentBytes(rootPID: process.processIdentifier)
      if residentBytes > 0 {
        lastResidentBytes = residentBytes
      }
      memorySamples.append(
        MeasurementMemorySample(
          elapsedSeconds: memorySamples.isEmpty
            ? 0
            : ProcessInfo.processInfo.systemUptime - started,
          processTreeResidentBytes: lastResidentBytes,
          metalAllocatedBytes: 0
        )
      )
      usleep(500_000)
    }
    process.waitUntilExit()
    let ended = ProcessInfo.processInfo.systemUptime
    let duration = ended - started
    if memorySamples.last?.elapsedSeconds != duration {
      memorySamples.append(
        MeasurementMemorySample(
          elapsedSeconds: duration,
          processTreeResidentBytes: lastResidentBytes,
          metalAllocatedBytes: 0
        )
      )
    }
    var usageAfter = rusage()
    guard getrusage(RUSAGE_CHILDREN, &usageAfter) == 0 else {
      throw MeasurementRunnerError.subprocessFailed("child CPU receipt is unavailable")
    }
    let userCPU = try elapsedMicroseconds(from: usageBefore.ru_utime, to: usageAfter.ru_utime)
    let systemCPU = try elapsedMicroseconds(from: usageBefore.ru_stime, to: usageAfter.ru_stime)
    guard memorySamples.allSatisfy({ $0.processTreeResidentBytes > 0 }) else {
      throw MeasurementRunnerError.subprocessFailed("worker resident-memory sample is unavailable")
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw MeasurementRunnerError.subprocessFailed(
        "worker exited with status \(process.terminationStatus)"
      )
    }
    let data = try BoundedMeasurementFile.read(invocation.envelope, maximumBytes: 2 * 1_024 * 1_024)
    let raw: [String: Any]
    do {
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MeasurementRunnerError.subprocessFailed("worker envelope is not an object")
      }
      raw = value
    } catch let error as MeasurementRunnerError {
      throw error
    } catch {
      throw MeasurementRunnerError.subprocessFailed("worker envelope is invalid JSON")
    }
    guard (raw["schema_version"] as? NSNumber)?.intValue == 1,
      raw["variant"] as? String == invocation.variant.rawValue,
      let outputPath = raw["output_ply"] as? String,
      let outputDigest = raw["output_sha256"] as? String,
      outputDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      let stageValues = raw["stage_seconds"] as? [String: NSNumber]
    else {
      throw MeasurementRunnerError.subprocessFailed("worker envelope fields are invalid")
    }
    let output = URL(fileURLWithPath: outputPath)
    let expectedOutput = invocation.projectRoot.appendingPathComponent("Output/splat.ply")
    guard output.standardizedFileURL == expectedOutput.standardizedFileURL,
      try sha256(output) == outputDigest
    else {
      throw MeasurementRunnerError.identityMismatch("worker PLY does not match its envelope")
    }
    var stageSeconds: [String: Double] = [:]
    for (name, number) in stageValues {
      let value = number.doubleValue
      guard !name.isEmpty, value.isFinite, value >= 0 else {
        throw MeasurementRunnerError.subprocessFailed("worker timing is invalid")
      }
      stageSeconds[name] = value
    }
    return MeasurementWorkerExecution(
      variant: invocation.variant,
      startedMonotonicSeconds: started,
      endedMonotonicSeconds: ended,
      exitCode: process.terminationStatus,
      userCPUMicroseconds: userCPU,
      systemCPUMicroseconds: systemCPU,
      memorySamples: memorySamples,
      outputPLY: output,
      outputSHA256: outputDigest,
      stageSeconds: stageSeconds
    )
  }

  private static func elapsedMicroseconds(from start: timeval, to end: timeval) throws -> UInt64 {
    let startValue = Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    let endValue = Int64(end.tv_sec) * 1_000_000 + Int64(end.tv_usec)
    guard startValue >= 0, endValue >= startValue else {
      throw MeasurementRunnerError.subprocessFailed("child CPU receipt moved backwards")
    }
    return UInt64(endValue - startValue)
  }

  private static func configuredProcess(
    _ invocation: MeasurementWorkerInvocation,
    stdout: FileHandle,
    stderr: FileHandle
  ) -> Process {
    let process = Process()
    process.executableURL = invocation.executable
    process.arguments = [
      "--request", invocation.request.path,
      "--input", invocation.input.path,
      "--toolchain-root", invocation.toolchainRoot.path,
      "--project-root", invocation.projectRoot.path,
      "--variant", invocation.variant.rawValue,
      "--output", invocation.envelope.path,
    ]
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "C",
      "LC_ALL": "C",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
    ]
    process.standardOutput = stdout
    process.standardError = stderr
    return process
  }


  private static func processTreeResidentBytes(rootPID: pid_t) -> UInt64 {
    var pending = [rootPID]
    var visited = Set<pid_t>()
    var total: UInt64 = 0
    while let pid = pending.popLast() {
      guard pid > 0, visited.insert(pid).inserted else { continue }
      var task = proc_taskinfo()
      let taskBytes = withUnsafeMutablePointer(to: &task) {
        proc_pidinfo(
          pid,
          PROC_PIDTASKINFO,
          0,
          $0,
          Int32(MemoryLayout<proc_taskinfo>.size)
        )
      }
      if taskBytes == Int32(MemoryLayout<proc_taskinfo>.size) {
        total &+= task.pti_resident_size
      }
      var children = [pid_t](repeating: 0, count: 256)
      let childBytes = children.withUnsafeMutableBytes {
        proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
      }
      guard childBytes > 0 else { continue }
      let count = min(Int(childBytes) / MemoryLayout<pid_t>.size, children.count)
      pending.append(contentsOf: children.prefix(count).filter { $0 > 0 })
    }
    return total
  }

  public static func sha256(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw MeasurementRunnerError.unsafePath("digest input must be a regular file")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private extension URL {
  var isSymbolicLink: Bool {
    (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}
