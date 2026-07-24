import CryptoKit
import Darwin
import EasySplatCore
import EasySplatReleaseVerifierCore
import Foundation

private func hasNoASCIIControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7f
    }
}

private enum InstallationPolicy: String {
    case remoteOnly = "remote-only"
    case bundledBootstrapOnly = "bundled-bootstrap-only"
    case cachedOnly = "cached-only"
}

private struct PackagedMarkerFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
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
        owner = status.st_uid
        linkCount = status.st_nlink
        mode = status.st_mode
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

private struct PackagedExecutableEvidence: Equatable {
    let path: String
    let byteCount: UInt64
    let sha256: String
    let identity: PackagedMarkerFileIdentity
}

private struct PackagedStableDataRead: Equatable {
    let data: Data
    let identity: PackagedMarkerFileIdentity
}

private struct PackagedProjectMetadataSnapshot: Equatable {
    let data: Data
    let identity: PackagedMarkerFileIdentity
    let canonicalDecodedSHA256: String
}

private struct Arguments {
    var inputManifest: URL
    var inputRoot: URL
    var manifestURL: URL
    var publicKeyFile: URL
    var expectedManifest: URL
    var expectedManifestFileSHA256: String
    var bootstrapManifest: URL?
    var bootstrapCoreArchive: URL?
    var cacheRoot: URL
    var output: URL
    var evidence: URL
    var appVersion: String
    var installationPolicy: InstallationPolicy
    var offline: Bool
    var allowInsecureLoopbackHTTP: Bool

    static func parse(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var offline = false
        var allowInsecureLoopbackHTTP = false
        var index = 0
        while index < raw.count {
            let option = raw[index]
            if option == "--offline" {
                offline = true
                index += 1
                continue
            }
            if option == "--allow-insecure-loopback-http" {
                allowInsecureLoopbackHTTP = true
                index += 1
                continue
            }
            guard [
                "--input-manifest", "--input-root", "--manifest-url", "--public-key-file", "--cache-root", "--output",
                "--app-version", "--bootstrap-manifest", "--bootstrap-core-archive",
                "--installation-policy", "--evidence", "--expected-manifest",
                "--expected-manifest-file-sha256",
            ].contains(option), index + 1 < raw.count else {
                throw VerificationError.usage("Unknown or incomplete option: \(option)")
            }
            values[option] = raw[index + 1]
            index += 2
        }

        guard let inputManifest = values["--input-manifest"],
              let inputRoot = values["--input-root"],
              let manifest = values["--manifest-url"],
              let manifestURL = URL(string: manifest),
              let publicKeyFile = values["--public-key-file"],
              let expectedManifest = values["--expected-manifest"],
              let expectedManifestFileSHA256 = values["--expected-manifest-file-sha256"],
              expectedManifestFileSHA256.range(
                of: "^[0-9a-fA-F]{64}$",
                options: .regularExpression
              ) != nil,
              let cacheRoot = values["--cache-root"],
              let output = values["--output"],
              let evidence = values["--evidence"],
              let appVersion = values["--app-version"],
              let policyValue = values["--installation-policy"],
              let installationPolicy = InstallationPolicy(rawValue: policyValue) else {
            throw VerificationError.usage(
                "Usage: EasySplatReleaseVerifier --input-manifest <schema1.json> --input-root <directory> --manifest-url <https-url> "
                    + "--public-key-file <file> --cache-root <dir> --output <splat.ply> "
                    + "--expected-manifest <manifest.json> --expected-manifest-file-sha256 <sha256> "
                    + "--app-version <semver> --installation-policy <remote-only|bundled-bootstrap-only|cached-only> "
                    + "--evidence <diagnostic.md> "
                    + "[--bootstrap-manifest <manifest.json> --bootstrap-core-archive <core.zip> --offline] "
                    + "[--allow-insecure-loopback-http]"
            )
        }
        switch installationPolicy {
        case .remoteOnly where offline:
            throw VerificationError.usage("The remote-only installation policy cannot be combined with --offline.")
        case .remoteOnly where values["--bootstrap-manifest"] != nil || values["--bootstrap-core-archive"] != nil:
            throw VerificationError.usage("The remote-only installation policy cannot receive bundled-bootstrap inputs.")
        case .bundledBootstrapOnly where !offline:
            throw VerificationError.usage("The bundled-bootstrap-only installation policy requires --offline.")
        case .bundledBootstrapOnly where values["--bootstrap-manifest"] == nil || values["--bootstrap-core-archive"] == nil:
            throw VerificationError.usage(
                "The bundled-bootstrap-only installation policy requires both bootstrap inputs."
            )
        case .cachedOnly where !offline:
            throw VerificationError.usage("The cached-only installation policy requires --offline.")
        case .cachedOnly where values["--bootstrap-manifest"] != nil || values["--bootstrap-core-archive"] != nil:
            throw VerificationError.usage("The cached-only installation policy cannot receive bundled-bootstrap inputs.")
        default:
            break
        }
        return Arguments(
            inputManifest: URL(fileURLWithPath: inputManifest),
            inputRoot: URL(fileURLWithPath: inputRoot, isDirectory: true),
            manifestURL: manifestURL,
            publicKeyFile: URL(fileURLWithPath: publicKeyFile),
            expectedManifest: URL(fileURLWithPath: expectedManifest),
            expectedManifestFileSHA256: expectedManifestFileSHA256.lowercased(),
            bootstrapManifest: values["--bootstrap-manifest"].map(URL.init(fileURLWithPath:)),
            bootstrapCoreArchive: values["--bootstrap-core-archive"].map(URL.init(fileURLWithPath:)),
            cacheRoot: URL(fileURLWithPath: cacheRoot, isDirectory: true),
            output: URL(fileURLWithPath: output),
            evidence: URL(fileURLWithPath: evidence),
            appVersion: appVersion,
            installationPolicy: installationPolicy,
            offline: offline,
            allowInsecureLoopbackHTTP: allowInsecureLoopbackHTTP
        )
    }
}

private enum VerificationError: Error, LocalizedError {
    case usage(String)
    case invalidPublicKey
    case nonemptyCacheRoot(String)
    case missingOutput
    case invalidOutput(String)
    case invalidEvidence(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidOutput(let message),
             .nonemptyCacheRoot(let message), .invalidEvidence(let message):
            return message
        case .invalidPublicKey:
            return "The toolchain public-key file is empty."
        case .missingOutput:
            return "The completed project did not record a PLY output."
        }
    }
}

private struct ExpectedManifestEvidence {
    let manifest: ToolchainManifest
    let fileSHA256: String
}

private struct SuccessfulRunEvidence {
    let toolchain: ToolchainInstallationEvidence
    let output: ValidatedPlyArtifactEvidence
    let publishedManifestFileSHA256: String
}

@main
private enum ReleaseVerifier {
    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        if rawArguments.first == "verify-packaged-project" {
            do {
                let arguments = try PackagedProjectArguments.parse(
                    Array(rawArguments.dropFirst())
                )
                try await verifyPackagedProject(arguments)
                print("Packaged app project, marker, and PLY evidence passed.")
            } catch {
                FileHandle.standardError.write(
                    Data("Packaged project verification failed: \(error.localizedDescription)\n".utf8)
                )
                Foundation.exit(EXIT_FAILURE)
            }
            return
        }
        let arguments: Arguments
        do {
            arguments = try Arguments.parse(rawArguments)
        } catch {
            FileHandle.standardError.write(Data("Release verification failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }

        var runError: Error?
        var successfulEvidence: SuccessfulRunEvidence?
        do {
            successfulEvidence = try await run(arguments: arguments)
        } catch {
            runError = error
        }

        do {
            try await writeEvidence(
                arguments: arguments,
                successfulEvidence: successfulEvidence,
                runError: runError
            )
        } catch {
            FileHandle.standardError.write(
                Data("Release verification could not preserve diagnostics: \(error.localizedDescription)\n".utf8)
            )
            if runError == nil {
                runError = error
            }
        }

        if let runError {
            FileHandle.standardError.write(
                Data("Release verification failed: \(runError.localizedDescription)\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func verifyPackagedProject(
        _ arguments: PackagedProjectArguments
    ) async throws {
        try requireAbsentEvidenceDestination(arguments.evidence)
        let initialInput = try arguments.resolveInput()
        let initialInputSnapshot = try ProjectArtifactValidator.captureExpectedInputSnapshot(
            initialInput.expectedInput
        )
        let expectedInputManifestSHA256 = sha256(initialInput.manifestData)
        let initialMarkerIdentity = try privateMarkerIdentity(at: arguments.marker)
        let initialMarkerRead = try packagedStableDataRead(
            at: arguments.marker,
            maximumBytes: 64 * 1_024
        )
        guard initialMarkerRead.identity == initialMarkerIdentity else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker changed before verification began."
            )
        }
        let markerData = initialMarkerRead.data
        let marker = try decodeCanonicalPackagedMarker(markerData)
        let initialPublicKeyRead = try packagedStableDataRead(
            at: arguments.publicKeyFile,
            maximumBytes: 4 * 1_024
        )
        let publicKeyData = initialPublicKeyRead.data
        guard let publicKey = String(data: publicKeyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !publicKey.isEmpty else {
            throw VerificationError.invalidPublicKey
        }
        let initialExpectedManifestRead = try packagedStableDataRead(
            at: arguments.expectedManifest,
            maximumBytes: ToolchainManifest.maximumEncodedBytes
        )
        guard let authenticatedManifest = try? ToolchainManifest.readAuthenticated(
            at: arguments.expectedManifest,
            publicKeyBase64: publicKey
        ), authenticatedManifest.data == initialExpectedManifestRead.data else {
            throw VerificationError.invalidEvidence(
                "The expected packaged toolchain manifest is not signed by the release authority."
            )
        }
        let expectedManifest = authenticatedManifest.manifest
        let expectedManifestData = authenticatedManifest.data
        let expectedManifestSHA256 = sha256(expectedManifestData)
        let initialExecutableEvidence = try packagedExecutableEvidence(
            at: arguments.expectedExecutable
        )
        guard initialExecutableEvidence.byteCount == arguments.expectedExecutableBytes,
              initialExecutableEvidence.sha256 == arguments.expectedExecutableSHA256 else {
            throw VerificationError.invalidEvidence(
                "The supervised packaged executable does not match the shell-authenticated identity."
            )
        }
        let canonicalProject = arguments.project.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalInput = initialInput.boundaryURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalAppBundle = try packagedAppBundleRoot(
            containingExecutable: arguments.expectedExecutable
        )
        let projectMetadataURL = ProjectPaths(root: canonicalProject).metadataURL
        let initialProjectMetadataSnapshot = try packagedProjectMetadataSnapshot(
            at: projectMetadataURL
        )
        let canonicalToolchain = try canonicalToolchainRoot(marker.toolchainRoot)
        try requireEvidenceDestination(
            arguments.evidence,
            outside: [
                canonicalProject,
                canonicalInput,
                canonicalToolchain,
                canonicalAppBundle,
            ]
        )
        let manager = ToolchainManager(
            appVersion: arguments.appVersion,
            localToolchainRoot: nil,
            installationRoot: canonicalToolchain.deletingLastPathComponent(),
            bundledBootstrap: nil,
            sourcePolicy: .cachedOnly
        )
        let markerRequest = ToolchainCapabilityRequest(
            capabilities: Set(marker.requestedCapabilities.compactMap(ToolchainCapability.init(rawValue:)))
        )
        guard markerRequest.capabilities.count == marker.requestedCapabilities.count else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker contains an unknown toolchain capability."
            )
        }
        let toolchainEvidenceBefore = try manager.validatedInstallationEvidence(
            root: canonicalToolchain,
            publicKeyBase64: publicKey,
            request: markerRequest,
            matching: expectedManifest
        )
        let evidence = try await ProjectArtifactValidator.validateFinishedProject(
            at: arguments.project,
            expectedInput: initialInput.expectedInput,
            authenticatedToolchain: FinishedProjectAuthenticatedToolchain(
                root: canonicalToolchain,
                installation: toolchainEvidenceBefore
            )
        )
        func markerMismatches(
            evidence currentEvidence: FinishedProjectArtifactEvidence,
            executable: PackagedExecutableEvidence
        ) -> [String] {
            let canonicalOutput = currentEvidence.outputURL.standardizedFileURL
                .resolvingSymlinksInPath()
            let expectedCapabilities = currentEvidence.toolchainRequest.capabilities
                .map(\.rawValue)
                .sorted()
            return [
                marker.schemaVersion == 3 ? nil : "schemaVersion",
                marker.releaseVerificationTokenSHA256
                    == arguments.expectedReleaseVerificationTokenSHA256
                    ? nil : "releaseVerificationTokenSHA256",
                marker.appVersion == arguments.appVersion ? nil : "appVersion",
                marker.executablePath == executable.path ? nil : "executablePath",
                marker.executableBytes == executable.byteCount ? nil : "executableBytes",
                marker.executableSHA256 == executable.sha256 ? nil : "executableSHA256",
                marker.projectRoot == canonicalProject.path ? nil : "projectRoot",
                marker.inputPath == canonicalInput.path ? nil : "inputPath",
                marker.inputManifestSHA256 == expectedInputManifestSHA256
                    ? nil : "inputManifestSHA256",
                marker.outputPlyPath == canonicalOutput.path ? nil : "outputPlyPath",
                marker.requestedCapabilities == expectedCapabilities
                    ? nil : "requestedCapabilities",
                marker.outputBytes == currentEvidence.outputEvidence.byteCount
                    ? nil : "outputBytes",
                marker.outputVertices == currentEvidence.outputEvidence.vertexCount
                    ? nil : "outputVertices",
                marker.outputFormat == currentEvidence.outputEvidence.format
                    ? nil : "outputFormat",
                marker.outputSHA256 == currentEvidence.outputEvidence.sha256
                    ? nil : "outputSHA256",
                marker.toolchainRoot == canonicalToolchain.path ? nil : "toolchainRoot",
            ].compactMap { $0 }
        }

        let mismatchedFields = markerMismatches(
            evidence: evidence,
            executable: initialExecutableEvidence
        )
        guard mismatchedFields.isEmpty else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker does not match finished project fields: "
                    + mismatchedFields.joined(separator: ", ") + "."
            )
        }

        let finalMarkerRead = try packagedStableDataRead(
            at: arguments.marker,
            maximumBytes: 64 * 1_024
        )
        let finalOutputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: evidence.outputURL
        )
        let toolchainEvidenceAfter = try manager.validatedInstallationEvidence(
            root: canonicalToolchain,
            publicKeyBase64: publicKey,
            request: evidence.toolchainRequest,
            matching: expectedManifest
        )
        let finalExecutableEvidence = try packagedExecutableEvidence(
            at: arguments.expectedExecutable
        )
        let finalPublicKeyRead = try packagedStableDataRead(
            at: arguments.publicKeyFile,
            maximumBytes: 4 * 1_024
        )
        let finalExpectedManifestRead = try packagedStableDataRead(
            at: arguments.expectedManifest,
            maximumBytes: ToolchainManifest.maximumEncodedBytes
        )
        let finalProjectMetadataSnapshot = try packagedProjectMetadataSnapshot(
            at: projectMetadataURL
        )
        guard finalMarkerRead == initialMarkerRead,
              finalPublicKeyRead == initialPublicKeyRead,
              finalExpectedManifestRead == initialExpectedManifestRead,
              try privateMarkerIdentity(at: arguments.marker) == initialMarkerIdentity,
              finalProjectMetadataSnapshot == initialProjectMetadataSnapshot,
              try canonicalProjectMetadataSHA256(evidence.metadata)
                == initialProjectMetadataSnapshot.canonicalDecodedSHA256,
              finalOutputEvidence == evidence.outputEvidence,
              toolchainEvidenceAfter == toolchainEvidenceBefore,
              finalExecutableEvidence == initialExecutableEvidence,
              try arguments.resolveInput() == initialInput,
              try ProjectArtifactValidator.captureExpectedInputSnapshot(
                initialInput.expectedInput
              ) == initialInputSnapshot else {
            throw VerificationError.invalidEvidence(
                "The packaged project or marker changed during independent verification."
            )
        }
        try await writePackagedProjectEvidence(
            arguments: arguments,
            marker: marker,
            markerData: markerData,
            expectedManifestSHA256: expectedManifestSHA256,
            executable: finalExecutableEvidence,
            toolchain: toolchainEvidenceAfter,
            projectMetadataSHA256: sha256(initialProjectMetadataSnapshot.data),
            inputManifestSHA256: expectedInputManifestSHA256,
            inputDigest: evidence.geometryArtifact.inputDigest,
            output: finalOutputEvidence,
            validateBeforePublication: {
                let postEvidence = try await ProjectArtifactValidator.validateFinishedProject(
                    at: arguments.project,
                    expectedInput: initialInput.expectedInput,
                    authenticatedToolchain: FinishedProjectAuthenticatedToolchain(
                        root: canonicalToolchain,
                        installation: toolchainEvidenceBefore
                    )
                )
                let postMarkerRead = try packagedStableDataRead(
                    at: arguments.marker,
                    maximumBytes: 64 * 1_024
                )
                let postPublicKeyRead = try packagedStableDataRead(
                    at: arguments.publicKeyFile,
                    maximumBytes: 4 * 1_024
                )
                let postExpectedManifestRead = try packagedStableDataRead(
                    at: arguments.expectedManifest,
                    maximumBytes: ToolchainManifest.maximumEncodedBytes
                )
                let postProjectMetadataSnapshot = try packagedProjectMetadataSnapshot(
                    at: projectMetadataURL
                )
                let postExecutableEvidence = try packagedExecutableEvidence(
                    at: arguments.expectedExecutable
                )
                let postOutputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
                    at: evidence.outputURL
                )
                let postToolchainEvidence = try manager.validatedInstallationEvidence(
                    root: canonicalToolchain,
                    publicKeyBase64: publicKey,
                    request: evidence.toolchainRequest,
                    matching: expectedManifest
                )
                guard postMarkerRead == initialMarkerRead,
                      postPublicKeyRead == initialPublicKeyRead,
                      postExpectedManifestRead == initialExpectedManifestRead,
                      try privateMarkerIdentity(at: arguments.marker) == initialMarkerIdentity,
                      postProjectMetadataSnapshot == initialProjectMetadataSnapshot,
                      try canonicalProjectMetadataSHA256(postEvidence.metadata)
                        == initialProjectMetadataSnapshot.canonicalDecodedSHA256,
                      postExecutableEvidence == initialExecutableEvidence,
                      postOutputEvidence == evidence.outputEvidence,
                      postToolchainEvidence == toolchainEvidenceBefore,
                      try arguments.resolveInput() == initialInput,
                      try ProjectArtifactValidator.captureExpectedInputSnapshot(
                        initialInput.expectedInput
                      ) == initialInputSnapshot,
                      postEvidence.outputURL.standardizedFileURL.resolvingSymlinksInPath()
                        == evidence.outputURL.standardizedFileURL.resolvingSymlinksInPath(),
                      markerMismatches(
                        evidence: postEvidence,
                        executable: postExecutableEvidence
                      ).isEmpty else {
                    throw VerificationError.invalidEvidence(
                        "Protected packaged-project identities changed before attestation publication."
                    )
                }
            }
        )
    }

    private static func decodeCanonicalPackagedMarker(
        _ data: Data
    ) throws -> PackagedProjectMarker {
        do {
            return try PackagedProjectMarkerCodec.decodeCanonical(data)
        } catch {
            throw VerificationError.invalidEvidence(
                error.localizedDescription
            )
        }
    }

    private static func privateMarkerIdentity(
        at url: URL
    ) throws -> PackagedMarkerFileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size > 0 else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker must be an ordinary single-link mode-0600 file."
            )
        }
        return PackagedMarkerFileIdentity(status)
    }

    private static func packagedExecutableEvidence(
        at suppliedURL: URL
    ) throws -> PackagedExecutableEvidence {
        let statedURL = suppliedURL.standardizedFileURL
        let canonicalURL = statedURL.resolvingSymlinksInPath()
        var statedStatus = stat()
        var canonicalStatus = stat()
        guard lstat(statedURL.path, &statedStatus) == 0,
              lstat(canonicalURL.path, &canonicalStatus) == 0,
              PackagedMarkerFileIdentity(statedStatus)
                == PackagedMarkerFileIdentity(canonicalStatus),
              (canonicalStatus.st_mode & S_IFMT) == S_IFREG,
              canonicalStatus.st_uid == geteuid(),
              canonicalStatus.st_nlink == 1,
              canonicalStatus.st_size > 0,
              (canonicalStatus.st_mode & mode_t(S_IXUSR)) != 0,
              (canonicalStatus.st_mode & 0o7022) == 0 else {
            throw VerificationError.invalidEvidence(
                "The packaged executable is not a private immutable executable file."
            )
        }

        let descriptor = Darwin.open(
            canonicalURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VerificationError.invalidEvidence(
                "The packaged executable could not be opened without following links."
            )
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              PackagedMarkerFileIdentity(initialStatus)
                == PackagedMarkerFileIdentity(canonicalStatus) else {
            throw VerificationError.invalidEvidence(
                "The packaged executable changed before it could be authenticated."
            )
        }

        var digest = SHA256()
        var consumed: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw VerificationError.invalidEvidence(
                    "The packaged executable could not be read safely."
                )
            }
            if count == 0 { break }
            guard UInt64(count) <= UInt64.max - consumed else {
                throw VerificationError.invalidEvidence(
                    "The packaged executable byte count overflowed."
                )
            }
            digest.update(data: Data(buffer[0..<count]))
            consumed += UInt64(count)
        }

        var finalDescriptorStatus = stat()
        var finalCanonicalStatus = stat()
        var finalStatedStatus = stat()
        let initialIdentity = PackagedMarkerFileIdentity(initialStatus)
        guard fstat(descriptor, &finalDescriptorStatus) == 0,
              lstat(canonicalURL.path, &finalCanonicalStatus) == 0,
              lstat(statedURL.path, &finalStatedStatus) == 0,
              consumed == UInt64(initialStatus.st_size),
              PackagedMarkerFileIdentity(finalDescriptorStatus) == initialIdentity,
              PackagedMarkerFileIdentity(finalCanonicalStatus) == initialIdentity,
              PackagedMarkerFileIdentity(finalStatedStatus) == initialIdentity else {
            throw VerificationError.invalidEvidence(
                "The packaged executable changed while it was authenticated."
            )
        }
        return PackagedExecutableEvidence(
            path: canonicalURL.path,
            byteCount: consumed,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            identity: initialIdentity
        )
    }

    private static func packagedStableDataRead(
        at url: URL,
        maximumBytes: Int
    ) throws -> PackagedStableDataRead {
        guard maximumBytes > 0 else {
            throw VerificationError.invalidEvidence(
                "The packaged-project read bound is invalid."
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VerificationError.invalidEvidence(
                "The packaged-project metadata could not be opened safely."
            )
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        var initialPathStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              lstat(url.path, &initialPathStatus) == 0,
              PackagedMarkerFileIdentity(initialStatus)
                == PackagedMarkerFileIdentity(initialPathStatus),
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size > 0,
              initialStatus.st_size <= off_t(maximumBytes) else {
            throw VerificationError.invalidEvidence(
                "The packaged-project metadata is not a bounded single-link file."
            )
        }
        let initialIdentity = PackagedMarkerFileIdentity(initialStatus)
        var data = Data()
        data.reserveCapacity(Int(initialStatus.st_size))
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 1_024 * 1_024))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0,
                  count <= maximumBytes - data.count else {
                throw VerificationError.invalidEvidence(
                    "The packaged-project metadata could not be read within its bound."
                )
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }

        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard fstat(descriptor, &finalDescriptorStatus) == 0,
              lstat(url.path, &finalPathStatus) == 0,
              data.count == Int(initialStatus.st_size),
              PackagedMarkerFileIdentity(finalDescriptorStatus) == initialIdentity,
              PackagedMarkerFileIdentity(finalPathStatus) == initialIdentity else {
            throw VerificationError.invalidEvidence(
                "The packaged-project metadata changed while it was read."
            )
        }
        return PackagedStableDataRead(data: data, identity: initialIdentity)
    }

    private static func packagedProjectMetadataSnapshot(
        at url: URL
    ) throws -> PackagedProjectMetadataSnapshot {
        let read = try packagedStableDataRead(at: url, maximumBytes: 8 * 1_024 * 1_024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ProjectMetadata.self, from: read.data),
              ProjectMetadataStore.acceptedFormatVersions.contains(decoded.formatVersion) else {
            throw VerificationError.invalidEvidence(
                "project.json could not be decoded from the descriptor-bound bytes."
            )
        }
        return PackagedProjectMetadataSnapshot(
            data: read.data,
            identity: read.identity,
            canonicalDecodedSHA256: try canonicalProjectMetadataSHA256(decoded)
        )
    }

    private static func canonicalProjectMetadataSHA256(
        _ metadata: ProjectMetadata
    ) throws -> String {
        try canonicalJSONSHA256(metadata)
    }

    private static func canonicalJSONSHA256<Value: Encodable>(
        _ value: Value
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return sha256(try encoder.encode(value))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireAbsentEvidenceDestination(_ evidenceURL: URL) throws {
        var status = stat()
        if lstat(evidenceURL.path, &status) == 0 || errno != ENOENT {
            throw VerificationError.invalidEvidence(
                "Packaged-app attestation destination must not already exist."
            )
        }
    }

    private static func requireEvidenceDestination(
        _ evidenceURL: URL,
        outside protectedURLs: [URL]
    ) throws {
        let canonicalEvidence = evidenceURL.standardizedFileURL.resolvingSymlinksInPath()
        var evidenceAncestorIdentities: [(device: dev_t, inode: ino_t)] = []
        var ancestor = canonicalEvidence.deletingLastPathComponent()
        while true {
            var status = stat()
            guard lstat(ancestor.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR else {
                throw VerificationError.invalidEvidence(
                    "Packaged-app attestation parent ancestry is unsafe."
                )
            }
            evidenceAncestorIdentities.append((status.st_dev, status.st_ino))
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        for protectedURL in protectedURLs {
            let canonicalProtected = protectedURL.standardizedFileURL.resolvingSymlinksInPath()
            let protectedPath = canonicalProtected.path
            guard canonicalEvidence.path != protectedPath,
                  !canonicalEvidence.path.hasPrefix(protectedPath + "/") else {
                throw VerificationError.invalidEvidence(
                    "Packaged-app attestation destination is inside an authenticated input."
                )
            }
            var protectedStatus = stat()
            if lstat(protectedPath, &protectedStatus) == 0,
               (protectedStatus.st_mode & S_IFMT) == S_IFDIR,
               evidenceAncestorIdentities.contains(where: {
                   $0.device == protectedStatus.st_dev && $0.inode == protectedStatus.st_ino
               }) {
                throw VerificationError.invalidEvidence(
                    "Packaged-app attestation destination is inside an authenticated input."
                )
            }
        }
    }

    private static func packagedAppBundleRoot(
        containingExecutable executableURL: URL
    ) throws -> URL {
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let macOSDirectory = executable.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let appBundle = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              appBundle.pathExtension.lowercased() == "app" else {
            throw VerificationError.invalidEvidence(
                "The supervised executable is not inside a canonical macOS app bundle."
            )
        }
        return appBundle
    }

    private static func writePackagedProjectEvidence(
        arguments: PackagedProjectArguments,
        marker: PackagedProjectMarker,
        markerData: Data,
        expectedManifestSHA256: String,
        executable: PackagedExecutableEvidence,
        toolchain: ToolchainInstallationEvidence,
        projectMetadataSHA256: String,
        inputManifestSHA256: String,
        inputDigest: String,
        output: ValidatedPlyArtifactEvidence,
        validateBeforePublication: () async throws -> Void
    ) async throws {
        var lines = [
            "# EasySplat Packaged-App Release Attestation",
            "Schema: 1",
            "Status: passed",
            "App version: \(arguments.appVersion)",
            "Release verification token SHA-256: "
                + arguments.expectedReleaseVerificationTokenSHA256,
            "Executable path SHA-256: \(sha256(Data(executable.path.utf8)))",
            "Executable bytes: \(executable.byteCount)",
            "Executable SHA-256: \(executable.sha256)",
            "Marker SHA-256: \(sha256(markerData))",
            "Project root path SHA-256: \(sha256(Data(marker.projectRoot.utf8)))",
            "Project metadata SHA-256: \(projectMetadataSHA256)",
            "Input path SHA-256: \(sha256(Data(marker.inputPath.utf8)))",
        ]
        lines.append("Input manifest SHA-256: \(inputManifestSHA256)")
        lines += [
            "Input digest: \(inputDigest)",
            "Output path SHA-256: \(sha256(Data(marker.outputPlyPath.utf8)))",
            "Expected packaged manifest file SHA-256: \(expectedManifestSHA256)",
            "Toolchain version JSON: \(try attestationJSON(toolchain.toolchainVersion))",
            "Toolchain key ID JSON: \(try attestationJSON(toolchain.keyID))",
            "Signed payload SHA-256: \(toolchain.canonicalManifestSHA256)",
            "Toolchain signature SHA-256: \(toolchain.signatureSHA256)",
            "Installed closure SHA-256: \(toolchain.closureSHA256)",
            "Installation identity SHA-256: \(toolchain.installationIdentitySHA256)",
        ]
        for (name, digest) in toolchain.installedArtifacts.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "Installed component JSON: "
                    + (try attestationJSON(["name": name, "sha256": digest]))
            )
        }
        lines.append(
            "Installed capabilities JSON: "
                + (try attestationJSON(toolchain.installedCapabilities))
        )
        lines.append("Output bytes: \(output.byteCount)")
        lines.append("Output vertices: \(output.vertexCount)")
        lines.append("Output format: \(output.format)")
        lines.append("Output SHA-256: \(output.sha256)")
        try await publishEvidence(
            lines,
            diagnostic: nil,
            to: arguments.evidence,
            validateBeforePublication: validateBeforePublication
        )
    }

    private static func attestationJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw VerificationError.invalidEvidence(
                "A packaged-app attestation value could not be encoded safely."
            )
        }
        return encoded
    }

    private static func canonicalToolchainRoot(_ path: String) throws -> URL {
        guard (path as NSString).isAbsolutePath else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker toolchain root is not absolute."
            )
        }
        let stated = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let canonical = stated.resolvingSymlinksInPath()
        var status = stat()
        guard canonical.path == stated.path,
              lstat(canonical.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker toolchain root is not a canonical ordinary directory."
            )
        }
        let receipt = canonical.appendingPathComponent(".easysplat_toolchain_state.json")
        var receiptStatus = stat()
        guard lstat(receipt.path, &receiptStatus) == 0,
              (receiptStatus.st_mode & S_IFMT) == S_IFREG,
              (receiptStatus.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              receiptStatus.st_nlink == 1,
              receiptStatus.st_size > 0 else {
            throw VerificationError.invalidEvidence(
                "The packaged-app marker toolchain root has no private signed receipt."
            )
        }
        return canonical
    }

    private static func run(arguments: Arguments) async throws -> SuccessfulRunEvidence {
        let fileManager = FileManager.default
        let resolvedInput = try PackagedProjectInputResolver.resolve(
            manifestURL: arguments.inputManifest,
            inputRoot: arguments.inputRoot
        )
        let expectedInputSnapshot = try ProjectArtifactValidator.captureExpectedInputSnapshot(
            resolvedInput.expectedInput
        )
        let input: InputSpec = switch resolvedInput.expectedInput {
        case .videoFiles(let files):
            .video(files: files.map(\.path))
        case .photoFolder(let folder):
            .photos(folder: folder.path)
        case .mixed(let videoFiles, let photoFolder):
            .mixed(videos: videoFiles.map(\.path), photosFolder: photoFolder.path)
        }

        let publicKeyData = try BoundedFileReader.readRegularFile(
            at: arguments.publicKeyFile,
            maximumBytes: 4 * 1024
        )
        guard let publicKey = String(data: publicKeyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !publicKey.isEmpty else {
            throw VerificationError.invalidPublicKey
        }
        let expectedManifest = try loadExpectedManifest(
            arguments: arguments,
            publicKeyBase64: publicKey
        )
        try fileManager.createDirectory(at: arguments.cacheRoot, withIntermediateDirectories: true)
        let cacheEntries = try fileManager.contentsOfDirectory(atPath: arguments.cacheRoot.path)
        switch arguments.installationPolicy {
        case .cachedOnly where cacheEntries.isEmpty:
            throw VerificationError.nonemptyCacheRoot(
                "Cached-only release-verification root must contain a signed installed toolchain: \(arguments.cacheRoot.path)"
            )
        case .remoteOnly where !cacheEntries.isEmpty:
            throw VerificationError.nonemptyCacheRoot(
                "Release-verification cache root must start empty: \(arguments.cacheRoot.path)"
            )
        case .bundledBootstrapOnly where !cacheEntries.isEmpty:
            throw VerificationError.nonemptyCacheRoot(
                "Release-verification cache root must start empty: \(arguments.cacheRoot.path)"
            )
        default:
            break
        }

        let options = RequestedRunOptions(
            capturePath: .automatic,
            detailProfile: .balanced,
            cameraGrouping: .automatic,
            lensProjection: .automatic,
            inputOrdering: .automatic,
            resourcePolicy: .automatic,
            photoSelection: .automatic
        )
        try RunPlanResolver.validate(requestedOptions: options, input: input)
        let plan = RunPlanResolver.resolveForCurrentHardware(
            requestedOptions: options,
            input: input,
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let request = try plan.toolchainCapabilityRequest()
        let manifestURL: URL
        let bundledBootstrap: ToolchainBootstrap?
        switch arguments.installationPolicy {
        case .remoteOnly:
            manifestURL = arguments.manifestURL
            bundledBootstrap = nil
        case .bundledBootstrapOnly:
            guard let bootstrapManifest = arguments.bootstrapManifest,
                  let bootstrapCoreArchive = arguments.bootstrapCoreArchive else {
                throw VerificationError.usage("Bundled-bootstrap inputs are missing.")
            }
            manifestURL = URL(string: "https://127.0.0.1:1/easysplat-offline-verification.json")!
            bundledBootstrap = ToolchainBootstrap(
                manifestURL: bootstrapManifest,
                coreArchiveURL: bootstrapCoreArchive
            )
        case .cachedOnly:
            manifestURL = URL(string: "https://127.0.0.1:1/easysplat-cached-only-verification.json")!
            bundledBootstrap = nil
        }
        let sourcePolicy: ToolchainSourcePolicy = switch arguments.installationPolicy {
        case .remoteOnly: .automatic
        case .bundledBootstrapOnly: .bundledBootstrapOnly
        case .cachedOnly: .cachedOnly
        }
        let manager = ToolchainManager(
            appVersion: arguments.appVersion,
            localToolchainRoot: nil,
            installationRoot: arguments.cacheRoot,
            allowInsecureLoopbackHTTP: arguments.allowInsecureLoopbackHTTP,
            bundledBootstrap: bundledBootstrap,
            sourcePolicy: sourcePolicy
        )
        let toolchain = try await manager.ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: publicKey,
            request: request
        ) { fraction, message in
            let progress = fraction >= 0 ? " \(Int((fraction * 100).rounded()))%" : ""
            print("Tools:\(progress) \(message)")
        }
        let toolchainEvidenceBeforeRun = try manager.validatedInstallationEvidence(
            root: toolchain.root,
            publicKeyBase64: publicKey,
            request: request,
            matching: expectedManifest.manifest
        )

        let projectParent = arguments.output.deletingLastPathComponent()
        try fileManager.createDirectory(at: projectParent, withIntermediateDirectories: true)
        let projectTitle: String
        switch arguments.installationPolicy {
        case .remoteOnly:
            projectTitle = "Online"
        case .bundledBootstrapOnly:
            projectTitle = "Offline"
        case .cachedOnly:
            projectTitle = "Cached"
        }
        let projectName = "\(projectTitle).easysplatproj"
        let expectedProjectURL = projectParent.appendingPathComponent(
            projectName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: expectedProjectURL.path)
            || (try? fileManager.destinationOfSymbolicLink(
                atPath: expectedProjectURL.path
            )) != nil {
            throw VerificationError.invalidEvidence(
                "Release-verification project path must start absent: "
                    + expectedProjectURL.lastPathComponent
            )
        }
        let preparedProject = try await ReleaseVerificationProjectBuilder.prepare(
            resolvedInput: resolvedInput,
            requestedOptions: options,
            resolvedRunPlan: plan,
            projectParent: projectParent,
            title: projectTitle
        )
        defer { preparedProject.publication.attestation.discard() }
        guard preparedProject.publication.projectURL
            .resolvingSymlinksInPath().standardizedFileURL
            == expectedProjectURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw VerificationError.invalidEvidence(
                "Release-verification project publication chose an unexpected destination."
            )
        }
        let projectURL = preparedProject.publication.projectURL
        let runner = PipelineRunner(
            projectURL: projectURL,
            config: .init(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42),
                resolvedRunPlan: plan
            )
        )
        try await runner.run(
            freshPublicationAttestation: preparedProject.publication.attestation
        ) { event in
            switch event {
            case .stageStarted(let stage):
                print("Stage: \(stage.rawValue)")
            case .stageLog(_, let line, let isError):
                let stream = isError ? FileHandle.standardError : FileHandle.standardOutput
                stream.write(Data("\(line)\n".utf8))
            default:
                break
            }
        }

        let toolchainEvidenceAfterRun = try manager.validatedInstallationEvidence(
            root: toolchain.root,
            publicKeyBase64: publicKey,
            request: request,
            matching: expectedManifest.manifest
        )
        guard toolchainEvidenceAfterRun == toolchainEvidenceBeforeRun else {
            throw VerificationError.invalidEvidence(
                "The installed toolchain changed while release verification was running."
            )
        }
        guard try PackagedProjectInputResolver.resolve(
            manifestURL: arguments.inputManifest,
            inputRoot: arguments.inputRoot
        ) == resolvedInput,
              try ProjectArtifactValidator.captureExpectedInputSnapshot(
                resolvedInput.expectedInput
              ) == expectedInputSnapshot else {
            throw VerificationError.invalidEvidence(
                "The typed release input changed while release verification was running."
            )
        }
        let finishedProject = try await ProjectArtifactValidator.validateFinishedProject(
            at: projectURL,
            expectedInput: resolvedInput.expectedInput,
            authenticatedToolchain: FinishedProjectAuthenticatedToolchain(
                root: toolchain.root,
                installation: toolchainEvidenceAfterRun
            )
        )
        let toolchainEvidenceAfterReplay = try manager.validatedInstallationEvidence(
            root: toolchain.root,
            publicKeyBase64: publicKey,
            request: request,
            matching: expectedManifest.manifest
        )
        guard toolchainEvidenceAfterReplay == toolchainEvidenceBeforeRun else {
            throw VerificationError.invalidEvidence(
                "The installed toolchain changed during signed dataset replay."
            )
        }
        guard try PackagedProjectInputResolver.resolve(
            manifestURL: arguments.inputManifest,
            inputRoot: arguments.inputRoot
        ) == resolvedInput,
              try ProjectArtifactValidator.captureExpectedInputSnapshot(
                resolvedInput.expectedInput
              ) == expectedInputSnapshot else {
            throw VerificationError.invalidEvidence(
                "The typed release input changed during signed dataset replay."
            )
        }
        let trainingArtifact = finishedProject.trainingArtifact
        guard let expectedOutputBytes = trainingArtifact.outputBytes,
              expectedOutputBytes > 0,
              let expectedOutputSHA256 = trainingArtifact.outputSHA256 else {
            throw VerificationError.invalidOutput(
                "The completed run is not bound to one validated training output."
            )
        }
        let outputEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: finishedProject.outputURL,
            to: arguments.output,
            expected: ExpectedPlyArtifactIdentity(
                byteCount: UInt64(expectedOutputBytes),
                vertexCount: trainingArtifact.gaussianCount,
                sha256: expectedOutputSHA256
            )
        )
        switch arguments.installationPolicy {
        case .remoteOnly:
            print("Fresh remote-only signed installation and reconstruction passed.")
        case .bundledBootstrapOnly:
            print("Bundled-bootstrap-only reconstruction passed.")
        case .cachedOnly:
            print("Cached-only offline reconstruction passed.")
        }
        return SuccessfulRunEvidence(
            toolchain: toolchainEvidenceAfterReplay,
            output: outputEvidence,
            publishedManifestFileSHA256: expectedManifest.fileSHA256
        )
    }

    private static func writeEvidence(
        arguments: Arguments,
        successfulEvidence: SuccessfulRunEvidence?,
        runError: Error?
    ) async throws {
        let evidenceURL = arguments.evidence
        let fileManager = FileManager.default
        let evidenceDirectory = evidenceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: evidenceURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: evidenceURL.path)) != nil {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence destination must not already exist."
            )
        }

        let projectURL = projectURL(for: arguments)
        let passed = runError == nil && successfulEvidence != nil
        if runError == nil, successfulEvidence == nil {
            throw VerificationError.invalidEvidence(
                "A successful release-verification lane produced no authenticated evidence."
            )
        }
        var lines = [
            "# EasySplat Release Verification Evidence",
            "Schema: 1",
            "App version: \(arguments.appVersion)",
            "Installation policy: \(arguments.installationPolicy.rawValue)",
            "Status: \(passed ? "passed" : "failed")",
        ]
        if let successfulEvidence {
            lines.append(contentsOf: provenanceLines(for: successfulEvidence))
        } else {
            lines.append(contentsOf: publicAuthorityLines(arguments: arguments))
        }

        if let runError {
            let sanitized = ProjectDiagnosticBundle.sanitizeForSharing(
                runError.localizedDescription,
                projectURL: projectURL
            )
            lines.append("Error: \(sanitized)")
        }

        if successfulEvidence == nil { lines.append("Output: not published") }

        try await publishEvidence(
            lines,
            diagnostic: diagnostic(for: projectURL),
            to: evidenceURL
        )
    }

    private static func diagnostic(for projectURL: URL) -> String? {
        ProjectDiagnosticBundle.build(
            projectURL: projectURL,
            hardwareLine: nil,
            includeNotes: false
        )
    }

    private static func publishEvidence(
        _ lines: [String],
        diagnostic: String?,
        to evidenceURL: URL,
        validateBeforePublication: () async throws -> Void = {}
    ) async throws {
        var text = lines.joined(separator: "\n")
        if let diagnostic, !diagnostic.isEmpty {
            text += "\n\n" + diagnostic
        }
        text = ProjectDiagnosticBundle.sanitizeForSharing(text)
        let payload = Data((text + "\n").utf8)
        let directoryURL = evidenceURL.deletingLastPathComponent()
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence directory could not be opened safely."
            )
        }
        defer { Darwin.close(directory) }
        var directoryIdentity = stat()
        guard fstat(directory, &directoryIdentity) == 0,
              (directoryIdentity.st_mode & S_IFMT) == S_IFDIR else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence directory identity could not be recorded."
            )
        }

        let temporaryName = ".\(evidenceURL.lastPathComponent).\(UUID().uuidString).tmp"
        let temporary = temporaryName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporary >= 0 else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence could not be staged safely."
            )
        }
        var removeTemporary = true
        defer {
            Darwin.close(temporary)
            if removeTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(directory, $0, 0) }
            }
        }

        try payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    temporary,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw VerificationError.invalidEvidence(
                        "Release-verification evidence could not be written durably."
                    )
                }
                written += count
            }
        }
        try synchronizeEvidenceDescriptor(temporary)
        var temporaryIdentity = stat()
        guard fstat(temporary, &temporaryIdentity) == 0,
              (temporaryIdentity.st_mode & S_IFMT) == S_IFREG,
              (temporaryIdentity.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              temporaryIdentity.st_uid == geteuid(),
              temporaryIdentity.st_nlink == 1,
              temporaryIdentity.st_size == payload.count else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence identity could not be recorded."
            )
        }
        try await validateBeforePublication()
        var validatedTemporaryIdentity = stat()
        guard fstat(temporary, &validatedTemporaryIdentity) == 0,
              PackagedMarkerFileIdentity(validatedTemporaryIdentity)
                == PackagedMarkerFileIdentity(temporaryIdentity) else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence changed before publication."
            )
        }
        let renamed = temporaryName.withCString { temporaryPath in
            evidenceURL.lastPathComponent.withCString { finalPath in
                renameatx_np(
                    directory,
                    temporaryPath,
                    directory,
                    finalPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renamed == 0 else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence could not be published atomically."
            )
        }
        removeTemporary = false
        var publishedIdentity = stat()
        do {
            guard fstat(temporary, &publishedIdentity) == 0,
                  publishedIdentity.st_dev == validatedTemporaryIdentity.st_dev,
                  publishedIdentity.st_ino == validatedTemporaryIdentity.st_ino,
                  publishedIdentity.st_uid == validatedTemporaryIdentity.st_uid,
                  publishedIdentity.st_mode == validatedTemporaryIdentity.st_mode,
                  publishedIdentity.st_nlink == validatedTemporaryIdentity.st_nlink,
                  publishedIdentity.st_size == validatedTemporaryIdentity.st_size,
                  publishedIdentity.st_mtimespec.tv_sec
                    == validatedTemporaryIdentity.st_mtimespec.tv_sec,
                  publishedIdentity.st_mtimespec.tv_nsec
                    == validatedTemporaryIdentity.st_mtimespec.tv_nsec,
                  try evidenceDescriptorData(
                      temporary,
                      expectedBytes: payload.count
                  ) == payload else {
                throw VerificationError.invalidEvidence(
                    "Release-verification evidence changed during publication."
                )
            }
            var contentValidatedIdentity = stat()
            guard fstat(temporary, &contentValidatedIdentity) == 0,
                  PackagedMarkerFileIdentity(contentValidatedIdentity)
                    == PackagedMarkerFileIdentity(publishedIdentity) else {
                throw VerificationError.invalidEvidence(
                    "Release-verification evidence changed during publication."
                )
            }
            try requirePublishedEvidenceIdentity(
                at: evidenceURL,
                directory: directory,
                expectedFile: publishedIdentity,
                expectedDirectory: directoryIdentity,
                expectedSize: payload.count
            )
            try synchronizeEvidenceDescriptor(directory)
            try requirePublishedEvidenceIdentity(
                at: evidenceURL,
                directory: directory,
                expectedFile: publishedIdentity,
                expectedDirectory: directoryIdentity,
                expectedSize: payload.count
            )
            var finalDescriptorIdentity = stat()
            guard fstat(temporary, &finalDescriptorIdentity) == 0,
                  PackagedMarkerFileIdentity(finalDescriptorIdentity)
                    == PackagedMarkerFileIdentity(publishedIdentity) else {
                throw VerificationError.invalidEvidence(
                    "Release-verification evidence changed after publication."
                )
            }
            try requirePublishedEvidenceIdentity(
                at: evidenceURL,
                directory: directory,
                expectedFile: publishedIdentity,
                expectedDirectory: directoryIdentity,
                expectedSize: payload.count
            )
        } catch {
            try rollbackPublishedEvidence(
                named: evidenceURL.lastPathComponent,
                expectedIdentity: validatedTemporaryIdentity,
                directory: directory
            )
            throw error
        }
    }

    private static func evidenceDescriptorData(
        _ descriptor: Int32,
        expectedBytes: Int
    ) throws -> Data {
        var result = Data(count: expectedBytes)
        try result.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var consumed = 0
            while consumed < expectedBytes {
                let count = Darwin.pread(
                    descriptor,
                    base.advanced(by: consumed),
                    expectedBytes - consumed,
                    off_t(consumed)
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw VerificationError.invalidEvidence(
                        "Release-verification evidence could not be read back after publication."
                    )
                }
                consumed += count
            }
        }
        return result
    }

    private static func synchronizeEvidenceDescriptor(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw VerificationError.invalidEvidence(
                "Release-verification evidence publication was not durable."
            )
        }
    }

    private static func requirePublishedEvidenceIdentity(
        at evidenceURL: URL,
        directory: Int32,
        expectedFile: stat,
        expectedDirectory: stat,
        expectedSize: Int
    ) throws {
        var published = stat()
        var directoryPath = stat()
        let status = evidenceURL.lastPathComponent.withCString {
            Darwin.fstatat(directory, $0, &published, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              published.st_dev == expectedFile.st_dev,
              published.st_ino == expectedFile.st_ino,
              published.st_uid == expectedFile.st_uid,
              (published.st_mode & S_IFMT) == S_IFREG,
              (published.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
              published.st_nlink == 1,
              published.st_size == expectedSize,
              published.st_mtimespec.tv_sec == expectedFile.st_mtimespec.tv_sec,
              published.st_mtimespec.tv_nsec == expectedFile.st_mtimespec.tv_nsec,
              published.st_ctimespec.tv_sec == expectedFile.st_ctimespec.tv_sec,
              published.st_ctimespec.tv_nsec == expectedFile.st_ctimespec.tv_nsec,
              lstat(evidenceURL.deletingLastPathComponent().path, &directoryPath) == 0,
              directoryPath.st_dev == expectedDirectory.st_dev,
              directoryPath.st_ino == expectedDirectory.st_ino,
              (directoryPath.st_mode & S_IFMT) == S_IFDIR else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence path changed during publication."
            )
        }
    }

    private static func rollbackPublishedEvidence(
        named destinationName: String,
        expectedIdentity: stat,
        directory: Int32
    ) throws {
        let quarantineName = ".\(destinationName).rollback.\(UUID().uuidString).tmp"
        let quarantined = destinationName.withCString { source in
            quarantineName.withCString { destination in
                Darwin.renameatx_np(
                    directory,
                    source,
                    directory,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard quarantined == 0 else {
            if errno == ENOENT {
                try synchronizeEvidenceDescriptor(directory)
                return
            }
            throw VerificationError.invalidEvidence(
                "Release-verification evidence rollback could not quarantine the published path."
            )
        }

        var identity = stat()
        let inspected = quarantineName.withCString {
            Darwin.fstatat(directory, $0, &identity, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0 else {
            throw VerificationError.invalidEvidence(
                "Release-verification evidence rollback could not inspect the quarantined path."
            )
        }
        if identity.st_dev == expectedIdentity.st_dev,
           identity.st_ino == expectedIdentity.st_ino {
            let removed = quarantineName.withCString { Darwin.unlinkat(directory, $0, 0) }
            if removed != 0, errno == ENOENT {
                try synchronizeEvidenceDescriptor(directory)
                return
            }
            guard removed == 0 else {
                throw VerificationError.invalidEvidence(
                    "Release-verification evidence rollback could not remove its staged file."
                )
            }
        } else {
            let restored = quarantineName.withCString { source in
                destinationName.withCString { destination in
                    Darwin.renameatx_np(
                        directory,
                        source,
                        directory,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restored == 0 else {
                throw VerificationError.invalidEvidence(
                    "Release-verification evidence rollback preserved foreign content in quarantine."
                )
            }
        }
        try synchronizeEvidenceDescriptor(directory)
    }

    private static func projectURL(for arguments: Arguments) -> URL {
        let projectName = switch arguments.installationPolicy {
        case .remoteOnly: "Online.easysplatproj"
        case .bundledBootstrapOnly: "Offline.easysplatproj"
        case .cachedOnly: "Cached.easysplatproj"
        }
        return arguments.output.deletingLastPathComponent()
            .appendingPathComponent(projectName, isDirectory: true)
    }

    private static func provenanceLines(for evidence: SuccessfulRunEvidence) -> [String] {
        var lines = [
            "Published manifest file SHA-256: \(evidence.publishedManifestFileSHA256)",
            "Toolchain version: \(evidence.toolchain.toolchainVersion)",
            "Toolchain key ID: \(evidence.toolchain.keyID)",
            "Signed payload SHA-256: \(evidence.toolchain.canonicalManifestSHA256)",
            "Toolchain signature SHA-256: \(evidence.toolchain.signatureSHA256)",
            "Installed closure SHA-256: \(evidence.toolchain.closureSHA256)",
            "Installation identity SHA-256: \(evidence.toolchain.installationIdentitySHA256)",
        ]
        for (name, digest) in evidence.toolchain.installedArtifacts.sorted(by: { $0.key < $1.key }) {
            lines.append("Installed component: \(name) \(digest)")
        }
        lines.append(
            "Installed capabilities: \(evidence.toolchain.installedCapabilities.joined(separator: ", "))"
        )
        lines.append("Output bytes: \(evidence.output.byteCount)")
        lines.append("Output vertices: \(evidence.output.vertexCount)")
        lines.append("Output format: \(evidence.output.format)")
        lines.append("Output SHA-256: \(evidence.output.sha256)")
        return lines
    }

    private static func publicAuthorityLines(arguments: Arguments) -> [String] {
        guard let data = try? BoundedFileReader.readRegularFile(
            at: arguments.publicKeyFile,
            maximumBytes: 4 * 1024
        ),
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let keyID = ToolchainManifest.keyID(publicKeyBase64: value) else {
            return ["Toolchain key ID: unavailable"]
        }
        return ["Toolchain key ID: \(keyID)"]
    }

    private static func loadExpectedManifest(
        arguments: Arguments,
        publicKeyBase64: String
    ) throws -> ExpectedManifestEvidence {
        let data: Data
        do {
            data = try BoundedFileReader.readRegularFile(
                at: arguments.expectedManifest,
                maximumBytes: ToolchainManifest.maximumEncodedBytes
            )
        } catch {
            throw VerificationError.invalidEvidence(
                "The expected published manifest could not be read safely."
            )
        }
        let fileSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard fileSHA256 == arguments.expectedManifestFileSHA256 else {
            throw VerificationError.invalidEvidence(
                "The expected published manifest does not match its verified file digest."
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data),
              manifest.hasMatchingKeyID(publicKeyBase64: publicKeyBase64),
              manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            throw VerificationError.invalidEvidence(
                "The expected published manifest could not be authenticated."
            )
        }
        return ExpectedManifestEvidence(manifest: manifest, fileSHA256: fileSHA256)
    }
}
