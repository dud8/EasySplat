import Darwin
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum PhotoInputReceiptValidationError: Error, LocalizedError, Equatable, Sendable {
    case unexpectedReceipts
    case missingReceipts
    case unexpectedSelectionReceipt
    case missingSelectionReceipt
    case invalidSelectionReceipt
    case invalidSelectionArtifact
    case invalidPhotoRoot
    case invalidReceipt(index: Int)
    case duplicateLeaf(index: Int)
    case duplicateDigest(index: Int)
    case duplicateRetainedRank(index: Int)
    case noncontiguousRetainedRanks
    case fileUnavailable(index: Int)
    case sizeMismatch(index: Int)
    case digestMismatch(index: Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedReceipts: return "Project metadata has photo receipts but no photo input."
        case .missingReceipts: return "Project metadata is missing its photo input receipts."
        case .unexpectedSelectionReceipt: return "Project metadata has photo selection evidence without retained photos."
        case .missingSelectionReceipt: return "Project metadata is missing its photo selection evidence."
        case .invalidSelectionReceipt: return "The photo selection receipt is invalid."
        case .invalidSelectionArtifact: return "The photo selection evidence could not be verified."
        case .invalidPhotoRoot: return "The photo input root is not the controlled project photo directory."
        case .invalidReceipt(let index): return "Photo receipt \(index + 1) is invalid."
        case .duplicateLeaf(let index): return "Photo receipt \(index + 1) reuses a controlled filename."
        case .duplicateDigest(let index): return "Photo receipt \(index + 1) duplicates another photo."
        case .duplicateRetainedRank(let index): return "Photo receipt \(index + 1) reuses a selection rank."
        case .noncontiguousRetainedRanks: return "Photo receipt selection ranks are incomplete."
        case .fileUnavailable(let index): return "The controlled copy for photo \(index + 1) is unavailable."
        case .sizeMismatch(let index): return "The controlled copy for photo \(index + 1) has changed size."
        case .digestMismatch(let index): return "The controlled copy for photo \(index + 1) no longer matches its receipt."
        }
    }
}

public enum PhotoInputReceiptValidator {
    public static func validateMetadata(
        _ metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        guard let photoRoot = metadata.input.photosFolder else {
            guard metadata.photoInputReceipts?.isEmpty != false else {
                throw PhotoInputReceiptValidationError.unexpectedReceipts
            }
            guard metadata.photoSelectionReceipt == nil else {
                throw PhotoInputReceiptValidationError.unexpectedSelectionReceipt
            }
            return
        }
        guard photoRoot == "Originals/Photos" else {
            throw PhotoInputReceiptValidationError.invalidPhotoRoot
        }
        guard let receipts = metadata.photoInputReceipts else {
            throw PhotoInputReceiptValidationError.missingReceipts
        }
        if case .photos = metadata.input, receipts.isEmpty {
            throw PhotoInputReceiptValidationError.missingReceipts
        }
        var leaves = Set<String>()
        var sourceDigests = Set<String>()
        var retainedRanks = Set<Int>()
        for (index, receipt) in receipts.enumerated() {
            let components = receipt.projectRelativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard structurallyValid(receipt),
                  components.count == 3,
                  components[0] == "Originals",
                  components[1] == "Photos",
                  controlledLeaf(
                    components[2],
                    index: index,
                    typeIdentifier: receipt.typeIdentifier
                  ),
                  (try? paths.resolveProjectRelativePath(receipt.projectRelativePath)) != nil else {
                throw PhotoInputReceiptValidationError.invalidReceipt(index: index)
            }
            guard leaves.insert(components[2]).inserted else {
                throw PhotoInputReceiptValidationError.duplicateLeaf(index: index)
            }
            guard sourceDigests.insert(receipt.source.sha256).inserted else {
                throw PhotoInputReceiptValidationError.duplicateDigest(index: index)
            }
            guard retainedRanks.insert(receipt.retainedRank).inserted else {
                throw PhotoInputReceiptValidationError.duplicateRetainedRank(index: index)
            }
        }
        guard retainedRanks == Set(0..<receipts.count) else {
            throw PhotoInputReceiptValidationError.noncontiguousRetainedRanks
        }
        if receipts.isEmpty {
            guard metadata.photoSelectionReceipt == nil else {
                throw PhotoInputReceiptValidationError.unexpectedSelectionReceipt
            }
        } else {
            guard let selectionReceipt = metadata.photoSelectionReceipt else {
                throw PhotoInputReceiptValidationError.missingSelectionReceipt
            }
            guard selectionReceipt.isCurrentStructurallyValid else {
                throw PhotoInputReceiptValidationError.invalidSelectionReceipt
            }
        }
    }

    public static func validateFiles(metadata: ProjectMetadata, paths: ProjectPaths) throws {
        try validateMetadata(metadata, paths: paths)
        guard let receipts = metadata.photoInputReceipts else { return }
        for (index, receipt) in receipts.enumerated() {
            guard let file = try? paths.resolveProjectRelativePath(receipt.projectRelativePath) else {
                throw PhotoInputReceiptValidationError.fileUnavailable(index: index)
            }
            var status = stat()
            guard lstat(file.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == getuid(),
                  status.st_nlink == 1,
                  status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
                throw PhotoInputReceiptValidationError.fileUnavailable(index: index)
            }
            guard status.st_size == receipt.byteCount else {
                throw PhotoInputReceiptValidationError.sizeMismatch(index: index)
            }
            let digest: String
            do {
                digest = try descriptorBoundSHA256(of: file, expected: status)
            } catch {
                throw PhotoInputReceiptValidationError.fileUnavailable(index: index)
            }
            guard digest == receipt.sha256 else {
                throw PhotoInputReceiptValidationError.digestMismatch(index: index)
            }
        }
        guard receipts.isEmpty || (try? PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: paths
        )) != nil else {
            throw PhotoInputReceiptValidationError.invalidSelectionArtifact
        }
    }

    private static func descriptorBoundSHA256(of file: URL, expected: stat) throws -> String {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameFile(opened, expected) else {
            throw CocoaError(.fileReadUnknown)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= expected.st_size else { throw CocoaError(.fileReadCorruptFile) }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var final = stat()
        var rebound = stat()
        guard total == expected.st_size,
              fstat(descriptor, &final) == 0,
              lstat(file.path, &rebound) == 0,
              sameFile(final, expected),
              sameFile(rebound, expected) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        (lhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func structurallyValid(_ receipt: PhotoInputReceipt) -> Bool {
        guard receipt.schemaVersion == PhotoInputReceipt.currentSchemaVersion
            && receipt.byteCount > 0
            && validDigest(receipt.sha256)
            && receipt.retainedRank >= 0
            && safeName(receipt.safeDisplayName)
            && (1...131_072).contains(receipt.pixelWidth)
            && (1...131_072).contains(receipt.pixelHeight)
            && (1...8).contains(receipt.orientation)
            && ["public.jpeg", "public.png", "public.heic", "public.heif"]
                .contains(receipt.typeIdentifier),
              receipt.source.byteCount > 0,
              validDigest(receipt.source.sha256),
              !receipt.source.typeIdentifier.isEmpty,
              validAnalysisEvidence(
                receipt.analysisEvidence,
                sourceSHA256: receipt.source.sha256
              ) else {
            return false
        }
        switch receipt.importMode {
        case .unchanged:
            return receipt.source.byteCount == receipt.byteCount
                && receipt.source.sha256 == receipt.sha256
                && receipt.source.typeIdentifier == receipt.typeIdentifier
        case .rawDevelopment(let evidence):
            guard receipt.typeIdentifier == "public.png",
                  receipt.orientation == 1,
                  let sourceType = UTType(receipt.source.typeIdentifier),
                  sourceType.conforms(to: .rawImage),
                  evidence.decoderIdentifier == "com.apple.CoreImage.CIRAWFilter",
                  !evidence.decoderVersion.isEmpty,
                  (1...131_072).contains(evidence.nativePixelWidth),
                  (1...131_072).contains(evidence.nativePixelHeight),
                  (1...8).contains(evidence.sourceOrientation) else {
                return false
            }
            return validRawSettings(evidence.settings)
        }
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func validAnalysisEvidence(
        _ evidence: PhotoAnalysisEvidence,
        sourceSHA256: String
    ) -> Bool {
        guard evidence.sourceSHA256 == sourceSHA256,
              evidence.analysisRecipeVersion == PhotoAnalysisEvidence.currentRecipeVersion,
              evidence.analysisRecipeSHA256 == PhotoAnalysisEvidence.currentRecipeSHA256 else {
            return false
        }
        do {
            _ = try PhotoDiversitySelector.rank(
                [evidence],
                targetCount: 0,
                checkCancellation: {}
            )
            return true
        } catch {
            return false
        }
    }

    private static func validRawSettings(_ settings: RawDevelopmentSettings) -> Bool {
        settings == .production(maximumPixelDimension: settings.maximumPixelDimension)
            && (1...16_384).contains(settings.maximumPixelDimension)
    }

    private static func controlledLeaf(
        _ leaf: String,
        index: Int,
        typeIdentifier: String
    ) -> Bool {
        let prefix = String(format: "photo-%04d.", index)
        guard leaf.hasPrefix(prefix) else { return false }
        let expectedExtension: String
        switch typeIdentifier {
        case "public.jpeg": expectedExtension = "jpg"
        case "public.png": expectedExtension = "png"
        case "public.heic": expectedExtension = "heic"
        case "public.heif": expectedExtension = "heif"
        default: return false
        }
        return leaf.dropFirst(prefix.count) == expectedExtension
    }

    private static func safeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == name && name.count <= 96
            && name.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.illegalCharacters.contains($0)
                    && $0.properties.generalCategory != .format
            }
    }
}
