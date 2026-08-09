import Darwin
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class UserSelectedExportPublicationTests: XCTestCase {
    func testSecurityScopeStartsBeforeDetachedPublicationAndEndsAfterLateCancelledSuccess() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            toolchainManager: UserSelectedExportTestToolchainManager(),
            projectBaseURL: root
        )
        let source = publicationSource(in: root)
        let destination = root.appendingPathComponent("Selected.ply")
        let state = ExportScopeState()
        let access = SecurityScopedAccess(
            start: { url in state.start(url); return true },
            stop: { state.stop($0) }
        )
        let publicationStarted = DispatchSemaphore(value: 0)
        let allowPublicationToReturn = DispatchSemaphore(value: 0)

        let export = Task { @MainActor in
            do {
                try await model.exportCurrentSplat(
                    source,
                    to: destination,
                    publisher: { _, _, _ in
                        state.recordPublicationStart()
                        publicationStarted.signal()
                        _ = allowPublicationToReturn.wait(timeout: .now() + 2)
                        state.recordPublicationEnd()
                    },
                    destinationAccess: access
                )
                return true
            } catch {
                return false
            }
        }
        let didStart = await wait(for: publicationStarted)
        XCTAssertEqual(didStart, .success)
        XCTAssertEqual(state.events, ["start", "publication-start-active"])

        export.cancel()
        await Task.yield()
        XCTAssertEqual(
            state.events,
            ["start", "publication-start-active"],
            "Cancellation must not close the grant while reconciliation is still running."
        )
        allowPublicationToReturn.signal()

        let succeeded = await export.value
        XCTAssertTrue(succeeded, "A reconciled success must not become a trailing cancellation.")
        XCTAssertEqual(
            state.events,
            ["start", "publication-start-active", "publication-end-active", "stop"]
        )
        XCTAssertEqual(state.startedURLs, [destination])
        XCTAssertEqual(state.stoppedURLs, [destination])
    }

    func testCorePublicationErrorsMapToSourceFailureDestinationFailureAndConflict() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            toolchainManager: UserSelectedExportTestToolchainManager(),
            projectBaseURL: root
        )
        let source = publicationSource(in: root)
        let destination = root.appendingPathComponent("Selected.ply")
        let cases: [(ProjectArtifactError, CurrentSplatExportError)] = [
            (.invalidOutput("source.ply"), .noFinishedOutput),
            (.publicationFailed("Selected.ply"), .destinationPublicationFailed),
            (.publicationConflict("Selected.ply"), .destinationPublicationConflict),
            (
                .publicationConflictPreservingPrevious("Selected.ply", "Previous.ply"),
                .destinationPublicationConflict
            ),
            (
                .publicationConflictPreservingFiles("Selected.ply", ["Foreign.ply"]),
                .destinationPublicationConflict
            ),
        ]

        for (coreError, expected) in cases {
            do {
                try await model.exportCurrentSplat(
                    source,
                    to: destination,
                    publisher: { _, _, _ in throw coreError }
                )
                XCTFail("Expected \(coreError) to be mapped.")
            } catch {
                XCTAssertEqual(error as? CurrentSplatExportError, expected)
            }
        }

        let subjectSource = AppModel.CurrentSplatPublicationSource(
            projectURL: source.projectURL,
            variant: .subject,
            outputURL: source.outputURL,
            expectedIdentity: source.expectedIdentity,
            publicationID: nil,
            publicationGeneration: nil,
            defaultFilename: source.defaultFilename
        )
        do {
            try await model.exportCurrentSplat(
                subjectSource,
                to: destination,
                publisher: { _, _, _ in
                    throw ProjectArtifactError.invalidOutput("subject.ply")
                }
            )
            XCTFail("Expected an invalid Subject source to be mapped.")
        } catch {
            XCTAssertEqual(error as? CurrentSplatExportError, .noValidSubjectOutput)
        }
    }

    func testSecurityScopeClosesAfterMappedPublicationFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            toolchainManager: UserSelectedExportTestToolchainManager(),
            projectBaseURL: root
        )
        let source = publicationSource(in: root)
        let destination = root.appendingPathComponent("Selected.ply")
        let state = ExportScopeState()
        let access = SecurityScopedAccess(
            start: { url in state.start(url); return true },
            stop: { state.stop($0) }
        )

        do {
            try await model.exportCurrentSplat(
                source,
                to: destination,
                publisher: { _, _, _ in
                    state.recordPublicationStart()
                    throw ProjectArtifactError.publicationFailed("Selected.ply")
                },
                destinationAccess: access
            )
            XCTFail("Expected publication failure.")
        } catch {
            XCTAssertEqual(error as? CurrentSplatExportError, .destinationPublicationFailed)
        }
        XCTAssertEqual(state.events, ["start", "publication-start-active", "stop"])
        XCTAssertEqual(state.startedURLs, [destination])
        XCTAssertEqual(state.stoppedURLs, [destination])
    }

    func testSameSourceDestinationRevalidatesExpectedEvidenceWithinSecurityScope() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            toolchainManager: UserSelectedExportTestToolchainManager(),
            projectBaseURL: root
        )
        let output = root.appendingPathComponent("source.ply")
        try writeMinimalPly(at: output)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: output)
        let expected = ExpectedPlyArtifactIdentity(
            byteCount: evidence.byteCount,
            vertexCount: evidence.vertexCount,
            sha256: evidence.sha256
        )
        let mutationDescriptor = Darwin.open(output.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(mutationDescriptor, 0)
        defer { Darwin.close(mutationDescriptor) }
        var changedByte = UInt8(ascii: "1")
        XCTAssertEqual(
            Darwin.pwrite(
                mutationDescriptor,
                &changedByte,
                1,
                off_t(try firstVertexXOffset(in: output))
            ),
            1
        )
        let source = AppModel.CurrentSplatPublicationSource(
            projectURL: root.appendingPathComponent("Project.easysplatproj"),
            variant: .original,
            outputURL: output,
            expectedIdentity: expected,
            publicationID: nil,
            publicationGeneration: nil,
            defaultFilename: "Project.ply"
        )
        let state = ExportScopeState()
        let access = SecurityScopedAccess(
            start: { url in state.start(url); return true },
            stop: { state.stop($0) }
        )

        do {
            try await model.exportCurrentSplat(
                source,
                to: output,
                publisher: { source, destination, expected in
                    state.recordPublicationStart()
                    defer { state.recordPublicationEnd() }
                    try AppModel.exportValidatedSplat(
                        from: source,
                        to: destination,
                        expected: expected
                    )
                },
                destinationAccess: access
            )
            XCTFail("Expected the mutated source evidence to be rejected.")
        } catch {
            XCTAssertEqual(error as? CurrentSplatExportError, .noFinishedOutput)
        }
        XCTAssertEqual(
            state.events,
            ["start", "publication-start-active", "publication-end-active", "stop"]
        )
        XCTAssertEqual(state.startedURLs, [output])
        XCTAssertEqual(state.stoppedURLs, [output])
    }

    private func publicationSource(in root: URL) -> AppModel.CurrentSplatPublicationSource {
        AppModel.CurrentSplatPublicationSource(
            projectURL: root.appendingPathComponent("Project.easysplatproj"),
            variant: .original,
            outputURL: root.appendingPathComponent("source.ply"),
            expectedIdentity: ExpectedPlyArtifactIdentity(
                byteCount: 1,
                vertexCount: 1,
                sha256: String(repeating: "a", count: 64)
            ),
            publicationID: nil,
            publicationGeneration: nil,
            defaultFilename: "Project.ply"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-user-export-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMinimalPly(at url: URL) throws {
        let text = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func firstVertexXOffset(in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let marker = Data("end_header\n".utf8)
        return try XCTUnwrap(data.range(of: marker)).upperBound
    }

    private func wait(for semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 1))
            }
        }
    }
}

private final class ExportScopeState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var storedEvents: [String] = []
    private var storedStartedURLs: [URL] = []
    private var storedStoppedURLs: [URL] = []

    var events: [String] { lock.withLock { storedEvents } }
    var startedURLs: [URL] { lock.withLock { storedStartedURLs } }
    var stoppedURLs: [URL] { lock.withLock { storedStoppedURLs } }

    func start(_ url: URL) {
        lock.withLock {
            active = true
            storedStartedURLs.append(url)
            storedEvents.append("start")
        }
    }

    func stop(_ url: URL) {
        lock.withLock {
            storedEvents.append(active ? "stop" : "stop-inactive")
            active = false
            storedStoppedURLs.append(url)
        }
    }

    func recordPublicationStart() {
        lock.withLock {
            storedEvents.append(active ? "publication-start-active" : "publication-start-inactive")
        }
    }

    func recordPublicationEnd() {
        lock.withLock {
            storedEvents.append(active ? "publication-end-active" : "publication-end-inactive")
        }
    }
}

private struct UserSelectedExportTestToolchainManager: ToolchainManaging {
    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        fatalError("User-selected export tests do not install a toolchain.")
    }
}
