import Darwin
import EasySplatCore
import Foundation

extension AppModel {
    private struct ReleaseVerificationEvidence: Codable {
        var schemaVersion: Int
        var toolchainRoot: String
        var requestedCapabilities: [String]
        var inputFolder: String
    }

    func prepareBundledToolchainForReleaseVerification(
        photoFolder: URL,
        successMarkerURL: URL
    ) async throws {
        let input = InputSpec.photos(folder: photoFolder.standardizedFileURL.path)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        try RunPlanResolver.validate(
            requestedOptions: requestedOptions,
            input: input,
            hardware: hardwareProfile
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: input,
            hardware: hardwareProfile,
            developmentOverrides: DevelopmentOverrides()
        )
        let request = try plan.toolchainCapabilityRequest()
        let toolchain = try await toolchainManager.ensureToolchain(
            manifestURL: AppConfig.toolchainManifestURL,
            publicKeyBase64: AppConfig.toolchainPublicKeyBase64,
            request: request
        ) { _, _ in }

        let evidence = ReleaseVerificationEvidence(
            schemaVersion: 1,
            toolchainRoot: toolchain.root.standardizedFileURL.path,
            requestedCapabilities: request.capabilities.map(\.rawValue).sorted(),
            inputFolder: photoFolder.standardizedFileURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.writeReleaseVerificationMarker(
            try encoder.encode(evidence),
            to: successMarkerURL
        )
    }

    nonisolated static func writeReleaseVerificationMarker(
        _ data: Data,
        to destination: URL,
        directorySynchronizer: (URL) throws -> Void = synchronizeReleaseVerificationDirectory
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var renamedDestination = false
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: temporary, to: destination)
            renamedDestination = true
            try directorySynchronizer(parent)
        } catch {
            if renamedDestination {
                try? fileManager.removeItem(at: destination)
                try? directorySynchronizer(parent)
            } else {
                try? fileManager.removeItem(at: temporary)
            }
            throw error
        }
    }

    private nonisolated static func synchronizeReleaseVerificationDirectory(_ directory: URL) throws {
        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
