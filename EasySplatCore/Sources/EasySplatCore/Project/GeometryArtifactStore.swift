import CryptoKit
import Foundation

enum GeometryArtifactStore {
    static let maximumMedianPixelResidual = 1.5
    static let maximumP90PixelResidual = 3.0
    static let minimumRegisteredViewFraction = 0.90

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidSchema(Int)
        case invalidCanonicalPath
        case invalidDigest(String)
        case invalidResiduals
        case invalidPeakMemory
        case artifactDigestMismatch(String)
        case modelHashMismatch(String)
        case measuredResidualMismatch

        var errorDescription: String? {
            switch self {
            case .invalidSchema(let schema):
                return "Unsupported geometry artifact schema \(schema)."
            case .invalidCanonicalPath:
                return "Geometry artifact points outside the project."
            case .invalidDigest(let field):
                return "Geometry artifact has an invalid \(field) digest."
            case .invalidResiduals:
                return "Geometry artifact does not contain measured pixel residuals."
            case .invalidPeakMemory:
                return "Geometry artifact does not contain a measured peak-memory value."
            case .artifactDigestMismatch(let field):
                return "Geometry artifact no longer matches its \(field)."
            case .modelHashMismatch(let name):
                return "Geometry artifact model file does not match its digest: \(name)."
            case .measuredResidualMismatch:
                return "Geometry artifact measurements do not match its canonical model."
            }
        }
    }

    static func load(from url: URL, projectPaths: ProjectPaths) throws -> GeometryArtifact {
        let artifact = try JSONDecoder().decode(GeometryArtifact.self, from: Data(contentsOf: url))
        try validate(artifact, projectPaths: projectPaths)
        return artifact
    }

    static func persist(
        _ artifact: GeometryArtifact,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil
    ) throws {
        try validate(
            artifact,
            projectPaths: paths,
            measuredResiduals: measuredResiduals
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        let previousManifest = try? Data(contentsOf: paths.geometryManifestURL)
        try data.write(to: paths.geometryManifestURL, options: [.atomic])

        let previousArtifact = metadata.geometryArtifact
        metadata.geometryArtifact = artifact
        do {
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
        measuredResiduals: ColmapResidualAnalyzer.Result? = nil
    ) throws {
        guard artifact.schemaVersion == 1 else { throw Error.invalidSchema(artifact.schemaVersion) }
        guard (try? projectPaths.resolveProjectRelativePath(artifact.canonicalModelPath)) != nil else {
            throw Error.invalidCanonicalPath
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
                  >= minimumRegisteredViewFraction,
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
        guard Set(artifact.modelHashes.keys) == ["cameras.txt", "images.txt", "points3D.txt"],
              artifact.modelHashes.values.allSatisfy(isSHA256) else {
            throw Error.invalidDigest("model")
        }
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            let relativePath = artifact.canonicalModelPath + "/" + name
            guard let file = try? projectPaths.resolveProjectRelativePath(relativePath),
                  let digest = try? sha256(of: file),
                  digest == artifact.modelHashes[name] else {
                throw Error.modelHashMismatch(name)
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

        let canonicalModel = try projectPaths.resolveProjectRelativePath(artifact.canonicalModelPath)
        let measured = try measuredResiduals
            ?? ColmapResidualAnalyzer.analyze(modelDirectory: canonicalModel)
        guard measured.provenance == artifact.residualProvenance,
              measured.registeredViewCount == artifact.registeredViewCount,
              Set(measured.registeredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Set(measured.measuredImageNames).isSubset(of: Set(artifact.orderedImageNames)),
              Double(measured.measuredImageNames.count) / Double(artifact.totalViewCount)
                  >= minimumRegisteredViewFraction,
              measured.pointCount == artifact.pointCount,
              measured.observationCount == artifact.trackCount,
              approximatelyEqual(measured.medianPixelResidual, artifact.medianPixelResidual),
              approximatelyEqual(measured.p90PixelResidual, artifact.p90PixelResidual) else {
            throw Error.measuredResidualMismatch
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
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
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0 else {
                throw Error.artifactDigestMismatch("file")
            }
            let relativePath = String(resolved.path.dropFirst(rootPath.count + 1))
            update(UInt64(relativePath.utf8.count), in: &hasher)
            hasher.update(data: Data(relativePath.utf8))
            update(UInt64(fileSize), in: &hasher)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
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
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
