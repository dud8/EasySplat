import AVFoundation
import CoreMedia
import Foundation
import ImageIO

public enum NativeProjectionTag: String, Equatable, Sendable {
    case equirectangular360 = "equirectangular-360"
    case halfEquirectangular180 = "half-equirectangular-180"
    case appleImmersive = "apple-immersive"
    case parametricImmersive = "parametric-immersive"
}

public struct UnsupportedSphericalMediaIssue: Error, Equatable, Sendable {
    public let tag: NativeProjectionTag

    public init(tag: NativeProjectionTag) {
        self.tag = tag
    }
}

struct NativeVideoProjectionInspection: Equatable, Sendable {
    let primaryTrackID: Int32
    let tag: NativeProjectionTag?
}

enum NativeProjectionMetadataError: Error, Equatable {
    case malformedISOBaseMedia
    case oversizedISOBaseMediaMetadata
}

enum NativeProjectionMetadataProbe {
    private static let gpanoNamespace = "http://ns.google.com/photos/1.0/panorama/"

    static func tag(inImageAt url: URL) -> NativeProjectionTag? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return tag(inImageSource: source)
    }

    static func tag(inImageSource source: CGImageSource) -> NativeProjectionTag? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else {
            return nil
        }
        var projectionValues: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(
            metadata,
            nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        ) { _, metadataTag in
            guard (CGImageMetadataTagCopyNamespace(metadataTag) as String?) == gpanoNamespace,
                  (CGImageMetadataTagCopyName(metadataTag) as String?) == "ProjectionType",
                  let value = CGImageMetadataTagCopyValue(metadataTag) as? String,
                  let normalized = normalizedString(value as CFString) else {
                return true
            }
            projectionValues.append(normalized)
            return true
        }
        let uniqueValues = Set(projectionValues)
        guard uniqueValues == ["equirectangular"] else { return nil }
        return .equirectangular360
    }

    static func inspection(inVideoAt url: URL) async throws -> NativeVideoProjectionInspection {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let primary = try await FrameExtractor.loadPrimaryTrack(from: tracks)
        let descriptions = try await primary.track.load(.formatDescriptions)
        let standardizedTag = tag(fromVideoProjectionKindValues: descriptions.compactMap {
            CMFormatDescriptionGetExtension(
                $0,
                extensionKey: kCMFormatDescriptionExtension_ProjectionKind
            ) as? String
        })
        let containerTag: NativeProjectionTag?
        if try ISOBaseMediaSphericalMetadataReader.isLikelyContainer(at: url) {
            containerTag = try tag(
                inISOBaseMediaAt: url,
                selectedTrackID: primary.descriptor.trackID
            )
        } else {
            containerTag = nil
        }
        return NativeVideoProjectionInspection(
            primaryTrackID: primary.descriptor.trackID,
            tag: containerTag ?? standardizedTag
        )
    }

    static func tag(
        inISOBaseMediaAt url: URL,
        selectedTrackID: Int32
    ) throws -> NativeProjectionTag? {
        var reader = try ISOBaseMediaSphericalMetadataReader(url: url)
        return try reader.tag(selectedTrackID: selectedTrackID)
    }

    static func tag(fromVideoProjectionKindValues values: [String]) -> NativeProjectionTag? {
        let recognized = Set(values.compactMap { raw -> NativeProjectionTag? in
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "Equirectangular":
                return .equirectangular360
            case "HalfEquirectangular":
                return .halfEquirectangular180
            case "AppleImmersiveVideo":
                return .appleImmersive
            case "ParametricImmersive":
                return .parametricImmersive
            default:
                return nil
            }
        })
        guard recognized.count == 1 else { return nil }
        return recognized.first
    }

    private static func normalizedString(_ value: CFString?) -> String? {
        guard let value else { return nil }
        let normalized = (value as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 64 else { return nil }
        return normalized
    }
}

private struct ISOBaseMediaSphericalMetadataReader {
    private struct Box {
        let type: String
        let payloadStart: UInt64
        let end: UInt64

        var payloadSize: UInt64 { end - payloadStart }
    }

    private static let sphericalV1UUID = Data([
        0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93,
        0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd,
    ])
    private static let maximumMetadataBytes: UInt64 = 256 * 1_024
    private static let maximumBoxCount = 100_000
    private static let maximumDepth = 16
    private static let recursiveContainers: Set<String> = [
        "mdia", "minf", "stbl", "dinf", "edts", "udta", "sv3d", "proj",
    ]
    private static let visualSampleEntries: Set<String> = [
        "avc1", "avc3", "hev1", "hvc1", "jpeg", "mp4v", "ap4h", "apcn",
        "dvh1", "dvhe", "vp09", "av01", "encv",
    ]

    private let handle: FileHandle
    private let fileSize: UInt64
    private var boxCount = 0

    init(url: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
            fileSize = try handle.seekToEnd()
        } catch {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
    }

    static func isLikelyContainer(at url: URL) throws -> Bool {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw NativeProjectionMetadataError.malformedISOBaseMedia }
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8,
              let type = String(data: header[4..<8], encoding: .ascii) else {
            return false
        }
        return ["ftyp", "moov", "wide", "free", "skip", "mdat"].contains(type)
    }

    mutating func tag(selectedTrackID: Int32) throws -> NativeProjectionTag? {
        defer { try? handle.close() }
        guard fileSize >= 8 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let topLevel = try boxes(in: 0..<fileSize, depth: 0)
        var selectedTrack: Box?
        for movie in topLevel where movie.type == "moov" {
            for track in try boxes(in: movie.payloadStart..<movie.end, depth: 1)
                where track.type == "trak" {
                let children = try boxes(in: track.payloadStart..<track.end, depth: 2)
                let trackHeaders = children.filter { $0.type == "tkhd" }
                guard trackHeaders.count == 1 else {
                    throw NativeProjectionMetadataError.malformedISOBaseMedia
                }
                if try trackID(in: trackHeaders[0]) == UInt32(bitPattern: selectedTrackID) {
                    guard selectedTrack == nil else {
                        throw NativeProjectionMetadataError.malformedISOBaseMedia
                    }
                    selectedTrack = track
                }
            }
        }
        guard let selectedTrack else { return nil }
        let directChildren = try boxes(
            in: selectedTrack.payloadStart..<selectedTrack.end,
            depth: 2
        )

        var v1Detected = false
        for uuid in directChildren where uuid.type == "uuid" {
            guard uuid.payloadSize >= 16 else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            let identifier = try read(at: uuid.payloadStart, count: 16)
            guard identifier == Self.sphericalV1UUID else { continue }
            let xmlByteCount = uuid.payloadSize - 16
            guard xmlByteCount <= Self.maximumMetadataBytes else {
                throw NativeProjectionMetadataError.oversizedISOBaseMediaMetadata
            }
            let xml = try read(
                at: uuid.payloadStart + 16,
                count: Int(xmlByteCount)
            )
            guard try SphericalV1XMLInspector.isEquirectangular(xml) else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            v1Detected = true
        }

        var v2Tags: [NativeProjectionTag] = []
        for child in directChildren {
            try collectV2Tags(in: child, depth: 3, into: &v2Tags)
        }
        let uniqueV2Tags = Set(v2Tags)
        guard uniqueV2Tags.count <= 1 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        if let v2Tag = uniqueV2Tags.first { return v2Tag }
        return v1Detected ? .equirectangular360 : nil
    }

    private mutating func collectV2Tags(
        in box: Box,
        depth: Int,
        into tags: inout [NativeProjectionTag]
    ) throws {
        guard depth <= Self.maximumDepth else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        if box.type == "sv3d" {
            tags.append(try tag(inSV3D: box, depth: depth))
            return
        }
        if box.type == "stsd" {
            guard box.payloadSize >= 8 else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            let header = try read(at: box.payloadStart, count: 8)
            guard header[0] == 0, let declaredEntryCount = header.uint32(at: 4) else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            let entries = try boxes(in: (box.payloadStart + 8)..<box.end, depth: depth)
            guard UInt64(entries.count) == UInt64(declaredEntryCount) else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            for entry in entries where Self.visualSampleEntries.contains(entry.type) {
                guard entry.payloadSize >= 78 else {
                    throw NativeProjectionMetadataError.malformedISOBaseMedia
                }
                for child in try boxes(
                    in: (entry.payloadStart + 78)..<entry.end,
                    depth: depth + 1,
                    allowTrailingZeroPadding: true
                ) {
                    try collectV2Tags(in: child, depth: depth + 1, into: &tags)
                }
            }
            return
        }
        if box.type == "meta" {
            guard box.payloadSize >= 4 else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            for child in try boxes(
                in: (box.payloadStart + 4)..<box.end,
                depth: depth + 1
            ) {
                try collectV2Tags(in: child, depth: depth + 1, into: &tags)
            }
            return
        }
        guard Self.recursiveContainers.contains(box.type) else { return }
        for child in try boxes(in: box.payloadStart..<box.end, depth: depth + 1) {
            try collectV2Tags(in: child, depth: depth + 1, into: &tags)
        }
    }

    private mutating func tag(inSV3D box: Box, depth: Int) throws -> NativeProjectionTag {
        let children = try boxes(in: box.payloadStart..<box.end, depth: depth + 1)
        let projections = children.filter { $0.type == "proj" }
        guard children.filter({ $0.type == "svhd" }).count == 1,
              projections.count == 1 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let projection = projections[0]
        let projectionChildren = try boxes(
            in: projection.payloadStart..<projection.end,
            depth: depth + 2
        )
        guard projectionChildren.filter({ $0.type == "prhd" }).count == 1 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let projectionTypes = projectionChildren.filter {
            ["equi", "cbmp", "mshp"].contains($0.type)
        }
        guard projectionTypes.count == 1, projectionTypes[0].type == "equi" else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let equirectangular = projectionTypes[0]
        guard equirectangular.payloadSize >= 20 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let payload = try read(at: equirectangular.payloadStart, count: 20)
        guard payload[0] == 0 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let top = payload.uint32(at: 4)
        let bottom = payload.uint32(at: 8)
        let left = payload.uint32(at: 12)
        let right = payload.uint32(at: 16)
        guard let top, let bottom, let left, let right else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        if top == 0, bottom == 0,
           UInt64(left) + UInt64(right) == UInt64(0x8000_0000) {
            return .halfEquirectangular180
        }
        return .equirectangular360
    }

    private mutating func trackID(in box: Box) throws -> UInt32 {
        guard box.payloadSize >= 4 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let version = try read(at: box.payloadStart, count: 1)[0]
        let offset: UInt64
        switch version {
        case 0: offset = 12
        case 1: offset = 20
        default: throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        guard box.payloadSize >= offset + 4 else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        guard let value = try read(at: box.payloadStart + offset, count: 4).uint32(at: 0) else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        return value
    }

    private mutating func boxes(
        in range: Range<UInt64>,
        depth: Int,
        allowTrailingZeroPadding: Bool = false
    ) throws -> [Box] {
        guard depth <= Self.maximumDepth, range.lowerBound <= range.upperBound,
              range.upperBound <= fileSize else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let remaining = range.upperBound - cursor
            if remaining < 8, allowTrailingZeroPadding,
               try read(at: cursor, count: Int(remaining)).allSatisfy({ $0 == 0 }) {
                cursor = range.upperBound
                continue
            }
            guard remaining >= 8 else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            boxCount += 1
            guard boxCount <= Self.maximumBoxCount else {
                throw NativeProjectionMetadataError.oversizedISOBaseMediaMetadata
            }
            let header = try read(at: cursor, count: 8)
            guard let smallSize = header.uint32(at: 0),
                  let type = String(data: header[4..<8], encoding: .ascii) else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            let headerSize: UInt64
            let size: UInt64
            switch smallSize {
            case 0:
                headerSize = 8
                size = range.upperBound - cursor
            case 1:
                guard range.upperBound - cursor >= 16,
                      let extended = try read(at: cursor + 8, count: 8).uint64(at: 0) else {
                    throw NativeProjectionMetadataError.malformedISOBaseMedia
                }
                headerSize = 16
                size = extended
            default:
                headerSize = 8
                size = UInt64(smallSize)
            }
            guard size >= headerSize, size <= range.upperBound - cursor else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            result.append(Box(
                type: type,
                payloadStart: cursor + headerSize,
                end: cursor + size
            ))
            cursor += size
        }
        return result
    }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, UInt64(count) <= fileSize,
              offset <= fileSize - UInt64(count) else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw NativeProjectionMetadataError.malformedISOBaseMedia
            }
            return data
        } catch let error as NativeProjectionMetadataError {
            throw error
        } catch {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
    }
}

private final class SphericalV1XMLInspector: NSObject, XMLParserDelegate {
    private static let namespace = "http://ns.google.com/videos/1.0/spherical/"
    private var activeElement: String?
    private var activeText = ""
    private var values: [String: [String]] = [:]

    static func isEquirectangular(_ data: Data) throws -> Bool {
        guard let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<!DOCTYPE", options: [.caseInsensitive]) == nil else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        let inspector = SphericalV1XMLInspector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = inspector
        guard parser.parse() else {
            throw NativeProjectionMetadataError.malformedISOBaseMedia
        }
        return inspector.singleValue("Spherical") == "true"
            && inspector.singleValue("Stitched") == "true"
            && inspector.singleValue("ProjectionType")?.lowercased() == "equirectangular"
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard namespaceURI == Self.namespace,
              ["Spherical", "Stitched", "ProjectionType"].contains(elementName) else {
            activeElement = nil
            activeText = ""
            return
        }
        activeElement = elementName
        activeText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeElement != nil, activeText.utf8.count + string.utf8.count <= 128 else {
            return
        }
        activeText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard namespaceURI == Self.namespace, activeElement == elementName else { return }
        values[elementName, default: []].append(
            activeText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        activeElement = nil
        activeText = ""
    }

    private func singleValue(_ name: String) -> String? {
        guard let values = values[name], values.count == 1 else { return nil }
        return values[0]
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset >= 0, count >= offset + 8 else { return nil }
        return self[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
