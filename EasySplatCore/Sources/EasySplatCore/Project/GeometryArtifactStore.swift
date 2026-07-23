import CryptoKit
import Darwin
import Foundation

enum GeometryArtifactStore {
    static let maximumManifestBytes = 1_048_576
    static let maximumMedianPixelResidual = 1.5
    static let maximumP90PixelResidual = 3.0
    static let minimumLearnedObservationsPerView = 20
    static let maximumMappingFallbackReasonBytes = 4_096

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidSchema(Int)
        case invalidSourceModelPath
        case invalidDigest(String)
        case invalidResiduals
        case invalidPeakMemory
        case invalidProvenance
        case artifactDigestMismatch(String)
        case modelHashMismatch(String)
        case measuredResidualMismatch
        case manifestTooLarge
        case invalidLearnedInitializer
        case invalidCameraGrouping
        case learnedInitializerDigestMismatch
        case invalidPairGraph
        case invalidMapping
        case invalidCanonicalOrientation
        case invalidConditioning
        case conditioningMismatch
        case invalidTimings
        case invalidWorkerExecution
        case invalidRunPlanBinding
        case invalidImportedEvidence

        var errorDescription: String? {
            switch self {
            case .invalidSchema(let schema):
                return "Unsupported geometry artifact schema \(schema)."
            case .invalidSourceModelPath:
                return "Geometry artifact points outside the project."
            case .invalidDigest(let field):
                return "Geometry artifact has an invalid \(field) digest."
            case .invalidResiduals:
                return "Geometry artifact does not contain measured pixel residuals."
            case .invalidPeakMemory:
                return "Geometry artifact does not contain a measured peak-memory value."
            case .invalidProvenance:
                return "Geometry artifact provenance is incomplete or inconsistent."
            case .artifactDigestMismatch(let field):
                return "Geometry artifact no longer matches its \(field)."
            case .modelHashMismatch(let name):
                return "Geometry artifact model file does not match its digest: \(name)."
            case .measuredResidualMismatch:
                return "Geometry artifact measurements do not match its source model."
            case .manifestTooLarge:
                return "Geometry artifact exceeds the supported size."
            case .invalidLearnedInitializer:
                return "Geometry artifact has an invalid learned point initializer."
            case .invalidCameraGrouping:
                return "Geometry artifact camera grouping is incomplete or inconsistent."
            case .learnedInitializerDigestMismatch:
                return "Learned point initialization no longer matches accepted geometry."
            case .invalidPairGraph:
                return "Geometry artifact pair-graph evidence is incomplete or inconsistent."
            case .invalidMapping:
                return "Geometry artifact mapping evidence is incomplete or inconsistent."
            case .invalidCanonicalOrientation:
                return "Geometry artifact orientation evidence is incomplete or inconsistent."
            case .invalidConditioning:
                return "Geometry artifact conditioning evidence is incomplete or inconsistent."
            case .conditioningMismatch:
                return "Geometry artifact conditioning evidence does not match its source model."
            case .invalidTimings:
                return "Geometry artifact timing evidence is incomplete or invalid."
            case .invalidWorkerExecution:
                return "Geometry artifact worker execution evidence is incomplete or invalid."
            case .invalidRunPlanBinding:
                return "Geometry artifact does not match its resolved run plan."
            case .invalidImportedEvidence:
                return "Geometry artifact imported evidence is incomplete or does not match its dataset seed."
            }
        }
    }

    static let importedSeedClosureDomain = "easysplat-dataset-seed-closure-v1"
    static let importedSourceClosureDomain = "easysplat-dataset-source-closure-v1"

    /// Domain-separated rollup over a dataset receipt file list. Order-independent
    /// (files are sorted by project-relative path), so a manifest and the on-disk
    /// receipt agree regardless of enumeration order. An empty list yields the
    /// domain-only digest, which still binds "no such files".
    static func datasetReceiptClosureDigest(
        _ files: [DatasetReceiptFile],
        domain: String
    ) -> String? {
        guard Set(files.map(\.projectRelativePath)).count == files.count,
              files.allSatisfy({ isSHA256($0.sha256) && $0.byteCount >= 0 }) else {
            return nil
        }
        let ordered = files.sorted { $0.projectRelativePath < $1.projectRelativePath }
        var hasher = SHA256()
        let domainData = Data(domain.utf8)
        update(UInt64(domainData.count), in: &hasher)
        hasher.update(data: domainData)
        for file in ordered {
            let pathData = Data(file.projectRelativePath.utf8)
            update(UInt64(pathData.count), in: &hasher)
            hasher.update(data: pathData)
            update(UInt64(file.byteCount), in: &hasher)
            let digestData = Data(file.sha256.utf8)
            update(UInt64(digestData.count), in: &hasher)
            hasher.update(data: digestData)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(
        from url: URL,
        projectPaths: ProjectPaths,
        expectedInput: InputSpec? = nil
    ) throws -> GeometryArtifact {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        let envelope = try JSONDecoder().decode(SchemaVersionEnvelope.self, from: data)
        guard envelope.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw Error.invalidSchema(envelope.schemaVersion)
        }
        let artifact = try JSONDecoder().decode(GeometryArtifact.self, from: data)
        let input = try expectedInput ?? projectInputIfPresent(projectPaths: projectPaths)
        let analysis = try validatedAnalysis(
            artifact,
            projectPaths: projectPaths,
            input: input
        )
        let stableData = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        guard stableData == data else {
            throw Error.artifactDigestMismatch("geometry manifest")
        }
        let sourceModel = try projectPaths.resolveProjectRelativePath(artifact.sourceModelPath)
        do {
            try GeometryModelSnapshot.validate(analysis.modelSnapshot, at: sourceModel)
        } catch {
            throw Error.modelHashMismatch("source snapshot")
        }
        return artifact
    }

    static func loadManifest(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> GeometryArtifact {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        let envelope = try JSONDecoder().decode(SchemaVersionEnvelope.self, from: data)
        guard envelope.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw Error.invalidSchema(envelope.schemaVersion)
        }
        let artifact = try JSONDecoder().decode(GeometryArtifact.self, from: data)
        _ = try projectPaths.resolveProjectRelativePath(artifact.sourceModelPath)
        let stableData = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        guard stableData == data else {
            throw Error.artifactDigestMismatch("geometry manifest")
        }
        return artifact
    }

    private struct SchemaVersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func manifestDigest(
        matching expectedArtifact: GeometryArtifact,
        at url: URL
    ) throws -> String {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        let envelope = try JSONDecoder().decode(SchemaVersionEnvelope.self, from: data)
        guard envelope.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw Error.invalidSchema(envelope.schemaVersion)
        }
        let persistedArtifact = try JSONDecoder().decode(GeometryArtifact.self, from: data)
        guard persistedArtifact == expectedArtifact else {
            throw Error.artifactDigestMismatch("geometry manifest")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func persist(
        _ artifact: GeometryArtifact,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil,
        verifiedSourceSnapshot: GeometryModelSnapshot.Verified? = nil,
        measuredAnalysis: GeometryConditioningAnalysis? = nil
    ) throws {
        guard let resolvedRunPlan = metadata.resolvedRunPlan else {
            throw Error.invalidRunPlanBinding
        }
        try requireRunPlanBinding(artifact, plan: resolvedRunPlan)
        let analysis = try validatedAnalysis(
            artifact,
            projectPaths: paths,
            measuredResiduals: measuredResiduals,
            verifiedSourceSnapshot: verifiedSourceSnapshot,
            measuredAnalysis: measuredAnalysis,
            input: metadata.input
        )
        let sourceModel = try paths.resolveProjectRelativePath(artifact.sourceModelPath)
        do {
            try GeometryModelSnapshot.validate(analysis.modelSnapshot, at: sourceModel)
        } catch {
            throw Error.modelHashMismatch("source snapshot")
        }
        if let verifiedSourceSnapshot {
            do {
                try GeometryModelSnapshot.validate(
                    verifiedSourceSnapshot,
                    at: sourceModel
                )
            } catch {
                throw Error.modelHashMismatch("source snapshot")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        guard data.count <= maximumManifestBytes else { throw Error.manifestTooLarge }
        try prepareManifestDestinationForAtomicReplacement(paths.geometryManifestURL)
        try data.write(to: paths.geometryManifestURL, options: [.atomic])
        _ = try load(from: paths.geometryManifestURL, projectPaths: paths, expectedInput: metadata.input)
    }

    private static func prepareManifestDestinationForAtomicReplacement(_ url: URL) throws {
        let fileManager = FileManager.default
        let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard fileManager.fileExists(atPath: url.path) || isSymlink else { return }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let isRegular = attributes?[.type] as? FileAttributeType == .typeRegular
        let linkCount = (attributes?[.referenceCount] as? NSNumber)?.intValue
        guard !isSymlink, isRegular, linkCount == 1 else {
            // This is an app-owned reserved path. Remove only the directory entry;
            // never follow a link or let a non-file block later recovery.
            try? fileManager.removeItem(at: url)
            throw Error.artifactDigestMismatch("geometry manifest destination")
        }
    }

    static func validate(
        _ artifact: GeometryArtifact,
        projectPaths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil,
        verifiedSourceSnapshot: GeometryModelSnapshot.Verified? = nil,
        input: InputSpec? = nil
    ) throws {
        _ = try validatedAnalysis(
            artifact,
            projectPaths: projectPaths,
            measuredResiduals: measuredResiduals,
            verifiedSourceSnapshot: verifiedSourceSnapshot,
            input: input
        )
    }

    static func requireRunPlanBinding(
        _ artifact: GeometryArtifact,
        plan: ResolvedRunPlan
    ) throws {
        do {
            try plan.validate()
        } catch {
            throw Error.invalidRunPlanBinding
        }

        // Imported geometry binds route `.adoptDirect`; a computed artifact on the
        // importedPoses backend was re-triangulated, so it binds `.seedTriangulate`.
        switch artifact.resolvedSource {
        case .imported:
            guard plan.geometryBackend == .importedPoses,
                  plan.datasetGeometryRoute == .adoptDirect else {
                throw Error.invalidRunPlanBinding
            }
        case .computed:
            if plan.geometryBackend == .importedPoses {
                guard plan.datasetGeometryRoute == .seedTriangulate else {
                    throw Error.invalidRunPlanBinding
                }
            }
        }

        let provenanceMatchesRoute: Bool
        switch plan.geometryBackend {
        case .colmap, .importedPoses:
            provenanceMatchesRoute = artifact.provenance.runtime == nil
                && artifact.provenance.model == nil
                && artifact.modelVersion == "none"
        case .da3:
            if let runtime = artifact.provenance.runtime,
               let model = artifact.provenance.model {
                provenanceMatchesRoute = runtime.identifier == "da3_mps"
                    && model.identifier == plan.modelIdentifier
                    && artifact.modelVersion == "\(model.identifier)@\(model.revision)"
            } else {
                provenanceMatchesRoute = false
            }
        }

        guard artifact.cameraGrouping == plan.cameraGrouping,
              artifact.cameraInitializationReceipt.recipe
                == plan.cameraInitializationRecipe,
              artifact.workerExecution.resolvedBudget == plan.geometryWorkerBudget,
              provenanceMatchesRoute,
              artifact.pairGraph.measurement.map({
                  $0.pairingPolicy == plan.pairingPolicy
              }) ?? true else {
            throw Error.invalidRunPlanBinding
        }

        if artifact.mapping.acceptedRefinementKind == .incrementalGlobal {
            guard let cadence = artifact.mapping.plannedIncrementalCadence,
                  cadence.localMaxRefinements == plan.baLocalMaxRefinements,
                  cadence.globalFramesRatio == plan.baGlobalFramesRatio,
                  cadence.globalPointsRatio == plan.baGlobalPointsRatio,
                  cadence.globalMaxRefinements == plan.baGlobalMaxRefinements,
                  cadence.localMaxNumIterations == plan.baLocalMaxNumIterations,
                  cadence.localFunctionTolerance == plan.baLocalFunctionTolerance,
                  cadence.globalFunctionTolerance == plan.baGlobalFunctionTolerance,
                  cadence.localImageCount == plan.baLocalImageCount else {
                throw Error.invalidRunPlanBinding
            }
        }
    }

    private static func validatedAnalysis(
        _ artifact: GeometryArtifact,
        projectPaths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil,
        verifiedSourceSnapshot: GeometryModelSnapshot.Verified? = nil,
        measuredAnalysis: GeometryConditioningAnalysis? = nil,
        input: InputSpec? = nil
    ) throws -> GeometryConditioningAnalysis {
        guard artifact.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw Error.invalidSchema(artifact.schemaVersion)
        }
        if artifact.resolvedSource == .imported {
            return try validatedImportedAnalysis(
                artifact,
                projectPaths: projectPaths,
                measuredResiduals: measuredResiduals,
                verifiedSourceSnapshot: verifiedSourceSnapshot,
                measuredAnalysis: measuredAnalysis,
                input: input
            )
        }
        do {
            try artifact.workerExecution.validate(
                expectedBudget: artifact.workerExecution.resolvedBudget
            )
            let persistedWorkerExecution = try GeometryWorkerExecutionArtifactStore.load(
                from: GeometryWorkerExecutionArtifactStore.canonicalURL(for: projectPaths),
                expectedBudget: artifact.workerExecution.resolvedBudget,
                projectPaths: projectPaths
            )
            guard persistedWorkerExecution == artifact.workerExecution else {
                throw Error.invalidWorkerExecution
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidWorkerExecution
        }
        let provenance = artifact.provenance
        guard !artifact.solverVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artifact.runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artifact.modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provenance.toolchainVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provenance.solver.identifier == "colmap",
              validComponent(provenance.solver),
              artifact.workerExecution.colmapRuntimeClosure.isValid,
              provenance.solver.payloadSHA256
                == artifact.workerExecution.colmapRuntimeClosure.closureSHA256,
              (provenance.runtime == nil) == (provenance.model == nil) else {
            throw Error.invalidProvenance
        }
        if let runtime = provenance.runtime, let model = provenance.model {
            guard runtime.identifier == "da3_mps",
                  validComponent(runtime),
                  validComponent(model),
                  artifact.modelVersion == "\(model.identifier)@\(model.revision)" else {
                throw Error.invalidProvenance
            }
        } else if artifact.modelVersion != "none" {
            throw Error.invalidProvenance
        }
        guard artifact.poseConvention == "world-to-camera",
              artifact.quaternionOrder == "wxyz",
              artifact.handedness == "right-handed",
              artifact.scaleType == "arbitrary-sim3" else {
            throw Error.invalidCanonicalOrientation
        }
        guard let cameraGroupingReceipt = artifact.cameraGroupingReceipt,
              cameraGroupingReceipt.isValid(
                  selectedImageCount: artifact.totalViewCount
              ),
              let featureDatabaseDigest = artifact.featureDatabaseDigest,
              isSHA256(featureDatabaseDigest) else {
            throw Error.invalidCameraGrouping
        }
        guard artifact.cameraInitializationReceipt.isValid else {
            throw Error.invalidCameraGrouping
        }
        guard artifact.cameraInitializationReceipt.cameraModel == artifact.cameraModel,
              artifact.cameraInitializationReceipt.singleCamera
                == (cameraGroupingReceipt.mode == .allSelectedImagesShared) else {
            throw Error.invalidCameraGrouping
        }
        if artifact.cameraInitializationReceipt.recipe
            == .sharedOpenCVFisheyeEquidistantDiagonal150V1 {
            guard cameraGroupingReceipt.mode == .allSelectedImagesShared,
                  artifact.cameraInitializationReceipt.cameraModel == "OPENCV_FISHEYE",
                  artifact.cameraModel == "OPENCV_FISHEYE" else {
                throw Error.invalidCameraGrouping
            }
        }
        switch artifact.cameraGrouping {
        case .sameCameraAndLens:
            guard cameraGroupingReceipt.mode == .allSelectedImagesShared else {
                throw Error.invalidCameraGrouping
            }
        case .mixedCamerasOrLenses:
            guard cameraGroupingReceipt.mode != .allSelectedImagesShared else {
                throw Error.invalidCameraGrouping
            }
        case .automatic:
            break
        }
        guard artifact.sourceModelPath == "SfM/colmap/sparse/0",
              let sourceModel = try? projectPaths.resolveProjectRelativePath(
                  artifact.sourceModelPath
              ) else {
            throw Error.invalidSourceModelPath
        }
        if let verifiedSourceSnapshot {
            do {
                try GeometryModelSnapshot.validate(verifiedSourceSnapshot, at: sourceModel)
            } catch {
                throw Error.modelHashMismatch("source snapshot")
            }
        }
        if provenance.model != nil {
            guard let initializer = artifact.learnedPointInitializer,
                  initializer.path == "SfM/colmap/seed/0/learned_points3D.txt",
                  initializer.pointCount > 0,
                  isSHA256(initializer.sha256),
                  let initializerURL = try? projectPaths.resolveProjectRelativePath(initializer.path) else {
                throw Error.invalidLearnedInitializer
            }
            do {
                _ = try Da3LearnedPointInitializer.inspect(
                    learnedPointsURL: initializerURL,
                    expectedPointCount: initializer.pointCount,
                    maximumPointCount: initializer.pointCount,
                    expectedSHA256: initializer.sha256
                )
            } catch Da3LearnedPointInitializer.Error.digestMismatch {
                throw Error.learnedInitializerDigestMismatch
            } catch {
                throw Error.invalidLearnedInitializer
            }
        } else if artifact.learnedPointInitializer != nil {
            throw Error.invalidLearnedInitializer
        }
        guard isSHA256(artifact.inputDigest) else { throw Error.invalidDigest("input") }
        guard isSHA256(artifact.selectedFramesDigest) else { throw Error.invalidDigest("selected frames") }
        let coverageDenominator = registeredCoverageDenominator(for: artifact)
        guard artifact.residualProvenance == "colmap-text-tracks-v1",
              artifact.observationCount > 0,
              artifact.pointCount > 0,
              artifact.totalViewCount > 0,
              artifact.registeredViewCount > 0,
              artifact.registeredViewCount <= artifact.totalViewCount,
              Double(artifact.registeredViewCount) / Double(coverageDenominator)
                  >= ReconstructionScorer.minimumRegisteredViewFraction
                  || isViablePartialRegistration(
                      artifact,
                      coverageDenominator: coverageDenominator
                  ),
              artifact.orderedImageNames.count == artifact.totalViewCount,
              artifact.orderedImageTimestamps.count == artifact.totalViewCount,
              artifact.medianPixelResidual.isFinite,
              artifact.p90PixelResidual.isFinite,
              artifact.medianPixelResidual >= 0,
              artifact.p90PixelResidual >= artifact.medianPixelResidual,
              artifact.medianPixelResidual <= maximumMedianPixelResidual,
              artifact.p90PixelResidual <= maximumP90PixelResidual else {
            throw Error.invalidResiduals
        }
        guard artifact.peakMemoryBytes > 0 else {
            throw Error.invalidPeakMemory
        }
        guard let orientationEstimationDuration = artifact.timings[
            "orientation_estimation_seconds"
        ],
              orientationEstimationDuration.isFinite,
              orientationEstimationDuration >= 0,
              artifact.timings["orientation_seconds"] == nil,
              artifact.timings.allSatisfy({ key, value in
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && value.isFinite
                      && value >= 0
              }) else {
            throw Error.invalidTimings
        }
        let hasLearnedProvenance = provenance.runtime != nil
            && provenance.model != nil
        try validatePairGraph(
            artifact.pairGraph,
            totalViewCount: artifact.totalViewCount,
            registeredViewCount: artifact.registeredViewCount,
            hasLearnedProvenance: hasLearnedProvenance
        )
        try validateMapping(
            artifact.mapping,
            totalViewCount: artifact.totalViewCount,
            registeredViewCount: artifact.registeredViewCount,
            pairGraphStatus: artifact.pairGraph.status,
            hasLearnedProvenance: hasLearnedProvenance,
            canonicalModelHashes: artifact.modelHashes,
            canonicalModelURL: sourceModel,
            projectPaths: projectPaths
        )
        do {
            try artifact.workerExecution.validateForPublishedGeometry(
                expectedBudget: artifact.workerExecution.resolvedBudget,
                context: GeometryWorkerExecutionPublicationContext(
                    mapping: artifact.mapping,
                    pairGraph: artifact.pairGraph,
                    expectedVideoSourceCount: input?.videoFiles.count
                        ?? artifact.workerExecution.videoSourceAnalysis.videoSourceCount
                )
            )
        } catch {
            throw Error.invalidWorkerExecution
        }
        if let input {
            guard cameraGroupingReceipt.groupedVideoSourceCount == input.videoFiles.count else {
                throw Error.invalidCameraGrouping
            }
        }
        if let conversion = artifact.mapping.canonicalModelPublication.conversion {
            guard conversion.workerEvidence.executableComponentPath == "bin/colmap",
                  conversion.workerEvidence.executableSHA256
                    == artifact.workerExecution.colmapRuntimeClosure.sha256(
                        for: "bin/colmap"
                    ) else {
                throw Error.invalidWorkerExecution
            }
        }
        try validateCanonicalOrientation(
            artifact.canonicalOrientation,
            registeredViewCount: artifact.registeredViewCount
        )
        guard Set(artifact.modelHashes.keys) == ["cameras.txt", "images.txt", "points3D.txt"],
              artifact.modelHashes.values.allSatisfy(isSHA256) else {
            throw Error.invalidDigest("model")
        }
        try validateConditioning(
            artifact.conditioning,
            registeredViewCount: artifact.registeredViewCount,
            pointCount: artifact.pointCount,
            observationCount: artifact.observationCount,
            modelHashes: artifact.modelHashes
        )
        if let verifiedSourceSnapshot {
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                guard verifiedSourceSnapshot.modelHashes[name]
                        == artifact.modelHashes[name] else {
                    throw Error.modelHashMismatch(name)
                }
            }
        } else {
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                let relativePath = artifact.sourceModelPath + "/" + name
                guard let file = try? projectPaths.resolveProjectRelativePath(relativePath),
                      let digest = try? sha256(of: file),
                      digest == artifact.modelHashes[name] else {
                    throw Error.modelHashMismatch(name)
                }
            }
        }
        let currentInputDigest = try inputDigest(projectPaths: projectPaths)
        guard currentInputDigest == artifact.inputDigest else {
            throw Error.artifactDigestMismatch("imported input")
        }
        let currentSelectedFramesDigest = try selectedFramesDigest(
            orderedImageNames: artifact.orderedImageNames,
            projectPaths: projectPaths
        )
        guard currentSelectedFramesDigest == artifact.selectedFramesDigest else {
            throw Error.artifactDigestMismatch("selected frames")
        }

        let analysis: GeometryConditioningAnalysis
        if let measuredAnalysis {
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                guard measuredAnalysis.modelSnapshot.modelHashes[name]
                        == artifact.modelHashes[name] else {
                    throw Error.modelHashMismatch(name)
                }
            }
            do {
                try GeometryModelSnapshot.validate(
                    measuredAnalysis.modelSnapshot,
                    at: sourceModel
                )
            } catch {
                throw Error.modelHashMismatch("source snapshot")
            }
            analysis = measuredAnalysis
        } else {
            do {
                analysis = try ColmapResidualAnalyzer.analyzeConditioning(
                    modelDirectory: sourceModel,
                    maximumRayPairEvaluations: artifact.conditioning.maximumRayPairEvaluations,
                    checkCancellation: { try Task.checkCancellation() }
                )
            } catch is GeometryConditioningFailure {
                throw Error.conditioningMismatch
            } catch is GeometryModelSnapshot.Error {
                throw Error.modelHashMismatch("source snapshot")
            }
        }
        let measured = analysis.residuals
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            guard analysis.modelSnapshot.modelHashes[name] == artifact.modelHashes[name] else {
                throw Error.modelHashMismatch(name)
            }
        }
        if let measuredResiduals, measuredResiduals != measured {
            throw Error.measuredResidualMismatch
        }
        let stronglyMeasuredViewCount = measured.observationCountByImage.values.filter {
            $0 >= minimumLearnedObservationsPerView
        }.count
        let learnedSupportIsValid = artifact.learnedPointInitializer == nil
            || Double(stronglyMeasuredViewCount) / Double(artifact.totalViewCount)
                >= ReconstructionScorer.minimumRegisteredViewFraction
        guard measured.provenance == artifact.residualProvenance,
              measured.cameraModel == artifact.cameraModel,
              measured.registeredViewCount == artifact.registeredViewCount,
              Set(measured.registeredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Set(measured.measuredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Double(measured.measuredImageNames.count)
                  / Double(registeredCoverageDenominator(for: artifact))
                  >= ReconstructionScorer.minimumRegisteredViewFraction
                  || (isViablePartialRegistration(
                          artifact,
                          coverageDenominator: registeredCoverageDenominator(
                              for: artifact
                          )
                      )
                      && Double(measured.measuredImageNames.count)
                          / Double(artifact.registeredViewCount)
                          >= ReconstructionScorer.minimumRegisteredViewFraction),
              learnedSupportIsValid,
              measured.pointCount == artifact.pointCount,
              measured.observationCount == artifact.observationCount,
              approximatelyEqual(measured.medianPixelResidual, artifact.medianPixelResidual),
              approximatelyEqual(measured.p90PixelResidual, artifact.p90PixelResidual) else {
            throw Error.measuredResidualMismatch
        }
        guard analysis.measurement == artifact.conditioning.measurement else {
            throw Error.conditioningMismatch
        }
        if let verifiedSourceSnapshot {
            do {
                try GeometryModelSnapshot.validate(verifiedSourceSnapshot, at: sourceModel)
            } catch {
                throw Error.modelHashMismatch("source snapshot")
            }
        }
        do {
            try GeometryModelSnapshot.validate(analysis.modelSnapshot, at: sourceModel)
        } catch {
            throw Error.modelHashMismatch("source snapshot")
        }
        return analysis
    }

    /// The load/persist verification path for directly-adopted dataset geometry.
    /// It re-derives the sparse/0 model digests exactly as the computed path does,
    /// re-runs conditioning against the imported model, and re-verifies the
    /// authenticated seed/source receipt — but requires none of the pair-graph,
    /// worker-execution, feature-database, or camera-grouping evidence, which do
    /// not exist on this route. The imported evidence replaces those legs.
    private static func validatedImportedAnalysis(
        _ artifact: GeometryArtifact,
        projectPaths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result?,
        verifiedSourceSnapshot: GeometryModelSnapshot.Verified?,
        measuredAnalysis: GeometryConditioningAnalysis?,
        input: InputSpec?
    ) throws -> GeometryConditioningAnalysis {
        let provenance = artifact.provenance
        guard let evidence = artifact.importedEvidence else {
            throw Error.invalidImportedEvidence
        }
        // Solver provenance is the pin between the artifact and its dataset seed.
        guard !artifact.solverVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artifact.runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              artifact.modelVersion == "none",
              !provenance.toolchainVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provenance.solver.identifier == "imported",
              provenance.runtime == nil,
              provenance.model == nil,
              validComponent(provenance.solver),
              provenance.solver.version == evidence.datasetKind,
              provenance.solver.revision == evidence.sourceClosureSHA256,
              provenance.solver.payloadSHA256 == evidence.seedClosureSHA256 else {
            throw Error.invalidProvenance
        }
        // Imported geometry carries none of the computed-evidence legs.
        guard artifact.pairGraph.status == .notEvaluated,
              artifact.pairGraph.measurement == nil,
              artifact.featureDatabaseDigest == nil,
              artifact.cameraGroupingReceipt == nil,
              artifact.learnedPointInitializer == nil else {
            throw Error.invalidImportedEvidence
        }
        // Re-verify the authenticated seed/source receipt: the closures pin into
        // provenance, and every on-disk file must still match its recorded digest,
        // so a swapped `Import/seed` invalidates the artifact.
        guard evidence.route == DatasetGeometryRoute.adoptDirect.rawValue,
              !evidence.datasetKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              evidence.imageCount == artifact.totalViewCount,
              Set(evidence.seedFiles.map(\.projectRelativePath))
                == Set(DatasetPoseSeedReceipt.seedFileRelativePaths),
              datasetReceiptClosureDigest(
                  evidence.seedFiles,
                  domain: importedSeedClosureDomain
              ) == evidence.seedClosureSHA256,
              datasetReceiptClosureDigest(
                  evidence.sourceFiles,
                  domain: importedSourceClosureDomain
              ) == evidence.sourceClosureSHA256 else {
            throw Error.invalidImportedEvidence
        }
        try verifyImportedReceiptFiles(evidence.seedFiles, projectPaths: projectPaths)
        try verifyImportedReceiptFiles(evidence.sourceFiles, projectPaths: projectPaths)

        guard artifact.poseConvention == "world-to-camera",
              artifact.quaternionOrder == "wxyz",
              artifact.handedness == "right-handed",
              artifact.scaleType == "arbitrary-sim3" else {
            throw Error.invalidCanonicalOrientation
        }
        guard artifact.sourceModelPath == "SfM/colmap/sparse/0",
              let sourceModel = try? projectPaths.resolveProjectRelativePath(
                  artifact.sourceModelPath
              ) else {
            throw Error.invalidSourceModelPath
        }
        if let verifiedSourceSnapshot {
            do {
                try GeometryModelSnapshot.validate(verifiedSourceSnapshot, at: sourceModel)
            } catch {
                throw Error.modelHashMismatch("source snapshot")
            }
        }
        guard isSHA256(artifact.inputDigest) else { throw Error.invalidDigest("input") }
        guard isSHA256(artifact.selectedFramesDigest) else {
            throw Error.invalidDigest("selected frames")
        }
        let coverageDenominator = registeredCoverageDenominator(for: artifact)
        guard artifact.residualProvenance == "colmap-text-tracks-v1",
              artifact.observationCount > 0,
              artifact.pointCount > 0,
              artifact.totalViewCount > 0,
              artifact.registeredViewCount > 0,
              artifact.registeredViewCount <= artifact.totalViewCount,
              Double(artifact.registeredViewCount) / Double(coverageDenominator)
                  >= ReconstructionScorer.minimumRegisteredViewFraction,
              artifact.orderedImageNames.count == artifact.totalViewCount,
              artifact.orderedImageTimestamps.count == artifact.totalViewCount,
              artifact.medianPixelResidual.isFinite,
              artifact.p90PixelResidual.isFinite,
              artifact.medianPixelResidual >= 0,
              artifact.p90PixelResidual >= artifact.medianPixelResidual,
              artifact.medianPixelResidual <= maximumMedianPixelResidual,
              artifact.p90PixelResidual <= maximumP90PixelResidual else {
            throw Error.invalidResiduals
        }
        guard artifact.peakMemoryBytes > 0 else { throw Error.invalidPeakMemory }
        guard let orientationEstimationDuration = artifact.timings[
            "orientation_estimation_seconds"
        ],
              orientationEstimationDuration.isFinite,
              orientationEstimationDuration >= 0,
              artifact.timings["orientation_seconds"] == nil,
              artifact.timings.allSatisfy({ key, value in
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && value.isFinite
                      && value >= 0
              }) else {
            throw Error.invalidTimings
        }
        try validateCanonicalOrientation(
            artifact.canonicalOrientation,
            registeredViewCount: artifact.registeredViewCount
        )
        guard Set(artifact.modelHashes.keys)
                == ["cameras.txt", "images.txt", "points3D.txt"],
              artifact.modelHashes.values.allSatisfy(isSHA256) else {
            throw Error.invalidDigest("model")
        }
        try validateConditioning(
            artifact.conditioning,
            registeredViewCount: artifact.registeredViewCount,
            pointCount: artifact.pointCount,
            observationCount: artifact.observationCount,
            modelHashes: artifact.modelHashes
        )
        if let verifiedSourceSnapshot {
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                guard verifiedSourceSnapshot.modelHashes[name]
                        == artifact.modelHashes[name] else {
                    throw Error.modelHashMismatch(name)
                }
            }
        } else {
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                let relativePath = artifact.sourceModelPath + "/" + name
                guard let file = try? projectPaths.resolveProjectRelativePath(relativePath),
                      let digest = try? sha256(of: file),
                      digest == artifact.modelHashes[name] else {
                    throw Error.modelHashMismatch(name)
                }
            }
        }
        let currentInputDigest = try inputDigest(projectPaths: projectPaths)
        guard currentInputDigest == artifact.inputDigest else {
            throw Error.artifactDigestMismatch("imported input")
        }
        let currentSelectedFramesDigest = try selectedFramesDigest(
            orderedImageNames: artifact.orderedImageNames,
            projectPaths: projectPaths
        )
        guard currentSelectedFramesDigest == artifact.selectedFramesDigest else {
            throw Error.artifactDigestMismatch("selected frames")
        }
        _ = input

        let analysis: GeometryConditioningAnalysis
        if let measuredAnalysis {
            for name in ["cameras.txt", "images.txt", "points3D.txt"] {
                guard measuredAnalysis.modelSnapshot.modelHashes[name]
                        == artifact.modelHashes[name] else {
                    throw Error.modelHashMismatch(name)
                }
            }
            do {
                try GeometryModelSnapshot.validate(
                    measuredAnalysis.modelSnapshot,
                    at: sourceModel
                )
            } catch {
                throw Error.modelHashMismatch("source snapshot")
            }
            analysis = measuredAnalysis
        } else {
            do {
                analysis = try ColmapResidualAnalyzer.analyzeConditioning(
                    modelDirectory: sourceModel,
                    maximumRayPairEvaluations:
                        artifact.conditioning.maximumRayPairEvaluations,
                    checkCancellation: { try Task.checkCancellation() }
                )
            } catch is GeometryConditioningFailure {
                throw Error.conditioningMismatch
            } catch is GeometryModelSnapshot.Error {
                throw Error.modelHashMismatch("source snapshot")
            }
        }
        let measured = analysis.residuals
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            guard analysis.modelSnapshot.modelHashes[name] == artifact.modelHashes[name] else {
                throw Error.modelHashMismatch(name)
            }
        }
        if let measuredResiduals, measuredResiduals != measured {
            throw Error.measuredResidualMismatch
        }
        guard measured.provenance == artifact.residualProvenance,
              measured.cameraModel == artifact.cameraModel,
              measured.registeredViewCount == artifact.registeredViewCount,
              Set(measured.registeredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Set(measured.measuredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Double(measured.measuredImageNames.count) / Double(coverageDenominator)
                  >= ReconstructionScorer.minimumRegisteredViewFraction,
              measured.pointCount == artifact.pointCount,
              measured.observationCount == artifact.observationCount,
              approximatelyEqual(measured.medianPixelResidual, artifact.medianPixelResidual),
              approximatelyEqual(measured.p90PixelResidual, artifact.p90PixelResidual) else {
            throw Error.measuredResidualMismatch
        }
        guard analysis.measurement == artifact.conditioning.measurement else {
            throw Error.conditioningMismatch
        }
        do {
            try GeometryModelSnapshot.validate(analysis.modelSnapshot, at: sourceModel)
        } catch {
            throw Error.modelHashMismatch("source snapshot")
        }
        return analysis
    }

    private static func verifyImportedReceiptFiles(
        _ files: [DatasetReceiptFile],
        projectPaths: ProjectPaths
    ) throws {
        for file in files {
            guard let url = try? projectPaths.resolveProjectRelativePath(
                      file.projectRelativePath
                  ),
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: url.path
                  ),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size == file.byteCount,
                  let digest = try? sha256(of: url),
                  digest == file.sha256 else {
                throw Error.invalidImportedEvidence
            }
        }
    }

    private static func validateConditioning(
        _ artifact: GeometryConditioningArtifact,
        registeredViewCount: Int,
        pointCount: Int,
        observationCount: Int,
        modelHashes: [String: String]
    ) throws {
        let measurement = artifact.measurement
        guard let registeredCameraPairCount = unorderedPairCount(registeredViewCount),
              let effectiveCameraPairCount = unorderedPairCount(
                  measurement.effectiveCameraCenterCount
              ) else {
            throw Error.invalidConditioning
        }
        let expectedCameraPairEvaluationCount: Int
        if measurement.largestCameraCenterClusterSize == 1 {
            expectedCameraPairEvaluationCount = registeredCameraPairCount
        } else {
            let (combined, overflow) = registeredCameraPairCount.addingReportingOverflow(
                effectiveCameraPairCount
            )
            guard !overflow else { throw Error.invalidConditioning }
            expectedCameraPairEvaluationCount = combined
        }
        let cameraCenterClusteringIsConsistent =
            (measurement.largestCameraCenterClusterSize == 1
                && measurement.effectiveCameraCenterCount == registeredViewCount)
            || (measurement.largestCameraCenterClusterSize > 1
                && measurement.effectiveCameraCenterCount < registeredViewCount)
        let (totalPairEvaluationCount, pairCountOverflow) =
            measurement.cameraPairEvaluationCount.addingReportingOverflow(
                measurement.rayPairEvaluationCount
            )
        guard
              artifact.schemaVersion == GeometryConditioningArtifact.currentSchemaVersion,
              artifact.measurementProvenance == GeometryConditioningMeasurement.provenance,
              artifact.acceptancePolicy
                == GeometryConditioningArtifact.currentAcceptancePolicy,
              artifact.maximumRayPairEvaluations
                == GeometryConditioningArtifact.defaultMaximumRayPairEvaluations,
              isSHA256(artifact.sourceModelClosureSHA256),
              artifact.sourceModelClosureSHA256 == modelClosureDigest(
                  modelHashes,
                  expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
              ),
              measurement.registeredViewCount == registeredViewCount,
              measurement.pointCount == pointCount,
              measurement.observationCount == observationCount,
              measurement.positiveDepthObservationCount == observationCount,
              measurement.stronglyMeasuredViewCount >= 0,
              measurement.stronglyMeasuredViewCount <= registeredViewCount,
              measurement.stronglyMeasuredViewCount >= Int(ceil(
                  Double(registeredViewCount)
                    * ReconstructionScorer.minimumRegisteredViewFraction
              )),
              validOrderedStatistics(
                  minimum: measurement.perViewObservationMinimum,
                  p10: measurement.perViewObservationP10,
                  median: measurement.perViewObservationMedian,
                  p90: measurement.perViewObservationP90,
                  lowerBound: 0,
                  upperBound: observationCount
              ),
              validOrderedStatistics(
                  minimum: measurement.distinctTrackLengthMinimum,
                  p10: measurement.distinctTrackLengthP10,
                  median: measurement.distinctTrackLengthMedian,
                  p90: measurement.distinctTrackLengthP90,
                  lowerBound: 2,
                  upperBound: registeredViewCount
              ),
              validNestedCounts(
                  leastSelective: measurement.pointsAtLeast1Point5Degrees,
                  middle: measurement.pointsAtLeast2Degrees,
                  mostSelective: measurement.pointsAtLeast3Degrees,
                  total: pointCount
              ),
              validNestedCounts(
                  leastSelective: measurement.observationsAtLeast1Point5Degrees,
                  middle: measurement.observationsAtLeast2Degrees,
                  mostSelective: measurement.observationsAtLeast3Degrees,
                  total: observationCount
              ),
              measurement.effectiveCameraCenterCount >= min(3, registeredViewCount),
              measurement.effectiveCameraCenterCount <= registeredViewCount,
              measurement.largestCameraCenterClusterSize > 0,
              measurement.largestCameraCenterClusterSize <= registeredViewCount,
              cameraCenterClusteringIsConsistent,
              measurement.cameraCenterMergeToleranceToMedianDepthRatio == 1e-5,
              measurement.numericallyConditionedPointCount
                >= pointCount / 2 + pointCount % 2,
              measurement.numericallyConditionedPointCount <= pointCount,
              measurement.numericallyConditionedObservationCount > 0,
              measurement.numericallyConditionedObservationCount <= observationCount,
              measurement.adaptiveParallaxThresholdMedianDegrees.isFinite,
              measurement.adaptiveParallaxThresholdP90Degrees.isFinite,
              measurement.adaptiveParallaxThresholdMedianDegrees >= 0.05 - 1e-12,
              measurement.adaptiveParallaxThresholdP90Degrees
                >= measurement.adaptiveParallaxThresholdMedianDegrees,
              measurement.medianObservedDepth.isFinite,
              measurement.medianObservedDepth > 0,
              measurement.cameraBaselineToMedianDepthRatio.isFinite,
              measurement.cameraBaselineToMedianDepthRatio
                > measurement.cameraCenterMergeToleranceToMedianDepthRatio,
              validNormalizedEigenvalues(measurement.cameraCenterEigenvalues),
              validNormalizedEigenvalues(measurement.pointEigenvalues),
              measurement.pointEigenvalues[1] >= 1e-8,
              measurement.cameraPairEvaluationCount
                == expectedCameraPairEvaluationCount,
              measurement.rayPairEvaluationCount > 0,
              !pairCountOverflow,
              totalPairEvaluationCount <= artifact.maximumRayPairEvaluations else {
            throw Error.invalidConditioning
        }
    }

    private static func validOrderedStatistics(
        minimum: Int,
        p10: Int,
        median: Double,
        p90: Int,
        lowerBound: Int,
        upperBound: Int
    ) -> Bool {
        median.isFinite
            && minimum >= lowerBound
            && minimum <= p10
            && Double(p10) <= median
            && median <= Double(p90)
            && p90 <= upperBound
    }

    private static func validNestedCounts(
        leastSelective: Int,
        middle: Int,
        mostSelective: Int,
        total: Int
    ) -> Bool {
        mostSelective >= 0
            && mostSelective <= middle
            && middle <= leastSelective
            && leastSelective <= total
    }

    private static func validNormalizedEigenvalues(_ values: [Double]) -> Bool {
        values.count == 3
            && values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            && values[0] <= values[1]
            && values[1] <= values[2]
            && abs(values.reduce(0, +) - 1) <= 1e-9
    }

    private static func unorderedPairCount(_ count: Int) -> Int? {
        guard count >= 0 else { return nil }
        let (product, overflow) = count.multipliedReportingOverflow(by: count - 1)
        guard !overflow else { return nil }
        return product / 2
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    static func modelClosureDigest(
        _ hashes: [String: String],
        expectedNames: [String]
    ) -> String? {
        let names = expectedNames.sorted()
        guard Set(hashes.keys) == Set(names),
              hashes.values.allSatisfy(isSHA256) else {
            return nil
        }
        var hasher = SHA256()
        let domain = Data("easysplat-model-closure-v1".utf8)
        update(UInt64(domain.count), in: &hasher)
        hasher.update(data: domain)
        for name in names {
            guard let digest = hashes[name] else { return nil }
            let nameData = Data(name.utf8)
            let digestData = Data(digest.utf8)
            update(UInt64(nameData.count), in: &hasher)
            hasher.update(data: nameData)
            update(UInt64(digestData.count), in: &hasher)
            hasher.update(data: digestData)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func modelCandidateIdentity(
        mappingAttemptOrdinal: Int,
        candidateProjectRelativePath: String,
        sourceModelDigest: String
    ) -> String? {
        guard mappingAttemptOrdinal > 0,
              !candidateProjectRelativePath.isEmpty,
              isSHA256(sourceModelDigest) else {
            return nil
        }
        var hasher = SHA256()
        let domain = Data("easysplat-model-candidate-v1".utf8)
        update(UInt64(domain.count), in: &hasher)
        hasher.update(data: domain)
        update(UInt64(mappingAttemptOrdinal), in: &hasher)
        let pathData = Data(candidateProjectRelativePath.utf8)
        update(UInt64(pathData.count), in: &hasher)
        hasher.update(data: pathData)
        hasher.update(data: Data(sourceModelDigest.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validComponent(_ component: GeometryComponentProvenance) -> Bool {
        !component.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !component.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !component.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isSHA256(component.payloadSHA256)
    }

    /// Registered-view coverage is measured against the views matching
    /// admitted to mapping, not the full selected set: a run that continued
    /// with the dominant connected component is judged on that component.
    /// Fully connected artifacts keep the selected count as denominator.
    /// A solve the pipeline accepted at terminal exhaustion with fewer
    /// registered views than the strict fraction of the admitted denominator.
    /// Coverage floors then bind to the registered count instead. Applies
    /// only when the pair graph has an admissible dominant component — an
    /// inadmissible graph (tied groups) never reaches the terminal
    /// acceptance, so its coverage stays strict.
    private static func isViablePartialRegistration(
        _ artifact: GeometryArtifact,
        coverageDenominator: Int
    ) -> Bool {
        guard artifact.pairGraph.status == .measured,
              let measurement = artifact.pairGraph.measurement,
              PairGraphConnectivityPolicy.admissibleDominantViewCount(
                  totalViewCount: artifact.totalViewCount,
                  componentViewCounts: measurement.componentViewCounts,
                  connectedComponentCount: measurement.connectedComponentCount,
                  isolatedViewCount: measurement.isolatedViewCount,
                  descriptorlessViewCount: measurement.descriptorlessViewCount
              ) != nil else {
            return false
        }
        return artifact.registeredViewCount
            >= PairGraphConnectivityPolicy.minimumViableDominantViewCount
            && artifact.registeredViewCount <= coverageDenominator
    }

    private static func registeredCoverageDenominator(
        for artifact: GeometryArtifact
    ) -> Int {
        guard artifact.pairGraph.status == .measured,
              let measurement = artifact.pairGraph.measurement,
              let admitted = PairGraphConnectivityPolicy.admissibleDominantViewCount(
                  totalViewCount: artifact.totalViewCount,
                  componentViewCounts: measurement.componentViewCounts,
                  connectedComponentCount: measurement.connectedComponentCount,
                  isolatedViewCount: measurement.isolatedViewCount,
                  descriptorlessViewCount: measurement.descriptorlessViewCount
              ) else {
            return artifact.totalViewCount
        }
        return admitted
    }

    private static func validatePairGraph(
        _ artifact: PairGraphArtifact,
        totalViewCount: Int,
        registeredViewCount: Int,
        hasLearnedProvenance: Bool
    ) throws {
        switch artifact.status {
        case .notEvaluated:
            guard artifact.measurement == nil,
                  !artifact.requiresCrossClipRetrieval,
                  !artifact.retrievalWasScheduled,
                  !artifact.usedLocalVocabularyRetrieval else {
                throw Error.invalidPairGraph
            }
        case .measured:
            guard let measurement = artifact.measurement else {
                throw Error.invalidPairGraph
            }
            let retrievalWasRequired = hasLearnedProvenance
                ? false
                : PairGraphRetrievalScheduling.isRequired(
                    pairingPolicy: measurement.pairingPolicy,
                    selectedFrameCount: totalViewCount,
                    requiresCrossClipRetrieval:
                        artifact.requiresCrossClipRetrieval
                )
            let crossClipPolicyIsCoherent: Bool
            switch measurement.pairingPolicy {
            case .orderedContinuous,
                 .orderedOrbit,
                 .orderedWalkthrough,
                 .orderedLargeArea,
                 .segmentedMixed:
                crossClipPolicyIsCoherent = true
            case .unorderedRetrieval:
                crossClipPolicyIsCoherent = !artifact.requiresCrossClipRetrieval
            }
            guard crossClipPolicyIsCoherent,
                  !hasLearnedProvenance
                    || (!artifact.requiresCrossClipRetrieval
                        && !artifact.usedLocalVocabularyRetrieval),
                  artifact.retrievalWasScheduled == retrievalWasRequired,
                  !artifact.usedLocalVocabularyRetrieval
                    || artifact.retrievalWasScheduled else {
                throw Error.invalidPairGraph
            }
            let descriptorlessViewCount = measurement.descriptorlessViewCount
            guard descriptorlessViewCount >= 0,
                  descriptorlessViewCount < totalViewCount else {
                throw Error.invalidPairGraph
            }
            guard let dominantViewCount = PairGraphConnectivityPolicy.admissibleDominantViewCount(
                totalViewCount: totalViewCount,
                componentViewCounts: measurement.componentViewCounts,
                connectedComponentCount: measurement.connectedComponentCount,
                isolatedViewCount: measurement.isolatedViewCount,
                descriptorlessViewCount: descriptorlessViewCount
            ) else {
                throw Error.invalidPairGraph
            }
            let hasMinorVerifiedComponent = measurement.componentViewCounts
                .dropFirst()
                .contains { $0 > 1 }
            let hasSingleBiconnectedBlock = measurement.biconnectedBlockCount == 1
            let localAndRetrieval = measurement.localPairCount.addingReportingOverflow(
                measurement.retrievalPairCount
            )
            let pairRoleCount = localAndRetrieval.partialValue.addingReportingOverflow(
                measurement.loopRevisitPairCount
            )
            guard dominantViewCount >= 2,
                  registeredViewCount <= dominantViewCount,
                  measurement.scheduledPairCount >= 0,
                  measurement.attemptedPairCount >= 0,
                  measurement.attemptedPairCount <= measurement.scheduledPairCount,
                  measurement.rawMatchedPairCount >= 0,
                  measurement.rawMatchedPairCount <= measurement.attemptedPairCount,
                  measurement.spatiallyVerifiedPairCount >= 0,
                  measurement.spatiallyVerifiedPairCount <= measurement.rawMatchedPairCount,
                  measurement.localPairCount >= 0,
                  measurement.retrievalPairCount >= 0,
                  measurement.loopRevisitPairCount >= 0,
                  measurement.localPairCount <= measurement.scheduledPairCount,
                  measurement.retrievalPairCount <= measurement.scheduledPairCount,
                  measurement.loopRevisitPairCount <= measurement.scheduledPairCount,
                  !localAndRetrieval.overflow,
                  !pairRoleCount.overflow,
                  pairRoleCount.partialValue == measurement.scheduledPairCount,
                  measurement.spatiallyVerifiedPairCount >= dominantViewCount - 1,
                  measurement.articulationViewCount >= 0,
                  measurement.articulationViewCount <= dominantViewCount - 2,
                  measurement.biconnectedBlockCount >= 1,
                  measurement.biconnectedBlockCount
                    <= min(measurement.spatiallyVerifiedPairCount, dominantViewCount - 1),
                  measurement.articulationViewCount < measurement.biconnectedBlockCount,
                  measurement.largestBiconnectedBlockViewCount >= 2,
                  measurement.largestBiconnectedBlockViewCount <= dominantViewCount,
                  measurement.secondLargestBiconnectedBlockViewCount >= 0,
                  measurement.secondLargestBiconnectedBlockViewCount
                    <= measurement.largestBiconnectedBlockViewCount,
                  hasSingleBiconnectedBlock
                    ? measurement.articulationViewCount == 0
                        && measurement.largestBiconnectedBlockViewCount == dominantViewCount
                        && measurement.secondLargestBiconnectedBlockViewCount == 0
                    : measurement.articulationViewCount > 0
                        && measurement.largestBiconnectedBlockViewCount < dominantViewCount
                        && measurement.secondLargestBiconnectedBlockViewCount >= 2,
                  measurement.degreeP10 >= 0,
                  measurement.degreeP10 <= measurement.degreeMedian,
                  measurement.degreeMedian <= measurement.degreeP90,
                  measurement.degreeP90 < dominantViewCount,
                  !measurement.matcherAttempts.isEmpty,
                  isSHA256(measurement.pairListDigest),
                  isSHA256(measurement.featureDatabaseDigest),
                  isSHA256(measurement.matchingDatabaseDigest),
                  measurement.matchingDurationSeconds.isFinite,
                  measurement.matchingDurationSeconds >= 0 else {
                throw Error.invalidPairGraph
            }
            try validatePairAttemptHistory(
                measurement.matcherAttempts,
                pairingPolicy: measurement.pairingPolicy,
                totalViewCount: totalViewCount
            )
            let attemptNumbers = measurement.matcherAttempts.map(\.attemptNumber)
            let measuredDuration = measurement.matcherAttempts.reduce(0.0) {
                $0 + $1.durationSeconds
            }
            guard Set(attemptNumbers).count == attemptNumbers.count,
                  attemptNumbers.sorted() == Array(1...attemptNumbers.count),
                  measurement.matcherAttempts.allSatisfy({ attempt in
                      (attempt.matcher == .exact)
                          == (attempt.exactRecoveryReason != nil)
                          && attempt.scheduledPairCount >= 0
                          && attempt.attemptedPairCount >= 0
                          && attempt.attemptedPairCount <= attempt.scheduledPairCount
                          && attempt.rawMatchedPairCount >= 0
                          && attempt.rawMatchedPairCount <= attempt.attemptedPairCount
                          && attempt.spatiallyVerifiedPairCount >= 0
                          && attempt.spatiallyVerifiedPairCount <= attempt.rawMatchedPairCount
                          && attempt.durationSeconds.isFinite
                          && attempt.durationSeconds >= 0
                          && (attempt.outcome == .failed
                              || attempt.attemptedPairCount == attempt.scheduledPairCount)
                  }),
                  measuredDuration.isFinite,
                  approximatelyEqual(
                      measuredDuration,
                      measurement.matchingDurationSeconds,
                      relativeTolerance: 1e-12
                  ),
                  let acceptedAttempt = measurement.matcherAttempts.last,
                  acceptedAttempt.outcome == .completed,
                  acceptedAttempt.scheduledPairCount == measurement.scheduledPairCount,
                  acceptedAttempt.attemptedPairCount == measurement.attemptedPairCount,
                  acceptedAttempt.rawMatchedPairCount == measurement.rawMatchedPairCount,
                  acceptedAttempt.spatiallyVerifiedPairCount
                    == measurement.spatiallyVerifiedPairCount else {
                throw Error.invalidPairGraph
            }
            if hasMinorVerifiedComponent, isOrdered(measurement.pairingPolicy) {
                // Ordered policies only ever accept minor verified components
                // past the normal recovery level. Unordered policies reach
                // them through the terminal viable acceptance at any level.
                guard acceptedAttempt.recoveryLevel != .normal else {
                    throw Error.invalidPairGraph
                }
            }
        }
    }

    private static func projectInputIfPresent(
        projectPaths: ProjectPaths
    ) throws -> InputSpec? {
        guard FileManager.default.fileExists(atPath: projectPaths.metadataURL.path) else {
            return nil
        }
        return try ProjectMetadataStore.load(from: projectPaths.metadataURL).input
    }

    private static func validatePairAttemptHistory(
        _ attempts: [PairMatchingAttemptArtifact],
        pairingPolicy: ResolvedPairingPolicy,
        totalViewCount: Int
    ) throws {
        guard let first = attempts.first,
              first.matcher == .faiss else {
            throw Error.invalidPairGraph
        }
        for index in attempts.indices.dropFirst() {
            let previous = attempts[index - 1]
            let attempt = attempts[index]
            let previousLevel = pairRecoveryLevelIndex(previous.recoveryLevel)
            let level = pairRecoveryLevelIndex(attempt.recoveryLevel)
            guard level >= previousLevel,
                  level - previousLevel <= 2 else {
                throw Error.invalidPairGraph
            }
            if level == previousLevel {
                if attempt.matcher == previous.matcher {
                    guard attempt.matcher == .faiss,
                          previous.outcome != .completed,
                          attempt.scheduledPairCount
                            == previous.scheduledPairCount else {
                        throw Error.invalidPairGraph
                    }
                } else {
                    guard previous.matcher == .faiss,
                          attempt.matcher == .exact,
                          previous.scheduledPairCount == attempt.scheduledPairCount,
                          PairGraphEvidenceStore.permitsExactMatcherTransition(
                              after: previous,
                              reason: attempt.exactRecoveryReason,
                              imageCount: totalViewCount,
                              pairingPolicy: pairingPolicy
                          ) else {
                        throw Error.invalidPairGraph
                    }
                }
            } else {
                guard attempt.matcher == .faiss,
                      previous.matcher == .faiss else {
                    throw Error.invalidPairGraph
                }
            }
        }
    }

    private static func pairRecoveryLevelIndex(_ level: PairGraphRecoveryLevel) -> Int {
        switch level {
        case .normal: return 0
        case .expanded: return 1
        case .maximum: return 2
        }
    }

    private static func isOrdered(_ policy: ResolvedPairingPolicy) -> Bool {
        switch policy {
        case .orderedContinuous,
             .orderedOrbit,
             .orderedWalkthrough,
             .orderedLargeArea:
            return true
        case .unorderedRetrieval, .segmentedMixed:
            return false
        }
    }

    private static func validateMapping(
        _ artifact: MappingArtifact,
        totalViewCount: Int,
        registeredViewCount: Int,
        pairGraphStatus: PairGraphMeasurementStatus,
        hasLearnedProvenance: Bool,
        canonicalModelHashes: [String: String],
        canonicalModelURL: URL,
        projectPaths: ProjectPaths
    ) throws {
        let fallbackIsValid = artifact.fallbackReason.map { reason in
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed == reason
                && reason.utf8.count <= maximumMappingFallbackReasonBytes
                && reason.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        } ?? true
        guard artifact.modelCount >= 1,
              artifact.modelCount <= artifact.unionRegisteredViewCount,
              artifact.largestModelRegisteredViewCount >= registeredViewCount,
              artifact.largestModelRegisteredViewCount >= 1,
              artifact.unionRegisteredViewCount >= artifact.largestModelRegisteredViewCount,
              artifact.unionRegisteredViewCount <= totalViewCount,
              artifact.attemptCount >= 1,
              artifact.acceptedMappingAttemptOrdinal >= 1,
              artifact.acceptedMappingAttemptOrdinal <= artifact.attemptCount,
              artifact.acceptedRefinementInvocationCount >= 0,
              fallbackIsValid,
              artifact.attemptCount == 1 || artifact.fallbackReason != nil else {
            throw Error.invalidMapping
        }

        let publication = artifact.canonicalModelPublication
        let sourceNames = Set(publication.sourceModelHashes.keys)
        guard publication.sourceModelHashes.values.allSatisfy(isSHA256) else {
            throw Error.invalidMapping
        }
        switch publication.kind {
        case .convertedFromBinary:
            guard sourceNames == ["cameras.bin", "images.bin", "points3D.bin"],
                  let conversion = publication.conversion,
                  conversion.invocationOrdinal > 0,
                  let sourceDigest = modelClosureDigest(
                      publication.sourceModelHashes,
                      expectedNames: ["cameras.bin", "images.bin", "points3D.bin"]
                  ),
                  conversion.workerEvidence.sourceModelDigest == sourceDigest,
                  conversion.workerEvidence.convertedModelDigest
                    == modelClosureDigest(
                        canonicalModelHashes,
                        expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
                    ),
                  conversion.workerEvidence.candidateIdentitySHA256
                    == modelCandidateIdentity(
                        mappingAttemptOrdinal: artifact.acceptedMappingAttemptOrdinal,
                        candidateProjectRelativePath:
                            conversion.workerEvidence.candidateProjectRelativePath,
                        sourceModelDigest: sourceDigest
                    ),
                  validConversionPaths(
                      conversion.workerEvidence,
                      projectPaths: projectPaths
                  ) else {
                throw Error.invalidMapping
            }
            for name in ["cameras.bin", "images.bin", "points3D.bin"] {
                let binary = canonicalModelURL.appendingPathComponent(name)
                guard let expected = publication.sourceModelHashes[name],
                      let digest = try? sha256(of: binary),
                      digest == expected else {
                    throw Error.invalidMapping
                }
            }
        case .directText, .resumedCanonicalText:
            guard sourceNames == ["cameras.txt", "images.txt", "points3D.txt"],
                  publication.sourceModelHashes == canonicalModelHashes,
                  publication.conversion == nil else {
                throw Error.invalidMapping
            }
        }

        if artifact.modelCount == 1 {
            guard artifact.largestModelRegisteredViewCount == registeredViewCount,
                  artifact.secondLargestModelRegisteredViewCount == 0,
                  artifact.unionRegisteredViewCount
                    == artifact.largestModelRegisteredViewCount else {
                throw Error.invalidMapping
            }
        } else {
            guard artifact.secondLargestModelRegisteredViewCount >= 1,
                  artifact.secondLargestModelRegisteredViewCount
                    <= artifact.largestModelRegisteredViewCount else {
                throw Error.invalidMapping
            }
            if artifact.modelCount == 2 {
                guard registeredViewCount == artifact.largestModelRegisteredViewCount
                        || registeredViewCount
                            == artifact.secondLargestModelRegisteredViewCount else {
                    throw Error.invalidMapping
                }
            } else if registeredViewCount
                > artifact.secondLargestModelRegisteredViewCount {
                guard registeredViewCount == artifact.largestModelRegisteredViewCount else {
                    throw Error.invalidMapping
                }
            }
        }

        switch artifact.acceptedRefinementKind {
        case .incrementalGlobal:
            guard !hasLearnedProvenance,
                  pairGraphStatus == .measured,
                  let plannedCadence = artifact.plannedIncrementalCadence,
                  let cadence = artifact.incrementalCadence,
                  plannedCadence.isValid,
                  cadence.isValid,
                  IncrementalMappingCadencePolicy.validates(
                    planned: plannedCadence,
                    accepted: cadence,
                    trigger: artifact.cadenceFallbackTrigger
                  ) else {
                throw Error.invalidMapping
            }
        case .seededBundleAdjustment:
            // Two producers publish seeded refinements: the DA3 route (learned
            // runtime and model provenance) and the imported-pose dataset route
            // (classical provenance with a trusted external seed). The worker
            // execution ledger separately pins this kind to exactly one
            // point_triangulator and one bundle_adjuster invocation with no
            // incremental mapper, so learned provenance is not required here.
            guard pairGraphStatus == .measured,
                  artifact.modelCount == 1,
                  artifact.acceptedRefinementInvocationCount == 1,
                  artifact.plannedIncrementalCadence == nil,
                  artifact.incrementalCadence == nil,
                  artifact.cadenceFallbackTrigger == nil else {
                throw Error.invalidMapping
            }
        }
    }

    private static func validConversionPaths(
        _ evidence: ColmapModelConversionWorkerEvidence,
        projectPaths: ProjectPaths
    ) -> Bool {
        let sparsePrefix = "SfM/colmap/sparse/"
        let candidateSuffix = evidence.candidateProjectRelativePath
            .dropFirst(sparsePrefix.count)
        guard evidence.candidateProjectRelativePath.hasPrefix(sparsePrefix),
              !candidateSuffix.isEmpty,
              candidateSuffix.allSatisfy(\.isNumber),
              evidence.inputProjectRelativePath.hasPrefix(
                  sparsePrefix + ".text-model-"
              ),
              evidence.inputProjectRelativePath.hasSuffix("/binary"),
              evidence.outputProjectRelativePath.hasPrefix(
                  sparsePrefix + ".text-model-"
              ),
              evidence.outputProjectRelativePath.hasSuffix("/text"),
              evidence.inputProjectRelativePath.dropLast("binary".count)
                == evidence.outputProjectRelativePath.dropLast("text".count),
              (try? projectPaths.resolveProjectRelativePath(
                  evidence.candidateProjectRelativePath
              )) != nil,
              (try? projectPaths.resolveProjectRelativePath(
                  evidence.inputProjectRelativePath
              )) != nil,
              (try? projectPaths.resolveProjectRelativePath(
                  evidence.outputProjectRelativePath
              )) != nil else {
            return false
        }
        return true
    }

    private static func validateCanonicalOrientation(
        _ artifact: CanonicalOrientationArtifact,
        registeredViewCount: Int
    ) throws {
        switch artifact.status {
        case .unresolved:
            guard artifact.sourceToCanonicalQuaternionWXYZ == nil,
                  let direction = artifact.canonicalOpeningViewDirection,
                  validUnitDirection(direction),
                  (artifact.method == nil) == (artifact.evidence == nil) else {
                throw Error.invalidCanonicalOrientation
            }
            if let evidence = artifact.evidence {
                try validateOrientationEvidence(evidence, registeredViewCount: registeredViewCount)
            }
        case .verified, .axisAlignedSignUnverified:
            guard let method = artifact.method,
                  let quaternion = artifact.sourceToCanonicalQuaternionWXYZ,
                  quaternion.isCanonicalUnitRotation,
                  let evidence = artifact.evidence,
                  let direction = artifact.canonicalOpeningViewDirection,
                  validUnitDirection(direction) else {
                throw Error.invalidCanonicalOrientation
            }
            try validateOrientationEvidence(evidence, registeredViewCount: registeredViewCount)
            guard evidence.trajectoryPlaneAgreementDegrees.map({ $0 <= 15 }) ?? true else {
                throw Error.invalidCanonicalOrientation
            }
            switch method {
            case .cameraRightNullspace:
                guard evidence.supportCount >= 8,
                      evidence.eigenvalue1 >= 0.03,
                      evidence.eigengap >= 25,
                      evidence.medianResidualDegrees <= 3,
                      evidence.bootstrapP95VariationDegrees <= 5 else {
                    throw Error.invalidCanonicalOrientation
                }
                guard evidence.cameraUpConcentration == nil,
                      evidence.cameraUpMedianSpreadDegrees == nil,
                      evidence.cameraUpP90SpreadDegrees == nil,
                      evidence.trajectoryPlaneAgreementDegrees.map({ $0 <= 15 }) ?? true else {
                    throw Error.invalidCanonicalOrientation
                }
                if artifact.status == .verified {
                    guard evidence.p90ResidualDegrees <= 8,
                          let medianAgreement = evidence.medianAbsoluteImageUpAgreement,
                          medianAgreement >= 0.20,
                          let signAgreement = evidence.signAgreement,
                          signAgreement >= 0.75,
                          evidence.trajectoryPlaneAgreementDegrees.map({ $0 <= 15 }) ?? true else {
                        throw Error.invalidCanonicalOrientation
                    }
                } else {
                    // Two ways to land here: the strict gate passed but the sign
                    // was ambiguous, or only the p90 residual tail missed (the
                    // relaxed tier, which keeps its best sign guess).
                    guard let medianAgreement = evidence.medianAbsoluteImageUpAgreement,
                          let signAgreement = evidence.signAgreement else {
                        throw Error.invalidCanonicalOrientation
                    }
                    let strictWithAmbiguousSign = evidence.p90ResidualDegrees <= 8
                        && (medianAgreement < 0.20 || signAgreement < 0.75)
                    let relaxedResidualTail = evidence.p90ResidualDegrees > 8
                        && evidence.p90ResidualDegrees <= 15
                    guard strictWithAmbiguousSign || relaxedResidualTail else {
                        throw Error.invalidCanonicalOrientation
                    }
                }
            case .cameraUpConsensus:
                guard artifact.status == .verified,
                      evidence.supportCount >= 8,
                      (evidence.eigenvalue1 < 0.03 || evidence.eigengap < 25),
                      let lineConcentration = evidence.trajectoryLineConcentration,
                      lineConcentration >= 0.90,
                      let concentration = evidence.cameraUpConcentration,
                      concentration >= 0.90,
                      let medianSpread = evidence.cameraUpMedianSpreadDegrees,
                      medianSpread <= 10,
                      let p90Spread = evidence.cameraUpP90SpreadDegrees,
                      p90Spread <= 20,
                      evidence.bootstrapP95VariationDegrees <= 5 else {
                    throw Error.invalidCanonicalOrientation
                }
            }
        }
    }

    static func isCanonicalOrientationValid(
        _ artifact: CanonicalOrientationArtifact,
        registeredViewCount: Int
    ) -> Bool {
        do {
            try validateCanonicalOrientation(
                artifact,
                registeredViewCount: registeredViewCount
            )
            return true
        } catch {
            return false
        }
    }

    private static func validateOrientationEvidence(
        _ evidence: CanonicalOrientationEvidence,
        registeredViewCount: Int
    ) throws {
        let finiteValues = [
            evidence.eigenvalue0,
            evidence.eigenvalue1,
            evidence.eigenvalue2,
            evidence.eigengap,
            evidence.medianResidualDegrees,
            evidence.p90ResidualDegrees,
            evidence.bootstrapP95VariationDegrees,
        ]
        guard finiteValues.allSatisfy(\.isFinite),
              evidence.supportCount > 0,
              evidence.supportCount <= registeredViewCount,
              evidence.eigenvalue0 >= 0,
              evidence.eigenvalue0 <= evidence.eigenvalue1,
              evidence.eigenvalue1 <= evidence.eigenvalue2,
              abs(evidence.eigenvalue0 + evidence.eigenvalue1 + evidence.eigenvalue2 - 1) <= 1e-6,
              evidence.eigengap >= 0,
              approximatelyEqual(
                  evidence.eigengap,
                  evidence.eigenvalue1 / max(evidence.eigenvalue0, 1e-9),
                  relativeTolerance: 1e-6
              ),
              evidence.medianResidualDegrees >= 0,
              evidence.p90ResidualDegrees >= evidence.medianResidualDegrees,
              evidence.bootstrapP95VariationDegrees >= 0,
              validUnitInterval(evidence.medianAbsoluteImageUpAgreement),
              validUnitInterval(evidence.signAgreement),
              validUnitInterval(evidence.trajectoryLineConcentration),
              validUnitInterval(evidence.cameraUpConcentration),
              validDegrees(evidence.trajectoryPlaneAgreementDegrees),
              validDegrees(evidence.cameraUpMedianSpreadDegrees),
              validDegrees(evidence.cameraUpP90SpreadDegrees) else {
            throw Error.invalidCanonicalOrientation
        }
    }

    private static func validUnitDirection(_ value: CanonicalDirection) -> Bool {
        let components = [value.x, value.y, value.z]
        guard components.allSatisfy(\.isFinite) else { return false }
        let squaredNorm = components.reduce(0) { $0 + $1 * $1 }
        return abs(squaredNorm - 1) <= 1e-6
    }

    private static func validUnitInterval(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 1
    }

    private static func validDegrees(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 180
    }

    private static func approximatelyEqual(
        _ first: Double,
        _ second: Double,
        relativeTolerance: Double
    ) -> Bool {
        abs(first - second) <= max(1e-9, max(abs(first), abs(second)) * relativeTolerance)
    }

    static func inputDigest(projectPaths: ProjectPaths) throws -> String {
        let files = try regularFiles(recursivelyUnder: projectPaths.originalsURL)
        return try digest(files: files, relativeTo: projectPaths.originalsURL, preserveOrder: false)
    }

    static func inputDigest(
        snapshots: [RuntimeInputSnapshotLease.Snapshot]
    ) throws -> String {
        guard !snapshots.isEmpty,
              Set(snapshots.map(\.projectRelativePath)).count == snapshots.count,
              snapshots.allSatisfy({
                  $0.projectRelativePath.hasPrefix("Originals/")
                      && $0.projectRelativePath.count > "Originals/".count
              }) else {
            throw Error.artifactDigestMismatch("digest input")
        }
        let ordered = snapshots.sorted {
            $0.projectRelativePath < $1.projectRelativePath
        }
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat geometry digest v2".utf8))
        for snapshot in ordered {
            let relativePath = String(
                snapshot.projectRelativePath.dropFirst("Originals/".count)
            )
            update(UInt64(relativePath.utf8.count), in: &hasher)
            hasher.update(data: Data(relativePath.utf8))
            try hashRegularFileContents(at: snapshot.url, into: &hasher) {
                fileSize, hasher in
                update(fileSize, in: &hasher)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func selectedFramesDigest(
        orderedImageNames: [String],
        projectPaths: ProjectPaths
    ) throws -> String {
        guard Set(orderedImageNames).count == orderedImageNames.count,
              orderedImageNames.allSatisfy({
                  !$0.isEmpty
                      && !$0.contains("/")
                      && !$0.contains("\\")
                      && $0 != "."
                      && $0 != ".."
              }) else {
            throw Error.artifactDigestMismatch("selected frame names")
        }
        let selectedFiles = try regularFiles(recursivelyUnder: projectPaths.framesSelectedURL)
        guard Set(selectedFiles.map(\.lastPathComponent)) == Set(orderedImageNames),
              selectedFiles.count == orderedImageNames.count else {
            throw Error.artifactDigestMismatch("selected frames")
        }
        let files = try orderedImageNames.map { name in
            try projectPaths.resolveProjectRelativePath("Frames/selected/\(name)")
        }
        return try digest(
            files: files,
            relativeTo: projectPaths.framesSelectedURL,
            preserveOrder: true
        )
    }

    private static func regularFiles(recursivelyUnder root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func digest(
        files: [URL],
        relativeTo root: URL,
        preserveOrder: Bool
    ) throws -> String {
        guard !files.isEmpty else { throw Error.artifactDigestMismatch("digest input") }
        let orderedFiles = preserveOrder ? files : files.sorted { $0.path < $1.path }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat geometry digest v2".utf8))
        for file in orderedFiles {
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPath + "/") else {
                throw Error.artifactDigestMismatch("path root")
            }
            let relativePath = String(resolved.path.dropFirst(rootPath.count + 1))
            update(UInt64(relativePath.utf8.count), in: &hasher)
            hasher.update(data: Data(relativePath.utf8))
            try hashRegularFileContents(at: file, into: &hasher) { fileSize, hasher in
                update(fileSize, in: &hasher)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ value: UInt64, in hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 1e-9
    }

    static func sha256(of file: URL, maximumBytes: UInt64? = nil) throws -> String {
        var hasher = SHA256()
        try hashRegularFileContents(
            at: file,
            into: &hasher,
            maximumBytes: maximumBytes
        )
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashRegularFileContents(
        at file: URL,
        into hasher: inout SHA256,
        maximumBytes: UInt64? = nil,
        beforeContents: (UInt64, inout SHA256) -> Void = { _, _ in }
    ) throws {
        let descriptor: Int32
        while true {
            let opened = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if opened >= 0 {
                descriptor = opened
                break
            }
            let code = errno
            if code == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { Darwin.close(descriptor) }

        func descriptorStatus() throws -> stat {
            while true {
                var status = stat()
                if Darwin.fstat(descriptor, &status) == 0 { return status }
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }

        let initial = try descriptorStatus()
        guard (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size >= 0,
              maximumBytes.map({ UInt64(initial.st_size) <= $0 }) ?? true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let expectedByteCount = UInt64(initial.st_size)
        beforeContents(expectedByteCount, &hasher)

        var totalByteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            if count == 0 { break }
            guard totalByteCount <= expectedByteCount,
                  UInt64(count) <= expectedByteCount - totalByteCount else {
                throw CocoaError(.fileReadUnknown)
            }
            hasher.update(data: Data(buffer[0..<count]))
            totalByteCount += UInt64(count)
        }

        let final = try descriptorStatus()
        guard (final.st_mode & S_IFMT) == S_IFREG,
              final.st_nlink == 1,
              final.st_size >= 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              totalByteCount == expectedByteCount else {
            throw CocoaError(.fileReadUnknown)
        }
    }
}
