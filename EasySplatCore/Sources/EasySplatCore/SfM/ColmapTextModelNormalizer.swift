import Foundation
import SQLite3

public enum ColmapTextModelNormalizer {
    public static func normalizeImagesTxtIfNeeded(at imagesTxtURL: URL) throws -> Bool {
        let contents = try String(contentsOf: imagesTxtURL, encoding: .utf8)
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return false }

        var output: [String] = []
        output.reserveCapacity(lines.count * 2)
        var didChange = false

        for index in lines.indices {
            let line = lines[index]
            output.append(line)
            guard isPoseLine(line) else { continue }

            let nextLine: String? = {
                let nextIndex = lines.index(after: index)
                if nextIndex < lines.endIndex {
                    return lines[nextIndex]
                }
                return nil
            }()

            if nextLine.map(isPoseLine) ?? true {
                output.append("")
                didChange = true
            }
        }

        guard didChange else { return false }
        let normalized = output.joined(separator: "\n") + "\n"
        try normalized.write(to: imagesTxtURL, atomically: true, encoding: .utf8)
        return true
    }

    public static func remapSeedModelIDsToDatabase(seedModelURL: URL, databaseURL: URL) throws -> Bool {
        let imagesURL = seedModelURL.appendingPathComponent("images.txt")
        let camerasURL = seedModelURL.appendingPathComponent("cameras.txt")
        let pointsURL = seedModelURL.appendingPathComponent("points3D.txt")

        let dbMappings = (try? readDatabaseImageMappings(databaseURL: databaseURL)) ?? [:]
        guard !dbMappings.isEmpty else { return false }

        let imagesContents = try String(contentsOf: imagesURL, encoding: .utf8)
        let imageLines = imagesContents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var remappedImageLines: [String] = []
        remappedImageLines.reserveCapacity(imageLines.count)

        var oldImageIDToNew: [Int: Int] = [:]
        var oldCameraIDToNew: [Int: Int] = [:]
        var didChange = false

        for line in imageLines {
            guard let parsed = parsePoseLine(line) else {
                remappedImageLines.append(line)
                continue
            }
            guard let mapping = dbMappings[parsed.name] else {
                remappedImageLines.append(line)
                continue
            }

            oldImageIDToNew[parsed.imageID] = mapping.imageID
            oldCameraIDToNew[parsed.cameraID] = mapping.cameraID

            var parts = parsed.parts
            if parsed.imageID != mapping.imageID {
                parts[0] = String(mapping.imageID)
                didChange = true
            }
            if parsed.cameraID != mapping.cameraID {
                parts[8] = String(mapping.cameraID)
                didChange = true
            }
            remappedImageLines.append(parts.joined(separator: " "))
        }

        guard !oldImageIDToNew.isEmpty else { return false }
        if didChange {
            try (remappedImageLines.joined(separator: "\n") + "\n").write(to: imagesURL, atomically: true, encoding: .utf8)
        }

        let camerasContents = try String(contentsOf: camerasURL, encoding: .utf8)
        let cameraLines = camerasContents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var remappedCameraLines: [String] = []
        remappedCameraLines.reserveCapacity(cameraLines.count)
        var seenCameraIDs = Set<Int>()

        for line in cameraLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                remappedCameraLines.append(line)
                continue
            }
            var parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let oldCameraID = Int(parts[0]) else {
                remappedCameraLines.append(line)
                continue
            }
            let newCameraID = oldCameraIDToNew[oldCameraID] ?? oldCameraID
            if newCameraID != oldCameraID {
                parts[0] = String(newCameraID)
                didChange = true
            }
            if seenCameraIDs.insert(newCameraID).inserted {
                remappedCameraLines.append(parts.joined(separator: " "))
            } else {
                didChange = true
            }
        }
        if didChange {
            try (remappedCameraLines.joined(separator: "\n") + "\n").write(to: camerasURL, atomically: true, encoding: .utf8)
        }

        let pointsContents = try String(contentsOf: pointsURL, encoding: .utf8)
        let pointLines = pointsContents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var remappedPointLines: [String] = []
        remappedPointLines.reserveCapacity(pointLines.count)

        for line in pointLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                remappedPointLines.append(line)
                continue
            }
            var parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 8 else {
                remappedPointLines.append(line)
                continue
            }
            var index = 8
            while index < parts.count {
                if let oldImageID = Int(parts[index]), let newImageID = oldImageIDToNew[oldImageID], newImageID != oldImageID {
                    parts[index] = String(newImageID)
                    didChange = true
                }
                index += 2
            }
            remappedPointLines.append(parts.joined(separator: " "))
        }
        if didChange {
            try (remappedPointLines.joined(separator: "\n") + "\n").write(to: pointsURL, atomically: true, encoding: .utf8)
        }

        return didChange
    }

    private static func isPoseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("#") else { return false }

        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 10 else { return false }
        guard Int(parts[0]) != nil else { return false }
        for index in 1...7 {
            if Double(parts[index]) == nil { return false }
        }
        guard Int(parts[8]) != nil else { return false }
        let name = String(parts[9])
        let hasLetter = name.rangeOfCharacter(from: .letters) != nil
        return hasLetter
    }

    private struct ParsedPoseLine {
        var parts: [String]
        let imageID: Int
        let cameraID: Int
        let name: String
    }

    private struct DatabaseImageMapping {
        let imageID: Int
        let cameraID: Int
    }

    private static func parsePoseLine(_ line: String) -> ParsedPoseLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPoseLine(trimmed) else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 10,
              let imageID = Int(parts[0]),
              let cameraID = Int(parts[8]) else {
            return nil
        }
        let name = parts[9]
        return ParsedPoseLine(parts: parts, imageID: imageID, cameraID: cameraID, name: name)
    }

    private static func readDatabaseImageMappings(databaseURL: URL) throws -> [String: DatabaseImageMapping] {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            throw NSError(domain: "ColmapTextModelNormalizer", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "Unable to open database at \(databaseURL.path)"
            ])
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT image_id, name, camera_id FROM images;"
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw NSError(domain: "ColmapTextModelNormalizer", code: Int(prepare), userInfo: [
                NSLocalizedDescriptionKey: "Unable to query image mappings from database"
            ])
        }
        defer { sqlite3_finalize(statement) }

        var mappings: [String: DatabaseImageMapping] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let imageID = Int(sqlite3_column_int64(statement, 0))
            guard let nameCStr = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: nameCStr)
            let cameraID = Int(sqlite3_column_int64(statement, 2))
            mappings[name] = DatabaseImageMapping(imageID: imageID, cameraID: cameraID)
        }
        return mappings
    }
}
