import Darwin
import Foundation

public enum VideoInputReceiptValidationError: Error, LocalizedError, Equatable, Sendable {
    case unexpectedReceipts
    case missingReceipts
    case receiptCountMismatch(expected: Int, actual: Int)
    case invalidReceipt(index: Int)
    case inputPathMismatch(index: Int)
    case duplicateLeaf(index: Int)
    case duplicateDigest(index: Int)
    case fileUnavailable(index: Int)
    case sizeMismatch(index: Int)
    case digestMismatch(index: Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedReceipts:
            return "Project metadata has video receipts but no video inputs."
        case .missingReceipts:
            return "Project metadata is missing its video input receipts."
        case .receiptCountMismatch(let expected, let actual):
            return "Project metadata has \(actual) video receipts for \(expected) video inputs."
        case .invalidReceipt(let index):
            return "Video receipt \(index + 1) is invalid."
        case .inputPathMismatch(let index):
            return "Video input \(index + 1) does not match its controlled project copy."
        case .duplicateLeaf(let index):
            return "Video receipt \(index + 1) reuses a controlled project filename."
        case .duplicateDigest(let index):
            return "Video receipt \(index + 1) duplicates another selected video."
        case .fileUnavailable(let index):
            return "The controlled copy for video \(index + 1) is unavailable."
        case .sizeMismatch(let index):
            return "The controlled copy for video \(index + 1) has changed size."
        case .digestMismatch(let index):
            return "The controlled copy for video \(index + 1) no longer matches its receipt."
        }
    }
}

/// Validates the immutable receipt contract for videos adopted into a project bundle.
public enum VideoInputReceiptValidator {
    public static func validateMetadata(
        _ metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        let inputs = metadata.input.videoFiles
        let receipts = metadata.videoInputReceipts
        guard !inputs.isEmpty else {
            guard receipts?.isEmpty != false else {
                throw VideoInputReceiptValidationError.unexpectedReceipts
            }
            return
        }
        guard let receipts else {
            throw VideoInputReceiptValidationError.missingReceipts
        }
        guard receipts.count == inputs.count else {
            throw VideoInputReceiptValidationError.receiptCountMismatch(
                expected: inputs.count,
                actual: receipts.count
            )
        }

        var leaves = Set<String>()
        var analysisLeaves = Set<String>()
        var digests = Set<String>()
        for (index, pair) in zip(inputs, receipts).enumerated() {
            let (input, receipt) = pair
            guard receiptIsStructurallyValid(receipt),
                  (try? paths.resolveProjectRelativePath(receipt.projectRelativePath)) != nil else {
                throw VideoInputReceiptValidationError.invalidReceipt(index: index)
            }

            let components = receipt.projectRelativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard components.count == 2,
                  components[0] == "Originals",
                  controlledLeaf(components[1], matches: index) else {
                throw VideoInputReceiptValidationError.invalidReceipt(index: index)
            }
            guard input == receipt.projectRelativePath else {
                throw VideoInputReceiptValidationError.inputPathMismatch(index: index)
            }
            guard leaves.insert(components[1]).inserted else {
                throw VideoInputReceiptValidationError.duplicateLeaf(index: index)
            }
            guard digests.insert(receipt.sha256).inserted else {
                throw VideoInputReceiptValidationError.duplicateDigest(index: index)
            }
            let analysisComponents = receipt.analysisArtifactPath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            let fixedAnalysisLeaf = String(
                format: "video-analysis-%04d.json",
                index
            )
            let regeneratedAnalysisLeaf = String(
                format: "video-analysis-%04d-%@.json",
                index,
                receipt.analysisArtifactSHA256
            )
            guard analysisComponents.count == 2,
                  analysisComponents[0] == "Frames",
                  analysisComponents[1] == fixedAnalysisLeaf
                    || analysisComponents[1] == regeneratedAnalysisLeaf,
                  (try? paths.resolveProjectRelativePath(receipt.analysisArtifactPath)) != nil,
                  analysisLeaves.insert(analysisComponents[1]).inserted else {
                throw VideoInputReceiptValidationError.invalidReceipt(index: index)
            }
        }
        if let pairingPolicy = metadata.resolvedRunPlan?.pairingPolicy {
            let identities: [VideoClipIdentity]
            do {
                identities = try VideoClipIdentityResolver.resolve(
                    sourceSHA256s: receipts.map(\.sha256),
                    pairingPolicy: pairingPolicy
                )
            } catch {
                throw VideoInputReceiptValidationError.invalidReceipt(index: 0)
            }
            for identity in identities {
                guard receipts[identity.sourceIndex].clipGroupID == identity.groupID else {
                    throw VideoInputReceiptValidationError.invalidReceipt(
                        index: identity.sourceIndex
                    )
                }
            }
        }
    }

    public static func validateFiles(
        metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        try validateMetadata(metadata, paths: paths)
        guard let receipts = metadata.videoInputReceipts else { return }

        for (index, receipt) in receipts.enumerated() {
            guard let file = try? paths.resolveProjectRelativePath(receipt.projectRelativePath) else {
                throw VideoInputReceiptValidationError.fileUnavailable(index: index)
            }
            var status = stat()
            guard lstat(file.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1 else {
                throw VideoInputReceiptValidationError.fileUnavailable(index: index)
            }
            guard status.st_size == receipt.byteCount else {
                throw VideoInputReceiptValidationError.sizeMismatch(index: index)
            }
            let digest: String
            do {
                digest = try GeometryArtifactStore.sha256(
                    of: file,
                    maximumBytes: UInt64(receipt.byteCount)
                )
            } catch {
                throw VideoInputReceiptValidationError.fileUnavailable(index: index)
            }
            guard digest == receipt.sha256 else {
                throw VideoInputReceiptValidationError.digestMismatch(index: index)
            }
            guard let analysisFile = try? paths.resolveProjectRelativePath(
                receipt.analysisArtifactPath
            ) else {
                throw VideoInputReceiptValidationError.fileUnavailable(index: index)
            }
            var analysisStatus = stat()
            guard lstat(analysisFile.path, &analysisStatus) == 0,
                  (analysisStatus.st_mode & S_IFMT) == S_IFREG,
                  analysisStatus.st_nlink == 1 else {
                throw VideoInputReceiptValidationError.fileUnavailable(index: index)
            }
            guard analysisStatus.st_size == receipt.analysisArtifactByteCount else {
                throw VideoInputReceiptValidationError.sizeMismatch(index: index)
            }
            let analysisDigest: String
            do {
                analysisDigest = try GeometryArtifactStore.sha256(
                    of: analysisFile,
                    maximumBytes: UInt64(receipt.analysisArtifactByteCount)
                )
            } catch {
                throw VideoInputReceiptValidationError.fileUnavailable(index: index)
            }
            guard analysisDigest == receipt.analysisArtifactSHA256 else {
                throw VideoInputReceiptValidationError.digestMismatch(index: index)
            }
        }
    }

    private static func receiptIsStructurallyValid(_ receipt: VideoInputReceipt) -> Bool {
        let transform = [
            receipt.transformA,
            receipt.transformB,
            receipt.transformC,
            receipt.transformD,
            receipt.transformTX,
            receipt.transformTY,
        ]
        let determinant = receipt.transformA * receipt.transformD
            - receipt.transformB * receipt.transformC
        return receipt.schemaVersion == VideoInputReceipt.currentSchemaVersion
            && receipt.byteCount > 0
            && receipt.sha256.utf8.count == 64
            && receipt.sha256.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 97 && scalar.value <= 102)
            }
            && safeDisplayNameIsValid(receipt.safeDisplayName)
            && receipt.trackID > 0
            && (1...131_072).contains(receipt.pixelWidth)
            && (1...131_072).contains(receipt.pixelHeight)
            && receipt.durationSeconds.isFinite
            && receipt.durationSeconds > 0
            && receipt.nominalFrameRate.isFinite
            && receipt.nominalFrameRate >= 0
            && receipt.decodedFrameCount > 0
            && !receipt.clipGroupID.isEmpty
            && receipt.clipGroupID.utf8.count <= 160
            && receipt.clipGroupID.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar == "_"
            }
            && isSHA256(receipt.analysisPolicySHA256)
            && receipt.analysisArtifactByteCount > 0
            && receipt.analysisArtifactByteCount
                <= Int64(VideoFrameAnalysisArtifactStore.maximumArtifactBytes)
            && isSHA256(receipt.analysisArtifactSHA256)
            && transform.allSatisfy(\.isFinite)
            && determinant.isFinite
            && abs(determinant) > 1e-12
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 97 && scalar.value <= 102)
            }
    }

    private static func safeDisplayNameIsValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && name.count <= 96
            && name == trimmed
            && name.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.illegalCharacters.contains(scalar)
                    && !CharacterSet.newlines.contains(scalar)
                    && scalar.properties.generalCategory != .format
            }
    }

    private static func controlledLeaf(_ leaf: String, matches index: Int) -> Bool {
        let prefix = String(format: "video-%04d.", index)
        guard leaf.hasPrefix(prefix) else { return false }
        let fileExtension = String(leaf.dropFirst(prefix.count))
        return !fileExtension.isEmpty
            && fileExtension.utf8.count <= 8
            && fileExtension.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 97 && scalar.value <= 122)
            }
    }
}
