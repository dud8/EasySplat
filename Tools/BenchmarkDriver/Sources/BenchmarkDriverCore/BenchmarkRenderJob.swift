import Foundation

public enum BenchmarkDriverError: LocalizedError, Equatable {
    case invalidJob(String)
    case metalUnavailable
    case renderFailed(String)
    case checkoutChanged(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJob(let detail): detail
        case .metalUnavailable: "Metal is unavailable on this Mac."
        case .renderFailed(let detail): detail
        case .checkoutChanged(let detail): detail
        }
    }
}

public enum RenderVariant: String, Codable, CaseIterable, Sendable {
    case accurateReference = "accurate_reference"
    case pairedBaseline = "paired_baseline"
    case candidateBalanced = "candidate_balanced"
    case candidateFast = "candidate_fast"
}

public struct CheckoutBinding: Codable, Equatable, Sendable {
    public var path: String
    public var commit: String

    public init(path: String, commit: String) {
        self.path = path
        self.commit = commit
    }
}

public struct RenderCamera: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var projectionMatrixColumnMajor: [Float]
    public var worldToCameraMatrixColumnMajor: [Float]

    public init(
        width: Int,
        height: Int,
        projectionMatrixColumnMajor: [Float],
        worldToCameraMatrixColumnMajor: [Float]
    ) {
        self.width = width
        self.height = height
        self.projectionMatrixColumnMajor = projectionMatrixColumnMajor
        self.worldToCameraMatrixColumnMajor = worldToCameraMatrixColumnMajor
    }

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case projectionMatrixColumnMajor = "projection_matrix_column_major"
        case worldToCameraMatrixColumnMajor = "world_to_camera_matrix_column_major"
    }
}

public struct GroundTruthImage: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct RenderSource: Codable, Equatable, Sendable {
    public var variant: RenderVariant
    public var runID: String
    public var checkoutCommit: String
    public var toolchainIdentity: String
    public var sourceExecutableSHA256: String
    public var plyPath: String
    public var plySHA256: String
    public var outputPath: String

    public init(
        variant: RenderVariant,
        runID: String,
        checkoutCommit: String,
        toolchainIdentity: String,
        sourceExecutableSHA256: String,
        plyPath: String,
        plySHA256: String,
        outputPath: String
    ) {
        self.variant = variant
        self.runID = runID
        self.checkoutCommit = checkoutCommit
        self.toolchainIdentity = toolchainIdentity
        self.sourceExecutableSHA256 = sourceExecutableSHA256
        self.plyPath = plyPath
        self.plySHA256 = plySHA256
        self.outputPath = outputPath
    }

    enum CodingKeys: String, CodingKey {
        case variant
        case runID = "run_id"
        case checkoutCommit = "checkout_commit"
        case toolchainIdentity = "toolchain_identity"
        case sourceExecutableSHA256 = "source_executable_sha256"
        case plyPath = "ply_path"
        case plySHA256 = "ply_sha256"
        case outputPath = "output_path"
    }
}

public struct RenderViewJob: Codable, Equatable, Sendable {
    public var holdoutIndex: Int
    public var camera: RenderCamera
    public var groundTruth: GroundTruthImage
    public var sources: [RenderSource]

    public init(
        holdoutIndex: Int,
        camera: RenderCamera,
        groundTruth: GroundTruthImage,
        sources: [RenderSource]
    ) {
        self.holdoutIndex = holdoutIndex
        self.camera = camera
        self.groundTruth = groundTruth
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case holdoutIndex = "holdout_index"
        case camera
        case groundTruth = "ground_truth"
        case sources
    }
}

public struct BenchmarkRenderJob: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sceneID: String
    public var scale: Int
    public var requestDigest: String
    public var inputDigest: String
    public var rendererClosureSHA256: String
    public var rendererExecutableSHA256: String
    public var holdoutIndices: [Int]
    public var trainingViewIndices: [Int]
    public var candidateCheckout: CheckoutBinding
    public var baselineCheckout: CheckoutBinding
    public var views: [RenderViewJob]

    public init(
        schemaVersion: Int,
        sceneID: String,
        scale: Int,
        requestDigest: String,
        inputDigest: String,
        rendererClosureSHA256: String,
        rendererExecutableSHA256: String,
        holdoutIndices: [Int],
        trainingViewIndices: [Int],
        candidateCheckout: CheckoutBinding,
        baselineCheckout: CheckoutBinding,
        views: [RenderViewJob]
    ) {
        self.schemaVersion = schemaVersion
        self.sceneID = sceneID
        self.scale = scale
        self.requestDigest = requestDigest
        self.inputDigest = inputDigest
        self.rendererClosureSHA256 = rendererClosureSHA256
        self.rendererExecutableSHA256 = rendererExecutableSHA256
        self.holdoutIndices = holdoutIndices
        self.trainingViewIndices = trainingViewIndices
        self.candidateCheckout = candidateCheckout
        self.baselineCheckout = baselineCheckout
        self.views = views
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sceneID = "scene_id"
        case scale
        case requestDigest = "request_digest"
        case inputDigest = "input_digest"
        case rendererClosureSHA256 = "renderer_closure_sha256"
        case rendererExecutableSHA256 = "renderer_executable_sha256"
        case holdoutIndices = "holdout_indices"
        case trainingViewIndices = "training_view_indices"
        case candidateCheckout = "candidate_checkout"
        case baselineCheckout = "baseline_checkout"
        case views
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw BenchmarkDriverError.invalidJob("The render-job schema is unsupported.")
        }
        guard Self.isToken(sceneID), scale > 0 else {
            throw BenchmarkDriverError.invalidJob("The scene binding is invalid.")
        }
        guard Self.isDigest(requestDigest), Self.isDigest(inputDigest),
              Self.isDigest(rendererClosureSHA256),
              Self.isDigest(rendererExecutableSHA256) else {
            throw BenchmarkDriverError.invalidJob("The request or input digest is invalid.")
        }
        guard holdoutIndices == holdoutIndices.sorted(),
              Set(holdoutIndices).count == holdoutIndices.count,
              !holdoutIndices.isEmpty,
              holdoutIndices.allSatisfy({ 0 <= $0 && $0 < scale }) else {
            throw BenchmarkDriverError.invalidJob("Holdout indices must be unique, ordered, and in range.")
        }
        let holdouts = Set(holdoutIndices)
        let expectedTraining = (0..<scale).filter { !holdouts.contains($0) }
        guard trainingViewIndices == expectedTraining else {
            throw BenchmarkDriverError.invalidJob("Held-out views must be excluded from training.")
        }
        guard views.map(\.holdoutIndex) == holdoutIndices else {
            throw BenchmarkDriverError.invalidJob("Render views must follow the signed holdout order.")
        }
        guard Self.isCommit(candidateCheckout.commit), Self.isCommit(baselineCheckout.commit) else {
            throw BenchmarkDriverError.invalidJob("A checkout commit is invalid.")
        }
        var imagePaths = Set<String>()
        var immutableSources = [RenderVariant: RenderSource]()
        for view in views {
            try Self.validate(camera: view.camera)
            guard Self.isSafeRelativePath(view.groundTruth.path),
                  Self.isDigest(view.groundTruth.sha256),
                  imagePaths.insert(view.groundTruth.path).inserted else {
                throw BenchmarkDriverError.invalidJob("A ground-truth image binding is invalid.")
            }
            guard view.sources.map(\.variant) == RenderVariant.allCases else {
                throw BenchmarkDriverError.invalidJob("Render sources must use the canonical variant order.")
            }
            for source in view.sources {
                let expectedCommit = source.variant == .pairedBaseline
                    ? baselineCheckout.commit
                    : candidateCheckout.commit
                guard source.checkoutCommit == expectedCommit,
                      Self.isToken(source.runID),
                      Self.isDigest(source.toolchainIdentity),
                      Self.isDigest(source.sourceExecutableSHA256),
                      Self.isDigest(source.plySHA256),
                      Self.isSafeRelativePath(source.plyPath),
                      Self.isSafeRelativePath(source.outputPath),
                      source.outputPath != "rendering-manifest.json",
                      imagePaths.insert(source.outputPath).inserted else {
                    throw BenchmarkDriverError.invalidJob("A render source binding is invalid.")
                }
                if let immutableSource = immutableSources[source.variant] {
                    guard source.hasSameImmutableIdentity(as: immutableSource) else {
                        throw BenchmarkDriverError.invalidJob(
                            "Every holdout must use one immutable source per render variant."
                        )
                    }
                } else {
                    immutableSources[source.variant] = source
                }
            }
        }
    }

    private static func validate(camera: RenderCamera) throws {
        let (pixelCount, overflow) = camera.width.multipliedReportingOverflow(by: camera.height)
        guard (64...16_384).contains(camera.width),
              (64...16_384).contains(camera.height),
              !overflow,
              pixelCount <= 4_194_304,
              camera.projectionMatrixColumnMajor.count == 16,
              camera.worldToCameraMatrixColumnMajor.count == 16,
              camera.projectionMatrixColumnMajor.allSatisfy(\.isFinite),
              camera.worldToCameraMatrixColumnMajor.allSatisfy(\.isFinite) else {
            throw BenchmarkDriverError.invalidJob("A render camera is invalid.")
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    static func isDigest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value.count == 71 else { return false }
        return value.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || "_.-".contains($0) }
    }
}

private extension RenderSource {
    func hasSameImmutableIdentity(as other: RenderSource) -> Bool {
        runID == other.runID
            && checkoutCommit == other.checkoutCommit
            && toolchainIdentity == other.toolchainIdentity
            && sourceExecutableSHA256 == other.sourceExecutableSHA256
            && plyPath == other.plyPath
            && plySHA256 == other.plySHA256
    }
}
