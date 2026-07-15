#if canImport(XCTest)
import Darwin
import Foundation
import SQLite3
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class PipelineFeatureRecoverySafetyTests: XCTestCase {
    func testFeatureExtractionStartsAfterStaleDatabaseStateIsFullyRemoved() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePhotos = root.appendingPathComponent("SourcePhotos", isDirectory: true)
        try TestFileBuilder.createDirectory(sourcePhotos)
        for index in 0..<2 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: sourcePhotos.appendingPathComponent("image_\(index).png"),
                size: 16,
                value: UInt8(48 + index),
                utType: .png
            ))
        }

        let projectURL = root.appendingPathComponent("StaleState.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Stale state",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
        )
        let staleURLs = [
            paths.colmapDatabaseURL,
            URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-wal"),
            URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-shm"),
            URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-journal"),
            paths.colmapFeatureEvidenceURL,
            paths.pairGraphEvidenceURL,
            paths.pairGraphRecoveryURL,
            paths.colmapSeedURL.appendingPathComponent("pairs_attempt_1.txt"),
            paths.colmapSparseURL.appendingPathComponent("stale.txt"),
            paths.geometryManifestURL,
            paths.trainingURL.appendingPathComponent("stale.txt"),
        ]
        for url in staleURLs {
            try Data("stale".utf8).write(to: url)
        }
        let publishedOutput = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: publishedOutput)

        let toolchain = TestToolchains.toolchainPaths(root: root)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertTrue(staleURLs.allSatisfy {
                        !FileManager.default.fileExists(atPath: $0.path)
                    })
                    XCTAssertEqual(
                        ProjectArtifactValidator.validatePlyFile(at: publishedOutput),
                        .valid
                    )
                    do {
                        try self.writeFeatureDatabase(for: arguments)
                    } catch {
                        XCTFail("Could not create feature database: \(error)")
                    }
                }
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: .colmap,
                    stopAfterStage: .sfmFeatures,
                    skipTraining: true
                ),
                hardwareProfile: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                )
            ),
            tooling: .init(runner: subprocess)
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(subprocess.calls.map { $0.1.first }, ["feature_extractor"])
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publishedOutput), .valid)
    }

    func testFeatureCleanupFailurePreventsExtractorAndPreservesPublishedOutput() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePhotos = root.appendingPathComponent("SourcePhotos", isDirectory: true)
        try TestFileBuilder.createDirectory(sourcePhotos)
        for index in 0..<2 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: sourcePhotos.appendingPathComponent("image_\(index).png"),
                size: 16,
                value: UInt8(32 + index),
                utType: .png
            ))
        }

        let projectURL = root.appendingPathComponent("Cleanup.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Cleanup",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
        )
        try Data("stale database".utf8).write(to: paths.colmapDatabaseURL)
        try Data("stale wal".utf8).write(
            to: URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-wal")
        )
        try Data("stale shm".utf8).write(
            to: URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-shm")
        )
        try Data("stale journal".utf8).write(
            to: URL(fileURLWithPath: paths.colmapDatabaseURL.path + "-journal")
        )
        try Data("stale feature evidence".utf8).write(to: paths.colmapFeatureEvidenceURL)
        try Data("stale pair evidence".utf8).write(to: paths.pairGraphEvidenceURL)
        let publishedOutput = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: publishedOutput)

        XCTAssertEqual(chflags(paths.colmapDatabaseURL.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(paths.colmapDatabaseURL.path, 0) }

        let toolchain = TestToolchains.toolchainPaths(root: root)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                )
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: pipelineConfig(toolchain: toolchain),
            tooling: .init(runner: subprocess)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        XCTAssertTrue(subprocess.calls.isEmpty)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publishedOutput), .valid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path))
    }

    func testDisconnectedPlannedScheduleNeverRunsMatcherOrExactRetry() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourcePhotos = root.appendingPathComponent("SourcePhotos", isDirectory: true)
        try TestFileBuilder.createDirectory(sourcePhotos)
        for index in 0..<251 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: sourcePhotos.appendingPathComponent(String(format: "image_%03d.png", index)),
                size: 8,
                value: UInt8(index),
                utType: .png
            ))
        }

        let projectURL = root.appendingPathComponent("Disconnected.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Disconnected",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .highDetail,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
        )

        let toolchain = TestToolchains.toolchainPaths(root: root)
        let emptyRetrieval: ([String]) -> Void = { arguments in
            guard let outputPath = self.value(for: "--output_pair_list_path", in: arguments) else {
                return XCTFail("Missing retrieval output path")
            }
            FileManager.default.createFile(atPath: outputPath, contents: Data())
        }
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    do {
                        try self.writeFeatureDatabase(for: arguments)
                    } catch {
                        XCTFail("Could not create feature database: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: emptyRetrieval
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: emptyRetrieval
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: emptyRetrieval
            ),
        ])
        let events = EventRecorder()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: pipelineConfig(toolchain: toolchain),
            tooling: .init(runner: subprocess)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { events.append($0) }
        }

        let commands = subprocess.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 3)
        XCTAssertFalse(commands.contains("matches_importer"))
        XCTAssertFalse(events.containsLog("exact descriptor matching"))
    }

    private func pipelineConfig(toolchain: ToolchainPaths) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: DevelopmentOverrides(
                candidateRoute: .colmap,
                skipTraining: true
            ),
            hardwareProfile: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            )
        )
    }

    private func value(for key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func writeFeatureDatabase(for arguments: [String]) throws {
        guard let databasePath = value(for: "--database_path", in: arguments),
              let imagePath = value(for: "--image_path", in: arguments) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: imagePath, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()

        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        try executeSQL(
            """
            CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);
            CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, camera_id INTEGER NOT NULL);
            CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
            CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
            CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
            CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB, config INTEGER NOT NULL DEFAULT 0);
            INSERT INTO cameras(camera_id) VALUES (1);
            """,
            database: database
        )
        for (offset, imageName) in imageNames.enumerated() {
            let identifier = offset + 1
            try executeSQL(
                """
                INSERT INTO images(image_id, name, camera_id) VALUES (\(identifier), '\(imageName)', 1);
                INSERT INTO keypoints(image_id, rows, cols, data) VALUES (\(identifier), 1, 4, X'00000000');
                INSERT INTO descriptors(image_id, rows, cols, data) VALUES (\(identifier), 1, 128, zeroblob(128));
                """,
                database: database
            )
        }
    }

    private func executeSQL(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []

    func append(_ event: PipelineEvent) {
        lock.withLock { events.append(event) }
    }

    func containsLog(_ fragment: String) -> Bool {
        lock.withLock {
            events.contains { event in
                guard case let .stageLog(_, line, _) = event else { return false }
                return line.contains(fragment)
            }
        }
    }
}
#endif
