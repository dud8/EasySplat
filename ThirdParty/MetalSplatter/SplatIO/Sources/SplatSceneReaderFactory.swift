import Foundation

/// One place that decides which reader a file gets, so the renderer, the bounds
/// calculator and anything that asks "can this be opened" cannot disagree.
public enum SplatSceneFormat: String, CaseIterable, Sendable {
    /// Covers both the uncompressed splat PLY and the chunked layout SuperSplat writes.
    case ply
    case splat

    public var fileExtension: String { rawValue }

    public static func format(for url: URL) -> SplatSceneFormat? {
        SplatSceneFormat(rawValue: url.pathExtension.lowercased())
    }

    public static var readableExtensions: Set<String> {
        Set(allCases.map(\.fileExtension))
    }
}

public enum SplatSceneReaderFactory {
    public enum Error: LocalizedError, Equatable {
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                ext.isEmpty
                    ? "This file has no extension identifying a splat format."
                    : "EasySplat does not read .\(ext) splats."
            }
        }
    }

    /// Builds a reader for a format the caller has already decided on. Use this when the
    /// URL cannot be dispatched on, such as a `/dev/fd` descriptor path.
    ///
    /// - Parameter validatesRenderEncoding: pass `false` only when the delegate encodes
    ///   every point with ``SplatRenderEncodingValidator`` before retaining it.
    public static func reader(
        for url: URL,
        format: SplatSceneFormat,
        validatesRenderEncoding: Bool = true
    ) -> SplatSceneReader {
        switch format {
        case .ply:
            SplatPLYSceneReader(url, validatesRenderEncoding: validatesRenderEncoding)
        case .splat:
            SplatBinarySceneReader(url)
        }
    }

    /// Builds a reader from the file's own extension, for files a user chose.
    public static func reader(
        for url: URL,
        validatesRenderEncoding: Bool = true
    ) throws -> SplatSceneReader {
        guard let format = SplatSceneFormat.format(for: url) else {
            throw Error.unsupportedFormat(url.pathExtension.lowercased())
        }
        return reader(for: url, format: format, validatesRenderEncoding: validatesRenderEncoding)
    }
}
