import Darwin
import Foundation
import SQLite3

public enum ColmapTextModelNormalizer {
    enum RemapError: Swift.Error, LocalizedError, Equatable {
        case databaseOpenFailed(Int32)
        case databaseQueryFailed(Int32)
        case invalidDatabaseRow
        case duplicateDatabaseImageName(String)
        case duplicateDatabaseImageID(Int)
        case malformedImagesFile(Int)
        case missingDatabaseImage(String)
        case duplicateSeedImageID(Int)
        case duplicateSeedImageName(String)
        case malformedCamerasFile(Int)
        case missingSeedCamera(Int)
        case inconsistentCameraMapping(Int)
        case cameraIDCollision(Int)
        case malformedPointsFile(Int)
        case unknownTrackImageID(Int)
        case invalidUTF8(String)
        case atomicSwapFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .databaseOpenFailed(let code):
                return "The COLMAP database could not be opened (SQLite error \(code))."
            case .databaseQueryFailed(let code):
                return "The COLMAP image table could not be read (SQLite error \(code))."
            case .invalidDatabaseRow:
                return "The COLMAP image table contains an invalid row."
            case .duplicateDatabaseImageName(let name):
                return "The COLMAP database contains more than one image named \(name)."
            case .duplicateDatabaseImageID(let imageID):
                return "The COLMAP database contains duplicate image ID \(imageID)."
            case .malformedImagesFile(let line):
                return "The seed images.txt file is malformed at line \(line)."
            case .missingDatabaseImage(let name):
                return "The seed image \(name) is missing from the COLMAP database."
            case .duplicateSeedImageID(let imageID):
                return "The seed model contains duplicate image ID \(imageID)."
            case .duplicateSeedImageName(let name):
                return "The seed model contains more than one image named \(name)."
            case .malformedCamerasFile(let line):
                return "The seed cameras.txt file is malformed at line \(line)."
            case .missingSeedCamera(let cameraID):
                return "The seed model is missing camera ID \(cameraID)."
            case .inconsistentCameraMapping(let cameraID):
                return "Seed camera ID \(cameraID) maps to conflicting database cameras."
            case .cameraIDCollision(let cameraID):
                return "Remapping would create duplicate camera ID \(cameraID)."
            case .malformedPointsFile(let line):
                return "The seed points3D.txt file is malformed at line \(line)."
            case .unknownTrackImageID(let imageID):
                return "A seed point track refers to unknown image ID \(imageID)."
            case .invalidUTF8(let file):
                return "The COLMAP text model contains invalid UTF-8 in \(file)."
            case .atomicSwapFailed(let code):
                return "The remapped seed model could not be installed atomically (errno \(code))."
            }
        }
    }

    private struct ParsedPoseLine {
        let tokenRanges: [Range<String.Index>]
        let imageID: Int
        let cameraID: Int
        let name: String
    }

    private struct DatabaseImageMapping {
        let imageID: Int
        let cameraID: Int
    }

    private struct TokenCursor {
        let text: String
        var index: String.Index

        init(_ text: String) {
            self.text = text
            index = text.startIndex
        }

        mutating func next() -> Range<String.Index>? {
            skipWhitespace()
            guard index < text.endIndex else { return nil }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            return start..<index
        }

        mutating func remainder() -> Range<String.Index>? {
            skipWhitespace()
            guard index < text.endIndex else { return nil }
            return index..<text.endIndex
        }

        private mutating func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
        }
    }

    public static func normalizeImagesTxtIfNeeded(
        at imagesTxtURL: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> Bool {
        try checkCancellation()
        guard try imagesTxtNeedsNormalization(
            at: imagesTxtURL,
            checkCancellation: checkCancellation
        ) else { return false }

        let stagingURL = imagesTxtURL.deletingLastPathComponent().appendingPathComponent(
            ".\(imagesTxtURL.lastPathComponent)-normalize-\(UUID().uuidString)"
        )
        var keepStaging = false
        defer {
            if !keepStaging { try? FileManager.default.removeItem(at: stagingURL) }
        }
        guard try writeNormalizedImagesTxt(
            from: imagesTxtURL,
            to: stagingURL,
            checkCancellation: checkCancellation
        ) else {
            return false
        }
        try checkCancellation()

        let result = stagingURL.withUnsafeFileSystemRepresentation { stagingPath in
            imagesTxtURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let stagingPath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(stagingPath, destinationPath)
            }
        }
        guard result == 0 else { throw RemapError.atomicSwapFailed(errno) }
        keepStaging = true
        return true
    }

    private static func imagesTxtNeedsNormalization(
        at imagesTxtURL: URL,
        checkCancellation: () throws -> Void
    ) throws -> Bool {
        let reader = try makeReader(
            at: imagesTxtURL,
            maximumBytes: ColmapTextFileLimits.images
        )
        var expectsPoints2D = false

        while let line = try nextLine(
            reader,
            fileName: imagesTxtURL.lastPathComponent,
            checkCancellation: checkCancellation
        ) {
            let firstContent = line.text.first(where: { !$0.isWhitespace })
            let isComment = firstContent == "#"

            if expectsPoints2D {
                if firstContent == nil {
                    expectsPoints2D = false
                    continue
                }
                if isComment { return true }
                if isPoseLine(line.text), !isPoints2DLine(line.text) { return true }
                expectsPoints2D = false
                continue
            }

            if !isComment, firstContent != nil, isPoseLine(line.text) {
                expectsPoints2D = true
            }
        }
        return expectsPoints2D
    }

    private static func writeNormalizedImagesTxt(
        from imagesTxtURL: URL,
        to stagingURL: URL,
        checkCancellation: () throws -> Void
    ) throws -> Bool {
        let reader = try makeReader(
            at: imagesTxtURL,
            maximumBytes: ColmapTextFileLimits.images
        )
        let writer = try BufferedUTF8LineWriter(at: stagingURL)

        var didChange = false
        var expectsPoints2D = false
        var poseTerminator: BoundedUTF8LineReader.Line.Terminator = .lf
        var preferredTerminator: BoundedUTF8LineReader.Line.Terminator = .lf

        while let line = try nextLine(
            reader,
            fileName: imagesTxtURL.lastPathComponent,
            checkCancellation: checkCancellation
        ) {
            if line.terminator != .endOfFile { preferredTerminator = line.terminator }
            let firstContent = line.text.first(where: { !$0.isWhitespace })
            let isComment = firstContent == "#"

            if expectsPoints2D {
                if firstContent == nil {
                    try writer.write(line)
                    expectsPoints2D = false
                    continue
                }
                if isComment {
                    try writeMissingPoints2DLine(
                        after: poseTerminator,
                        preferred: preferredTerminator,
                        writer: writer
                    )
                    didChange = true
                    expectsPoints2D = false
                    try writer.write(line)
                    continue
                }
                if isPoseLine(line.text), !isPoints2DLine(line.text) {
                    try writeMissingPoints2DLine(
                        after: poseTerminator,
                        preferred: preferredTerminator,
                        writer: writer
                    )
                    didChange = true
                    try writer.write(line)
                    poseTerminator = line.terminator
                    continue
                }
                try writer.write(line)
                expectsPoints2D = false
                continue
            }

            try writer.write(line)
            if !isComment, firstContent != nil, isPoseLine(line.text) {
                expectsPoints2D = true
                poseTerminator = line.terminator
            }
        }

        if expectsPoints2D {
            try writeMissingPoints2DLine(
                after: poseTerminator,
                preferred: preferredTerminator,
                writer: writer
            )
            didChange = true
        }
        try writer.finish()
        return didChange
    }

    public static func remapSeedModelIDsToDatabase(
        seedModelURL: URL,
        databaseURL: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> Bool {
        try checkCancellation()
        let dbMappings = try readDatabaseImageMappings(
            databaseURL: databaseURL,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        let stagingURL = seedModelURL.deletingLastPathComponent().appendingPathComponent(
            ".\(seedModelURL.lastPathComponent)-id-remap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        var keepStaging = false
        defer {
            if !keepStaging { try? FileManager.default.removeItem(at: stagingURL) }
        }

        var oldImageIDToNew: [Int: Int] = [:]
        var oldCameraIDToNew: [Int: Int] = [:]
        var didChange = false
        try remapImages(
            from: seedModelURL.appendingPathComponent("images.txt"),
            to: stagingURL.appendingPathComponent("images.txt"),
            databaseMappings: dbMappings,
            oldImageIDToNew: &oldImageIDToNew,
            oldCameraIDToNew: &oldCameraIDToNew,
            didChange: &didChange,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        try remapCameras(
            from: seedModelURL.appendingPathComponent("cameras.txt"),
            to: stagingURL.appendingPathComponent("cameras.txt"),
            oldCameraIDToNew: oldCameraIDToNew,
            didChange: &didChange,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        try remapPoints(
            from: seedModelURL.appendingPathComponent("points3D.txt"),
            to: stagingURL.appendingPathComponent("points3D.txt"),
            oldImageIDToNew: oldImageIDToNew,
            didChange: &didChange,
            checkCancellation: checkCancellation
        )
        try checkCancellation()

        guard didChange else { return false }
        let swapResult = seedModelURL.withUnsafeFileSystemRepresentation { modelPath in
            stagingURL.withUnsafeFileSystemRepresentation { stagingPath in
                guard let modelPath, let stagingPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    modelPath,
                    AT_FDCWD,
                    stagingPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard swapResult == 0 else { throw RemapError.atomicSwapFailed(errno) }
        try FileManager.default.removeItem(at: stagingURL)
        keepStaging = true
        return true
    }

    private static func remapImages(
        from source: URL,
        to destination: URL,
        databaseMappings: [String: DatabaseImageMapping],
        oldImageIDToNew: inout [Int: Int],
        oldCameraIDToNew: inout [Int: Int],
        didChange: inout Bool,
        checkCancellation: () throws -> Void
    ) throws {
        let reader = try makeReader(at: source, maximumBytes: ColmapTextFileLimits.images)
        let writer = try BufferedUTF8LineWriter(at: destination)
        var seenSeedImageIDs = Set<Int>()
        var seenSeedImageNames = Set<String>()
        var seenTargetImageIDs = Set<Int>()
        var expectsPose = true
        var poseCount = 0
        var lastLine = 0

        while let line = try nextLine(
            reader,
            fileName: source.lastPathComponent,
            checkCancellation: checkCancellation
        ) {
            lastLine = line.number
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                try writer.write(line)
                continue
            }
            if expectsPose {
                if trimmed.isEmpty {
                    try writer.write(line)
                    continue
                }
                guard let parsed = parsePoseLine(line.text) else {
                    throw RemapError.malformedImagesFile(line.number)
                }
                guard seenSeedImageIDs.insert(parsed.imageID).inserted else {
                    throw RemapError.duplicateSeedImageID(parsed.imageID)
                }
                guard seenSeedImageNames.insert(parsed.name).inserted else {
                    throw RemapError.duplicateSeedImageName(parsed.name)
                }
                guard let mapping = databaseMappings[parsed.name] else {
                    throw RemapError.missingDatabaseImage(parsed.name)
                }
                guard seenTargetImageIDs.insert(mapping.imageID).inserted else {
                    throw RemapError.duplicateDatabaseImageID(mapping.imageID)
                }
                oldImageIDToNew[parsed.imageID] = mapping.imageID
                if let existing = oldCameraIDToNew[parsed.cameraID], existing != mapping.cameraID {
                    throw RemapError.inconsistentCameraMapping(parsed.cameraID)
                }
                oldCameraIDToNew[parsed.cameraID] = mapping.cameraID
                var replacements: [Int: String] = [:]
                if parsed.imageID != mapping.imageID {
                    replacements[0] = String(mapping.imageID)
                    didChange = true
                }
                if parsed.cameraID != mapping.cameraID {
                    replacements[8] = String(mapping.cameraID)
                    didChange = true
                }
                if replacements.isEmpty {
                    try writer.write(line)
                } else {
                    try writer.write(
                        text: line.text,
                        tokenRanges: parsed.tokenRanges,
                        replacements: replacements,
                        terminator: line.terminator
                    )
                }
                poseCount += 1
                expectsPose = false
            } else {
                guard trimmed.isEmpty || isPoints2DLine(line.text) else {
                    throw RemapError.malformedImagesFile(line.number)
                }
                try writer.write(line)
                expectsPose = true
            }
        }
        guard poseCount > 0, expectsPose else {
            throw RemapError.malformedImagesFile(max(lastLine, 1))
        }
        try writer.finish()
    }

    private static func remapCameras(
        from source: URL,
        to destination: URL,
        oldCameraIDToNew: [Int: Int],
        didChange: inout Bool,
        checkCancellation: () throws -> Void
    ) throws {
        var targetOwners: [Int: Int] = [:]
        for (oldID, newID) in oldCameraIDToNew {
            if let existing = targetOwners[newID], existing != oldID {
                throw RemapError.cameraIDCollision(newID)
            }
            targetOwners[newID] = oldID
        }
        let reader = try makeReader(at: source, maximumBytes: ColmapTextFileLimits.cameras)
        let writer = try BufferedUTF8LineWriter(at: destination)
        var seedCameraIDs = Set<Int>()
        var outputCameraIDs = Set<Int>()
        var cameraCount = 0
        var lastLine = 0

        while let line = try nextLine(
            reader,
            fileName: source.lastPathComponent,
            checkCancellation: checkCancellation
        ) {
            lastLine = line.number
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                try writer.write(line)
                continue
            }
            var cursor = TokenCursor(line.text)
            var ranges: [Range<String.Index>] = []
            for _ in 0..<5 {
                guard let range = cursor.next() else {
                    throw RemapError.malformedCamerasFile(line.number)
                }
                ranges.append(range)
            }
            guard let cameraID = Int(line.text[ranges[0]]), cameraID > 0,
                  let width = Int(line.text[ranges[2]]), width > 0,
                  let height = Int(line.text[ranges[3]]), height > 0,
                  Double(line.text[ranges[4]])?.isFinite == true else {
                throw RemapError.malformedCamerasFile(line.number)
            }
            while let parameter = cursor.next() {
                guard Double(line.text[parameter])?.isFinite == true else {
                    throw RemapError.malformedCamerasFile(line.number)
                }
            }
            guard seedCameraIDs.insert(cameraID).inserted else {
                throw RemapError.cameraIDCollision(cameraID)
            }
            let newCameraID = oldCameraIDToNew[cameraID] ?? cameraID
            guard outputCameraIDs.insert(newCameraID).inserted else {
                throw RemapError.cameraIDCollision(newCameraID)
            }
            if newCameraID == cameraID {
                try writer.write(line)
            } else {
                didChange = true
                try writer.write(
                    text: line.text,
                    tokenRanges: ranges,
                    replacements: [0: String(newCameraID)],
                    terminator: line.terminator
                )
            }
            cameraCount += 1
        }
        guard cameraCount > 0 else {
            throw RemapError.malformedCamerasFile(max(lastLine, 1))
        }
        for cameraID in oldCameraIDToNew.keys where !seedCameraIDs.contains(cameraID) {
            throw RemapError.missingSeedCamera(cameraID)
        }
        try writer.finish()
    }

    private static func remapPoints(
        from source: URL,
        to destination: URL,
        oldImageIDToNew: [Int: Int],
        didChange: inout Bool,
        checkCancellation: () throws -> Void
    ) throws {
        let reader = try makeReader(at: source, maximumBytes: ColmapTextFileLimits.points)
        let writer = try BufferedUTF8LineWriter(at: destination)
        while let line = try nextLine(
            reader,
            fileName: source.lastPathComponent,
            checkCancellation: checkCancellation
        ) {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                try writer.write(line)
                continue
            }
            var cursor = TokenCursor(line.text)
            var prefix: [Range<String.Index>] = []
            for _ in 0..<8 {
                guard let range = cursor.next() else {
                    throw RemapError.malformedPointsFile(line.number)
                }
                prefix.append(range)
            }
            guard let pointID = Int64(line.text[prefix[0]]), pointID > 0,
                  Double(line.text[prefix[1]])?.isFinite == true,
                  Double(line.text[prefix[2]])?.isFinite == true,
                  Double(line.text[prefix[3]])?.isFinite == true,
                  let red = Int(line.text[prefix[4]]), (0...255).contains(red),
                  let green = Int(line.text[prefix[5]]), (0...255).contains(green),
                  let blue = Int(line.text[prefix[6]]), (0...255).contains(blue),
                  Double(line.text[prefix[7]])?.isFinite == true else {
                throw RemapError.malformedPointsFile(line.number)
            }
            var outputCursor = line.text.startIndex
            var lineChanged = false
            while let imageRange = cursor.next() {
                guard let pointIndexRange = cursor.next(),
                      let oldImageID = Int(line.text[imageRange]), oldImageID > 0,
                      let pointIndex = Int(line.text[pointIndexRange]), pointIndex >= 0 else {
                    throw RemapError.malformedPointsFile(line.number)
                }
                guard let newImageID = oldImageIDToNew[oldImageID] else {
                    throw RemapError.unknownTrackImageID(oldImageID)
                }
                if newImageID != oldImageID {
                    try writer.write(fragment: line.text[outputCursor..<imageRange.lowerBound])
                    try writer.write(fragment: String(newImageID))
                    outputCursor = imageRange.upperBound
                    lineChanged = true
                    didChange = true
                }
            }
            if lineChanged {
                try writer.write(fragment: line.text[outputCursor...])
                try writer.write(line.terminator)
            } else {
                try writer.write(line)
            }
        }
        try writer.finish()
    }

    private static func parsePoseLine(_ line: String) -> ParsedPoseLine? {
        var cursor = TokenCursor(line)
        var ranges: [Range<String.Index>] = []
        ranges.reserveCapacity(9)
        for _ in 0..<9 {
            guard let range = cursor.next() else { return nil }
            ranges.append(range)
        }
        guard let nameRange = cursor.remainder(),
              let imageID = Int(line[ranges[0]]), imageID > 0,
              let cameraID = Int(line[ranges[8]]), cameraID > 0,
              let qw = Double(line[ranges[1]]), qw.isFinite,
              let qx = Double(line[ranges[2]]), qx.isFinite,
              let qy = Double(line[ranges[3]]), qy.isFinite,
              let qz = Double(line[ranges[4]]), qz.isFinite,
              ranges[5...7].allSatisfy({ Double(line[$0])?.isFinite == true }) else {
            return nil
        }
        let quaternionNormSquared = qw * qw + qx * qx + qy * qy + qz * qz
        guard quaternionNormSquared.isFinite, quaternionNormSquared > 0 else { return nil }
        let name = String(line[nameRange])
        guard !name.isEmpty, !name.contains("\0") else { return nil }
        return ParsedPoseLine(
            tokenRanges: ranges,
            imageID: imageID,
            cameraID: cameraID,
            name: name
        )
    }

    private static func isPoseLine(_ line: String) -> Bool {
        parsePoseLine(line) != nil
    }

    private static func isPoints2DLine(_ line: String) -> Bool {
        var cursor = TokenCursor(line)
        var count = 0
        while let x = cursor.next() {
            guard let y = cursor.next(), let point = cursor.next(),
                  Double(line[x])?.isFinite == true,
                  Double(line[y])?.isFinite == true,
                  let pointID = Int64(line[point]), pointID >= -1 else {
                return false
            }
            count += 1
        }
        return count > 0
    }

    private static func writeMissingPoints2DLine(
        after poseTerminator: BoundedUTF8LineReader.Line.Terminator,
        preferred: BoundedUTF8LineReader.Line.Terminator,
        writer: BufferedUTF8LineWriter
    ) throws {
        let terminator = preferred == .endOfFile ? .lf : preferred
        if poseTerminator == .endOfFile { try writer.write(terminator) }
        try writer.write(poseTerminator == .endOfFile ? terminator : poseTerminator)
    }

    private static func makeReader(
        at url: URL,
        maximumBytes: Int
    ) throws -> BoundedUTF8LineReader {
        try BoundedUTF8LineReader(
            at: url,
            maximumBytes: maximumBytes,
            maximumLineBytes: min(maximumBytes, ColmapTextFileLimits.maximumLine)
        )
    }

    private static func nextLine(
        _ reader: BoundedUTF8LineReader,
        fileName: String,
        checkCancellation: () throws -> Void
    ) throws -> BoundedUTF8LineReader.Line? {
        do {
            return try reader.next(checkCancellation: checkCancellation)
        } catch BoundedUTF8LineReader.Error.invalidUTF8 {
            throw RemapError.invalidUTF8(fileName)
        }
    }

    private static func readDatabaseImageMappings(
        databaseURL: URL,
        checkCancellation: () throws -> Void
    ) throws -> [String: DatabaseImageMapping] {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw RemapError.databaseOpenFailed(rc)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            db,
            "SELECT image_id, name, camera_id FROM images;",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            throw RemapError.databaseQueryFailed(prepare)
        }
        defer { sqlite3_finalize(statement) }

        var mappings: [String: DatabaseImageMapping] = [:]
        var seenImageIDs = Set<Int>()
        while true {
            try checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw RemapError.databaseQueryFailed(step) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER else {
                throw RemapError.invalidDatabaseRow
            }
            let imageID = Int(sqlite3_column_int64(statement, 0))
            let cameraID = Int(sqlite3_column_int64(statement, 2))
            guard imageID > 0, cameraID > 0,
                  let nameBytes = sqlite3_column_text(statement, 1) else {
                throw RemapError.invalidDatabaseRow
            }
            let nameData = Data(bytes: nameBytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty else {
                throw RemapError.invalidDatabaseRow
            }
            guard mappings[name] == nil else {
                throw RemapError.duplicateDatabaseImageName(name)
            }
            guard seenImageIDs.insert(imageID).inserted else {
                throw RemapError.duplicateDatabaseImageID(imageID)
            }
            mappings[name] = DatabaseImageMapping(imageID: imageID, cameraID: cameraID)
        }
        return mappings
    }
}
