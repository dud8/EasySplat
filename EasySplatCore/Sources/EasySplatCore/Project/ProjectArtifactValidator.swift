import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SplatIO
import UniformTypeIdentifiers

private final class ViewerPlyCompatibilityProbe: SplatSceneReaderDelegate {
    private(set) var finished = false
    private(set) var failure: Error?

    func didStartReading(withPointCount pointCount: UInt32) {}

    func didRead(points: [SplatScenePoint]) {}

    func didFinishReading() {
        finished = true
    }

    func didFailReading(withError error: Error?) {
        failure = error
    }
}

public enum ProjectArtifactStatus: Equatable, Sendable {
    case valid
    case missing
    case corrupt(reason: String)
}

public enum ProjectArtifactValidationDepth: Sendable {
    case quick
    case full
}

public struct PlyHeaderInfo: Sendable, Equatable {
    public var vertexCount: Int
    public var format: String

    public init(vertexCount: Int, format: String) {
        self.vertexCount = vertexCount
        self.format = format
    }
}

public struct ValidatedPlyArtifactEvidence: Sendable, Equatable {
    public let byteCount: UInt64
    public let vertexCount: Int
    public let format: String
    public let sha256: String
    public let sceneBounds: SplatSceneBounds

    public init(
        byteCount: UInt64,
        vertexCount: Int,
        format: String,
        sha256: String,
        sceneBounds: SplatSceneBounds
    ) {
        self.byteCount = byteCount
        self.vertexCount = vertexCount
        self.format = format
        self.sha256 = sha256
        self.sceneBounds = sceneBounds
    }
}

public struct ExpectedPlyArtifactIdentity: Sendable, Equatable {
    public let byteCount: UInt64
    public let vertexCount: Int
    public let sha256: String

    public init(byteCount: UInt64, vertexCount: Int, sha256: String) {
        self.byteCount = byteCount
        self.vertexCount = vertexCount
        self.sha256 = sha256
    }
}

public struct FinishedProjectValidationContext: Sendable {
    public let hardwareProfile: HardwareProfile

    public init(hardwareProfile: HardwareProfile) {
        self.hardwareProfile = hardwareProfile
    }

    public static func currentReleaseHost() -> Self {
        Self(hardwareProfile: .detect())
    }
}

/// The external source selection a release verifier must bind to the immutable
/// copies retained by one finished project. Order is significant for videos.
public enum FinishedProjectExpectedInput: Sendable, Equatable {
    case videoFiles([URL])
    case photoFolder(URL)
    case mixed(videoFiles: [URL], photoFolder: URL)
}

/// Opaque evidence that one external finished-project input selection still
/// names the same files and directory tree. The value intentionally retains no
/// source paths; callers can only compare snapshots captured at trust-boundary
/// transitions.
public struct FinishedProjectExpectedInputContinuitySnapshot: Sendable, Equatable {
    private let fingerprint: String

    fileprivate init(fingerprint: String) {
        self.fingerprint = fingerprint
    }
}

public struct FinishedProjectArtifactEvidence: Sendable {
    public let metadata: ProjectMetadata
    public let input: InputSpec
    public let requestedRunOptions: RequestedRunOptions
    public let resolvedRunPlan: ResolvedRunPlan
    public let toolchainRequest: ToolchainCapabilityRequest
    public let geometryArtifact: GeometryArtifact
    public let trainingArtifact: TrainingArtifact
    public let outputURL: URL
    public let outputEvidence: ValidatedPlyArtifactEvidence

    public init(
        metadata: ProjectMetadata,
        input: InputSpec,
        requestedRunOptions: RequestedRunOptions,
        resolvedRunPlan: ResolvedRunPlan,
        toolchainRequest: ToolchainCapabilityRequest,
        geometryArtifact: GeometryArtifact,
        trainingArtifact: TrainingArtifact,
        outputURL: URL,
        outputEvidence: ValidatedPlyArtifactEvidence
    ) {
        self.metadata = metadata
        self.input = input
        self.requestedRunOptions = requestedRunOptions
        self.resolvedRunPlan = resolvedRunPlan
        self.toolchainRequest = toolchainRequest
        self.geometryArtifact = geometryArtifact
        self.trainingArtifact = trainingArtifact
        self.outputURL = outputURL
        self.outputEvidence = outputEvidence
    }
}

public enum FinishedProjectArtifactValidationError: Error, LocalizedError, Equatable {
    case invalidProject(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProject(let reason):
            return "Finished project validation failed: \(reason)"
        }
    }
}

struct PlyPublicationSystemCalls {
    var synchronize: (Int32) -> Int32
    var renameExclusively: (Int32, String, String) -> Int32
    var status: (Int32, String, UnsafeMutablePointer<stat>) -> Int32
    var remove: (Int32, String) -> Int32
    var readAt: (Int32, UnsafeMutableRawPointer?, Int, off_t) -> Int
    var write: (Int32, UnsafeRawPointer?, Int) -> Int

    static func system() -> Self {
        Self(
            synchronize: { Darwin.fsync($0) },
            renameExclusively: { directory, source, destination in
                source.withCString { sourcePointer in
                    destination.withCString { destinationPointer in
                        Darwin.renameatx_np(
                            directory,
                            sourcePointer,
                            directory,
                            destinationPointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
            },
            status: { directory, name, metadata in
                name.withCString {
                    Darwin.fstatat(directory, $0, metadata, AT_SYMLINK_NOFOLLOW)
                }
            },
            remove: { directory, name in
                name.withCString { Darwin.unlinkat(directory, $0, 0) }
            },
            readAt: { descriptor, bytes, count, offset in
                Darwin.pread(descriptor, bytes, count, offset)
            },
            write: { descriptor, bytes, count in
                Darwin.write(descriptor, bytes, count)
            }
        )
    }
}

public enum ProjectArtifactValidator {
    private static let maxHeaderBytes = 64 * 1024
    private static let maxAsciiVertexRowBytes = 1024 * 1024

    public static func captureExpectedInputSnapshot(
        _ expectedInput: FinishedProjectExpectedInput
    ) throws -> FinishedProjectExpectedInputContinuitySnapshot {
        expectedInputContinuitySnapshot(
            try canonicalFinishedProjectExpectedInput(expectedInput)
        )
    }

    /// Read only the PLY header for a known-good output file and return the
    /// vertex count + format. Returns nil when the file is unreadable, missing,
    /// or not a valid PLY header. Cheap (single bounded read of the header).
    public static func readPlyHeader(at url: URL) -> PlyHeaderInfo? {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxHeaderBytes)) ?? Data()
        guard !data.isEmpty, let bounds = plyHeaderBounds(in: data) else { return nil }
        guard let header = String(data: data.prefix(bounds.headerEnd), encoding: .utf8) else { return nil }
        let lines = header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let vertexLine = lines.first(where: { $0.lowercased().hasPrefix("element vertex ") }),
              let raw = vertexLine.split(separator: " ").last,
              let vertexCount = Int(raw), vertexCount > 0 else {
            return nil
        }
        let format = lines
            .first(where: { $0.lowercased().hasPrefix("format ") })?
            .split(separator: " ")
            .dropFirst()
            .first
            .map(String.init)?
            .lowercased() ?? ""
        return PlyHeaderInfo(vertexCount: vertexCount, format: format)
    }

    public static func resolveValidatedOutputPly(paths: ProjectPaths, relativePath: String) throws -> URL {
        let url = try paths.resolveProjectRelativePath(relativePath)
        guard validatePlyFile(at: url) == .valid else {
            throw ProjectArtifactError.invalidOutput(relativePath)
        }
        return url
    }

    public static func validatedPlyEvidence(
        at url: URL
    ) throws -> ValidatedPlyArtifactEvidence {
        try validatedPlyEvidence(
            at: url,
            beforeBoundsMeasurement: {},
            shouldCancel: { false }
        )
    }

    static func validatedPlyEvidence(
        at url: URL,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ValidatedPlyArtifactEvidence {
        try validatedPlyEvidence(
            at: url,
            beforeBoundsMeasurement: {},
            shouldCancel: shouldCancel
        )
    }

#if DEBUG
    static func test_validatedPlyEvidence(
        at url: URL,
        beforeBoundsMeasurement: () throws -> Void
    ) throws -> ValidatedPlyArtifactEvidence {
        try validatedPlyEvidence(
            at: url,
            beforeBoundsMeasurement: beforeBoundsMeasurement,
            shouldCancel: { false }
        )
    }
#endif

    private static func validatedPlyEvidence(
        at url: URL,
        beforeBoundsMeasurement: () throws -> Void,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ValidatedPlyArtifactEvidence {
        try throwIfCancellationRequested(shouldCancel)
        let parentURL = url.deletingLastPathComponent()
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw ProjectArtifactError.invalidOutput(url.lastPathComponent)
        }
        defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ProjectArtifactError.invalidOutput(url.lastPathComponent)
        }
        defer { Darwin.close(descriptor) }

        var initialDescriptor = stat()
        var initialPath = stat()
        var initialParent = stat()
        var initialParentPath = stat()
        let initialPathStatus = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &initialPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &initialDescriptor) == 0,
              initialPathStatus == 0,
              fstat(parent, &initialParent) == 0,
              lstat(parentURL.path, &initialParentPath) == 0,
              samePublishedFile(initialDescriptor, initialPath),
              samePublishedFile(initialParent, initialParentPath),
              (initialParent.st_mode & S_IFMT) == S_IFDIR else {
            throw ProjectArtifactError.invalidOutput(url.lastPathComponent)
        }
        let evidence = try validatedPlyEvidence(
            descriptor: descriptor,
            label: url.lastPathComponent,
            beforeBoundsMeasurement: beforeBoundsMeasurement,
            shouldCancel: shouldCancel
        )
        var finalDescriptor = stat()
        var finalPath = stat()
        var finalParent = stat()
        var finalParentPath = stat()
        let finalPathStatus = url.lastPathComponent.withCString {
            Darwin.fstatat(parent, $0, &finalPath, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &finalDescriptor) == 0,
              finalPathStatus == 0,
              fstat(parent, &finalParent) == 0,
              lstat(parentURL.path, &finalParentPath) == 0,
              samePublishedFile(initialDescriptor, finalDescriptor),
              samePublishedFile(initialDescriptor, finalPath),
              samePublishedFile(initialParent, finalParent),
              samePublishedFile(initialParent, finalParentPath) else {
            throw ProjectArtifactError.invalidOutput(url.lastPathComponent)
        }
        return evidence
    }

    /// Independently proves that a packaged-app project is a current, fully
    /// completed run whose persisted plan, geometry, training receipt, and
    /// public PLY still describe the same artifacts.
    public static func validateFinishedProject(
        at projectURL: URL,
        expectedInput: FinishedProjectExpectedInput,
        context: FinishedProjectValidationContext = .currentReleaseHost()
    ) throws -> FinishedProjectArtifactEvidence {
        try validateFinishedProjectCore(
            at: projectURL,
            expectedInput: try canonicalFinishedProjectExpectedInput(expectedInput),
            context: context,
            allowPendingVideoLineage: false
        ).evidence
    }

    /// Authenticates a published geometry stage without requiring training or
    /// a final PLY. Benchmark callers must supply the exact geometry artifact
    /// whose bytes they measured so this check cannot silently validate a
    /// different publication.
    @discardableResult
    public static func validatePublishedGeometry(
        at projectURL: URL,
        expectedGeometry: GeometryArtifact
    ) throws -> GeometryArtifact {
        let canonicalProject = try canonicalFinishedProjectDirectory(projectURL)
        let paths = ProjectPaths(root: canonicalProject)
        let metadata: ProjectMetadata
        do {
            metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        } catch {
            throw finishedProjectError("project.json is not valid current-format metadata")
        }
        guard let plan = metadata.resolvedRunPlan else {
            throw finishedProjectError(
                "the project has no resolved plan and published geometry"
            )
        }
        let geometry: GeometryArtifact
        do {
            geometry = try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        } catch {
            throw finishedProjectError("the geometry sidecar is missing or invalid")
        }
        guard geometry == expectedGeometry else {
            throw finishedProjectError(
                "the published geometry does not match the expected artifact"
            )
        }
        try requireGeometryPlanBinding(geometry, plan: plan)

        let manifest: [PipelineRunner.SelectedFrameMapping]
        do {
            let data = try BoundedFileReader.readRegularFile(
                at: paths.framesSelectedManifestURL,
                maximumBytes: 4 * 1_024 * 1_024
            )
            manifest = try JSONDecoder().decode(
                [PipelineRunner.SelectedFrameMapping].self,
                from: data
            )
        } catch {
            throw finishedProjectError("selected_manifest.json is missing or invalid")
        }
        let imageNames = manifest.map(\.outputFileName)
        guard imageNames == geometry.orderedImageNames,
              Set(imageNames).count == imageNames.count else {
            throw finishedProjectError(
                "selected_manifest.json does not bind the published geometry"
            )
        }
        let selectedImages = imageNames.map {
            paths.framesSelectedURL.appendingPathComponent($0)
        }
        let cameraEvidence: [ColmapSelectedImageCameraEvidence]
        let expectedInitialization: ColmapCameraInitializationReceipt
        do {
            cameraEvidence = try PipelineRunner.colmapCameraGroupingEvidence(
                imageNames: imageNames,
                manifest: manifest
            )
            expectedInitialization = try ColmapCameraInitializationReceipt.resolve(
                plan: plan,
                detailProfile: metadata.requestedRunOptions.detailProfile,
                selectedImages: selectedImages
            )
        } catch {
            throw finishedProjectError(
                "the camera initialization cannot be reproduced from the resolved plan"
            )
        }
        let featureEvidence: ColmapFeatureEvidence
        do {
            featureEvidence = try ColmapFeatureEvidenceStore.loadVerified(
                from: paths.colmapFeatureEvidenceURL,
                expectedImageNames: imageNames,
                expectedCameraEvidence: cameraEvidence,
                expectedCameraGroupingMode: PipelineRunner.colmapCameraGroupingMode(
                    cameraGrouping: plan.cameraGrouping,
                    evidence: cameraEvidence
                ),
                expectedCameraInitializationReceipt: expectedInitialization,
                databaseURL: paths.colmapDatabaseURL,
                projectPaths: paths
            )
        } catch {
            throw finishedProjectError(
                "the feature database does not authenticate the published camera initialization"
            )
        }
        guard featureEvidence.cameraGroupingReceipt == geometry.cameraGroupingReceipt,
              featureEvidence.cameraInitializationReceipt
                == geometry.cameraInitializationReceipt,
              featureEvidence.featureDatabaseDigest == geometry.featureDatabaseDigest,
              geometry.cameraInitializationReceipt == expectedInitialization,
              geometry.cameraInitializationReceipt.recipe
                == plan.cameraInitializationRecipe else {
            throw finishedProjectError(
                "the feature, camera, and geometry evidence do not describe one publication"
            )
        }
        return geometry
    }

    public static func validateFinishedProject(
        at projectURL: URL,
        expectedInput: FinishedProjectExpectedInput,
        context: FinishedProjectValidationContext = .currentReleaseHost(),
        independentlyRederiveVideoFrames: Bool
    ) async throws -> FinishedProjectArtifactEvidence {
        guard independentlyRederiveVideoFrames else {
            throw finishedProjectError(
                "video lineage validation cannot be disabled on the asynchronous release path"
            )
        }
        let canonicalExpectedInput = try canonicalFinishedProjectExpectedInput(expectedInput)
        let initial = try validateFinishedProjectCore(
            at: projectURL,
            expectedInput: canonicalExpectedInput,
            context: context,
            allowPendingVideoLineage: true
        )
        try await validateSelectedVideoLineage(
            projectURL: projectURL,
            evidence: initial.evidence,
            expectedLineage: initial.projectSnapshot.selectedLineage
        )
        let final = try validateFinishedProjectCore(
            at: projectURL,
            expectedInput: canonicalExpectedInput,
            context: context,
            allowPendingVideoLineage: true
        )
        guard final.projectSnapshot == initial.projectSnapshot else {
            throw finishedProjectError(
                "the finished project changed after independent video rederivation"
            )
        }
        return final.evidence
    }

#if DEBUG
    static func test_validateControlledInputBinding(
        metadata: ProjectMetadata,
        expectedInput: FinishedProjectExpectedInput,
        paths: ProjectPaths
    ) throws {
        try VideoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
        let photoSelectionProjection = try verifiedPhotoSelectionProjection(
            metadata: metadata,
            paths: paths
        )
        let canonicalInput = try canonicalFinishedProjectExpectedInput(expectedInput)
        try requireExpectedInput(metadata.input, canonicalInput: canonicalInput)
        guard let plan = metadata.resolvedRunPlan else {
            throw finishedProjectError("the project has no resolved run plan")
        }
        _ = try validateImportedInputBinding(
            input: metadata.input,
            videoInputReceipts: metadata.videoInputReceipts,
            photoInputReceipts: metadata.photoInputReceipts,
            photoSelectionProjection: photoSelectionProjection,
            plan: plan,
            canonicalInput: canonicalInput,
            paths: paths
        )
    }

    static func test_validateFinishedProjectSnapshotBinding(
        at projectURL: URL,
        expectedInput: FinishedProjectExpectedInput,
        context: FinishedProjectValidationContext,
        mutation: () throws -> Void
    ) throws {
        let initial = try validateFinishedProjectCore(
            at: projectURL,
            expectedInput: try canonicalFinishedProjectExpectedInput(expectedInput),
            context: context,
            allowPendingVideoLineage: false
        )
        try mutation()
        let final = try validateFinishedProjectCore(
            at: projectURL,
            expectedInput: try canonicalFinishedProjectExpectedInput(expectedInput),
            context: context,
            allowPendingVideoLineage: false
        )
        guard final.projectSnapshot == initial.projectSnapshot else {
            throw finishedProjectError(
                "the finished project changed after independent video rederivation"
            )
        }
    }

    static func test_protectedFileIdentityMatchesAfterMutation(
        at url: URL,
        mutation: () throws -> Void
    ) throws -> Bool {
        let mutationGuard = try FinishedProjectProtectedPathMutationGuard(
            urls: [url.deletingLastPathComponent(), url]
        )
        defer { mutationGuard.close() }
        let initial = try safeFinishedProjectProtectedFileIdentity(at: url)
        try mutation()
        return try safeFinishedProjectProtectedFileIdentity(at: url) == initial
            && mutationGuard.observedOnlyAttributeChanges()
    }

    static func test_protectedDirectoryRejectsMutation(
        at url: URL,
        mutation: () throws -> Void
    ) throws -> Bool {
        let mutationGuard = try FinishedProjectProtectedPathMutationGuard(
            urls: [url]
        )
        defer { mutationGuard.close() }
        try mutation()
        return mutationGuard.observedNoChanges()
    }

    static func test_requireExactVideoCoverage(
        _ manifest: [PipelineRunner.SelectedFrameMapping],
        sourceFiles: [String],
        sourceSHA256s: [String],
        pairingPolicy: ResolvedPairingPolicy
    ) throws {
        try requireExactVideoCoverage(
            manifest,
            expectedGroups: try expectedVideoGroups(
                sourceFiles: sourceFiles,
                sourceSHA256s: sourceSHA256s,
                pairingPolicy: pairingPolicy
            )
        )
    }

    static func test_requireExactOrderedTimestamps(
        _ manifest: [PipelineRunner.SelectedFrameMapping],
        geometryTimestamps: [Double?]
    ) throws {
        try requireExactOrderedTimestamps(
            manifest,
            geometryTimestamps: geometryTimestamps
        )
    }

    static func test_photoSelectionTarget(
        validCount: Int,
        plan: ResolvedRunPlan
    ) throws -> Int {
        try photoSelectionTarget(validCount: validCount, plan: plan)
    }

    static func test_requireExactPhotoProjection(
        _ observed: [(path: String, sha256: String, retainedRank: Int)],
        projection: PhotoSelectionProjection,
        targetCount: Int
    ) throws {
        try requireExactPhotoProjection(
            observed,
            projection: projection,
            targetCount: targetCount,
            failureReason: "test photo projection mismatch"
        )
    }

    static func test_requireCanonicalOrientationBinding(
        geometry: GeometryArtifact,
        measured: ColmapResidualAnalyzer.Result,
        plan: ResolvedRunPlan
    ) throws {
        try requireCanonicalOrientationBinding(
            geometry: geometry,
            measured: measured,
            plan: plan
        )
    }

    static func test_requireGeometryPlanBinding(
        _ geometry: GeometryArtifact,
        plan: ResolvedRunPlan
    ) throws {
        try requireGeometryPlanBinding(geometry, plan: plan)
    }

    static func test_reproducePairGraph(
        plan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        selectedFrameManifest: [PipelineRunner.SelectedFrameMapping],
        paths: ProjectPaths
    ) throws -> PairGraphArtifact {
        try reproducePairGraph(
            plan: plan,
            geometry: geometry,
            selectedFrameManifest: selectedFrameManifest,
            paths: paths
        )
    }

    static func test_requireCanonicalCameraBinding(
        geometry: GeometryArtifact,
        measured: ColmapResidualAnalyzer.Result,
        plan: ResolvedRunPlan,
        detailProfile: DetailProfile,
        selectedImages: [URL],
        selectedFrameManifest: [PipelineRunner.SelectedFrameMapping]? = nil
    ) throws {
        let manifest = selectedFrameManifest ?? selectedImages.map {
            PipelineRunner.SelectedFrameMapping(
                outputFileName: $0.lastPathComponent,
                groupId: "photos",
                isVideo: false
            )
        }
        try requireCanonicalCameraBinding(
            geometry: geometry,
            measured: measured,
            plan: plan,
            detailProfile: detailProfile,
            selectedImages: selectedImages,
            selectedFrameManifest: manifest
        )
    }

    static func test_independentlySelectedVideoOrigins(
        from sourceURL: URL,
        plan: ResolvedRunPlan,
        detail: DetailProfile,
        outputDirectory: URL
    ) async throws -> [VideoFrameOrigin] {
        let selection = try await independentlySelectVideoFrames(
            extractor: FrameExtractor(),
            from: [sourceURL],
            validPhotoCount: 0,
            to: outputDirectory,
            plan: plan,
            detail: detail,
            outputFormat: detail == .highDetail ? .png : .jpeg
        )
        return selection.groups[0].outputs.map(\.origin)
    }
#endif

    private static func reproducePairGraph(
        plan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        selectedFrameManifest: [PipelineRunner.SelectedFrameMapping],
        paths: ProjectPaths
    ) throws -> PairGraphArtifact {
        switch plan.geometryBackend {
        case .importedPoses:
            switch plan.datasetGeometryRoute {
            case .adoptDirect:
                // Directly-adopted geometry has no solved pair graph. Its
                // authenticated seed/source receipt and sparse/0 digests were
                // already re-verified when the geometry artifact loaded; the
                // artifact's own pair graph is the not-evaluated sentinel, so
                // that is what the caller must match.
                guard geometry.resolvedSource == .imported,
                      geometry.pairGraph.status == .notEvaluated else {
                    throw finishedProjectError(
                        "an adopted-geometry project has inconsistent pair-graph evidence"
                    )
                }
                return .notEvaluated()
            case .seedTriangulate, nil:
                // Re-triangulated dataset poses run the classical matching path,
                // so their pair-graph evidence exists and is reproduced exactly
                // as a COLMAP project's is.
                let pairEvidence = try PairGraphEvidenceStore.loadVerified(
                    from: paths.pairGraphEvidenceURL,
                    expectedImageNames: geometry.orderedImageNames,
                    databaseURL: paths.colmapDatabaseURL,
                    projectPaths: paths
                )
                let groups = try PipelineRunner.colmapPairGroups(
                    imageNames: geometry.orderedImageNames,
                    manifest: selectedFrameManifest
                )
                try PairGraphEvidenceStore.validateSchedule(
                    pairEvidence,
                    resolvedPlan: plan,
                    groups: groups
                )
                try PairGraphEvidenceStore.validateWorkerExecution(
                    pairEvidence,
                    workerExecution: geometry.workerExecution
                )
                return try pairEvidence.pairGraphArtifact()
            }
        case .colmap:
            let pairEvidence = try PairGraphEvidenceStore.loadVerified(
                from: paths.pairGraphEvidenceURL,
                expectedImageNames: geometry.orderedImageNames,
                databaseURL: paths.colmapDatabaseURL,
                projectPaths: paths
            )
            let groups = try PipelineRunner.colmapPairGroups(
                imageNames: geometry.orderedImageNames,
                manifest: selectedFrameManifest
            )
            try PairGraphEvidenceStore.validateSchedule(
                pairEvidence,
                resolvedPlan: plan,
                groups: groups
            )
            try PairGraphEvidenceStore.validateWorkerExecution(
                pairEvidence,
                workerExecution: geometry.workerExecution
            )
            return try pairEvidence.pairGraphArtifact()
        case .da3:
            let pairPlan = try ColmapPairEstimator.validatedDa3RefinementPairPlan(
                manifest: try Da3CoverageManifest.load(
                    from: paths.da3CoverageManifestURL
                ),
                imageNames: geometry.orderedImageNames,
                resolvedPlan: plan
            )
            let planBinding = PairGraphPlanBinding(plan)
            let pairEvidence = try PairGraphEvidenceStore.loadVerifiedDa3Refinement(
                from: paths.pairGraphEvidenceURL,
                expectedImageNames: geometry.orderedImageNames,
                expectedPlanBinding: planBinding,
                expectedPairPlan: pairPlan,
                databaseURL: paths.colmapDatabaseURL,
                projectPaths: paths
            )
            try PairGraphEvidenceStore.validateDa3WorkerExecution(
                pairEvidence,
                expectedPlanBinding: planBinding,
                expectedPairPlan: pairPlan,
                workerExecution: geometry.workerExecution
            )
            return try PairGraphEvidenceStore.da3PairGraphArtifact(
                pairEvidence,
                expectedPlanBinding: planBinding,
                expectedPairPlan: pairPlan
            )
        }
    }

    private static func validateFinishedProjectCore(
        at projectURL: URL,
        expectedInput: CanonicalFinishedProjectExpectedInput,
        context: FinishedProjectValidationContext,
        allowPendingVideoLineage: Bool
    ) throws -> FinishedProjectValidationResult {
        let canonicalProject = try canonicalFinishedProjectDirectory(projectURL)
        let paths = ProjectPaths(root: canonicalProject)
        let canonicalModel = paths.colmapSparseModelURL
        let canonicalOutput = paths.outputSplatURL
        let binaryModelFiles = ["cameras.bin", "images.bin", "points3D.bin"].map {
            canonicalModel.appendingPathComponent($0)
        }
        var protectedFiles = [
            paths.metadataURL,
            paths.geometryManifestURL,
            paths.trainingManifestURL,
            paths.framesSelectedManifestURL,
            GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            paths.colmapFeatureEvidenceURL,
            paths.pairGraphEvidenceURL,
            paths.colmapDatabaseURL,
            canonicalModel.appendingPathComponent("cameras.txt"),
            canonicalModel.appendingPathComponent("images.txt"),
            canonicalModel.appendingPathComponent("points3D.txt"),
            canonicalOutput,
        ]
        let possibleProtectedFiles = protectedFiles
            + binaryModelFiles
            + [paths.da3CoverageManifestURL, paths.photoSelectionArtifactURL]
        let protectedDirectoryMutationGuard: FinishedProjectProtectedPathMutationGuard
        let metadataMutationGuard: FinishedProjectProtectedPathMutationGuard
        do {
            protectedDirectoryMutationGuard = try FinishedProjectProtectedPathMutationGuard(
                urls: protectedAncestorDirectories(
                    projectRoot: canonicalProject,
                    files: possibleProtectedFiles
                )
            )
            metadataMutationGuard = try FinishedProjectProtectedPathMutationGuard(
                urls: [paths.metadataURL]
            )
        } catch {
            throw finishedProjectError("the project artifacts could not be guarded during validation")
        }
        defer { protectedDirectoryMutationGuard.close() }
        defer { metadataMutationGuard.close() }
        for binary in binaryModelFiles {
            if FileManager.default.fileExists(atPath: binary.path)
                || (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: binary.path
                )) != nil {
                protectedFiles.append(binary)
            }
        }
        let metadata: ProjectMetadata
        do {
            metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        } catch {
            throw finishedProjectError("project.json is not valid current-format metadata")
        }
        if metadata.resolvedRunPlan?.geometryBackend == .da3 {
            protectedFiles.append(paths.da3CoverageManifestURL)
        }
        if metadata.photoInputReceipts?.isEmpty == false {
            protectedFiles.append(paths.photoSelectionArtifactURL)
        }
        if metadata.resolvedRunPlan?.datasetGeometryRoute == .adoptDirect {
            // Directly-adopted dataset geometry runs no COLMAP solve, so the
            // feature database and the feature and pair-graph evidence never
            // exist. Do not guard files the route does not produce.
            let absentForDirectAdoption: Set<String> = [
                paths.colmapFeatureEvidenceURL.path,
                paths.pairGraphEvidenceURL.path,
                paths.colmapDatabaseURL.path,
            ]
            protectedFiles.removeAll { absentForDirectAdoption.contains($0.path) }
        }
        let protectedFileMutationGuard: FinishedProjectProtectedPathMutationGuard
        do {
            protectedFileMutationGuard = try FinishedProjectProtectedPathMutationGuard(
                urls: protectedFiles.filter { $0 != paths.metadataURL }
            )
        } catch {
            throw finishedProjectError("the project artifacts could not be guarded during validation")
        }
        defer { protectedFileMutationGuard.close() }
        let initialIdentities = try Dictionary(
            uniqueKeysWithValues: protectedFiles.map { url in
                (url.path, try safeFinishedProjectProtectedFileIdentity(at: url))
            }
        )
        let photoSelectionProjection: PhotoSelectionProjection?
        do {
            try VideoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
            try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
            photoSelectionProjection = try verifiedPhotoSelectionProjection(
                metadata: metadata,
                paths: paths
            )
        } catch {
            throw finishedProjectError("the controlled inputs do not match their receipts")
        }
        guard metadata.state.stage == .done,
              metadata.state.lastError == nil,
              metadata.checkpoint == nil,
              metadata.lastRunStartedAt == nil else {
            throw finishedProjectError("the pipeline is not durably finished")
        }
        if metadata.input.hasVideos, !allowPendingVideoLineage {
            throw finishedProjectError(
                "video projects require independent asynchronous frame rederivation"
            )
        }
        try validateCompletedStageTimings(
            metadata.stageTimings,
            input: metadata.input,
            datasetGeometryRoute: metadata.resolvedRunPlan?.datasetGeometryRoute
        )
        try requireExpectedInput(metadata.input, canonicalInput: expectedInput)
        guard let plan = metadata.resolvedRunPlan else {
            throw finishedProjectError("the project has no resolved run plan")
        }
        let initialInputBinding = try validateImportedInputBinding(
            input: metadata.input,
            videoInputReceipts: metadata.videoInputReceipts,
            photoInputReceipts: metadata.photoInputReceipts,
            photoSelectionProjection: photoSelectionProjection,
            plan: plan,
            canonicalInput: expectedInput,
            paths: paths
        )

        do {
            try RunPlanResolver.validate(
                requestedOptions: metadata.requestedRunOptions,
                input: metadata.input,
                hardware: context.hardwareProfile
            )
        } catch {
            throw finishedProjectError("the requested options are invalid for the release host")
        }
        let independentlyResolvedPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: context.hardwareProfile,
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42),
            trainingMemoryRetryBudgetBytes: metadata.trainingMemoryRetryBudgetBytes,
            datasetImport: datasetImportContext(for: metadata)
        )
        guard plan == independentlyResolvedPlan else {
            throw finishedProjectError(
                "the resolved run plan was not derived from the release host and fixed seed"
            )
        }
        let toolchainRequest: ToolchainCapabilityRequest
        do {
            toolchainRequest = try plan.toolchainCapabilityRequest()
        } catch {
            throw finishedProjectError("the resolved run plan has invalid toolchain capabilities")
        }

        let sidecarGeometry: GeometryArtifact
        do {
            sidecarGeometry = try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths
            )
        } catch {
            throw finishedProjectError("the geometry sidecar is missing or invalid")
        }
        guard sidecarGeometry.sourceModelPath == "SfM/colmap/sparse/0" else {
            throw finishedProjectError("the project has no canonical geometry artifact")
        }
        try requireGeometryPlanBinding(sidecarGeometry, plan: plan)
        let canonicalMeasurement: ColmapResidualAnalyzer.Result
        do {
            canonicalMeasurement = try ColmapResidualAnalyzer.analyze(
                modelDirectory: canonicalModel
            )
            try requireCanonicalOrientationBinding(
                geometry: sidecarGeometry,
                measured: canonicalMeasurement,
                plan: plan
            )
        } catch let error as FinishedProjectArtifactValidationError {
            throw error
        } catch {
            throw finishedProjectError(
                "the canonical orientation cannot be independently reproduced"
            )
        }
        let initialSelectedLineage = try validateSelectedFrameLineage(
            paths: paths,
            input: metadata.input,
            videoInputReceipts: metadata.videoInputReceipts,
            photoSelectionProjection: photoSelectionProjection,
            plan: plan,
            geometry: sidecarGeometry,
            allowPendingVideoLineage: allowPendingVideoLineage
        )
        // Directly-adopted geometry has no feature database or camera-grouping
        // evidence to reproduce; its cameras come from the imported model, and
        // its authenticated seed/source receipt was already re-verified when the
        // geometry sidecar loaded. The run-plan binding check above pins the
        // camera grouping and initialization recipe.
        if sidecarGeometry.resolvedSource != .imported {
            let cameraEvidence: [ColmapSelectedImageCameraEvidence]
            let featureEvidence: ColmapFeatureEvidence
            do {
                cameraEvidence = try PipelineRunner.colmapCameraGroupingEvidence(
                    imageNames: sidecarGeometry.orderedImageNames,
                    manifest: initialSelectedLineage.manifest
                )
                let selectedImages = sidecarGeometry.orderedImageNames.map {
                    paths.framesSelectedURL.appendingPathComponent($0)
                }
                let expectedCameraInitialization = try ColmapCameraInitializationReceipt.resolve(
                    plan: plan,
                    detailProfile: metadata.requestedRunOptions.detailProfile,
                    selectedImages: selectedImages
                )
                featureEvidence = try ColmapFeatureEvidenceStore.loadVerified(
                    from: paths.colmapFeatureEvidenceURL,
                    expectedImageNames: sidecarGeometry.orderedImageNames,
                    expectedCameraEvidence: cameraEvidence,
                    expectedCameraGroupingMode: PipelineRunner.colmapCameraGroupingMode(
                        cameraGrouping: plan.cameraGrouping,
                        evidence: cameraEvidence
                    ),
                    expectedCameraInitializationReceipt: expectedCameraInitialization,
                    databaseURL: paths.colmapDatabaseURL,
                    projectPaths: paths
                )
                guard featureEvidence.cameraGroupingReceipt
                        == sidecarGeometry.cameraGroupingReceipt,
                      featureEvidence.cameraInitializationReceipt
                        == sidecarGeometry.cameraInitializationReceipt,
                      sidecarGeometry.cameraInitializationReceipt.recipe
                        == plan.cameraInitializationRecipe,
                      featureEvidence.featureDatabaseDigest
                        == sidecarGeometry.featureDatabaseDigest else {
                    throw finishedProjectError(
                        "the camera grouping evidence does not match the geometry artifact"
                    )
                }
                try requireCanonicalCameraBinding(
                    geometry: sidecarGeometry,
                    measured: canonicalMeasurement,
                    plan: plan,
                    detailProfile: metadata.requestedRunOptions.detailProfile,
                    selectedImages: sidecarGeometry.orderedImageNames.map {
                        paths.framesSelectedURL.appendingPathComponent($0)
                    },
                    selectedFrameManifest: initialSelectedLineage.manifest
                )
            } catch let error as FinishedProjectArtifactValidationError {
                throw error
            } catch {
                throw finishedProjectError(
                    "the canonical camera grouping cannot be independently reproduced"
                )
            }
        }
        do {
            let reproducedPairGraph = try reproducePairGraph(
                plan: plan,
                geometry: sidecarGeometry,
                selectedFrameManifest: initialSelectedLineage.manifest,
                paths: paths
            )
            guard reproducedPairGraph == sidecarGeometry.pairGraph else {
                throw finishedProjectError(
                    "the pair-graph evidence does not match the geometry artifact"
                )
            }
        } catch let error as FinishedProjectArtifactValidationError {
            throw error
        } catch {
            throw finishedProjectError(
                "the accepted pair graph cannot be reproduced from the run plan"
            )
        }

        let sidecarTraining: TrainingArtifact
        do {
            sidecarTraining = try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            )
        } catch {
            throw finishedProjectError("the training sidecar is missing or invalid")
        }
        guard sidecarTraining.completionStatus == .completed,
              sidecarTraining.outputPath == "Output/splat.ply",
              sidecarTraining.droppedIntersectionCount == 0,
              sidecarTraining.detailProfile == metadata.requestedRunOptions.detailProfile,
              sidecarTraining.matchesResolvedTrainingPlan(
                  plan,
                  resourcePolicy: metadata.requestedRunOptions.resourcePolicy
              ),
              TrainingMemoryBudget.isValid(sidecarTraining.resourceAdmission),
              metadata.trainingMemoryRetryBudgetBytes.map({
                  $0 == plan.trainerMemoryBudgetBytes
              }) ?? true else {
            throw finishedProjectError("the training artifact does not match the resolved run plan")
        }

        let initialDatasetSnapshot: RetainedMsplatDatasetSnapshot
        do {
            initialDatasetSnapshot = try retainedMsplatDatasetSnapshot(
                paths: paths,
                geometry: sidecarGeometry
            )
        } catch {
            throw finishedProjectError("the retained msplat dataset is missing or unsafe")
        }
        let currentImportedInputDigest = try GeometryArtifactStore.inputDigest(projectPaths: paths)
        let currentSelectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: sidecarGeometry.orderedImageNames,
            projectPaths: paths
        )
        guard sidecarTraining.inputDigest == initialDatasetSnapshot.identity.inputDigest,
              sidecarTraining.geometryDigest == initialDatasetSnapshot.identity.geometryDigest,
              sidecarGeometry.inputDigest == currentImportedInputDigest,
              sidecarGeometry.selectedFramesDigest == currentSelectedFramesDigest else {
            throw finishedProjectError(
                "the training artifact does not match the retained msplat dataset and geometry"
            )
        }
        let preparationKind: MsplatDatasetPreparationKind
        do {
            preparationKind = try MsplatCameraCompatibility.requiresUndistortion(
                modelDirectory: canonicalModel
            ) ? .undistorted : .direct
        } catch {
            throw finishedProjectError("the canonical camera model is invalid")
        }
        let expectedDatasetDerivation = MsplatDatasetDerivationArtifact(
            sourceGeometryManifestSHA256: try GeometryArtifactStore.manifestDigest(
                matching: sidecarGeometry,
                at: paths.geometryManifestURL
            ),
            sourceSelectedFramesDigest: sidecarGeometry.selectedFramesDigest,
            preparationKind: preparationKind,
            maximumImageDimension: plan.maximumImageDimension,
            toolchainVersion: sidecarGeometry.provenance.toolchainVersion,
            colmapProvenance: sidecarGeometry.provenance.solver,
            registeredImageNames: initialDatasetSnapshot.registeredImageNames,
            datasetInputDigest: initialDatasetSnapshot.identity.inputDigest,
            datasetGeometryDigest: initialDatasetSnapshot.identity.geometryDigest
        )
        let canonicalRegisteredImageNames = canonicalMeasurement.registeredImageNames
        guard sidecarTraining.datasetDerivation == expectedDatasetDerivation,
              canonicalRegisteredImageNames.count
                == initialDatasetSnapshot.registeredImageNames.count,
              Set(canonicalRegisteredImageNames)
                == Set(initialDatasetSnapshot.registeredImageNames) else {
            throw finishedProjectError(
                "the training artifact was not derived from the accepted geometry"
            )
        }
        if preparationKind == .direct {
            try requireDirectDatasetImageBinding(
                paths: paths,
                registeredImageNames: initialDatasetSnapshot.registeredImageNames,
                maximumPixelDimension: plan.maximumImageDimension
            )
        }

        let outputEvidence: ValidatedPlyArtifactEvidence
        do {
            outputEvidence = try validatedPlyEvidence(at: canonicalOutput)
        } catch {
            throw finishedProjectError("the canonical PLY is invalid")
        }
        guard let outputBytes = sidecarTraining.outputBytes,
              outputBytes > 0,
              UInt64(outputBytes) == outputEvidence.byteCount,
              sidecarTraining.outputSHA256 == outputEvidence.sha256,
              sidecarTraining.gaussianCount == outputEvidence.vertexCount else {
            throw finishedProjectError("the canonical PLY does not match the training artifact")
        }
        guard let recordedBounds = sidecarTraining.sceneBounds,
              SplatSceneBoundsCalculator.matches(recordedBounds, outputEvidence.sceneBounds) else {
            throw finishedProjectError(
                "the training scene bounds do not match the canonical PLY"
            )
        }

        for url in protectedFiles {
            guard let initial = initialIdentities[url.path],
                  try safeFinishedProjectProtectedFileIdentity(at: url) == initial else {
                throw finishedProjectError("\(url.lastPathComponent) changed during validation")
            }
        }
        guard try validateImportedInputBinding(
            input: metadata.input,
            videoInputReceipts: metadata.videoInputReceipts,
            photoInputReceipts: metadata.photoInputReceipts,
            photoSelectionProjection: photoSelectionProjection,
            plan: plan,
            canonicalInput: expectedInput,
            paths: paths
        ) == initialInputBinding else {
            throw finishedProjectError("the imported input changed during validation")
        }
        guard try retainedMsplatDatasetSnapshot(
            paths: paths,
            geometry: sidecarGeometry
        ) == initialDatasetSnapshot else {
            throw finishedProjectError("the retained msplat dataset changed during validation")
        }
        guard try validateSelectedFrameLineage(
            paths: paths,
            input: metadata.input,
            videoInputReceipts: metadata.videoInputReceipts,
            photoSelectionProjection: photoSelectionProjection,
            plan: plan,
            geometry: sidecarGeometry,
            allowPendingVideoLineage: allowPendingVideoLineage
        ) == initialSelectedLineage else {
            throw finishedProjectError("selected-frame lineage changed during validation")
        }
        guard metadataMutationGuard.observedOnlyAttributeChanges(),
              protectedFileMutationGuard.observedOnlyAttributeChanges(),
              protectedDirectoryMutationGuard.observedNoChanges() else {
            throw finishedProjectError("a project artifact changed during validation")
        }
        return FinishedProjectValidationResult(
            evidence: FinishedProjectArtifactEvidence(
                metadata: metadata,
                input: metadata.input,
                requestedRunOptions: metadata.requestedRunOptions,
                resolvedRunPlan: plan,
                toolchainRequest: toolchainRequest,
                geometryArtifact: sidecarGeometry,
                trainingArtifact: sidecarTraining,
                outputURL: canonicalOutput,
                outputEvidence: outputEvidence
            ),
            projectSnapshot: FinishedProjectValidationSnapshot(
                protectedFileIdentities: initialIdentities,
                importedInputBinding: initialInputBinding,
                retainedDataset: initialDatasetSnapshot,
                selectedLineage: initialSelectedLineage
            )
        )
    }

    /// Binds persisted solver and trainer provenance to one independently
    /// authenticated installed toolchain closure.
    public static func validateToolchainBinding(
        finishedProject: FinishedProjectArtifactEvidence,
        installation: ToolchainInstallationEvidence
    ) throws {
        let geometry = finishedProject.geometryArtifact
        let training = finishedProject.trainingArtifact
        let installedCapabilities = Set(installation.installedCapabilities)
        let requiredCapabilities = Set(
            finishedProject.toolchainRequest.capabilities.map(\.rawValue)
        )
        guard requiredCapabilities.isSubset(of: installedCapabilities),
              !installation.installedArtifacts.isEmpty,
              geometry.provenance.toolchainVersion == installation.toolchainVersion else {
            throw finishedProjectError(
                "the authenticated toolchain does not satisfy the finished run"
            )
        }

        let runtimeClosure = geometry.workerExecution.colmapRuntimeClosure
        let solverBindingIsValid: Bool
        switch geometry.resolvedSource {
        case .computed:
            // A COLMAP solve pins its solver provenance to the runtime closure.
            solverBindingIsValid = geometry.provenance.solver.identifier == "colmap"
                && geometry.provenance.solver.payloadSHA256 == runtimeClosure.closureSHA256
        case .imported:
            // Imported geometry ran no COLMAP solve; its solver provenance pins the
            // dataset seed, not the runtime closure. The dataset's training model was
            // still converted by the signed COLMAP, so the runtime closure is
            // verified against the installed toolchain just the same.
            solverBindingIsValid = geometry.provenance.solver.identifier == "imported"
        }
        guard solverBindingIsValid,
              runtimeClosure.isValid,
              runtimeClosure.components.allSatisfy({ component in
                  installation.installedCriticalFileSHA256[
                    component.toolchainRelativePath
                  ] == component.sha256
              }) else {
            throw finishedProjectError(
                "the geometry solver does not match the authenticated toolchain"
            )
        }
        guard training.trainerBuildDigest == installation.nativeTrainerBuildDigest else {
            throw finishedProjectError(
                "the trainer does not match the authenticated toolchain"
            )
        }

        let componentNames = installation.signedComponents.map(\.name)
        let closurePaths = Set(runtimeClosure.components.map(\.toolchainRelativePath))
        guard Set(componentNames).count == componentNames.count,
              installation.signedComponents.filter({
                  closurePaths.isSubset(of: Set($0.declaredContents))
              }).count == 1 else {
            throw finishedProjectError(
                "the authenticated toolchain has duplicate or missing signed components"
            )
        }
        switch geometry.resolvedSource {
        case .computed:
            // A COLMAP solve (classical or imported-pose re-triangulation) pins
            // its persisted version and revision to signed COLMAP provenance.
            let colmapRecord = try uniqueProvenanceRecord(
                path: "provenance/colmap.json",
                installation: installation
            )
            guard colmapRecord.fileSHA256
                    == installation.installedCriticalFileSHA256["provenance/colmap.json"],
                  colmapRecord.stringFields["toolchain_name"] == "colmap",
                  colmapRecord.stringFields["source_version"]
                    == geometry.provenance.solver.version,
                  colmapRecord.stringFields["source_commit"]
                    == geometry.provenance.solver.revision,
                  colmapRecord.stringFields["executable_sha256"]
                    == runtimeClosure.sha256(for: "bin/colmap"),
                  geometry.solverVersion.hasSuffix(
                    "COLMAP \(geometry.provenance.solver.version) "
                        + "(git \(geometry.provenance.solver.revision.prefix(7)))"
                  ) else {
                throw finishedProjectError(
                    "the persisted COLMAP version and revision are not signed provenance"
                )
            }
        case .imported:
            // Directly-adopted geometry ran no COLMAP solve; its solver
            // provenance pins the dataset seed, not signed COLMAP provenance. Its
            // conversion-tooling runtime closure was already authenticated above;
            // here the artifact must instead satisfy its own imported contract,
            // whose closures the geometry store re-derives from Import/ on load.
            guard let importedEvidence = geometry.importedEvidence,
                  geometry.provenance.solver.identifier == "imported",
                  DatasetKind(rawValue: geometry.provenance.solver.version) != nil,
                  geometry.provenance.solver.revision
                    == importedEvidence.sourceClosureSHA256,
                  geometry.provenance.solver.payloadSHA256
                    == importedEvidence.seedClosureSHA256,
                  geometry.solverVersion
                    == "imported \(geometry.provenance.solver.version); "
                        + importedEvidence.route else {
                throw finishedProjectError(
                    "the imported dataset provenance is not internally consistent"
                )
            }
        }
        let msplatRecord = try uniqueProvenanceRecord(
            path: "msplat/build_info.json",
            installation: installation
        )
        guard msplatRecord.fileSHA256
                == installation.installedCriticalFileSHA256["msplat/build_info.json"],
              msplatRecord.stringFields["toolchain_name"] == "msplat",
              let msplatVersion = msplatRecord.stringFields["source_version"],
              !msplatVersion.isEmpty,
              let msplatCommit = msplatRecord.stringFields["source_commit"],
              msplatCommit.count == 40,
              isLowercaseGitCommit(msplatCommit),
              msplatRecord.stringFields["executable_sha256"]
                == installation.installedCriticalFileSHA256["bin/easysplat-train"],
              msplatRecord.stringFields["metallib_sha256"]
                == installation.installedCriticalFileSHA256["bin/default.metallib"],
              training.trainerVersion
                == "\(msplatVersion) (git \(msplatCommit.prefix(7)))",
              training.runtimeVersion == "native-metal-cli-v2" else {
            throw finishedProjectError(
                "the persisted native trainer version and revision are not signed provenance"
            )
        }

        switch (geometry.provenance.runtime, geometry.provenance.model) {
        case (nil, nil):
            // Imported-pose runs re-solve through the same COLMAP binary, so
            // their provenance is classical too.
            guard geometry.modelVersion == "none",
                  geometry.runtimeVersion
                    == "toolchain \(geometry.provenance.toolchainVersion)",
                  [.colmap, .importedPoses].contains(
                    finishedProject.resolvedRunPlan.geometryBackend
                  ) else {
                throw finishedProjectError(
                    "classical geometry provenance does not match the resolved route"
                )
            }
        case (let runtime?, let model?):
            guard runtime.identifier == "da3_mps",
                  installation.installedArtifacts["geometry-da3-base"] != nil,
                  installedCapabilities.contains(ToolchainCapability.da3Runtime.rawValue),
                  installation.installedCriticalFileSHA256["da3_mps/build_info.json"]
                    == runtime.payloadSHA256 else {
                throw finishedProjectError(
                    "the learned geometry runtime does not match the authenticated toolchain"
                )
            }
            let modelPath: String
            let componentName: String
            let capability: ToolchainCapability
            switch model.identifier {
            case "DA3-BASE":
                modelPath = "da3_mps/models/DA3-BASE/model.safetensors"
                componentName = "geometry-da3-base"
                capability = .da3Base
            case "DA3-SMALL":
                modelPath = "da3_mps/models/DA3-SMALL/model.safetensors"
                componentName = "geometry-da3-small"
                capability = .da3Small
            default:
                throw finishedProjectError(
                    "the learned geometry model is not a supported signed component"
                )
            }
            guard installation.installedArtifacts[componentName] != nil,
                  installedCapabilities.contains(capability.rawValue),
                  finishedProject.resolvedRunPlan.geometryBackend == .da3,
                  finishedProject.resolvedRunPlan.requiredToolchainCapabilities
                    .contains(capability.rawValue),
                  installation.installedCriticalFileSHA256[modelPath]
                    == model.payloadSHA256 else {
                throw finishedProjectError(
                    "the learned geometry model does not match the authenticated toolchain"
                )
            }
            let runtimeRecord = try uniqueProvenanceRecord(
                path: "da3_mps/build_info.json",
                installation: installation
            )
            let modelInfoPath = "da3_mps/models/\(model.identifier)/easysplat_model_info.json"
            let modelRecord = try uniqueProvenanceRecord(
                path: modelInfoPath,
                installation: installation
            )
            guard runtimeRecord.fileSHA256
                    == installation.installedCriticalFileSHA256["da3_mps/build_info.json"],
                  runtimeRecord.stringFields["toolchain_name"] == "da3_mps",
                  runtimeRecord.stringFields["source_ref"] == runtime.version,
                  runtimeRecord.stringFields["source_commit"] == runtime.revision,
                  runtimeRecord.stringFields[
                    model.identifier == "DA3-BASE"
                        ? "base_checkpoint_commit"
                        : "small_checkpoint_commit"
                  ] == model.revision,
                  modelRecord.fileSHA256
                    == installation.installedCriticalFileSHA256[modelInfoPath],
                  modelRecord.stringFields["requested_revision"] == model.version,
                  modelRecord.stringFields["resolved_sha"] == model.revision,
                  modelRecord.stringFields["license"]?.lowercased() == "apache-2.0",
                  geometry.runtimeVersion
                    == "toolchain \(geometry.provenance.toolchainVersion); "
                        + "\(runtime.identifier) \(runtime.version) "
                        + "(git \(runtime.revision.prefix(7)))",
                  geometry.modelVersion == "\(model.identifier)@\(model.revision)",
                  let signedModelComponent = uniqueSignedComponent(
                    named: componentName,
                    installation: installation
                  ),
                  signedModelComponent.declaredContents.contains(modelPath),
                  signedModelComponent.declaredContents.contains(modelInfoPath) else {
                throw finishedProjectError(
                    "the learned runtime and model versions are not signed provenance"
                )
            }
        default:
            throw finishedProjectError(
                "the geometry artifact has incomplete learned-component provenance"
            )
        }
    }

    private static func uniqueProvenanceRecord(
        path: String,
        installation: ToolchainInstallationEvidence
    ) throws -> ToolchainInstallationEvidence.ProvenanceRecord {
        let matches = installation.provenanceRecords.filter { $0.path == path }
        guard matches.count == 1, let record = matches.first else {
            throw finishedProjectError(
                "the authenticated toolchain has duplicate or missing provenance: \(path)"
            )
        }
        return record
    }

    private static func uniqueSignedComponent(
        named name: String,
        installation: ToolchainInstallationEvidence
    ) -> ToolchainInstallationEvidence.SignedComponent? {
        let matches = installation.signedComponents.filter { $0.name == name }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func isLowercaseGitCommit(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private struct FinishedProjectFileIdentity: Equatable, Hashable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let group: gid_t
        let linkCount: nlink_t
        let mode: mode_t
        let flags: UInt32
        let size: off_t
        let modifiedSeconds: time_t
        let modifiedNanoseconds: Int64
        let changedSeconds: time_t
        let changedNanoseconds: Int64
        let createdSeconds: time_t
        let createdNanoseconds: Int64

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            owner = status.st_uid
            group = status.st_gid
            linkCount = status.st_nlink
            mode = status.st_mode
            flags = status.st_flags
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            createdSeconds = status.st_birthtimespec.tv_sec
            createdNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        }
    }

    /// Release validation hashes protected artifacts so macOS may attach its
    /// sandbox consent label without turning a metadata-only ctime update into a
    /// false content mutation. Other file-identity consumers remain ctime-strict.
    private struct FinishedProjectProtectedFileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let group: gid_t
        let linkCount: nlink_t
        let mode: mode_t
        let flags: UInt32
        let size: off_t
        let modifiedSeconds: time_t
        let modifiedNanoseconds: Int64
        let createdSeconds: time_t
        let createdNanoseconds: Int64
        let sha256: String

        init(identity: FinishedProjectFileIdentity, sha256: String) {
            device = identity.device
            inode = identity.inode
            owner = identity.owner
            group = identity.group
            linkCount = identity.linkCount
            mode = identity.mode
            flags = identity.flags
            size = identity.size
            modifiedSeconds = identity.modifiedSeconds
            modifiedNanoseconds = identity.modifiedNanoseconds
            createdSeconds = identity.createdSeconds
            createdNanoseconds = identity.createdNanoseconds
            self.sha256 = sha256
        }
    }

    /// Keeps vnode watches armed while protected artifacts are parsed. Hashes
    /// permit macOS consent-label ctime churn; the watches still reject any
    /// write-and-restore attempt between the matching hash snapshots.
    private final class FinishedProjectProtectedPathMutationGuard {
        private var descriptors: [Int32] = []
        private var monitor: VnodeMutationMonitor?

        init(urls: [URL]) throws {
            var openedDescriptors: [Int32] = []
            do {
                for url in urls {
                    let descriptor = Darwin.open(
                        url.path,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                    guard descriptor >= 0 else {
                        throw finishedProjectError(
                            "\(url.lastPathComponent) changed during validation"
                        )
                    }
                    openedDescriptors.append(descriptor)
                }
                let watches = zip(urls, openedDescriptors).map { url, descriptor in
                    VnodeMutationMonitor.Watch(
                        descriptor: descriptor,
                        label: url.path,
                        ownership: .borrowed
                    )
                }
                monitor = try VnodeMutationMonitor(watches: watches)
                descriptors = openedDescriptors
            } catch {
                for descriptor in openedDescriptors.reversed() {
                    Darwin.close(descriptor)
                }
                throw error
            }
        }

        deinit {
            close()
        }

        func observedOnlyAttributeChanges() -> Bool {
            guard let snapshot = monitor?.poll(), snapshot.failure == nil else {
                return false
            }
            return snapshot.mutations.allSatisfy { mutation in
                mutation.flags == [.attribute]
            }
        }

        func observedNoChanges() -> Bool {
            monitor?.poll().isTrustworthy == true
        }

        func close() {
            monitor?.close()
            monitor = nil
            for descriptor in descriptors.reversed() {
                Darwin.close(descriptor)
            }
            descriptors.removeAll(keepingCapacity: false)
        }
    }

    private struct CanonicalFinishedProjectExpectedInput {
        enum Kind { case videos, photos, mixed }

        let kind: Kind
        let videoFiles: [CanonicalFinishedProjectInputFile]
        let photoFolder: CanonicalFinishedProjectPhotoFolder?
    }

    private struct CanonicalFinishedProjectInputFile: Equatable {
        let url: URL
        let relativePath: String?
        let identity: FinishedProjectFileIdentity
        let byteCount: Int64
        let sha256: String
        let typeIdentifier: String?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let orientation: Int?
        let isReadablePhoto: Bool
    }

    private struct CanonicalFinishedProjectPhotoFolder: Equatable {
        let url: URL
        let identity: FinishedProjectFileIdentity
        let discoveredPhotos: [CanonicalFinishedProjectInputFile]
        let acceptedPhotos: [CanonicalFinishedProjectInputFile]
        let allFileIdentities: [FinishedProjectFileIdentity]
        let traversedEntries: [CanonicalFinishedProjectTreeEntry]
    }

    private struct CanonicalFinishedProjectTreeEntry: Equatable {
        enum Kind: String, Equatable {
            case directory
            case regularFile
        }

        let relativePath: String
        let identity: FinishedProjectFileIdentity
        let kind: Kind
    }

    private struct RetainedMsplatDatasetSnapshot: Equatable {
        let identity: MsplatDatasetIdentity
        let registeredImageNames: [String]
        let directoryIdentities: [String: FinishedProjectFileIdentity]
        let fileIdentities: [String: FinishedProjectFileIdentity]
    }

    private struct SelectedFrameLineageSnapshot: Equatable {
        let manifest: [PipelineRunner.SelectedFrameMapping]
        let manifestIdentity: FinishedProjectFileIdentity
        let selectedDirectoryIdentity: FinishedProjectFileIdentity
        let selectedFileIdentities: [String: FinishedProjectFileIdentity]
        let sourceFileIdentities: [String: FinishedProjectFileIdentity]
    }

    private struct FinishedProjectValidationSnapshot: Equatable {
        let protectedFileIdentities: [String: FinishedProjectProtectedFileIdentity]
        let importedInputBinding: ImportedInputBinding
        let retainedDataset: RetainedMsplatDatasetSnapshot
        let selectedLineage: SelectedFrameLineageSnapshot
    }

    private struct FinishedProjectValidationResult {
        let evidence: FinishedProjectArtifactEvidence
        let projectSnapshot: FinishedProjectValidationSnapshot
    }

    private static func validateSelectedFrameLineage(
        paths: ProjectPaths,
        input: InputSpec,
        videoInputReceipts: [VideoInputReceipt]?,
        photoSelectionProjection: PhotoSelectionProjection?,
        plan: ResolvedRunPlan,
        geometry: GeometryArtifact,
        allowPendingVideoLineage: Bool
    ) throws -> SelectedFrameLineageSnapshot {
        let manifestIdentity = try safeFinishedProjectFileIdentity(
            at: paths.framesSelectedManifestURL
        )
        let data: Data
        let manifest: [PipelineRunner.SelectedFrameMapping]
        do {
            data = try BoundedFileReader.readRegularFile(
                at: paths.framesSelectedManifestURL,
                maximumBytes: 4 * 1_024 * 1_024
            )
            manifest = try JSONDecoder().decode(
                [PipelineRunner.SelectedFrameMapping].self,
                from: data
            )
        } catch {
            throw finishedProjectError("selected_manifest.json is missing or invalid")
        }
        let orderedNames = manifest.map(\.outputFileName)
        try requireExactOrderedTimestamps(
            manifest,
            geometryTimestamps: geometry.orderedImageTimestamps
        )
        guard !manifest.isEmpty,
              orderedNames == geometry.orderedImageNames,
              Set(orderedNames).count == orderedNames.count,
              manifest.count <= 3_000 else {
            throw finishedProjectError(
                "selected_manifest.json does not bind the exact ordered geometry frames"
            )
        }
        let selectedDirectoryIdentity = try safeFinishedProjectDirectoryIdentity(
            at: paths.framesSelectedURL
        )
        let selectedEntries = try FileManager.default.contentsOfDirectory(
            at: paths.framesSelectedURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard selectedEntries.map(\.lastPathComponent).sorted() == orderedNames.sorted() else {
            throw finishedProjectError("Frames/Selected contains unrecorded or missing files")
        }

        var selectedIdentities: [String: FinishedProjectFileIdentity] = [:]
        var sourceIdentities: [String: FinishedProjectFileIdentity] = [:]
        var selectedPhotoLineage: [(
            path: String,
            sha256: String,
            retainedRank: Int
        )] = []
        var priorVideoFrameByGroup: [String: Int] = [:]
        let reproductionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-selected-lineage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: reproductionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: reproductionRoot) }

        for (index, entry) in manifest.enumerated() {
            let expectedPrefix = String(format: "frame_%06d.", index)
            guard entry.schemaVersion == PipelineRunner.SelectedFrameMapping.currentSchemaVersion,
                  entry.outputFileName.hasPrefix(expectedPrefix),
                  URL(fileURLWithPath: entry.outputFileName).lastPathComponent
                    == entry.outputFileName,
                  ["jpg", "jpeg", "png"].contains(
                    URL(fileURLWithPath: entry.outputFileName).pathExtension.lowercased()
                  ),
                  let sourceRelativePath = entry.sourceProjectRelativePath,
                  sourceRelativePath.hasPrefix("Originals/"),
                  let sourceSHA256 = entry.sourceSHA256,
                  GeometryArtifactStore.isSHA256(sourceSHA256),
                  let selectedSHA256 = entry.selectedSHA256,
                  GeometryArtifactStore.isSHA256(selectedSHA256),
                  let selectedPixelSHA256 = entry.selectedPixelSHA256,
                  GeometryArtifactStore.isSHA256(selectedPixelSHA256),
                  let normalization = entry.normalization,
                  normalization.maximumPixelDimension == plan.maximumImageDimension,
                  normalization.outputFormat
                    == URL(fileURLWithPath: entry.outputFileName).pathExtension.lowercased() else {
                throw finishedProjectError(
                    "selected frame \(index) has incomplete or invalid lineage evidence"
                )
            }
            let source = try paths.resolveProjectRelativePath(sourceRelativePath)
            let selected = try paths.resolveProjectRelativePath(
                "Frames/Selected/\(entry.outputFileName)"
            )
            let sourceIdentity = try safeFinishedProjectFileIdentity(at: source)
            let selectedIdentity = try safeFinishedProjectFileIdentity(at: selected)
            let selectedContentIdentity = try PipelineRunner.selectedFrameContentIdentity(
                at: selected,
                maximumPixelDimension: normalization.maximumPixelDimension
            )
            guard try GeometryArtifactStore.sha256(of: source) == sourceSHA256,
                  selectedContentIdentity.sha256 == selectedSHA256,
                  selectedContentIdentity.pixelSHA256 == selectedPixelSHA256 else {
                throw finishedProjectError(
                    "selected frame \(index) does not match its recorded source and output"
                )
            }
            sourceIdentities[source.path] = sourceIdentity
            selectedIdentities[selected.path] = selectedIdentity

            if entry.isVideo {
                guard allowPendingVideoLineage,
                      entry.photoRetainedRank == nil,
                      input.hasVideos,
                      let videoSource = entry.videoSource,
                      videoSource.projectRelativePath == sourceRelativePath,
                      videoSource.sourceSHA256 == sourceSHA256,
                      videoSource.isValidEvidence,
                      let origin = entry.videoOrigin,
                      origin.isValidEvidence,
                      entry.timestampSeconds == origin.timestampSeconds,
                      entry.groupId.hasPrefix("video_"),
                      !sourceRelativePath.hasPrefix("Originals/Photos/") else {
                    throw finishedProjectError(
                        "selected video frame \(index) has invalid source-sample evidence"
                    )
                }
                if let prior = priorVideoFrameByGroup[entry.groupId],
                   origin.decodedFrameIndex <= prior {
                    throw finishedProjectError(
                        "selected video samples are not in source decode order"
                    )
                }
                priorVideoFrameByGroup[entry.groupId] = origin.decodedFrameIndex
            } else {
                guard input.hasPhotos,
                      let photoRetainedRank = entry.photoRetainedRank,
                      entry.groupId == "photos",
                      entry.timestampSeconds == nil,
                      entry.videoSource == nil,
                      entry.videoOrigin == nil,
                      sourceRelativePath.hasPrefix("Originals/Photos/") else {
                    throw finishedProjectError(
                        "selected photo frame \(index) has invalid source evidence"
                    )
                }
                if case .dataset = input {
                    // Dataset frames are copied pixel-for-pixel from the adopted
                    // originals — no resize, no re-encode, no exposure lift — so
                    // the retained file must be byte-identical to its source
                    // rather than a reproducible photo-normalized transcode.
                    guard entry.lowLightExposureEV == nil,
                          sourceSHA256 == selectedSHA256 else {
                        throw finishedProjectError(
                            "selected dataset frame \(index) is not a byte-identical copy of its source"
                        )
                    }
                } else {
                    let recomputedExposure = try FrameScoring.scoreFrame(at: source).lowLightExposureEV
                    let expectedExposure = recomputedExposure > 0 ? recomputedExposure : nil
                    guard equalOptionalFiniteDouble(
                        entry.lowLightExposureEV,
                        expectedExposure,
                        tolerance: 1e-12
                    ) else {
                        throw finishedProjectError(
                            "selected photo frame \(index) has untrusted exposure evidence"
                        )
                    }
                    let reproduced = reproductionRoot.appendingPathComponent(
                        entry.outputFileName
                    )
                    try PipelineRunner.reproduceSelectedFrame(
                        source: source,
                        destination: reproduced,
                        normalization: normalization,
                        exposureEV: entry.lowLightExposureEV
                    )
                    let reproducedIdentity = try PipelineRunner.selectedFrameContentIdentity(
                        at: reproduced,
                        maximumPixelDimension: normalization.maximumPixelDimension
                    )
                    guard reproducedIdentity.sha256 == selectedSHA256,
                          reproducedIdentity.pixelSHA256 == selectedPixelSHA256 else {
                        throw finishedProjectError(
                            "selected photo frame \(index) cannot be independently reproduced"
                        )
                    }
                }
                selectedPhotoLineage.append((
                    sourceRelativePath,
                    sourceSHA256,
                    photoRetainedRank
                ))
            }
        }

        switch input {
        case .photos, .dataset:
            guard let photoSelectionProjection else {
                throw finishedProjectError("the photo selection evidence is missing")
            }
            let target = try photoSelectionTarget(
                validCount: photoSelectionProjection.canonicalReceipts.count,
                plan: plan
            )
            try requireExactPhotoProjection(
                selectedPhotoLineage,
                projection: photoSelectionProjection,
                targetCount: target,
                failureReason:
                    "selected photos were not derived from the resolved deterministic policy"
            )
        case .video(let files):
            guard selectedPhotoLineage.isEmpty, photoSelectionProjection == nil else {
                throw finishedProjectError("a video-only project selected a photo frame")
            }
            try requireExactVideoCoverage(
                manifest,
                expectedGroups: try expectedVideoGroups(
                    sourceFiles: files,
                    receipts: videoInputReceipts,
                    pairingPolicy: plan.pairingPolicy
                )
            )
        case .mixed(let files, _):
            try requireExactVideoCoverage(
                manifest,
                expectedGroups: try expectedVideoGroups(
                    sourceFiles: files,
                    receipts: videoInputReceipts,
                    pairingPolicy: plan.pairingPolicy
                )
            )
            guard let photoSelectionProjection else {
                guard selectedPhotoLineage.isEmpty else {
                    throw finishedProjectError(
                        "selected mixed-input photos have no authenticated selection evidence"
                    )
                }
                break
            }
            guard selectedPhotoLineage.count
                    <= photoSelectionProjection.canonicalReceipts.count else {
                throw finishedProjectError(
                    "selected photos exceed the controlled mixed-input projection"
                )
            }
            try requireExactPhotoProjection(
                selectedPhotoLineage,
                projection: photoSelectionProjection,
                targetCount: selectedPhotoLineage.count,
                failureReason: "selected mixed-input photos were not deterministically chosen"
            )
        }

        guard try safeFinishedProjectFileIdentity(at: paths.framesSelectedManifestURL)
                == manifestIdentity,
              try safeFinishedProjectDirectoryIdentity(at: paths.framesSelectedURL)
                == selectedDirectoryIdentity,
              try selectedIdentities.allSatisfy({ path, identity in
                  try safeFinishedProjectFileIdentity(at: URL(fileURLWithPath: path)) == identity
              }),
              try sourceIdentities.allSatisfy({ path, identity in
                  try safeFinishedProjectFileIdentity(at: URL(fileURLWithPath: path)) == identity
              }) else {
            throw finishedProjectError("selected-frame evidence changed during validation")
        }
        return SelectedFrameLineageSnapshot(
            manifest: manifest,
            manifestIdentity: manifestIdentity,
            selectedDirectoryIdentity: selectedDirectoryIdentity,
            selectedFileIdentities: selectedIdentities,
            sourceFileIdentities: sourceIdentities
        )
    }

    private struct ExpectedVideoGroup {
        let groupID: String
        let sourcePath: String
        let sourceSHA256: String
    }

    private static func expectedVideoGroups(
        sourceFiles: [String],
        receipts: [VideoInputReceipt]?,
        pairingPolicy: ResolvedPairingPolicy
    ) throws -> [ExpectedVideoGroup] {
        guard let receipts,
              receipts.count == sourceFiles.count,
              zip(sourceFiles, receipts).allSatisfy({
                  $0 == $1.projectRelativePath
              }) else {
            throw finishedProjectError("the declared video inputs do not match their receipts")
        }
        return try expectedVideoGroups(
            sourceFiles: sourceFiles,
            sourceSHA256s: receipts.map(\.sha256),
            pairingPolicy: pairingPolicy
        )
    }

    private static func expectedVideoGroups(
        sourceFiles: [String],
        sourceSHA256s: [String],
        pairingPolicy: ResolvedPairingPolicy
    ) throws -> [ExpectedVideoGroup] {
        guard !sourceFiles.isEmpty,
              sourceFiles.count == sourceSHA256s.count,
              Set(sourceFiles).count == sourceFiles.count else {
            throw finishedProjectError("the declared video inputs are ambiguous")
        }
        let identities: [VideoClipIdentity]
        do {
            identities = try VideoClipIdentityResolver.resolve(
                sourceSHA256s: sourceSHA256s,
                pairingPolicy: pairingPolicy
            )
        } catch {
            throw finishedProjectError("the declared video input digests are invalid")
        }
        return identities.map {
            ExpectedVideoGroup(
                groupID: $0.groupID,
                sourcePath: sourceFiles[$0.sourceIndex],
                sourceSHA256: $0.sourceSHA256
            )
        }
    }

    private static func requireExactVideoCoverage(
        _ manifest: [PipelineRunner.SelectedFrameMapping],
        expectedGroups: [ExpectedVideoGroup]
    ) throws {
        let videoEntries = manifest.filter(\.isVideo)
        var observedGroupOrder: [String] = []
        for entry in videoEntries where observedGroupOrder.last != entry.groupId {
            observedGroupOrder.append(entry.groupId)
        }
        guard !expectedGroups.isEmpty,
              observedGroupOrder == expectedGroups.map(\.groupID),
              videoEntries.count >= expectedGroups.count * 2 else {
            throw finishedProjectError(
                "selected video frames do not cover the exact imported source group"
            )
        }
        for expected in expectedGroups {
            let entries = videoEntries.filter { $0.groupId == expected.groupID }
            guard entries.count >= 2,
                  entries.allSatisfy({
                      $0.sourceProjectRelativePath == expected.sourcePath
                          && $0.sourceSHA256 == expected.sourceSHA256
                  }) else {
                throw finishedProjectError(
                    "selected video frames do not cover the exact imported source group"
                )
            }
        }
    }

    private static func requireExactOrderedTimestamps(
        _ manifest: [PipelineRunner.SelectedFrameMapping],
        geometryTimestamps: [Double?]
    ) throws {
        let selectedTimestamps = manifest.map(\.timestampSeconds)
        guard selectedTimestamps.count == geometryTimestamps.count,
              zip(selectedTimestamps, geometryTimestamps).allSatisfy({
                  equalOptionalFiniteDouble($0, $1, tolerance: 0)
              }) else {
            throw finishedProjectError(
                "selected_manifest.json timestamps do not match accepted geometry"
            )
        }
    }

    private static func photoSelectionTarget(
        validCount: Int,
        plan: ResolvedRunPlan
    ) throws -> Int {
        guard validCount >= 0 else {
            throw finishedProjectError("the valid photo count is invalid")
        }
        if plan.photoSelection == .useAllValidPhotos {
            guard validCount <= plan.keyframeBudget else {
                throw finishedProjectError(
                    "the selected photo set exceeds the resolved frame budget"
                )
            }
            return validCount
        }
        return min(validCount, plan.keyframeBudget)
    }

    private static func verifiedPhotoSelectionProjection(
        metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws -> PhotoSelectionProjection? {
        let projection = try PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: paths
        )
        guard projection == nil else { return projection }

        var status = stat()
        guard lstat(paths.photoSelectionArtifactURL.path, &status) != 0 else {
            throw finishedProjectError(
                "the project contains stale photo selection evidence"
            )
        }
        guard errno == ENOENT else {
            throw finishedProjectError(
                "the photo selection evidence path could not be verified"
            )
        }
        return nil
    }

    private static func requireExactPhotoProjection(
        _ observed: [(path: String, sha256: String, retainedRank: Int)],
        projection: PhotoSelectionProjection,
        targetCount: Int,
        failureReason: String
    ) throws {
        let expected = try projection.project(targetCount: targetCount)
        guard observed.elementsEqual(
            expected.map {
                ($0.projectRelativePath, $0.sha256, $0.retainedRank)
            },
            by: { observed, expected in
                observed.path == expected.0
                    && observed.sha256 == expected.1
                    && observed.retainedRank == expected.2
            }
        ) else {
            throw finishedProjectError(failureReason)
        }
    }

    private static func equalOptionalFiniteDouble(
        _ lhs: Double?,
        _ rhs: Double?,
        tolerance: Double
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            return lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
        default:
            return false
        }
    }

    private static func validateSelectedVideoLineage(
        projectURL: URL,
        evidence: FinishedProjectArtifactEvidence,
        expectedLineage: SelectedFrameLineageSnapshot
    ) async throws {
        guard evidence.input.hasVideos else { return }
        let paths = ProjectPaths(root: try canonicalFinishedProjectDirectory(projectURL))
        try requireUnchangedSelectedLineage(expectedLineage, paths: paths)
        let manifestIdentity = try safeFinishedProjectFileIdentity(
            at: paths.framesSelectedManifestURL
        )
        let manifestData = try BoundedFileReader.readRegularFile(
            at: paths.framesSelectedManifestURL,
            maximumBytes: 4 * 1_024 * 1_024
        )
        let manifest = try JSONDecoder().decode(
            [PipelineRunner.SelectedFrameMapping].self,
            from: manifestData
        )
        let videoEntries = manifest.filter(\.isVideo)
        guard !videoEntries.isEmpty else {
            throw finishedProjectError("video input produced no selected video frames")
        }
        let grouped = Dictionary(grouping: videoEntries, by: \.groupId)
        let sourceFiles = evidence.input.videoFiles
        let expectedGroups = try expectedVideoGroups(
            sourceFiles: sourceFiles,
            receipts: evidence.metadata.videoInputReceipts,
            pairingPolicy: evidence.resolvedRunPlan.pairingPolicy
        )
        guard Set(grouped.keys) == Set(expectedGroups.map(\.groupID)) else {
            throw finishedProjectError("selected video groups do not match the declared inputs")
        }
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-video-lineage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let extractor = FrameExtractor()
        var orderedGroups: [[PipelineRunner.SelectedFrameMapping]] = []
        var sourceURLs: [URL] = []
        var recordedSources: [PipelineRunner.SelectedVideoSource] = []
        var analysisBindings: [FinishedVideoAnalysisBinding] = []
        var outputFormat: FrameOutputFormat?
        guard let videoReceipts = evidence.metadata.videoInputReceipts else {
            throw finishedProjectError("video analysis receipts are missing")
        }
        let receiptIndices = Dictionary(
            uniqueKeysWithValues: videoReceipts.enumerated().map {
                ($0.element.projectRelativePath, $0.offset)
            }
        )
        orderedGroups.reserveCapacity(expectedGroups.count)
        sourceURLs.reserveCapacity(expectedGroups.count)
        recordedSources.reserveCapacity(expectedGroups.count)
        for expectedGroup in expectedGroups {
            guard let entries = grouped[expectedGroup.groupID],
                  let recordedSource = entries.first?.videoSource,
                  entries.allSatisfy({ $0.videoSource == recordedSource }),
                  let firstNormalization = entries.first?.normalization,
                  entries.allSatisfy({
                      $0.normalization?.maximumPixelDimension
                        == evidence.resolvedRunPlan.maximumImageDimension
                  }),
                  let sourcePath = entries.first?.sourceProjectRelativePath,
                  entries.allSatisfy({ $0.sourceProjectRelativePath == sourcePath }),
                  sourcePath == expectedGroup.sourcePath,
                  entries.allSatisfy({ $0.sourceSHA256 == expectedGroup.sourceSHA256 }),
                  recordedSource.sourceSHA256 == expectedGroup.sourceSHA256,
                  entries.allSatisfy({ $0.videoOrigin?.isValidEvidence == true }) else {
                throw finishedProjectError(
                    "selected video group \(expectedGroup.groupID) has inconsistent lineage evidence"
                )
            }
            let source = try paths.resolveProjectRelativePath(sourcePath)
            let groupOutputFormat: FrameOutputFormat
            switch firstNormalization.outputFormat {
            case "jpg", "jpeg":
                groupOutputFormat = .jpeg
            case "png":
                groupOutputFormat = .png
            default:
                throw finishedProjectError("selected video output format is unsupported")
            }
            if let outputFormat, outputFormat != groupOutputFormat {
                throw finishedProjectError("selected video groups use inconsistent output formats")
            }
            outputFormat = groupOutputFormat
            guard let receiptIndex = receiptIndices[sourcePath] else {
                throw finishedProjectError("video analysis receipt is missing")
            }
            orderedGroups.append(entries)
            sourceURLs.append(source)
            recordedSources.append(recordedSource)
            analysisBindings.append(FinishedVideoAnalysisBinding(
                receipt: videoReceipts[receiptIndex],
                sourceIndex: receiptIndex,
                clipGroupID: expectedGroup.groupID,
                projectPaths: paths
            ))
        }

        let independent: IndependentFinishedVideoSelection
        do {
            independent = try await independentlySelectVideoFrames(
                extractor: extractor,
                from: sourceURLs,
                validPhotoCount: evidence.metadata.photoInputReceipts?.count ?? 0,
                to: temporaryRoot,
                plan: evidence.resolvedRunPlan,
                detail: evidence.requestedRunOptions.detailProfile,
                outputFormat: outputFormat ?? .jpeg,
                analysisBindings: analysisBindings
            )
        } catch {
            throw finishedProjectError(
                "the resolved video selection policy could not be independently reproduced"
            )
        }
        guard independent.groups.map({ $0.outputs.count })
                == orderedGroups.map(\.count),
              independent.frameTargets.videoTargets == orderedGroups.map(\.count),
              independent.frameTargets.photoTarget == manifest.filter({ !$0.isVideo }).count else {
            throw finishedProjectError(
                "selected frame groups do not match the resolved global frame budget"
            )
        }

        for (groupIndex, expectedGroup) in expectedGroups.enumerated() {
            let entries = orderedGroups[groupIndex]
            let independentlySelected = independent.groups[groupIndex]
            let recordedSource = recordedSources[groupIndex]
            let sourcePath = expectedGroup.sourcePath
            let inspectedSource = PipelineRunner.SelectedVideoSource(
                projectRelativePath: sourcePath,
                sourceSHA256: expectedGroup.sourceSHA256,
                source: independentlySelected.source
            )
            guard inspectedSource == recordedSource,
                  independentlySelected.outputs.count == entries.count,
                  independentlySelected.outputs.map(\.origin)
                    == entries.compactMap(\.videoOrigin) else {
                throw finishedProjectError(
                    "selected video frames do not match the resolved deterministic policy"
                )
            }
            let selectedDirectory = temporaryRoot.appendingPathComponent(
                "\(expectedGroup.groupID)-selected",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: selectedDirectory,
                withIntermediateDirectories: false
            )
            for (index, pair) in zip(entries, independentlySelected.outputs).enumerated() {
                let entry = pair.0
                let raw = pair.1
                guard raw.origin == entry.videoOrigin,
                      let normalization = entry.normalization,
                      let expectedSHA256 = entry.selectedSHA256,
                      let expectedPixelSHA256 = entry.selectedPixelSHA256 else {
                    throw finishedProjectError(
                        "selected video frame \(index) has incomplete evidence"
                    )
                }
                let recomputedExposure = try FrameScoring.scoreFrame(
                    at: raw.url
                ).lowLightExposureEV
                let expectedExposure = recomputedExposure > 0 ? recomputedExposure : nil
                guard equalOptionalFiniteDouble(
                    entry.lowLightExposureEV,
                    expectedExposure,
                    tolerance: 1e-12
                ) else {
                    throw finishedProjectError(
                        "selected video frame \(index) has untrusted exposure evidence"
                    )
                }
                let reproduced = selectedDirectory.appendingPathComponent(
                    entry.outputFileName
                )
                do {
                    try PipelineRunner.reproduceSelectedFrame(
                        source: raw.url,
                        destination: reproduced,
                        normalization: normalization,
                        exposureEV: entry.lowLightExposureEV
                    )
                    let reproducedIdentity = try PipelineRunner.selectedFrameContentIdentity(
                        at: reproduced,
                        maximumPixelDimension: normalization.maximumPixelDimension
                    )
                    guard reproducedIdentity.sha256 == expectedSHA256,
                          reproducedIdentity.pixelSHA256 == expectedPixelSHA256 else {
                        throw finishedProjectError(
                            "selected video frame \(index) differs from its source sample"
                        )
                    }
                } catch let error as FinishedProjectArtifactValidationError {
                    throw error
                } catch {
                    throw finishedProjectError(
                        "selected video frame \(index) could not be reproduced"
                    )
                }
            }
        }
        guard try BoundedFileReader.readRegularFile(
            at: paths.framesSelectedManifestURL,
            maximumBytes: 4 * 1_024 * 1_024
        ) == manifestData,
              try safeFinishedProjectFileIdentity(at: paths.framesSelectedManifestURL)
                == manifestIdentity else {
            throw finishedProjectError(
                "selected_manifest.json changed during video rederivation"
            )
        }
        try requireUnchangedSelectedLineage(expectedLineage, paths: paths)
    }

    private struct IndependentFinishedVideoSelection {
        struct Group {
            let source: FrameExtractionSource
            let outputs: [ExtractedFrameOutput]
        }

        let groups: [Group]
        let frameTargets: GlobalFrameTargets
    }

    private struct FinishedVideoAnalysisBinding {
        let receipt: VideoInputReceipt
        let sourceIndex: Int
        let clipGroupID: String
        let projectPaths: ProjectPaths
    }

    private static func independentlySelectVideoFrames(
        extractor: FrameExtractor,
        from sourceURLs: [URL],
        validPhotoCount: Int,
        to outputRoot: URL,
        plan: ResolvedRunPlan,
        detail: DetailProfile,
        outputFormat: FrameOutputFormat,
        analysisBindings: [FinishedVideoAnalysisBinding]? = nil
    ) async throws -> IndependentFinishedVideoSelection {
        guard !sourceURLs.isEmpty, validPhotoCount >= 0 else {
            throw finishedProjectError("the resolved video frame target is invalid")
        }
        var sources: [FrameExtractionSource] = []
        sources.reserveCapacity(sourceURLs.count)
        for url in sourceURLs {
            sources.append(try await extractor.inspect(url))
        }
        let target: Int
        if validPhotoCount > 0 {
            target = plan.keyframeBudget
        } else if let durationTarget = PipelineRunner.durationAwareVideoFrameTarget(
            durations: sources.map(\.durationSeconds),
            frameCeiling: plan.keyframeBudget,
            analysisFrameRate: plan.analysisFrameRate,
            detail: detail
        ) {
            target = durationTarget
        } else {
            throw finishedProjectError("the resolved video frame target is invalid")
        }
        let minimumDistanceRatio: Double = switch plan.capturePath {
        case .orbit: 0.12
        case .automatic, .walkthrough: 0.20
        case .largeArea: 0.30
        }
        let options = FrameExtractionOptions(
            targetCount: target,
            maxDimension: CGFloat(plan.maximumImageDimension),
            targetFPS: plan.analysisFrameRate,
            minDistanceRatio: minimumDistanceRatio,
            outputFormat: outputFormat
        )
        let policyRunner = finishedProjectFramePolicyRunner()
        let analyses: [FrameExtractionAnalysis]
        if let analysisBindings {
            guard analysisBindings.count == sources.count else {
                throw finishedProjectError("video analysis bindings are incomplete")
            }
            let policy = VideoFrameAnalysisPolicy(resolvedRunPlan: plan)
            analyses = try zip(sources, analysisBindings).map { source, binding in
                let artifactURL = try binding.projectPaths.resolveProjectRelativePath(
                    binding.receipt.analysisArtifactPath
                )
                let artifact = try VideoFrameAnalysisArtifactStore.load(
                    from: artifactURL,
                    receipt: binding.receipt,
                    expectedPolicy: policy,
                    expectedClipGroupID: binding.clipGroupID,
                    expectedSourceIndex: binding.sourceIndex,
                    projectPaths: binding.projectPaths
                )
                return try artifact.frameExtractionAnalysis(source: source)
            }
        } else {
            let preliminary = try policyRunner.resolveGlobalFrameTargets(
                videos: sources.map {
                    VideoFrameAllocationInput(
                        durationSeconds: $0.durationSeconds,
                        availableCandidateCount: target
                    )
                },
                validPhotoCount: validPhotoCount,
                targetCount: target,
                photoSelection: plan.photoSelection
            )
            analyses = try await policyRunner.analyzeVideoSources(
                sources,
                options: options,
                targetCounts: preliminary.videoTargets,
                maximumConcurrentTasks: PipelineRunner.videoSourceAnalysisConcurrency(
                    maximumConcurrentTasks: plan.geometryWorkerBudget
                        .maximumConcurrentVideoSourceAnalysisTasks,
                    videoSourceCount: sources.count
                ),
                concurrencyMeter: VideoSourceAnalysisConcurrencyMeter(),
                progress: { _, _ in }
            )
        }
        let finalTargets = try policyRunner.resolveGlobalFrameTargets(
            videos: analyses.map {
                VideoFrameAllocationInput(
                    durationSeconds: $0.durationSeconds,
                    availableCandidateCount: $0.availableCandidateCount
                )
            },
            validPhotoCount: validPhotoCount,
            targetCount: target,
            photoSelection: plan.photoSelection
        )
        var groups: [IndependentFinishedVideoSelection.Group] = []
        groups.reserveCapacity(analyses.count)
        for (index, analysis) in analyses.enumerated() {
            let perVideoTarget = finalTargets.videoTargets[index]
            guard perVideoTarget > 0 else {
                throw finishedProjectError("the global video frame allocation is incomplete")
            }
            var outputOptions = options
            outputOptions.targetCount = perVideoTarget
            let outputDirectory = outputRoot.appendingPathComponent(
                String(format: "video_%03d-raw", index),
                isDirectory: true
            )
            let outputs = try await extractor.extractFrameOutputs(
                from: analysis,
                targetCount: perVideoTarget,
                to: outputDirectory,
                options: outputOptions,
                progress: { _, _ in }
            )
            guard outputs.count == perVideoTarget else {
                throw finishedProjectError("video selection produced an incomplete frame set")
            }
            groups.append(.init(source: sources[index], outputs: outputs))
        }
        return IndependentFinishedVideoSelection(
            groups: groups,
            frameTargets: finalTargets
        )
    }

    private static func finishedProjectFramePolicyRunner() -> PipelineRunner {
        let root = URL(fileURLWithPath: "/")
        let da3 = Da3Toolchain(
            root: root,
            sfmTool: root,
            python: root,
            models: root,
            modelBundle: root,
            smallModelBundle: root
        )
        return PipelineRunner(
            projectURL: root,
            config: .init(
                toolchain: ToolchainPaths(
                    root: root,
                    dataRoot: root,
                    toolchainIdentity: "local-\(root.lastPathComponent)",
                    colmap: root,
                    msplat: root,
                    metallib: root,
                    da3: da3
                )
            )
        )
    }

    private static func requireUnchangedSelectedLineage(
        _ expected: SelectedFrameLineageSnapshot,
        paths: ProjectPaths
    ) throws {
        let manifestData = try BoundedFileReader.readRegularFile(
            at: paths.framesSelectedManifestURL,
            maximumBytes: 4 * 1_024 * 1_024
        )
        guard try JSONDecoder().decode(
            [PipelineRunner.SelectedFrameMapping].self,
            from: manifestData
        ) == expected.manifest,
              try safeFinishedProjectFileIdentity(at: paths.framesSelectedManifestURL)
                == expected.manifestIdentity,
              try safeFinishedProjectDirectoryIdentity(at: paths.framesSelectedURL)
                == expected.selectedDirectoryIdentity,
              try expected.selectedFileIdentities.allSatisfy({ path, identity in
                  try safeFinishedProjectFileIdentity(at: URL(fileURLWithPath: path)) == identity
              }),
              try expected.sourceFileIdentities.allSatisfy({ path, identity in
                  try safeFinishedProjectFileIdentity(at: URL(fileURLWithPath: path)) == identity
              }) else {
            throw finishedProjectError(
                "selected-frame lineage changed during independent video rederivation"
            )
        }
    }

    private static func retainedMsplatDatasetSnapshot(
        paths: ProjectPaths,
        geometry: GeometryArtifact
    ) throws -> RetainedMsplatDatasetSnapshot {
        let orderedImageNames = geometry.orderedImageNames
        guard !orderedImageNames.isEmpty,
              Set(orderedImageNames).count == orderedImageNames.count,
              orderedImageNames.allSatisfy(isSafeSelectedImageName) else {
            throw finishedProjectError("the geometry has an invalid selected-image order")
        }
        let dataset = try paths.resolveProjectRelativePath("Training/msplat_dataset")
        let images = try paths.resolveProjectRelativePath("Training/msplat_dataset/images")
        let sparseRoot = try paths.resolveProjectRelativePath("Training/msplat_dataset/sparse")
        let sparse = try paths.resolveProjectRelativePath("Training/msplat_dataset/sparse/0")
        let directories = [dataset, images, sparseRoot, sparse]
        let directoryIdentities = try Dictionary(
            uniqueKeysWithValues: directories.map { directory in
                (directory.path, try safeFinishedProjectDirectoryIdentity(at: directory))
            }
        )
        try requireExactDirectoryEntryNames(dataset, expected: ["images", "sparse"])
        try requireExactDirectoryEntryNames(sparseRoot, expected: ["0"])
        let registeredImageNames = try ColmapSparseModelMembershipReader(
            databaseURL: paths.colmapDatabaseURL,
            selectedImageNames: orderedImageNames
        ).registeredImageNames(in: sparse, checkCancellation: {})
        guard registeredImageNames.count == geometry.registeredViewCount else {
            throw finishedProjectError(
                "the retained training cameras do not match registered geometry coverage"
            )
        }
        try requireExactDirectoryEntryNames(images, expected: registeredImageNames)
        let sparseNames = [
            "cameras.bin",
            "images.bin",
            "points3D.bin",
            MsplatOrientationOverlay.fileName,
        ]
        try requireExactDirectoryEntryNames(sparse, expected: sparseNames)

        let imageFiles = registeredImageNames.map { images.appendingPathComponent($0) }
        let sparseFiles = sparseNames.map { sparse.appendingPathComponent($0) }
        let allFiles = imageFiles + sparseFiles
        let fileIdentities = try Dictionary(
            uniqueKeysWithValues: allFiles.map { file in
                (file.path, try safeFinishedProjectFileIdentity(at: file))
            }
        )
        let identity = try MsplatDatasetIdentity.compute(
            imageFiles: imageFiles,
            sparseDirectory: sparse
        )
        let retainedOrientation = try BoundedFileReader.readRegularFile(
            at: sparse.appendingPathComponent(MsplatOrientationOverlay.fileName),
            maximumBytes: 4_096
        )
        let expectedOrientation = try MsplatOrientationOverlay(
            canonicalOrientation: geometry.canonicalOrientation
        ).encodedData()
        guard retainedOrientation == expectedOrientation else {
            throw finishedProjectError(
                "the retained training orientation does not match accepted geometry"
            )
        }
        for file in allFiles {
            let finalIdentity = try safeFinishedProjectFileIdentity(at: file)
            guard fileIdentities[file.path] == finalIdentity else {
                throw finishedProjectError("\(file.lastPathComponent) changed during dataset hashing")
            }
        }
        for directory in directories {
            let finalIdentity = try safeFinishedProjectDirectoryIdentity(at: directory)
            guard directoryIdentities[directory.path] == finalIdentity else {
                throw finishedProjectError("the retained dataset layout changed during validation")
            }
        }
        return RetainedMsplatDatasetSnapshot(
            identity: identity,
            registeredImageNames: registeredImageNames,
            directoryIdentities: directoryIdentities,
            fileIdentities: fileIdentities
        )
    }

    private static func requireDirectDatasetImageBinding(
        paths: ProjectPaths,
        registeredImageNames: [String],
        maximumPixelDimension: Int
    ) throws {
        let retainedImages = try paths.resolveProjectRelativePath(
            "Training/msplat_dataset/images"
        )
        for name in registeredImageNames {
            let selected = paths.framesSelectedURL.appendingPathComponent(name)
            let retained = retainedImages.appendingPathComponent(name)
            let selectedIdentity = try PipelineRunner.selectedFrameContentIdentity(
                at: selected,
                maximumPixelDimension: maximumPixelDimension
            )
            let retainedIdentity = try PipelineRunner.selectedFrameContentIdentity(
                at: retained,
                maximumPixelDimension: maximumPixelDimension
            )
            guard retainedIdentity == selectedIdentity else {
                throw finishedProjectError(
                    "the retained training image \(name) does not match its selected frame"
                )
            }
        }
    }

    private static func isSafeSelectedImageName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              URL(fileURLWithPath: name).lastPathComponent == name else {
            return false
        }
        return ["jpg", "jpeg", "png"].contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        )
    }

    private static func requireExactDirectoryEntryNames(
        _ directory: URL,
        expected: [String]
    ) throws {
        guard Set(expected).count == expected.count else {
            throw finishedProjectError("the expected retained dataset layout is ambiguous")
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard entries.count == expected.count,
              Set(entries.map(\.lastPathComponent)) == Set(expected) else {
            throw finishedProjectError("the retained dataset layout has unexpected entries")
        }
    }

    private static func safeFinishedProjectDirectoryIdentity(
        at url: URL
    ) throws -> FinishedProjectFileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_nlink >= 2 else {
            throw finishedProjectError("\(url.lastPathComponent) is not an ordinary directory")
        }
        let permissions = status.st_mode & 0o7777
        guard (permissions & 0o700) == mode_t(S_IRUSR | S_IWUSR | S_IXUSR),
              (permissions & 0o022) == 0,
              (permissions & 0o7000) == 0 else {
            throw finishedProjectError("\(url.lastPathComponent) has unsafe directory permissions")
        }
        return FinishedProjectFileIdentity(status)
    }

    private static func canonicalFinishedProjectDirectory(_ url: URL) throws -> URL {
        var supplied = stat()
        guard lstat(url.path, &supplied) == 0,
              (supplied.st_mode & S_IFMT) == S_IFDIR,
              url.pathExtension == "easysplatproj" else {
            throw finishedProjectError("the project root is not an ordinary .easysplatproj directory")
        }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var resolved = stat()
        guard lstat(canonical.path, &resolved) == 0,
              supplied.st_dev == resolved.st_dev,
              supplied.st_ino == resolved.st_ino,
              (resolved.st_mode & S_IFMT) == S_IFDIR else {
            throw finishedProjectError("the project root changed while it was resolved")
        }
        return canonical
    }

    private static func canonicalFinishedProjectExpectedInput(
        _ input: FinishedProjectExpectedInput
    ) throws -> CanonicalFinishedProjectExpectedInput {
        let result: CanonicalFinishedProjectExpectedInput
        switch input {
        case .videoFiles(let files):
            result = CanonicalFinishedProjectExpectedInput(
                kind: .videos,
                videoFiles: try canonicalFinishedProjectVideoFiles(files),
                photoFolder: nil
            )
        case .photoFolder(let folder):
            result = CanonicalFinishedProjectExpectedInput(
                kind: .photos,
                videoFiles: [],
                photoFolder: try canonicalFinishedProjectPhotoFolder(folder)
            )
        case .mixed(let videos, let photoFolder):
            result = CanonicalFinishedProjectExpectedInput(
                kind: .mixed,
                videoFiles: try canonicalFinishedProjectVideoFiles(videos),
                photoFolder: try canonicalFinishedProjectPhotoFolder(photoFolder)
            )
        }
        let videoIdentities = Set(result.videoFiles.map(\.identity))
        guard videoIdentities.count == result.videoFiles.count,
              result.photoFolder.map({ folder in
                  videoIdentities.isDisjoint(with: Set(folder.allFileIdentities))
              }) ?? true else {
            throw finishedProjectError("the expected input selection contains duplicate files")
        }
        return result
    }

    private static func canonicalFinishedProjectVideoFiles(
        _ files: [URL]
    ) throws -> [CanonicalFinishedProjectInputFile] {
        guard !files.isEmpty, files.count <= 64 else {
            throw finishedProjectError("the expected video selection count is invalid")
        }
        let result = try files.map {
            try stableFinishedProjectInputFile(at: $0, relativePath: nil)
        }
        let pathKeys = result.map { canonicalFinishedProjectPathKey($0.url.path) }
        guard Set(pathKeys).count == pathKeys.count,
              Set(result.map(\.identity)).count == result.count else {
            throw finishedProjectError("the expected video selection contains duplicate files")
        }
        return result
    }

    private static func canonicalFinishedProjectPhotoFolder(
        _ suppliedURL: URL
    ) throws -> CanonicalFinishedProjectPhotoFolder {
        guard suppliedURL.isFileURL else {
            throw finishedProjectError("the expected photo input is not a local folder")
        }
        var suppliedStatus = stat()
        guard lstat(suppliedURL.path, &suppliedStatus) == 0,
              (suppliedStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw finishedProjectError("the expected photo input is not an ordinary folder")
        }
        let canonicalURL = suppliedURL.standardizedFileURL.resolvingSymlinksInPath()
        var canonicalStatus = stat()
        guard lstat(canonicalURL.path, &canonicalStatus) == 0,
              FinishedProjectFileIdentity(canonicalStatus)
                == FinishedProjectFileIdentity(suppliedStatus) else {
            throw finishedProjectError("the expected photo input changed while it was resolved")
        }
        let descriptor = Darwin.open(
            canonicalURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw finishedProjectError("the expected photo input could not be opened safely")
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              FinishedProjectFileIdentity(openedStatus)
                == FinishedProjectFileIdentity(suppliedStatus) else {
            throw finishedProjectError("the expected photo input changed while it was opened")
        }

        var discovered: [CanonicalFinishedProjectInputFile] = []
        var allFileIdentities: [FinishedProjectFileIdentity] = []
        var traversedEntries: [CanonicalFinishedProjectTreeEntry] = []
        var normalizedEntryKeys = Set<String>()
        var traversedEntryCount = 0
        try scanFinishedProjectPhotoFolder(
            descriptor: descriptor,
            canonicalRoot: canonicalURL,
            prefix: "",
            depth: 0,
            traversedEntryCount: &traversedEntryCount,
            normalizedEntryKeys: &normalizedEntryKeys,
            discoveredPhotos: &discovered,
            allFileIdentities: &allFileIdentities,
            traversedEntries: &traversedEntries
        )
        discovered.sort { ($0.relativePath ?? "") < ($1.relativePath ?? "") }
        guard discovered.count <= 10_000,
              Set(allFileIdentities).count == allFileIdentities.count else {
            throw finishedProjectError("the expected photo input has an ambiguous file set")
        }
        var accepted: [CanonicalFinishedProjectInputFile] = []
        var seenDigests = Set<String>()
        for photo in discovered where photo.isReadablePhoto {
            if seenDigests.insert(photo.sha256).inserted {
                accepted.append(photo)
            }
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              FinishedProjectFileIdentity(finalStatus)
                == FinishedProjectFileIdentity(suppliedStatus),
              lstat(canonicalURL.path, &canonicalStatus) == 0,
              FinishedProjectFileIdentity(canonicalStatus)
                == FinishedProjectFileIdentity(suppliedStatus) else {
            throw finishedProjectError("the expected photo input changed during inspection")
        }
        return CanonicalFinishedProjectPhotoFolder(
            url: canonicalURL,
            identity: FinishedProjectFileIdentity(suppliedStatus),
            discoveredPhotos: discovered,
            acceptedPhotos: accepted,
            allFileIdentities: allFileIdentities,
            traversedEntries: traversedEntries
        )
    }

    private static func scanFinishedProjectPhotoFolder(
        descriptor: Int32,
        canonicalRoot: URL,
        prefix: String,
        depth: Int,
        traversedEntryCount: inout Int,
        normalizedEntryKeys: inout Set<String>,
        discoveredPhotos: inout [CanonicalFinishedProjectInputFile],
        allFileIdentities: inout [FinishedProjectFileIdentity],
        traversedEntries: inout [CanonicalFinishedProjectTreeEntry]
    ) throws {
        guard depth <= 64 else {
            throw finishedProjectError("the expected photo input exceeds the traversal depth limit")
        }
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw finishedProjectError("the expected photo input could not be traversed safely")
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw finishedProjectError("the expected photo input could not be traversed safely")
        }
        for name in names.sorted() {
            try Task.checkCancellation()
            traversedEntryCount += 1
            guard traversedEntryCount <= 50_000 else {
                throw finishedProjectError("the expected photo input exceeds the traversal limit")
            }
            let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let normalizedKey = canonicalFinishedProjectPathKey(relativePath)
            guard normalizedEntryKeys.insert(normalizedKey).inserted else {
                throw finishedProjectError(
                    "the expected photo input has case- or Unicode-equivalent entries"
                )
            }
            var entryStatus = stat()
            guard name.withCString({
                fstatat(descriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw finishedProjectError("the expected photo input contains an unreadable entry")
            }
            switch entryStatus.st_mode & S_IFMT {
            case S_IFLNK:
                throw finishedProjectError("the expected photo input contains a symbolic link")
            case S_IFDIR:
                guard !name.hasPrefix(".") else {
                    throw finishedProjectError("the expected photo input contains a hidden subtree")
                }
                let child = name.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw finishedProjectError("the expected photo input contains an unsafe directory")
                }
                do {
                    var opened = stat()
                    guard fstat(child, &opened) == 0,
                          FinishedProjectFileIdentity(opened)
                            == FinishedProjectFileIdentity(entryStatus) else {
                        throw finishedProjectError(
                            "the expected photo input changed during traversal"
                        )
                    }
                    traversedEntries.append(
                        CanonicalFinishedProjectTreeEntry(
                            relativePath: relativePath,
                            identity: FinishedProjectFileIdentity(entryStatus),
                            kind: .directory
                        )
                    )
                    try scanFinishedProjectPhotoFolder(
                        descriptor: child,
                        canonicalRoot: canonicalRoot,
                        prefix: relativePath,
                        depth: depth + 1,
                        traversedEntryCount: &traversedEntryCount,
                        normalizedEntryKeys: &normalizedEntryKeys,
                        discoveredPhotos: &discoveredPhotos,
                        allFileIdentities: &allFileIdentities,
                        traversedEntries: &traversedEntries
                    )
                    var rebound = stat()
                    guard name.withCString({
                        fstatat(descriptor, $0, &rebound, AT_SYMLINK_NOFOLLOW)
                    }) == 0,
                          FinishedProjectFileIdentity(rebound)
                            == FinishedProjectFileIdentity(entryStatus) else {
                        throw finishedProjectError(
                            "the expected photo input changed during traversal"
                        )
                    }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            case S_IFREG:
                guard entryStatus.st_nlink == 1 else {
                    throw finishedProjectError("the expected photo input contains a hard-linked file")
                }
                let identity = FinishedProjectFileIdentity(entryStatus)
                allFileIdentities.append(identity)
                traversedEntries.append(
                    CanonicalFinishedProjectTreeEntry(
                        relativePath: relativePath,
                        identity: identity,
                        kind: .regularFile
                    )
                )
                guard !name.hasPrefix(".") else { continue }
                let detectedType = try detectedFinishedProjectPhotoType(
                    parentDescriptor: descriptor,
                    leaf: name,
                    expectedStatus: entryStatus
                )
                let detectedImage = detectedType.map {
                    isSupportedFinishedProjectPhotoType($0)
                } == true
                let declaredImage = detectedType == nil
                    && UTType(filenameExtension: (name as NSString).pathExtension)?
                        .conforms(to: .image) == true
                guard detectedImage || declaredImage else {
                    continue
                }
                guard entryStatus.st_size > 0 else {
                    throw finishedProjectError("the expected photo input contains an empty photo")
                }
                discoveredPhotos.append(
                    try stableFinishedProjectInputFile(
                        parentDescriptor: descriptor,
                        leaf: name,
                        url: canonicalRoot.appendingPathComponent(relativePath),
                        relativePath: relativePath,
                        expectedStatus: entryStatus,
                        inspectAsPhoto: true
                    )
                )
            default:
                throw finishedProjectError("the expected photo input contains a special entry")
            }
        }
    }

    private static func detectedFinishedProjectPhotoType(
        parentDescriptor: Int32,
        leaf: String,
        expectedStatus: stat
    ) throws -> String? {
        let expectedIdentity = FinishedProjectFileIdentity(expectedStatus)
        let descriptor = leaf.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw finishedProjectError("an expected photo changed before type inspection")
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              FinishedProjectFileIdentity(opened) == expectedIdentity else {
            throw finishedProjectError("an expected photo changed during type inspection")
        }
        let typeIdentifier = finishedProjectImageSource(
            descriptor: descriptor,
            declaredFilename: leaf
        )?.typeIdentifier
        var final = stat()
        var rebound = stat()
        guard fstat(descriptor, &final) == 0,
              FinishedProjectFileIdentity(final) == expectedIdentity,
              leaf.withCString({
                  fstatat(parentDescriptor, $0, &rebound, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              FinishedProjectFileIdentity(rebound) == expectedIdentity else {
            throw finishedProjectError("an expected photo changed during type inspection")
        }
        return typeIdentifier
    }

    private static func stableFinishedProjectInputFile(
        at suppliedURL: URL,
        relativePath: String?,
        inspectAsPhoto: Bool = false
    ) throws -> CanonicalFinishedProjectInputFile {
        guard suppliedURL.isFileURL else {
            throw finishedProjectError("the expected input is not a local file")
        }
        var suppliedStatus = stat()
        guard lstat(suppliedURL.path, &suppliedStatus) == 0,
              (suppliedStatus.st_mode & S_IFMT) == S_IFREG,
              suppliedStatus.st_nlink == 1,
              suppliedStatus.st_size > 0 else {
            throw finishedProjectError("the expected input is not an ordinary single-link file")
        }
        let canonicalURL = suppliedURL.standardizedFileURL.resolvingSymlinksInPath()
        var resolvedStatus = stat()
        guard lstat(canonicalURL.path, &resolvedStatus) == 0,
              FinishedProjectFileIdentity(resolvedStatus)
                == FinishedProjectFileIdentity(suppliedStatus) else {
            throw finishedProjectError("the expected input changed while it was resolved")
        }
        let descriptor = Darwin.open(
            canonicalURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw finishedProjectError("the expected input could not be opened safely")
        }
        defer { Darwin.close(descriptor) }
        return try stableFinishedProjectInputFile(
            descriptor: descriptor,
            url: canonicalURL,
            relativePath: relativePath,
            expectedStatus: suppliedStatus,
            inspectAsPhoto: inspectAsPhoto,
            reboundStatus: {
                var rebound = stat()
                guard lstat(canonicalURL.path, &rebound) == 0 else { return nil }
                return rebound
            }
        )
    }

    private static func stableFinishedProjectInputFile(
        parentDescriptor: Int32,
        leaf: String,
        url: URL,
        relativePath: String,
        expectedStatus: stat,
        inspectAsPhoto: Bool
    ) throws -> CanonicalFinishedProjectInputFile {
        let descriptor = leaf.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw finishedProjectError("an expected photo changed before it could be opened")
        }
        defer { Darwin.close(descriptor) }
        return try stableFinishedProjectInputFile(
            descriptor: descriptor,
            url: url,
            relativePath: relativePath,
            expectedStatus: expectedStatus,
            inspectAsPhoto: inspectAsPhoto,
            reboundStatus: {
                var rebound = stat()
                guard leaf.withCString({
                    fstatat(parentDescriptor, $0, &rebound, AT_SYMLINK_NOFOLLOW)
                }) == 0 else { return nil }
                return rebound
            }
        )
    }

    private static func stableFinishedProjectInputFile(
        descriptor: Int32,
        url: URL,
        relativePath: String?,
        expectedStatus: stat,
        inspectAsPhoto: Bool,
        reboundStatus: () -> stat?
    ) throws -> CanonicalFinishedProjectInputFile {
        let expectedIdentity = FinishedProjectFileIdentity(expectedStatus)
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              FinishedProjectFileIdentity(openedStatus) == expectedIdentity,
              (openedStatus.st_mode & S_IFMT) == S_IFREG,
              openedStatus.st_nlink == 1,
              openedStatus.st_size > 0 else {
            throw finishedProjectError("an expected input changed before authentication")
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw finishedProjectError("an expected input could not be read safely")
            }
            if count == 0 { break }
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow, next <= Int64(expectedStatus.st_size) else {
                throw finishedProjectError("an expected input changed while it was read")
            }
            total = next
            hasher.update(data: Data(buffer[0..<count]))
        }
        let photoEvidence: FinishedProjectPhotoEvidence?
        if inspectAsPhoto {
            guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw finishedProjectError("an expected photo could not be inspected safely")
            }
            photoEvidence = finishedProjectPhotoEvidence(
                descriptor: descriptor,
                declaredFilename: url.lastPathComponent
            )
        } else {
            photoEvidence = nil
        }
        var finalStatus = stat()
        guard total == Int64(expectedStatus.st_size),
              fstat(descriptor, &finalStatus) == 0,
              FinishedProjectFileIdentity(finalStatus) == expectedIdentity,
              reboundStatus().map(FinishedProjectFileIdentity.init) == expectedIdentity else {
            throw finishedProjectError("an expected input changed during authentication")
        }
        return CanonicalFinishedProjectInputFile(
            url: url,
            relativePath: relativePath,
            identity: expectedIdentity,
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            typeIdentifier: photoEvidence?.typeIdentifier,
            pixelWidth: photoEvidence?.pixelWidth,
            pixelHeight: photoEvidence?.pixelHeight,
            orientation: photoEvidence?.orientation,
            isReadablePhoto: photoEvidence?.isReadable ?? false
        )
    }

    private struct FinishedProjectPhotoEvidence {
        let typeIdentifier: String?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let orientation: Int?
        let isReadable: Bool
    }

    private struct FinishedProjectImageSource {
        let source: CGImageSource
        let typeIdentifier: String
    }

    private static func isSupportedFinishedProjectRasterType(
        _ typeIdentifier: String
    ) -> Bool {
        ["public.jpeg", "public.png", "public.heic", "public.heif"]
            .contains(typeIdentifier)
    }

    private static func isSupportedFinishedProjectPhotoType(
        _ typeIdentifier: String
    ) -> Bool {
        isSupportedFinishedProjectRasterType(typeIdentifier)
            || UTType(typeIdentifier)?.conforms(to: .rawImage) == true
    }

    private static func finishedProjectImageSource(
        descriptor: Int32,
        declaredFilename: String
    ) -> FinishedProjectImageSource? {
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        let uncachedOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(
            descriptorURL as CFURL,
            uncachedOptions
        ),
           CGImageSourceGetCount(source) > 0,
           let typeIdentifier = CGImageSourceGetType(source) as String? {
            return FinishedProjectImageSource(
                source: source,
                typeIdentifier: typeIdentifier
            )
        }

        // Content sniffing must win over the suffix so a renamed JPEG or PNG
        // cannot be promoted to RAW. ImageIO needs a RAW hint only for formats
        // it cannot open from a descriptor URL without one.
        let pathExtension = (declaredFilename as NSString).pathExtension
        guard let declaredType = UTType(filenameExtension: pathExtension),
              declaredType.conforms(to: .rawImage) else {
            return nil
        }
        let hintedOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: declaredType.identifier,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(
            descriptorURL as CFURL,
            hintedOptions
        ),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let detectedType = UTType(typeIdentifier),
              detectedType.conforms(to: .rawImage) else {
            return nil
        }
        return FinishedProjectImageSource(
            source: source,
            typeIdentifier: typeIdentifier
        )
    }

    private static func finishedProjectPhotoEvidence(
        descriptor: Int32,
        declaredFilename: String
    ) -> FinishedProjectPhotoEvidence {
        guard let imageSource = finishedProjectImageSource(
            descriptor: descriptor,
            declaredFilename: declaredFilename
        ) else {
            return FinishedProjectPhotoEvidence(
                typeIdentifier: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                orientation: nil,
                isReadable: false
            )
        }
        let source = imageSource.source
        let typeIdentifier = imageSource.typeIdentifier
        let isRaster = isSupportedFinishedProjectRasterType(typeIdentifier)
        let isRaw = !isRaster
            && UTType(typeIdentifier)?.conforms(to: .rawImage) == true
        guard isRaster || isRaw,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0,
              Int64(width.intValue) <= 250_000_000 / Int64(height.intValue),
              (1...8).contains(
                  (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
              ) else {
            return FinishedProjectPhotoEvidence(
                typeIdentifier: typeIdentifier,
                pixelWidth: nil,
                pixelHeight: nil,
                orientation: nil,
                isReadable: false
            )
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if isRaw {
            return FinishedProjectPhotoEvidence(
                typeIdentifier: typeIdentifier,
                pixelWidth: width.intValue,
                pixelHeight: height.intValue,
                orientation: orientation,
                isReadable: true
            )
        }
        guard isRaster,
              CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4_096,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldCache: true,
                ] as CFDictionary
              ) != nil else {
            return FinishedProjectPhotoEvidence(
                typeIdentifier: typeIdentifier,
                pixelWidth: width.intValue,
                pixelHeight: height.intValue,
                orientation: orientation,
                isReadable: false
            )
        }
        return FinishedProjectPhotoEvidence(
            typeIdentifier: typeIdentifier,
            pixelWidth: width.intValue,
            pixelHeight: height.intValue,
            orientation: orientation,
            isReadable: true
        )
    }

    private static func canonicalFinishedProjectPathKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func expectedInputContinuitySnapshot(
        _ input: CanonicalFinishedProjectExpectedInput
    ) -> FinishedProjectExpectedInputContinuitySnapshot {
        var hasher = SHA256()
        updateExpectedInputContinuityHasher(&hasher, string: "EasySplat expected input continuity v1")
        switch input.kind {
        case .videos:
            updateExpectedInputContinuityHasher(&hasher, string: "videos")
        case .photos:
            updateExpectedInputContinuityHasher(&hasher, string: "photos")
        case .mixed:
            updateExpectedInputContinuityHasher(&hasher, string: "mixed")
        }
        updateExpectedInputContinuityHasher(&hasher, integer: input.videoFiles.count)
        for video in input.videoFiles {
            updateExpectedInputContinuityHasher(&hasher, identity: video.identity)
            updateExpectedInputContinuityHasher(&hasher, integer: video.byteCount)
            updateExpectedInputContinuityHasher(&hasher, string: video.sha256)
        }
        if let folder = input.photoFolder {
            updateExpectedInputContinuityHasher(&hasher, string: "photo-root")
            updateExpectedInputContinuityHasher(&hasher, identity: folder.identity)
            updateExpectedInputContinuityHasher(&hasher, integer: folder.discoveredPhotos.count)
            for photo in folder.discoveredPhotos {
                updateExpectedInputContinuityHasher(
                    &hasher,
                    string: photo.relativePath ?? ""
                )
                updateExpectedInputContinuityHasher(&hasher, identity: photo.identity)
                updateExpectedInputContinuityHasher(&hasher, integer: photo.byteCount)
                updateExpectedInputContinuityHasher(&hasher, string: photo.sha256)
                updateExpectedInputContinuityHasher(
                    &hasher,
                    integer: photo.isReadablePhoto ? 1 : 0
                )
            }
            updateExpectedInputContinuityHasher(&hasher, integer: folder.acceptedPhotos.count)
            for photo in folder.acceptedPhotos {
                updateExpectedInputContinuityHasher(
                    &hasher,
                    string: photo.relativePath ?? ""
                )
                updateExpectedInputContinuityHasher(&hasher, identity: photo.identity)
                updateExpectedInputContinuityHasher(&hasher, string: photo.sha256)
            }
            updateExpectedInputContinuityHasher(&hasher, integer: folder.allFileIdentities.count)
            for identity in folder.allFileIdentities {
                updateExpectedInputContinuityHasher(&hasher, identity: identity)
            }
            updateExpectedInputContinuityHasher(&hasher, integer: folder.traversedEntries.count)
            for entry in folder.traversedEntries {
                updateExpectedInputContinuityHasher(&hasher, string: entry.relativePath)
                updateExpectedInputContinuityHasher(&hasher, string: entry.kind.rawValue)
                updateExpectedInputContinuityHasher(&hasher, identity: entry.identity)
            }
        } else {
            updateExpectedInputContinuityHasher(&hasher, string: "no-photo-root")
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FinishedProjectExpectedInputContinuitySnapshot(fingerprint: fingerprint)
    }

    private static func updateExpectedInputContinuityHasher<T: BinaryInteger>(
        _ hasher: inout SHA256,
        integer: T
    ) {
        updateExpectedInputContinuityHasher(&hasher, string: String(integer))
    }

    private static func updateExpectedInputContinuityHasher(
        _ hasher: inout SHA256,
        identity: FinishedProjectFileIdentity
    ) {
        updateExpectedInputContinuityHasher(&hasher, integer: identity.device)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.inode)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.owner)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.group)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.linkCount)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.mode)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.flags)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.size)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.modifiedSeconds)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.modifiedNanoseconds)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.changedSeconds)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.changedNanoseconds)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.createdSeconds)
        updateExpectedInputContinuityHasher(&hasher, integer: identity.createdNanoseconds)
    }

    private static func updateExpectedInputContinuityHasher(
        _ hasher: inout SHA256,
        string: String
    ) {
        let bytes = Data(string.utf8)
        var byteCount = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &byteCount) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
    }

    private static func requireCanonicalExpectedInputUnchanged(
        _ expected: CanonicalFinishedProjectExpectedInput
    ) throws {
        if !expected.videoFiles.isEmpty {
            let currentVideos = try canonicalFinishedProjectVideoFiles(
                expected.videoFiles.map(\.url)
            )
            guard currentVideos == expected.videoFiles else {
                throw finishedProjectError("an expected video input changed during validation")
            }
        }
        if let expectedFolder = expected.photoFolder {
            let currentFolder = try canonicalFinishedProjectPhotoFolder(expectedFolder.url)
            guard currentFolder == expectedFolder else {
                throw finishedProjectError("the expected photo input changed during validation")
            }
        }
    }

    private static func requireExpectedInput(
        _ input: InputSpec,
        canonicalInput: CanonicalFinishedProjectExpectedInput
    ) throws {
        switch (canonicalInput.kind, input) {
        case (.photos, .photos(let folder)):
            guard folder == "Originals/Photos", canonicalInput.photoFolder != nil else {
                throw finishedProjectError(
                    "project.json does not record the controlled photo directory"
                )
            }
            return
        case (.photos, .dataset(_, let folder)):
            // A dataset's images ride the photo machinery: they are admitted into
            // Originals/Photos and bound to a photo folder just as ordinary photos
            // are, so the caller supplies the dataset image folder as the expected
            // photo folder.
            guard folder == "Originals/Photos", canonicalInput.photoFolder != nil else {
                throw finishedProjectError(
                    "project.json does not record the controlled photo directory"
                )
            }
            return
        case (.videos, .video(let files)):
            guard files.count == canonicalInput.videoFiles.count,
                  files.allSatisfy({ !($0 as NSString).isAbsolutePath }) else {
                throw finishedProjectError(
                    "project.json records an external video path"
                )
            }
            return
        case (.mixed, .mixed(let videos, let folder)):
            guard videos.count == canonicalInput.videoFiles.count,
                  videos.allSatisfy({ !($0 as NSString).isAbsolutePath }),
                  folder == "Originals/Photos",
                  canonicalInput.photoFolder != nil else {
                throw finishedProjectError("project.json records a different mixed input")
            }
            return
        default:
            throw finishedProjectError("project.json records a different input kind")
        }
    }

    private struct ImportedInputBinding: Equatable {
        let importedRelativePaths: [String]
        let sourceSHA256: [String]
        let sourceIdentities: [FinishedProjectFileIdentity]
        let photoFolderIdentity: FinishedProjectFileIdentity?
    }

    private struct ExpectedImportedInputMapping {
        let source: CanonicalFinishedProjectInputFile
        let importedRelativePath: String
        let controlledSHA256: String
        let controlledPhotoReceipt: PhotoInputReceipt?
    }

    private static func validateImportedInputBinding(
        input: InputSpec,
        videoInputReceipts: [VideoInputReceipt]?,
        photoInputReceipts: [PhotoInputReceipt]?,
        photoSelectionProjection: PhotoSelectionProjection?,
        plan: ResolvedRunPlan,
        canonicalInput: CanonicalFinishedProjectExpectedInput,
        paths: ProjectPaths
    ) throws -> ImportedInputBinding {
        try requireCanonicalExpectedInputUnchanged(canonicalInput)

        func videoMappings(
            files: [String],
            receipts: [VideoInputReceipt]?
        ) throws -> [ExpectedImportedInputMapping] {
            guard files.count == canonicalInput.videoFiles.count,
                  receipts?.count == files.count,
                  let receipts else {
                throw finishedProjectError("the packaged video input is ambiguous")
            }
            let sources: [CanonicalFinishedProjectInputFile]
            if plan.pairingPolicy.canonicalizesVideoClipOrder {
                var byDigest: [String: CanonicalFinishedProjectInputFile] = [:]
                for source in canonicalInput.videoFiles {
                    guard byDigest.updateValue(source, forKey: source.sha256) == nil else {
                        throw finishedProjectError("the packaged video input is ambiguous")
                    }
                }
                sources = try receipts.map { receipt in
                    guard let source = byDigest[receipt.sha256] else {
                        throw finishedProjectError(
                            "the packaged video input does not match its receipts"
                        )
                    }
                    return source
                }
            } else {
                sources = canonicalInput.videoFiles
            }
            return try zip(
                sources,
                zip(files, receipts)
            ).enumerated().map { index, pair in
                let source = pair.0
                let file = pair.1.0
                let receipt = pair.1.1
                guard receipt.projectRelativePath == file,
                      receipt.projectRelativePath.hasPrefix("Originals/"),
                      source.byteCount == receipt.byteCount,
                      source.sha256 == receipt.sha256 else {
                    throw finishedProjectError(
                        "packaged video input \(index + 1) does not match its receipt"
                    )
                }
                return ExpectedImportedInputMapping(
                    source: source,
                    importedRelativePath: String(
                        receipt.projectRelativePath.dropFirst("Originals/".count)
                    ),
                    controlledSHA256: receipt.sha256,
                    controlledPhotoReceipt: nil
                )
            }
        }

        func photoMappings(
            receipts: [PhotoInputReceipt]?,
            requireNonempty: Bool
        ) throws -> [ExpectedImportedInputMapping] {
            guard let folder = canonicalInput.photoFolder,
                  let receipts,
                  !requireNonempty || !receipts.isEmpty,
                  !requireNonempty || !folder.acceptedPhotos.isEmpty else {
                throw finishedProjectError("the controlled photo receipts are missing")
            }
            if receipts.isEmpty {
                guard photoSelectionProjection == nil else {
                    throw finishedProjectError("the controlled photo projection is ambiguous")
                }
                return []
            }
            guard let photoSelectionProjection,
                  photoSelectionProjection.canonicalReceipts == receipts else {
                throw finishedProjectError(
                    "the controlled photo receipts do not match their selection evidence"
                )
            }
            var sourcesBySHA256: [String: CanonicalFinishedProjectInputFile] = [:]
            for source in folder.acceptedPhotos {
                guard sourcesBySHA256.updateValue(source, forKey: source.sha256) == nil else {
                    throw finishedProjectError("the packaged photo input is ambiguous")
                }
            }
            return try receipts.enumerated().map { index, receipt in
                guard let source = sourcesBySHA256[receipt.source.sha256] else {
                    throw finishedProjectError(
                        "controlled photo receipt \(index + 1) is not present in the packaged input"
                    )
                }
                guard source.byteCount == receipt.source.byteCount,
                      source.sha256 == receipt.source.sha256,
                      source.typeIdentifier == receipt.source.typeIdentifier,
                      source.isReadablePhoto,
                      receipt.projectRelativePath.hasPrefix("Originals/Photos/") else {
                    throw finishedProjectError(
                        "controlled photo receipt \(index + 1) is not derived from the packaged input"
                    )
                }
                switch receipt.importMode {
                case .unchanged:
                    guard receipt.source.byteCount == receipt.byteCount,
                          receipt.source.sha256 == receipt.sha256,
                          receipt.source.typeIdentifier == receipt.typeIdentifier,
                          source.pixelWidth == receipt.pixelWidth,
                          source.pixelHeight == receipt.pixelHeight,
                          source.orientation == receipt.orientation else {
                        throw finishedProjectError(
                            "controlled photo receipt \(index + 1) has invalid unchanged provenance"
                        )
                    }
                case .rawDevelopment(let evidence):
                    guard receipt.typeIdentifier == UTType.png.identifier,
                          receipt.orientation == 1,
                          UTType(receipt.source.typeIdentifier)?.conforms(to: .rawImage) == true,
                          source.pixelWidth == evidence.nativePixelWidth,
                          source.pixelHeight == evidence.nativePixelHeight,
                          source.orientation == evidence.sourceOrientation else {
                        throw finishedProjectError(
                            "controlled photo receipt \(index + 1) has invalid RAW provenance"
                        )
                    }
                }
                return ExpectedImportedInputMapping(
                    source: source,
                    importedRelativePath: String(
                        receipt.projectRelativePath.dropFirst("Originals/".count)
                    ),
                    controlledSHA256: receipt.sha256,
                    controlledPhotoReceipt: receipt
                )
            }
        }

        let mappings: [ExpectedImportedInputMapping]
        switch input {
        case .video(let files):
            mappings = try videoMappings(files: files, receipts: videoInputReceipts)
        case .photos, .dataset:
            mappings = try photoMappings(receipts: photoInputReceipts, requireNonempty: true)
        case .mixed(let files, _):
            mappings = try videoMappings(files: files, receipts: videoInputReceipts)
                + photoMappings(receipts: photoInputReceipts, requireNonempty: false)
        }

        let expectedPaths = mappings.map(\.importedRelativePath).sorted()
        let expectedDirectories = expectedOriginalsDirectories(
            filePaths: expectedPaths,
            includesPhotoRoot: input.hasPhotos
        )
        let actualInventory = try importedOriginalsInventory(paths.originalsURL)
        guard actualInventory.regularFiles == expectedPaths,
              actualInventory.directories == expectedDirectories else {
            throw finishedProjectError(
                "the project Originals do not match the packaged input projection"
            )
        }

        var sourceDigests: [String] = []
        sourceDigests.reserveCapacity(mappings.count)
        for mapping in mappings {
            let destination: URL
            do {
                destination = try paths.resolveProjectRelativePath(
                    "Originals/\(mapping.importedRelativePath)"
                )
            } catch {
                throw finishedProjectError("the imported input path is unsafe")
            }
            let imported: CanonicalFinishedProjectInputFile
            do {
                imported = try stableFinishedProjectInputFile(
                    at: destination,
                    relativePath: nil,
                    inspectAsPhoto: mapping.controlledPhotoReceipt != nil
                )
            } catch {
                throw finishedProjectError("the packaged input or imported copy is unreadable")
            }
            guard mapping.controlledSHA256 == imported.sha256 else {
                throw finishedProjectError(
                    "the project Originals were not copied from the packaged input"
                )
            }
            if let receipt = mapping.controlledPhotoReceipt {
                guard imported.byteCount == receipt.byteCount,
                      imported.typeIdentifier == receipt.typeIdentifier,
                      imported.pixelWidth == receipt.pixelWidth,
                      imported.pixelHeight == receipt.pixelHeight,
                      imported.orientation == receipt.orientation,
                      imported.isReadablePhoto else {
                    throw finishedProjectError(
                        "a controlled photo does not match its authenticated receipt"
                    )
                }
            }
            sourceDigests.append(mapping.source.sha256)
        }
        try requireCanonicalExpectedInputUnchanged(canonicalInput)
        return ImportedInputBinding(
            importedRelativePaths: expectedPaths,
            sourceSHA256: sourceDigests,
            sourceIdentities: mappings.map(\.source.identity),
            photoFolderIdentity: canonicalInput.photoFolder?.identity
        )
    }

    private struct ImportedOriginalsInventory {
        let regularFiles: [String]
        let directories: [String]
    }

    private static func expectedOriginalsDirectories(
        filePaths: [String],
        includesPhotoRoot: Bool
    ) -> [String] {
        var directories = Set<String>()
        if includesPhotoRoot {
            directories.insert("Photos")
        }
        for filePath in filePaths {
            let components = filePath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1 else { continue }
            for endIndex in 1..<components.count {
                directories.insert(
                    components[..<endIndex].joined(separator: "/")
                )
            }
        }
        return directories.sorted()
    }

    private static func importedOriginalsInventory(
        _ root: URL
    ) throws -> ImportedOriginalsInventory {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw finishedProjectError("the project Originals directory is unreadable")
        }
        let prefix = root.standardizedFileURL.path + "/"
        var regularFiles: [String] = []
        var directories: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw finishedProjectError("the project Originals contain a symbolic link")
            }
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(prefix) else {
                throw finishedProjectError("the project Originals contain an unsafe entry")
            }
            let relativePath = String(standardizedPath.dropFirst(prefix.count))
            if values.isDirectory == true {
                directories.append(relativePath)
                continue
            }
            guard values.isRegularFile == true,
                  !relativePath.isEmpty else {
                throw finishedProjectError("the project Originals contain a special entry")
            }
            regularFiles.append(relativePath)
        }
        return ImportedOriginalsInventory(
            regularFiles: regularFiles.sorted(),
            directories: directories.sorted()
        )
    }

    private static func requireGeometryPlanBinding(
        _ geometry: GeometryArtifact,
        plan: ResolvedRunPlan
    ) throws {
        do {
            try GeometryArtifactStore.requireRunPlanBinding(geometry, plan: plan)
        } catch {
            throw finishedProjectError("the geometry artifact does not match the resolved run plan")
        }
    }

    private static func requireCanonicalOrientationBinding(
        geometry: GeometryArtifact,
        measured: ColmapResidualAnalyzer.Result,
        plan: ResolvedRunPlan
    ) throws {
        let orderedInput: Bool
        switch plan.pairingPolicy {
        case .unorderedRetrieval, .segmentedMixed:
            orderedInput = false
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
            orderedInput = true
        }
        let allowCameraUpFallback = plan.pairingPolicy == .orderedContinuous
            || plan.pairingPolicy == .orderedWalkthrough
        let independentlyEstimated = CanonicalOrientationEstimator.estimate(
            cameras: measured.cameraSamples,
            orderedImageNames: geometry.orderedImageNames,
            orderedInput: orderedInput,
            allowCameraUpFallback: allowCameraUpFallback,
            deterministicSeed: plan.runSeed
        ).artifact
        guard independentlyEstimated == geometry.canonicalOrientation else {
            throw finishedProjectError(
                "the canonical orientation does not match the deterministic estimator"
            )
        }
    }

    private static func requireCanonicalCameraBinding(
        geometry: GeometryArtifact,
        measured: ColmapResidualAnalyzer.Result,
        plan: ResolvedRunPlan,
        detailProfile: DetailProfile,
        selectedImages: [URL],
        selectedFrameManifest: [PipelineRunner.SelectedFrameMapping]
    ) throws {
        let expectedModel = ResolvedCameraModelPolicy.model(
            detailProfile: detailProfile,
            capturePath: plan.capturePath,
            lensProjection: plan.lensProjection
        )
        let registeredCameraIDs = Set(measured.cameraIDsByImageName.values)
        guard geometry.cameraModel == expectedModel,
              measured.cameraModel == expectedModel,
              !registeredCameraIDs.isEmpty,
              measured.cameraIDsByImageName.count == measured.registeredViewCount,
              Set(measured.cameraModelsByID.values) == [expectedModel],
              registeredCameraIDs == Set(measured.cameraModelsByID.keys) else {
            throw finishedProjectError(
                "the canonical camera model does not match the resolved run plan"
            )
        }
        let registeredImageNames = Set(measured.cameraIDsByImageName.keys)
        let registeredImages = selectedImages.filter {
            registeredImageNames.contains($0.lastPathComponent)
        }
        guard registeredImages.count == registeredImageNames.count else {
            throw finishedProjectError(
                "the canonical camera grouping does not match the selected frames"
            )
        }
        guard plan.cameraGrouping != .automatic,
              let receipt = geometry.cameraGroupingReceipt else {
            throw finishedProjectError(
                "the canonical camera grouping does not match the resolved run plan"
            )
        }
        let manifestByName = Dictionary(
            uniqueKeysWithValues: selectedFrameManifest.map {
                ($0.outputFileName, $0)
            }
        )
        let registeredManifest = registeredImageNames.compactMap { manifestByName[$0] }
        guard registeredManifest.count == registeredImageNames.count else {
            throw finishedProjectError(
                "the canonical camera grouping does not match the selected frames"
            )
        }

        switch receipt.mode {
        case .allSelectedImagesShared:
            guard plan.cameraGrouping == .sameCameraAndLens,
                  try SelectedImageCameraGroupingPolicy.hasUniformPixelDimensions(
                      selectedImages
                  ),
                  registeredCameraIDs.count == 1,
                  registeredCameraIDs.first.map(Int64.init)
                    == receipt.groups.first?.canonicalCameraID else {
                throw finishedProjectError(
                    "the canonical camera grouping does not match the resolved run plan"
                )
            }
        case .preserveExisting:
            guard plan.cameraGrouping == .mixedCamerasOrLenses,
                  registeredManifest.allSatisfy({ !$0.isVideo }),
                  try SelectedImageCameraGroupingPolicy.cameraIDsMatchExpectedGroups(
                      images: registeredImages,
                      mode: .colmapAutomatic,
                      cameraIDsByImageName: measured.cameraIDsByImageName
                  ) else {
                throw finishedProjectError(
                    "the canonical camera grouping does not match the resolved run plan"
                )
            }
        case .videoSourceGroups:
            guard plan.cameraGrouping == .mixedCamerasOrLenses else {
                throw finishedProjectError(
                    "the canonical camera grouping does not match the resolved run plan"
                )
            }
            let receiptsByGroup = Dictionary(
                uniqueKeysWithValues: receipt.groups.map { ($0.sourceGroupID, $0) }
            )
            let registeredVideoFrames = registeredManifest.filter(\.isVideo)
            let videoFramesByGroup = Dictionary(
                grouping: registeredVideoFrames,
                by: \.groupId
            )
            var videoCameraIDs = Set<Int>()
            for (groupID, frames) in videoFramesByGroup {
                guard let groupReceipt = receiptsByGroup[groupID],
                      let canonicalCameraID = Int(exactly: groupReceipt.canonicalCameraID) else {
                    throw finishedProjectError(
                        "the canonical camera grouping does not match the selected frames"
                    )
                }
                let cameraIDs = Set(frames.compactMap {
                    measured.cameraIDsByImageName[$0.outputFileName]
                })
                guard cameraIDs == [canonicalCameraID],
                      videoCameraIDs.insert(canonicalCameraID).inserted else {
                    throw finishedProjectError(
                        "the canonical camera grouping does not match the resolved run plan"
                    )
                }
            }
            let registeredPhotoNames = Set(
                registeredManifest.lazy.filter({ !$0.isVideo }).map(\.outputFileName)
            )
            if !registeredPhotoNames.isEmpty {
                let photoImages = registeredImages.filter {
                    registeredPhotoNames.contains($0.lastPathComponent)
                }
                let photoCameraIDs = measured.cameraIDsByImageName.filter {
                    registeredPhotoNames.contains($0.key)
                }
                guard Set(photoCameraIDs.values).isDisjoint(with: videoCameraIDs),
                      try SelectedImageCameraGroupingPolicy.cameraIDsMatchExpectedGroups(
                          images: photoImages,
                          mode: .colmapAutomatic,
                          cameraIDsByImageName: photoCameraIDs
                      ) else {
                    throw finishedProjectError(
                        "the canonical camera grouping does not match the resolved run plan"
                    )
                }
            }
        }
    }

    private static func safeFinishedProjectFileIdentity(
        at url: URL
    ) throws -> FinishedProjectFileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size > 0 else {
            throw finishedProjectError(
                "\(url.lastPathComponent) is not a safe owner-writable single-link file"
            )
        }
        let permissions = status.st_mode & 0o7777
        guard (permissions & 0o600) == mode_t(S_IRUSR | S_IWUSR),
              (permissions & 0o111) == 0,
              (permissions & 0o022) == 0,
              (permissions & 0o7000) == 0 else {
            throw finishedProjectError(
                "\(url.lastPathComponent) has unsafe write, execute, or ownership permissions"
            )
        }
        return FinishedProjectFileIdentity(status)
    }

    private static func protectedAncestorDirectories(
        projectRoot: URL,
        files: [URL]
    ) -> [URL] {
        let root = projectRoot.standardizedFileURL
        let rootPrefix = root.path + "/"
        var directoriesByPath = [root.path: root]
        for file in files {
            var directory = file.deletingLastPathComponent().standardizedFileURL
            while directory.path == root.path || directory.path.hasPrefix(rootPrefix) {
                directoriesByPath[directory.path] = directory
                guard directory.path != root.path else { break }
                directory = directory.deletingLastPathComponent().standardizedFileURL
            }
        }
        return directoriesByPath.values.sorted {
            let leftDepth = $0.pathComponents.count
            let rightDepth = $1.pathComponents.count
            return leftDepth == rightDepth ? $0.path < $1.path : leftDepth < rightDepth
        }
    }

    private static func safeFinishedProjectProtectedFileIdentity(
        at url: URL
    ) throws -> FinishedProjectProtectedFileIdentity {
        let initialPathIdentity = try safeFinishedProjectFileIdentity(at: url)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw finishedProjectError("\(url.lastPathComponent) changed during validation")
        }
        defer { Darwin.close(descriptor) }

        var initialDescriptorStatus = stat()
        guard fstat(descriptor, &initialDescriptorStatus) == 0 else {
            throw finishedProjectError("\(url.lastPathComponent) changed during validation")
        }
        let initialDescriptorIdentity = FinishedProjectFileIdentity(
            initialDescriptorStatus
        )
        guard sameStableFinishedProjectFileMetadata(
            initialPathIdentity,
            initialDescriptorIdentity
        ) else {
            throw finishedProjectError("\(url.lastPathComponent) changed during validation")
        }

        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < initialDescriptorStatus.st_size {
            let requested = min(
                buffer.count,
                Int(initialDescriptorStatus.st_size - offset)
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, requested, offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, count <= requested else {
                throw finishedProjectError("\(url.lastPathComponent) changed during validation")
            }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
        }

        var finalDescriptorStatus = stat()
        guard fstat(descriptor, &finalDescriptorStatus) == 0,
              offset == initialDescriptorStatus.st_size else {
            throw finishedProjectError("\(url.lastPathComponent) changed during validation")
        }
        let finalDescriptorIdentity = FinishedProjectFileIdentity(
            finalDescriptorStatus
        )
        let finalPathIdentity = try safeFinishedProjectFileIdentity(at: url)
        guard sameStableFinishedProjectFileMetadata(
            initialDescriptorIdentity,
            finalDescriptorIdentity
        ), sameStableFinishedProjectFileMetadata(
            finalDescriptorIdentity,
            finalPathIdentity
        ) else {
            throw finishedProjectError("\(url.lastPathComponent) changed during validation")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FinishedProjectProtectedFileIdentity(
            identity: finalDescriptorIdentity,
            sha256: digest
        )
    }

    private static func sameStableFinishedProjectFileMetadata(
        _ lhs: FinishedProjectFileIdentity,
        _ rhs: FinishedProjectFileIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.owner == rhs.owner
            && lhs.group == rhs.group
            && lhs.linkCount == rhs.linkCount
            && lhs.mode == rhs.mode
            && lhs.flags == rhs.flags
            && lhs.size == rhs.size
            && lhs.modifiedSeconds == rhs.modifiedSeconds
            && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
            && lhs.createdSeconds == rhs.createdSeconds
            && lhs.createdNanoseconds == rhs.createdNanoseconds
    }

    private static func finishedProjectError(
        _ reason: String
    ) -> FinishedProjectArtifactValidationError {
        .invalidProject(reason)
    }

    /// Rebuilds the dataset import context a finished dataset project resolved
    /// its plan against, mirroring the pipeline's resume path: the route and
    /// image count come from the persisted pose seed, and the pixel ceiling is
    /// the largest dimension across the photo receipts (dataset images are
    /// adopted unscaled, so the receipts reproduce preflight's measured
    /// ceiling). Non-dataset projects have no import context.
    private static func datasetImportContext(
        for metadata: ProjectMetadata
    ) -> RunPlanResolver.DatasetImportContext? {
        guard metadata.input.isDataset, let seed = metadata.datasetPoseSeed else {
            return nil
        }
        return RunPlanResolver.DatasetImportContext(
            route: seed.route,
            imageCount: seed.imageCount,
            maximumImagePixelDimension: metadata.photoInputReceipts?
                .map { max($0.pixelWidth, $0.pixelHeight) }
                .max()
        )
    }

    /// Copies a validated PLY through descriptor-stable reads and publishes it
    /// atomically. The returned size and digest describe the exact bytes made
    /// visible at `destination`.
    public static func publishValidatedPly(
        from source: URL,
        to destination: URL
    ) throws -> ValidatedPlyArtifactEvidence {
        try publishValidatedPly(
            from: source,
            to: destination,
            expected: nil,
            systemCalls: .system(),
            shouldCancel: { Task.isCancelled }
        )
    }

    public static func publishValidatedPly(
        from source: URL,
        to destination: URL,
        expected: ExpectedPlyArtifactIdentity
    ) throws -> ValidatedPlyArtifactEvidence {
        try publishValidatedPly(
            from: source,
            to: destination,
            expected: Optional(expected),
            systemCalls: .system(),
            shouldCancel: { Task.isCancelled }
        )
    }

    static func publishValidatedPly(
        from source: URL,
        to destination: URL,
        expected: ExpectedPlyArtifactIdentity?,
        systemCalls: PlyPublicationSystemCalls,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ValidatedPlyArtifactEvidence {
        try throwIfCancellationRequested(shouldCancel)
        let sourceDescriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw ProjectArtifactError.invalidOutput(source.lastPathComponent)
        }
        defer { Darwin.close(sourceDescriptor) }

        let sourceEvidence = try validatedPlyEvidence(
            descriptor: sourceDescriptor,
            label: source.lastPathComponent,
            readAt: systemCalls.readAt,
            shouldCancel: shouldCancel
        )
        if let expected {
            guard sourceEvidence.byteCount == expected.byteCount,
                  sourceEvidence.vertexCount == expected.vertexCount,
                  sourceEvidence.sha256 == expected.sha256.lowercased() else {
                throw ProjectArtifactError.invalidOutput(source.lastPathComponent)
            }
        }
        let destinationDirectory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let directoryDescriptor = Darwin.open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw ProjectArtifactError.invalidOutput(destination.lastPathComponent)
        }
        defer { Darwin.close(directoryDescriptor) }
        var directoryIdentity = stat()
        guard fstat(directoryDescriptor, &directoryIdentity) == 0,
              (directoryIdentity.st_mode & S_IFMT) == S_IFDIR else {
            throw ProjectArtifactError.invalidOutput(destination.lastPathComponent)
        }

        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/") else {
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        var existingDestination = stat()
        let existingResult = systemCalls.status(
            directoryDescriptor,
            destinationName,
            &existingDestination
        )
        var backupName: String?
        var backupIdentity: stat?
        if existingResult == 0 {
            guard (existingDestination.st_mode & S_IFMT) == S_IFREG,
                  existingDestination.st_nlink == 1 else {
                throw ProjectArtifactError.invalidOutput(destinationName)
            }
            backupName = ".\(destinationName).previous.\(UUID().uuidString).tmp"
            backupIdentity = existingDestination
        } else if errno != ENOENT {
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        var removeTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if removeTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while offset < Int64(sourceEvidence.byteCount) {
            try throwIfCancellationRequested(shouldCancel)
            let requested = min(buffer.count, Int(sourceEvidence.byteCount - UInt64(offset)))
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemCalls.readAt(
                    sourceDescriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, count <= requested else {
                throw ProjectArtifactError.invalidOutput(source.lastPathComponent)
            }
            var written = 0
            while written < count {
                try throwIfCancellationRequested(shouldCancel)
                let result = buffer.withUnsafeBytes { bytes in
                    systemCalls.write(
                        temporaryDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 && errno == EINTR { continue }
                guard result > 0, result <= count - written else {
                    throw ProjectArtifactError.invalidOutput(destinationName)
                }
                written += result
            }
            offset += Int64(count)
        }
        try throwIfCancellationRequested(shouldCancel)
        guard fchmod(temporaryDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        try synchronize(
            temporaryDescriptor,
            label: destinationName,
            systemCalls: systemCalls
        )

        let destinationEvidence = try validatedPlyEvidence(
            descriptor: temporaryDescriptor,
            label: destinationName,
            readAt: systemCalls.readAt,
            shouldCancel: shouldCancel
        )
        guard destinationEvidence == sourceEvidence else {
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        let finalSourceEvidence = try validatedPlyEvidence(
            descriptor: sourceDescriptor,
            label: source.lastPathComponent,
            readAt: systemCalls.readAt,
            shouldCancel: shouldCancel
        )
        guard finalSourceEvidence == sourceEvidence else {
            throw ProjectArtifactError.invalidOutput(source.lastPathComponent)
        }
        var sourceDescriptorIdentity = stat()
        var sourcePathIdentity = stat()
        guard fstat(sourceDescriptor, &sourceDescriptorIdentity) == 0,
              lstat(source.path, &sourcePathIdentity) == 0,
              sourcePathIdentity.st_dev == sourceDescriptorIdentity.st_dev,
              sourcePathIdentity.st_ino == sourceDescriptorIdentity.st_ino,
              sourcePathIdentity.st_nlink == sourceDescriptorIdentity.st_nlink,
              sourcePathIdentity.st_mode == sourceDescriptorIdentity.st_mode,
              sourcePathIdentity.st_size == sourceDescriptorIdentity.st_size else {
            throw ProjectArtifactError.invalidOutput(source.lastPathComponent)
        }
        var temporaryIdentity = stat()
        guard fstat(temporaryDescriptor, &temporaryIdentity) == 0 else {
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        var existingWasMovedAside = false
        var temporaryWasPublished = false
        var committedPublishedIdentity: stat?
        var publicationCommitted = false
        do {
            try throwIfCancellationRequested(shouldCancel)
            if let backupName {
                let moveExistingResult = systemCalls.renameExclusively(
                    directoryDescriptor,
                    destinationName,
                    backupName
                )
                guard moveExistingResult == 0 else {
                    if errno == ENOENT {
                        throw ProjectArtifactError.publicationConflict(destinationName)
                    }
                    throw ProjectArtifactError.invalidOutput(destinationName)
                }
                existingWasMovedAside = true
                var movedExisting = stat()
                guard systemCalls.status(directoryDescriptor, backupName, &movedExisting) == 0 else {
                    throw ProjectArtifactError.invalidOutput(destinationName)
                }
                backupIdentity = movedExisting
                guard samePublishedFileIgnoringChangeTime(existingDestination, movedExisting) else {
                    throw ProjectArtifactError.publicationConflict(destinationName)
                }
            }
            let publishResult = systemCalls.renameExclusively(
                directoryDescriptor,
                temporaryName,
                destinationName
            )
            guard publishResult == 0 else {
                if errno == EEXIST {
                    throw ProjectArtifactError.publicationConflict(destinationName)
                }
                throw ProjectArtifactError.invalidOutput(destinationName)
            }
            temporaryWasPublished = true
            removeTemporary = false
            var publishedIdentity = stat()
            guard fstat(temporaryDescriptor, &publishedIdentity) == 0,
                  samePublishedFileIgnoringChangeTime(temporaryIdentity, publishedIdentity) else {
                throw ProjectArtifactError.invalidOutput(destinationName)
            }
            committedPublishedIdentity = publishedIdentity
            try requirePublishedFileIdentity(
                named: destinationName,
                descriptor: temporaryDescriptor,
                directory: directoryDescriptor,
                directoryURL: destinationDirectory,
                expectedFile: publishedIdentity,
                expectedDirectory: directoryIdentity,
                expectedBytes: sourceEvidence.byteCount,
                systemCalls: systemCalls
            )
            try synchronize(
                directoryDescriptor,
                label: destinationName,
                systemCalls: systemCalls
            )
            try requirePublishedFileIdentity(
                named: destinationName,
                descriptor: temporaryDescriptor,
                directory: directoryDescriptor,
                directoryURL: destinationDirectory,
                expectedFile: publishedIdentity,
                expectedDirectory: directoryIdentity,
                expectedBytes: sourceEvidence.byteCount,
                systemCalls: systemCalls
            )
            let publishedEvidence = try validatedPlyEvidence(
                descriptor: temporaryDescriptor,
                label: destinationName,
                readAt: systemCalls.readAt,
                shouldCancel: shouldCancel
            )
            guard publishedEvidence == destinationEvidence else {
                throw ProjectArtifactError.invalidOutput(destinationName)
            }
            try requirePublishedFileIdentity(
                named: destinationName,
                descriptor: temporaryDescriptor,
                directory: directoryDescriptor,
                directoryURL: destinationDirectory,
                expectedFile: publishedIdentity,
                expectedDirectory: directoryIdentity,
                expectedBytes: publishedEvidence.byteCount,
                systemCalls: systemCalls
            )
            try throwIfCancellationRequested(shouldCancel)
            publicationCommitted = true
            if let backupName {
                guard let backupIdentity else {
                    throw ProjectArtifactError.invalidOutput(destinationName)
                }
                try cleanupCommittedBackup(
                    named: backupName,
                    destinationName: destinationName,
                    expectedIdentity: backupIdentity,
                    directory: directoryDescriptor,
                    systemCalls: systemCalls
                )
            }
            return publishedEvidence
        } catch {
            if publicationCommitted {
                throw error
            }
            var recoveredPreviousName: String?
            var restoredForeignDestination = false
            var recoveredForeignName: String?
            var rollbackError: Error?
            var recoveryError: Error?
            var backupConflict = false
            var backupIsAvailable = true
            var observedBackup: stat?
            if let backupName, existingWasMovedAside {
                var stillBackup = stat()
                let backupStatus = systemCalls.status(
                    directoryDescriptor,
                    backupName,
                    &stillBackup
                )
                if backupStatus == 0 {
                    observedBackup = stillBackup
                    if let backupIdentity,
                       !samePublishedFileIgnoringChangeTime(backupIdentity, stillBackup) {
                        backupConflict = true
                    }
                } else if errno == ENOENT {
                    backupIsAvailable = false
                    backupConflict = true
                } else {
                    // Do not remove the published destination without first
                    // proving that the prior destination can be recovered.
                    backupConflict = true
                }
            }

            let canRollbackPublishedDestination = !existingWasMovedAside
                || observedBackup != nil
            if temporaryWasPublished, canRollbackPublishedDestination {
                do {
                    let rollback = try rollbackPublishedFile(
                        named: destinationName,
                        expectedIdentity: committedPublishedIdentity ?? temporaryIdentity,
                        directory: directoryDescriptor,
                        systemCalls: systemCalls
                    )
                    restoredForeignDestination = rollback.restoredForeignDestination
                    recoveredForeignName = rollback.recoveredForeignName
                } catch {
                    rollbackError = error
                }
            }

            if let backupName, existingWasMovedAside, backupIsAvailable {
                let restoreResult = systemCalls.renameExclusively(
                    directoryDescriptor,
                    backupName,
                    destinationName
                )
                if restoreResult != 0 {
                    if errno == EEXIST {
                        do {
                            recoveredPreviousName = try preservePreviousPublication(
                                named: backupName,
                                destinationName: destinationName,
                                directory: directoryDescriptor,
                                systemCalls: systemCalls
                            )
                        } catch {
                            recoveryError = error
                        }
                    } else if errno == ENOENT {
                        backupConflict = true
                    } else {
                        do {
                            recoveredPreviousName = try preservePreviousPublication(
                                named: backupName,
                                destinationName: destinationName,
                                directory: directoryDescriptor,
                                systemCalls: systemCalls
                            )
                            backupConflict = true
                        } catch {
                            recoveryError = error
                        }
                    }
                }
                synchronizeBestEffort(directoryDescriptor, systemCalls: systemCalls)
            }

            if let recoveredForeignName {
                let recoveredNames = [recoveredForeignName, recoveredPreviousName]
                    .compactMap { $0 }
                throw ProjectArtifactError.publicationConflictPreservingFiles(
                    destinationName,
                    recoveredNames
                )
            }
            if let recoveredPreviousName {
                throw ProjectArtifactError.publicationConflictPreservingPrevious(
                    destinationName,
                    recoveredPreviousName
                )
            }
            if restoredForeignDestination || backupConflict {
                throw ProjectArtifactError.publicationConflict(destinationName)
            }
            if let recoveryError {
                throw recoveryError
            }
            if let rollbackError {
                throw rollbackError
            }
            throw error
        }
    }

    private static func synchronize(
        _ descriptor: Int32,
        label: String,
        systemCalls: PlyPublicationSystemCalls
    ) throws {
        while systemCalls.synchronize(descriptor) != 0 {
            if errno == EINTR { continue }
            throw ProjectArtifactError.invalidOutput(label)
        }
    }

    private static func throwIfCancellationRequested(
        _ shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    private static func samePublishedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func samePublishedFileIgnoringChangeTime(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func requirePublishedFileIdentity(
        named name: String,
        descriptor: Int32,
        directory: Int32,
        directoryURL: URL,
        expectedFile: stat,
        expectedDirectory: stat,
        expectedBytes: UInt64,
        systemCalls: PlyPublicationSystemCalls
    ) throws {
        var descriptorBefore = stat()
        var publishedBefore = stat()
        var publishedAfter = stat()
        var descriptorAfter = stat()
        var directoryPath = stat()
        guard fstat(descriptor, &descriptorBefore) == 0,
              systemCalls.status(directory, name, &publishedBefore) == 0,
              systemCalls.status(directory, name, &publishedAfter) == 0,
              fstat(descriptor, &descriptorAfter) == 0,
              samePublishedFile(expectedFile, descriptorBefore),
              samePublishedFile(expectedFile, publishedBefore),
              samePublishedFile(expectedFile, publishedAfter),
              samePublishedFile(expectedFile, descriptorAfter),
              (publishedAfter.st_mode & S_IFMT) == S_IFREG,
              (publishedAfter.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              publishedAfter.st_nlink == 1,
              publishedAfter.st_size >= 0,
              UInt64(publishedAfter.st_size) == expectedBytes,
              lstat(directoryURL.path, &directoryPath) == 0,
              directoryPath.st_dev == expectedDirectory.st_dev,
              directoryPath.st_ino == expectedDirectory.st_ino,
              (directoryPath.st_mode & S_IFMT) == S_IFDIR else {
            throw ProjectArtifactError.invalidOutput(name)
        }
    }

    /// The new destination has already been validated and directory-synced when
    /// this runs. Cleanup must therefore never roll it back. The prior path is
    /// first moved to a unique quarantine, then authenticated there; anything
    /// unexpected is moved to a visible recovery name instead of being deleted.
    private static func cleanupCommittedBackup(
        named backupName: String,
        destinationName: String,
        expectedIdentity: stat,
        directory: Int32,
        systemCalls: PlyPublicationSystemCalls
    ) throws {
        var beforeCleanup = stat()
        let beforeResult = systemCalls.status(directory, backupName, &beforeCleanup)
        guard beforeResult == 0 else {
            if errno == ENOENT {
                throw ProjectArtifactError.publicationConflict(destinationName)
            }
            if let recovered = try? preservePreviousPublication(
                named: backupName,
                destinationName: destinationName,
                directory: directory,
                systemCalls: systemCalls
            ) {
                synchronizeBestEffort(directory, systemCalls: systemCalls)
                throw ProjectArtifactError.publicationConflictPreservingFiles(
                    destinationName,
                    [recovered]
                )
            }
            throw ProjectArtifactError.invalidOutput(destinationName)
        }

        let cleanupName = ".\(destinationName).cleanup.\(UUID().uuidString).tmp"
        let moveResult = systemCalls.renameExclusively(
            directory,
            backupName,
            cleanupName
        )
        guard moveResult == 0 else {
            if errno == ENOENT {
                throw ProjectArtifactError.publicationConflict(destinationName)
            }
            if let recovered = try? preservePreviousPublication(
                named: backupName,
                destinationName: destinationName,
                directory: directory,
                systemCalls: systemCalls
            ) {
                synchronizeBestEffort(directory, systemCalls: systemCalls)
                throw ProjectArtifactError.publicationConflictPreservingFiles(
                    destinationName,
                    [recovered]
                )
            }
            throw ProjectArtifactError.invalidOutput(destinationName)
        }

        var quarantined = stat()
        let quarantineResult = systemCalls.status(directory, cleanupName, &quarantined)
        guard quarantineResult == 0,
              samePublishedFileIgnoringChangeTime(beforeCleanup, quarantined),
              samePublishedFileIgnoringChangeTime(expectedIdentity, quarantined) else {
            let recovered = try preservePreviousPublication(
                named: cleanupName,
                destinationName: destinationName,
                directory: directory,
                systemCalls: systemCalls
            )
            synchronizeBestEffort(directory, systemCalls: systemCalls)
            throw ProjectArtifactError.publicationConflictPreservingFiles(
                destinationName,
                [recovered]
            )
        }

        guard systemCalls.remove(directory, cleanupName) == 0 else {
            if errno == ENOENT {
                throw ProjectArtifactError.publicationConflict(destinationName)
            }
            if let recovered = try? preservePreviousPublication(
                named: cleanupName,
                destinationName: destinationName,
                directory: directory,
                systemCalls: systemCalls
            ) {
                synchronizeBestEffort(directory, systemCalls: systemCalls)
                throw ProjectArtifactError.publicationConflictPreservingFiles(
                    destinationName,
                    [recovered]
                )
            }
            throw ProjectArtifactError.invalidOutput(destinationName)
        }

        // The publication rename was already made durable before cleanup. A
        // cleanup fsync failure can only leave the old hidden name resurrectable
        // after a crash; it cannot make the committed destination invalid.
        synchronizeBestEffort(directory, systemCalls: systemCalls)
    }

    private static func synchronizeBestEffort(
        _ descriptor: Int32,
        systemCalls: PlyPublicationSystemCalls
    ) {
        while systemCalls.synchronize(descriptor) != 0 {
            if errno != EINTR { return }
        }
    }

    private static func rollbackPublishedFile(
        named destinationName: String,
        expectedIdentity: stat,
        directory: Int32,
        systemCalls: PlyPublicationSystemCalls
    ) throws -> (
        restoredForeignDestination: Bool,
        recoveredForeignName: String?
    ) {
        var beforeRollback = stat()
        let statusResult = systemCalls.status(
            directory,
            destinationName,
            &beforeRollback
        )
        if statusResult != 0 {
            if errno == ENOENT {
                try synchronize(directory, label: destinationName, systemCalls: systemCalls)
                return (false, nil)
            }
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        guard samePublishedFile(expectedIdentity, beforeRollback) else {
            return (true, nil)
        }

        let quarantineName = ".\(destinationName).rollback.\(UUID().uuidString).tmp"
        guard systemCalls.renameExclusively(
            directory,
            destinationName,
            quarantineName
        ) == 0 else {
            if errno == ENOENT {
                try synchronize(directory, label: destinationName, systemCalls: systemCalls)
                return (false, nil)
            }
            throw ProjectArtifactError.invalidOutput(destinationName)
        }

        var quarantined = stat()
        guard systemCalls.status(directory, quarantineName, &quarantined) == 0 else {
            let restoreResult = systemCalls.renameExclusively(
                directory,
                quarantineName,
                destinationName
            )
            if restoreResult == 0 {
                synchronizeBestEffort(directory, systemCalls: systemCalls)
                return (true, nil)
            }
            if errno == EEXIST,
               let recovered = try? preservePreviousPublication(
                named: quarantineName,
                destinationName: destinationName,
                directory: directory,
                systemCalls: systemCalls
               ) {
                synchronizeBestEffort(directory, systemCalls: systemCalls)
                return (true, recovered)
            }
            throw ProjectArtifactError.invalidOutput(destinationName)
        }
        let isPublishedFile = samePublishedFileIgnoringChangeTime(
            quarantined,
            expectedIdentity
        )
        var recoveredForeignName: String?
        if isPublishedFile {
            if systemCalls.remove(directory, quarantineName) != 0 {
                if errno == ENOENT {
                    synchronizeBestEffort(directory, systemCalls: systemCalls)
                    return (true, nil)
                }
                if let recovered = try? preservePreviousPublication(
                    named: quarantineName,
                    destinationName: destinationName,
                    directory: directory,
                    systemCalls: systemCalls
                ) {
                    synchronizeBestEffort(directory, systemCalls: systemCalls)
                    return (true, recovered)
                }
                throw ProjectArtifactError.invalidOutput(destinationName)
            }
        } else {
            let restoreResult = systemCalls.renameExclusively(
                directory,
                quarantineName,
                destinationName
            )
            if restoreResult != 0 {
                guard errno == EEXIST else {
                    throw ProjectArtifactError.invalidOutput(destinationName)
                }
                recoveredForeignName = try preservePreviousPublication(
                    named: quarantineName,
                    destinationName: destinationName,
                    directory: directory,
                    systemCalls: systemCalls
                )
            }
        }
        synchronizeBestEffort(directory, systemCalls: systemCalls)
        return (!isPublishedFile, recoveredForeignName)
    }

    private static func preservePreviousPublication(
        named backupName: String,
        destinationName: String,
        directory: Int32,
        systemCalls: PlyPublicationSystemCalls
    ) throws -> String {
        let destination = destinationName as NSString
        let pathExtension = destination.pathExtension
        let stem = destination.deletingPathExtension
        for _ in 0..<8 {
            let identifier = UUID().uuidString
            let recoveredName: String
            if pathExtension.isEmpty {
                recoveredName = "\(destinationName).easysplat-recovered-\(identifier)"
            } else {
                recoveredName = "\(stem).easysplat-recovered-\(identifier).\(pathExtension)"
            }
            let result = systemCalls.renameExclusively(
                directory,
                backupName,
                recoveredName
            )
            if result == 0 {
                return recoveredName
            }
            if errno != EEXIST {
                throw ProjectArtifactError.invalidOutput(destinationName)
            }
        }
        throw ProjectArtifactError.invalidOutput(destinationName)
    }

    private static func validatedPlyEvidence(
        descriptor: Int32,
        label: String,
        beforeBoundsMeasurement: () throws -> Void = {},
        readAt: (Int32, UnsafeMutableRawPointer?, Int, off_t) -> Int = {
            Darwin.pread($0, $1, $2, $3)
        },
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ValidatedPlyArtifactEvidence {
        try throwIfCancellationRequested(shouldCancel)
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size > 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ProjectArtifactError.invalidOutput(label)
        }
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        guard try validatePlyFile(
            at: descriptorURL,
            depth: .full,
            shouldCancel: shouldCancel
        ) == .valid else {
            throw ProjectArtifactError.invalidOutput(label)
        }
        guard lseek(descriptor, 0, SEEK_SET) == 0,
              let header = readPlyHeader(at: descriptorURL) else {
            throw ProjectArtifactError.invalidOutput(label)
        }

        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while offset < Int64(initial.st_size) {
            try throwIfCancellationRequested(shouldCancel)
            let requested = min(buffer.count, Int(Int64(initial.st_size) - offset))
            let count = buffer.withUnsafeMutableBytes { bytes in
                readAt(descriptor, bytes.baseAddress, requested, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, count <= requested else {
                throw ProjectArtifactError.invalidOutput(label)
            }
            hasher.update(data: Data(buffer[0..<count]))
            offset += Int64(count)
        }

        try throwIfCancellationRequested(shouldCancel)
        try beforeBoundsMeasurement()
        guard lseek(descriptor, 0, SEEK_SET) == 0,
              let sceneBounds = try SplatSceneBoundsCalculator.compute(
                at: descriptorURL,
                shouldCancel: shouldCancel
              ) else {
            throw ProjectArtifactError.invalidOutput(label)
        }
        try throwIfCancellationRequested(shouldCancel)

        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_nlink == initial.st_nlink,
              final.st_mode == initial.st_mode,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              offset == Int64(initial.st_size) else {
            throw ProjectArtifactError.invalidOutput(label)
        }
        return ValidatedPlyArtifactEvidence(
            byteCount: UInt64(initial.st_size),
            vertexCount: header.vertexCount,
            format: header.format,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            sceneBounds: sceneBounds
        )
    }

    public static func validatePlyFile(
        at url: URL,
        depth: ProjectArtifactValidationDepth = .full
    ) -> ProjectArtifactStatus {
        do {
            return try validatePlyFile(
                at: url,
                depth: depth,
                shouldCancel: { false }
            )
        } catch {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
    }

    private static func validatePlyFile(
        at url: URL,
        depth: ProjectArtifactValidationDepth,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ProjectArtifactStatus {
        try throwIfCancellationRequested(shouldCancel)
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue {
            return .corrupt(reason: "\(url.lastPathComponent) is a directory")
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            return .corrupt(reason: "\(url.lastPathComponent) is empty")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxHeaderBytes)) ?? Data()
        try throwIfCancellationRequested(shouldCancel)
        guard !data.isEmpty else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        guard let headerBounds = plyHeaderBounds(in: data) else {
            guard let prefix = String(data: data.prefix(4096), encoding: .utf8),
                  prefix.lowercased().hasPrefix("ply") else {
                return .corrupt(reason: "\(url.lastPathComponent) is not a PLY file")
            }
            return .corrupt(reason: "\(url.lastPathComponent) is missing end_header")
        }
        let bodyStart = headerBounds.bodyStart
        let headerData = data.prefix(headerBounds.headerEnd)
        guard let header = String(data: headerData, encoding: .utf8) else {
            return .corrupt(reason: "\(url.lastPathComponent) is not valid UTF-8 near header")
        }
        guard header.lowercased().hasPrefix("ply") else {
            return .corrupt(reason: "\(url.lastPathComponent) is not a PLY file")
        }
        let lines = header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        guard let vertexLine = lines.first(where: { $0.lowercased().hasPrefix("element vertex ") }) else {
            return .corrupt(reason: "\(url.lastPathComponent) is missing vertex element metadata")
        }
        let comps = vertexLine.split(separator: " ")
        guard let raw = comps.last, let vertexCount = Int(raw), vertexCount > 0 else {
            return .corrupt(reason: "\(url.lastPathComponent) has invalid vertex count")
        }
        guard let format = lines.first(where: { $0.lowercased().hasPrefix("format ") })?.split(separator: " ").dropFirst().first?.lowercased() else {
            return .corrupt(reason: "\(url.lastPathComponent) is missing PLY format")
        }
        var vertexProperties: [(name: String, type: String)] = []
        var isReadingVertexProperties = false
        for line in lines {
            try throwIfCancellationRequested(shouldCancel)
            let parts = line.split(separator: " ")
            guard let first = parts.first?.lowercased() else { continue }
            if first == "element" {
                isReadingVertexProperties = parts.count >= 2 && parts[1].lowercased() == "vertex"
                continue
            }
            guard isReadingVertexProperties, first == "property" else { continue }
            if parts.count >= 5, parts[1].lowercased() == "list" {
                return .corrupt(reason: "\(url.lastPathComponent) has unsupported list property in vertex element")
            }
            guard parts.count >= 3 else { continue }
            vertexProperties.append((name: String(parts.last?.lowercased() ?? ""), type: String(parts[1].lowercased())))
        }
        let properties = Set(vertexProperties.map(\.name))
        for required in ["x", "y", "z"] where !properties.contains(required) {
            return .corrupt(reason: "\(url.lastPathComponent) is missing Gaussian splat property \(required)")
        }
        let hasSHColor = ["f_dc_0", "f_dc_1", "f_dc_2"].allSatisfy { properties.contains($0) }
        let hasRGBColor = ["red", "green", "blue"].allSatisfy { properties.contains($0) }
        if !hasSHColor && !hasRGBColor {
            return .corrupt(reason: "\(url.lastPathComponent) is missing Gaussian splat property f_dc_0")
        }
        for required in ["scale_0", "scale_1", "scale_2", "opacity", "rot_0", "rot_1", "rot_2", "rot_3"] where !properties.contains(required) {
            return .corrupt(reason: "\(url.lastPathComponent) is missing Gaussian splat property \(required)")
        }
        let safeBodyStart = min(bodyStart, data.count)
        let body = data[safeBodyStart...]
        let trimmedBody = body.drop { $0 == 10 || $0 == 13 || $0 == 32 || $0 == 9 }
        if trimmedBody.isEmpty {
            guard size > Int64(data.count) else {
                return .corrupt(reason: "\(url.lastPathComponent) has no vertex data")
            }
        }
        switch format {
        case "ascii":
            if depth == .quick {
                return .valid
            }
            if let corrupt = try validateAsciiVertexBody(
                at: url,
                bodyStart: bodyStart,
                vertexCount: vertexCount,
                vertexProperties: vertexProperties,
                shouldCancel: shouldCancel
            ) {
                return corrupt
            }
        case "binary_little_endian", "binary_big_endian":
            let stride = try? vertexProperties.reduce(Int64(0)) { partial, property in
                guard let size = binaryPropertySize(property.type) else {
                    throw ProjectArtifactValidationInternalError.unsupportedType
                }
                let result = partial.addingReportingOverflow(Int64(size))
                guard !result.overflow else {
                    throw ProjectArtifactValidationInternalError.unsupportedType
                }
                return result.partialValue
            }
            guard let stride, stride > 0 else {
                return .corrupt(reason: "\(url.lastPathComponent) has unsupported binary vertex property type")
            }
            let vertexCount64 = Int64(vertexCount)
            let multiplied = stride.multipliedReportingOverflow(by: vertexCount64)
            guard !multiplied.overflow else {
                return .corrupt(reason: "\(url.lastPathComponent) vertex byte count is too large")
            }
            let requiredBytes = multiplied.partialValue
            let availableBytes = size - Int64(bodyStart)
            guard availableBytes >= requiredBytes else {
                return .corrupt(reason: "\(url.lastPathComponent) expected at least \(requiredBytes) vertex bytes, found \(max(0, availableBytes))")
            }
            if depth == .full,
               let corrupt = try validateBinaryVertexBody(
                   handle: handle,
                   label: url.lastPathComponent,
                   bodyStart: bodyStart,
                   vertexCount: vertexCount,
                   vertexProperties: vertexProperties,
                   littleEndian: format == "binary_little_endian",
                   shouldCancel: shouldCancel
               ) {
                return corrupt
            }
        default:
            return .corrupt(reason: "\(url.lastPathComponent) has unsupported PLY format \(format)")
        }
        if depth == .full {
            do {
                try handle.seek(toOffset: 0)
            } catch {
                return .corrupt(reason: "failed to rewind \(url.lastPathComponent) for viewer validation")
            }
            let probe = ViewerPlyCompatibilityProbe()
            SplatPLYSceneReader(url).read(to: probe, shouldCancel: shouldCancel)
            if probe.failure is CancellationError {
                throw CancellationError()
            }
            try throwIfCancellationRequested(shouldCancel)
            guard probe.finished, probe.failure == nil else {
                let detail = probe.failure?.localizedDescription ?? "unknown reader failure"
                return .corrupt(
                    reason: "\(url.lastPathComponent) cannot be opened by the splat viewer: \(detail)"
                )
            }
        }
        return .valid
    }

    private static func plyHeaderBounds(in data: Data) -> (headerEnd: Int, bodyStart: Int)? {
        var lineStart = data.startIndex

        while lineStart < data.endIndex {
            var lineEnd = lineStart
            while lineEnd < data.endIndex, data[lineEnd] != 10, data[lineEnd] != 13 {
                lineEnd += 1
            }

            let line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "end_header" {
                var bodyStart = lineEnd
                if bodyStart < data.endIndex {
                    if data[bodyStart] == 13 {
                        bodyStart += 1
                        if bodyStart < data.endIndex, data[bodyStart] == 10 {
                            bodyStart += 1
                        }
                    } else if data[bodyStart] == 10 {
                        bodyStart += 1
                    }
                }
                return (headerEnd: lineEnd, bodyStart: bodyStart)
            }

            guard lineEnd < data.endIndex else { break }
            lineStart = lineEnd
            if data[lineStart] == 13 {
                lineStart += 1
                if lineStart < data.endIndex, data[lineStart] == 10 {
                    lineStart += 1
                }
            } else if data[lineStart] == 10 {
                lineStart += 1
            }
        }

        return nil
    }

    private static func validateAsciiVertexBody(
        at url: URL,
        bodyStart: Int,
        vertexCount: Int,
        vertexProperties: [(name: String, type: String)],
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ProjectArtifactStatus? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(bodyStart))
        } catch {
            return .corrupt(reason: "failed to read \(url.lastPathComponent)")
        }

        var rowCount = 0
        var carry = ""

        func consume(_ row: String) throws -> ProjectArtifactStatus? {
            try throwIfCancellationRequested(shouldCancel)
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            rowCount += 1
            let columns = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= vertexProperties.count else {
                return .corrupt(reason: "\(url.lastPathComponent) has incomplete vertex data")
            }
            for (index, property) in vertexProperties.enumerated() {
                guard asciiValue(String(columns[index]), isValidFor: property.type) else {
                    return .corrupt(reason: "\(url.lastPathComponent) has invalid vertex value for \(property.name)")
                }
            }
            return nil
        }

        while rowCount < vertexCount {
            try throwIfCancellationRequested(shouldCancel)
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            carry += String(decoding: chunk, as: UTF8.self)
            if carry.utf8.count > maxAsciiVertexRowBytes,
               !carry.contains("\n"),
               !carry.contains("\r") {
                return .corrupt(reason: "\(url.lastPathComponent) has an oversized vertex row")
            }
            let parts = carry.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            let endsWithNewline = carry.last == "\n" || carry.last == "\r"
            let completeRows = endsWithNewline ? parts[...] : parts.dropLast()
            for row in completeRows {
                if let corrupt = try consume(String(row)) {
                    return corrupt
                }
                if rowCount >= vertexCount {
                    return nil
                }
            }
            carry = endsWithNewline ? "" : String(parts.last ?? "")
        }

        if rowCount < vertexCount, let corrupt = try consume(carry) {
            return corrupt
        }
        guard rowCount >= vertexCount else {
            return .corrupt(reason: "\(url.lastPathComponent) expected \(vertexCount) vertices, found \(rowCount)")
        }
        return nil
    }

    private static func binaryPropertySize(_ type: String) -> Int? {
        switch type {
        case "char", "uchar", "int8", "uint8": 1
        case "short", "ushort", "int16", "uint16": 2
        case "int", "uint", "int32", "uint32", "float", "float32": 4
        case "double", "float64": 8
        default: nil
        }
    }

    private static func validateBinaryVertexBody(
        handle: FileHandle,
        label: String,
        bodyStart: Int,
        vertexCount: Int,
        vertexProperties: [(name: String, type: String)],
        littleEndian: Bool,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ProjectArtifactStatus? {
        var offset = 0
        var floatingProperties: [(name: String, type: String, offset: Int)] = []
        for property in vertexProperties {
            guard let size = binaryPropertySize(property.type) else {
                return .corrupt(reason: "\(label) has unsupported binary vertex property type")
            }
            if ["float", "float32", "double", "float64"].contains(property.type) {
                floatingProperties.append((property.name, property.type, offset))
            }
            let next = offset.addingReportingOverflow(size)
            guard !next.overflow else {
                return .corrupt(reason: "\(label) vertex byte count is too large")
            }
            offset = next.partialValue
        }
        let stride = offset
        guard stride > 0 else {
            return .corrupt(reason: "\(label) has unsupported binary vertex property type")
        }
        do {
            try handle.seek(toOffset: UInt64(bodyStart))
        } catch {
            return .corrupt(reason: "failed to read \(label)")
        }

        var carry = Data()
        var verticesRead = 0
        while verticesRead < vertexCount {
            try throwIfCancellationRequested(shouldCancel)
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty, carry.count < stride {
                return .corrupt(
                    reason: "\(label) expected \(vertexCount) binary vertices, found \(verticesRead)"
                )
            }
            carry.append(chunk)
            let availableRecords = min(vertexCount - verticesRead, carry.count / stride)
            if availableRecords == 0 { continue }

            var invalidProperty: String?
            try throwIfCancellationRequested(shouldCancel)
            carry.withUnsafeBytes { rawBuffer in
                guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                for record in 0..<availableRecords {
                    let recordStart = record * stride
                    for property in floatingProperties where !binaryFloatingPointIsFinite(
                        bytes: bytes,
                        offset: recordStart + property.offset,
                        type: property.type,
                        littleEndian: littleEndian
                    ) {
                        invalidProperty = property.name
                        return
                    }
                }
            }
            if let invalidProperty {
                return .corrupt(reason: "\(label) has invalid vertex value for \(invalidProperty)")
            }
            let consumed = availableRecords * stride
            carry = Data(carry.dropFirst(consumed))
            verticesRead += availableRecords
        }
        return nil
    }

    private static func binaryFloatingPointIsFinite(
        bytes: UnsafePointer<UInt8>,
        offset: Int,
        type: String,
        littleEndian: Bool
    ) -> Bool {
        switch type {
        case "float", "float32":
            var bits: UInt32 = 0
            for index in 0..<4 {
                let source = littleEndian ? index : 3 - index
                bits |= UInt32(bytes[offset + source]) << UInt32(index * 8)
            }
            return Float(bitPattern: bits).isFinite
        case "double", "float64":
            var bits: UInt64 = 0
            for index in 0..<8 {
                let source = littleEndian ? index : 7 - index
                bits |= UInt64(bytes[offset + source]) << UInt64(index * 8)
            }
            return Double(bitPattern: bits).isFinite
        default:
            return true
        }
    }

    private static func asciiValue(_ value: String, isValidFor type: String) -> Bool {
        switch type {
        case "char", "int8", "short", "int16", "int", "int32":
            return Int64(value) != nil
        case "uchar", "uint8", "ushort", "uint16", "uint", "uint32":
            return UInt64(value) != nil
        case "float", "float32", "double", "float64":
            guard let number = Double(value) else { return false }
            return number.isFinite
        default:
            return false
        }
    }
}

private enum ProjectArtifactValidationInternalError: Error {
    case unsupportedType
}

public enum ProjectArtifactError: Error, LocalizedError, Equatable {
    case invalidOutput(String)
    case publicationConflict(String)
    case publicationConflictPreservingPrevious(String, String)
    case publicationConflictPreservingFiles(String, [String])

    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let path):
            return "Invalid project output: \(path)"
        case .publicationConflict(let path):
            return "The destination changed while EasySplat was publishing: \(path)"
        case .publicationConflictPreservingPrevious(let path, let recoveredPath):
            return "The destination changed while EasySplat was publishing: \(path). The prior file was preserved as \(recoveredPath)."
        case .publicationConflictPreservingFiles(let path, let recoveredPaths):
            return "The destination changed while EasySplat was publishing: \(path). Displaced files were preserved as \(recoveredPaths.joined(separator: ", "))."
        }
    }
}
