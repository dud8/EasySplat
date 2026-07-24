import Darwin
import Foundation

public enum DatasetPoseSeedReceiptValidationError: Error, LocalizedError, Equatable, Sendable {
    case unexpectedReceipt
    case missingReceipt
    case unsupportedSchemaVersion(Int)
    case noEntries
    case imageCountMismatch(declared: Int, actual: Int)
    case invalidSeedManifest
    case invalidFile(path: String)
    case unsafePath(String)
    case invalidEntry(index: Int)
    case duplicateEntryID(index: Int)
    case duplicateAdoptedFileName(index: Int)
    case fileUnavailable(path: String)
    case sizeMismatch(path: String)
    case digestMismatch(path: String)
    case photoReceiptClosureMismatch
    case seedImageClosureMismatch

    public var errorDescription: String? {
        switch self {
        case .unexpectedReceipt:
            return "Project metadata has a dataset pose seed receipt without a dataset input."
        case .missingReceipt:
            return "Project metadata is missing its dataset pose seed receipt."
        case .unsupportedSchemaVersion(let version):
            return "The dataset pose seed receipt uses unsupported schema version \(version)."
        case .noEntries:
            return "The dataset pose seed receipt declares no image entries."
        case .imageCountMismatch(let declared, let actual):
            return "The dataset pose seed receipt declares \(declared) images but lists \(actual) entries."
        case .invalidSeedManifest:
            return "The dataset pose seed must contain exactly cameras.txt, images.txt, and points3D.txt under Import/seed."
        case .invalidFile(let path):
            return "The dataset receipt describes \(path) with an invalid manifest entry."
        case .unsafePath(let path):
            return "The dataset pose seed receipt references an unsafe project path: \(path)."
        case .invalidEntry(let index):
            return "Dataset pose seed entry \(index + 1) is invalid."
        case .duplicateEntryID(let index):
            return "Dataset pose seed entry \(index + 1) reuses a declared entry identity."
        case .duplicateAdoptedFileName(let index):
            return "Dataset pose seed entry \(index + 1) reuses an adopted photo filename."
        case .fileUnavailable(let path):
            return "The controlled copy of \(path) is unavailable."
        case .sizeMismatch(let path):
            return "The controlled copy of \(path) has changed size."
        case .digestMismatch(let path):
            return "The controlled copy of \(path) no longer matches its receipt."
        case .photoReceiptClosureMismatch:
            return "The dataset pose seed entries do not correspond one-to-one to the imported photos."
        case .seedImageClosureMismatch:
            return "The dataset pose seed entries do not correspond one-to-one to the imported seed images."
        }
    }
}

/// Validates the immutable receipt contract for a pre-processed dataset import.
/// Mirrors `PhotoInputReceiptValidator`: a pure structural pass over the receipt
/// and a file-level pass that re-verifies each persisted file on disk with the
/// same descriptor-bound, TOCTOU-hardened digest the photo and video receipts use.
public enum DatasetPoseSeedReceiptValidator {
    /// Enforces the persisted invariant `input.isDataset ⇔ datasetPoseSeed != nil`, then runs
    /// the structural receipt pass when a receipt is present. Mirrors the photo validator's
    /// missing/unexpected symmetry so metadata that gained or lost its dataset seed out of
    /// band cannot load.
    public static func validateMetadata(_ metadata: ProjectMetadata) throws {
        if metadata.input.isDataset {
            guard let receipt = metadata.datasetPoseSeed else {
                throw DatasetPoseSeedReceiptValidationError.missingReceipt
            }
            try validateMetadata(receipt)
        } else {
            guard metadata.datasetPoseSeed == nil else {
                throw DatasetPoseSeedReceiptValidationError.unexpectedReceipt
            }
        }
    }

    public static func validateMetadata(_ receipt: DatasetPoseSeedReceipt) throws {
        guard receipt.schemaVersion == DatasetPoseSeedReceipt.currentSchemaVersion else {
            throw DatasetPoseSeedReceiptValidationError.unsupportedSchemaVersion(receipt.schemaVersion)
        }
        guard !receipt.entries.isEmpty else {
            throw DatasetPoseSeedReceiptValidationError.noEntries
        }
        guard receipt.imageCount == receipt.entries.count else {
            throw DatasetPoseSeedReceiptValidationError.imageCountMismatch(
                declared: receipt.imageCount,
                actual: receipt.entries.count
            )
        }

        // Reject unsafe file paths before any structural interpretation so a path
        // that escapes the bundle can never be resolved on disk.
        for file in receipt.seedFiles + receipt.sourceFiles {
            guard isSafeProjectRelativePath(file.projectRelativePath) else {
                throw DatasetPoseSeedReceiptValidationError.unsafePath(file.projectRelativePath)
            }
        }

        let expectedSeedPaths = Set(DatasetPoseSeedReceipt.seedFileRelativePaths)
        guard receipt.seedFiles.count == expectedSeedPaths.count,
              Set(receipt.seedFiles.map(\.projectRelativePath)) == expectedSeedPaths else {
            throw DatasetPoseSeedReceiptValidationError.invalidSeedManifest
        }

        let sourcePrefix = DatasetPoseSeedReceipt.sourceDirectoryRelativePath + "/"
        for file in receipt.seedFiles {
            guard fileIsStructurallyValid(file) else {
                throw DatasetPoseSeedReceiptValidationError.invalidFile(path: file.projectRelativePath)
            }
        }
        for file in receipt.sourceFiles {
            guard fileIsStructurallyValid(file),
                  file.projectRelativePath.hasPrefix(sourcePrefix) else {
                throw DatasetPoseSeedReceiptValidationError.invalidFile(path: file.projectRelativePath)
            }
        }

        var seenEntryIDs = Set<String>()
        var seenAdoptedFileNames = Set<String>()
        for (index, entry) in receipt.entries.enumerated() {
            guard entryIsStructurallyValid(entry) else {
                throw DatasetPoseSeedReceiptValidationError.invalidEntry(index: index)
            }
            guard seenEntryIDs.insert(entry.entryID).inserted else {
                throw DatasetPoseSeedReceiptValidationError.duplicateEntryID(index: index)
            }
            guard seenAdoptedFileNames.insert(entry.adoptedFileName).inserted else {
                throw DatasetPoseSeedReceiptValidationError.duplicateAdoptedFileName(index: index)
            }
        }
    }

    public static func validateFiles(
        receipt: DatasetPoseSeedReceipt,
        projectRoot: URL
    ) throws {
        try validateMetadata(receipt)
        let paths = ProjectPaths(root: projectRoot)
        for file in receipt.seedFiles + receipt.sourceFiles {
            try verifyFile(file, paths: paths)
        }
    }

    /// Proves the entry mapping is a validated one-to-one closure at run start:
    /// every declared image resolves to exactly one admitted photo and one seed
    /// model image, and no photo or seed image is left over. Binding each entry
    /// to a receipt by both its content digest and its adopted file name (not the
    /// digest alone) is what makes a swap of two entries' digests detectable —
    /// the moved digest no longer pairs with its recorded adopted name.
    public static func validateClosure(
        receipt: DatasetPoseSeedReceipt,
        photoReceipts: [PhotoInputReceipt],
        seedModel: ColmapTextModel
    ) throws {
        try validateMetadata(receipt)

        guard receipt.entries.count == photoReceipts.count else {
            throw DatasetPoseSeedReceiptValidationError.photoReceiptClosureMismatch
        }
        var remainingReceipts: [PhotoReceiptClosureKey: Int] = [:]
        for photoReceipt in photoReceipts {
            let key = PhotoReceiptClosureKey(
                sourceSHA256: photoReceipt.source.sha256,
                adoptedFileName: (photoReceipt.projectRelativePath as NSString).lastPathComponent
            )
            remainingReceipts[key, default: 0] += 1
        }
        for entry in receipt.entries {
            let key = PhotoReceiptClosureKey(
                sourceSHA256: entry.sourceSHA256,
                adoptedFileName: entry.adoptedFileName
            )
            guard let count = remainingReceipts[key], count > 0 else {
                throw DatasetPoseSeedReceiptValidationError.photoReceiptClosureMismatch
            }
            remainingReceipts[key] = count - 1
        }

        guard receipt.entries.count == seedModel.images.count else {
            throw DatasetPoseSeedReceiptValidationError.seedImageClosureMismatch
        }
        var remainingSeedImages: [String: Int] = [:]
        for image in seedModel.images {
            remainingSeedImages[image.name, default: 0] += 1
        }
        for entry in receipt.entries {
            guard let count = remainingSeedImages[entry.declaredPath], count > 0 else {
                throw DatasetPoseSeedReceiptValidationError.seedImageClosureMismatch
            }
            remainingSeedImages[entry.declaredPath] = count - 1
        }
    }

    private struct PhotoReceiptClosureKey: Hashable {
        let sourceSHA256: String
        let adoptedFileName: String
    }

    private static func verifyFile(_ file: DatasetReceiptFile, paths: ProjectPaths) throws {
        guard let url = try? paths.resolveProjectRelativePath(file.projectRelativePath) else {
            throw DatasetPoseSeedReceiptValidationError.fileUnavailable(path: file.projectRelativePath)
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(0o7777) == mode_t(0o600) else {
            throw DatasetPoseSeedReceiptValidationError.fileUnavailable(path: file.projectRelativePath)
        }
        guard status.st_size == Int64(file.byteCount) else {
            throw DatasetPoseSeedReceiptValidationError.sizeMismatch(path: file.projectRelativePath)
        }
        let digest: String
        do {
            digest = try GeometryArtifactStore.sha256(
                of: url,
                maximumBytes: UInt64(file.byteCount)
            )
        } catch {
            throw DatasetPoseSeedReceiptValidationError.fileUnavailable(path: file.projectRelativePath)
        }
        guard digest == file.sha256 else {
            throw DatasetPoseSeedReceiptValidationError.digestMismatch(path: file.projectRelativePath)
        }
    }

    private static func fileIsStructurallyValid(_ file: DatasetReceiptFile) -> Bool {
        file.byteCount > 0 && GeometryArtifactStore.isSHA256(file.sha256)
    }

    private static func entryIsStructurallyValid(_ entry: DatasetReceiptEntry) -> Bool {
        !entry.entryID.isEmpty
            && DatasetDeclaredPath.normalized(entry.declaredPath) != nil
            && isSafeFileName(entry.adoptedFileName)
            && GeometryArtifactStore.isSHA256(entry.sourceSHA256)
    }

    private static func isSafeProjectRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else { return false }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar != "/"
                && !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && scalar.properties.generalCategory != .format
        }
    }
}
