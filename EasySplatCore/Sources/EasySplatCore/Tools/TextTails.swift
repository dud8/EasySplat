import Foundation

enum TextTails {
    static func tailLines(_ text: String, limit: Int, byteLimit: Int = 64 * 1024) -> String {
        guard limit > 0, byteLimit > 0 else { return "" }
        let lines = splitLines(text)
        let tailed = lines.count > limit ? lines.suffix(limit).joined(separator: "\n") : text
        return trimToByteLimit(tailed, byteLimit: byteLimit)
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r" {
                lines.append(current)
                current = ""
                let next = text.index(after: index)
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                } else {
                    index = next
                }
            } else {
                current.append(character)
                index = text.index(after: index)
            }
        }
        lines.append(current)
        return lines
    }

    private static func trimToByteLimit(_ text: String, byteLimit: Int) -> String {
        TextByteLimiter.validUTF8Suffix(text, byteLimit: byteLimit)
    }
}

enum TextByteLimiter {
    static func validUTF8Suffix(_ text: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
        guard text.utf8.count > byteLimit else { return text }

        var start = text.endIndex
        var retainedBytes = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let characterBytes = text[previous..<start].utf8.count
            guard retainedBytes + characterBytes <= byteLimit else { break }
            retainedBytes += characterBytes
            start = previous
        }
        return String(text[start...])
    }
}
