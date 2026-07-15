import CryptoKit
import Darwin
import Foundation

enum GeometryArtifactStore {
    static let maximumManifestBytes = 1_048_576
    static let maximumMedianPixelResidual = 1.5
    static let maximumP90PixelResidual = 3.0
    static let minimumLearnedObservationsPerView = 20

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
        case learnedInitializerDigestMismatch
        case invalidPairGraph
        case invalidCanonicalOrientation
        case invalidTimings

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
            case .learnedInitializerDigestMismatch:
                return "Learned point initialization no longer matches accepted geometry."
            case .invalidPairGraph:
                return "Geometry artifact pair-graph evidence is incomplete or inconsistent."
            case .invalidCanonicalOrientation:
                return "Geometry artifact orientation evidence is incomplete or inconsistent."
            case .invalidTimings:
                return "Geometry artifact timing evidence is incomplete or invalid."
            }
        }
    }

    static func load(from url: URL, projectPaths: ProjectPaths) throws -> GeometryArtifact {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        let envelope = try JSONDecoder().decode(SchemaVersionEnvelope.self, from: data)
        guard envelope.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw Error.invalidSchema(envelope.schemaVersion)
        }
        let artifact = try JSONDecoder().decode(GeometryArtifact.self, from: data)
        try validate(artifact, projectPaths: projectPaths)
        return artifact
    }

    private struct SchemaVersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func persist(
        _ artifact: GeometryArtifact,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil,
        verifiedSourceSnapshot: GeometryModelSnapshot.Verified? = nil
    ) throws {
        try validate(
            artifact,
            projectPaths: paths,
            measuredResiduals: measuredResiduals,
            verifiedSourceSnapshot: verifiedSourceSnapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        guard data.count <= maximumManifestBytes else { throw Error.manifestTooLarge }
        let previousManifest: Data?
        do {
            previousManifest = try BoundedFileReader.readRegularFile(
                at: paths.geometryManifestURL,
                maximumBytes: maximumManifestBytes
            )
        } catch where BoundedFileReader.isMissingFileError(error) {
            previousManifest = nil
        }
        try data.write(to: paths.geometryManifestURL, options: [.atomic])

        let previousArtifact = metadata.geometryArtifact
        do {
            if let verifiedSourceSnapshot {
                let sourceModel = try paths.resolveProjectRelativePath(artifact.sourceModelPath)
                do {
                    try GeometryModelSnapshot.validate(
                        verifiedSourceSnapshot,
                        at: sourceModel
                    )
                } catch {
                    throw Error.modelHashMismatch("source snapshot")
                }
            }
            metadata.geometryArtifact = artifact
            try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        } catch {
            metadata.geometryArtifact = previousArtifact
            if let previousManifest {
                try? previousManifest.write(to: paths.geometryManifestURL, options: [.atomic])
            } else {
                try? FileManager.default.removeItem(at: paths.geometryManifestURL)
            }
            throw error
        }
    }

    static func validate(
        _ artifact: GeometryArtifact,
        projectPaths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil,
        verifiedSourceSnapshot: GeometryModelSnapshot.Verified? = nil
    ) throws {
        guard artifact.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw Error.invalidSchema(artifact.schemaVersion)
        }
        let provenance = artifact.provenance
        guard !artifact.solverVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artifact.runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artifact.modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provenance.toolchainVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provenance.solver.identifier == "colmap",
              validComponent(provenance.solver),
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
        guard artifact.residualProvenance == "colmap-text-tracks-v1",
              artifact.trackCount > 0,
              artifact.pointCount > 0,
              artifact.totalViewCount > 0,
              artifact.registeredViewCount > 0,
              artifact.registeredViewCount <= artifact.totalViewCount,
              Double(artifact.registeredViewCount) / Double(artifact.totalViewCount)
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
        try validatePairGraph(artifact.pairGraph, totalViewCount: artifact.totalViewCount)
        try validateCanonicalOrientation(
            artifact.canonicalOrientation,
            registeredViewCount: artifact.registeredViewCount
        )
        guard Set(artifact.modelHashes.keys) == ["cameras.txt", "images.txt", "points3D.txt"],
              artifact.modelHashes.values.allSatisfy(isSHA256) else {
            throw Error.invalidDigest("model")
        }
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

        let measured = try measuredResiduals
            ?? ColmapResidualAnalyzer.analyze(modelDirectory: sourceModel)
        let stronglyMeasuredViewCount = measured.observationCountByImage.values.filter {
            $0 >= minimumLearnedObservationsPerView
        }.count
        let learnedSupportIsValid = artifact.learnedPointInitializer == nil
            || Double(stronglyMeasuredViewCount) / Double(artifact.totalViewCount)
                >= ReconstructionScorer.minimumRegisteredViewFraction
        guard measured.provenance == artifact.residualProvenance,
              measured.registeredViewCount == artifact.registeredViewCount,
              Set(measured.registeredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Set(measured.measuredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Double(measured.measuredImageNames.count) / Double(artifact.totalViewCount)
                  >= ReconstructionScorer.minimumRegisteredViewFraction,
              learnedSupportIsValid,
              measured.pointCount == artifact.pointCount,
              measured.observationCount == artifact.trackCount,
              approximatelyEqual(measured.medianPixelResidual, artifact.medianPixelResidual),
              approximatelyEqual(measured.p90PixelResidual, artifact.p90PixelResidual) else {
            throw Error.measuredResidualMismatch
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func validComponent(_ component: GeometryComponentProvenance) -> Bool {
        !component.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !component.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !component.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isSHA256(component.payloadSHA256)
    }

    private static func validatePairGraph(
        _ artifact: PairGraphArtifact,
        totalViewCount: Int
    ) throws {
        guard artifact.mappingAttemptNumber > 0,
              artifact.bundleAdjustmentCycleCount > 0,
              artifact.fallbackReason.map({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) ?? true else {
            throw Error.invalidPairGraph
        }
        switch artifact.status {
        case .notEvaluated:
            guard artifact.measurement == nil else { throw Error.invalidPairGraph }
        case .measured:
            guard let measurement = artifact.measurement,
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
                  measurement.localPairCount
                    + measurement.retrievalPairCount
                    + measurement.loopRevisitPairCount
                    == measurement.scheduledPairCount,
                  measurement.connectedComponentCount == 1,
                  measurement.isolatedViewCount == 0,
                  measurement.spatiallyVerifiedPairCount >= max(0, totalViewCount - 1),
                  measurement.degreeP10 >= 0,
                  measurement.degreeP10 <= measurement.degreeMedian,
                  measurement.degreeMedian <= measurement.degreeP90,
                  measurement.degreeP90 < totalViewCount,
                  !measurement.matcherAttempts.isEmpty,
                  isSHA256(measurement.pairListDigest),
                  isSHA256(measurement.featureDatabaseDigest),
                  isSHA256(measurement.matchingDatabaseDigest),
                  measurement.matchingDurationSeconds.isFinite,
                  measurement.matchingDurationSeconds >= 0 else {
                throw Error.invalidPairGraph
            }
            let attemptNumbers = measurement.matcherAttempts.map(\.attemptNumber)
            let measuredDuration = measurement.matcherAttempts.reduce(0.0) {
                $0 + $1.durationSeconds
            }
            guard Set(attemptNumbers).count == attemptNumbers.count,
                  attemptNumbers.sorted() == Array(1...attemptNumbers.count),
                  measurement.matcherAttempts.allSatisfy({ attempt in
                      attempt.scheduledPairCount >= 0
                          && attempt.attemptedPairCount >= 0
                          && attempt.attemptedPairCount <= attempt.scheduledPairCount
                          && attempt.rawMatchedPairCount >= 0
                          && attempt.rawMatchedPairCount <= attempt.attemptedPairCount
                          && attempt.spatiallyVerifiedPairCount >= 0
                          && attempt.spatiallyVerifiedPairCount <= attempt.rawMatchedPairCount
                          && attempt.durationSeconds.isFinite
                          && attempt.durationSeconds >= 0
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
        }
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
                  validUnitQuaternion(quaternion),
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
                      evidence.p90ResidualDegrees <= 8,
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
                    guard let medianAgreement = evidence.medianAbsoluteImageUpAgreement,
                          medianAgreement >= 0.20,
                          let signAgreement = evidence.signAgreement,
                          signAgreement >= 0.75,
                          evidence.trajectoryPlaneAgreementDegrees.map({ $0 <= 15 }) ?? true else {
                        throw Error.invalidCanonicalOrientation
                    }
                } else {
                    guard let medianAgreement = evidence.medianAbsoluteImageUpAgreement,
                          let signAgreement = evidence.signAgreement,
                          medianAgreement < 0.20 || signAgreement < 0.75 else {
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

    private static func validUnitQuaternion(_ value: CanonicalQuaternionWXYZ) -> Bool {
        let components = [value.w, value.x, value.y, value.z]
        guard components.allSatisfy(\.isFinite) else { return false }
        let squaredNorm = components.reduce(0) { $0 + $1 * $1 }
        guard abs(squaredNorm - 1) <= 1e-6 else { return false }
        if value.w > 0 { return true }
        if value.w < 0 { return false }
        for component in [value.x, value.y, value.z] where component != 0 {
            return component > 0
        }
        return false
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

    static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        try hashRegularFileContents(at: file, into: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashRegularFileContents(
        at file: URL,
        into hasher: inout SHA256,
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
              initial.st_size >= 0 else {
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
