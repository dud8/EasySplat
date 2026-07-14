import CryptoKit
import Darwin
import Foundation

struct ExtractedFrameManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let groups: [ExtractedFrameGroup]
}

struct ExtractedFrameGroup: Codable, Equatable, Sendable {
    let index: Int
    let targetCount: Int
    let files: [ExtractedFrameFile]
}

struct ExtractedFrameFile: Codable, Equatable, Sendable {
    let index: Int
    let fileName: String
    let byteCount: Int64
    let sha256: String
}

enum ExtractedFrameManifestError: Error, Equatable {
    case missingManifest
    case invalidManifest
    case unsafeLayout
    case changedFile(String)
}

enum ExtractedFrameManifestStore {
    private static let maximumManifestBytes = 4 * 1_024 * 1_024
    private static let bufferSize = 1_048_576
    private static let maximumFrameBytes: Int64 = 512 * 1_024 * 1_024
    private static let maximumAggregateBytes: Int64 = 64 * 1_024 * 1_024 * 1_024

    static func persist(
        groups: [[URL]],
        targetCounts: [Int],
        paths: ProjectPaths
    ) throws -> ExtractedFrameManifest {
        guard groups.count == targetCounts.count,
              !groups.isEmpty,
              targetCounts.allSatisfy({ $0 > 0 }) else {
            throw ExtractedFrameManifestError.invalidManifest
        }

        var totalBytes: Int64 = 0
        let manifestGroups = try zip(groups.indices, zip(groups, targetCounts)).map {
            index, values -> ExtractedFrameGroup in
            let (files, targetCount) = values
            guard files.count == targetCount else {
                throw ExtractedFrameManifestError.invalidManifest
            }
            let expectedDirectory = try groupDirectory(index: index, paths: paths)
            let expectedPath = expectedDirectory.standardizedFileURL.path + "/"
            var seenNames = Set<String>()
            let manifestFiles = try files.enumerated().map { frameIndex, file -> ExtractedFrameFile in
                let standardized = file.standardizedFileURL
                guard standardized.deletingLastPathComponent() == expectedDirectory.standardizedFileURL,
                      standardized.path.hasPrefix(expectedPath),
                      isSafeFrameFileName(standardized.lastPathComponent),
                      hasExpectedFrameIndex(
                          standardized.lastPathComponent,
                          index: frameIndex
                      ),
                      seenNames.insert(standardized.lastPathComponent.lowercased()).inserted else {
                    throw ExtractedFrameManifestError.unsafeLayout
                }
                let fingerprint = try fingerprint(standardized)
                guard fingerprint.byteCount <= maximumAggregateBytes - totalBytes else {
                    throw ExtractedFrameManifestError.invalidManifest
                }
                totalBytes += fingerprint.byteCount
                return ExtractedFrameFile(
                    index: frameIndex,
                    fileName: standardized.lastPathComponent,
                    byteCount: fingerprint.byteCount,
                    sha256: fingerprint.sha256
                )
            }
            return ExtractedFrameGroup(
                index: index,
                targetCount: targetCount,
                files: manifestFiles
            )
        }
        let manifest = ExtractedFrameManifest(
            schemaVersion: ExtractedFrameManifest.currentSchemaVersion,
            groups: manifestGroups
        )
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= maximumManifestBytes else {
            throw ExtractedFrameManifestError.invalidManifest
        }
        try verifyRawDirectoryLayout(manifest: manifest, paths: paths)
        try data.write(to: paths.framesRawManifestURL, options: [.atomic])
        let persistedData = try BoundedFileReader.readRegularFile(
            at: paths.framesRawManifestURL,
            maximumBytes: maximumManifestBytes
        )
        guard persistedData == data else {
            throw ExtractedFrameManifestError.invalidManifest
        }
        return manifest
    }

    static func loadVerified(
        paths: ProjectPaths,
        expectedVideoCount: Int,
        maximumTotalFrames: Int
    ) throws -> ExtractedFrameManifest {
        let data: Data
        do {
            data = try BoundedFileReader.readRegularFile(
                at: paths.framesRawManifestURL,
                maximumBytes: maximumManifestBytes
            )
        } catch where BoundedFileReader.isMissingFileError(error) {
            throw ExtractedFrameManifestError.missingManifest
        } catch {
            throw ExtractedFrameManifestError.invalidManifest
        }
        guard expectedVideoCount > 0,
              maximumTotalFrames > 0,
              let manifest = try? JSONDecoder().decode(
                ExtractedFrameManifest.self,
                from: data
              ),
              manifest.schemaVersion == ExtractedFrameManifest.currentSchemaVersion,
              manifest.groups.count == expectedVideoCount,
              manifest.groups.map(\.index) == Array(0..<expectedVideoCount),
              manifest.groups.allSatisfy({
                  $0.targetCount > 0
                      && $0.targetCount <= maximumTotalFrames
                      && $0.files.count == $0.targetCount
                      && $0.files.map(\.index) == Array(0..<$0.files.count)
                      && Set($0.files.map { $0.fileName.lowercased() }).count == $0.files.count
              }) else {
            throw ExtractedFrameManifestError.invalidManifest
        }

        var totalFrames = 0
        var totalBytes: Int64 = 0
        for group in manifest.groups {
            guard group.targetCount <= maximumTotalFrames - totalFrames else {
                throw ExtractedFrameManifestError.invalidManifest
            }
            totalFrames += group.targetCount
            for file in group.files {
                guard file.byteCount > 0,
                      file.byteCount <= maximumFrameBytes,
                      file.byteCount <= maximumAggregateBytes - totalBytes else {
                    throw ExtractedFrameManifestError.invalidManifest
                }
                totalBytes += file.byteCount
            }
        }

        try verifyRawDirectoryLayout(manifest: manifest, paths: paths)
        for group in manifest.groups {
            let directory = try groupDirectory(index: group.index, paths: paths)
            for file in group.files {
                guard isSafeFrameFileName(file.fileName),
                      hasExpectedFrameIndex(file.fileName, index: file.index),
                      file.byteCount > 0,
                      file.sha256.count == 64,
                      file.sha256 == file.sha256.lowercased(),
                      file.sha256.allSatisfy({ $0.isHexDigit }) else {
                    throw ExtractedFrameManifestError.invalidManifest
                }
                let fingerprint = try fingerprint(
                    directory.appendingPathComponent(file.fileName),
                    expectedByteCount: file.byteCount
                )
                guard fingerprint.byteCount == file.byteCount,
                      fingerprint.sha256 == file.sha256 else {
                    throw ExtractedFrameManifestError.changedFile(file.fileName)
                }
            }
        }
        return manifest
    }

    static func frameGroups(
        from manifest: ExtractedFrameManifest,
        paths: ProjectPaths
    ) throws -> [[URL]] {
        try manifest.groups.map { group in
            let directory = try groupDirectory(index: group.index, paths: paths)
            return group.files.map { directory.appendingPathComponent($0.fileName) }
        }
    }

    static func isSafeRegularFrameFile(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size > 0
            && metadata.st_size <= maximumFrameBytes
    }

    private static func verifyRawDirectoryLayout(
        manifest: ExtractedFrameManifest,
        paths: ProjectPaths
    ) throws {
        let fileManager = FileManager.default
        let rawValues = try paths.framesRawURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rawValues.isDirectory == true, rawValues.isSymbolicLink != true else {
            throw ExtractedFrameManifestError.unsafeLayout
        }
        let rootEntries = try fileManager.contentsOfDirectory(
            at: paths.framesRawURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        let expectedGroupNames = Set(manifest.groups.map {
            String(format: "video_%03d", $0.index).lowercased()
        })
        guard rootEntries.count == expectedGroupNames.count,
              Set(rootEntries.map { $0.lastPathComponent.lowercased() }) == expectedGroupNames else {
            throw ExtractedFrameManifestError.unsafeLayout
        }

        for group in manifest.groups {
            let directory = try groupDirectory(index: group.index, paths: paths)
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ExtractedFrameManifestError.unsafeLayout
            }
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
            let expectedNames = Set(group.files.map { $0.fileName.lowercased() })
            guard entries.count == expectedNames.count,
                  Set(entries.map { $0.lastPathComponent.lowercased() }) == expectedNames else {
                throw ExtractedFrameManifestError.unsafeLayout
            }
            for entry in entries {
                let entryValues = try entry.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard entryValues.isRegularFile == true,
                      entryValues.isSymbolicLink != true else {
                    throw ExtractedFrameManifestError.unsafeLayout
                }
            }
        }
    }

    private static func groupDirectory(index: Int, paths: ProjectPaths) throws -> URL {
        try paths.resolveProjectRelativePath(
            String(format: "Frames/raw/video_%03d", index)
        )
    }

    private static func isSafeFrameFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            return false
        }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg" || ext == "png"
    }

    private static func hasExpectedFrameIndex(_ fileName: String, index: Int) -> Bool {
        guard index >= 0 else { return false }
        let prefix = String(format: "frame_%06d", index)
        guard fileName.hasPrefix(prefix) else { return false }
        let suffix = fileName.dropFirst(prefix.count)
        return suffix.first == "." || suffix.first == "_"
    }

    private static func fingerprint(
        _ url: URL,
        expectedByteCount: Int64? = nil
    ) throws -> (byteCount: Int64, sha256: String) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ExtractedFrameManifestError.changedFile(url.lastPathComponent)
        }
        defer { Darwin.close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size > 0,
              initial.st_size <= maximumFrameBytes,
              expectedByteCount.map({ initial.st_size == $0 }) ?? true else {
            throw ExtractedFrameManifestError.changedFile(url.lastPathComponent)
        }
        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw ExtractedFrameManifestError.changedFile(url.lastPathComponent)
            }
            if count == 0 { break }
            consumed += Int64(count)
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count])
                )
            }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_nlink == 1,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              consumed == initial.st_size else {
            throw ExtractedFrameManifestError.changedFile(url.lastPathComponent)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (consumed, digest)
    }
}
