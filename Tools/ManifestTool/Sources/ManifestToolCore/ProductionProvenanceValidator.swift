import CoreFoundation
import Darwin
import Foundation

struct ProductionProvenanceSourceSnapshot: Sendable {
  let commit: String
  let files: [String: Data]
}

enum ProductionProvenanceValidator {
  private typealias JSONObject = [String: Any]

  private struct Identity {
    let source: String
    let version: String
    let revision: String
    let license: String
  }

  private struct FileEvidence {
    let sha256: String
    let size: UInt64
  }

  private struct ArchiveSizeCacheKey: Hashable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
  }

  private final class ArchiveSizeCache {
    private let lock = NSLock()
    private var sizesByArchive: [ArchiveSizeCacheKey: [String: UInt64]] = [:]

    func sizes(for key: ArchiveSizeCacheKey) -> [String: UInt64]? {
      lock.lock()
      defer { lock.unlock() }
      return sizesByArchive[key]
    }

    func store(_ sizes: [String: UInt64], for key: ArchiveSizeCacheKey) {
      lock.lock()
      defer { lock.unlock() }
      sizesByArchive[key] = sizes
    }
  }

  private struct ReviewedSourceClosure {
    let commit: String
    let colmap: [String: String]
    let supportLock: JSONObject
    let supportLockData: Data
    let ceresLock: JSONObject
    let openImageIOLock: JSONObject
    let msplat: [String: String]
    let da3: [String: String]
    let modelLock: JSONObject
    let modelLockData: Data
    let requirementsData: Data
    let runtimePatchData: Data
    let distributionSigningInputs: [String: Data]

    static func load(expectedCommit: String?) throws -> Self {
      let commit: String
      let tracked: (String) throws -> Data
      if let snapshot = sourceSnapshotForTesting {
        commit = snapshot.commit
        tracked = { path in
          guard let data = snapshot.files[path] else {
            try fail("Test source snapshot is missing a reviewed source file: \(path)")
          }
          return data
        }
      } else {
        let root = try repositoryRoot()
        let head = try gitData(["-C", root.path, "rev-parse", "HEAD"])
        let currentCommit = String(decoding: head, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        commit = expectedCommit ?? currentCommit
        if let expectedCommit {
          tracked = { path in
            try gitData(["-C", root.path, "show", "\(expectedCommit):\(path)"])
          }
        } else {
          tracked = { path in
            try reviewedWorkingTreeData(path, root: root)
          }
        }
        if let expectedCommit, expectedCommit != currentCommit {
          try fail("Production provenance must be validated from the exact release source commit.")
        }
      }
      try requireHex(commit, count: 40, label: "reviewed source commit")
      if let expectedCommit {
        try requireHex(expectedCommit, count: 40, label: "release source commit")
        guard expectedCommit == commit else {
          try fail("Production provenance source snapshot does not match the release commit.")
        }
      }
      let colmapData = try tracked("scripts/toolchain/build_colmap_impl.sh")
      let supportLockData = try tracked("scripts/toolchain/colmap-support-lock.json")
      let ceresLockData = try tracked("scripts/toolchain/ceres-lock.json")
      let openImageIOLockData = try tracked("scripts/toolchain/openimageio-lock.json")
      let msplatData = try tracked("scripts/toolchain/build_msplat.sh")
      let da3Data = try tracked("scripts/toolchain/build_da3_mps.sh")
      let modelLockData = try tracked("scripts/toolchain/da3-model-lock.json")
      let distributionSigningInputs = try Dictionary(
        uniqueKeysWithValues:
          distributionSigningSourcePaths.map { path in
            (path, try tracked(path))
          }
      )
      return try Self(
        commit: commit,
        colmap: shellAssignments(
          colmapData,
          names: [
            "COLMAP_REPO", "COLMAP_COMMIT", "COLMAP_VERSION",
            "POSELIB_URL", "POSELIB_COMMIT", "POSELIB_SHA256",
            "FAISS_URL", "FAISS_COMMIT", "FAISS_VERSION", "FAISS_SHA256",
          ]),
        supportLock: object(supportLockData, label: "reviewed COLMAP support lock"),
        supportLockData: supportLockData,
        ceresLock: object(ceresLockData, label: "reviewed Ceres lock"),
        openImageIOLock: object(openImageIOLockData, label: "reviewed OpenImageIO lock"),
        msplat: shellAssignments(
          msplatData,
          names: [
            "MSPLAT_REPO", "MSPLAT_COMMIT", "MSPLAT_VERSION",
            "NLOHMANN_JSON_URL", "NLOHMANN_JSON_SHA256",
            "NANOFLANN_URL", "NANOFLANN_SHA256", "CLI11_URL", "CLI11_SHA256",
          ]),
        da3: shellAssignments(
          da3Data,
          names: [
            "DA3_RUNTIME_PATCH_SHA256", "DA3_REPO", "DA3_REF",
            "PYTHON_STANDALONE_TAG", "PYTHON_STANDALONE_VERSION",
            "PYTHON_STANDALONE_ASSET", "PYTHON_STANDALONE_SHA256",
            "PYTHON_STANDALONE_FULL_ASSET", "PYTHON_STANDALONE_FULL_SHA256",
          ]),
        modelLock: object(modelLockData, label: "reviewed DA3 model lock"),
        modelLockData: modelLockData,
        requirementsData: tracked("Tools/Da3Sfm/requirements.txt"),
        runtimePatchData: tracked("Tools/Da3Sfm/patches/da3-api-lazy-export.patch"),
        distributionSigningInputs: distributionSigningInputs
      )
    }
  }

  private struct DistributionSigningClosure {
    let preSignHashes: [String: String]
    let component: JSONObject
  }

  private static let ordinaryReceiptLimit = 1 * 1_024 * 1_024
  private static let supplyChainReceiptLimit = 16 * 1_024 * 1_024
  private static let archiveSizeCache = ArchiveSizeCache()
  private static let distributionSigningSourcePaths = [
    "Tools/NativeColmap/local_vocab_retriever.cc",
    "Tools/NativeColmap/local_vocab_retriever.h",
    "scripts/release/finalize_signed_toolchain.py",
    "scripts/release/sign_macos_distribution.py",
    "scripts/toolchain/atomic_swap_install.py",
    "scripts/toolchain/build_colmap.sh",
    "scripts/toolchain/build_colmap_impl.sh",
    "scripts/toolchain/create_reproducible_zip.py",
    "scripts/toolchain/generate_supply_chain_manifest.py",
    "scripts/toolchain/package_toolchain.sh",
    "scripts/toolchain/patches/colmap-4.1.1-easysplat.patch",
    "scripts/toolchain/validate_da3_payload.py",
    "scripts/toolchain/validate_native_msplat.sh",
    "scripts/toolchain/colmap-support-lock.json",
    "scripts/toolchain/ceres-lock.json",
    "scripts/toolchain/openimageio-lock.json",
    "scripts/toolchain/da3-model-lock.json",
  ]
  @TaskLocal private static var sourceSnapshotForTesting: ProductionProvenanceSourceSnapshot?

  static var hasSourceSnapshotForTesting: Bool {
    sourceSnapshotForTesting != nil
  }

  static func withSourceSnapshotForTesting<T>(
    _ snapshot: ProductionProvenanceSourceSnapshot,
    operation: () throws -> T
  ) rethrows -> T {
    try $sourceSnapshotForTesting.withValue(snapshot, operation: operation)
  }

  static func trackedSourceDataForTesting(
    expectedCommit: String,
    path: String
  ) throws -> Data {
    let root = try repositoryRoot()
    let head = String(
      decoding: try gitData(["-C", root.path, "rev-parse", "HEAD"]),
      as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard expectedCommit == head else {
      try fail("Production provenance must be validated from the exact release source commit.")
    }
    return try gitData(["-C", root.path, "show", "\(expectedCommit):\(path)"])
  }

  static func validate(
    version: String,
    sourceRepository: String?,
    sourceCommit: String?,
    inputs: [ManifestArtifactInput],
    components: [ManifestDocument.Component]
  ) throws {
    let reviewed = try ReviewedSourceClosure.load(expectedCommit: sourceCommit)
    guard let coreInput = inputs.first(where: { $0.name == "macos-arm64-core" }),
      let core = components.first(where: { $0.name == "macos-arm64-core" })
    else {
      try fail("Production provenance validation requires the native core component.")
    }

    let colmap = try object(
      readEntry("provenance/colmap.json", from: coreInput.zipURL),
      label: "COLMAP provenance"
    )
    let support = try object(
      readEntry("provenance/colmap-support.json", from: coreInput.zipURL),
      label: "COLMAP support provenance"
    )
    let ceres = try object(
      readEntry("provenance/ceres.json", from: coreInput.zipURL),
      label: "Ceres provenance"
    )
    let openImageIO = try object(
      readEntry("provenance/openimageio.json", from: coreInput.zipURL),
      label: "OpenImageIO provenance"
    )
    let msplat = try object(
      readEntry("msplat/build_info.json", from: coreInput.zipURL),
      label: "msplat provenance"
    )
    let supplyChain = try object(
      readEntry("supply-chain/components.json", from: coreInput.zipURL),
      label: "supply-chain provenance"
    )
    let evidence = try fileEvidence(inputs: inputs, components: components)
    let signedClosure: DistributionSigningClosure?
    let hasSigningReceipt = core.contents.contains("provenance/distribution-signing.json")
    let supplyComponentIDs = Set(
      try arrayOfObjects(supplyChain["components"], label: "supply-chain components")
        .map { string($0, "id") }
    )
    let hasSigningComponent = supplyComponentIDs.contains("easysplat-distribution-signing")
    guard hasSigningReceipt == hasSigningComponent else {
      try fail("Distribution-signing receipt and supply-chain component must appear together.")
    }
    if hasSigningReceipt {
      let receiptData = try readEntry(
        "provenance/distribution-signing.json",
        from: coreInput.zipURL
      )
      signedClosure = try validateDistributionSigning(
        try object(receiptData, label: "distribution-signing provenance"),
        receiptData: receiptData,
        supplyChain: supplyChain,
        version: version,
        sourceRepository: sourceRepository,
        reviewed: reviewed,
        evidence: evidence,
        colmap: colmap,
        support: support,
        msplat: msplat
      )
    } else {
      signedClosure = nil
    }

    _ = try validateColmap(
      colmap,
      expectedExecutableSHA256: signedClosure?.preSignHashes["bin/colmap"]
        ?? core.criticalFileHashes["bin/colmap"],
      reviewed: reviewed
    )
    _ = try validateSupport(
      support,
      expectedLibompSHA256: signedClosure?.preSignHashes["lib/libomp.dylib"]
        ?? core.criticalFileHashes["lib/libomp.dylib"],
      reviewed: reviewed
    )
    _ = try validateCeres(ceres, reviewed: reviewed)
    _ = try validateOpenImageIO(openImageIO, reviewed: reviewed)
    _ = try validateMsplat(
      msplat,
      expectedExecutableSHA256: signedClosure?.preSignHashes["bin/easysplat-train"]
        ?? core.criticalFileHashes["bin/easysplat-train"],
      expectedMetallibSHA256: core.criticalFileHashes["bin/default.metallib"],
      reviewed: reviewed
    )
    var expectedComponents = try expectedComponentClosure(
      version: version,
      sourceRepository: sourceRepository,
      inputs: inputs,
      manifestComponents: components,
      colmap: colmap,
      support: support,
      ceres: ceres,
      openImageIO: openImageIO,
      msplat: msplat,
      reviewed: reviewed
    )
    if let signedClosure {
      expectedComponents["easysplat-distribution-signing"] = signedClosure.component
    }
    try validateSupplyChain(
      supplyChain,
      version: version,
      inputs: inputs,
      components: components,
      expectedComponents: expectedComponents
    )
  }

  private static func validateColmap(
    _ receipt: JSONObject,
    expectedExecutableSHA256: String?,
    reviewed: ReviewedSourceClosure
  ) throws -> Identity {
    guard integer(receipt["schema_version"]) == 2,
      string(receipt, "toolchain_name") == "colmap"
    else {
      try fail("COLMAP provenance has the wrong schema or toolchain name.")
    }
    let identity = try sourceIdentity(
      receipt,
      revisionKeys: ["source_commit"],
      label: "COLMAP"
    )
    try requireHex(string(receipt, "source_commit"), count: 40, label: "COLMAP source commit")
    try requireHex(
      string(receipt, "source_tree_sha256"),
      count: 64,
      label: "COLMAP source tree"
    )
    guard string(receipt, "executable_sha256") == expectedExecutableSHA256 else {
      try fail("COLMAP provenance executable hash does not match bin/colmap.")
    }
    guard string(receipt, "source_url") == reviewed.colmap["COLMAP_REPO"],
      string(receipt, "source_commit") == reviewed.colmap["COLMAP_COMMIT"],
      string(receipt, "source_version") == reviewed.colmap["COLMAP_VERSION"],
      string(receipt, "license") == "BSD-3-Clause"
    else {
      try fail("COLMAP provenance does not match the reviewed source lock.")
    }
    let dependencies = try dictionary(receipt["dependencies"], label: "COLMAP dependencies")
    guard Set(dependencies.keys) == ["faiss", "poselib", "vlfeat"] else {
      try fail("COLMAP provenance has an unexpected dependency closure.")
    }
    let commit = reviewed.colmap["COLMAP_COMMIT"] ?? ""
    let version = reviewed.colmap["COLMAP_VERSION"] ?? ""
    try requireReviewedDependency(
      dependencies["faiss"],
      source: reviewed.colmap["FAISS_URL"] ?? "",
      version: reviewed.colmap["FAISS_VERSION"] ?? "",
      commit: reviewed.colmap["FAISS_COMMIT"],
      sha256: reviewed.colmap["FAISS_SHA256"],
      license: "MIT",
      label: "COLMAP FAISS"
    )
    try requireReviewedDependency(
      dependencies["poselib"],
      source: reviewed.colmap["POSELIB_URL"] ?? "",
      version: reviewed.colmap["POSELIB_COMMIT"] ?? "",
      commit: reviewed.colmap["POSELIB_COMMIT"],
      sha256: reviewed.colmap["POSELIB_SHA256"],
      license: "BSD-3-Clause",
      label: "COLMAP PoseLib"
    )
    try requireReviewedDependency(
      dependencies["vlfeat"],
      source:
        "\((reviewed.colmap["COLMAP_REPO"] ?? "").replacingOccurrences(of: ".git", with: ""))/tree/\(commit)/src/thirdparty/VLFeat",
      version: "vendored-at-colmap-\(version)",
      commit: commit,
      sha256: nil,
      license: "BSD-2-Clause",
      label: "COLMAP VLFeat"
    )
    return identity
  }

  private static func validateSupport(
    _ receipt: JSONObject,
    expectedLibompSHA256: String?,
    reviewed: ReviewedSourceClosure
  ) throws -> Identity {
    guard integer(receipt["schema_version"]) == 1,
      string(receipt, "toolchain_name") == "colmap-support"
    else {
      try fail("COLMAP support provenance has the wrong schema or toolchain name.")
    }
    let revision = string(receipt, "source_lock_sha256")
    try requireHex(revision, count: 64, label: "COLMAP support source lock")
    guard revision == ManifestBuilder.sha256Hex(data: reviewed.supportLockData) else {
      try fail("COLMAP support provenance does not match the reviewed source lock.")
    }
    let libraries = try dictionary(
      receipt["library_sha256"],
      label: "COLMAP support library hashes"
    )
    guard Set(libraries.keys) == ["lib/libomp.dylib"],
      string(libraries, "lib/libomp.dylib") == expectedLibompSHA256
    else {
      try fail("COLMAP support provenance does not match lib/libomp.dylib.")
    }
    let dependencies = try dictionary(receipt["dependencies"], label: "COLMAP support dependencies")
    guard Set(dependencies.keys) == ["boost", "gflags", "glog", "libomp"] else {
      try fail("COLMAP support provenance has an unexpected dependency closure.")
    }
    let locked = try dictionary(
      reviewed.supportLock["dependencies"],
      label: "reviewed COLMAP support dependencies"
    )
    for name in dependencies.keys.sorted() {
      try requireLockDependency(
        dependencies[name],
        lock: locked[name],
        label: "COLMAP support dependency \(name)"
      )
    }
    return Identity(
      source: "",
      version: "1",
      revision: revision,
      license: "LicenseRef-Dependency-Closure"
    )
  }

  private static func validateCeres(
    _ receipt: JSONObject,
    reviewed: ReviewedSourceClosure
  ) throws -> Identity {
    guard integer(receipt["schema_version"]) == 1,
      string(receipt, "toolchain_name") == "ceres-static"
    else {
      try fail("Ceres provenance has the wrong schema or toolchain name.")
    }
    let dependencies = try dictionary(receipt["dependencies"], label: "Ceres dependencies")
    guard Set(dependencies.keys) == ["ceres", "eigen"] else {
      try fail("Ceres provenance has an unexpected dependency closure.")
    }
    let ceresDependency = try dictionary(dependencies["ceres"], label: "Ceres dependency")
    let locked = try dictionary(
      reviewed.ceresLock["dependencies"],
      label: "reviewed Ceres dependencies"
    )
    for name in dependencies.keys.sorted() {
      try requireLockDependency(
        dependencies[name],
        lock: locked[name],
        label: "Ceres dependency \(name)"
      )
    }
    let identity = try dependencyIdentity(ceresDependency, label: "Ceres dependency")
    _ = try dependencyIdentity(dependencies["eigen"], label: "Eigen dependency")
    guard string(receipt, "source_url") == identity.source,
      string(receipt, "source_version") == identity.version,
      string(receipt, "source_commit") == identity.revision,
      string(receipt, "source_sha256") == string(ceresDependency, "source_sha256"),
      string(receipt, "license") == identity.license
    else {
      try fail("Ceres top-level source identity does not match its dependency receipt.")
    }
    return identity
  }

  private static func validateOpenImageIO(
    _ receipt: JSONObject,
    reviewed: ReviewedSourceClosure
  ) throws -> Identity {
    guard integer(receipt["schema_version"]) == 1,
      string(receipt, "toolchain_name") == "openimageio-static"
    else {
      try fail("OpenImageIO provenance has the wrong schema or toolchain name.")
    }
    let dependencies = try dictionary(receipt["dependencies"], label: "OpenImageIO dependencies")
    let expected = Set([
      "boost", "fmt", "imath", "libjpeg-turbo", "libpng", "openimageio", "robin-map",
    ])
    guard Set(dependencies.keys) == expected else {
      try fail("OpenImageIO provenance has an unexpected dependency closure.")
    }
    let lockedOIIO = try dictionary(
      reviewed.openImageIOLock["dependencies"],
      label: "reviewed OpenImageIO dependencies"
    )
    let lockedSupport = try dictionary(
      reviewed.supportLock["dependencies"],
      label: "reviewed COLMAP support dependencies"
    )
    for name in dependencies.keys.sorted() {
      let lock = name == "boost" ? lockedSupport[name] : lockedOIIO[name]
      try requireLockDependency(
        dependencies[name],
        lock: lock,
        label: "OpenImageIO dependency \(name)"
      )
    }
    return try dependencyIdentity(dependencies["openimageio"], label: "OpenImageIO dependency")
  }

  private static func validateMsplat(
    _ receipt: JSONObject,
    expectedExecutableSHA256: String?,
    expectedMetallibSHA256: String?,
    reviewed: ReviewedSourceClosure
  ) throws -> Identity {
    guard string(receipt, "toolchain_name") == "msplat",
      string(receipt, "deployment_target") == "macOS 15.0",
      string(receipt, "build_configuration") == "Release"
    else {
      try fail("msplat provenance does not describe the reviewed release build.")
    }
    let identity = try sourceIdentity(
      receipt,
      revisionKeys: ["source_commit"],
      label: "msplat",
      license: "Apache-2.0"
    )
    try requireHex(string(receipt, "source_commit"), count: 40, label: "msplat source commit")
    try requireHex(
      string(receipt, "source_tree_sha256"),
      count: 64,
      label: "msplat source tree"
    )
    guard
      string(receipt, "executable_sha256")
        == expectedExecutableSHA256,
      string(receipt, "metallib_sha256")
        == expectedMetallibSHA256
    else {
      try fail("msplat provenance does not match the executable and Metal library.")
    }
    guard string(receipt, "source_url") == reviewed.msplat["MSPLAT_REPO"],
      string(receipt, "source_commit") == reviewed.msplat["MSPLAT_COMMIT"],
      string(receipt, "source_version") == reviewed.msplat["MSPLAT_VERSION"]
    else {
      try fail("msplat provenance does not match the reviewed source lock.")
    }
    let dependencies = try dictionary(receipt["dependencies"], label: "msplat dependencies")
    guard
      Set(dependencies.keys) == [
        "cli11_v2.4.2_sha256",
        "nanoflann_v1.5.5_sha256",
        "nlohmann_json_v3.11.3_sha256",
      ]
    else {
      try fail("msplat provenance has an unexpected dependency closure.")
    }
    for (name, value) in dependencies {
      guard !name.isEmpty, let digest = value as? String else {
        try fail("msplat dependency provenance is malformed.")
      }
      try requireHex(digest, count: 64, label: "msplat dependency \(name)")
    }
    guard string(dependencies, "cli11_v2.4.2_sha256") == reviewed.msplat["CLI11_SHA256"],
      string(dependencies, "nanoflann_v1.5.5_sha256") == reviewed.msplat["NANOFLANN_SHA256"],
      string(dependencies, "nlohmann_json_v3.11.3_sha256")
        == reviewed.msplat["NLOHMANN_JSON_SHA256"]
    else {
      try fail("msplat dependency provenance does not match the reviewed source lock.")
    }
    return identity
  }

  private static func expectedComponentClosure(
    version: String,
    sourceRepository: String?,
    inputs: [ManifestArtifactInput],
    manifestComponents: [ManifestDocument.Component],
    colmap: JSONObject,
    support: JSONObject,
    ceres: JSONObject,
    openImageIO: JSONObject,
    msplat: JSONObject,
    reviewed: ReviewedSourceClosure
  ) throws -> [String: JSONObject] {
    let repository = sourceRepository ?? "dud8/EasySplat"
    var expected: [String: JSONObject] = [:]

    let colmapDependencies = try dictionary(colmap["dependencies"], label: "COLMAP dependencies")
    for name in colmapDependencies.keys.sorted() {
      let id = "colmap:\(name)"
      expected[id] = try dependencyRecord(
        id: id,
        name: name,
        entry: colmapDependencies[name],
        buildCommand: "./scripts/toolchain/build_colmap.sh",
        incorporatedInto: "colmap"
      )
    }
    expected["colmap"] = componentRecord(
      id: "colmap",
      name: "COLMAP",
      type: "executable",
      version: string(colmap, "source_version"),
      revision: string(colmap, "source_commit"),
      source: string(colmap, "source_url"),
      buildCommand: "./scripts/toolchain/build_colmap.sh",
      license: normalizedLicense(string(colmap, "license")),
      licenseFiles: ["licenses/COLMAP/COPYING.txt"],
      linkage: "native-executable",
      dependencies: (colmapDependencies.keys.map { "colmap:\($0)" }
        + ["colmap-support", "ceres", "openimageio"]).sorted()
    )

    let supportDependencies = try dictionary(
      support["dependencies"],
      label: "COLMAP support dependencies"
    )
    for name in supportDependencies.keys.sorted() {
      let id = "colmap-support:\(name)"
      expected[id] = try dependencyRecord(
        id: id,
        name: name,
        entry: supportDependencies[name],
        buildCommand: "./scripts/toolchain/build_colmap_support.sh",
        incorporatedInto: "colmap-support"
      )
    }
    expected["colmap-support"] = componentRecord(
      id: "colmap-support",
      name: "EasySplat COLMAP support closure",
      type: "native-build-input",
      version: String(integer(support["schema_version"]) ?? 1),
      revision: string(support, "source_lock_sha256"),
      source: "https://github.com/\(repository)",
      buildCommand: "./scripts/toolchain/build_colmap_support.sh",
      license: "LicenseRef-Dependency-Closure",
      licenseFiles: ["licenses/EasySplat/LICENSE"],
      linkage: "build-input",
      dependencies: supportDependencies.keys.map { "colmap-support:\($0)" }.sorted()
    )

    let ceresDependencies = try dictionary(ceres["dependencies"], label: "Ceres dependencies")
    var ceresRecord = try dependencyRecord(
      id: "ceres",
      name: "Ceres Solver",
      entry: ceresDependencies["ceres"],
      buildCommand: "./scripts/toolchain/build_ceres.sh",
      incorporatedInto: "colmap"
    )
    ceresRecord["type"] = "static-library"
    ceresRecord["dependencies"] = ["ceres:eigen"]
    expected["ceres"] = ceresRecord
    expected["ceres:eigen"] = try dependencyRecord(
      id: "ceres:eigen",
      name: "Eigen",
      entry: ceresDependencies["eigen"],
      buildCommand: "./scripts/toolchain/build_ceres.sh",
      incorporatedInto: "ceres"
    )

    let oiioDependencies = try dictionary(
      openImageIO["dependencies"],
      label: "OpenImageIO dependencies"
    )
    var oiioRecord = try dependencyRecord(
      id: "openimageio",
      name: "OpenImageIO",
      entry: oiioDependencies["openimageio"],
      buildCommand: "./scripts/toolchain/build_openimageio.sh",
      incorporatedInto: "colmap"
    )
    oiioRecord["type"] = "static-library"
    oiioRecord["dependencies"] = oiioDependencies.keys
      .filter { $0 != "openimageio" }
      .map { "openimageio:\($0)" }
      .sorted()
    expected["openimageio"] = oiioRecord
    for name in oiioDependencies.keys.sorted() where name != "openimageio" {
      let id = "openimageio:\(name)"
      expected[id] = try dependencyRecord(
        id: id,
        name: name,
        entry: oiioDependencies[name],
        buildCommand: "./scripts/toolchain/build_openimageio.sh",
        incorporatedInto: "openimageio"
      )
    }

    let msplatDependencies = try dictionary(msplat["dependencies"], label: "msplat dependencies")
    let msplatInputs: [(String, String, String, String, String, String, String)] = [
      (
        "msplat:cli11", "CLI11", try archiveTagVersion(reviewed.msplat["CLI11_URL"]),
        try archiveRepository(reviewed.msplat["CLI11_URL"]), "BSD-3-Clause",
        "licenses/msplat/CLI11/LICENSE", "cli11_v2.4.2_sha256"
      ),
      (
        "msplat:nanoflann", "nanoflann", try archiveTagVersion(reviewed.msplat["NANOFLANN_URL"]),
        try archiveRepository(reviewed.msplat["NANOFLANN_URL"]), "BSD-2-Clause",
        "licenses/msplat/nanoflann/COPYING", "nanoflann_v1.5.5_sha256"
      ),
      (
        "msplat:nlohmann-json", "nlohmann-json",
        try archiveTagVersion(reviewed.msplat["NLOHMANN_JSON_URL"]),
        try archiveRepository(reviewed.msplat["NLOHMANN_JSON_URL"]), "MIT",
        "licenses/msplat/nlohmann-json/LICENSE.MIT", "nlohmann_json_v3.11.3_sha256"
      ),
    ]
    for (id, name, dependencyVersion, source, license, licensePath, receiptKey) in msplatInputs {
      expected[id] = componentRecord(
        id: id,
        name: name,
        type: "static-dependency",
        version: dependencyVersion,
        revision: "sha256:\(string(msplatDependencies, receiptKey))",
        source: source,
        buildCommand: "./scripts/toolchain/build_msplat.sh",
        license: license,
        licenseFiles: [licensePath],
        linkage: "compiled-in",
        dependencies: [],
        incorporatedInto: ["msplat"]
      )
    }
    expected["msplat"] = componentRecord(
      id: "msplat",
      name: "msplat",
      type: "executable",
      version: string(msplat, "source_version"),
      revision: string(msplat, "source_commit"),
      source: string(msplat, "source_url"),
      buildCommand: "./scripts/toolchain/build_msplat.sh",
      license: "Apache-2.0",
      licenseFiles: ["msplat/LICENSE"],
      linkage: "executable",
      dependencies: msplatInputs.map { $0.0 }.sorted()
    )

    let expectedFiles = try fileEvidence(inputs: inputs, components: manifestComponents)
    try appendDA3Components(
      to: &expected,
      version: version,
      repository: repository,
      inputs: inputs,
      manifestComponents: manifestComponents,
      fileEvidence: expectedFiles,
      reviewed: reviewed
    )
    return expected
  }

  private static func dependencyRecord(
    id: String,
    name: String,
    entry value: Any?,
    buildCommand: String,
    incorporatedInto: String
  ) throws -> JSONObject {
    let entry = try dictionary(value, label: "dependency \(id)")
    let source = string(entry, "source_url")
    let version = string(entry, "source_version")
    let revision =
      ["source_commit", "source_sha256", "source_archive_sha256", "source_tree_sha256"]
      .lazy.map { string(entry, $0) }.first(where: { !$0.isEmpty }) ?? version
    var record = componentRecord(
      id: id,
      name: name,
      type: "static-dependency",
      version: version,
      revision: revision,
      source: source,
      buildCommand: buildCommand,
      license: normalizedLicense(string(entry, "license")),
      licenseFiles: try stringArray(entry["license_files"], label: "dependency licenses for \(id)")
        .sorted(),
      linkage: string(entry, "linkage").isEmpty ? "compiled-in" : string(entry, "linkage"),
      dependencies: [],
      incorporatedInto: [incorporatedInto]
    )
    if let artifact = try dependencyArtifact(entry, label: "dependency \(id)") {
      record["artifact"] = artifact.url
      record["artifactSha256"] = artifact.sha256
    }
    return record
  }

  private static func componentRecord(
    id: String,
    name: String,
    type: String,
    version: String,
    revision: String,
    source: String,
    buildCommand: String,
    license: String,
    licenseFiles: [String],
    linkage: String,
    dependencies: [String],
    incorporatedInto: [String]? = nil
  ) -> JSONObject {
    var record: JSONObject = [
      "id": id,
      "name": name,
      "type": type,
      "version": version,
      "revision": revision,
      "source": source,
      "buildCommand": buildCommand,
      "license": license,
      "licenseFiles": licenseFiles.sorted(),
      "linkage": linkage,
      "dependencies": dependencies.sorted(),
    ]
    if let incorporatedInto { record["incorporatedInto"] = incorporatedInto.sorted() }
    return record
  }

  private static func appendDA3Components(
    to expected: inout [String: JSONObject],
    version: String,
    repository: String,
    inputs: [ManifestArtifactInput],
    manifestComponents: [ManifestDocument.Component],
    fileEvidence: [String: FileEvidence],
    reviewed: ReviewedSourceClosure
  ) throws {
    guard let coreInput = inputs.first(where: { $0.name == "macos-arm64-core" }),
      let baseInput = inputs.first(where: { $0.name == "geometry-da3-base" }),
      let smallInput = inputs.first(where: { $0.name == "geometry-da3-small" }),
      let core = manifestComponents.first(where: { $0.name == "macos-arm64-core" }),
      let base = manifestComponents.first(where: { $0.name == "geometry-da3-base" }),
      manifestComponents.contains(where: { $0.name == "geometry-da3-small" })
    else {
      try fail("DA3 provenance validation requires the complete production component set.")
    }
    let build = try object(
      readEntry("da3_mps/build_info.json", from: baseInput.zipURL),
      label: "DA3 build provenance"
    )
    guard string(build, "toolchain_name") == "da3_mps",
      string(build, "source_provenance") == "pinned-git",
      string(build, "source_repo") == string(build, "expected_upstream_repo"),
      string(build, "source_ref") == string(build, "source_commit"),
      string(build, "source_ref") == string(build, "expected_upstream_ref"),
      string(build, "source_path")
        == "git:\(string(build, "source_repo"))@\(string(build, "source_commit"))",
      validHTTPS(string(build, "source_repo"))
    else {
      try fail("DA3 build provenance is not pinned to one reviewed source tree.")
    }
    try requireHex(string(build, "source_commit"), count: 40, label: "DA3 source commit")
    let da3Repository = reviewed.da3["DA3_REPO"] ?? ""
    let da3Commit = reviewed.da3["DA3_REF"] ?? ""
    guard string(build, "source_repo") == da3Repository,
      string(build, "expected_upstream_repo") == da3Repository,
      string(build, "source_ref") == da3Commit,
      string(build, "source_commit") == da3Commit,
      string(build, "expected_upstream_ref") == da3Commit
    else {
      try fail("DA3 provenance does not match the reviewed source lock.")
    }
    for key in [
      "model_lock_sha256", "python_standalone_sha256",
      "python_standalone_license_archive_sha256", "requirements_lock_sha256",
      "runtime_patch_sha256", "supplemental_license_manifest_sha256",
    ] {
      try requireHex(string(build, key), count: 64, label: "DA3 \(key)")
    }
    guard string(build, "model_lock") == "scripts/toolchain/da3-model-lock.json",
      string(build, "requirements_lock") == "Tools/Da3Sfm/requirements.txt",
      string(build, "runtime_patch") == "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
      string(build, "pip_install_report") == "licenses/python-packages-install-report.json",
      string(build, "supplemental_license_manifest")
        == "licenses/python-package-upstream-notices.json",
      validHTTPS(string(build, "python_standalone_url")),
      validHTTPS(string(build, "python_standalone_license_archive_url")),
      !string(build, "python_version").isEmpty
    else {
      try fail("DA3 runtime lock provenance is incomplete or unreviewed.")
    }

    let standaloneTag = reviewed.da3["PYTHON_STANDALONE_TAG"] ?? ""
    let standaloneVersion = reviewed.da3["PYTHON_STANDALONE_VERSION"] ?? ""
    let standaloneAsset = try expandedShellValue(
      reviewed.da3["PYTHON_STANDALONE_ASSET"] ?? "",
      assignments: reviewed.da3
    )
    let standaloneFullAsset = try expandedShellValue(
      reviewed.da3["PYTHON_STANDALONE_FULL_ASSET"] ?? "",
      assignments: reviewed.da3
    )
    let standaloneBase =
      "https://github.com/indygreg/python-build-standalone/releases/download/\(standaloneTag)"
    guard
      string(build, "model_lock_sha256")
        == ManifestBuilder.sha256Hex(data: reviewed.modelLockData),
      string(build, "requirements_lock_sha256")
        == ManifestBuilder.sha256Hex(data: reviewed.requirementsData),
      string(build, "runtime_patch_sha256")
        == ManifestBuilder.sha256Hex(data: reviewed.runtimePatchData),
      string(build, "runtime_patch_sha256")
        == reviewed.da3["DA3_RUNTIME_PATCH_SHA256"],
      string(build, "python_version") == standaloneVersion,
      string(build, "python_standalone_url") == "\(standaloneBase)/\(standaloneAsset)",
      string(build, "python_standalone_sha256")
        == reviewed.da3["PYTHON_STANDALONE_SHA256"],
      string(build, "python_standalone_license_archive_url")
        == "\(standaloneBase)/\(standaloneFullAsset)",
      string(build, "python_standalone_license_archive_sha256")
        == reviewed.da3["PYTHON_STANDALONE_FULL_SHA256"]
    else {
      try fail("DA3 runtime provenance does not match the reviewed source lock.")
    }

    let requirementsPath = "da3_mps/licenses/python-packages-requirements.txt"
    let reportPath = "da3_mps/licenses/python-packages-install-report.json"
    let supplementalPath = "da3_mps/licenses/python-package-upstream-notices.json"
    let requirementsData = try readEntry(requirementsPath, from: baseInput.zipURL)
    let reportData = try readEntry(reportPath, from: baseInput.zipURL)
    let supplementalData = try readEntry(supplementalPath, from: baseInput.zipURL)
    guard requirementsData == reviewed.requirementsData,
      ManifestBuilder.sha256Hex(data: requirementsData)
        == string(build, "requirements_lock_sha256"),
      ManifestBuilder.sha256Hex(data: supplementalData)
        == string(build, "supplemental_license_manifest_sha256")
    else {
      try fail("DA3 requirements or supplemental-license lock was modified.")
    }

    expected["da3"] = componentRecord(
      id: "da3",
      name: "Depth Anything 3",
      type: "python-source",
      version: string(build, "source_ref"),
      revision: string(build, "source_commit"),
      source: string(build, "source_repo"),
      buildCommand: "./scripts/toolchain/build_da3_mps.sh",
      license: "Apache-2.0",
      licenseFiles: ["da3_mps/vendor/depth-anything-3/LICENSE"],
      linkage: "python",
      dependencies: []
    )
    expected["easysplat-da3-runner"] = componentRecord(
      id: "easysplat-da3-runner",
      name: "EasySplat DA3 runner",
      type: "script",
      version: version,
      revision: reviewed.commit,
      source: "https://github.com/\(repository)",
      buildCommand: "./scripts/toolchain/build_da3_mps.sh",
      license: "MIT",
      licenseFiles: ["licenses/EasySplat/LICENSE"],
      linkage: "python",
      dependencies: ["da3", "python-build-standalone"]
    )

    let standaloneLicensePrefix = "da3_mps/licenses/python-build-standalone/"
    let standaloneLicenses = base.contents
      .filter { $0.hasPrefix(standaloneLicensePrefix) }
      .sorted()
    guard standaloneLicenses.contains("\(standaloneLicensePrefix)PYTHON.json"),
      standaloneLicenses.contains(where: { $0.hasPrefix("\(standaloneLicensePrefix)licenses/") })
    else {
      try fail("python-build-standalone license closure is incomplete.")
    }
    expected["python-build-standalone"] = componentRecord(
      id: "python-build-standalone",
      name: "python-build-standalone",
      type: "runtime",
      version: string(build, "python_version"),
      revision: "sha256:\(string(build, "python_standalone_sha256"))",
      source: string(build, "python_standalone_url"),
      buildCommand: "./scripts/toolchain/build_da3_mps.sh",
      license: "LicenseRef-Python-Build-Standalone-Closure",
      licenseFiles: standaloneLicenses,
      linkage: "runtime",
      dependencies: []
    )

    try appendModelComponent(
      name: "DA3-BASE",
      checkpointPrefix: "base",
      input: baseInput,
      expected: &expected,
      build: build,
      fileEvidence: fileEvidence,
      reviewedModelLock: reviewed.modelLock
    )
    try appendModelComponent(
      name: "DA3-SMALL",
      checkpointPrefix: "small",
      input: smallInput,
      expected: &expected,
      build: build,
      fileEvidence: fileEvidence,
      reviewedModelLock: reviewed.modelLock
    )

    let lockedRequirements = try parseRequirementsLock(requirementsData)
    let report = try object(reportData, label: "Python install report")
    let installs = try arrayOfObjects(report["install"], label: "Python install report entries")
    var reportSlugs: Set<String> = []
    let installedIDs = Set(
      installs.compactMap { entry -> String? in
        guard let metadata = entry["metadata"] as? JSONObject else { return nil }
        let name = string(metadata, "name")
        return name.isEmpty ? nil : "python:\(pythonSlug(name))"
      })
    guard installedIDs.count == installs.count else {
      try fail("Python install report has missing or duplicated package identities.")
    }

    let metadataPaths = base.contents.filter { directDistributionMetadataPath($0) }
    let metadataDataByPath = try readEntries(metadataPaths, from: baseInput.zipURL)
    var installedMetadata: [String: (path: String, data: Data, headers: [String: [String]])] = [:]
    for path in metadataPaths {
      guard let data = metadataDataByPath[path] else {
        try fail("Unable to read required Python distribution metadata: \(path)")
      }
      let headers = parseMetadata(data)
      guard let name = headers["name"]?.first,
        let packageVersion = headers["version"]?.first
      else { continue }
      let slug = pythonSlug(name)
      guard installedMetadata[slug] == nil else {
        try fail("Python runtime contains duplicate top-level distribution metadata: \(slug)")
      }
      installedMetadata[slug] = (path, data, headers)
      guard !packageVersion.isEmpty else {
        try fail("Python distribution version is missing: \(slug)")
      }
    }

    let licenseMetadataPathsBySlug = Dictionary(
      uniqueKeysWithValues: installedMetadata.keys.sorted().map { slug in
        (slug, "licenses/python-packages/\(slug)/METADATA")
      })
    let licenseMetadataByPath = try readEntries(
      Array(licenseMetadataPathsBySlug.values),
      from: coreInput.zipURL
    )

    for entry in installs {
      let metadata = try dictionary(entry["metadata"], label: "pip package metadata")
      let reportName = string(metadata, "name")
      let packageVersion = string(metadata, "version")
      let slug = pythonSlug(reportName)
      guard !slug.isEmpty, reportSlugs.insert(slug).inserted,
        let runtime = installedMetadata[slug],
        runtime.headers["version"]?.first == packageVersion,
        let lock = lockedRequirements[slug],
        lock.version == packageVersion
      else {
        try fail("Python package identity is absent from the runtime or requirements lock: \(slug)")
      }
      let download = try dictionary(entry["download_info"], label: "pip artifact \(slug)")
      let archive = try dictionary(download["archive_info"], label: "pip archive \(slug)")
      let hashes = (archive["hashes"] as? JSONObject) ?? [:]
      var artifactSHA = string(hashes, "sha256")
      if artifactSHA.isEmpty {
        let raw = string(archive, "hash")
        if raw.hasPrefix("sha256=") { artifactSHA = String(raw.dropFirst(7)) }
      }
      let artifactURL = string(download, "url")
      try requireHex(artifactSHA, count: 64, label: "Python artifact \(slug)")
      guard validHTTPS(artifactURL), lock.hashes.contains(artifactSHA) else {
        try fail("Python artifact is not bound to its hash lock: \(slug)")
      }

      let receiptPath = licenseMetadataPathsBySlug[slug] ?? ""
      guard let receiptData = licenseMetadataByPath[receiptPath] else {
        try fail("Python package license metadata is missing: \(slug)")
      }
      guard receiptData == runtime.data else {
        try fail("Python package license metadata differs from the installed runtime: \(slug)")
      }
      let packageName = runtime.headers["name"]?.first ?? reportName
      let source = pythonSource(
        headers: runtime.headers, name: packageName, version: packageVersion)
      let license = try pythonLicense(headers: runtime.headers, package: packageName)
      let dependencies = pythonDependencies(
        headers: runtime.headers,
        installedIDs: installedIDs
      )
      let licensePrefix = "licenses/python-packages/\(slug)/"
      let licenseFiles = core.contents.filter { $0.hasPrefix(licensePrefix) }.sorted()
      guard !licenseFiles.isEmpty else {
        try fail("Python package has no signed license closure: \(slug)")
      }
      var record = componentRecord(
        id: "python:\(slug)",
        name: packageName,
        type: "python-package",
        version: packageVersion,
        revision: packageVersion,
        source: source,
        buildCommand: "./scripts/toolchain/build_da3_mps.sh",
        license: license,
        licenseFiles: licenseFiles,
        linkage: "python",
        dependencies: dependencies
      )
      record["artifact"] = artifactURL
      record["artifactSha256"] = artifactSHA
      expected["python:\(slug)"] = record
    }
    guard Set(lockedRequirements.keys) == reportSlugs else {
      try fail("Python requirements lock and install report package sets differ.")
    }
    guard Set(installedMetadata.keys) == reportSlugs else {
      try fail("Installed Python distribution set does not match the report and requirements lock.")
    }
    try validatePythonRuntimeClosure(
      base: base,
      input: baseInput,
      installedMetadata: installedMetadata,
      fileEvidence: fileEvidence
    )
    for (buildKey, slug) in [
      ("torch_version", "torch"),
      ("torchvision_version", "torchvision"),
      ("huggingface_hub_version", "huggingface-hub"),
    ] {
      guard lockedRequirements[slug]?.version == string(build, buildKey) else {
        try fail("DA3 build receipt package version does not match the hash lock: \(slug)")
      }
    }
    guard expected.count == 63 else {
      try fail("Production supply-chain closure must contain exactly 63 reviewed components.")
    }
  }

  private static func appendModelComponent(
    name: String,
    checkpointPrefix: String,
    input: ManifestArtifactInput,
    expected: inout [String: JSONObject],
    build: JSONObject,
    fileEvidence: [String: FileEvidence],
    reviewedModelLock: JSONObject
  ) throws {
    let prefix = "da3_mps/models/\(name)"
    let info = try object(
      readEntry("\(prefix)/easysplat_model_info.json", from: input.zipURL),
      label: "\(name) model provenance"
    )
    let reviewedModels = try dictionary(
      reviewedModelLock["models"],
      label: "reviewed DA3 model identities"
    )
    let reviewedInfo = try dictionary(
      reviewedModels[name],
      label: "reviewed \(name) identity"
    )
    guard
      Set(info.keys) == ["repo_id", "requested_revision", "resolved_sha", "license", "artifacts"],
      string(info, "repo_id") == string(reviewedInfo, "repo_id"),
      string(info, "requested_revision") == string(reviewedInfo, "requested_revision"),
      string(info, "resolved_sha") == string(reviewedInfo, "resolved_sha"),
      string(info, "license") == string(reviewedInfo, "license"),
      string(info, "repo_id") == string(build, "\(checkpointPrefix)_checkpoint_repo"),
      string(info, "requested_revision")
        == string(build, "\(checkpointPrefix)_checkpoint_revision"),
      string(info, "resolved_sha")
        == string(build, "\(checkpointPrefix)_checkpoint_commit"),
      string(info, "requested_revision") == string(info, "resolved_sha"),
      string(info, "license").lowercased() == "apache-2.0"
    else {
      try fail("\(name) model identity does not match the DA3 build lock.")
    }
    try requireHex(string(info, "resolved_sha"), count: 40, label: "\(name) revision")
    let artifacts = try dictionary(info["artifacts"], label: "\(name) artifacts")
    let reviewedArtifacts = try dictionary(
      reviewedInfo["artifacts"],
      label: "reviewed \(name) artifacts"
    )
    guard Set(artifacts.keys) == ["config.json", "model.safetensors"],
      try canonicalJSONValue(artifacts) == canonicalJSONValue(reviewedArtifacts)
    else {
      try fail("\(name) model artifact closure is incomplete.")
    }
    var sourceArtifacts: [[String: Any]] = []
    for filename in ["config.json", "model.safetensors"] {
      let artifact = try dictionary(artifacts[filename], label: "\(name) \(filename)")
      guard Set(artifact.keys) == ["sha256", "size_bytes"],
        let evidence = fileEvidence["\(prefix)/\(filename)"],
        string(artifact, "sha256") == evidence.sha256,
        unsignedInteger(artifact["size_bytes"]) == evidence.size
      else {
        try fail("\(name) artifact does not match the signed model bytes: \(filename)")
      }
      sourceArtifacts.append([
        "name": filename,
        "sha256": evidence.sha256,
        "size": NSNumber(value: evidence.size),
        "url":
          "https://huggingface.co/\(string(info, "repo_id"))/resolve/\(string(info, "resolved_sha"))/\(filename)",
      ])
    }
    var record = componentRecord(
      id: "model:\(name.lowercased())",
      name: name,
      type: "model",
      version: string(info, "requested_revision"),
      revision: string(info, "resolved_sha"),
      source: "https://huggingface.co/\(string(info, "repo_id"))",
      buildCommand: "./scripts/toolchain/build_da3_mps.sh",
      license: "Apache-2.0",
      licenseFiles: ["\(prefix)/LICENSE"],
      linkage: "model-data",
      dependencies: ["da3"]
    )
    record["sourceArtifacts"] = sourceArtifacts
    expected["model:\(name.lowercased())"] = record
  }

  private static func validateDistributionSigning(
    _ receipt: JSONObject,
    receiptData: Data,
    supplyChain: JSONObject,
    version: String,
    sourceRepository: String?,
    reviewed: ReviewedSourceClosure,
    evidence: [String: FileEvidence],
    colmap: JSONObject,
    support: JSONObject,
    msplat: JSONObject
  ) throws -> DistributionSigningClosure {
    let requiredKeys = Set([
      "schemaVersion", "kind", "toolchainVersion", "identityFingerprintSHA1",
      "teamID", "signedAt", "sourceCommit", "sourceInputs", "unsignedComponentArchives",
      "builderAttestedUnsignedRequestSHA256", "builderAttestedUnsignedManifestSHA256",
      "unsignedSupplyChainSHA256", "machOFiles", "recordRepairs",
    ])
    let fingerprint = string(receipt, "identityFingerprintSHA1")
    let teamID = string(receipt, "teamID")
    let signedAt = string(receipt, "signedAt")
    guard Set(receipt.keys) == requiredKeys,
      integer(receipt["schemaVersion"]) == 1,
      string(receipt, "kind") == "easysplat-distribution-signing",
      string(receipt, "toolchainVersion") == version,
      uppercaseHex(fingerprint, count: 40),
      teamID.count == 10,
      teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
      canonicalUTCSeconds(signedAt),
      string(receipt, "sourceCommit") == reviewed.commit
    else {
      try fail("Distribution-signing receipt identity or version is invalid.")
    }
    try requireHex(
      string(receipt, "builderAttestedUnsignedRequestSHA256"),
      count: 64,
      label: "source release request"
    )
    try requireHex(
      string(receipt, "builderAttestedUnsignedManifestSHA256"),
      count: 64,
      label: "source release manifest"
    )
    try requireHex(
      string(receipt, "unsignedSupplyChainSHA256"),
      count: 64,
      label: "unsigned supply-chain manifest"
    )

    let sourceInputs = try arrayOfObjects(
      receipt["sourceInputs"],
      label: "distribution-signing source inputs"
    )
    let expectedSourceInputs: [[String: Any]] = try distributionSigningSourcePaths.map { path in
      guard let data = reviewed.distributionSigningInputs[path] else {
        try fail("Reviewed distribution-signing source input is missing: \(path)")
      }
      return ["path": path, "sha256": ManifestBuilder.sha256Hex(data: data)]
    }
    guard try canonicalJSONValue(sourceInputs) == canonicalJSONValue(expectedSourceInputs) else {
      try fail("Distribution-signing tracked source-input closure is incomplete or stale.")
    }

    let sourceArchives = try arrayOfObjects(
      receipt["unsignedComponentArchives"],
      label: "distribution-signing source archives"
    )
    guard sourceArchives.count == 3,
      sourceArchives.map({ string($0, "component") }) == ["core", "base", "small"]
    else {
      try fail("Distribution-signing source archive closure is incomplete.")
    }
    for archive in sourceArchives {
      let name = string(archive, "name")
      guard Set(archive.keys) == ["component", "name", "sha256", "size"],
        !name.isEmpty,
        !name.contains("/"),
        !name.contains("\\"),
        name.hasSuffix(".zip"),
        name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
        let size = unsignedInteger(archive["size"]),
        size > 0,
        size < ManifestBuilder.maximumReleaseAssetBytes
      else {
        try fail("Distribution-signing source archive identity is invalid.")
      }
      try requireHex(
        string(archive, "sha256"),
        count: 64,
        label: "unsigned source archive"
      )
    }

    let supplyRows = try arrayOfObjects(
      supplyChain["files"],
      label: "signed supply-chain files"
    )
    var supplyByPath: [String: JSONObject] = [:]
    for row in supplyRows {
      let path = string(row, "path")
      guard !path.isEmpty, supplyByPath.updateValue(row, forKey: path) == nil else {
        try fail("Signed supply-chain file paths are missing or duplicated.")
      }
    }
    let machORows = try arrayOfObjects(
      receipt["machOFiles"],
      label: "distribution-signing Mach-O files"
    )
    guard
      machORows.map({ string($0, "path") })
        == machORows.map({ string($0, "path") }).sorted()
    else {
      try fail("Distribution-signing Mach-O closure is not canonical.")
    }
    var preSignHashes: [String: String] = [:]
    var pythonRecordByMember: [String: String] = [:]
    for row in machORows {
      let path = string(row, "path")
      let component = string(row, "component")
      let preSign = string(row, "preSignSHA256")
      let postSign = string(row, "postSignSHA256")
      guard
        Set(row.keys) == [
          "path", "component", "preSignSHA256", "postSignSHA256",
          "preSignProvenance", "codesign",
        ],
        let finalEvidence = evidence[path],
        finalEvidence.sha256 == postSign,
        let supply = supplyByPath[path],
        string(supply, "component") == component,
        string(supply, "kind") == "mach-o",
        string(supply, "sha256") == postSign,
        unsignedInteger(supply["size"]) == finalEvidence.size,
        preSignHashes.updateValue(preSign, forKey: path) == nil
      else {
        try fail("Distribution-signing Mach-O bridge is stale or duplicated: \(path)")
      }
      try requireHex(preSign, count: 64, label: "pre-sign Mach-O")
      try requireHex(postSign, count: 64, label: "post-sign Mach-O")
      let codesign = try dictionary(row["codesign"], label: "codesign evidence for \(path)")
      guard string(codesign, "teamIdentifier") == teamID,
        codesign["hardenedRuntime"] as? Bool == true
      else {
        try fail("Distribution-signing codesign evidence is invalid: \(path)")
      }

      let provenance = try arrayOfObjects(
        row["preSignProvenance"],
        label: "pre-sign provenance for \(path)"
      )
      let supplyProvenance = provenance.filter { string($0, "kind") == "supply-chain" }
      guard supplyProvenance.count == 1,
        Set(supplyProvenance[0].keys) == ["kind", "path", "component", "sha256"],
        string(supplyProvenance[0], "path") == "supply-chain/components.json",
        string(supplyProvenance[0], "component") == component,
        string(supplyProvenance[0], "sha256") == preSign
      else {
        try fail(
          "Distribution-signing Mach-O lacks exact unsigned supply-chain provenance: \(path)")
      }
      let buildProvenance = provenance.filter { string($0, "kind") == "build-receipt" }
      let pythonProvenance = provenance.filter { string($0, "kind") == "python-record" }
      guard provenance.count == 1 + buildProvenance.count + pythonProvenance.count,
        buildProvenance.count <= 1,
        pythonProvenance.count <= 1
      else {
        try fail("Distribution-signing Mach-O provenance is ambiguous: \(path)")
      }
      if let python = pythonProvenance.first {
        let recordPath = string(python, "path")
        guard Set(python.keys) == ["kind", "path", "member", "sha256"],
          recordPath.hasSuffix(".dist-info/RECORD"),
          !string(python, "member").isEmpty,
          string(python, "sha256") == preSign,
          pythonRecordByMember.updateValue(recordPath, forKey: path) == nil
        else {
          try fail("Distribution-signing Python RECORD provenance is invalid: \(path)")
        }
      }
    }
    let expectedMachOs = Set(
      supplyRows.filter { string($0, "kind") == "mach-o" }
        .map { string($0, "path") })
    guard Set(preSignHashes.keys) == expectedMachOs else {
      try fail("Distribution-signing receipt has a missing or extra Mach-O bridge.")
    }
    try validateBuildReceiptBridge(
      path: "bin/colmap",
      receiptPath: "provenance/colmap.json",
      pointer: "/executable_sha256",
      receiptHash: string(colmap, "executable_sha256"),
      machORows: machORows
    )
    try validateBuildReceiptBridge(
      path: "bin/easysplat-train",
      receiptPath: "msplat/build_info.json",
      pointer: "/executable_sha256",
      receiptHash: string(msplat, "executable_sha256"),
      machORows: machORows
    )
    let supportLibraries = try dictionary(
      support["library_sha256"],
      label: "COLMAP support library hashes"
    )
    try validateBuildReceiptBridge(
      path: "lib/libomp.dylib",
      receiptPath: "provenance/colmap-support.json",
      pointer: "/library_sha256/lib/libomp.dylib",
      receiptHash: string(supportLibraries, "lib/libomp.dylib"),
      machORows: machORows
    )

    let repairs = try arrayOfObjects(
      receipt["recordRepairs"],
      label: "distribution-signing RECORD repairs"
    )
    guard repairs.map({ string($0, "path") }) == repairs.map({ string($0, "path") }).sorted() else {
      try fail("Distribution-signing RECORD repair closure is not canonical.")
    }
    var repairedMembers: Set<String> = []
    var repairedPaths: Set<String> = []
    for repair in repairs {
      let path = string(repair, "path")
      guard
        Set(repair.keys) == [
          "path", "preRepairSHA256", "postRepairSHA256", "signedMembers",
        ],
        path.hasSuffix(".dist-info/RECORD"),
        repairedPaths.insert(path).inserted,
        let finalEvidence = evidence[path],
        string(repair, "postRepairSHA256") == finalEvidence.sha256
      else {
        try fail("Distribution-signing RECORD repair is stale or duplicated: \(path)")
      }
      try requireHex(
        string(repair, "preRepairSHA256"),
        count: 64,
        label: "pre-repair Python RECORD"
      )
      let members = try arrayOfObjects(
        repair["signedMembers"],
        label: "signed RECORD members for \(path)"
      )
      guard !members.isEmpty,
        members.map({ string($0, "path") }) == members.map({ string($0, "path") }).sorted()
      else {
        try fail("Distribution-signing RECORD repair members are incomplete: \(path)")
      }
      for member in members {
        let memberPath = string(member, "path")
        guard Set(member.keys) == ["path", "preSignSHA256", "postSignSHA256"],
          repairedMembers.insert(memberPath).inserted,
          pythonRecordByMember[memberPath] == path,
          string(member, "preSignSHA256") == preSignHashes[memberPath],
          string(member, "postSignSHA256") == evidence[memberPath]?.sha256
        else {
          try fail("Distribution-signing RECORD repair member is stale: \(memberPath)")
        }
      }
    }
    guard repairedMembers == Set(pythonRecordByMember.keys) else {
      try fail("Distribution-signing RECORD repair member closure is incomplete.")
    }

    let repository = sourceRepository ?? "dud8/EasySplat"
    let component = componentRecord(
      id: "easysplat-distribution-signing",
      name: "EasySplat distribution signing",
      type: "distribution-signing",
      version: version,
      revision: "sha256:\(ManifestBuilder.sha256Hex(data: receiptData))",
      source: "https://github.com/\(repository)",
      buildCommand: "./scripts/release/finalize_signed_toolchain.py",
      license: "MIT",
      licenseFiles: ["licenses/EasySplat/LICENSE"],
      linkage: "distribution-process",
      dependencies: []
    )
    return DistributionSigningClosure(preSignHashes: preSignHashes, component: component)
  }

  private static func validateBuildReceiptBridge(
    path: String,
    receiptPath: String,
    pointer: String,
    receiptHash: String,
    machORows: [JSONObject]
  ) throws {
    guard let row = machORows.first(where: { string($0, "path") == path }) else {
      try fail("Distribution-signing build receipt bridge is missing: \(path)")
    }
    let provenance = try arrayOfObjects(
      row["preSignProvenance"],
      label: "pre-sign provenance for \(path)"
    )
    let buildRows = provenance.filter { string($0, "kind") == "build-receipt" }
    guard buildRows.count == 1,
      Set(buildRows[0].keys) == ["kind", "path", "jsonPointer", "sha256"],
      string(buildRows[0], "path") == receiptPath,
      string(buildRows[0], "jsonPointer") == pointer,
      string(buildRows[0], "sha256") == receiptHash,
      string(row, "preSignSHA256") == receiptHash
    else {
      try fail("Distribution-signing build receipt bridge is stale: \(path)")
    }
  }

  private static func validateSupplyChain(
    _ document: JSONObject,
    version: String,
    inputs: [ManifestArtifactInput],
    components manifestComponents: [ManifestDocument.Component],
    expectedComponents: [String: JSONObject]
  ) throws {
    guard Set(document.keys) == ["schemaVersion", "toolchainVersion", "components", "files"],
      integer(document["schemaVersion"]) == 1,
      string(document, "toolchainVersion") == version
    else {
      try fail("Supply-chain provenance has the wrong schema or toolchain version.")
    }
    let rawComponents = try arrayOfObjects(document["components"], label: "supply-chain components")
    let componentIDs = rawComponents.compactMap { $0["id"] as? String }
    guard componentIDs.count == rawComponents.count,
      componentIDs == componentIDs.sorted(),
      Set(componentIDs).count == componentIDs.count,
      Set(componentIDs) == Set(expectedComponents.keys)
    else {
      try fail("Supply-chain component records are missing, duplicated, or not canonical.")
    }
    let records = Dictionary(uniqueKeysWithValues: zip(componentIDs, rawComponents))
    for id in componentIDs {
      try validateComponentRecord(records[id]!, id: id, installedIDs: Set(componentIDs))
      try requireExactRecord(records[id]!, matches: expectedComponents[id]!, id: id)
    }

    let expectedFiles = try fileEvidence(inputs: inputs, components: manifestComponents)
    let expectedPaths = Set(expectedFiles.keys)
    for id in componentIDs {
      let licenses = try stringArray(
        records[id]?["licenseFiles"], label: "component licenses for \(id)")
      guard Set(licenses).isSubset(of: expectedPaths) else {
        try fail("Supply-chain component license files are outside the signed closure: \(id)")
      }
    }
    let rawFiles = try arrayOfObjects(document["files"], label: "supply-chain files")
    let paths = rawFiles.compactMap { $0["path"] as? String }
    guard paths.count == rawFiles.count,
      paths == paths.sorted(),
      Set(paths).count == paths.count,
      Set(paths) == expectedPaths
    else {
      try fail("Supply-chain file closure is missing, duplicated, or not canonical.")
    }

    var ownedPaths: [String: [String]] = [:]
    for row in rawFiles {
      let path = string(row, "path")
      let owner = string(row, "component")
      guard let expected = expectedFiles[path], records[owner] != nil,
        string(row, "sha256") == expected.sha256,
        unsignedInteger(row["size"]) == expected.size,
        ["file", "mach-o"].contains(string(row, "kind"))
      else {
        try fail("Supply-chain file evidence does not match the signed archive: \(path)")
      }
      if string(row, "kind") == "mach-o" {
        _ = try stringArray(row["dependencies"], label: "Mach-O dependencies for \(path)")
      }
      ownedPaths[owner, default: []].append(path)
    }

    for id in componentIDs {
      let recorded = try stringArray(records[id]?["files"], label: "component files for \(id)")
      guard recorded == recorded.sorted(),
        Set(recorded).count == recorded.count,
        recorded == (ownedPaths[id] ?? []).sorted()
      else {
        try fail("Supply-chain component file ownership is inconsistent: \(id)")
      }
    }
  }

  private static func validateComponentRecord(
    _ record: JSONObject,
    id: String,
    installedIDs: Set<String>
  ) throws {
    guard !string(record, "name").isEmpty,
      !string(record, "type").isEmpty,
      !string(record, "version").isEmpty,
      !string(record, "revision").isEmpty,
      validHTTPS(string(record, "source")),
      !string(record, "license").isEmpty,
      !string(record, "linkage").isEmpty,
      string(record, "buildCommand") == reviewedBuildCommand(for: id)
    else {
      try fail("Supply-chain component record is incomplete or unreviewed: \(id)")
    }
    let licenses = try stringArray(record["licenseFiles"], label: "component licenses for \(id)")
    let dependencies = try stringArray(
      record["dependencies"], label: "component dependencies for \(id)")
    guard !licenses.isEmpty,
      licenses.allSatisfy({ !$0.isEmpty }),
      dependencies == dependencies.sorted(),
      Set(dependencies).count == dependencies.count,
      Set(dependencies).isSubset(of: installedIDs)
    else {
      try fail("Supply-chain component dependency or license closure is invalid: \(id)")
    }
    if let incorporated = record["incorporatedInto"] {
      let owners = try stringArray(incorporated, label: "incorporatedInto for \(id)")
      guard !owners.isEmpty, Set(owners).isSubset(of: installedIDs) else {
        try fail("Supply-chain incorporatedInto closure is invalid: \(id)")
      }
    }
  }

  private static func requireExactRecord(
    _ record: JSONObject,
    matches expected: JSONObject,
    id: String
  ) throws {
    var actual = record
    actual.removeValue(forKey: "files")
    let keys = Set(actual.keys).union(expected.keys)
    let mismatched = try keys.filter { key in
      guard let actualValue = actual[key], let expectedValue = expected[key] else {
        return true
      }
      return try canonicalJSONValue(actualValue) != canonicalJSONValue(expectedValue)
    }.sorted()
    guard mismatched.isEmpty else {
      try fail(
        "Supply-chain component does not match its authoritative receipt: \(id) "
          + "(\(mismatched.joined(separator: ", ")))."
      )
    }
  }

  private static func canonicalJSONObject(_ object: JSONObject) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      try fail("Supply-chain semantic record is not valid JSON.")
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private static func canonicalJSONValue(_ value: Any) throws -> Data {
    try canonicalJSONObject(["value": value])
  }

  private struct LockedRequirement {
    let version: String
    var hashes: Set<String>
  }

  private static func validatePythonRuntimeClosure(
    base: ManifestDocument.Component,
    input: ManifestArtifactInput,
    installedMetadata: [String: (path: String, data: Data, headers: [String: [String]])],
    fileEvidence: [String: FileEvidence]
  ) throws {
    let metadataPaths = installedMetadata.values.map(\.path)
    let siteRoots = Set(
      metadataPaths.compactMap { path -> String? in
        guard let range = path.range(of: "/site-packages/") else { return nil }
        return String(path[..<range.upperBound].dropLast())
      })
    let archivedSiteRoots = Set(
      base.contents.compactMap { path -> String? in
        guard let range = path.range(of: "/site-packages/") else { return nil }
        return String(path[..<range.upperBound].dropLast())
      })
    guard siteRoots.count == 1, let siteRoot = siteRoots.first,
      archivedSiteRoots == siteRoots,
      siteRoot.hasPrefix("da3_mps/python/lib/python")
    else {
      try fail("Python runtime must contain one reviewed site-packages root.")
    }
    let runtimeRoot = "da3_mps/python"
    let archivedPaths = Set(base.contents)
    var ownerByPath: [String: String] = [:]
    let recordPathsBySlug = Dictionary(
      uniqueKeysWithValues: installedMetadata.keys.sorted().map { slug in
        let metadataPath = installedMetadata[slug]!.path
        return (slug, "\(String(metadataPath.dropLast("METADATA".count)))RECORD")
      })
    let recordDataByPath = try readEntries(Array(recordPathsBySlug.values), from: input.zipURL)

    for slug in installedMetadata.keys.sorted() {
      let metadataPath = installedMetadata[slug]!.path
      let distInfo = String(metadataPath.dropLast("METADATA".count))
      let recordPath = recordPathsBySlug[slug] ?? "\(distInfo)RECORD"
      guard archivedPaths.contains(recordPath) else {
        try fail("Installed Python distribution has no RECORD: \(slug)")
      }
      guard let recordData = recordDataByPath[recordPath] else {
        try fail("Installed Python distribution has unreadable RECORD: \(slug)")
      }
      let rows = try parseCSV(recordData, label: "Python RECORD \(slug)")
      var localPaths: Set<String> = []
      for row in rows {
        guard row.count == 3, !row[0].isEmpty else {
          try fail("Python RECORD row is malformed: \(slug)")
        }
        let resolved = try resolveRecordPath(row[0], relativeTo: siteRoot)
        if !archivedPaths.contains(resolved) {
          if resolved.hasSuffix(".pyc") { continue }
          try fail("Python RECORD member is missing: \(slug): \(resolved)")
        }
        guard resolved == runtimeRoot || resolved.hasPrefix("\(runtimeRoot)/") else {
          try fail("Python RECORD member escapes the runtime: \(slug): \(resolved)")
        }
        guard localPaths.insert(resolved).inserted,
          ownerByPath.updateValue(slug, forKey: resolved) == nil
        else {
          try fail("Python RECORD ownership overlaps or duplicates: \(resolved)")
        }
        guard let evidence = fileEvidence[resolved] else {
          try fail("Python RECORD member has no signed file evidence: \(resolved)")
        }
        let isRecord = resolved == recordPath
        if row[1].isEmpty || row[2].isEmpty {
          guard isRecord, row[1].isEmpty, row[2].isEmpty else {
            try fail("Python RECORD omits hash or size for a payload file: \(resolved)")
          }
        } else {
          guard row[1].hasPrefix("sha256=") else {
            try fail("Python RECORD uses an unsupported hash: \(resolved)")
          }
          let encoded = String(row[1].dropFirst("sha256=".count))
          guard encoded == (try base64URLSHA256(hex: evidence.sha256)),
            row[2] == String(evidence.size)
          else {
            try fail("Python RECORD hash or size does not match the signed runtime: \(resolved)")
          }
        }
      }
      guard ownerByPath[metadataPath] == slug, ownerByPath[recordPath] == slug else {
        try fail("Python RECORD does not own its distribution metadata: \(slug)")
      }
    }

    let sitePackageFiles = Set(base.contents.filter { $0.hasPrefix("\(siteRoot)/") })
    guard Set(ownerByPath.keys).intersection(sitePackageFiles) == sitePackageFiles else {
      let missing = sitePackageFiles.subtracting(ownerByPath.keys).sorted().first ?? "unknown"
      try fail("Python site-packages contains a file absent from every RECORD: \(missing)")
    }
  }

  private static func resolveRecordPath(_ path: String, relativeTo root: String) throws -> String {
    let rawParts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
      rawParts.allSatisfy({ !$0.isEmpty && $0 != "." })
    else {
      try fail("Python RECORD contains an unsafe path.")
    }
    var parts = root.split(separator: "/").map(String.init)
    for part in rawParts {
      switch part {
      case "", ".": continue
      case "..":
        guard !parts.isEmpty else { try fail("Python RECORD path escapes its runtime.") }
        parts.removeLast()
      default:
        parts.append(String(part))
      }
    }
    return parts.joined(separator: "/")
  }

  private static func parseCSV(_ data: Data, label: String) throws -> [[String]] {
    guard let text = String(data: data, encoding: .utf8) else {
      try fail("\(label) is not UTF-8.")
    }
    var rows: [[String]] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      var fields: [String] = []
      var field = ""
      var quoted = false
      var index = line.startIndex
      while index < line.endIndex {
        let character = line[index]
        if quoted {
          if character == "\"" {
            let next = line.index(after: index)
            if next < line.endIndex, line[next] == "\"" {
              field.append("\"")
              index = next
            } else {
              quoted = false
            }
          } else {
            field.append(character)
          }
        } else if character == "," {
          fields.append(field)
          field = ""
        } else if character == "\"", field.isEmpty {
          quoted = true
        } else {
          field.append(character)
        }
        index = line.index(after: index)
      }
      guard !quoted else { try fail("\(label) contains an unterminated quoted field.") }
      fields.append(field)
      rows.append(fields)
    }
    return rows
  }

  private static func base64URLSHA256(hex: String) throws -> String {
    try requireHex(hex, count: 64, label: "Python RECORD file hash")
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else {
        try fail("Python RECORD file hash is malformed.")
      }
      data.append(byte)
      index = next
    }
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func parseRequirementsLock(_ data: Data) throws -> [String: LockedRequirement] {
    guard let text = String(data: data, encoding: .utf8) else {
      try fail("Python requirements lock is not UTF-8.")
    }
    var result: [String: LockedRequirement] = [:]
    var current: String?
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if rawLine.first?.isWhitespace == false {
        let declaration = line.split(separator: " ", maxSplits: 1)[0]
        let parts = declaration.split(separator: "=", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[1].isEmpty else {
          try fail("Python requirements lock contains an unsupported declaration.")
        }
        let slug = pythonSlug(String(parts[0]))
        var version = String(parts[2])
        if version.hasSuffix("\\") { version.removeLast() }
        guard !slug.isEmpty, !version.isEmpty, result[slug] == nil else {
          try fail("Python requirements lock contains a duplicate or malformed package.")
        }
        result[slug] = LockedRequirement(version: version, hashes: [])
        current = slug
      }
      if let range = line.range(of: "--hash=sha256:"), let current {
        var digest = String(line[range.upperBound...])
        if let whitespace = digest.firstIndex(where: { $0.isWhitespace }) {
          digest = String(digest[..<whitespace])
        }
        if digest.hasSuffix("\\") { digest.removeLast() }
        try requireHex(digest, count: 64, label: "Python requirements artifact")
        result[current]?.hashes.insert(digest)
      }
    }
    guard !result.isEmpty, result.values.allSatisfy({ !$0.hashes.isEmpty }) else {
      try fail("Python requirements lock has missing artifact hashes.")
    }
    return result
  }

  private static func directDistributionMetadataPath(_ path: String) -> Bool {
    let marker = "/site-packages/"
    guard path.hasSuffix(".dist-info/METADATA"),
      let range = path.range(of: marker)
    else { return false }
    let suffix = path[range.upperBound...]
    return suffix.split(separator: "/").count == 2
  }

  private static func parseMetadata(_ data: Data) -> [String: [String]] {
    guard let text = String(data: data, encoding: .utf8) else { return [:] }
    var result: [String: [String]] = [:]
    var lastKey: String?
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.isEmpty { break }
      if line.first?.isWhitespace == true, let lastKey,
        var values = result[lastKey], !values.isEmpty
      {
        values[values.count - 1] += line.trimmingCharacters(in: .whitespaces)
        result[lastKey] = values
        continue
      }
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      result[key, default: []].append(value)
      lastKey = key
    }
    return result
  }

  private static func pythonSlug(_ value: String) -> String {
    var result = ""
    var pendingSeparator = false
    for character in value.lowercased() {
      if character == "-" || character == "_" || character == "." {
        pendingSeparator = !result.isEmpty
      } else {
        if pendingSeparator { result.append("-") }
        result.append(character)
        pendingSeparator = false
      }
    }
    return result
  }

  private static func pythonSource(
    headers: [String: [String]],
    name: String,
    version: String
  ) -> String {
    var projectURLs: [String: String] = [:]
    for entry in headers["project-url"] ?? [] {
      let parts = entry.split(separator: ",", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.count == 2 { projectURLs[parts[0].lowercased()] = parts[1] }
    }
    for key in ["source", "repository", "homepage"] {
      if let candidate = projectURLs[key], validHTTPS(candidate) { return candidate }
    }
    if let home = headers["home-page"]?.first, validHTTPS(home) { return home }
    return "https://pypi.org/project/\(name)/\(version)/"
  }

  private static func pythonLicense(
    headers: [String: [String]],
    package: String
  ) throws -> String {
    if let expression = headers["license-expression"]?.first, !expression.isEmpty {
      return normalizedLicense(expression)
    }
    if let legacy = headers["license"]?.first,
      !legacy.isEmpty,
      legacy.count <= 160,
      !["UNKNOWN", "NOASSERTION", "NONE"].contains(legacy.uppercased())
    {
      return normalizedLicense(legacy)
    }
    let classifiers: [String: String] = [
      "Apache Software License": "Apache-2.0",
      "BSD License": "BSD-3-Clause",
      "Boost Software License 1.0 (BSL-1.0)": "BSL-1.0",
      "ISC License (ISCL)": "ISC",
      "MIT License": "MIT",
      "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
      "Python Software Foundation License": "Python-2.0",
    ]
    let prefix = "License :: OSI Approved :: "
    let candidates = Set(
      (headers["classifier"] ?? []).compactMap { value -> String? in
        guard value.hasPrefix(prefix) else { return nil }
        return classifiers[String(value.dropFirst(prefix.count))]
      })
    guard candidates.count == 1, let license = candidates.first else {
      try fail("Python package has no unambiguous license metadata: \(package)")
    }
    return license
  }

  private static func pythonDependencies(
    headers: [String: [String]],
    installedIDs: Set<String>
  ) -> [String] {
    let delimiters = CharacterSet(charactersIn: " (;<>=!~")
    return Set(
      (headers["requires-dist"] ?? []).compactMap { requirement -> String? in
        let name = requirement.components(separatedBy: delimiters).first ?? ""
        let id = "python:\(pythonSlug(name))"
        return installedIDs.contains(id) ? id : nil
      }
    ).sorted()
  }

  private static func normalizedLicense(_ value: String) -> String {
    let aliases: [String: String] = [
      "apache 2.0": "Apache-2.0",
      "apache 2.0 license": "Apache-2.0",
      "apache-2.0": "Apache-2.0",
      "apache software license": "Apache-2.0",
      "bsd": "BSD-3-Clause",
      "bsd-3-clause": "BSD-3-Clause",
      "bsd license": "BSD-3-Clause",
      "mit": "MIT",
      "mit license": "MIT",
      "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0",
      "mpl-2.0": "MPL-2.0",
      "python software foundation license": "Python-2.0",
      "python-2.0": "Python-2.0",
      "isc": "ISC",
      "isc license": "ISC",
      "isc license (iscl)": "ISC",
      "boost software license": "BSL-1.0",
      "bsl-1.0": "BSL-1.0",
    ]
    return aliases[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
      ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func archiveLike(_ source: String) -> Bool {
    let path = URL(string: source)?.path.lowercased() ?? ""
    return [".zip", ".tar", ".tar.gz", ".tar.xz", ".tgz", ".txz"]
      .contains(where: path.hasSuffix)
  }

  private static func sourceIdentity(
    _ object: JSONObject,
    revisionKeys: [String],
    label: String,
    license: String? = nil
  ) throws -> Identity {
    let source = string(object, "source_url")
    let version = string(object, "source_version")
    let revision = revisionKeys.lazy.map { string(object, $0) }.first(where: { !$0.isEmpty }) ?? ""
    let resolvedLicense = license ?? string(object, "license")
    guard validHTTPS(source), !version.isEmpty, !revision.isEmpty, !resolvedLicense.isEmpty else {
      try fail("\(label) source provenance is incomplete.")
    }
    return Identity(source: source, version: version, revision: revision, license: resolvedLicense)
  }

  private static func dependencyIdentity(_ value: Any?, label: String) throws -> Identity {
    let object = try dictionary(value, label: label)
    let identity = try sourceIdentity(
      object,
      revisionKeys: [
        "source_commit", "source_sha256", "source_archive_sha256", "source_tree_sha256",
      ],
      label: label
    )
    if let commit = object["source_commit"] as? String {
      try requireHex(commit, count: 40, label: "\(label) source commit")
    }
    let sourceDigestKeys = [
      "source_sha256", "source_archive_sha256", "source_tree_sha256",
    ].filter { object[$0] != nil }
    guard sourceDigestKeys.count == 1 else {
      try fail("\(label) artifact provenance has an ambiguous source hash.")
    }
    guard let sourceDigest = object[sourceDigestKeys[0]] as? String,
      !sourceDigest.isEmpty
    else {
      try fail("\(label) has no source hash.")
    }
    try requireHex(sourceDigest, count: 64, label: "\(label) source hash")
    let licenses = try stringArray(object["license_files"], label: "\(label) license files")
    guard !licenses.isEmpty, licenses.allSatisfy({ !$0.isEmpty }) else {
      try fail("\(label) has no license evidence.")
    }
    _ = try dependencyArtifact(object, label: label)
    return identity
  }

  private static func dependencyArtifact(
    _ object: JSONObject,
    label: String
  ) throws -> (url: String, sha256: String)? {
    let source = string(object, "source_url")
    let sourceDigestKeys = [
      "source_sha256", "source_archive_sha256", "source_tree_sha256",
    ].filter { object[$0] != nil }
    guard sourceDigestKeys.count == 1,
      let sourceDigest = object[sourceDigestKeys[0]] as? String,
      !sourceDigest.isEmpty
    else {
      try fail("\(label) artifact provenance has an ambiguous source hash.")
    }
    let artifactURL = object["artifact_url"] as? String
    let artifactSHA256 = object["artifact_sha256"] as? String
    let sourceArchiveURL = object["source_archive_url"] as? String
    let hasArtifactURL = object.keys.contains("artifact_url")
    let hasArtifactSHA256 = object.keys.contains("artifact_sha256")
    let hasSourceArchiveURL = object.keys.contains("source_archive_url")

    if hasArtifactURL || hasArtifactSHA256 {
      guard !hasSourceArchiveURL,
        sourceDigestKeys[0] == "source_sha256",
        let artifactURL,
        let artifactSHA256,
        validHTTPS(artifactURL),
        artifactURL == source,
        archiveLike(artifactURL),
        artifactSHA256 == sourceDigest
      else {
        try fail("\(label) artifact provenance is not bound to the reviewed source archive.")
      }
      try requireHex(artifactSHA256, count: 64, label: "\(label) artifact")
      return (artifactURL, artifactSHA256)
    }

    if hasSourceArchiveURL {
      guard let sourceArchiveURL,
        sourceDigestKeys[0] == "source_archive_sha256",
        validHTTPS(sourceArchiveURL),
        sourceArchiveURL == source,
        archiveLike(sourceArchiveURL)
      else {
        try fail("\(label) source archive is not bound to the reviewed source archive.")
      }
      try requireHex(sourceDigest, count: 64, label: "\(label) source archive")
      return (sourceArchiveURL, sourceDigest)
    }

    if archiveLike(source), sourceDigestKeys[0] != "source_tree_sha256" {
      return (source, sourceDigest)
    }
    return nil
  }

  private static func fileEvidence(
    inputs: [ManifestArtifactInput],
    components: [ManifestDocument.Component]
  ) throws -> [String: FileEvidence] {
    var result: [String: FileEvidence] = [:]
    for input in inputs {
      guard let component = components.first(where: { $0.name == input.name }) else {
        try fail("Production component metadata is incomplete: \(input.name)")
      }
      let sizes = try archiveFileSizes(input.zipURL)
      for path in component.contents where path != "supply-chain/components.json" {
        guard let digest = component.criticalFileHashes[path], let size = sizes[path],
          result.updateValue(FileEvidence(sha256: digest, size: size), forKey: path) == nil
        else {
          try fail("Production component file evidence overlaps or is incomplete: \(path)")
        }
      }
    }
    return result
  }

  private static func reviewedBuildCommand(for id: String) -> String? {
    if id == "colmap" || id.hasPrefix("colmap:") {
      return "./scripts/toolchain/build_colmap.sh"
    }
    if id == "colmap-support" || id.hasPrefix("colmap-support:") {
      return "./scripts/toolchain/build_colmap_support.sh"
    }
    if id == "ceres" || id.hasPrefix("ceres:") {
      return "./scripts/toolchain/build_ceres.sh"
    }
    if id == "openimageio" || id.hasPrefix("openimageio:") {
      return "./scripts/toolchain/build_openimageio.sh"
    }
    if id == "msplat" || id.hasPrefix("msplat:") {
      return "./scripts/toolchain/build_msplat.sh"
    }
    if ["da3", "easysplat-da3-runner", "python-build-standalone"].contains(id)
      || id.hasPrefix("model:") || id.hasPrefix("python:")
    {
      return "./scripts/toolchain/build_da3_mps.sh"
    }
    if id == "easysplat-distribution-signing" {
      return "./scripts/release/finalize_signed_toolchain.py"
    }
    return nil
  }

  private static func requireLockDependency(
    _ value: Any?,
    lock lockValue: Any?,
    label: String
  ) throws {
    let lock = try dictionary(lockValue, label: "\(label) reviewed source lock")
    let source = try dictionary(lock["source"], label: "\(label) reviewed source")
    try requireReviewedDependency(
      value,
      source: string(source, "url"),
      version: string(lock, "version"),
      commit: string(lock, "commit").isEmpty ? nil : string(lock, "commit"),
      sha256: string(source, "sha256"),
      license: string(lock, "license"),
      label: label
    )
  }

  private static func requireReviewedDependency(
    _ value: Any?,
    source: String,
    version: String,
    commit: String?,
    sha256: String?,
    license: String,
    label: String
  ) throws {
    let dependency = try dictionary(value, label: label)
    _ = try dependencyIdentity(dependency, label: label)
    guard string(dependency, "source_url") == source,
      string(dependency, "source_version") == version,
      string(dependency, "license") == license,
      commit == nil || string(dependency, "source_commit") == commit
    else {
      try fail("\(label) provenance does not match the reviewed source lock.")
    }
    if let sha256 {
      let receiptDigest = ["source_sha256", "source_archive_sha256", "source_tree_sha256"]
        .lazy.map { string(dependency, $0) }.first(where: { !$0.isEmpty })
      guard receiptDigest == sha256 else {
        try fail("\(label) provenance does not match the reviewed source lock.")
      }
    } else {
      let digestKeys = [
        "source_sha256", "source_archive_sha256", "source_tree_sha256",
      ].filter { dependency[$0] != nil }
      guard digestKeys == ["source_tree_sha256"] else {
        try fail("\(label) provenance does not match the reviewed source lock.")
      }
    }
  }

  private static func archiveRepository(_ rawURL: String?) throws -> String {
    guard let rawURL, let marker = rawURL.range(of: "/archive/") else {
      try fail("Reviewed archive URL has an unsupported repository shape.")
    }
    return String(rawURL[..<marker.lowerBound])
  }

  private static func archiveTagVersion(_ rawURL: String?) throws -> String {
    guard let rawURL,
      let marker = rawURL.range(of: "/refs/tags/v"),
      rawURL.hasSuffix(".zip")
    else {
      try fail("Reviewed archive URL has an unsupported tag shape.")
    }
    return String(rawURL[marker.upperBound..<rawURL.index(rawURL.endIndex, offsetBy: -4)])
  }

  private static func shellAssignments(_ data: Data, names: Set<String>) throws -> [String: String]
  {
    guard let text = String(data: data, encoding: .utf8) else {
      try fail("Reviewed source lock is not UTF-8.")
    }
    var values: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine)
      guard let separator = line.firstIndex(of: "=") else { continue }
      let name = String(line[..<separator])
      guard names.contains(name) else { continue }
      let rawValue = String(line[line.index(after: separator)...])
      guard rawValue.count >= 2, rawValue.first == "\"", rawValue.last == "\"",
        values.updateValue(String(rawValue.dropFirst().dropLast()), forKey: name) == nil
      else {
        try fail("Reviewed source lock has a duplicate or unsupported assignment: \(name)")
      }
    }
    guard Set(values.keys) == names else {
      try fail("Reviewed source lock is missing a required assignment.")
    }
    return values
  }

  private static func expandedShellValue(
    _ value: String,
    assignments: [String: String]
  ) throws -> String {
    var result = value
    for _ in 0..<assignments.count {
      guard let start = result.range(of: "${") else { return result }
      guard let end = result[start.upperBound...].firstIndex(of: "}") else {
        try fail("Reviewed source lock has an unsupported interpolation.")
      }
      let name = String(result[start.upperBound..<end])
      guard let replacement = assignments[name] else {
        try fail("Reviewed source lock references an unknown assignment: \(name)")
      }
      result.replaceSubrange(start.lowerBound...end, with: replacement)
    }
    guard !result.contains("${") else {
      try fail("Reviewed source lock interpolation is recursive.")
    }
    return result
  }

  private static func repositoryRoot() throws -> URL {
    let data = try gitData([
      "-C", FileManager.default.currentDirectoryPath,
      "rev-parse", "--show-toplevel",
    ])
    let path = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { try fail("Unable to locate the reviewed source checkout.") }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }

  private static func gitData(_ arguments: [String]) throws -> Data {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0,
      data.count <= 2 * 1_024 * 1_024
    else {
      try fail("Unable to read the reviewed source lock from the release commit.")
    }
    return data
  }

  private static func reviewedWorkingTreeData(_ path: String, root: URL) throws -> Data {
    try requireSafeArchiveMemberName(path)
    let rootPath = root.standardizedFileURL.path
    let file = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
    guard file.path.hasPrefix("\(rootPath)/") else {
      try fail("Reviewed source path escapes the checkout.")
    }
    var status = stat()
    guard lstat(file.path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_nlink == 1,
      status.st_size > 0,
      status.st_size <= 8 * 1_024 * 1_024
    else {
      try fail("Unable to read the reviewed source lock from the working tree.")
    }
    return try Data(contentsOf: file)
  }

  private static func readEntry(_ path: String, from archive: URL) throws -> Data {
    let limit =
      path == "supply-chain/components.json"
      ? supplyChainReceiptLimit
      : ordinaryReceiptLimit
    let limitLabel = path == "supply-chain/components.json" ? "16 MiB" : "1 MiB"
    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, path]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()

    var data = Data()
    while true {
      let chunk = try stdout.fileHandleForReading.read(upToCount: 64 * 1_024) ?? Data()
      if chunk.isEmpty { break }
      guard chunk.count <= limit, data.count <= limit - chunk.count else {
        process.terminate()
        process.waitUntilExit()
        try fail("Provenance receipt exceeds the \(limitLabel) safety limit: \(path)")
      }
      data.append(chunk)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0, !data.isEmpty else {
      try fail("Unable to read required provenance receipt: \(path)")
    }
    return data
  }

  private static func readEntries(_ paths: [String], from archive: URL) throws -> [String: Data] {
    let uniquePaths = Array(Set(paths)).sorted()
    guard !uniquePaths.isEmpty else { return [:] }
    for path in uniquePaths {
      try requireSafeArchiveMemberName(path)
    }
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasySplatManifestEntries-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-qq", archive.path] + uniquePaths + ["-d", temporaryRoot.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      try fail("Unable to extract required provenance receipts.")
    }

    var result: [String: Data] = [:]
    for path in uniquePaths {
      let extracted = temporaryRoot.appendingPathComponent(path, isDirectory: false)
      var status = stat()
      guard lstat(extracted.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_nlink == 1,
        status.st_size > 0
      else {
        try fail("Extracted provenance receipt is not a regular file: \(path)")
      }
      let limit =
        path == "supply-chain/components.json"
        ? supplyChainReceiptLimit
        : ordinaryReceiptLimit
      guard UInt64(status.st_size) <= UInt64(limit) else {
        let limitLabel = path == "supply-chain/components.json" ? "16 MiB" : "1 MiB"
        try fail("Provenance receipt exceeds the \(limitLabel) safety limit: \(path)")
      }
      result[path] = try Data(contentsOf: extracted)
    }
    return result
  }

  private static func requireSafeArchiveMemberName(_ path: String) throws {
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.contains("\\")
    else {
      try fail("Archive member path is unsafe: \(path)")
    }
    for component in path.split(separator: "/", omittingEmptySubsequences: false) {
      if component.isEmpty || component == "." || component == ".." {
        try fail("Archive member path is unsafe: \(path)")
      }
    }
  }

  private static func archiveFileSizes(_ archive: URL) throws -> [String: UInt64] {
    var archiveStatus = stat()
    guard lstat(archive.path, &archiveStatus) == 0,
      (archiveStatus.st_mode & S_IFMT) == S_IFREG,
      archiveStatus.st_size > 0
    else {
      try fail("Production archive is not a bounded regular file.")
    }
    let cacheKey = ArchiveSizeCacheKey(
      path: archive.path,
      device: UInt64(archiveStatus.st_dev),
      inode: UInt64(archiveStatus.st_ino),
      size: Int64(archiveStatus.st_size),
      modifiedSeconds: Int64(archiveStatus.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(archiveStatus.st_mtimespec.tv_nsec),
      changedSeconds: Int64(archiveStatus.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(archiveStatus.st_ctimespec.tv_nsec)
    )
    if let cached = archiveSizeCache.sizes(for: cacheKey) {
      return cached
    }

    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    process.arguments = ["-l", archive.path]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      try fail("Unable to inspect production archive sizes.")
    }
    var result: [String: UInt64] = [:]
    for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
      guard line.first == "-" else { continue }
      let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
      guard fields.count == 10,
        let size = UInt64(fields[3]),
        result.updateValue(size, forKey: String(fields[9])) == nil
      else {
        try fail("Production archive has malformed or duplicate size metadata.")
      }
    }
    archiveSizeCache.store(result, for: cacheKey)
    return result
  }

  private static func object(_ data: Data, label: String) throws -> JSONObject {
    do {
      guard let result = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
        try fail("\(label) must be a JSON object.")
      }
      return result
    } catch {
      try fail("\(label) is not valid JSON: \(error.localizedDescription)")
    }
  }

  private static func dictionary(_ value: Any?, label: String) throws -> JSONObject {
    guard let result = value as? JSONObject else {
      try fail("\(label) must be a JSON object.")
    }
    return result
  }

  private static func arrayOfObjects(_ value: Any?, label: String) throws -> [JSONObject] {
    guard let result = value as? [JSONObject] else {
      try fail("\(label) must be an array of JSON objects.")
    }
    return result
  }

  private static func stringArray(_ value: Any?, label: String) throws -> [String] {
    guard let result = value as? [String] else {
      try fail("\(label) must be an array of strings.")
    }
    return result
  }

  private static func string(_ object: JSONObject, _ key: String) -> String {
    object[key] as? String ?? ""
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return Int(number.stringValue)
  }

  private static func unsignedInteger(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return UInt64(number.stringValue)
  }

  private static func validHTTPS(_ value: String) -> Bool {
    guard let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return false
    }
    return true
  }

  private static func uppercaseHex(_ value: String, count: Int) -> Bool {
    value.count == count
      && value.allSatisfy({ ("0"..."9").contains($0) || ("A"..."F").contains($0) })
  }

  private static func canonicalUTCSeconds(_ value: String) -> Bool {
    guard value.count == 20,
      value[value.index(value.startIndex, offsetBy: 4)] == "-",
      value[value.index(value.startIndex, offsetBy: 7)] == "-",
      value[value.index(value.startIndex, offsetBy: 10)] == "T",
      value[value.index(value.startIndex, offsetBy: 13)] == ":",
      value[value.index(value.startIndex, offsetBy: 16)] == ":",
      value.last == "Z"
    else {
      return false
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
  }

  private static func requireHex(_ value: String, count: Int, label: String) throws {
    guard value.count == count,
      value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
    else {
      try fail("\(label) is not canonical lowercase hexadecimal evidence.")
    }
  }

  private static func fail(_ message: String) throws -> Never {
    throw NSError(
      domain: "ManifestTool",
      code: 14,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
