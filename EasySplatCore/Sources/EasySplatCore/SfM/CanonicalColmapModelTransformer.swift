import Darwin
import Foundation

/// Publishes the accepted COLMAP model in EasySplat's canonical world frame.
/// Image observations and intrinsics stay byte-identical; only world points and
/// world-to-camera rotations change. A receipt inside the swapped directory
/// makes publication idempotent across a later metadata-write failure.
enum CanonicalColmapModelTransformer {
    static let receiptFileName = "easysplat_canonical_orientation.json"
    static let canonicalLearnedPointFileName = "learned_points3D.txt"
    static let maximumAllowedResidualDifference = 1e-6

    enum PublicationCheckpoint: Sendable, Equatable {
        case beforeSwap
        case afterSwap
        case beforePublishedValidation
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidOrientation
        case malformedRecord(file: String, line: Int)
        case incompleteImagesFile
        case residualsChanged(Double)
        case modelFactsChanged
        case invalidReceipt
        case unsafeLayout
        case synchronizationFailed(Int32)
        case atomicSwapFailed(Int32)
        case atomicRollbackFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidOrientation:
                return "The canonical orientation is not a proper rotation."
            case .malformedRecord(let file, let line):
                return "Canonical orientation found malformed \(file) data at line \(line)."
            case .incompleteImagesFile:
                return "Canonical orientation found an image pose without its observation line."
            case .residualsChanged(let maximumDifference):
                return String(
                    format: "Canonical orientation changed a measured residual by %.9g pixels.",
                    maximumDifference
                )
            case .modelFactsChanged:
                return "Canonical orientation changed measured reconstruction facts."
            case .invalidReceipt:
                return "The canonical orientation receipt does not match the accepted model."
            case .unsafeLayout:
                return "Canonical orientation found an unsafe model directory layout."
            case .synchronizationFailed(let code):
                return "Could not durably synchronize canonical geometry (errno \(code))."
            case .atomicSwapFailed(let code):
                return "Could not atomically publish canonical geometry (errno \(code))."
            case .atomicRollbackFailed(let code):
                return "Could not safely restore geometry after publication failed (errno \(code))."
            }
        }
    }

    struct LearnedPointInitializer: Sendable, Equatable {
        let sourceURL: URL
        let expectedPointCount: Int
        let expectedSHA256: String
    }

    struct Result {
        let artifact: CanonicalOrientationArtifact
        let measurement: ColmapResidualAnalyzer.Result
        let snapshot: GeometryModelSnapshot.Verified
        let learnedPointInitializer: Da3LearnedPointInitializer.Validation?
        let maximumResidualDifference: Double
        let didTransform: Bool
    }

    private struct ReceiptInitializer: Codable, Sendable, Equatable {
        let pointCount: Int
        let sha256: String
    }

    private struct Receipt: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let orientation: CanonicalOrientationArtifact
        let modelHashes: [String: String]
        let learnedPointInitializer: ReceiptInitializer?
    }

    static func loadPublishedResult(
        modelDirectory: URL,
        measurement: ColmapResidualAnalyzer.Result
    ) throws -> Result? {
        let receiptURL = modelDirectory.appendingPathComponent(receiptFileName)
        guard entryExists(at: receiptURL) else { return nil }
        let data = try BoundedFileReader.readRegularFile(
            at: receiptURL,
            maximumBytes: 1_048_576
        )
        let receipt: Receipt
        do {
            receipt = try JSONDecoder().decode(Receipt.self, from: data)
        } catch {
            throw Error.invalidReceipt
        }
        guard receipt.schemaVersion == 1,
              receipt.orientation.status != .unresolved,
              GeometryArtifactStore.isCanonicalOrientationValid(
                  receipt.orientation,
                  registeredViewCount: measurement.registeredViewCount
              ) else {
            throw Error.invalidReceipt
        }

        let snapshot = try GeometryModelSnapshot.capture(in: modelDirectory)
        guard receipt.modelHashes == snapshot.modelHashes else {
            throw Error.invalidReceipt
        }
        let canonicalInitializerURL = modelDirectory.appendingPathComponent(
            canonicalLearnedPointFileName
        )
        let initializer: Da3LearnedPointInitializer.Validation?
        if let expected = receipt.learnedPointInitializer {
            do {
                initializer = try Da3LearnedPointInitializer.inspect(
                    learnedPointsURL: canonicalInitializerURL,
                    expectedPointCount: expected.pointCount,
                    maximumPointCount: expected.pointCount,
                    expectedSHA256: expected.sha256
                )
            } catch {
                throw Error.invalidReceipt
            }
        } else {
            guard !entryExists(at: canonicalInitializerURL) else {
                throw Error.invalidReceipt
            }
            initializer = nil
        }
        return Result(
            artifact: receipt.orientation,
            measurement: measurement,
            snapshot: snapshot,
            learnedPointInitializer: initializer,
            maximumResidualDifference: 0,
            didTransform: false
        )
    }

    static func canonicalize(
        modelDirectory: URL,
        solution: CanonicalOrientationSolution,
        sourceMeasurement: ColmapResidualAnalyzer.Result,
        sourceSnapshot: GeometryModelSnapshot.Verified,
        learnedPointInitializer: LearnedPointInitializer?,
        checkCancellation: () throws -> Void = {},
        publicationCheckpoint: (PublicationCheckpoint) throws -> Void = { _ in }
    ) throws -> Result {
        if let published = try loadPublishedResult(
            modelDirectory: modelDirectory,
            measurement: sourceMeasurement
        ) {
            return published
        }

        if solution.artifact.status == .unresolved {
            guard solution.sourceToCanonical == .identity,
                  solution.artifact.sourceToCanonicalQuaternionWXYZ == nil else {
                throw Error.invalidOrientation
            }
            try GeometryModelSnapshot.validate(sourceSnapshot, at: modelDirectory)
            return Result(
                artifact: solution.artifact,
                measurement: sourceMeasurement,
                snapshot: sourceSnapshot,
                learnedPointInitializer: nil,
                maximumResidualDifference: 0,
                didTransform: false
            )
        }

        try validate(
            solution: solution,
            registeredViewCount: sourceMeasurement.registeredViewCount
        )
        let sourceInitializerValidation: Da3LearnedPointInitializer.Validation?
        if let learnedPointInitializer {
            sourceInitializerValidation = try Da3LearnedPointInitializer.inspect(
                learnedPointsURL: learnedPointInitializer.sourceURL,
                expectedPointCount: learnedPointInitializer.expectedPointCount,
                maximumPointCount: learnedPointInitializer.expectedPointCount,
                expectedSHA256: learnedPointInitializer.expectedSHA256
            )
        } else {
            sourceInitializerValidation = nil
        }

        try checkCancellation()
        try GeometryModelSnapshot.validate(sourceSnapshot, at: modelDirectory)
        let fileManager = FileManager.default
        let parentDirectory = modelDirectory.deletingLastPathComponent()
        let modelName = modelDirectory.lastPathComponent
        guard isSafeEntryName(modelName) else { throw Error.unsafeLayout }
        let parentDescriptor = try openDirectory(at: parentDirectory)
        defer { Darwin.close(parentDescriptor) }
        let stagingName = ".canonical-model-\(UUID().uuidString)"
        let staging = parentDirectory.appendingPathComponent(
            stagingName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var stagingIsLive = true
        defer {
            if stagingIsLive { try? fileManager.removeItem(at: staging) }
        }
        let stagingDescriptor = try openDirectory(named: stagingName, in: parentDescriptor)
        defer { Darwin.close(stagingDescriptor) }

        try fileManager.copyItem(
            at: modelDirectory.appendingPathComponent("cameras.txt"),
            to: staging.appendingPathComponent("cameras.txt")
        )
        try transformImages(
            from: modelDirectory.appendingPathComponent("images.txt"),
            to: staging.appendingPathComponent("images.txt"),
            sourceToCanonical: solution.sourceToCanonical,
            checkCancellation: checkCancellation
        )
        try transformPoints(
            from: modelDirectory.appendingPathComponent("points3D.txt"),
            to: staging.appendingPathComponent("points3D.txt"),
            sourceToCanonical: solution.sourceToCanonical,
            exactFieldCount: nil,
            checkCancellation: checkCancellation
        )

        let canonicalInitializerValidation: Da3LearnedPointInitializer.Validation?
        if let learnedPointInitializer, let sourceInitializerValidation {
            let canonicalInitializerURL = staging.appendingPathComponent(
                canonicalLearnedPointFileName
            )
            try transformPoints(
                from: learnedPointInitializer.sourceURL,
                to: canonicalInitializerURL,
                sourceToCanonical: solution.sourceToCanonical,
                exactFieldCount: 8,
                checkCancellation: checkCancellation
            )
            canonicalInitializerValidation = try Da3LearnedPointInitializer.inspect(
                learnedPointsURL: canonicalInitializerURL,
                expectedPointCount: sourceInitializerValidation.pointCount,
                maximumPointCount: sourceInitializerValidation.pointCount
            )
            _ = try Da3LearnedPointInitializer.inspect(
                learnedPointsURL: learnedPointInitializer.sourceURL,
                expectedPointCount: learnedPointInitializer.expectedPointCount,
                maximumPointCount: learnedPointInitializer.expectedPointCount,
                expectedSHA256: learnedPointInitializer.expectedSHA256
            )
        } else {
            canonicalInitializerValidation = nil
        }

        try checkCancellation()
        try GeometryModelSnapshot.validate(sourceSnapshot, at: modelDirectory)
        let candidateMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: staging)
        guard sameMeasuredFacts(sourceMeasurement, candidateMeasurement) else {
            throw Error.modelFactsChanged
        }
        let maximumResidualDifference = try ColmapResidualAnalyzer.maximumResidualDifference(
            between: modelDirectory,
            and: staging
        )
        guard maximumResidualDifference <= maximumAllowedResidualDifference else {
            throw Error.residualsChanged(maximumResidualDifference)
        }
        try GeometryModelSnapshot.validate(sourceSnapshot, at: modelDirectory)
        let candidateSnapshot = try GeometryModelSnapshot.capture(in: staging)
        try writeReceipt(
            Receipt(
                schemaVersion: 1,
                orientation: solution.artifact,
                modelHashes: candidateSnapshot.modelHashes,
                learnedPointInitializer: canonicalInitializerValidation.map {
                    ReceiptInitializer(pointCount: $0.pointCount, sha256: $0.sha256)
                }
            ),
            to: staging.appendingPathComponent(receiptFileName)
        )

        try synchronizeStagedModel(
            directory: stagingDescriptor,
            includesLearnedPointInitializer: canonicalInitializerValidation != nil
        )
        try synchronize(parentDescriptor)

        try checkCancellation()
        try GeometryModelSnapshot.validate(sourceSnapshot, at: modelDirectory)
        try publicationCheckpoint(.beforeSwap)
        try atomicSwap(
            directory: parentDescriptor,
            firstName: modelName,
            secondName: stagingName
        )
        do {
            try publicationCheckpoint(.afterSwap)
            try synchronize(parentDescriptor)
            try publicationCheckpoint(.beforePublishedValidation)
            try GeometryModelSnapshot.validate(candidateSnapshot, at: modelDirectory)
            let published = try loadPublishedResult(
                modelDirectory: modelDirectory,
                measurement: candidateMeasurement
            )
            guard let published,
                  published.artifact == solution.artifact,
                  published.snapshot.modelHashes == candidateSnapshot.modelHashes else {
                throw Error.invalidReceipt
            }
        } catch {
            let publicationError = error
            do {
                try atomicSwap(
                    directory: parentDescriptor,
                    firstName: modelName,
                    secondName: stagingName
                )
                try synchronize(parentDescriptor)
                try GeometryModelSnapshot.validate(sourceSnapshot, at: modelDirectory)
                stagingIsLive = false
                try fileManager.removeItem(at: staging)
                try synchronize(parentDescriptor)
            } catch {
                // The accepted source remains preserved at one of the two paths.
                // Do not remove either directory when rollback cannot be proven.
                stagingIsLive = false
                throw Error.atomicRollbackFailed(posixCode(from: error))
            }
            throw publicationError
        }

        stagingIsLive = false
        try fileManager.removeItem(at: staging)
        try synchronize(parentDescriptor)
        return Result(
            artifact: solution.artifact,
            measurement: candidateMeasurement,
            snapshot: candidateSnapshot,
            learnedPointInitializer: canonicalInitializerValidation,
            maximumResidualDifference: maximumResidualDifference,
            didTransform: true
        )
    }

    private static func validate(
        solution: CanonicalOrientationSolution,
        registeredViewCount: Int
    ) throws {
        guard solution.artifact.status == .verified
                || solution.artifact.status == .axisAlignedSignUnverified,
              GeometryArtifactStore.isCanonicalOrientationValid(
                  solution.artifact,
                  registeredViewCount: registeredViewCount
              ),
              let expectedQuaternion = solution.artifact.sourceToCanonicalQuaternionWXYZ,
              matrixIsProperRotation(solution.sourceToCanonical) else {
            throw Error.invalidOrientation
        }
        let actualQuaternion = solution.sourceToCanonical.canonicalQuaternion()
        let differences = [
            abs(actualQuaternion.w - expectedQuaternion.w),
            abs(actualQuaternion.x - expectedQuaternion.x),
            abs(actualQuaternion.y - expectedQuaternion.y),
            abs(actualQuaternion.z - expectedQuaternion.z),
        ]
        guard differences.max()! <= 1e-10 else { throw Error.invalidOrientation }
    }

    private static func matrixIsProperRotation(_ matrix: OrientationMatrix3) -> Bool {
        guard abs(matrix.determinant - 1) <= 1e-10 else { return false }
        let product = matrix.multiplied(by: matrix.transposed)
        for row in 0..<3 {
            for column in 0..<3 {
                let expected = row == column ? 1.0 : 0.0
                guard product[row, column].isFinite,
                      abs(product[row, column] - expected) <= 1e-10 else {
                    return false
                }
            }
        }
        return true
    }

    private static func transformImages(
        from source: URL,
        to destination: URL,
        sourceToCanonical: OrientationMatrix3,
        checkCancellation: () throws -> Void
    ) throws {
        let reader = try BoundedUTF8LineReader(
            at: source,
            maximumBytes: ColmapTextFileLimits.images,
            maximumLineBytes: ColmapTextFileLimits.maximumLine
        )
        let writer = try BufferedUTF8LineWriter(at: destination)
        var expectsPose = true
        while let line = try reader.next(checkCancellation: checkCancellation) {
            if !expectsPose {
                try writer.write(line)
                expectsPose = true
                continue
            }
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                try writer.write(line)
                continue
            }
            let ranges = tokenRanges(in: line.text)
            guard ranges.count >= 10,
                  let qw = finiteDouble(line.text, range: ranges[1]),
                  let qx = finiteDouble(line.text, range: ranges[2]),
                  let qy = finiteDouble(line.text, range: ranges[3]),
                  let qz = finiteDouble(line.text, range: ranges[4]),
                  finiteDouble(line.text, range: ranges[5]) != nil,
                  finiteDouble(line.text, range: ranges[6]) != nil,
                  finiteDouble(line.text, range: ranges[7]) != nil,
                  let sourceRotation = rotationMatrix(qw: qw, qx: qx, qy: qy, qz: qz) else {
                throw Error.malformedRecord(file: "images.txt", line: line.number)
            }
            let canonicalRotation = sourceRotation.multiplied(by: sourceToCanonical.transposed)
            guard matrixIsProperRotation(canonicalRotation) else {
                throw Error.invalidOrientation
            }
            let quaternion = canonicalRotation.canonicalQuaternion()
            try writer.write(
                text: line.text,
                tokenRanges: ranges,
                replacements: [
                    1: decimal(quaternion.w),
                    2: decimal(quaternion.x),
                    3: decimal(quaternion.y),
                    4: decimal(quaternion.z),
                ],
                terminator: line.terminator
            )
            expectsPose = false
        }
        guard expectsPose else { throw Error.incompleteImagesFile }
        try writer.finish()
    }

    private static func transformPoints(
        from source: URL,
        to destination: URL,
        sourceToCanonical: OrientationMatrix3,
        exactFieldCount: Int?,
        checkCancellation: () throws -> Void
    ) throws {
        let reader = try BoundedUTF8LineReader(
            at: source,
            maximumBytes: ColmapTextFileLimits.points,
            maximumLineBytes: ColmapTextFileLimits.maximumLine
        )
        let writer = try BufferedUTF8LineWriter(at: destination)
        while let line = try reader.next(checkCancellation: checkCancellation) {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                try writer.write(line)
                continue
            }
            let ranges = tokenRanges(in: line.text)
            let fieldCountIsValid = exactFieldCount.map { ranges.count == $0 }
                ?? (ranges.count >= 8 && ranges.count.isMultiple(of: 2))
            guard fieldCountIsValid,
                  let x = finiteDouble(line.text, range: ranges[1]),
                  let y = finiteDouble(line.text, range: ranges[2]),
                  let z = finiteDouble(line.text, range: ranges[3]) else {
                throw Error.malformedRecord(file: source.lastPathComponent, line: line.number)
            }
            let transformed = sourceToCanonical.applied(
                to: OrientationVector3(x: x, y: y, z: z)
            )
            guard transformed.x.isFinite, transformed.y.isFinite, transformed.z.isFinite else {
                throw Error.invalidOrientation
            }
            try writer.write(
                text: line.text,
                tokenRanges: ranges,
                replacements: [
                    1: decimal(transformed.x),
                    2: decimal(transformed.y),
                    3: decimal(transformed.z),
                ],
                terminator: line.terminator
            )
        }
        try writer.finish()
    }

    private static func sameMeasuredFacts(
        _ source: ColmapResidualAnalyzer.Result,
        _ candidate: ColmapResidualAnalyzer.Result
    ) -> Bool {
        source.registeredViewCount == candidate.registeredViewCount
            && source.registeredImageNames == candidate.registeredImageNames
            && source.measuredImageNames == candidate.measuredImageNames
            && source.observationCountByImage == candidate.observationCountByImage
            && source.cameraModel == candidate.cameraModel
            && source.pointCount == candidate.pointCount
            && source.observationCount == candidate.observationCount
            && source.provenance == candidate.provenance
    }

    private static func writeReceipt(_ receipt: Receipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.invalidReceipt
        }
        let writer = try BufferedUTF8LineWriter(at: url)
        try writer.write(fragment: text)
        try writer.write(.lf)
        try writer.finish()
    }

    private static func synchronizeStagedModel(
        directory: Int32,
        includesLearnedPointInitializer: Bool
    ) throws {
        var names = ["cameras.txt", "images.txt", "points3D.txt", receiptFileName]
        if includesLearnedPointInitializer {
            names.append(canonicalLearnedPointFileName)
        }
        for name in names {
            try synchronizeRegularFile(named: name, in: directory)
        }
        try synchronize(directory)
    }

    private static func synchronizeRegularFile(named name: String, in directory: Int32) throws {
        var descriptor: Int32 = -1
        while true {
            descriptor = name.withCString {
                openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            if descriptor >= 0 { break }
            let code = errno
            if code == EINTR { continue }
            if code == ELOOP || code == ENOTDIR { throw Error.unsafeLayout }
            throw Error.synchronizationFailed(code)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0 else {
            throw Error.unsafeLayout
        }
        try synchronize(descriptor)
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            if code == ELOOP || code == ENOTDIR { throw Error.unsafeLayout }
            throw Error.synchronizationFailed(code)
        }
    }

    private static func openDirectory(named name: String, in parent: Int32) throws -> Int32 {
        while true {
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            if code == ELOOP || code == ENOTDIR { throw Error.unsafeLayout }
            throw Error.synchronizationFailed(code)
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while true {
            if Darwin.fsync(descriptor) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw Error.synchronizationFailed(code)
        }
    }

    private static func atomicSwap(
        directory: Int32,
        firstName: String,
        secondName: String
    ) throws {
        while true {
            let result = firstName.withCString { first in
                secondName.withCString { second in
                    renameatx_np(
                        directory,
                        first,
                        directory,
                        second,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            if result == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw Error.atomicSwapFailed(code)
        }
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0")
    }

    private static func posixCode(from error: Swift.Error) -> Int32 {
        if let error = error as? Error {
            switch error {
            case .synchronizationFailed(let code),
                 .atomicSwapFailed(let code),
                 .atomicRollbackFailed(let code):
                return code
            default:
                return EIO
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain,
           cocoa.code > 0,
           cocoa.code <= Int(Int32.max) {
            return Int32(cocoa.code)
        }
        return EIO
    }

    private static func rotationMatrix(
        qw: Double,
        qx: Double,
        qy: Double,
        qz: Double
    ) -> OrientationMatrix3? {
        let norm = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
        guard norm.isFinite, norm > 0 else { return nil }
        let w = qw / norm
        let x = qx / norm
        let y = qy / norm
        let z = qz / norm
        return OrientationMatrix3(
            rows: OrientationVector3(
                x: 1 - 2 * (y * y + z * z),
                y: 2 * (x * y - z * w),
                z: 2 * (x * z + y * w)
            ),
            OrientationVector3(
                x: 2 * (x * y + z * w),
                y: 1 - 2 * (x * x + z * z),
                z: 2 * (y * z - x * w)
            ),
            OrientationVector3(
                x: 2 * (x * z - y * w),
                y: 2 * (y * z + x * w),
                z: 1 - 2 * (x * x + y * y)
            )
        )
    }

    private static func tokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }
            let start = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            ranges.append(start..<cursor)
        }
        return ranges
    }

    private static func finiteDouble(_ text: String, range: Range<String.Index>) -> Double? {
        guard let value = Double(text[range]), value.isFinite else { return nil }
        return value
    }

    private static func decimal(_ value: Double) -> String {
        String(
            format: "%.17g",
            locale: Locale(identifier: "en_US_POSIX"),
            value == 0 ? 0 : value
        )
    }

    private static func entryExists(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }
}
