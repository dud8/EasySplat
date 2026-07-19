#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class UnorderedPhotoProductBoundaryTests: XCTestCase {
    private struct ReceiptProof: Equatable {
        let projectRelativePath: String
        let controlledSHA256: String
        let sourceSHA256: String
        let retainedRank: Int
    }

    private struct SelectedProof: Equatable {
        let outputFileName: String
        let sourceSHA256: String
        let retainedRank: Int
        let selectedSHA256: String
        let selectedPixelSHA256: String
    }

    private struct BoundaryProof {
        let receipts: [ReceiptProof]
        let selected: [SelectedProof]
        let selectionArtifactSHA256: String

        var receiptContentOrder: [String] { receipts.map(\.sourceSHA256) }
        var selectedContentOrder: [String] { selected.map(\.sourceSHA256) }
    }

    func testUnorderedAdmissionCanonicalizesFourFilenamePermutationsThroughSelectionBoundary() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureRoot = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)

        let fixtureBytes = try (0..<8).map { index -> Data in
            let url = fixtureRoot.appendingPathComponent("fixture-\(index).png")
            try writeGrayscalePNG(at: url, value: UInt8(32 + index * 27))
            return try Data(contentsOf: url)
        }
        let permutations = [
            [3, 0, 7, 1, 6, 2, 5, 4],
            [6, 2, 0, 7, 3, 5, 1, 4],
            [1, 7, 4, 0, 5, 3, 6, 2],
            [5, 4, 2, 6, 1, 7, 3, 0],
        ]

        var unorderedProofs: [BoundaryProof] = []
        var continuousProofs: [BoundaryProof] = []
        for (variant, permutation) in permutations.enumerated() {
            let source = root.appendingPathComponent("source-\(variant)", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            for (position, contentIndex) in permutation.enumerated() {
                try fixtureBytes[contentIndex].write(
                    to: source.appendingPathComponent(String(format: "random-%02d.png", position)),
                    options: .withoutOverwriting
                )
            }
            unorderedProofs.append(try await boundaryProof(
                source: source,
                workspace: root.appendingPathComponent("unordered-\(variant)", isDirectory: true),
                inputOrdering: .unordered
            ))
            continuousProofs.append(try await boundaryProof(
                source: source,
                workspace: root.appendingPathComponent("continuous-\(variant)", isDirectory: true),
                inputOrdering: .continuous
            ))
        }

        let canonical = try XCTUnwrap(unorderedProofs.first)
        XCTAssertTrue(unorderedProofs.dropFirst().allSatisfy { $0.receipts == canonical.receipts })
        XCTAssertTrue(unorderedProofs.dropFirst().allSatisfy { $0.selected == canonical.selected })
        XCTAssertTrue(unorderedProofs.dropFirst().allSatisfy {
            $0.selectionArtifactSHA256 == canonical.selectionArtifactSHA256
        })
        XCTAssertEqual(canonical.selected.map(\.retainedRank), [0, 1, 2])
        XCTAssertEqual(
            canonical.selectedContentOrder,
            canonical.receipts.sorted { $0.retainedRank < $1.retainedRank }
                .prefix(3).map(\.sourceSHA256)
        )
        XCTAssertEqual(Set(continuousProofs.map(\.receiptContentOrder)).count, permutations.count)
        XCTAssertTrue(continuousProofs.allSatisfy {
            $0.selected.map(\.retainedRank) == [0, 2, 4]
                && $0.receiptContentOrder != canonical.receiptContentOrder
        })
    }

    private func boundaryProof(
        source: URL,
        workspace: URL,
        inputOrdering: InputOrdering
    ) async throws -> BoundaryProof {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let prepared = try await PhotoInputPreflight.prepare(
            folder: source,
            stagingParent: workspace,
            photoSelection: .automatic,
            inputOrdering: inputOrdering,
            keyframeBudget: 5,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 8,
                maximumTotalBytes: 8 * 1_024 * 1_024,
                maximumSinglePhotoBytes: 1_024 * 1_024,
                maximumPixelCount: 1_024 * 1_024,
                maximumDecodedDimension: 128,
                maximumTraversalEntryCount: 16,
                maximumRecursionDepth: 2,
                minimumFreeSpaceReserveBytes: 0
            ),
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        let project = workspace.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let paths = ProjectPaths(root: project)
        var adoption = ProjectInputAdoption(requestedInput: .photos(folder: source.path))
        try adoption.adoptPhotos(prepared, into: paths)
        try paths.ensureDirectories()
        let receipts = try XCTUnwrap(adoption.photoInputReceipts)
        let receiptProof = receipts.map {
            ReceiptProof(
                projectRelativePath: $0.projectRelativePath,
                controlledSHA256: $0.sha256,
                sourceSHA256: $0.source.sha256,
                retainedRank: $0.retainedRank
            )
        }

        let options = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: inputOrdering,
            photoSelection: .automatic
        )
        let input = adoption.input
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let metadata = ProjectMetadata(
            title: "Permutation",
            input: input,
            photoInputReceipts: receipts,
            photoSelectionReceipt: adoption.photoSelectionReceipt,
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )
        let projection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: paths
        ))
        let selectedReceipts = try projection.project(targetCount: 3)
        let runner = PipelineRunner(
            projectURL: project,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: workspace))
        )
        let adoptedPhotos = try selectedReceipts.map {
            try paths.resolveProjectRelativePath($0.projectRelativePath)
        }
        let bindings = Dictionary(uniqueKeysWithValues: zip(adoptedPhotos, selectedReceipts).map {
            photo, receipt in
            (
                photo.lastPathComponent,
                PipelineRunner.SelectedInputSource(
                    projectRelativePath: receipt.projectRelativePath,
                    sha256: receipt.sha256,
                    photoRetainedRank: receipt.retainedRank
                )
            )
        })
        let selection = try runner.copySelected(
            groups: [.init(
                id: "photos",
                frames: adoptedPhotos,
                isVideo: false,
                budgetProjection: projection.policy == .rankedPrefix
                    ? .rankedPrefix
                    : .evenlySpaced,
                sourceBindingsByFileName: bindings
            )],
            to: paths.framesSelectedURL,
            manifestURL: paths.framesSelectedManifestURL,
            maxDimension: 128,
            projectPaths: paths
        )
        XCTAssertEqual(
            selection.frames.map(\.lastPathComponent),
            selection.manifest.map(\.outputFileName)
        )
        let selectedProof = try selection.manifest.map { item in
            SelectedProof(
                outputFileName: item.outputFileName,
                sourceSHA256: try XCTUnwrap(item.sourceSHA256),
                retainedRank: try XCTUnwrap(item.photoRetainedRank),
                selectedSHA256: try XCTUnwrap(item.selectedSHA256),
                selectedPixelSHA256: try XCTUnwrap(item.selectedPixelSHA256)
            )
        }
        return BoundaryProof(
            receipts: receiptProof,
            selected: selectedProof,
            selectionArtifactSHA256: try XCTUnwrap(adoption.photoSelectionReceipt?.sha256)
        )
    }

    private func writeGrayscalePNG(at url: URL, value: UInt8) throws {
        let width = 24
        let height = 24
        var pixels = [UInt8](repeating: value, count: width * height)
        let data = Data(bytes: &pixels, count: pixels.count)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
#endif
