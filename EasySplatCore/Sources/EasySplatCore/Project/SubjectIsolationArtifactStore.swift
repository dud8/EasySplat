import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IsolationArtifactStaleReason: String, Sendable, Equatable {
    case sourceOutput
    case trainingManifest
    case datasetIdentity
}

public enum IsolationArtifactLoadResult: Sendable, Equatable {
    case noArtifact
    case valid(IsolationArtifact, ValidatedSplatOutput)
    case stale(IsolationArtifactStaleReason)
    case invalid
}

public enum SubjectIsolationArtifactStoreError: Error, LocalizedError, Equatable {
    case invalidArtifact
    case publicationConflict
    case canonicalPublicationUnchanged

    public var errorDescription: String? {
        switch self {
        case .invalidArtifact:
            "The subject-isolation artifact is invalid."
        case .publicationConflict:
            "The subject-isolation artifact changed during publication."
        case .canonicalPublicationUnchanged:
            "The canonical splat publication has not changed since subject isolation."
        }
    }
}

public enum SubjectIsolationArtifactStore {
    private static let maximumManifestBytes = 1_048_576
    private static let maximumMaskBytes = 64 * 1_048_576
    private static let maximumIdentityBytes = 1_024

    public static func load(paths: ProjectPaths) -> IsolationArtifactLoadResult {
        let fileManager = FileManager.default
        let manifestExists = fileManager.fileExists(atPath: paths.isolationManifestURL.path)
            || (try? fileManager.destinationOfSymbolicLink(
                atPath: paths.isolationManifestURL.path
            )) != nil
        if !manifestExists {
            let outputExists = fileManager.fileExists(atPath: paths.isolatedOutputURL.path)
                || (try? fileManager.destinationOfSymbolicLink(
                    atPath: paths.isolatedOutputURL.path
                )) != nil
            return outputExists ? .invalid : .noArtifact
        }

        do {
            let artifact = try loadManifest(paths: paths)
            if let stale = try staleReason(for: artifact, paths: paths) {
                return .stale(stale)
            }
            let output = try validatePublishedFiles(artifact, paths: paths)
            guard try loadManifest(paths: paths) == artifact else {
                return .invalid
            }
            return .valid(artifact, output)
        } catch {
            return .invalid
        }
    }

    @discardableResult
    public static func publish(
        _ artifact: IsolationArtifact,
        stagedOutputURL: URL,
        stagedMasksURL: URL,
        paths: ProjectPaths,
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ValidatedSplatOutput {
        try throwIfCancelled(shouldCancel)
        try paths.ensureIsolationDirectories()
        try validateManifest(artifact, paths: paths)
        guard try staleReason(
            for: artifact,
            paths: paths,
            shouldCancel: shouldCancel
        ) == nil else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try validateStagingLocation(
            output: stagedOutputURL,
            masks: stagedMasksURL,
            paths: paths
        )

        let stagedOutput = try ProjectArtifactValidator.validatedPlyEvidence(
            at: stagedOutputURL,
            shouldCancel: shouldCancel
        )
        try requireOutput(stagedOutput, matches: artifact.output)
        let stagedMaskURLs = try stagedMaskFiles(at: stagedMasksURL)
        guard stagedMaskURLs.count == artifact.masks.count else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for (mask, url) in zip(artifact.masks, stagedMaskURLs) {
            try validateMask(mask, at: url, shouldCancel: shouldCancel)
        }

        let manifestData = try encodedManifest(artifact)
        let outputTemporary = paths.outputURL.appendingPathComponent(
            ".isolated.\(UUID().uuidString).pending"
        )
        let manifestTemporary = paths.isolationURL.appendingPathComponent(
            ".isolation_manifest.\(UUID().uuidString).pending"
        )
        var publishedMaskURLs: [URL] = []
        var outputBackup: URL?
        var manifestBackup: URL?
        var outputWasPublished = false
        var manifestWasPublished = false
        var transactionCommitted = false

        defer {
            if !transactionCommitted {
                try? rollbackPublishedFile(
                    destination: paths.isolationManifestURL,
                    backup: manifestBackup,
                    newWasPublished: manifestWasPublished
                )
                try? rollbackPublishedFile(
                    destination: paths.isolatedOutputURL,
                    backup: outputBackup,
                    newWasPublished: outputWasPublished
                )
                for url in publishedMaskURLs {
                    try? removePrivateRegularFileIfPresent(url)
                }
                try? synchronizeDirectory(paths.isolationMasksURL)
            }
            try? removePrivateRegularFileIfPresent(outputTemporary)
            try? removePrivateRegularFileIfPresent(manifestTemporary)
        }

        for (mask, source) in zip(artifact.masks, stagedMaskURLs) {
            try throwIfCancelled(shouldCancel)
            let destination = try paths.resolveProjectRelativePath(mask.relativePath)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: destination.path
                  )) == nil else {
                throw SubjectIsolationArtifactStoreError.publicationConflict
            }
            try copyPrivateRegularFile(
                from: source,
                to: destination,
                maximumBytes: maximumMaskBytes,
                shouldCancel: shouldCancel
            )
            publishedMaskURLs.append(destination)
            try validateMask(mask, at: destination, shouldCancel: shouldCancel)
        }
        try throwIfCancelled(shouldCancel)
        try synchronizeDirectory(paths.isolationMasksURL)

        _ = try ProjectArtifactValidator.publishValidatedPly(
            from: stagedOutputURL,
            to: outputTemporary,
            expected: Optional(ExpectedPlyArtifactIdentity(
                byteCount: artifact.output.byteCount,
                vertexCount: artifact.output.gaussianCount,
                sha256: artifact.output.sha256
            )),
            systemCalls: .system(),
            shouldCancel: shouldCancel
        )
        try writePrivateFile(
            manifestData,
            to: manifestTemporary,
            shouldCancel: shouldCancel
        )
        try throwIfCancelled(shouldCancel)

        outputBackup = try moveAsideIfPresent(paths.isolatedOutputURL)
        try renameExclusive(outputTemporary, to: paths.isolatedOutputURL)
        outputWasPublished = true
        try synchronizeDirectory(paths.outputURL)
        try throwIfCancelled(shouldCancel)

        manifestBackup = try moveAsideIfPresent(paths.isolationManifestURL)
        try renameExclusive(manifestTemporary, to: paths.isolationManifestURL)
        manifestWasPublished = true
        try synchronizeDirectory(paths.isolationURL)

        try throwIfCancelled(shouldCancel)
        let validated = try validatePublishedFiles(
            artifact,
            paths: paths,
            shouldCancel: shouldCancel
        )
        guard try loadManifest(paths: paths) == artifact else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        transactionCommitted = true
        if let outputBackup {
            try? removePrivateRegularFileIfPresent(outputBackup)
            try? synchronizeDirectory(paths.outputURL)
        }
        if let manifestBackup {
            let previousMasks = (try? loadManifest(from: manifestBackup, paths: paths))?.masks ?? []
            try? removePrivateRegularFileIfPresent(manifestBackup)
            for mask in previousMasks where !artifact.masks.contains(where: {
                $0.relativePath == mask.relativePath
            }) {
                if let url = try? paths.resolveProjectRelativePath(mask.relativePath) {
                    try? removePrivateRegularFileIfPresent(url)
                }
            }
            try? synchronizeDirectory(paths.isolationURL)
            try? synchronizeDirectory(paths.isolationMasksURL)
        }
        return validated
    }

    @discardableResult
    public static func removeValidatedSubject(paths: ProjectPaths) throws -> Bool {
        guard case .valid(let artifact, _) = load(paths: paths) else {
            return false
        }
        try removeValidated(artifact, paths: paths)
        return true
    }

    static func captureCanonicalPublication(
        paths: ProjectPaths
    ) throws -> CanonicalSplatPublication {
        let training = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        guard training.completionStatus == .completed,
              training.outputPath == "Output/splat.ply" else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.outputSplatURL
        )
        try TrainingArtifactStore.validateCompletedOutput(
            training,
            at: paths.outputSplatURL
        )
        let trainingManifest = try BoundedFileReader.readRegularFile(
            at: paths.trainingManifestURL,
            maximumBytes: maximumManifestBytes
        )
        return CanonicalSplatPublication(
            outputEvidence: outputEvidence,
            trainingManifestSHA256: sha256(trainingManifest),
            trainingInputDigest: training.inputDigest,
            trainingGeometryDigest: training.geometryDigest,
            selectedFramesDigest: training.datasetDerivation.sourceSelectedFramesDigest,
            selectedImageOrder: training.datasetDerivation.registeredImageNames
        )
    }

    /// Call only with a publication receipt captured after the replacement
    /// canonical PLY and its completed training receipt are durably persisted.
    @discardableResult
    public static func invalidateAfterCanonicalRetraining(
        paths: ProjectPaths,
        publication: CanonicalSplatPublication
    ) throws -> Bool {
        guard try captureCanonicalPublication(paths: paths) == publication else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        guard FileManager.default.fileExists(atPath: paths.isolationManifestURL.path) else {
            return false
        }
        let artifact = try loadManifest(paths: paths)
        guard artifact.sourcePlySHA256 != publication.outputEvidence.sha256
                || artifact.trainingManifestSHA256 != publication.trainingManifestSHA256
                || artifact.dataset.inputDigest != publication.trainingInputDigest
                || artifact.dataset.geometryDigest != publication.trainingGeometryDigest
                || artifact.dataset.selectedFramesDigest != publication.selectedFramesDigest
                || artifact.dataset.selectedImageOrder != publication.selectedImageOrder else {
            throw SubjectIsolationArtifactStoreError.canonicalPublicationUnchanged
        }
        _ = try validatePublishedFiles(artifact, paths: paths)
        try removeValidated(artifact, paths: paths)
        return true
    }

    private static func loadManifest(paths: ProjectPaths) throws -> IsolationArtifact {
        try loadManifest(from: paths.isolationManifestURL, paths: paths)
    }

    private static func loadManifest(
        from url: URL,
        paths: ProjectPaths
    ) throws -> IsolationArtifact {
        if url == paths.isolationManifestURL {
            _ = try paths.validateReservedProjectPath(
                url,
                relativePath: "Isolation/isolation_manifest.json"
            )
        } else {
            let relative = try paths.projectRelativePath(for: url)
            guard relative.hasPrefix("Isolation/.isolation_manifest."),
                  relative.hasSuffix(".pending")
                    || relative.contains(".previous.") else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        )
        guard !data.isEmpty else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireStrictSchema(data)
        let artifact = try JSONDecoder().decode(IsolationArtifact.self, from: data)
        try validateManifest(artifact, paths: paths)
        guard try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumManifestBytes
        ) == data else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return artifact
    }

    private static func validateManifest(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths
    ) throws {
        let dataset = artifact.dataset
        let selected = artifact.selectedViewIdentities
        let heldOut = artifact.heldOutViewIdentities
        let knownViews = Set(dataset.selectedImageOrder)
        guard artifact.schemaVersion == IsolationArtifact.currentSchemaVersion,
              isSHA256(artifact.sourcePlySHA256),
              isSHA256(artifact.trainingManifestSHA256),
              isSHA256(dataset.inputDigest),
              isSHA256(dataset.geometryDigest),
              isSHA256(dataset.selectedFramesDigest),
              !dataset.selectedImageOrder.isEmpty,
              Set(dataset.selectedImageOrder).count == dataset.selectedImageOrder.count,
              dataset.selectedImageOrder.allSatisfy(isSafeIdentity),
              !artifact.masks.isEmpty,
              artifact.masks.count <= IsolationArtifact.maximumMaskCount,
              !artifact.toolchainBuildIdentity.isEmpty,
              artifact.toolchainBuildIdentity.utf8.count <= maximumIdentityBytes,
              isSHA256(artifact.nativeExecutableSHA256),
              artifact.visionRequestRevision > 0,
              !selected.isEmpty,
              Set(selected).count == selected.count,
              Set(heldOut).count == heldOut.count,
              Set(selected).isDisjoint(with: Set(heldOut)),
              selected.allSatisfy(knownViews.contains),
              heldOut.allSatisfy(knownViews.contains),
              validPolicy(artifact.policy),
              validMetrics(artifact.metrics, policy: artifact.policy),
              artifact.output.relativePath == "Output/isolated.ply",
              isSHA256(artifact.output.sha256),
              artifact.output.byteCount > 0,
              artifact.output.gaussianCount > 0,
              artifact.output.sceneBounds.isValid else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        _ = try paths.resolveProjectRelativePath(artifact.output.relativePath)

        if let anchor = artifact.subjectAnchor {
            guard knownViews.contains(anchor.imageIdentity),
                  anchor.normalizedX.isFinite,
                  anchor.normalizedY.isFinite,
                  (0...1).contains(anchor.normalizedX),
                  (0...1).contains(anchor.normalizedY) else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }

        var maskPaths = Set<String>()
        var maskViews = Set<String>()
        for mask in artifact.masks {
            guard maskPaths.insert(mask.relativePath).inserted,
                  maskViews.insert(mask.imageIdentity).inserted,
                  knownViews.contains(mask.imageIdentity),
                  isSHA256(mask.imageSHA256),
                  isSHA256(mask.maskSHA256),
                  mask.pixelWidth > 0,
                  mask.pixelWidth <= IsolationArtifact.maximumMaskDimension,
                  mask.pixelHeight > 0,
                  mask.pixelHeight <= IsolationArtifact.maximumMaskDimension,
                  mask.pixelWidth.multipliedReportingOverflow(
                    by: mask.pixelHeight
                  ).overflow == false,
                  mask.pixelWidth * mask.pixelHeight
                    <= IsolationArtifact.maximumDecodedMaskPixelCount,
                  mask.backgroundLabel == 0,
                  mask.subjectLabel > 0 else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            let resolved = try paths.resolveProjectRelativePath(mask.relativePath)
            guard mask.relativePath.hasPrefix("Isolation/masks/"),
                  resolved.deletingLastPathComponent().path == paths.isolationMasksURL.path,
                  resolved.pathExtension.lowercased() == "png" else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
        }
    }

    private static func staleReason(
        for artifact: IsolationArtifact,
        paths: ProjectPaths,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> IsolationArtifactStaleReason? {
        try throwIfCancelled(shouldCancel)
        let source = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.outputSplatURL,
            shouldCancel: shouldCancel
        )
        guard source.sha256 == artifact.sourcePlySHA256 else {
            return .sourceOutput
        }
        let trainingData = try BoundedFileReader.readRegularFile(
            at: paths.trainingManifestURL,
            maximumBytes: maximumManifestBytes,
            shouldCancel: shouldCancel
        )
        guard sha256(trainingData) == artifact.trainingManifestSHA256 else {
            return .trainingManifest
        }
        let training = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        guard artifact.dataset.inputDigest == training.inputDigest,
              artifact.dataset.geometryDigest == training.geometryDigest,
              artifact.dataset.selectedFramesDigest
                == training.datasetDerivation.sourceSelectedFramesDigest,
              artifact.dataset.selectedImageOrder
                == training.datasetDerivation.registeredImageNames else {
            return .datasetIdentity
        }
        let imageDirectory = try paths.resolveProjectRelativePath(
            "Training/msplat_dataset/images"
        )
        for mask in artifact.masks {
            try throwIfCancelled(shouldCancel)
            let imageURL = imageDirectory.appendingPathComponent(mask.imageIdentity)
            guard try GeometryArtifactStore.sha256(
                of: imageURL,
                maximumBytes: 512 * 1_048_576,
                shouldCancel: shouldCancel
            ) == mask.imageSHA256 else {
                return .datasetIdentity
            }
        }
        return nil
    }

    private static func validatePublishedFiles(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ValidatedSplatOutput {
        for mask in artifact.masks {
            try validateMask(
                mask,
                at: try paths.resolveProjectRelativePath(mask.relativePath),
                shouldCancel: shouldCancel
            )
        }
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.isolatedOutputURL,
            shouldCancel: shouldCancel
        )
        try requireOutput(evidence, matches: artifact.output)
        return ValidatedSplatOutput(
            variant: .subject,
            url: paths.isolatedOutputURL,
            sha256: evidence.sha256,
            byteCount: evidence.byteCount,
            gaussianCount: evidence.vertexCount,
            sceneBounds: evidence.sceneBounds
        )
    }

    private static func validateMask(
        _ mask: IsolationArtifact.Mask,
        at url: URL,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        beforeDecode: () -> Void = {}
    ) throws {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumMaskBytes,
            shouldCancel: shouldCancel
        )
        try throwIfCancelled(shouldCancel)
        guard try sha256(data, shouldCancel: shouldCancel) == mask.maskSHA256,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue == mask.pixelWidth,
              height.intValue == mask.pixelHeight,
              width.intValue > 0,
              width.intValue <= IsolationArtifact.maximumMaskDimension,
              height.intValue > 0,
              height.intValue <= IsolationArtifact.maximumMaskDimension,
              width.intValue.multipliedReportingOverflow(by: height.intValue).overflow == false,
              width.intValue * height.intValue
                <= IsolationArtifact.maximumDecodedMaskPixelCount else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try throwIfCancelled(shouldCancel)
        beforeDecode()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == mask.pixelWidth,
              image.height == mask.pixelHeight,
              image.bitsPerComponent == 8,
              image.colorSpace?.model == .monochrome,
              try containsOnlyExpectedLabels(
                image,
                background: mask.backgroundLabel,
                subject: mask.subjectLabel,
                shouldCancel: shouldCancel
              ) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func containsOnlyExpectedLabels(
        _ image: CGImage,
        background: UInt8,
        subject: UInt8,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        guard image.bitsPerPixel == 8,
              image.bytesPerRow >= image.width,
              let data = image.dataProvider?.data else {
            return false
        }
        let bytes = CFDataGetBytePtr(data)
        guard let bytes else { return false }
        var foundSubject = false
        for row in 0..<image.height {
            try throwIfCancelled(shouldCancel)
            let rowStart = row * image.bytesPerRow
            for column in 0..<image.width {
                let value = bytes[rowStart + column]
                guard value == background || value == subject else {
                    return false
                }
                foundSubject = foundSubject || value == subject
            }
        }
        return foundSubject
    }

#if DEBUG
    static func test_validateMask(
        _ mask: IsolationArtifact.Mask,
        at url: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        beforeDecode: () -> Void = {}
    ) throws {
        try validateMask(
            mask,
            at: url,
            shouldCancel: shouldCancel,
            beforeDecode: beforeDecode
        )
    }
#endif

    private static func requireOutput(
        _ evidence: ValidatedPlyArtifactEvidence,
        matches identity: IsolationArtifact.OutputIdentity
    ) throws {
        guard evidence.sha256 == identity.sha256,
              evidence.byteCount == identity.byteCount,
              evidence.vertexCount == identity.gaussianCount,
              SplatSceneBoundsCalculator.matches(
                evidence.sceneBounds,
                identity.sceneBounds
              ) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func removeValidated(
        _ artifact: IsolationArtifact,
        paths: ProjectPaths
    ) throws {
        _ = try validatePublishedFiles(artifact, paths: paths)
        try removePrivateRegularFileIfPresent(paths.isolationManifestURL)
        try synchronizeDirectory(paths.isolationURL)
        try removePrivateRegularFileIfPresent(paths.isolatedOutputURL)
        try synchronizeDirectory(paths.outputURL)
        for mask in artifact.masks {
            try removePrivateRegularFileIfPresent(
                try paths.resolveProjectRelativePath(mask.relativePath)
            )
        }
        try synchronizeDirectory(paths.isolationMasksURL)
        if FileManager.default.fileExists(atPath: paths.isolationURL.path) {
            try paths.validateRootDirectory()
            let values = try paths.isolationURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SubjectIsolationArtifactStoreError.invalidArtifact
            }
            try FileManager.default.removeItem(at: paths.isolationURL)
            try synchronizeDirectory(paths.root)
        }
    }

    private static func validateStagingLocation(
        output: URL,
        masks: URL,
        paths: ProjectPaths
    ) throws {
        let outputRelative = try paths.projectRelativePath(for: output)
        let masksRelative = try paths.projectRelativePath(for: masks)
        let outputParts = outputRelative.split(separator: "/")
        let maskParts = masksRelative.split(separator: "/")
        guard outputParts.count == 4,
              outputParts[0] == "Isolation",
              outputParts[1] == "staging",
              UUID(uuidString: String(outputParts[2])) != nil,
              outputParts[3] == "isolated.ply",
              maskParts.count == 4,
              maskParts[0] == "Isolation",
              maskParts[1] == "staging",
              maskParts[2] == outputParts[2],
              maskParts[3] == "masks" else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func stagedMaskFiles(at directory: URL) throws -> [URL] {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func encodedManifest(_ artifact: IsolationArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireStrictSchema(data)
        return data
    }

    private static func requireStrictSchema(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireKeys(
            root,
            required: [
                "schemaVersion", "sourcePlySHA256", "trainingManifestSHA256",
                "dataset", "masks", "toolchainBuildIdentity",
                "nativeExecutableSHA256", "visionRequestRevision",
                "selectedViewIdentities", "heldOutViewIdentities", "policy",
                "metrics", "output",
            ],
            optional: ["subjectAnchor"]
        )
        try requireObject(
            root["dataset"],
            keys: [
                "inputDigest", "geometryDigest", "selectedFramesDigest",
                "selectedImageOrder",
            ]
        )
        guard let masks = root["masks"] as? [[String: Any]] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        for mask in masks {
            try requireKeys(
                mask,
                required: [
                    "relativePath", "imageIdentity", "imageSHA256", "maskSHA256",
                    "pixelWidth", "pixelHeight", "backgroundLabel", "subjectLabel",
                ]
            )
        }
        try requireObject(
            root["policy"],
            keys: [
                "version", "minimumMaskConfidence", "minimumHeldOutIoU",
                "minimumRetainedGaussianFraction", "maximumRetainedGaussianFraction",
            ]
        )
        try requireObject(
            root["metrics"],
            required: ["meanMaskConfidence", "retainedGaussianFraction"],
            optional: ["heldOutMeanIoU"]
        )
        try requireObject(
            root["output"],
            keys: [
                "identity", "relativePath", "sha256", "byteCount",
                "gaussianCount", "sceneBounds",
            ]
        )
        if let output = root["output"] as? [String: Any] {
            try requireObject(output["sceneBounds"], keys: ["center", "radius"])
            if let bounds = output["sceneBounds"] as? [String: Any] {
                try requireObject(bounds["center"], keys: ["x", "y", "z"])
            }
        }
        if let anchor = root["subjectAnchor"] {
            if !(anchor is NSNull) {
                try requireObject(
                    anchor,
                    keys: ["imageIdentity", "normalizedX", "normalizedY"]
                )
            }
        }
    }

    private static func requireObject(_ value: Any?, keys: Set<String>) throws {
        try requireObject(value, required: keys, optional: [])
    }

    private static func requireObject(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String>
    ) throws {
        guard let object = value as? [String: Any] else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        try requireKeys(object, required: required, optional: optional)
    }

    private static func requireKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual),
              actual.isSubset(of: required.union(optional)) else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func validPolicy(_ policy: IsolationArtifact.Policy) -> Bool {
        policy.version > 0
            && validUnitInterval(policy.minimumMaskConfidence)
            && validUnitInterval(policy.minimumHeldOutIoU)
            && policy.minimumRetainedGaussianFraction.isFinite
            && policy.maximumRetainedGaussianFraction.isFinite
            && policy.minimumRetainedGaussianFraction > 0
            && policy.minimumRetainedGaussianFraction
                < policy.maximumRetainedGaussianFraction
            && policy.maximumRetainedGaussianFraction <= 1
    }

    private static func validMetrics(
        _ metrics: IsolationArtifact.ValidationMetrics,
        policy: IsolationArtifact.Policy
    ) -> Bool {
        validUnitInterval(metrics.meanMaskConfidence)
            && metrics.heldOutMeanIoU.map(validUnitInterval) ?? true
            && validUnitInterval(metrics.retainedGaussianFraction)
            && metrics.meanMaskConfidence >= policy.minimumMaskConfidence
            && (metrics.heldOutMeanIoU.map {
                $0 >= policy.minimumHeldOutIoU
            } ?? true)
            && metrics.retainedGaussianFraction
                >= policy.minimumRetainedGaussianFraction
            && metrics.retainedGaussianFraction
                <= policy.maximumRetainedGaussianFraction
    }

    private static func validUnitInterval(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isSafeIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumIdentityBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && URL(fileURLWithPath: value).lastPathComponent == value
            && value != "."
            && value != ".."
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(
        _ data: Data,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> String {
        var hasher = SHA256()
        let chunkSize = 1_048_576
        var offset = 0
        while offset < data.count {
            try throwIfCancelled(shouldCancel)
            let end = min(offset + chunkSize, data.count)
            hasher.update(data: data[offset..<end])
            offset = end
        }
        try throwIfCancelled(shouldCancel)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func throwIfCancelled(
        _ shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    private static func copyPrivateRegularFile(
        from source: URL,
        to destination: URL,
        maximumBytes: Int,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        let data = try BoundedFileReader.readRegularFile(
            at: source,
            maximumBytes: maximumBytes,
            shouldCancel: shouldCancel
        )
        try writePrivateFile(data, to: destination, shouldCancel: shouldCancel)
    }

    private static func writePrivateFile(
        _ data: Data,
        to destination: URL,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        let parent = destination.deletingLastPathComponent()
        let directory = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        let descriptor = destination.lastPathComponent.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
        var keep = false
        defer {
            Darwin.close(descriptor)
            if !keep {
                destination.lastPathComponent.withCString {
                    _ = Darwin.unlinkat(directory, $0, 0)
                }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try throwIfCancelled(shouldCancel)
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SubjectIsolationArtifactStoreError.invalidArtifact
                }
                offset += count
            }
        }
        try throwIfCancelled(shouldCancel)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size == data.count else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        keep = true
    }

    private static func moveAsideIfPresent(_ destination: URL) throws -> URL? {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: destination.path)
            || (try? fileManager.destinationOfSymbolicLink(
                atPath: destination.path
            )) != nil
        guard exists else { return nil }
        try requirePrivateRegularFile(destination)
        let backup = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).previous.\(UUID().uuidString)"
        )
        try renameExclusive(destination, to: backup)
        return backup
    }

    private static func renameExclusive(_ source: URL, to destination: URL) throws {
        guard source.deletingLastPathComponent().path
                == destination.deletingLastPathComponent().path else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let directoryURL = source.deletingLastPathComponent()
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        let result = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { destinationName in
                Darwin.renameatx_np(
                    directory,
                    sourceName,
                    directory,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw SubjectIsolationArtifactStoreError.publicationConflict
        }
    }

    private static func rollbackPublishedFile(
        destination: URL,
        backup: URL?,
        newWasPublished: Bool
    ) throws {
        if newWasPublished {
            try removePrivateRegularFileIfPresent(destination)
        }
        if let backup,
           FileManager.default.fileExists(atPath: backup.path) {
            try renameExclusive(backup, to: destination)
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private static func removePrivateRegularFileIfPresent(_ url: URL) throws {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard exists else { return }
        let directoryURL = url.deletingLastPathComponent()
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(directory) }
        var status = stat()
        let statusResult = url.lastPathComponent.withCString {
            Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        let removeResult = url.lastPathComponent.withCString {
            Darwin.unlinkat(directory, $0, 0)
        }
        guard removeResult == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func requirePrivateRegularFile(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              pathStatus.st_nlink == 1 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw SubjectIsolationArtifactStoreError.invalidArtifact
        }
    }
}
