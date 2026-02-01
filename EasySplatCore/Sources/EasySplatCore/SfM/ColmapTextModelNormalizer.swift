import Foundation

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

            if nextLine == nil || isPoseLine(nextLine!) {
                output.append("")
                didChange = true
            }
        }

        guard didChange else { return false }
        let normalized = output.joined(separator: "\n") + "\n"
        try normalized.write(to: imagesTxtURL, atomically: true, encoding: .utf8)
        return true
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
}
