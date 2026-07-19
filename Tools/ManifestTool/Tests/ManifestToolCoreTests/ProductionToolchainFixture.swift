import CryptoKit
import Foundation

@testable import ManifestToolCore

struct ProductionToolchainFileFixture {
  private struct PythonPackage {
    let slug: String
    let version: String
    let dependencies: [String]
  }

  static let colmapCommit = "a0d785fba74b2664f31edc4a29026a8b27c00f67"
  static let ceresCommit = "85331393dc0dff09f6fb9903ab0c4bfa3e134b01"
  static let msplatCommit = "106499b0a53f82b0c92d013b0861fbebd341b17e"
  static let sourceArchiveSHA256 = String(repeating: "4", count: 64)
  static let signedPythonMemberPath =
    "da3_mps/python/lib/python3.13/site-packages/numpy/_core/_multiarray_umath.cpython-313-darwin.so"
  static let signedPythonRecordPath =
    "da3_mps/python/lib/python3.13/site-packages/numpy-2.3.5.dist-info/RECORD"
  private static let da3Commit = "41736238f5bced4debf3f2a12375d2466874866d"
  private static let baseModelCommit = "f4a6c9b3c95e41c82048423d3493a81ec3fa810e"
  private static let smallModelCommit = "e08cab65ca0ec38e7826075418411ab90cab4da3"
  private static let repositoryRoot: URL = {
    var result = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { result.deleteLastPathComponent() }
    return result
  }()
  private static let supportLockData = try! Data(
    contentsOf: repositoryRoot.appendingPathComponent("scripts/toolchain/colmap-support-lock.json")
  )
  private static let ceresLockData = try! Data(
    contentsOf: repositoryRoot.appendingPathComponent("scripts/toolchain/ceres-lock.json")
  )
  private static let openImageIOLockData = try! Data(
    contentsOf: repositoryRoot.appendingPathComponent("scripts/toolchain/openimageio-lock.json")
  )
  private static let requirementsLockData = try! Data(
    contentsOf: repositoryRoot.appendingPathComponent("Tools/Da3Sfm/requirements.txt")
  )
  private static let runtimePatchData = try! Data(
    contentsOf: repositoryRoot.appendingPathComponent(
      "Tools/Da3Sfm/patches/da3-api-lazy-export.patch"
    )
  )
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
  private static let pythonPackages: [PythonPackage] = [
    .init(slug: "addict", version: "2.4.0", dependencies: []),
    .init(slug: "annotated-doc", version: "0.0.4", dependencies: []),
    .init(slug: "antlr4-python3-runtime", version: "4.9.3", dependencies: []),
    .init(
      slug: "anyio", version: "4.14.1", dependencies: ["python:idna", "python:typing-extensions"]),
    .init(slug: "certifi", version: "2026.6.17", dependencies: []),
    .init(slug: "einops", version: "0.8.2", dependencies: []),
    .init(slug: "filelock", version: "3.29.7", dependencies: []),
    .init(
      slug: "fsspec", version: "2026.6.0",
      dependencies: ["python:jinja2", "python:numpy", "python:tqdm"]),
    .init(slug: "h11", version: "0.16.0", dependencies: []),
    .init(slug: "hf-xet", version: "1.5.1", dependencies: []),
    .init(
      slug: "httpcore", version: "1.0.9",
      dependencies: ["python:anyio", "python:certifi", "python:h11"]),
    .init(
      slug: "httpx", version: "0.28.1",
      dependencies: [
        "python:anyio", "python:certifi", "python:httpcore", "python:idna", "python:pygments",
        "python:rich",
      ]),
    .init(
      slug: "huggingface-hub", version: "1.14.0",
      dependencies: [
        "python:filelock", "python:fsspec", "python:hf-xet", "python:httpx", "python:jinja2",
        "python:numpy", "python:packaging", "python:pillow", "python:pyyaml", "python:torch",
        "python:tqdm", "python:typer", "python:typing-extensions",
      ]),
    .init(slug: "idna", version: "3.18", dependencies: []),
    .init(slug: "jinja2", version: "3.1.6", dependencies: ["python:markupsafe"]),
    .init(
      slug: "markdown-it-py", version: "4.2.0", dependencies: ["python:mdurl", "python:pyyaml"]),
    .init(slug: "markupsafe", version: "3.0.3", dependencies: []),
    .init(slug: "mdurl", version: "0.1.2", dependencies: []),
    .init(slug: "mpmath", version: "1.3.0", dependencies: []),
    .init(
      slug: "networkx", version: "3.6.1",
      dependencies: ["python:numpy", "python:pillow", "python:sympy"]),
    .init(slug: "numpy", version: "2.3.5", dependencies: []),
    .init(
      slug: "omegaconf", version: "2.3.0",
      dependencies: ["python:antlr4-python3-runtime", "python:pyyaml"]),
    .init(slug: "packaging", version: "26.2", dependencies: []),
    .init(slug: "pillow", version: "12.2.0", dependencies: ["python:packaging"]),
    .init(slug: "pygments", version: "2.20.0", dependencies: []),
    .init(slug: "pyyaml", version: "6.0.3", dependencies: []),
    .init(
      slug: "rich", version: "15.0.0", dependencies: ["python:markdown-it-py", "python:pygments"]),
    .init(
      slug: "safetensors", version: "0.7.0",
      dependencies: ["python:huggingface-hub", "python:numpy", "python:packaging", "python:torch"]),
    .init(
      slug: "setuptools", version: "81.0.0", dependencies: ["python:filelock", "python:packaging"]),
    .init(slug: "shellingham", version: "1.5.4", dependencies: []),
    .init(slug: "sympy", version: "1.14.0", dependencies: ["python:mpmath"]),
    .init(
      slug: "torch", version: "2.12.1",
      dependencies: [
        "python:filelock", "python:fsspec", "python:jinja2", "python:networkx", "python:pyyaml",
        "python:setuptools", "python:sympy", "python:typing-extensions",
      ]),
    .init(
      slug: "torchvision", version: "0.27.1",
      dependencies: ["python:numpy", "python:pillow", "python:torch"]),
    .init(slug: "tqdm", version: "4.68.4", dependencies: []),
    .init(
      slug: "typer", version: "0.26.8",
      dependencies: ["python:annotated-doc", "python:rich", "python:shellingham"]),
    .init(slug: "typing-extensions", version: "4.16.0", dependencies: []),
  ]

  var core: [String: Data]
  var base: [String: Data]
  var small: [String: Data]
  let version: String
  let sourceRepository: String
  let sourceCommit: String

  init(
    version: String = "2.0.0",
    sourceRepository: String = "dud8/EasySplat",
    sourceCommit: String? = nil
  ) throws {
    let sourceCommit = try sourceCommit ?? Self.currentSourceCommit()
    self.version = version
    self.sourceRepository = sourceRepository
    self.sourceCommit = sourceCommit

    let colmap = Data("native-colmap".utf8)
    let trainer = Data("native-msplat".utf8)
    let metallib = Data("native-metallib".utf8)
    core = [
      "bin/colmap": colmap,
      "bin/easysplat-train": trainer,
      "bin/default.metallib": metallib,
      "lib/libomp.dylib": Data("libomp".utf8),
      "msplat/LICENSE": Data("Apache-2.0".utf8),
      "licenses/COLMAP/COPYING.txt": Data("BSD-3-Clause".utf8),
      "licenses/ceres/LICENSE": Data("BSD-3-Clause".utf8),
      "licenses/openimageio/LICENSE": Data("Apache-2.0".utf8),
      "licenses/EasySplat/LICENSE": Data("MIT".utf8),
    ]
    base = Dictionary(
      uniqueKeysWithValues: ManifestToolDefaults.da3BaseContents.map {
        ($0, Data("base:\($0)".utf8))
      })
    small = Dictionary(
      uniqueKeysWithValues: ManifestToolDefaults.da3SmallContents.map {
        ($0, Data("small:\($0)".utf8))
      })

    var vlfeatDependency = Self.dependency(
      name: "vlfeat",
      version: "vendored-at-colmap-4.1.1",
      commit: Self.colmapCommit,
      license: "BSD-2-Clause",
      sourceURL:
        "https://github.com/colmap/colmap/tree/\(Self.colmapCommit)/src/thirdparty/VLFeat"
    )
    vlfeatDependency["source_tree_sha256"] = vlfeatDependency.removeValue(
      forKey: "source_sha256"
    )

    core["provenance/colmap.json"] = try Self.json([
      "schema_version": 2,
      "toolchain_name": "colmap",
      "source_url": "https://github.com/colmap/colmap.git",
      "source_version": "4.1.1",
      "source_commit": Self.colmapCommit,
      "source_tree_sha256": String(repeating: "5", count: 64),
      "license": "BSD-3-Clause",
      "executable_sha256": Self.sha256(colmap),
      "dependencies": [
        "faiss": Self.dependency(
          name: "faiss",
          version: "1.14.3",
          commit: "0ca9df4792b173d573044ee14ca0704780176e82",
          license: "MIT",
          sha256: "fdb01044e707caa7e16d009a8ed11816aebe17fefbccb428c495486e28e6046d",
          sourceURL: "https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.3.zip"
        ),
        "poselib": Self.dependency(
          name: "poselib",
          version: "fa7280fee27f97aff31ae7f98bab7f583fac7d08",
          commit: "fa7280fee27f97aff31ae7f98bab7f583fac7d08",
          license: "BSD-3-Clause",
          sha256: "5408d4ae8ce367cb2f076bc6c5f0f6f78abd3573d2c015304b04e46f23455f5b",
          sourceURL:
            "https://github.com/PoseLib/PoseLib/archive/fa7280fee27f97aff31ae7f98bab7f583fac7d08.zip"
        ),
        "vlfeat": vlfeatDependency,
      ],
    ])
    let supportDependencies: [String: Any] = [
      "boost": try Self.lockDependency(Self.supportLockData, name: "boost"),
      "gflags": try Self.lockDependency(Self.supportLockData, name: "gflags"),
      "glog": try Self.lockDependency(Self.supportLockData, name: "glog"),
      "libomp": try Self.lockDependency(Self.supportLockData, name: "libomp"),
    ]
    core["provenance/colmap-support.json"] = try Self.json([
      "schema_version": 1,
      "toolchain_name": "colmap-support",
      "source_lock_sha256": Self.sha256(Self.supportLockData),
      "library_sha256": ["lib/libomp.dylib": Self.sha256(core["lib/libomp.dylib"]!)],
      "dependencies": supportDependencies,
    ])
    let ceresDependency = try Self.lockDependency(Self.ceresLockData, name: "ceres")
    let eigenDependency = try Self.lockDependency(Self.ceresLockData, name: "eigen")
    core["provenance/ceres.json"] = try Self.json([
      "schema_version": 1,
      "toolchain_name": "ceres-static",
      "source_url": ceresDependency["source_url"]!,
      "source_version": ceresDependency["source_version"]!,
      "source_commit": ceresDependency["source_commit"]!,
      "source_sha256": ceresDependency["source_sha256"]!,
      "license": ceresDependency["license"]!,
      "dependencies": [
        "ceres": ceresDependency,
        "eigen": eigenDependency,
      ],
    ])
    let openImageIODependency = try Self.lockDependency(
      Self.openImageIOLockData,
      name: "openimageio"
    )
    core["provenance/openimageio.json"] = try Self.json([
      "schema_version": 1,
      "toolchain_name": "openimageio-static",
      "dependencies": [
        "boost": try Self.lockDependency(Self.supportLockData, name: "boost"),
        "fmt": try Self.lockDependency(Self.openImageIOLockData, name: "fmt"),
        "imath": try Self.lockDependency(Self.openImageIOLockData, name: "imath"),
        "libjpeg-turbo": try Self.lockDependency(Self.openImageIOLockData, name: "libjpeg-turbo"),
        "libpng": try Self.lockDependency(Self.openImageIOLockData, name: "libpng"),
        "openimageio": openImageIODependency,
        "robin-map": try Self.lockDependency(Self.openImageIOLockData, name: "robin-map"),
      ],
    ])
    core["msplat/build_info.json"] = try Self.json([
      "toolchain_name": "msplat",
      "source_url": "https://github.com/rayanht/msplat.git",
      "source_version": "1.1.3",
      "source_commit": Self.msplatCommit,
      "source_tree_sha256": String(repeating: "b", count: 64),
      "executable_sha256": Self.sha256(trainer),
      "metallib_sha256": Self.sha256(metallib),
      "deployment_target": "macOS 15.0",
      "build_configuration": "Release",
      "build_timestamp": "2026-07-18T00:00:00Z",
      "compiler": "Apple clang",
      "cmake": "cmake 4.0",
      "ninja": "1.13.0",
      "cmake_arguments": ["-G Ninja"],
      "dependencies": [
        "cli11_v2.4.2_sha256": "43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0",
        "nanoflann_v1.5.5_sha256":
          "57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc",
        "nlohmann_json_v3.11.3_sha256":
          "04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069",
      ],
    ])
    try installTransitiveFixtureFiles()
    try refreshSupplyChain()
  }

  private mutating func installTransitiveFixtureFiles() throws {
    let nativeDependencies = [
      "faiss", "poselib", "vlfeat", "boost", "gflags", "glog", "libomp",
      "ceres", "eigen", "fmt", "imath", "libjpeg-turbo", "libpng",
      "openimageio", "robin-map",
    ]
    for name in nativeDependencies {
      core["licenses/\(name)/LICENSE"] = Data("fixture license for \(name)".utf8)
    }
    core["licenses/msplat/CLI11/LICENSE"] = Data("BSD-3-Clause".utf8)
    core["licenses/msplat/nanoflann/COPYING"] = Data("BSD-2-Clause".utf8)
    core["licenses/msplat/nlohmann-json/LICENSE.MIT"] = Data("MIT".utf8)

    base["da3_mps/vendor/depth-anything-3/LICENSE"] = Data("Apache-2.0".utf8)
    base["da3_mps/licenses/python-build-standalone/PYTHON.json"] = try Self.json([
      "name": "python-build-standalone",
      "version": "3.13.11",
    ])
    base["da3_mps/licenses/python-build-standalone/licenses/LICENSE.cpython.txt"] =
      Data("Python-2.0".utf8)
    let supplemental = try Self.json(["schemaVersion": 1, "notices": []])
    base["da3_mps/licenses/python-package-upstream-notices.json"] = supplemental

    var installEntries: [[String: Any]] = []
    let requirementsData = Self.requirementsLockData
    let lockedArtifacts = try Self.requirementArtifactHashes(requirementsData)
    for package in Self.pythonPackages {
      let module = package.slug.replacingOccurrences(of: "-", with: "_")
      let distInfo = "\(module)-\(package.version).dist-info"
      let metadataPath = "da3_mps/python/lib/python3.13/site-packages/\(distInfo)/METADATA"
      let recordPath = "da3_mps/python/lib/python3.13/site-packages/\(distInfo)/RECORD"
      let modulePath = "da3_mps/python/lib/python3.13/site-packages/\(module)/__init__.py"
      var metadata = """
        Metadata-Version: 2.4
        Name: \(package.slug)
        Version: \(package.version)
        License-Expression: MIT
        Project-URL: Source, https://example.com/python/\(package.slug)

        """
      for dependency in package.dependencies {
        let dependencyName = dependency.replacingOccurrences(of: "python:", with: "")
        metadata += "Requires-Dist: \(dependencyName)\n"
      }
      let metadataData = Data(metadata.utf8)
      let moduleData = Data("__all__ = []\n".utf8)
      base[metadataPath] = metadataData
      base[modulePath] = moduleData
      var recordRows = [
        "\(module)/__init__.py,sha256=\(Self.recordHash(moduleData)),\(moduleData.count)",
        "\(distInfo)/METADATA,sha256=\(Self.recordHash(metadataData)),\(metadataData.count)",
      ]
      if package.slug == "numpy" {
        let extensionData = Data("fixture numpy Mach-O".utf8)
        base[Self.signedPythonMemberPath] = extensionData
        recordRows.append(
          "numpy/_core/_multiarray_umath.cpython-313-darwin.so,sha256=\(Self.recordHash(extensionData)),\(extensionData.count)"
        )
      }
      recordRows.append("\(distInfo)/RECORD,,")
      base[recordPath] = Data((recordRows.joined(separator: "\n") + "\n").utf8)
      core["licenses/python-packages/\(package.slug)/METADATA"] = metadataData
      core["licenses/python-packages/\(package.slug)/LICENSE"] = Data("MIT".utf8)

      guard let artifactHash = lockedArtifacts[package.slug]?.first else {
        throw NSError(domain: "ProductionToolchainFileFixture", code: 2)
      }
      installEntries.append([
        "download_info": [
          "url": "https://files.pythonhosted.org/fixture/\(package.slug)-\(package.version).whl",
          "archive_info": ["hashes": ["sha256": artifactHash]],
        ],
        "metadata": ["name": package.slug, "version": package.version],
      ])
    }
    let installReport = try Self.json([
      "version": "1",
      "pip_version": "26.1",
      "install": installEntries,
    ])
    base["da3_mps/licenses/python-packages-install-report.json"] = installReport
    base["da3_mps/licenses/python-packages-requirements.txt"] = requirementsData

    let baseConfig = base["da3_mps/models/DA3-BASE/config.json"]!
    let baseWeights = base["da3_mps/models/DA3-BASE/model.safetensors"]!
    let smallConfig = small["da3_mps/models/DA3-SMALL/config.json"]!
    let smallWeights = small["da3_mps/models/DA3-SMALL/model.safetensors"]!
    base["da3_mps/models/DA3-BASE/easysplat_model_info.json"] = try Self.modelInfo(
      name: "DA3-BASE",
      revision: Self.baseModelCommit,
      config: baseConfig,
      weights: baseWeights
    )
    small["da3_mps/models/DA3-SMALL/easysplat_model_info.json"] = try Self.modelInfo(
      name: "DA3-SMALL",
      revision: Self.smallModelCommit,
      config: smallConfig,
      weights: smallWeights
    )
    let fixtureModelLock = try Self.fixtureModelLock(base: base, small: small)
    base["da3_mps/build_info.json"] = try Self.json([
      "toolchain_name": "da3_mps",
      "source_repo": "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
      "source_ref": Self.da3Commit,
      "source_commit": Self.da3Commit,
      "source_path": "git:https://github.com/ByteDance-Seed/Depth-Anything-3.git@\(Self.da3Commit)",
      "source_provenance": "pinned-git",
      "expected_upstream_repo": "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
      "expected_upstream_ref": Self.da3Commit,
      "base_checkpoint_repo": "depth-anything/DA3-BASE",
      "base_checkpoint_revision": Self.baseModelCommit,
      "base_checkpoint_commit": Self.baseModelCommit,
      "small_checkpoint_repo": "depth-anything/DA3-SMALL",
      "small_checkpoint_revision": Self.smallModelCommit,
      "small_checkpoint_commit": Self.smallModelCommit,
      "model_lock": "scripts/toolchain/da3-model-lock.json",
      "model_lock_sha256": Self.sha256(fixtureModelLock),
      "python_version": "3.13.11",
      "python_standalone_url":
        "https://github.com/indygreg/python-build-standalone/releases/download/20260127/cpython-3.13.11+20260127-aarch64-apple-darwin-install_only_stripped.tar.gz",
      "python_standalone_sha256":
        "718a87bf84d81cb81355488ca37be1f66c2252304be2090721016948de96e7ca",
      "python_standalone_license_archive_url":
        "https://github.com/indygreg/python-build-standalone/releases/download/20260127/cpython-3.13.11+20260127-aarch64-apple-darwin-pgo+lto-full.tar.zst",
      "python_standalone_license_archive_sha256":
        "ff7e2bb25f1f29067a0663af42b32980b0da295b948238d5e3fc09d2b27228a6",
      "requirements_lock": "Tools/Da3Sfm/requirements.txt",
      "requirements_lock_sha256": Self.sha256(requirementsData),
      "runtime_patch": "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
      "runtime_patch_sha256": Self.sha256(Self.runtimePatchData),
      "supplemental_license_manifest": "licenses/python-package-upstream-notices.json",
      "supplemental_license_manifest_sha256": Self.sha256(supplemental),
      "pip_install_report": "licenses/python-packages-install-report.json",
      "torch_version": "2.12.1",
      "torchvision_version": "0.27.1",
      "huggingface_hub_version": "1.14.0",
    ])
  }

  mutating func refreshSupplyChain() throws {
    core.removeValue(forKey: "supply-chain/components.json")
    let allFiles = core.merging(base, uniquingKeysWith: { current, _ in current })
      .merging(small, uniquingKeysWith: { current, _ in current })
    let ownerFiles = Dictionary(grouping: allFiles.keys, by: Self.owner(for:))
      .mapValues { $0.sorted() }
    var components: [[String: Any]] = []
    func append(_ component: [String: Any]) { components.append(component) }

    let colmapReceipt = try Self.object(core["provenance/colmap.json"]!)
    let colmapDependencies = colmapReceipt["dependencies"] as! [String: [String: Any]]
    for name in colmapDependencies.keys.sorted() {
      append(
        Self.receiptDependencyComponent(
          id: "colmap:\(name)", name: name, entry: colmapDependencies[name]!,
          buildCommand: "./scripts/toolchain/build_colmap.sh", incorporatedInto: "colmap",
          files: ownerFiles["colmap:\(name)"] ?? []
        ))
    }
    append(
      Self.component(
        id: "colmap", name: "COLMAP", type: "executable",
        version: colmapReceipt["source_version"] as! String,
        revision: colmapReceipt["source_commit"] as! String,
        source: colmapReceipt["source_url"] as! String,
        buildCommand: "./scripts/toolchain/build_colmap.sh", license: "BSD-3-Clause",
        licenseFiles: ["licenses/COLMAP/COPYING.txt"], linkage: "native-executable",
        dependencies: [
          "ceres", "colmap-support", "colmap:faiss", "colmap:poselib", "colmap:vlfeat",
          "openimageio",
        ],
        files: ownerFiles["colmap"] ?? []
      ))

    let supportReceipt = try Self.object(core["provenance/colmap-support.json"]!)
    let supportDependencies = supportReceipt["dependencies"] as! [String: [String: Any]]
    for name in supportDependencies.keys.sorted() {
      append(
        Self.receiptDependencyComponent(
          id: "colmap-support:\(name)", name: name, entry: supportDependencies[name]!,
          buildCommand: "./scripts/toolchain/build_colmap_support.sh",
          incorporatedInto: "colmap-support",
          files: ownerFiles["colmap-support:\(name)"] ?? []
        ))
    }
    append(
      Self.component(
        id: "colmap-support", name: "EasySplat COLMAP support closure",
        type: "native-build-input", version: "1",
        revision: supportReceipt["source_lock_sha256"] as! String,
        source: "https://github.com/\(sourceRepository)",
        buildCommand: "./scripts/toolchain/build_colmap_support.sh",
        license: "LicenseRef-Dependency-Closure", licenseFiles: ["licenses/EasySplat/LICENSE"],
        linkage: "build-input",
        dependencies: supportDependencies.keys.map { "colmap-support:\($0)" }.sorted(),
        files: ownerFiles["colmap-support"] ?? []
      ))

    let ceresReceipt = try Self.object(core["provenance/ceres.json"]!)
    let ceresDependencies = ceresReceipt["dependencies"] as! [String: [String: Any]]
    append(
      Self.receiptDependencyComponent(
        id: "ceres:eigen", name: "Eigen", entry: ceresDependencies["eigen"]!,
        buildCommand: "./scripts/toolchain/build_ceres.sh", incorporatedInto: "ceres",
        files: ownerFiles["ceres:eigen"] ?? []
      ))
    let ceres = ceresDependencies["ceres"]!
    append(
      Self.component(
        id: "ceres", name: "Ceres Solver", type: "static-library",
        version: ceres["source_version"] as! String,
        revision: ceres["source_commit"] as! String,
        source: ceres["source_url"] as! String,
        buildCommand: "./scripts/toolchain/build_ceres.sh", license: ceres["license"] as! String,
        licenseFiles: ceres["license_files"] as! [String], linkage: "compiled-in",
        dependencies: ["ceres:eigen"], incorporatedInto: ["colmap"],
        artifact: ceres["source_url"] as? String,
        artifactSHA256: ceres["source_sha256"] as? String,
        files: ownerFiles["ceres"] ?? []
      ))

    let oiioReceipt = try Self.object(core["provenance/openimageio.json"]!)
    let oiioDependencies = oiioReceipt["dependencies"] as! [String: [String: Any]]
    for name in oiioDependencies.keys.sorted() where name != "openimageio" {
      append(
        Self.receiptDependencyComponent(
          id: "openimageio:\(name)", name: name, entry: oiioDependencies[name]!,
          buildCommand: "./scripts/toolchain/build_openimageio.sh",
          incorporatedInto: "openimageio",
          files: ownerFiles["openimageio:\(name)"] ?? []
        ))
    }
    let oiio = oiioDependencies["openimageio"]!
    append(
      Self.component(
        id: "openimageio", name: "OpenImageIO", type: "static-library",
        version: oiio["source_version"] as! String,
        revision: oiio["source_sha256"] as! String,
        source: oiio["source_url"] as! String,
        buildCommand: "./scripts/toolchain/build_openimageio.sh",
        license: oiio["license"] as! String,
        licenseFiles: oiio["license_files"] as! [String], linkage: "compiled-in",
        dependencies: oiioDependencies.keys.filter { $0 != "openimageio" }
          .map { "openimageio:\($0)" }.sorted(),
        incorporatedInto: ["colmap"],
        artifact: oiio["source_url"] as? String,
        artifactSHA256: oiio["source_sha256"] as? String,
        files: ownerFiles["openimageio"] ?? []
      ))

    let msplatDependencies: [(String, String, String, String, String, String)] = [
      (
        "cli11", "CLI11", "2.4.2", "https://github.com/CLIUtils/CLI11", "BSD-3-Clause",
        "43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0"
      ),
      (
        "nanoflann", "nanoflann", "1.5.5", "https://github.com/jlblancoc/nanoflann", "BSD-2-Clause",
        "57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc"
      ),
      (
        "nlohmann-json", "nlohmann-json", "3.11.3", "https://github.com/nlohmann/json", "MIT",
        "04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069"
      ),
    ]
    for (idSuffix, name, dependencyVersion, source, license, digest) in msplatDependencies {
      let licensePath: String
      switch idSuffix {
      case "cli11": licensePath = "licenses/msplat/CLI11/LICENSE"
      case "nanoflann": licensePath = "licenses/msplat/nanoflann/COPYING"
      default: licensePath = "licenses/msplat/nlohmann-json/LICENSE.MIT"
      }
      append(
        Self.staticDependencyComponent(
          id: "msplat:\(idSuffix)", name: name, version: dependencyVersion,
          revision: "sha256:\(digest)", source: source, license: license,
          licenseFiles: [licensePath], buildCommand: "./scripts/toolchain/build_msplat.sh",
          incorporatedInto: "msplat", artifactSHA256: nil,
          files: ownerFiles["msplat:\(idSuffix)"] ?? []
        ))
    }
    append(
      Self.component(
        id: "msplat", name: "msplat", type: "executable", version: "1.1.3",
        revision: Self.msplatCommit, source: "https://github.com/rayanht/msplat.git",
        buildCommand: "./scripts/toolchain/build_msplat.sh", license: "Apache-2.0",
        licenseFiles: ["msplat/LICENSE"], linkage: "executable",
        dependencies: msplatDependencies.map { "msplat:\($0.0)" }.sorted(),
        files: ownerFiles["msplat"] ?? []
      ))

    append(
      Self.component(
        id: "da3", name: "Depth Anything 3", type: "python-source",
        version: Self.da3Commit, revision: Self.da3Commit,
        source: "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
        buildCommand: "./scripts/toolchain/build_da3_mps.sh", license: "Apache-2.0",
        licenseFiles: ["da3_mps/vendor/depth-anything-3/LICENSE"], linkage: "python",
        dependencies: [], files: ownerFiles["da3"] ?? []
      ))
    append(
      Self.component(
        id: "easysplat-da3-runner", name: "EasySplat DA3 runner", type: "script",
        version: version, revision: sourceCommit, source: "https://github.com/\(sourceRepository)",
        buildCommand: "./scripts/toolchain/build_da3_mps.sh", license: "MIT",
        licenseFiles: ["licenses/EasySplat/LICENSE"], linkage: "python",
        dependencies: ["da3", "python-build-standalone"],
        files: ownerFiles["easysplat-da3-runner"] ?? []
      ))
    let da3Build = try Self.object(base["da3_mps/build_info.json"]!)
    append(
      Self.component(
        id: "python-build-standalone", name: "python-build-standalone", type: "runtime",
        version: da3Build["python_version"] as! String,
        revision: "sha256:\(da3Build["python_standalone_sha256"] as! String)",
        source: da3Build["python_standalone_url"] as! String,
        buildCommand: "./scripts/toolchain/build_da3_mps.sh",
        license: "LicenseRef-Python-Build-Standalone-Closure",
        licenseFiles: [
          "da3_mps/licenses/python-build-standalone/PYTHON.json",
          "da3_mps/licenses/python-build-standalone/licenses/LICENSE.cpython.txt",
        ],
        linkage: "runtime", dependencies: [], files: ownerFiles["python-build-standalone"] ?? []
      ))

    for (name, revision) in [
      ("DA3-BASE", Self.baseModelCommit), ("DA3-SMALL", Self.smallModelCommit),
    ] {
      let lower = name.lowercased()
      let prefix = "da3_mps/models/\(name)"
      let infoData =
        name == "DA3-BASE"
        ? base["\(prefix)/easysplat_model_info.json"]!
        : small["\(prefix)/easysplat_model_info.json"]!
      let info = try Self.object(infoData)
      let artifacts = info["artifacts"] as! [String: [String: Any]]
      let sourceArtifacts: [[String: Any]] = ["config.json", "model.safetensors"].map { filename in
        let artifact = artifacts[filename]!
        return [
          "name": filename,
          "sha256": artifact["sha256"]!,
          "size": artifact["size_bytes"]!,
          "url": "https://huggingface.co/depth-anything/\(name)/resolve/\(revision)/\(filename)",
        ]
      }
      append(
        Self.component(
          id: "model:\(lower)", name: name, type: "model", version: revision,
          revision: revision, source: "https://huggingface.co/depth-anything/\(name)",
          buildCommand: "./scripts/toolchain/build_da3_mps.sh", license: "Apache-2.0",
          licenseFiles: ["\(prefix)/LICENSE"], linkage: "model-data",
          dependencies: ["da3"], sourceArtifacts: sourceArtifacts,
          files: ownerFiles["model:\(lower)"] ?? []
        ))
    }

    for package in Self.pythonPackages {
      let artifacts = try Self.requirementArtifactHashes(Self.requirementsLockData)
      guard let artifactHash = artifacts[package.slug]?.first else {
        throw NSError(domain: "ProductionToolchainFileFixture", code: 4)
      }
      append(
        Self.component(
          id: "python:\(package.slug)", name: package.slug, type: "python-package",
          version: package.version, revision: package.version,
          source: "https://example.com/python/\(package.slug)",
          buildCommand: "./scripts/toolchain/build_da3_mps.sh", license: "MIT",
          licenseFiles: [
            "licenses/python-packages/\(package.slug)/LICENSE",
            "licenses/python-packages/\(package.slug)/METADATA",
          ].sorted(),
          linkage: "python", dependencies: package.dependencies.sorted(),
          artifact: "https://files.pythonhosted.org/fixture/\(package.slug)-\(package.version).whl",
          artifactSHA256: artifactHash,
          files: ownerFiles["python:\(package.slug)"] ?? []
        ))
    }
    if let signingReceipt = core["provenance/distribution-signing.json"] {
      append(
        Self.component(
          id: "easysplat-distribution-signing",
          name: "EasySplat distribution signing",
          type: "distribution-signing",
          version: version,
          revision: "sha256:\(Self.sha256(signingReceipt))",
          source: "https://github.com/\(sourceRepository)",
          buildCommand: "./scripts/release/finalize_signed_toolchain.py",
          license: "MIT",
          licenseFiles: ["licenses/EasySplat/LICENSE"],
          linkage: "distribution-process",
          dependencies: [],
          files: ["provenance/distribution-signing.json"]
        ))
    }
    components.sort { ($0["id"] as! String) < ($1["id"] as! String) }
    precondition(
      components.count == (core["provenance/distribution-signing.json"] == nil ? 63 : 64))

    let rows: [[String: Any]] = allFiles.keys.sorted().map { path in
      let data = allFiles[path]!
      var row: [String: Any] = [
        "component": Self.owner(for: path),
        "kind": [
          "bin/colmap", "bin/easysplat-train", "lib/libomp.dylib",
          Self.signedPythonMemberPath,
        ].contains(path)
          ? "mach-o" : "file",
        "path": path,
        "sha256": Self.sha256(data),
        "size": data.count,
      ]
      if row["kind"] as? String == "mach-o" { row["dependencies"] = [] }
      return row
    }
    core["supply-chain/components.json"] = try Self.json([
      "schemaVersion": 1,
      "toolchainVersion": version,
      "components": components,
      "files": rows,
    ])
  }

  mutating func finalizeDistributionSigningForTesting() throws {
    let unsignedSupplyChain = core["supply-chain/components.json"]!
    let unsignedDocument = try Self.object(unsignedSupplyChain)
    let unsignedRows = unsignedDocument["files"] as! [[String: Any]]
    let unsignedByPath = Dictionary(
      uniqueKeysWithValues: unsignedRows.map {
        ($0["path"] as! String, $0)
      })
    let nativePaths = [
      "bin/colmap", "bin/easysplat-train", "lib/libomp.dylib",
      Self.signedPythonMemberPath,
    ]
    var machOFiles: [[String: Any]] = []
    var signedPythonTransition: (preSign: Data, postSign: Data)?
    for path in nativePaths.sorted() {
      let preSign = (core[path] ?? base[path])!
      let postSign = preSign + Data("-developer-id-signed".utf8)
      if path == Self.signedPythonMemberPath {
        base[path] = postSign
        signedPythonTransition = (preSign, postSign)
      } else {
        core[path] = postSign
      }
      let supplyProvenance: [String: Any] = [
        "kind": "supply-chain",
        "path": "supply-chain/components.json",
        "component": unsignedByPath[path]!["component"]!,
        "sha256": Self.sha256(preSign),
      ]
      let payloadProvenance: [String: Any]
      switch path {
      case "bin/colmap":
        payloadProvenance = [
          "kind": "build-receipt",
          "path": "provenance/colmap.json",
          "jsonPointer": "/executable_sha256",
          "sha256": Self.sha256(preSign),
        ]
      case "bin/easysplat-train":
        payloadProvenance = [
          "kind": "build-receipt",
          "path": "msplat/build_info.json",
          "jsonPointer": "/executable_sha256",
          "sha256": Self.sha256(preSign),
        ]
      case "lib/libomp.dylib":
        payloadProvenance = [
          "kind": "build-receipt",
          "path": "provenance/colmap-support.json",
          "jsonPointer": "/library_sha256/lib/libomp.dylib",
          "sha256": Self.sha256(preSign),
        ]
      default:
        payloadProvenance = [
          "kind": "python-record",
          "path": Self.signedPythonRecordPath,
          "member": "numpy/_core/_multiarray_umath.cpython-313-darwin.so",
          "sha256": Self.sha256(preSign),
        ]
      }
      machOFiles.append([
        "path": path,
        "component": unsignedByPath[path]!["component"]!,
        "preSignSHA256": Self.sha256(preSign),
        "postSignSHA256": Self.sha256(postSign),
        "preSignProvenance": [supplyProvenance, payloadProvenance],
        "codesign": [
          "teamIdentifier": "ABCDE12345",
          "hardenedRuntime": true,
          "timestamp": "2026-07-18T00:00:00Z",
          "authorities": [
            "Developer ID Application: EasySplat (ABCDE12345)",
            "Developer ID Certification Authority",
            "Apple Root CA",
          ],
        ],
      ])
    }
    guard let signedPythonTransition,
      let preRepairRecord = base[Self.signedPythonRecordPath],
      var recordText = String(data: preRepairRecord, encoding: .utf8)
    else {
      throw NSError(domain: "ProductionToolchainFileFixture", code: 5)
    }
    let member = "numpy/_core/_multiarray_umath.cpython-313-darwin.so"
    let oldRow = recordText.split(separator: "\n").first { $0.hasPrefix("\(member),") }
    guard let oldRow else {
      throw NSError(domain: "ProductionToolchainFileFixture", code: 6)
    }
    let newRow =
      "\(member),sha256=\(Self.recordHash(signedPythonTransition.postSign)),\(signedPythonTransition.postSign.count)"
    recordText.replaceSubrange(
      recordText.range(of: String(oldRow))!,
      with: newRow
    )
    let postRepairRecord = Data(recordText.utf8)
    base[Self.signedPythonRecordPath] = postRepairRecord
    let recordRepairs: [[String: Any]] = [
      [
        "path": Self.signedPythonRecordPath,
        "preRepairSHA256": Self.sha256(preRepairRecord),
        "postRepairSHA256": Self.sha256(postRepairRecord),
        "signedMembers": [
          [
            "path": Self.signedPythonMemberPath,
            "preSignSHA256": Self.sha256(signedPythonTransition.preSign),
            "postSignSHA256": Self.sha256(signedPythonTransition.postSign),
          ]
        ],
      ]
    ]
    let sourceInputs: [[String: Any]] = try Self.distributionSigningSourcePaths.map { path in
      let data =
        path == "scripts/toolchain/da3-model-lock.json"
        ? try Self.fixtureModelLock(base: base, small: small)
        : try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(path))
      return ["path": path, "sha256": Self.sha256(data)]
    }
    core["provenance/distribution-signing.json"] = try Self.json([
      "schemaVersion": 1,
      "kind": "easysplat-distribution-signing",
      "toolchainVersion": version,
      "identityFingerprintSHA1": String(repeating: "A", count: 40),
      "teamID": "ABCDE12345",
      "signedAt": "2026-07-18T00:00:00Z",
      "sourceCommit": sourceCommit,
      "sourceInputs": sourceInputs,
      "unsignedComponentArchives": [
        [
          "component": "core", "name": "unsigned-core.zip",
          "sha256": String(repeating: "1", count: 64), "size": 101,
        ],
        [
          "component": "base", "name": "unsigned-base.zip",
          "sha256": String(repeating: "2", count: 64), "size": 102,
        ],
        [
          "component": "small", "name": "unsigned-small.zip",
          "sha256": String(repeating: "3", count: 64), "size": 103,
        ],
      ],
      "builderAttestedUnsignedRequestSHA256": String(repeating: "4", count: 64),
      "builderAttestedUnsignedManifestSHA256": String(repeating: "5", count: 64),
      "unsignedSupplyChainSHA256": Self.sha256(unsignedSupplyChain),
      "machOFiles": machOFiles,
      "recordRepairs": recordRepairs,
    ])
    try refreshSupplyChain()
  }

  func withReviewedSourceSnapshot<T>(_ operation: () throws -> T) throws -> T {
    let paths = Array(
      Set(
        [
          "scripts/toolchain/build_colmap_impl.sh",
          "scripts/toolchain/colmap-support-lock.json",
          "scripts/toolchain/ceres-lock.json",
          "scripts/toolchain/openimageio-lock.json",
          "scripts/toolchain/build_msplat.sh",
          "scripts/toolchain/build_da3_mps.sh",
          "scripts/toolchain/da3-model-lock.json",
          "Tools/Da3Sfm/requirements.txt",
          "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
        ] + Self.distributionSigningSourcePaths)
    ).sorted()
    var sourceFiles = try Dictionary(
      uniqueKeysWithValues: paths.map { path in
        (path, try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(path)))
      })
    sourceFiles["scripts/toolchain/da3-model-lock.json"] = try Self.fixtureModelLock(
      base: base,
      small: small
    )
    let snapshot = ProductionProvenanceSourceSnapshot(
      commit: sourceCommit,
      files: sourceFiles
    )
    return try ProductionProvenanceValidator.withSourceSnapshotForTesting(
      snapshot,
      operation: operation
    )
  }

  private static func owner(for path: String) -> String {
    if path.hasPrefix("licenses/python-packages/") {
      let parts = path.split(separator: "/")
      return "python:\(parts[2])"
    }
    if path == "provenance/distribution-signing.json" {
      return "easysplat-distribution-signing"
    }
    if let package = pythonPackages.first(where: { package in
      let module = package.slug.replacingOccurrences(of: "-", with: "_")
      return path.contains("/site-packages/\(module)/")
        || path.contains("/site-packages/\(module)-\(package.version).dist-info/")
    }) {
      return "python:\(package.slug)"
    }
    if path.hasPrefix("da3_mps/python/")
      || path.hasPrefix("da3_mps/licenses/python-build-standalone/")
      || path == "da3_mps/licenses/python-packages-install-report.json"
      || path == "da3_mps/licenses/python-packages-requirements.txt"
    {
      return "python-build-standalone"
    }
    if path.hasPrefix("da3_mps/models/DA3-BASE/") { return "model:da3-base" }
    if path.hasPrefix("da3_mps/models/DA3-SMALL/") { return "model:da3-small" }
    if path.hasPrefix("da3_mps/vendor/") { return "da3" }
    if path.hasPrefix("da3_mps/") { return "easysplat-da3-runner" }
    if path.hasPrefix("licenses/EasySplat/") { return "easysplat-da3-runner" }
    if path == "bin/colmap" || path.hasPrefix("licenses/COLMAP/")
      || path == "provenance/colmap.json"
    {
      return "colmap"
    }
    if path == "bin/easysplat-train" || path == "bin/default.metallib"
      || path.hasPrefix("msplat/")
    {
      return "msplat"
    }
    if path.hasPrefix("licenses/msplat/CLI11/") { return "msplat:cli11" }
    if path.hasPrefix("licenses/msplat/nanoflann/") { return "msplat:nanoflann" }
    if path.hasPrefix("licenses/msplat/nlohmann-json/") { return "msplat:nlohmann-json" }
    if path == "provenance/ceres.json" || path.hasPrefix("licenses/ceres/")
      || path.hasPrefix("licenses/Ceres/")
    {
      return "ceres"
    }
    if path.hasPrefix("licenses/eigen/") { return "ceres:eigen" }
    if path == "provenance/openimageio.json" || path.hasPrefix("licenses/openimageio/")
      || path.hasPrefix("licenses/OpenImageIO/")
    {
      return "openimageio"
    }
    if ["boost", "fmt", "imath", "libjpeg-turbo", "libpng", "robin-map"].contains(where: {
      path.hasPrefix("licenses/\($0)/")
    }) {
      return "openimageio:\(path.split(separator: "/")[1])"
    }
    if ["faiss", "poselib", "vlfeat"].contains(where: { path.hasPrefix("licenses/\($0)/") }) {
      return "colmap:\(path.split(separator: "/")[1])"
    }
    if ["gflags", "glog", "libomp"].contains(where: { path.hasPrefix("licenses/\($0)/") }) {
      return "colmap-support:\(path.split(separator: "/")[1])"
    }
    if path.hasPrefix("licenses/boost/") { return "colmap-support:boost" }
    return "colmap-support"
  }

  private static func component(
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
    incorporatedInto: [String]? = nil,
    artifact: String? = nil,
    artifactSHA256: String? = nil,
    sourceArtifacts: [[String: Any]]? = nil,
    files: [String]
  ) -> [String: Any] {
    var result: [String: Any] = [
      "id": id,
      "name": name,
      "type": type,
      "version": version,
      "revision": revision,
      "source": source,
      "buildCommand": buildCommand,
      "license": license,
      "licenseFiles": licenseFiles,
      "linkage": linkage,
      "dependencies": dependencies.sorted(),
      "files": files,
    ]
    if let incorporatedInto { result["incorporatedInto"] = incorporatedInto.sorted() }
    if let artifact { result["artifact"] = artifact }
    if let artifactSHA256 { result["artifactSha256"] = artifactSHA256 }
    if let sourceArtifacts { result["sourceArtifacts"] = sourceArtifacts }
    return result
  }

  private static func staticDependencyComponent(
    id: String,
    name: String,
    version: String,
    revision: String,
    source: String,
    license: String,
    licenseFiles: [String],
    buildCommand: String,
    incorporatedInto: String,
    artifactSHA256: String?,
    files: [String]
  ) -> [String: Any] {
    component(
      id: id, name: name, type: "static-dependency", version: version,
      revision: revision, source: source, buildCommand: buildCommand, license: license,
      licenseFiles: licenseFiles, linkage: "compiled-in", dependencies: [],
      incorporatedInto: [incorporatedInto], artifact: artifactSHA256 == nil ? nil : source,
      artifactSHA256: artifactSHA256, files: files
    )
  }

  private static func receiptDependencyComponent(
    id: String,
    name: String,
    entry: [String: Any],
    buildCommand: String,
    incorporatedInto: String,
    files: [String]
  ) -> [String: Any] {
    let source = entry["source_url"] as! String
    let version = entry["source_version"] as! String
    let revision =
      (entry["source_commit"] as? String)
      ?? (entry["source_sha256"] as? String)
      ?? (entry["source_archive_sha256"] as? String)
      ?? (entry["source_tree_sha256"] as? String)
      ?? version
    let archiveLike = [".zip", ".tar", ".tar.gz", ".tar.xz", ".tgz", ".txz"]
      .contains(where: source.lowercased().hasSuffix)
    let artifactSHA =
      (entry["source_archive_sha256"] as? String)
      ?? (archiveLike ? entry["source_sha256"] as? String : nil)
    return component(
      id: id,
      name: name,
      type: "static-dependency",
      version: version,
      revision: revision,
      source: source,
      buildCommand: buildCommand,
      license: entry["license"] as! String,
      licenseFiles: entry["license_files"] as! [String],
      linkage: (entry["linkage"] as? String) ?? "compiled-in",
      dependencies: [],
      incorporatedInto: [incorporatedInto],
      artifact: artifactSHA == nil ? nil : source,
      artifactSHA256: artifactSHA,
      files: files
    )
  }

  private static func dependency(
    name: String,
    version: String,
    commit: String? = nil,
    license: String,
    sha256: String = sourceArchiveSHA256,
    sourceURL: String? = nil,
    licenseFiles: [String]? = nil,
    linkage: String = "compiled-in"
  ) -> [String: Any] {
    var result: [String: Any] = [
      "source_url": sourceURL ?? "https://example.com/\(name)-\(version).tar.gz",
      "source_version": version,
      "source_sha256": sha256,
      "license": license,
      "license_files": licenseFiles ?? ["licenses/\(name)/LICENSE"],
      "linkage": linkage,
    ]
    if let commit { result["source_commit"] = commit }
    return result
  }

  private static func lockDependency(
    _ lockData: Data,
    name: String,
    licenseFiles: [String]? = nil,
    linkage: String = "compiled-in"
  ) throws -> [String: Any] {
    let lock = try object(lockData)
    let dependencies = lock["dependencies"] as! [String: [String: Any]]
    let entry = dependencies[name]!
    let source = entry["source"] as! [String: Any]
    return dependency(
      name: name,
      version: entry["version"] as! String,
      commit: entry["commit"] as? String,
      license: entry["license"] as! String,
      sha256: source["sha256"] as! String,
      sourceURL: source["url"] as? String,
      licenseFiles: licenseFiles,
      linkage: linkage
    )
  }

  private static func modelInfo(
    name: String,
    revision: String,
    config: Data,
    weights: Data
  ) throws -> Data {
    try json([
      "repo_id": "depth-anything/\(name)",
      "requested_revision": revision,
      "resolved_sha": revision,
      "license": "apache-2.0",
      "artifacts": [
        "config.json": ["sha256": sha256(config), "size_bytes": config.count],
        "model.safetensors": ["sha256": sha256(weights), "size_bytes": weights.count],
      ],
    ])
  }

  private static func fixtureModelLock(
    base: [String: Data],
    small: [String: Data]
  ) throws -> Data {
    let baseInfo = try object(
      base["da3_mps/models/DA3-BASE/easysplat_model_info.json"]!
    )
    let smallInfo = try object(
      small["da3_mps/models/DA3-SMALL/easysplat_model_info.json"]!
    )
    return try json([
      "schema_version": 1,
      "models": ["DA3-BASE": baseInfo, "DA3-SMALL": smallInfo],
    ])
  }

  private static func requirementArtifactHashes(_ data: Data) throws -> [String: [String]] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "ProductionToolchainFileFixture", code: 3)
    }
    var result: [String: [String]] = [:]
    var current: String?
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if rawLine.first?.isWhitespace == false, !line.isEmpty, !line.hasPrefix("#") {
        let declaration = line.split(separator: " ", maxSplits: 1)[0]
        let parts = declaration.components(separatedBy: "==")
        current = parts.count == 2 ? parts[0].lowercased() : nil
      }
      if let range = line.range(of: "--hash=sha256:"), let current {
        let digest = line[range.upperBound...].prefix(64)
        result[current, default: []].append(String(digest))
      }
    }
    return result
  }

  private static func currentSourceCommit() throws -> String {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = repositoryRoot
    process.arguments = ["rev-parse", "HEAD"]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw NSError(domain: "ProductionToolchainFileFixture", code: 5)
    }
    return String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func recordHash(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "ProductionToolchainFileFixture", code: 1)
    }
    return object
  }

  static func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
