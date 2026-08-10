import Darwin
import CryptoKit
import EasySplatCore
import Foundation

private struct PackagedProjectInputManifestDocument: Codable, Equatable {
    let schemaVersion: Int
    let videos: [String]
    let photoFolder: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case videos
        case photoFolder
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(videos, forKey: .videos)
        if let photoFolder {
            try container.encode(photoFolder, forKey: .photoFolder)
        } else {
            try container.encodeNil(forKey: .photoFolder)
        }
    }
}

private struct PackagedProjectInputIdentity: Equatable, Hashable {
    let device: dev_t
    let inode: ino_t
    let linkCount: nlink_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: time_t
    let modifiedNanoseconds: Int64
    let changedSeconds: time_t
    let changedNanoseconds: Int64

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        linkCount = status.st_nlink
        mode = status.st_mode
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

public enum PackagedProjectArgumentError: Error, LocalizedError, Equatable {
    case usage(String)
    case invalidInputManifest(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidInputManifest(let message):
            return message
        }
    }
}

public struct ResolvedPackagedProjectInput: Equatable, Sendable {
    public let expectedInput: FinishedProjectExpectedInput
    public let boundaryURL: URL
    public let manifestData: Data
    public let continuityTokenSHA256: String

    public init(
        expectedInput: FinishedProjectExpectedInput,
        boundaryURL: URL,
        manifestData: Data,
        continuityTokenSHA256: String
    ) {
        self.expectedInput = expectedInput
        self.boundaryURL = boundaryURL
        self.manifestData = manifestData
        self.continuityTokenSHA256 = continuityTokenSHA256
    }
}

public enum PackagedProjectInputResolver {
    public static func resolve(
        manifestURL: URL,
        inputRoot: URL
    ) throws -> ResolvedPackagedProjectInput {
        try PackagedProjectArguments.resolveManifest(
            at: manifestURL,
            inputRoot: inputRoot
        )
    }
}

public struct PackagedProjectArguments: Equatable, Sendable {
    public let project: URL
    public let inputManifestURL: URL
    public let inputRootURL: URL
    public let marker: URL
    public let appVersion: String
    public let expectedReleaseVerificationTokenSHA256: String
    public let expectedExecutable: URL
    public let expectedExecutableSHA256: String
    public let expectedExecutableBytes: UInt64
    public let evidence: URL

    public static let usage = "Usage: EasySplatReleaseVerifier verify-packaged-project "
        + "--project <root.easysplatproj> "
        + "--input-manifest <schema1.json> --input-root <directory> "
        + "--marker <schema3.json> --app-version <semver> "
        + "--expected-release-verification-token-sha256 <sha256> "
        + "--expected-executable <file> --expected-executable-sha256 <sha256> "
        + "--expected-executable-bytes <bytes> --evidence <attestation.md>"

    public static func parse(_ raw: [String]) throws -> Self {
        var values: [String: String] = [:]
        let allowed: Set<String> = [
            "--project", "--input-manifest", "--input-root",
            "--marker", "--app-version",
            "--expected-release-verification-token-sha256", "--expected-executable",
            "--expected-executable-sha256", "--expected-executable-bytes", "--evidence",
        ]
        var index = 0
        while index < raw.count {
            let option = raw[index]
            guard allowed.contains(option),
                  index + 1 < raw.count,
                  values[option] == nil else {
                throw PackagedProjectArgumentError.usage(usage)
            }
            values[option] = raw[index + 1]
            index += 2
        }
        guard let project = values["--project"],
              let marker = values["--marker"],
              let appVersion = values["--app-version"],
              let expectedTokenSHA256 = values[
                "--expected-release-verification-token-sha256"
              ],
              let expectedExecutable = values["--expected-executable"],
              let expectedExecutableSHA256 = values["--expected-executable-sha256"],
              let expectedExecutableBytesValue = values["--expected-executable-bytes"],
              let expectedExecutableBytes = UInt64(expectedExecutableBytesValue),
              expectedExecutableBytes > 0,
              let evidence = values["--evidence"],
              isSafeAppVersion(appVersion),
              isLowercaseSHA256(expectedTokenSHA256),
              isLowercaseSHA256(expectedExecutableSHA256) else {
            throw PackagedProjectArgumentError.usage(usage)
        }
        guard let inputManifest = values["--input-manifest"],
              let inputRoot = values["--input-root"] else {
            throw PackagedProjectArgumentError.usage(usage)
        }
        let pathValues = [
            project,
            inputManifest,
            inputRoot,
            marker,
            expectedExecutable,
            evidence,
        ].compactMap { $0 }
        guard pathValues.allSatisfy({ hasNoASCIIControlCharacters($0) }),
              pathValues.allSatisfy({ ($0 as NSString).isAbsolutePath }) else {
            throw PackagedProjectArgumentError.usage(usage)
        }
        return Self(
            project: URL(fileURLWithPath: project, isDirectory: true),
            inputManifestURL: URL(fileURLWithPath: inputManifest),
            inputRootURL: URL(fileURLWithPath: inputRoot, isDirectory: true),
            marker: URL(fileURLWithPath: marker),
            appVersion: appVersion,
            expectedReleaseVerificationTokenSHA256: expectedTokenSHA256,
            expectedExecutable: URL(fileURLWithPath: expectedExecutable),
            expectedExecutableSHA256: expectedExecutableSHA256,
            expectedExecutableBytes: expectedExecutableBytes,
            evidence: URL(fileURLWithPath: evidence)
        )
    }

    public func resolveInput() throws -> ResolvedPackagedProjectInput {
        try PackagedProjectInputResolver.resolve(
            manifestURL: inputManifestURL,
            inputRoot: inputRootURL
        )
    }

    fileprivate static func resolveManifest(
        at manifestURL: URL,
        inputRoot suppliedRoot: URL
    ) throws -> ResolvedPackagedProjectInput {
        let manifestRead = try Self.readStableManifest(at: manifestURL)
        let data = manifestRead.data
        let expectedKeys: Set<String> = ["schemaVersion", "videos", "photoFolder"]
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == expectedKeys,
              let document = try? JSONDecoder().decode(
                PackagedProjectInputManifestDocument.self,
                from: data
              ),
              document.schemaVersion == 1,
              !document.videos.isEmpty || document.photoFolder != nil,
              document.videos.count <= 64 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest is not strict schema 1."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(document) == data else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest is not canonical JSON."
            )
        }
        let allPaths = document.videos + [document.photoFolder].compactMap { $0 }
        guard allPaths.allSatisfy(Self.safeProjectRelativeInputPath) else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest contains an unsafe relative path."
            )
        }
        let normalizedKeys = allPaths.map(Self.normalizedPathKey)
        guard Set(normalizedKeys).count == normalizedKeys.count else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest contains case- or Unicode-equivalent paths."
            )
        }

        let canonicalRoot = try Self.canonicalInputRoot(suppliedRoot)
        let rootDescriptor = Darwin.open(
            canonicalRoot.url.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input root could not be opened safely."
            )
        }
        defer { Darwin.close(rootDescriptor) }
        var openedRootStatus = stat()
        guard fstat(rootDescriptor, &openedRootStatus) == 0,
              PackagedProjectInputIdentity(openedRootStatus) == canonicalRoot.identity else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input root changed while it was opened."
            )
        }

        var videoURLs: [URL] = []
        var videoIdentities: [PackagedProjectInputIdentity] = []
        for path in document.videos {
            let entry = try Self.resolveInputEntry(
                path,
                expectingDirectory: false,
                rootDescriptor: rootDescriptor,
                rootURL: canonicalRoot.url
            )
            videoURLs.append(entry.url)
            videoIdentities.append(entry.identity)
        }
        guard Set(videoIdentities).count == videoIdentities.count else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest selects the same video identity more than once."
            )
        }
        let photoEntry: (url: URL, identity: PackagedProjectInputIdentity)?
        if let photoFolder = document.photoFolder {
            photoEntry = try Self.resolveInputEntry(
                photoFolder,
                expectingDirectory: true,
                rootDescriptor: rootDescriptor,
                rootURL: canonicalRoot.url
            )
        } else {
            photoEntry = nil
        }
        var finalRootStatus = stat()
        var reboundRootStatus = stat()
        guard fstat(rootDescriptor, &finalRootStatus) == 0,
              lstat(canonicalRoot.url.path, &reboundRootStatus) == 0,
              PackagedProjectInputIdentity(finalRootStatus) == canonicalRoot.identity,
              PackagedProjectInputIdentity(reboundRootStatus) == canonicalRoot.identity else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input root changed during manifest resolution."
            )
        }

        let expectedInput: FinishedProjectExpectedInput
        switch (videoURLs.isEmpty, photoEntry?.url) {
        case (false, nil):
            expectedInput = .videoFiles(videoURLs)
        case (true, let folder?):
            expectedInput = .photoFolder(folder)
        case (false, let folder?):
            expectedInput = .mixed(videoFiles: videoURLs, photoFolder: folder)
        case (true, nil):
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest selects no inputs."
            )
        }
        return ResolvedPackagedProjectInput(
            expectedInput: expectedInput,
            boundaryURL: canonicalRoot.url,
            manifestData: data,
            continuityTokenSHA256: continuityToken(
                [
                    continuityRow(tag: "manifest", identity: manifestRead.identity),
                    continuityRow(tag: "root", identity: canonicalRoot.identity),
                ]
                    + videoIdentities.enumerated().map { index, identity in
                        continuityRow(tag: "video-\(index)", identity: identity)
                    }
                    + [photoEntry.map {
                        continuityRow(tag: "photos", identity: $0.identity)
                    }].compactMap { $0 }
            )
        )
    }

    private static func readStableManifest(
        at url: URL
    ) throws -> (data: Data, identity: PackagedProjectInputIdentity) {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              pathStatus.st_nlink == 1,
              pathStatus.st_size > 0,
              pathStatus.st_size <= 64 * 1_024 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest is not a bounded ordinary file."
            )
        }
        let expected = PackagedProjectInputIdentity(pathStatus)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest could not be opened safely."
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              PackagedProjectInputIdentity(opened) == expected else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest changed before it was read."
            )
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw PackagedProjectArgumentError.invalidInputManifest(
                    "The packaged-project input manifest could not be read safely."
                )
            }
            if count == 0 { break }
            guard data.count + count <= 64 * 1_024 else {
                throw PackagedProjectArgumentError.invalidInputManifest(
                    "The packaged-project input manifest exceeds its size limit."
                )
            }
            data.append(contentsOf: buffer[0..<count])
        }
        var final = stat()
        var rebound = stat()
        guard data.count == Int(opened.st_size),
              fstat(descriptor, &final) == 0,
              lstat(url.path, &rebound) == 0,
              PackagedProjectInputIdentity(final) == expected,
              PackagedProjectInputIdentity(rebound) == expected else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input manifest changed while it was read."
            )
        }
        return (data, expected)
    }

    private static func continuityRow(
        tag: String,
        identity: PackagedProjectInputIdentity
    ) -> String {
        [
            tag,
            String(identity.device),
            String(identity.inode),
            String(identity.linkCount),
            String(identity.mode),
            String(identity.size),
            String(identity.modifiedSeconds),
            String(identity.modifiedNanoseconds),
            String(identity.changedSeconds),
            String(identity.changedNanoseconds),
        ].joined(separator: ":")
    }

    private static func continuityToken(_ rows: [String]) -> String {
        SHA256.hash(data: Data(rows.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalInputRoot(
        _ suppliedURL: URL
    ) throws -> (url: URL, identity: PackagedProjectInputIdentity) {
        var supplied = stat()
        guard suppliedURL.isFileURL,
              lstat(suppliedURL.path, &supplied) == 0,
              (supplied.st_mode & S_IFMT) == S_IFDIR else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input root is not an ordinary directory."
            )
        }
        let canonical = suppliedURL.standardizedFileURL.resolvingSymlinksInPath()
        var resolved = stat()
        let identity = PackagedProjectInputIdentity(supplied)
        guard lstat(canonical.path, &resolved) == 0,
              PackagedProjectInputIdentity(resolved) == identity else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input root changed while it was resolved."
            )
        }
        return (canonical, identity)
    }

    private static func resolveInputEntry(
        _ relativePath: String,
        expectingDirectory: Bool,
        rootDescriptor: Int32,
        rootURL: URL
    ) throws -> (url: URL, identity: PackagedProjectInputIdentity) {
        let components = relativePath.split(separator: "/").map(String.init)
        var current = dup(rootDescriptor)
        guard current >= 0 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "The packaged-project input root could not be duplicated safely."
            )
        }
        defer { Darwin.close(current) }
        for component in components.dropLast() {
            let next = component.withCString {
                openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                throw PackagedProjectArgumentError.invalidInputManifest(
                    "A packaged-project input path contains a missing or linked directory."
                )
            }
            Darwin.close(current)
            current = next
        }
        guard let leaf = components.last else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "A packaged-project input path is empty."
            )
        }
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            | (expectingDirectory ? O_DIRECTORY : 0)
        let entryDescriptor = leaf.withCString { openat(current, $0, flags) }
        guard entryDescriptor >= 0 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "A packaged-project input entry is missing, linked, or has the wrong kind."
            )
        }
        defer { Darwin.close(entryDescriptor) }
        var opened = stat()
        var rebound = stat()
        guard fstat(entryDescriptor, &opened) == 0,
              leaf.withCString({
                fstatat(current, $0, &rebound, AT_SYMLINK_NOFOLLOW)
              }) == 0 else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "A packaged-project input entry changed while it was opened."
            )
        }
        let identity = PackagedProjectInputIdentity(opened)
        let expectedKind = expectingDirectory ? S_IFDIR : S_IFREG
        guard (opened.st_mode & S_IFMT) == expectedKind,
              PackagedProjectInputIdentity(rebound) == identity,
              expectingDirectory || (opened.st_nlink == 1 && opened.st_size > 0) else {
            throw PackagedProjectArgumentError.invalidInputManifest(
                "A packaged-project input entry is not an ordinary expected-kind entry."
            )
        }
        return (
            rootURL.appendingPathComponent(relativePath),
            identity
        )
    }

    private static func safeProjectRelativeInputPath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && value.utf8.count <= 1_024
            && value == value.precomposedStringWithCanonicalMapping
            && !(value as NSString).isAbsolutePath
            && !value.contains("\\")
            && components.count <= 64
            && components.allSatisfy { component in
                !component.isEmpty
                    && component != "."
                    && component != ".."
                    && component.utf8.count <= 255
                    && component.unicodeScalars.allSatisfy { scalar in
                        !CharacterSet.controlCharacters.contains(scalar)
                            && !CharacterSet.illegalCharacters.contains(scalar)
                            && !CharacterSet.newlines.contains(scalar)
                            && scalar.properties.generalCategory != .format
                    }
            }
    }

    private static func normalizedPathKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func hasNoASCIIControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func isSafeAppVersion(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$",
            options: .regularExpression
        ) != nil
    }
}
